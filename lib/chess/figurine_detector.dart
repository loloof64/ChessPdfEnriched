import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';
import 'hog_extractor.dart';
import 'models.dart';

/// Detects and classifies figurine chess-piece glyphs from a rendered PDF page.
///
/// Flow:
///   1. Collect every character in [rawText] whose rendered glyph is large
///      enough to produce a meaningful image (≥ [minGlyphSize] in both axes).
///   2. Render the page at [renderScale].
///   3. Crop each candidate, resize to 32×32 grayscale, run the TFLite model.
///   4. Return one [DetectedFigurine] per glyph whose confidence ≥ [minConfidence].
///
/// No Unicode-range or ASCII filtering is applied: the model decides whether a
/// shape is a chess piece, regardless of the character's code point.
class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API

  /// Detect figurine glyphs on [page].
  ///
  /// [rawText] and [charRects] come from [PdfPageRawText] (same page).
  ///
  /// [minGlyphSize] (default 7 pt): minimum width AND height of a candidate
  /// bounding box.  At [renderScale] 2.0 this corresponds to ≥ 14 px in each
  /// dimension — enough for the 32×32 model to see meaningful detail.
  /// Characters smaller than this (e.g. narrow accented letters) are skipped
  /// because their downscaled images are too noisy for reliable classification.
  ///
  /// Set [verbose] to true for per-candidate debug output.
  Future<List<DetectedFigurine>> detectFigurines(
    PdfPage page,
    String rawText,
    List<PdfRect> charRects, {
    double renderScale = 2.0,
    double minConfidence = 0.70,
    double minGlyphSize = 7.0,
    bool verbose = false,
  }) async {
    // --- 1. Collect size-filtered candidates (all code points) ---
    final candidates = <_GlyphCandidate>[];
    int filteredSize = 0;

    for (int i = 0; i < rawText.length && i < charRects.length; i++) {
      final rect = charRects[i];
      if (rect.isEmpty) continue;

      final w = rect.right - rect.left;
      final h = rect.top - rect.bottom;

      if (w < minGlyphSize || h < minGlyphSize) {
        filteredSize++;
        continue;
      }

      candidates.add(_GlyphCandidate(
        charIndex: i,
        char: rawText[i],
        rect: rect,
      ));
    }

    debugPrint(
      '[FigurineDetector] ${rawText.length} chars → '
      '$filteredSize too small → ${candidates.length} candidate(s)',
    );

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
        // PDF coords → pixel coords (Y axis flipped: PDF bottom-left, image top-left).
        final px = (c.rect.left * renderScale).round();
        final py = ((page.height - c.rect.top) * renderScale).round();
        final pw = math.max(1, ((c.rect.right - c.rect.left) * renderScale).round());
        final ph = math.max(1, ((c.rect.top - c.rect.bottom) * renderScale).round());

        final pixels   = _cropAndResize32(gray, iW, iH, px, py, pw, ph);
        final features = HogExtractor.extract(pixels, pw, ph);
        final hit      = classifier.classifyWithConfidence(features);
        if (hit == null) continue;

        final (piece, confidence) = hit;
        final passes = confidence >= minConfidence;

        if (verbose) {
          final code = c.char.codeUnitAt(0).toRadixString(16).padLeft(4, '0');
          final w = (c.rect.right - c.rect.left).toStringAsFixed(1);
          final h = (c.rect.top - c.rect.bottom).toStringAsFixed(1);
          debugPrint(
            '[FigurineDetector] U+$code "${c.char}" $w×${h}pt '
            '→ $piece ${(confidence * 100).toStringAsFixed(0)}%'
            '${passes ? "" : " (skip)"}',
          );
        }

        if (!passes) continue;

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
  // Pixel utilities

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4] / 255.0;
    }
    return g;
  }

  /// Crop [px,py,pw,ph] from [gray] and nearest-neighbour resize to
  /// [HogExtractor.imageSize] × [HogExtractor.imageSize] (32×32).
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
