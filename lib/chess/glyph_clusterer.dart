import 'dart:math' as math;
import 'dart:typed_data';

/// Book-level glyph clustering with legality-vote labeling.
///
/// Rationale (see project memory "legality-decoding proposal"): what is
/// actually constant across a printed book is the *shape* of each figurine
/// glyph — the same figurine font is used from cover to cover. The OCR text
/// layer's reading of that shape is NOT constant (the same rook glyph is
/// read as "E" on one page and "H" on another), and the per-blob TFLite
/// classifier misses many instances. So instead of trusting either reading
/// per occurrence:
///
///   1. Every glyph crop processed by the CV pipeline is assigned to a
///      shape cluster (incremental nearest-centroid clustering on a
///      down-sampled crop).
///   2. While parsing *anchored* segments (position known exactly: user
///      FEN, FEN found in text, or a game starting at move 1), each move
///      whose piece letter is uniquely determined by legality casts a vote
///      "cluster X is piece P".
///   3. A cluster labeled by enough concordant votes overrides both the
///      OCR char and the per-blob classifier everywhere in the book.
///
/// Votes are keyed by a caller-supplied source id (page + token index) so
/// re-analysing a page overwrites its previous votes instead of double
/// counting them.
class GlyphClusterer {
  GlyphClusterer({
    // 0.87: a too-strict threshold fragments the same glyph into many
    // clusters and votes never accumulate (observed: 10k+ clusters, 0
    // labels at 0.93 on a scanned book). A too-loose one merges different
    // glyphs — but a merged cluster with conflicting votes simply fails the
    // dominance check and stays unlabeled, so erring low is the safe side.
    this.similarityThreshold = 0.87,
    this.minVotes = 3,
    this.minDominance = 0.8,
  });

  /// Feature grid: 32×32 crops are mean-pooled to 16×16, then zero-meaned
  /// and L2-normalised so cosine similarity compares pure shape.
  static const int gridSize = 16;
  static const int dim = gridSize * gridSize;

  /// Minimum cosine similarity to join an existing cluster.
  final double similarityThreshold;

  /// Minimum number of legality votes before a cluster gets a piece label.
  final int minVotes;

  /// Minimum fraction of the cluster's votes the winning piece must hold.
  final double minDominance;

  final List<Float32List> _centroids = [];
  final List<int> _counts = [];
  final List<double> _aspects = [];

  /// Diagnostic: histogram of best-similarity per assign. Buckets:
  /// <0.70, 0.70–0.75, 0.75–0.80, 0.80–0.85, 0.85–0.90, 0.90–0.95, ≥0.95.
  static const simBucketEdges = [0.70, 0.75, 0.80, 0.85, 0.90, 0.95];
  final List<int> _simHistogram = List.filled(simBucketEdges.length + 1, 0);
  int _assignCount = 0;

  static int _simBucket(double sim) {
    for (int i = 0; i < simBucketEdges.length; i++) {
      if (sim < simBucketEdges[i]) return i;
    }
    return simBucketEdges.length;
  }

  /// source id ("page:tokenIndex") → (clusterId, piece letter).
  final Map<String, (int, String)> _votes = {};

  /// clusterId → piece → vote count. Rebuilt lazily after votes change.
  Map<int, Map<String, int>>? _tallyCache;

  int get clusterCount => _centroids.length;
  int get voteCount => _votes.length;

  /// Converts a 32×32 grayscale crop (values 0–1, row-major, ink dark) into
  /// the clustering feature vector, registration-invariant:
  ///
  ///   1. Find the tight bounding box of the ink (pixels below the mid-range
  ///      threshold). The crop comes from an OCR char rect whose padding and
  ///      cuts jitter by several pixels between occurrences of the *same*
  ///      glyph — resampling the raw box makes identical glyphs dissimilar
  ///      and was fragmenting the book into thousands of clusters.
  ///   2. Bilinearly resample the ink box to 16×16 (translation + scale
  ///      normalisation), then zero-mean and L2-normalise so cosine
  ///      similarity compares pure shape.
  ///
  /// [cropAspect] is the source crop's width/height in page pixels; the
  /// returned aspect is the ink box's aspect in the same units, to be passed
  /// to [assign] (the raw crop aspect carries the same bbox jitter).
  static ({Float32List features, double aspect}) featuresFromCrop32(
    Float32List crop32,
    double cropAspect,
  ) {
    const src = 32;

    // 1. Ink bounding box over the DOMINANT connected components only
    //    (ink = below mid-range threshold). OCR char rects bleed into
    //    neighbouring glyphs and scans carry salt-and-pepper noise; a bbox
    //    over every ink pixel jumps around with each stray fragment, which
    //    de-registers otherwise identical glyphs. Components smaller than
    //    25 % of the largest one are ignored; genuinely split glyph halves
    //    (comparable sizes) both stay in.
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final v in crop32) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    int x0 = src, x1 = -1, y0 = src, y1 = -1;
    if (hi - lo > 1e-6) {
      final thr = lo + (hi - lo) * 0.5;
      // Label 4-connected ink components.
      final comp = Int32List(src * src); // 0 = background / unvisited
      final compSizes = <int>[0]; // index 0 unused
      final stack = <int>[];
      for (int start = 0; start < src * src; start++) {
        if (comp[start] != 0 || crop32[start] >= thr) continue;
        final id = compSizes.length;
        compSizes.add(0);
        stack.add(start);
        comp[start] = id;
        while (stack.isNotEmpty) {
          final p = stack.removeLast();
          compSizes[id]++;
          final px = p % src, py = p ~/ src;
          if (px > 0 && comp[p - 1] == 0 && crop32[p - 1] < thr) {
            comp[p - 1] = id;
            stack.add(p - 1);
          }
          if (px < src - 1 && comp[p + 1] == 0 && crop32[p + 1] < thr) {
            comp[p + 1] = id;
            stack.add(p + 1);
          }
          if (py > 0 && comp[p - src] == 0 && crop32[p - src] < thr) {
            comp[p - src] = id;
            stack.add(p - src);
          }
          if (py < src - 1 && comp[p + src] == 0 && crop32[p + src] < thr) {
            comp[p + src] = id;
            stack.add(p + src);
          }
        }
      }
      int largest = 0;
      for (int i = 1; i < compSizes.length; i++) {
        if (compSizes[i] > largest) largest = compSizes[i];
      }
      final minSize = largest * 0.25;
      for (int p = 0; p < src * src; p++) {
        final id = comp[p];
        if (id == 0 || compSizes[id] < minSize) continue;
        final x = p % src, y = p ~/ src;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
    if (x1 < x0 || y1 < y0) {
      x0 = 0;
      y0 = 0;
      x1 = src - 1;
      y1 = src - 1;
    }
    final iw = x1 - x0 + 1;
    final ih = y1 - y0 + 1;

    // 2. Bilinear resample of the ink box to 16×16.
    final out = Float32List(dim);
    double mean = 0;
    for (int gy = 0; gy < gridSize; gy++) {
      final fy = y0 + (gy + 0.5) * ih / gridSize - 0.5;
      final ya = fy.floor();
      final ty = fy - ya;
      final y0c = ya.clamp(0, src - 1);
      final y1c = (ya + 1).clamp(0, src - 1);
      for (int gx = 0; gx < gridSize; gx++) {
        final fx = x0 + (gx + 0.5) * iw / gridSize - 0.5;
        final xa = fx.floor();
        final tx = fx - xa;
        final x0c = xa.clamp(0, src - 1);
        final x1c = (xa + 1).clamp(0, src - 1);
        final v = (crop32[y0c * src + x0c] * (1 - tx) +
                crop32[y0c * src + x1c] * tx) *
                (1 - ty) +
            (crop32[y1c * src + x0c] * (1 - tx) +
                    crop32[y1c * src + x1c] * tx) *
                ty;
        out[gy * gridSize + gx] = v;
        mean += v;
      }
    }
    mean /= dim;
    double norm = 0;
    for (int i = 0; i < dim; i++) {
      out[i] -= mean;
      norm += out[i] * out[i];
    }
    norm = math.sqrt(norm);
    if (norm > 1e-6) {
      for (int i = 0; i < dim; i++) {
        out[i] /= norm;
      }
    }
    return (features: out, aspect: cropAspect * iw / ih);
  }

  /// Assigns [features] (from [featuresFromCrop32]) to the nearest cluster,
  /// creating a new one when nothing is similar enough. [aspectRatio] is the
  /// crop's original width/height — clusters only accept glyphs of similar
  /// proportions, so a narrow "l" can never join a square piece cluster even
  /// if their pooled pixels happen to correlate.
  int assign(Float32List features, double aspectRatio) {
    int best = -1;
    double bestSim = -2;
    for (int c = 0; c < _centroids.length; c++) {
      final ar = _aspects[c];
      final ratio = aspectRatio > ar ? aspectRatio / ar : ar / aspectRatio;
      if (ratio > 1.35) continue;
      final centroid = _centroids[c];
      double sim = 0;
      for (int i = 0; i < dim; i++) {
        sim += centroid[i] * features[i];
      }
      if (sim >= bestSim) {
        bestSim = sim;
        best = c;
      }
    }

    // Diagnostic: distribution of best-similarities tells whether the
    // threshold is the binding constraint (mass just below it) or the
    // features themselves don't discriminate (mass far below).
    _assignCount++;
    _simHistogram[_simBucket(bestSim)]++;

    if (best < 0 || bestSim < similarityThreshold) {
      _centroids.add(Float32List.fromList(features));
      _counts.add(1);
      _aspects.add(aspectRatio);
      return _centroids.length - 1;
    }

    // Running-mean centroid update, re-normalised so cosine stays valid.
    final n = _counts[best];
    final centroid = _centroids[best];
    double norm = 0;
    for (int i = 0; i < dim; i++) {
      centroid[i] = (centroid[i] * n + features[i]) / (n + 1);
      norm += centroid[i] * centroid[i];
    }
    norm = math.sqrt(norm);
    if (norm > 1e-6) {
      for (int i = 0; i < dim; i++) {
        centroid[i] /= norm;
      }
    }
    _aspects[best] = (_aspects[best] * n + aspectRatio) / (n + 1);
    _counts[best] = n + 1;
    return best;
  }

  /// Records a legality vote: the glyph of cluster [clusterId] acted as
  /// piece [piece] in a legality-unique move of an anchored segment.
  /// [source] identifies the vote's origin (e.g. "page:tokenIndex") so that
  /// re-parsing the same page replaces its votes instead of stacking them.
  void vote({
    required String source,
    required int clusterId,
    required String piece,
  }) {
    _votes[source] = (clusterId, piece);
    _tallyCache = null;
  }

  Map<int, Map<String, int>> get _tally {
    final cached = _tallyCache;
    if (cached != null) return cached;
    final tally = <int, Map<String, int>>{};
    for (final (clusterId, piece) in _votes.values) {
      final byPiece = tally.putIfAbsent(clusterId, () => {});
      byPiece[piece] = (byPiece[piece] ?? 0) + 1;
    }
    return _tallyCache = tally;
  }

  /// The piece letter this cluster is confidently labeled with, or null.
  String? labelFor(int clusterId) {
    final byPiece = _tally[clusterId];
    if (byPiece == null) return null;
    var total = 0;
    String? topPiece;
    var topCount = 0;
    for (final e in byPiece.entries) {
      total += e.value;
      if (e.value > topCount) {
        topCount = e.value;
        topPiece = e.key;
      }
    }
    if (total < minVotes) return null;
    if (topCount / total < minDominance) return null;
    return topPiece;
  }

  /// All confidently labeled clusters (clusterId → piece letter).
  Map<int, String> get labels {
    final out = <int, String>{};
    for (final clusterId in _tally.keys) {
      final label = labelFor(clusterId);
      if (label != null) out[clusterId] = label;
    }
    return out;
  }

  /// One-line diagnostic summary for the debug log.
  String debugSummary() {
    final tally = _tally;
    final labeled = labels;
    final parts = labeled.entries
        .map((e) => 'c${e.key}→${e.value}(${tally[e.key]!.values.reduce((a, b) => a + b)}v)')
        .join(' ');

    // Top clusters by vote count, labeled or not — shows how concentrated
    // the vote pool is (fragmentation = votes spread 1–2 per cluster).
    final byVotes = tally.entries
        .map((e) => (id: e.key, total: e.value.values.reduce((a, b) => a + b), byPiece: e.value))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final top = byVotes
        .take(8)
        .map((c) =>
            'c${c.id}{${c.byPiece.entries.map((e) => '${e.key}:${e.value}').join(',')}}')
        .join(' ');

    // Similarity histogram: where assigns land relative to the threshold.
    final hist = <String>[];
    for (int i = 0; i <= simBucketEdges.length; i++) {
      final label = i == 0
          ? '<${simBucketEdges[0]}'
          : i == simBucketEdges.length
              ? '≥${simBucketEdges.last}'
              : '${simBucketEdges[i - 1]}–${simBucketEdges[i]}';
      hist.add('$label:${_simHistogram[i]}');
    }

    return '$clusterCount cluster(s), ${_votes.length} vote(s), '
        '${labeled.length} labeled${labeled.isEmpty ? '' : ': $parts'}'
        '${top.isEmpty ? '' : '  topVotes: $top'}'
        '  sim[$_assignCount assigns, thr=$similarityThreshold]: ${hist.join(' ')}';
  }
}
