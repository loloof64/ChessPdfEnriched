import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';

/// Builds a `fontMap` entry for each unknown figurine character found on a
/// PDF page by cropping the character's bounding box from the rendered page
/// image and running [FigurineClassifier] on it.
///
/// Only characters that are NOT already known standard SAN starts and are NOT
/// already in the caller's `knownMap` are processed.
class FigurineMapBuilder {
  // Render scale — matches BoardDetector so we can share a render if needed.
  static const _scale = 2.0;

  // Minimum classifier confidence to accept a prediction.
  static const _minConfidence = 0.70;

  // Chars MoveParser treats as standard SAN starts (no TFLite needed for these).
  static final _standardSanStart = RegExp(
    r'[KQRBNa-hO0-9x=+#♔♕♖♗♘♙♚♛♜♝♞♟]',
  );

  static bool _looksLikeSanSuffix(String ch) =>
      (ch.compareTo('a') >= 0 && ch.compareTo('h') <= 0) ||
      ch == 'x' ||
      ch == '=';

  static bool _isDelimiter(String c) =>
      c == ' ' ||
      c == '\n' ||
      c == '\r' ||
      c == '\t' ||
      c == '(' ||
      c == ')' ||
      c == '{' ||
      c == '}';

  /// Discover figurine character → piece mappings for [page].
  ///
  /// Returns a map of newly discovered entries (chars not in [knownMap]).
  /// The caller should merge the result into their shared `fontMap`.
  ///
  /// Mapping values follow the same convention as `MoveParser.fontMap`:
  ///   - `'K'`, `'Q'`, `'R'`, `'B'`, `'N'` for the corresponding pieces
  ///   - `''` (empty string) for pawn glyphs
  static Future<Map<String, String>> buildForPage(
    FigurineClassifier classifier,
    PdfPage page,
    PdfPageRawText rawText, {
    Map<String, String>? knownMap,
  }) async {
    final text = rawText.fullText;
    final charRects = rawText.charRects;

    // ── 1. Find candidate characters ────────────────────────────────────────
    // A candidate is the first char of a whitespace-delimited token that:
    //   • is not a standard SAN start
    //   • is not already in knownMap
    //   • is followed by a char that looks like a SAN file/capture suffix

    final candidates = <String, int>{}; // char → one representative text index

    int i = 0;
    while (i < text.length) {
      while (i < text.length && _isDelimiter(text[i])) { i++; }
      if (i >= text.length) break;

      final wordStart = i;
      while (i < text.length && !_isDelimiter(text[i])) { i++; }

      if (i - wordStart < 2) continue;

      final first = text[wordStart];
      if (!_standardSanStart.hasMatch(first) &&
          !(knownMap?.containsKey(first) ?? false) &&
          !candidates.containsKey(first)) {
        final next = text[wordStart + 1];
        if (_looksLikeSanSuffix(next) &&
            wordStart < charRects.length &&
            charRects[wordStart].isNotEmpty) {
          candidates[first] = wordStart;
        }
      }
    }

    if (candidates.isEmpty) return const {};
    debugPrint(
      '[FigurineMapBuilder] ${candidates.length} candidate(s): '
      '"${candidates.keys.join()}"',
    );

    // ── 2. Render page ───────────────────────────────────────────────────────
    final iW = (page.width * _scale).round();
    final iH = (page.height * _scale).round();
    final pdfImage = await page.render(
      x: 0,
      y: 0,
      width: iW,
      height: iH,
      fullWidth: iW.toDouble(),
      fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (pdfImage == null) return const {};

    // ── 3. Classify each candidate ───────────────────────────────────────────
    final result = <String, String>{};

    for (final entry in candidates.entries) {
      final ch = entry.key;
      final idx = entry.value;
      if (idx >= charRects.length) continue;
      final rect = charRects[idx];
      if (rect.isEmpty) continue;

      // PDF coords: origin bottom-left, Y up → image coords: origin top-left, Y down
      final imgLeft   = (rect.left * _scale).round().clamp(0, iW - 1);
      final imgTop    = ((page.height - rect.top) * _scale).round().clamp(0, iH - 1);
      final imgRight  = (rect.right * _scale).round().clamp(imgLeft + 1, iW);
      final imgBottom = ((page.height - rect.bottom) * _scale).round().clamp(imgTop + 1, iH);

      final cropW = imgRight - imgLeft;
      final cropH = imgBottom - imgTop;
      if (cropW < 3 || cropH < 3) continue;

      final pixels = _cropAndResize(
        pdfImage.pixels,
        iW,
        imgLeft,
        imgTop,
        cropW,
        cropH,
        FigurineClassifier.inputSize,
      );

      final prediction = classifier.classifyWithConfidence(pixels);
      if (prediction == null) continue;
      final (piece, confidence) = prediction;

      if (confidence >= _minConfidence) {
        result[ch] = piece == 'P' ? '' : piece;
        debugPrint(
          '[FigurineMapBuilder] "$ch" → $piece '
          '(${(confidence * 100).round()}%)',
        );
      } else {
        debugPrint(
          '[FigurineMapBuilder] "$ch" → low confidence '
          '($piece ${(confidence * 100).round()}%), skipped',
        );
      }
    }

    return result;
  }

  /// Crop a region from BGRA pixels and resize to [size]×[size] grayscale [0,1].
  static Float32List _cropAndResize(
    Uint8List bgra,
    int srcWidth,
    int cropX,
    int cropY,
    int cropW,
    int cropH,
    int size,
  ) {
    final srcHeight = bgra.length ~/ (srcWidth * 4);
    final out = Float32List(size * size);
    for (int ty = 0; ty < size; ty++) {
      for (int tx = 0; tx < size; tx++) {
        final sx = (cropX + ((tx + 0.5) * cropW / size - 0.5).round())
            .clamp(0, srcWidth - 1);
        final sy = (cropY + ((ty + 0.5) * cropH / size - 0.5).round())
            .clamp(0, srcHeight - 1);
        final p = (sy * srcWidth + sx) * 4;
        // BGRA → luminance
        out[ty * size + tx] =
            (0.299 * bgra[p + 2] + 0.587 * bgra[p + 1] + 0.114 * bgra[p]) /
            255.0;
      }
    }
    return out;
  }
}
