import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';
import 'hog_extractor.dart';
import 'models.dart';

/// Detects and classifies figurine chess-piece glyphs from a rendered PDF page.
///
/// Approach: purely visual — no PDF text-extraction dependency.
///   1. Render page to grayscale.
///   2. Binarize (dark-ink threshold).
///   3. Dilate horizontally → connected-component analysis gives word-level blobs.
///   4. Within each word blob, connected-component analysis on the original
///      binary image gives character-level blobs.
///   5. Filter by size / aspect ratio; skip blobs inside detected board rects.
///   6. Resize each blob to 32×32, extract HOG features, run TFLite classifier.
///      The NotAFigurine class rejects non-piece characters naturally.
class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API

  /// Detect figurine glyphs on [page].
  ///
  /// [boardRects] — PDF-coordinate rectangles of detected chess board diagrams;
  /// blobs whose centre falls inside one are skipped.
  ///
  /// [minGlyphSizePt] (default 8 pt): minimum width AND height of a candidate
  /// blob in PDF points.
  ///
  /// [maxAspectRatio] (default 2.0): maximum width/height (or height/width)
  /// ratio accepted.
  ///
  /// [binarizeThreshold] (default 0.85): grayscale value below which a pixel
  /// is considered ink (0 = black, 1 = white).
  ///
  /// [wordDilateKernelPx] (default 12 px at renderScale): horizontal dilation
  /// kernel used to group characters into word blobs before letter segmentation.
  Future<List<DetectedFigurine>> detectFigurines(
    PdfPage page, {
    List<PdfRect> boardRects = const [],
    double renderScale = 2.0,
    double minConfidence = 0.60,
    double minGlyphSizePt = 8.0,
    double maxAspectRatio = 2.0,
    double binarizeThreshold = 0.85,
    bool verbose = false,
    String? debugLogPath,
    int? debugPageNumber,
    void Function(List<MoveBounds>)? onWordBoxes,
  }) async {
    // --- 1. Render page ---
    final iW = (page.width  * renderScale).round();
    final iH = (page.height * renderScale).round();
    final image = await page.render(
      x: 0, y: 0, width: iW, height: iH,
      fullWidth: iW.toDouble(), fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) return [];

    final results = <DetectedFigurine>[];
    try {
      final gray   = _toGray(image.pixels, iW, iH);
      final binary = _binarize(gray, iW, iH, binarizeThreshold);

      // --- 2. Single-pass CCL: find all ink blobs directly ---
      final allBlobs = _connectedBoxes(binary, iW, iH);

      // Board exclusion zones in pixel coordinates.
      final boardPx = boardRects.map((b) => (
        x0: (b.left                         * renderScale).round(),
        y0: ((page.height - b.top)          * renderScale).round(),
        x1: (b.right                        * renderScale).round(),
        y1: ((page.height - b.bottom)       * renderScale).round(),
      )).toList();

      final minSizePx = (minGlyphSizePt * renderScale).round();
      int filteredSize = 0, filteredAspect = 0, filteredBoard = 0, classified = 0;

      // Candidate blobs (passed size + aspect + board filters) for debug overlay.
      final candidateBoxes = <({int x0, int y0, int x1, int y1})>[];

      final log = debugLogPath != null ? StringBuffer() : null;
      if (log != null) {
        log.writeln('=== Page ${debugPageNumber ?? '?'} '
            '| ${allBlobs.length} ink blob(s) '
            '| page ${page.width.toStringAsFixed(1)}×${page.height.toStringAsFixed(1)}pt '
            '| renderScale=$renderScale ===');
      }

      // Merge horizontally close blobs that are vertically overlapping (fragments
      // of the same glyph — e.g. counters, dots, serifs separated by CCL).
      final mergeGapPx = (minGlyphSizePt * renderScale * 0.4).round().clamp(2, 8);
      final merged = _mergeNearbyBlobs(allBlobs, mergeGapPx);

      // Expand wide blobs by vertical splitting so each character is processed.
      final candidates = <({int x0, int y0, int x1, int y1})>[];
      for (final cb in merged) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;
        if (cw > ch * maxAspectRatio) {
          candidates.addAll(_splitBlobVertically(binary, iW, cb, maxAspectRatio));
        } else {
          candidates.add(cb);
        }
      }

      for (final cb in candidates) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;
        final cLeftPt = cb.x0 / renderScale;
        final cTopPt  = page.height - cb.y0 / renderScale;

        // Size gate
        if (cw < minSizePx || ch < minSizePx) {
          filteredSize++;
          log?.writeln('  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
              'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → too_small');
          continue;
        }

        // Aspect ratio gate
        final ar = cw / ch;
        if (ar < 1.0 / maxAspectRatio || ar > maxAspectRatio) {
          filteredAspect++;
          log?.writeln('  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
              'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → bad_aspect(${ar.toStringAsFixed(2)})');
          continue;
        }

        // Board exclusion
        final cx = (cb.x0 + cb.x1) / 2.0;
        final cy = (cb.y0 + cb.y1) / 2.0;
        if (boardPx.any((b) =>
            cx >= b.x0 && cx <= b.x1 && cy >= b.y0 && cy <= b.y1)) {
          filteredBoard++;
          log?.writeln('  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
              'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → in_board');
          continue;
        }

        candidateBoxes.add(cb);

        // --- 3. Classify ---
        final pixels   = _cropAndResize32(gray, iW, iH, cb.x0, cb.y0, cw, ch);
        final features = HogExtractor.extract(pixels, cw, ch);
        final hit      = classifier.classifyWithConfidence(features);
        if (hit == null) {
          log?.writeln('  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
              'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → NotAFigurine');
          continue;
        }

        final (piece, confidence) = hit;
        final passes = confidence >= minConfidence;
        final pct = (confidence * 100).toStringAsFixed(0);

        log?.writeln('  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
            'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] '
            '→ $piece $pct%${passes ? ' PASS' : ' skip'}');

        if (verbose) {
          debugPrint(
            '[FigurineDetector] blob $cw×${ch}px'
            ' → $piece $pct%'
            '${passes ? '' : ' (skip)'}',
          );
        }

        if (!passes) continue;

        // Convert pixel bbox → PDF coordinates (Y-axis flip: PDF y=0 at bottom)
        results.add(DetectedFigurine(
          bounds: MoveBounds(
            left:   cb.x0        / renderScale,
            top:    page.height - cb.y0        / renderScale,
            right:  (cb.x1 + 1) / renderScale,
            bottom: page.height - (cb.y1 + 1) / renderScale,
          ),
          piece:      piece,
          confidence: confidence,
        ));
        classified++;
      }

      if (onWordBoxes != null) {
        onWordBoxes(candidateBoxes.map((b) => MoveBounds(
          left:   b.x0        / renderScale,
          top:    page.height - b.y0        / renderScale,
          right:  (b.x1 + 1) / renderScale,
          bottom: page.height - (b.y1 + 1) / renderScale,
        )).toList());
      }

      if (log != null) {
        File(debugLogPath!).writeAsStringSync(log.toString(), mode: FileMode.append);
      }

      debugPrint(
        '[FigurineDetector] ${allBlobs.length} ink blob(s) → '
        '$filteredSize too small, $filteredAspect bad aspect, '
        '$filteredBoard in board → $classified figurine(s) at '
        'conf≥${minConfidence.toStringAsFixed(2)}',
      );
    } finally {
      image.dispose();
    }

    // Deduplicate: when two detections overlap, keep the higher-confidence one.
    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    final deduped = <DetectedFigurine>[];
    for (final fig in results) {
      if (!deduped.any((k) => _boundsOverlap(k.bounds, fig.bounds))) {
        deduped.add(fig);
      }
    }
    if (deduped.length < results.length) {
      debugPrint(
        '[FigurineDetector] dedup: ${results.length} → ${deduped.length}',
      );
    }
    return deduped;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Image-processing utilities

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4    ] / 255.0;
    }
    return g;
  }

  /// Returns a binary image: 1 = ink (dark), 0 = background (light).
  static Uint8List _binarize(Float32List gray, int w, int h, double threshold) {
    final out = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      out[i] = gray[i] < threshold ? 1 : 0;
    }
    return out;
  }

  /// Two-pass connected-component labeling (union-find with path compression).
  /// Returns bounding boxes of all foreground (ink) components.
  ///
  /// Operates on the sub-region [clipX0, clipX1) × [clipY0, clipY1).
  static List<({int x0, int y0, int x1, int y1})> _connectedBoxes(
    Uint8List binary,
    int w,
    int h, {
    int clipX0 = 0,
    int clipY0 = 0,
    int? clipX1,
    int? clipY1,
  }) {
    final ex = clipX1 ?? w;
    final ey = clipY1 ?? h;
    final rw = ex - clipX0;
    final rh = ey - clipY0;
    if (rw <= 0 || rh <= 0) return [];

    final labels = Int32List(rw * rh); // 0 = background/unlabelled
    final parent = <int>[0];           // index 0 is a sentinel (no-label)

    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]]; // path compression (halving)
        x = parent[x];
      }
      return x;
    }

    void unite(int a, int b) {
      a = find(a);
      b = find(b);
      if (a != b) parent[b] = a;
    }

    // First pass — assign provisional labels
    for (int ry = 0; ry < rh; ry++) {
      for (int rx = 0; rx < rw; rx++) {
        if (binary[(clipY0 + ry) * w + (clipX0 + rx)] == 0) continue;

        final above = ry > 0 ? labels[(ry - 1) * rw + rx] : 0;
        final left  = rx > 0 ? labels[ry * rw + rx - 1]  : 0;

        if (above == 0 && left == 0) {
          labels[ry * rw + rx] = parent.length;
          parent.add(parent.length); // new singleton label
        } else if (above != 0 && left == 0) {
          labels[ry * rw + rx] = above;
        } else if (above == 0) {
          labels[ry * rw + rx] = left;
        } else {
          labels[ry * rw + rx] = left;
          unite(above, left);
        }
      }
    }

    // Second pass — compute bounding boxes per canonical label
    final bx0 = <int, int>{};
    final by0 = <int, int>{};
    final bx1 = <int, int>{};
    final by1 = <int, int>{};

    for (int ry = 0; ry < rh; ry++) {
      for (int rx = 0; rx < rw; rx++) {
        int lbl = labels[ry * rw + rx];
        if (lbl == 0) continue;
        lbl = find(lbl);
        final gx = clipX0 + rx;
        final gy = clipY0 + ry;
        if (!bx0.containsKey(lbl)) {
          bx0[lbl] = gx; by0[lbl] = gy;
          bx1[lbl] = gx; by1[lbl] = gy;
        } else {
          if (gx < bx0[lbl]!) bx0[lbl] = gx;
          if (gy < by0[lbl]!) by0[lbl] = gy;
          if (gx > bx1[lbl]!) bx1[lbl] = gx;
          if (gy > by1[lbl]!) by1[lbl] = gy;
        }
      }
    }

    return bx0.keys
        .map((k) => (x0: bx0[k]!, y0: by0[k]!, x1: bx1[k]!, y1: by1[k]!))
        .toList();
  }

  /// Merge blobs that are close enough horizontally and overlap vertically —
  /// they are likely fragments of the same glyph (counters, dots, serifs).
  /// [maxGapPx] is the maximum horizontal gap in pixels to trigger a merge.
  static List<({int x0, int y0, int x1, int y1})> _mergeNearbyBlobs(
    List<({int x0, int y0, int x1, int y1})> blobs,
    int maxGapPx,
  ) {
    if (blobs.isEmpty) return blobs;

    // Sort by left edge so we only need a single forward pass.
    final sorted = blobs.toList()
      ..sort((a, b) => a.x0.compareTo(b.x0));

    final out = <({int x0, int y0, int x1, int y1})>[];
    var cur = sorted[0];

    for (int i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      final hGap = next.x0 - cur.x1 - 1;           // pixels between right of cur and left of next
      final vOverlap = cur.y1 >= next.y0 && next.y1 >= cur.y0; // vertical bands overlap
      if (hGap <= maxGapPx && vOverlap) {
        // Absorb next into cur.
        cur = (
          x0: cur.x0,
          y0: cur.y0 < next.y0 ? cur.y0 : next.y0,
          x1: cur.x1 > next.x1 ? cur.x1 : next.x1,
          y1: cur.y1 > next.y1 ? cur.y1 : next.y1,
        );
      } else {
        out.add(cur);
        cur = next;
      }
    }
    out.add(cur);
    return out;
  }

  /// Split a wide blob at vertical ink-density valleys so each piece has an
  /// acceptable aspect ratio. Recurses until narrow enough or unsplittable.
  static List<({int x0, int y0, int x1, int y1})> _splitBlobVertically(
    Uint8List binary,
    int iW,
    ({int x0, int y0, int x1, int y1}) blob,
    double maxAspectRatio,
  ) {
    final bw = blob.x1 - blob.x0 + 1;
    final bh = blob.y1 - blob.y0 + 1;
    if (bw <= bh * maxAspectRatio || bw < 4) return [blob];

    // Column-wise ink density within the blob.
    final proj = List<int>.filled(bw, 0);
    for (int ry = 0; ry < bh; ry++) {
      for (int rx = 0; rx < bw; rx++) {
        proj[rx] += binary[(blob.y0 + ry) * iW + (blob.x0 + rx)];
      }
    }

    // Find the column with minimum ink (best split point), excluding edges.
    int minVal = proj[1];
    int minRx = 1;
    for (int rx = 1; rx < bw - 1; rx++) {
      if (proj[rx] < minVal) {
        minVal = proj[rx];
        minRx = rx;
      }
    }

    // Refuse to split if the minimum is more than 30% of the peak — characters
    // that genuinely overlap cannot be separated this way.
    final peak = proj.reduce((a, b) => a > b ? a : b);
    if (minVal > peak * 0.3) return [blob];

    final left  = (x0: blob.x0,          y0: blob.y0, x1: blob.x0 + minRx - 1, y1: blob.y1);
    final right = (x0: blob.x0 + minRx + 1, y0: blob.y0, x1: blob.x1, y1: blob.y1);

    return [
      ..._splitBlobVertically(binary, iW, left,  maxAspectRatio),
      ..._splitBlobVertically(binary, iW, right, maxAspectRatio),
    ];
  }

  static bool _boundsOverlap(MoveBounds a, MoveBounds b) {
    return a.left < b.right && a.right > b.left &&
           a.bottom < b.top  && a.top   > b.bottom;
  }

  static Float32List _cropAndResize32(
    Float32List gray,
    int imgW,
    int imgH,
    int px,
    int py,
    int pw,
    int ph,
  ) {
    const size = HogExtractor.imageSize; // 32
    final out = Float32List(size * size);
    for (int dy = 0; dy < size; dy++) {
      for (int dx = 0; dx < size; dx++) {
        final sx = (px + (dx * pw) ~/ size).clamp(0, imgW - 1);
        final sy = (py + (dy * ph) ~/ size).clamp(0, imgH - 1);
        out[dy * size + dx] = gray[sy * imgW + sx];
      }
    }
    return out;
  }
}
