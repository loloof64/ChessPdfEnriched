import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';
import 'hog_extractor.dart';
import 'models.dart';

/// Detects and classifies figurine chess-piece glyphs from a rendered PDF page.
///
/// Approach: purely visual — no codepoint or context filtering.
///   1. Take every character whose PDF bounding box is large enough and
///      roughly square (aspect ratio 0.5–2.0). This captures figurine glyphs
///      regardless of what byte the PDF font encodes them as.
///   2. Skip characters whose bounding box falls inside a detected chess board
///      (supplied via [boardRects]) — boards contain piece graphics too but
///      those belong to board detection, not move annotation.
///   3. Render the page, crop each candidate, resize to 32×32, run HOG→TFLite.
///   4. Return one [DetectedFigurine] per glyph whose confidence ≥ [minConfidence].
class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API

  /// Detect figurine glyphs on [page].
  ///
  /// [rawText] and [charRects] come from [PdfPageRawText] (same page).
  ///
  /// [boardRects] — PDF-coordinate rectangles of detected chess board diagrams;
  /// characters whose rect centre falls inside one of these are skipped.
  ///
  /// [minGlyphSize] (default 12 pt): minimum width AND height of a candidate
  /// bounding box.  Filters out normal-sized letters; figurine glyphs in chess
  /// book paragraphs are typically ≥ 12 pt in both dimensions.
  ///
  /// [maxAspectRatio] (default 2.0): maximum width/height (or height/width)
  /// ratio.  Rejects very tall/narrow elements (decorative rules, etc.).
  Future<List<DetectedFigurine>> detectFigurines(
    PdfPage page,
    String rawText,
    List<PdfRect> charRects, {
    List<PdfRect> boardRects = const [],
    double renderScale = 2.0,
    double minConfidence = 0.60,
    double minGlyphSize = 12.0,
    double maxAspectRatio = 2.0,
    bool verbose = false,
  }) async {
    // --- 1. Collect candidates ---
    final candidates = <_GlyphCandidate>[];
    int filteredSize   = 0;
    int filteredAspect = 0;
    int filteredBoard  = 0;
    int filteredChar   = 0;

    for (int i = 0; i < rawText.length && i < charRects.length; i++) {
      final rect = charRects[i];
      if (rect.isEmpty) continue;

      // Figurine glyphs in PDF text extraction are virtually never regular
      // ASCII digits or lowercase letters — those are always plain text.
      final cp = rawText.codeUnitAt(i);
      if ((cp >= 0x30 && cp <= 0x39) || (cp >= 0x61 && cp <= 0x7A)) {
        filteredChar++;
        continue;
      }

      final w = rect.right  - rect.left;
      final h = rect.top    - rect.bottom;

      // Size gate — both dimensions must meet the minimum.
      if (w < minGlyphSize || h < minGlyphSize) { filteredSize++; continue; }

      // Aspect-ratio gate — rejects decorative rules, ligatures, etc.
      final ar = w / h;
      if (ar < 1.0 / maxAspectRatio || ar > maxAspectRatio) {
        filteredAspect++;
        continue;
      }

      // Board exclusion — centre of the glyph must not be inside a board rect.
      final cx = (rect.left + rect.right)  / 2;
      final cy = (rect.bottom + rect.top) / 2;
      if (boardRects.any((b) =>
          cx >= b.left && cx <= b.right &&
          cy >= b.bottom && cy <= b.top)) {
        filteredBoard++;
        continue;
      }

      candidates.add(_GlyphCandidate(charIndex: i, char: rawText[i], rect: rect));
    }

    debugPrint(
      '[FigurineDetector] ${rawText.length} chars → '
      '$filteredChar plain text → $filteredSize too small → '
      '$filteredAspect bad aspect → $filteredBoard in board → '
      '${candidates.length} candidate(s)',
    );

    if (candidates.isEmpty) return [];

    // --- 2. Render page ---
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
      final gray = _toGray(image.pixels, iW, iH);
      int classified = 0;

      for (final c in candidates) {
        // PDF coords → pixel coords (Y-axis flip)
        final px = (c.rect.left  * renderScale).round();
        final py = ((page.height - c.rect.top) * renderScale).round();
        final pw = math.max(1, ((c.rect.right  - c.rect.left)   * renderScale).round());
        final ph = math.max(1, ((c.rect.top    - c.rect.bottom) * renderScale).round());

        final pixels   = _cropAndResize32(gray, iW, iH, px, py, pw, ph);
        final features = HogExtractor.extract(pixels, pw, ph);
        final hit      = classifier.classifyWithConfidence(features);
        if (hit == null) continue;

        final (piece, confidence) = hit;
        final passes = confidence >= minConfidence;

        if (verbose) {
          final code = c.char.codeUnitAt(0).toRadixString(16).padLeft(4, '0');
          final ws = (c.rect.right - c.rect.left).toStringAsFixed(1);
          final hs = (c.rect.top - c.rect.bottom).toStringAsFixed(1);
          debugPrint(
            '[FigurineDetector] U+$code "${c.char}" $ws×${hs}pt '
            '→ $piece ${(confidence * 100).toStringAsFixed(0)}%'
            '${passes ? '' : ' (skip)'}',
          );
        }

        if (!passes) continue;

        results.add(DetectedFigurine(
          charIndex: c.charIndex,
          bounds: MoveBounds(
            left: c.rect.left, top: c.rect.top,
            right: c.rect.right, bottom: c.rect.bottom,
          ),
          piece: piece,
          confidence: confidence,
        ));
        classified++;
      }

      debugPrint(
        '[FigurineDetector] ${candidates.length} candidate(s) → '
        '$classified figurine(s) at conf≥${minConfidence.toStringAsFixed(2)}',
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
