import 'dart:io';

import 'package:flutter/foundation.dart';

import 'figurine_classifier.dart';
import 'figurine_detector.dart';
import 'hog_extractor.dart';
import 'models.dart';
import 'notafigurine_classifier.dart';

/// Result of parsing a single element within a word block.
class ParsedElement {
  const ParsedElement({
    required this.text,
    required this.bounds,
    required this.type, // 'figurine' or 'text'
    required this.confidence,
  });

  /// Parsed character(s) (e.g. 'K', 'f', '3').
  final String text;

  /// Bounding box in PDF coordinates.
  final MoveBounds bounds;

  /// 'figurine' or 'text'
  final String type;

  /// Classification confidence (0.0–1.0).
  final double confidence;
}

/// Parses elements within a word block using element-by-element classification.
///
/// For each detected element (glyph) within a word block:
/// 1. Classify using notafigurine_classifier (is it text or figurine?)
/// 2. If figurine (high confidence): use figurine_classifier to identify piece
/// 3. If text (high confidence): return placeholder (text handling via PDF layer)
/// 4. Build a move string from the parsed elements
class ElementParser {
  ElementParser({
    required this.figurineClassifier,
    required this.notAFigurineClassifier,
  });

  final FigurineClassifier figurineClassifier;
  final NotAFigurineClassifier notAFigurineClassifier;

  /// Parse all elements within a word block using gap detection for segmentation.
  ///
  /// Pipeline:
  /// 1. Segment word block into individual elements by detecting vertical gaps
  /// 2. For each element:
  ///    a. Extract HOG features
  ///    b. Try FigurineClassifier first (figurines are prioritized)
  ///    c. If figurine found → use piece classification
  ///    d. Else, try NotAFigurineClassifier to confirm it's text
  ///    e. If text confirmed → OCR it to get character
  /// 3. Return parsed elements sorted left-to-right
  Future<List<ParsedElement>> parseWordBlock(
    RenderedPage rendered,
    MoveBounds blockBounds,
    double pageHeight,
    double renderScale, {
    double minTextConfidence = 0.50,
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
      final pixels = _cropAndResizeBlob(
        rendered.gray,
        rendered.width,
        rendered.height,
        elemBounds,
        pageHeight,
        renderScale,
      );
      final features = HogExtractor.extract(pixels, 32, 32);

      // Run both classifiers and log scores for debugging.
      final figResult = figurineClassifier.classifyWithConfidence(features);
      final textConf =
          notAFigurineClassifier.classifyAsNotFigurine(
            features,
            debugLogFile: debugLogFile,
          ) ??
          0.0;

      if (debugCropDir != null) {
        final label = figResult != null
            ? '${figResult.$1}_${(figResult.$2 * 100).round()}pct'
            : 'notafig_${(textConf * 100).round()}pct';
        _dumpCropPgm(debugCropDir, pixels, 'elem${i}_$label.pgm');
      }

      _log(
        debugLogFile,
        '[ElementParser]   elem[$i] @ ${elemBounds.left.toStringAsFixed(1)}: '
        'fig=${figResult != null ? "${figResult.$2.toStringAsFixed(2)} (${figResult.$1})" : "null"}, '
        'notAFig=${textConf.toStringAsFixed(2)}',
      );

      if (figResult != null && figResult.$2 > 0.95) {
        // Strong figurine signal — classify as figurine regardless of notAFig score.
        // (notAFig also fires for real figurines on some PDFs, so figurine wins.)
        final (piece, conf) = figResult;
        parsed.add(
          ParsedElement(
            text: piece,
            bounds: elemBounds,
            type: 'figurine',
            confidence: conf,
          ),
        );
        _log(
          debugLogFile,
          '[ElementParser]     → FIGURINE: $piece (fig=${conf.toStringAsFixed(2)}, notAFig=${textConf.toStringAsFixed(2)})',
        );
      } else if (textConf >= minTextConfidence) {
        // No strong figurine, but notAFigurine fires → treat as text.
        // Skip OCR: move assembly uses the PDF text layer, not OCR'd text.
        // Just use a placeholder for the debug overlay.
        parsed.add(
          ParsedElement(
            text: '·',
            bounds: elemBounds,
            type: 'text',
            confidence: textConf,
          ),
        );
        _log(
          debugLogFile,
          '[ElementParser]     → TEXT (fig=${figResult?.$2.toStringAsFixed(2) ?? "null"}, notAFig=${textConf.toStringAsFixed(2)})',
        );
      } else {
        _log(
          debugLogFile,
          '[ElementParser]     → SKIPPED (fig=${figResult?.$2.toStringAsFixed(2) ?? "null"}, notAFig=${textConf.toStringAsFixed(2)})',
        );
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
  static void _log(String? logFile, String message) {
    if (logFile == null) {
      debugPrint(message);
      return;
    }
    try {
      File(logFile).writeAsStringSync('$message\n', mode: FileMode.append);
    } catch (e) {
      debugPrint('[ElementParser] failed to write log: $e');
    }
  }

  /// Writes a 32×32 grayscale [pixels] buffer (values 0.0–1.0) as a binary
  /// PGM (P5) file — viewable with most image tools (e.g. GIMP, `convert
  /// crop.pgm crop.png`) without extra dependencies.
  static void _dumpCropPgm(String dir, Float32List pixels, String filename) {
    const size = HogExtractor.imageSize; // 32
    try {
      Directory(dir).createSync(recursive: true);
      final bytes = Uint8List(size * size);
      for (int i = 0; i < pixels.length; i++) {
        bytes[i] = (pixels[i].clamp(0.0, 1.0) * 255).round();
      }
      final header = 'P5\n$size $size\n255\n';
      final file = File('$dir/$filename');
      file.writeAsBytesSync([...header.codeUnits, ...bytes]);
    } catch (e) {
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
          (ch) => _boundsOverlap(elem.bounds, ch.bounds),
        );
        if (matching.isNotEmpty) {
          result.write(matching.first.char);
        }
      }
    }

    return result.toString();
  }

  static bool _boundsOverlap(MoveBounds a, MoveBounds b) {
    return a.left < b.right &&
        a.right > b.left &&
        a.bottom < b.top &&
        a.top > b.bottom;
  }

  /// Crop and resize a blob to 32×32 for HOG extraction.
  static Float32List _cropAndResizeBlob(
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
    return out;
  }
}
