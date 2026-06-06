import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
  }) async {
    // Step 1: Segment word block into individual elements by gap detection
    final elementBounds = _segmentElementsByGaps(
      rendered.gray,
      rendered.width,
      rendered.height,
      blockBounds,
      pageHeight,
      renderScale,
    );

    debugPrint(
      '[ElementParser] block at left=${blockBounds.left.toStringAsFixed(1)} '
      '→ ${elementBounds.length} element(s) segmented',
    );

    if (elementBounds.isEmpty) return [];

    // Step 2: For each element, classify as figurine or text
    final parsed = <ParsedElement>[];
    for (int i = 0; i < elementBounds.length; i++) {
      final elemBounds = elementBounds[i];

      debugPrint(
        '[ElementParser]   elem[$i] @ ${elemBounds.left.toStringAsFixed(1)}: ',
      );

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

      // Try FigurineClassifier first (figurines are higher priority in chess notation)
      final figResult = figurineClassifier.classifyWithConfidence(features);
      if (figResult != null && figResult.$2 > 0.95) {
        // High figurine confidence (>0.95) → use it (extremely strict threshold)
        final (piece, conf) = figResult;
        parsed.add(
          ParsedElement(
            text: piece,
            bounds: elemBounds,
            type: 'figurine',
            confidence: conf,
          ),
        );
        debugPrint(
          '[ElementParser]     → FIGURINE: $piece (conf=${conf.toStringAsFixed(2)})',
        );
      } else {
        // No good figurine match → try NotAFigurineClassifier to confirm text
        final textConf =
            notAFigurineClassifier.classifyAsNotFigurine(features) ?? 0.0;

        debugPrint(
          '[ElementParser]     textConfidence=${textConf.toStringAsFixed(2)}',
        );

        if (textConf >= minTextConfidence) {
          // High text confidence → OCR it
          final ocrChar = await _ocrElement(
            rendered.gray,
            elemBounds,
            rendered.width,
            rendered.height,
            pageHeight,
            renderScale,
          );

          if (ocrChar.isNotEmpty) {
            parsed.add(
              ParsedElement(
                text: ocrChar,
                bounds: elemBounds,
                type: 'text',
                confidence: textConf,
              ),
            );
            debugPrint('[ElementParser]     → TEXT (OCR): "$ocrChar"');
          } else {
            debugPrint('[ElementParser]     → TEXT (OCR failed)');
          }
        } else {
          debugPrint('[ElementParser]     → SKIPPED (ambiguous)');
        }
      }
    }

    debugPrint(
      '[ElementParser] block → ${parsed.length}/${elementBounds.length} element(s) classified',
    );

    return parsed;
  }

  /// Segment a word block into individual elements by detecting gaps in the rendered pixels.
  /// Returns a list of bounding boxes for each detected element, sorted left-to-right.
  static List<MoveBounds> _segmentElementsByGaps(
    Float32List gray,
    int imgW,
    int imgH,
    MoveBounds blockBounds,
    double pageHeight,
    double scale, {
    double pixelThreshold = 0.75, // Pixels > 0.75 are "white" (background)
    double gapThreshold =
        0.25, // Columns with >25% white pixels are gaps (balanced)
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

    // Compute column-wise white pixel fraction (gap detection)
    final colGapFraction = List<double>.filled(colWidth, 0.0);
    for (int x = px0; x < px1; x++) {
      int whiteCount = 0;
      for (int y = py0; y < py1; y++) {
        final idx = y * imgW + x;
        if (idx < gray.length && gray[idx] > pixelThreshold) {
          whiteCount++;
        }
      }
      colGapFraction[x - px0] = whiteCount / colHeight;
    }

    debugPrint(
      '[SegmentElements] gap fraction: min=${colGapFraction.reduce((a, b) => a < b ? a : b).toStringAsFixed(3)}, '
      'max=${colGapFraction.reduce((a, b) => a > b ? a : b).toStringAsFixed(3)}, '
      'threshold=$gapThreshold',
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

  /// OCR a single element to extract its character.
  /// Returns the recognized text, or empty string if OCR fails.
  static Future<String> _ocrElement(
    Float32List gray,
    MoveBounds elemBounds,
    int imgW,
    int imgH,
    double pageHeight,
    double scale,
  ) async {
    try {
      // Crop element region from image
      final px0 = (elemBounds.left * scale).round().clamp(0, imgW - 1);
      final px1 = (elemBounds.right * scale).round().clamp(px0 + 1, imgW);
      final py0 = ((pageHeight - elemBounds.top) * scale).round().clamp(
        0,
        imgH - 1,
      );
      final py1 = ((pageHeight - elemBounds.bottom) * scale).round().clamp(
        py0 + 1,
        imgH,
      );

      final width = px1 - px0;
      final height = py1 - py0;
      if (width <= 0 || height <= 0) return '';

      // Extract grayscale pixels and convert to 8-bit format for tesseract
      final imageBytes = Uint8List(width * height);
      for (int y = py0; y < py1; y++) {
        for (int x = px0; x < px1; x++) {
          final idx = y * imgW + x;
          if (idx < gray.length) {
            imageBytes[(y - py0) * width + (x - px0)] = (gray[idx] * 255)
                .round()
                .clamp(0, 255)
                .toUnsigned(8);
          }
        }
      }

      // Save to temporary file in PBM format
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
        '${tmpDir.path}/ocr_${DateTime.now().millisecondsSinceEpoch}.pbm',
      );

      // PBM format header: P5\nwidth height\n255\n then raw bytes
      final pbmHeader = 'P5\n$width $height\n255\n'.codeUnits;
      final pbmData = Uint8List(pbmHeader.length + imageBytes.length);
      pbmData.setRange(0, pbmHeader.length, pbmHeader);
      pbmData.setRange(
        pbmHeader.length,
        pbmHeader.length + imageBytes.length,
        imageBytes,
      );
      tmpFile.writeAsBytesSync(pbmData);

      // Run tesseract OCR
      final result = await Process.run('tesseract', [
        tmpFile.path,
        'stdout',
        '-l', 'eng',
        '--psm', '10', // Single character mode
      ]);

      // Clean up temp file
      try {
        tmpFile.deleteSync();
      } catch (_) {}

      if (result.exitCode != 0) {
        debugPrint(
          '[OcrElement] tesseract exit ${result.exitCode}: ${result.stderr}',
        );
        return '';
      }

      // Extract first character from OCR output
      final text = (result.stdout as String).trim();
      return text.isNotEmpty
          ? text.split('\n').first.trim().characters.first.toString()
          : '';
    } catch (e) {
      debugPrint('[OcrElement] OCR failed: $e');
      return '';
    }
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
