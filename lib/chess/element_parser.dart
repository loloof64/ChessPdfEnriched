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

  /// Parse all elements within a word block.
  /// Returns a list of parsed elements sorted left-to-right.
  List<ParsedElement> parseWordBlock(
    RenderedPage rendered,
    MoveBounds blockBounds,
    double pageHeight,
    double renderScale, {
    double minConfidence = 0.50,
    double minGlyphSizePt = 8.0,
    double maxAspectRatio = 2.0,
  }) {
    // Step 1: Detect blobs within the word block
    final blobResults = FigurineDetector(classifier: figurineClassifier)
        .analyseWordBlock(
          rendered,
          blockBounds,
          pageHeight,
          renderScale,
          minConfidence: 0.0, // Accept all candidates
          minGlyphSizePt: minGlyphSizePt,
          maxAspectRatio: maxAspectRatio,
        );

    debugPrint(
      '[ElementParser] block at left=${blockBounds.left.toStringAsFixed(1)} → ${blobResults.length} blob(s) detected',
    );

    if (blobResults.isEmpty) return [];

    // Step 2: For each blob, classify as figurine or text
    final parsed = <ParsedElement>[];
    for (final blob in blobResults) {
      final pdfBounds = blob.bounds;

      // Extract HOG features for text/figurine classification
      final pixels = _cropAndResizeBlob(
        rendered.gray,
        rendered.width,
        rendered.height,
        pdfBounds,
        pageHeight,
        renderScale,
      );
      final features = HogExtractor.extract(pixels, 32, 32);

      // Debug: inspect feature stats
      double minFeat = features.isEmpty ? 0 : features.first;
      double maxFeat = features.isEmpty ? 0 : features.first;
      double sumFeat = 0.0;
      for (final f in features) {
        minFeat = minFeat < f ? minFeat : f;
        maxFeat = maxFeat > f ? maxFeat : f;
        sumFeat += f;
      }
      final meanFeat = features.isEmpty ? 0 : sumFeat / features.length;
      debugPrint(
        '[ElementParser] HOG stats: min=$minFeat max=$maxFeat mean=$meanFeat',
      );

      // Classify as text vs figurine
      final notFigurineConf =
          notAFigurineClassifier.classifyAsNotFigurine(features) ?? 0.0;
      final isFigurineConf = blob.confidence;

      debugPrint(
        '[ElementParser]   blob @ ${pdfBounds.left.toStringAsFixed(1)}: '
        'figurine=${isFigurineConf.toStringAsFixed(2)} notFigurine=${notFigurineConf.toStringAsFixed(2)} '
        'piece=${blob.piece}',
      );

      // Decide based on which classifier is more confident
      if (isFigurineConf > notFigurineConf && blob.piece != null) {
        // High figurine confidence → it's a chess piece
        parsed.add(
          ParsedElement(
            text: blob.piece!,
            bounds: pdfBounds,
            type: 'figurine',
            confidence: isFigurineConf,
          ),
        );
        debugPrint(
          '[ElementParser]     → classified as FIGURINE: ${blob.piece}',
        );
      } else if (notFigurineConf >= minConfidence) {
        // High text confidence → it's a regular character
        // Placeholder: actual OCR/text extraction handled by caller
        parsed.add(
          ParsedElement(
            text: '?', // Caller will map this to PDF text
            bounds: pdfBounds,
            type: 'text',
            confidence: notFigurineConf,
          ),
        );
        debugPrint('[ElementParser]     → classified as TEXT');
      } else {
        debugPrint('[ElementParser]     → SKIPPED (ambiguous)');
      }
    }

    debugPrint(
      '[ElementParser] block → ${parsed.length}/${blobResults.length} element(s) accepted',
    );

    return parsed;
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
