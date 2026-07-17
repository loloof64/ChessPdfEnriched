import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'figurine_classifier.dart';
import 'figurine_detector.dart';
import 'glyph_clusterer.dart';
import 'hog_extractor.dart';
import 'models.dart';

/// Result of parsing a single element within a word block.
class ParsedElement {
  const ParsedElement({
    required this.text,
    required this.bounds,
    required this.type, // 'figurine' or 'text'
    required this.confidence,
    this.clusterId,
  });

  /// Parsed character(s) (e.g. 'K', 'f', '3').
  final String text;

  /// Bounding box in PDF coordinates.
  final MoveBounds bounds;

  /// 'figurine' or 'text'
  final String type;

  /// Classification confidence (0.0–1.0).
  final double confidence;

  /// Book-level shape-cluster id assigned by [GlyphClusterer], or null when
  /// clustering was not run for this element.
  final int? clusterId;
}

/// Parses elements within a word block using element-by-element classification.
///
/// For each detected element (glyph) within a word block:
/// 1. Classify with the 6-class figurine classifier {K,Q,R,B,N,NotAFigurine}.
/// 2. Piece class → record the piece letter.
/// 3. NotAFigurine (reject) class → treat as text; identity comes from the
///    PDF text layer during move assembly, not OCR here.
/// 4. Build a move string from the parsed elements.
class ElementParser {
  ElementParser({required this.figurineClassifier});

  final FigurineClassifier figurineClassifier;

  /// Parse all elements within a word block using gap detection for segmentation.
  ///
  /// Pipeline:
  /// 1. Segment word block into individual elements by detecting vertical gaps
  /// 2. For each element:
  ///    a. Extract HOG features
  ///    b. Run the 6-class figurine classifier
  ///    c. Piece class → record the piece letter
  ///    d. NotAFigurine (reject) class → mark as text
  /// 3. Return parsed elements sorted left-to-right
  Future<List<ParsedElement>> parseWordBlock(
    RenderedPage rendered,
    MoveBounds blockBounds,
    double pageHeight,
    double renderScale, {
    /// Pre-computed CCL blob bounds from FigurineDetector.analyseWordBlock.
    /// When provided these are used directly, skipping column-projection
    /// segmentation (which fails for complex/inverted glyphs).
    List<MoveBounds>? blobBounds,
    /// When set, every 32×32 crop actually classified here is dumped as a
    /// .pgm file — lets us visually verify whether the elements this
    /// function receives (e.g. PDF-char-rect-derived bounds) are cleanly
    /// separated, independently from FigurineDetector's own debug crops.
    String? debugCropDir,
    /// When set, diagnostic lines are appended straight to this file instead
    /// of going through debugPrint — terminal/logcat output gets truncated
    /// or drops lines under heavy volume, a file never does.
    String? debugLogFile,
    /// Book-level glyph clusterer: when set, every element crop is assigned
    /// a shape-cluster id (see [GlyphClusterer]) carried in
    /// [ParsedElement.clusterId].
    GlyphClusterer? clusterer,
  }) async {
    // Step 1: Prefer CCL blob bounds; fall back to column-projection.
    List<MoveBounds> elementBounds;
    if (blobBounds != null && blobBounds.isNotEmpty) {
      elementBounds = blobBounds;
      _log(
        debugLogFile,
        '[ElementParser] block at left=${blockBounds.left.toStringAsFixed(1)} '
        '→ ${elementBounds.length} element(s) from blob bounds',
      );
    } else {
      elementBounds = _segmentElementsByGaps(
        rendered.binary,
        rendered.width,
        rendered.height,
        blockBounds,
        pageHeight,
        renderScale,
      );
      _log(
        debugLogFile,
        '[ElementParser] block at left=${blockBounds.left.toStringAsFixed(1)} '
        '→ ${elementBounds.length} element(s) from gap projection',
      );
    }

    if (elementBounds.isEmpty) return [];

    // Step 2: For each element, classify as figurine or text
    final parsed = <ParsedElement>[];
    for (int i = 0; i < elementBounds.length; i++) {
      final elemBounds = elementBounds[i];

      // Extract HOG features from element bounds
      final crop = _cropAndResizeBlob(
        rendered.gray,
        rendered.width,
        rendered.height,
        elemBounds,
        pageHeight,
        renderScale,
      );
      final pixels = crop.pixels;
      final features = HogExtractor.extract(pixels, crop.pw, crop.ph);

      // Single 6-class classifier {K,Q,R,B,N,NotAFigurine}: classifyWithConfidence
      // returns (piece, confidence) when the argmax is a piece, or null when it
      // is the NotAFigurine reject class. The reject class makes a separate
      // text/figurine gate (the old NotAFigurine autoencoder + confidence-margin
      // heuristic) unnecessary — a non-piece is simply where the model's own
      // argmax lands on NotAFigurine.
      final figResult = figurineClassifier.classifyWithConfidence(features);

      int? clusterId;
      if (clusterer != null) {
        // Clustering uses its own bilinear supersampled crop: the classifier
        // crop above is nearest-neighbour sampled, and at ~30 px glyph height
        // a sub-pixel shift of the source box re-jitters the whole 32×32 grid
        // — enough to push identical glyphs below the similarity threshold.
        final smooth = _cropBilinear32(
          rendered.gray,
          rendered.width,
          rendered.height,
          elemBounds,
          pageHeight,
          renderScale,
        );
        final cropAspect = crop.ph > 0 ? crop.pw / crop.ph : 1.0;
        final f = GlyphClusterer.featuresFromCrop32(smooth, cropAspect);
        clusterId = clusterer.assign(f.features, f.aspect);
      }

      if (debugCropDir != null) {
        final label = figResult != null
            ? '${figResult.$1}_${(figResult.$2 * 100).round()}pct'
            : 'notafig';
        _dumpCropPgm(debugCropDir, pixels, 'elem${i}_$label.pgm');
      }

      _log(
        debugLogFile,
        '[ElementParser]   elem[$i] @ ${elemBounds.left.toStringAsFixed(1)}: '
        'fig=${figResult != null ? "${figResult.$2.toStringAsFixed(2)} (${figResult.$1})" : "NotAFigurine"}',
      );

      if (figResult != null) {
        // Argmax is a piece class.
        final (piece, conf) = figResult;
        parsed.add(
          ParsedElement(
            text: piece,
            bounds: elemBounds,
            type: 'figurine',
            confidence: conf,
            clusterId: clusterId,
          ),
        );
        _log(
          debugLogFile,
          '[ElementParser]     → FIGURINE: $piece (${conf.toStringAsFixed(2)})',
        );
      } else {
        // Reject class → text. Identity resolved from the PDF text layer at
        // move-assembly time; a placeholder marks the element for the overlay.
        parsed.add(
          ParsedElement(
            text: '·',
            bounds: elemBounds,
            type: 'text',
            confidence: 0.0,
            clusterId: clusterId,
          ),
        );
        _log(debugLogFile, '[ElementParser]     → TEXT (NotAFigurine)');
      }
    }

    _log(
      debugLogFile,
      '[ElementParser] block → ${parsed.length}/${elementBounds.length} element(s) classified',
    );

    return parsed;
  }

  /// Appends [message] to [logFile] if set, otherwise falls back to
  /// [debugPrint]. Terminal/logcat output gets truncated or drops lines
  /// under heavy volume — writing straight to a file never does.
  // Per-file line buffers, flushed asynchronously in a batch rather than
  // opening/appending/closing the log file on every single call. Debug
  // logging happens hundreds/thousands of times per page (once per glyph),
  // and doing that with *synchronous* file I/O blocks the UI isolate's
  // event loop with no frames in between — which is what made the app look
  // "hung" rather than just slow, especially once the target directory had
  // to be recreated (e.g. after the user deleted it mid-run).
  static final Map<String, StringBuffer> _logBuffers = {};
  static final Set<String> _logFlushPending = {};

  static void _log(String? logFile, String message) {
    if (logFile == null) {
      debugPrint(message);
      return;
    }
    _logBuffers.putIfAbsent(logFile, () => StringBuffer()).writeln(message);
    if (_logFlushPending.add(logFile)) {
      unawaited(_flushLog(logFile));
    }
  }

  static Future<void> _flushLog(String logFile) async {
    // Yield first so same-tick _log() calls accumulate into one write.
    await Future<void>.delayed(Duration.zero);
    _logFlushPending.remove(logFile);
    final buffer = _logBuffers.remove(logFile);
    if (buffer == null || buffer.isEmpty) return;
    try {
      final file = File(logFile);
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString(), mode: FileMode.append);
    } catch (e) {
      debugPrint('[ElementParser] failed to write log: $e');
    }
  }

  /// Writes a 32×32 grayscale [pixels] buffer (values 0.0–1.0) as a binary
  /// PGM (P5) file — viewable with most image tools (e.g. GIMP, `convert
  /// crop.pgm crop.png`) without extra dependencies.
  //
  // Fire-and-forget async I/O for the same reason as `_log` above: dumps
  // happen once per glyph in a tight synchronous loop, so blocking sync
  // file calls here stall the UI isolate. Directories we've already
  // confirmed exist are cached so repeated dumps into the same block don't
  // each re-run a recursive mkdir; a failed write evicts the cache entry so
  // the next dump retries directory creation instead of failing forever.
  static final Set<String> _knownDirs = {};

  static void _dumpCropPgm(String dir, Float32List pixels, String filename) {
    const size = HogExtractor.imageSize; // 32
    unawaited(_writeCropPgm(dir, pixels, filename, size));
  }

  static Future<void> _writeCropPgm(
    String dir,
    Float32List pixels,
    String filename,
    int size,
  ) async {
    try {
      if (!_knownDirs.contains(dir)) {
        await Directory(dir).create(recursive: true);
        _knownDirs.add(dir);
      }
      final bytes = Uint8List(size * size);
      for (int i = 0; i < pixels.length; i++) {
        bytes[i] = (pixels[i].clamp(0.0, 1.0) * 255).round();
      }
      final header = 'P5\n$size $size\n255\n';
      final file = File('$dir/$filename');
      await file.writeAsBytes([...header.codeUnits, ...bytes]);
    } catch (e) {
      // The dir may have been deleted after we last confirmed it (e.g. the
      // user cleared the debug folder mid-run) — drop it from the cache so
      // the next dump into this path recreates it instead of failing forever.
      _knownDirs.remove(dir);
      debugPrint('[ElementParser] failed to dump crop $filename: $e');
    }
  }

  /// Segment a word block into individual elements by detecting gaps in the rendered pixels.
  /// Returns a list of bounding boxes for each detected element, sorted left-to-right.
  ///
  /// Uses the binary image (1=ink, 0=background) so the threshold is exact.
  /// gapThreshold=0.75: a column needs >75% background pixels to be a gap.
  /// This accounts for ascender/descender whitespace: even the densest ink column
  /// only fills ~50% of the block height, so we need the bar high enough to
  /// distinguish ink columns (~50% bg) from true gaps (~100% bg).
  static List<MoveBounds> _segmentElementsByGaps(
    Uint8List binary,
    int imgW,
    int imgH,
    MoveBounds blockBounds,
    double pageHeight,
    double scale, {
    double gapThreshold = 0.75, // Columns with >75% background pixels are gaps
    double minElementWidthPt = 2.0, // Minimum element width
  }) {
    // Convert word block from PDF coords to pixel coords
    final px0 = (blockBounds.left * scale).round().clamp(0, imgW - 1);
    final px1 = (blockBounds.right * scale).round().clamp(px0 + 1, imgW);
    final py0 = ((pageHeight - blockBounds.top) * scale).round().clamp(
      0,
      imgH - 1,
    );
    final py1 = ((pageHeight - blockBounds.bottom) * scale).round().clamp(
      py0 + 1,
      imgH,
    );

    final colWidth = px1 - px0;
    final colHeight = py1 - py0;
    if (colWidth <= 0 || colHeight <= 0) return [];

    // Compute column-wise background-pixel fraction.
    // binary[idx]==0 means background (white), binary[idx]==1 means ink (dark).
    final colGapFraction = List<double>.filled(colWidth, 0.0);
    for (int x = px0; x < px1; x++) {
      int bgCount = 0;
      for (int y = py0; y < py1; y++) {
        final idx = y * imgW + x;
        if (idx < binary.length && binary[idx] == 0) {
          bgCount++;
        }
      }
      colGapFraction[x - px0] = bgCount / colHeight;
    }

    debugPrint(
      '[SegmentElements] bg fraction: min=${colGapFraction.reduce((a, b) => a < b ? a : b).toStringAsFixed(3)}, '
      'max=${colGapFraction.reduce((a, b) => a > b ? a : b).toStringAsFixed(3)}, '
      'gapThreshold=$gapThreshold',
    );

    // Identify gap columns (mostly white)
    final isGap = List<bool>.filled(colWidth, false);
    for (int i = 0; i < colGapFraction.length; i++) {
      if (colGapFraction[i] > gapThreshold) {
        isGap[i] = true;
      }
    }

    // Find contiguous segments of non-gap columns (individual elements)
    final elements = <MoveBounds>[];
    int? segStart;
    for (int i = 0; i <= isGap.length; i++) {
      final isCurrentGap = (i < isGap.length) ? isGap[i] : true;

      if (!isCurrentGap) {
        segStart ??= i;
      } else {
        if (segStart != null) {
          // Found a gap after a segment
          final segEnd = i;
          final elemWidth = (segEnd - segStart) / scale;

          if (elemWidth >= minElementWidthPt) {
            elements.add(
              MoveBounds(
                left: (px0 + segStart) / scale,
                right: (px0 + segEnd) / scale,
                top: blockBounds.top,
                bottom: blockBounds.bottom,
              ),
            );
          }
          segStart = null;
        }
      }
    }

    debugPrint(
      '[SegmentElements] block → ${elements.length} element(s) from gaps',
    );
    return elements;
  }

  /// Build a move string from parsed elements, using PDF text layer for text elements.
  ///
  /// For elements marked as 'text', look up the actual character from [pdfCharRects]
  /// (the PDF's text layer) by finding the overlapping character bounding box.
  static String buildMoveString(
    List<ParsedElement> elements,
    List<({MoveBounds bounds, String char})> pdfCharRects,
  ) {
    final result = StringBuffer();

    for (final elem in elements) {
      if (elem.type == 'figurine') {
        result.write(elem.text);
      } else if (elem.type == 'text') {
        // Find the PDF character that overlaps this element
        final matching = pdfCharRects.where(
          (ch) => boundsOverlap(elem.bounds, ch.bounds),
        );
        if (matching.isNotEmpty) {
          result.write(matching.first.char);
        }
      }
    }

    return result.toString();
  }

  static bool boundsOverlap(MoveBounds a, MoveBounds b) {
    return a.left < b.right &&
        a.right > b.left &&
        a.bottom < b.top &&
        a.top > b.bottom;
  }

  /// Crop and resize a blob to 32×32 for HOG extraction. Also returns the
  /// true pre-resize crop width/height in pixels — needed as-is (not 32×32)
  /// for the aspect-ratio feature HogExtractor appends after the HOG vector.
  static ({Float32List pixels, int pw, int ph}) _cropAndResizeBlob(
    Float32List gray,
    int imgW,
    int imgH,
    MoveBounds bounds,
    double pageHeight,
    double scale,
  ) {
    // Convert PDF bounds to pixel coordinates
    final px0 = (bounds.left * scale).round().clamp(0, imgW);
    final py0 = ((pageHeight - bounds.top) * scale).round().clamp(0, imgH);
    final pw = ((bounds.right - bounds.left) * scale).round().clamp(
      1,
      imgW - px0,
    );
    final ph = ((bounds.top - bounds.bottom) * scale).round().clamp(
      1,
      imgH - py0,
    );

    const size = 32;
    final out = Float32List(size * size);
    for (int dy = 0; dy < size; dy++) {
      for (int dx = 0; dx < size; dx++) {
        final sx = (px0 + (dx * pw) ~/ size).clamp(0, imgW - 1);
        final sy = (py0 + (dy * ph) ~/ size).clamp(0, imgH - 1);
        out[dy * size + dx] = gray[sy * imgW + sx];
      }
    }
    return (pixels: out, pw: pw, ph: ph);
  }

  /// Smooth 32×32 crop of [bounds] for glyph clustering: each output pixel
  /// averages a 2×2 grid of bilinear samples, so sub-pixel shifts of the
  /// source box produce nearly identical crops (the nearest-neighbour crop
  /// of [_cropAndResizeBlob] re-jitters the whole grid on a 1-px shift —
  /// kept as-is because the TFLite classifier was calibrated on it).
  static Float32List _cropBilinear32(
    Float32List gray,
    int imgW,
    int imgH,
    MoveBounds bounds,
    double pageHeight,
    double scale,
  ) {
    final fx0 = bounds.left * scale;
    final fy0 = (pageHeight - bounds.top) * scale;
    final fw = (bounds.right - bounds.left) * scale;
    final fh = (bounds.top - bounds.bottom) * scale;

    double sample(double sx, double sy) {
      final xa = sx.floor();
      final ya = sy.floor();
      final tx = sx - xa;
      final ty = sy - ya;
      final x0 = xa.clamp(0, imgW - 1);
      final x1 = (xa + 1).clamp(0, imgW - 1);
      final y0 = ya.clamp(0, imgH - 1);
      final y1 = (ya + 1).clamp(0, imgH - 1);
      return (gray[y0 * imgW + x0] * (1 - tx) + gray[y0 * imgW + x1] * tx) *
              (1 - ty) +
          (gray[y1 * imgW + x0] * (1 - tx) + gray[y1 * imgW + x1] * tx) * ty;
    }

    const size = 32;
    final out = Float32List(size * size);
    for (int dy = 0; dy < size; dy++) {
      for (int dx = 0; dx < size; dx++) {
        double acc = 0;
        for (int sub = 0; sub < 4; sub++) {
          final ox = (sub & 1) == 0 ? 0.25 : 0.75;
          final oy = (sub & 2) == 0 ? 0.25 : 0.75;
          acc += sample(
            fx0 + (dx + ox) * fw / size - 0.5,
            fy0 + (dy + oy) * fh / size - 0.5,
          );
        }
        out[dy * size + dx] = acc / 4;
      }
    }
    return out;
  }
}
