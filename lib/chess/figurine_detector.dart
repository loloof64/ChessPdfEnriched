import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';
import 'models.dart';

/// Detects and classifies figurine chess-piece glyphs from a rendered PDF page.
///
/// Flow:
///   1. Find every non-ASCII character in [rawText] that has a non-empty charRect.
///   2. Render the page at [renderScale] (default 2.0 = 144 DPI).
///   3. For each candidate, crop the glyph region, resize to 32×32 grayscale,
///      and classify with the TFLite [FigurineClassifier].
///   4. Return one [DetectedFigurine] per glyph whose confidence ≥ [minConfidence].
///
/// The [renderScale] is kept as an explicit parameter so a future PDF-viewer
/// zoom level can be forwarded here without changing the rest of the pipeline.
class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API

  /// Detect figurine glyphs on [page].
  ///
  /// [rawText] and [charRects] come from [PdfPageRawText] (same page).
  /// [renderScale] should match the zoom/DPI used when text was extracted so
  /// that PDF-space coordinates map correctly to pixel coordinates.
  Future<List<DetectedFigurine>> detectFigurines(
    PdfPage page,
    String rawText,
    List<PdfRect> charRects, {
    double renderScale = 2.0,
    double minConfidence = 0.70,
  }) async {
    // --- 1. Gather non-ASCII candidates ---
    final candidates = <_GlyphCandidate>[];
    for (int i = 0; i < rawText.length && i < charRects.length; i++) {
      final char = rawText[i];
      if (char.codeUnitAt(0) <= 127) continue; // skip plain ASCII
      final rect = charRects[i];
      if (rect.isEmpty) continue;
      final w = rect.right - rect.left;
      final h = rect.top - rect.bottom;
      if (w < 4.0 || h < 4.0) continue; // too small to classify
      candidates.add(_GlyphCandidate(charIndex: i, char: char, rect: rect));
    }

    if (candidates.isEmpty) return [];

    // --- 2. Render page ---
    final iW = (page.width * renderScale).round();
    final iH = (page.height * renderScale).round();
    final image = await page.render(
      x: 0,
      y: 0,
      width: iW,
      height: iH,
      fullWidth: iW.toDouble(),
      fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) return [];

    final results = <DetectedFigurine>[];
    try {
      final gray = _toGray(image.pixels, iW, iH);
      int classified = 0;

      for (final c in candidates) {
        // PDF coords → pixel coords (Y axis is flipped: PDF bottom-left, image top-left).
        final px = (c.rect.left * renderScale).round();
        final py = ((page.height - c.rect.top) * renderScale).round();
        final pw = math.max(1, ((c.rect.right - c.rect.left) * renderScale).round());
        final ph = math.max(1, ((c.rect.top - c.rect.bottom) * renderScale).round());

        final pixels = _cropAndResize32(gray, iW, iH, px, py, pw, ph);
        final hit = classifier.classifyWithConfidence(pixels);
        if (hit == null) continue;

        final (pieceRaw, confidence) = hit;
        if (confidence < minConfidence) continue;

        // Pawn → empty string: the file letter is already the next character.
        final piece = pieceRaw == 'P' ? '' : pieceRaw;

        results.add(DetectedFigurine(
          charIndex: c.charIndex,
          bounds: MoveBounds(
            left: c.rect.left,
            top: c.rect.top,
            right: c.rect.right,
            bottom: c.rect.bottom,
          ),
          piece: piece,
          confidence: confidence,
        ));
        classified++;
      }

      debugPrint(
        '[FigurineDetector] ${candidates.length} candidate(s) → '
        '$classified classified at conf≥${minConfidence.toStringAsFixed(2)}',
      );
    } finally {
      image.dispose();
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Pixel utilities (duplicated from BoardDetector to keep modules independent)

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4] / 255.0;
    }
    return g;
  }

  /// Crop the rectangle [px,py,pw,ph] from [gray] and bilinearly resize to
  /// [FigurineClassifier.inputSize] × [FigurineClassifier.inputSize].
  static Float32List _cropAndResize32(
    Float32List gray,
    int imgW,
    int imgH,
    int px,
    int py,
    int pw,
    int ph,
  ) {
    const size = FigurineClassifier.inputSize; // 32
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

// ─────────────────────────────────────────────────────────────────────────────

class _GlyphCandidate {
  const _GlyphCandidate({
    required this.charIndex,
    required this.char,
    required this.rect,
  });

  final int charIndex;
  final String char;
  final PdfRect rect;
}
