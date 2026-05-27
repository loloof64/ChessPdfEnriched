import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'figurine_classifier.dart';
import 'hog_extractor.dart';
import 'models.dart';

/// Detects and classifies figurine chess-piece glyphs from a rendered PDF page
/// using connected-component (blob) analysis on the rendered image.
///
/// Flow:
///   1. Render the page at [renderScale].
///   2. Convert to grayscale and binarize (dark pixels = foreground).
///   3. Extract connected components with 8-connectivity; keep blobs whose
///      bounding box fits within [minGlyphSize]×[minGlyphSize] and
///      [maxGlyphSize]×[maxGlyphSize] (in PDF points).
///   4. For each blob: crop, resize to 32×32, run HOG → TFLite classifier.
///   5. Recover the PDF char-index by spatial overlap with [charRects].
class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API

  /// Detect figurine glyphs on [page].
  ///
  /// [rawText] and [charRects] come from [PdfPageRawText] (same page).
  /// [rawText] is not used for candidate selection; [charRects] is used only
  /// to recover a char-index for each detected blob (for downstream token
  /// merging in MoveParser).
  Future<List<DetectedFigurine>> detectFigurines(
    PdfPage page,
    String rawText,
    List<PdfRect> charRects, {
    double renderScale = 2.0,
    double minConfidence = 0.70,
    double minGlyphSize = 7.0,
    double maxGlyphSize = 60.0,
    double binaryThreshold = 0.85,
    bool verbose = false,
  }) async {
    // --- 1. Render page ---
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
      // --- 2. Grayscale + binary ---
      final gray = _toGray(image.pixels, iW, iH);
      final dark = _binarize(gray, iW, iH, binaryThreshold);

      // --- 3. Connected components ---
      final minPx = (minGlyphSize * renderScale).round();
      final maxPx = (maxGlyphSize * renderScale).round();
      final blobs = _connectedComponents(dark, iW, iH, minPx, maxPx);

      debugPrint('[FigurineDetector] ${blobs.length} blob(s) after size filter '
          '(${minGlyphSize.toStringAsFixed(0)}–${maxGlyphSize.toStringAsFixed(0)} pt)');

      // --- 4. Classify each blob ---
      int classified = 0;
      for (final blob in blobs) {
        final cropW = blob.right - blob.left;
        final cropH = blob.bottom - blob.top;

        final pixels   = _cropAndResize32(gray, iW, blob.left, blob.top, cropW, cropH);
        final features = HogExtractor.extract(pixels, cropW, cropH);
        final hit      = classifier.classifyWithConfidence(features);
        if (hit == null) continue;

        final (piece, confidence) = hit;
        final passes = confidence >= minConfidence;

        // Convert pixel bbox → PDF coords (image Y↓, PDF Y↑)
        final pdfLeft   = blob.left  / renderScale;
        final pdfRight  = blob.right / renderScale;
        final pdfTop    = page.height - blob.top    / renderScale;
        final pdfBottom = page.height - blob.bottom / renderScale;

        if (verbose) {
          final w = (pdfRight - pdfLeft).toStringAsFixed(1);
          final h = (pdfTop - pdfBottom).toStringAsFixed(1);
          debugPrint(
            '[FigurineDetector] blob ${w}×${h}pt → $piece '
            '${(confidence * 100).toStringAsFixed(0)}%'
            '${passes ? '' : ' (skip)'}',
          );
        }

        if (!passes) continue;

        // --- 5. Recover charIndex by spatial overlap ---
        final charIndex = _bestCharIndex(
          charRects,
          pdfLeft,
          pdfTop,
          pdfRight,
          pdfBottom,
        );

        results.add(DetectedFigurine(
          charIndex: charIndex,
          bounds: MoveBounds(
            left:   pdfLeft,
            top:    pdfTop,
            right:  pdfRight,
            bottom: pdfBottom,
          ),
          piece: piece,
          confidence: confidence,
        ));
        classified++;
      }

      debugPrint(
        '[FigurineDetector] ${blobs.length} blob(s) → '
        '$classified figurine(s) at conf≥${minConfidence.toStringAsFixed(2)}',
      );
    } finally {
      image.dispose();
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Image utilities

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4] / 255.0;
    }
    return g;
  }

  static Uint8List _binarize(Float32List gray, int w, int h, double threshold) {
    final out = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      out[i] = gray[i] < threshold ? 1 : 0;
    }
    return out;
  }

  /// Crop [cropX,cropY,cropW,cropH] from [gray] and resize to 32×32 using
  /// nearest-neighbour sampling.
  static Float32List _cropAndResize32(
    Float32List gray,
    int imgW,
    int cropX,
    int cropY,
    int cropW,
    int cropH,
  ) {
    const size = HogExtractor.imageSize; // 32
    final out = Float32List(size * size);
    for (int dy = 0; dy < size; dy++) {
      for (int dx = 0; dx < size; dx++) {
        final sx = (cropX + (dx * cropW) ~/ size).clamp(0, imgW - 1);
        final sy = cropY + (dy * cropH) ~/ size;
        out[dy * size + dx] = gray[sy * imgW + sx];
      }
    }
    return out;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connected-component analysis

  /// Find blobs in [dark] (1 = foreground, 0 = background) using 8-connected
  /// BFS. Only keeps blobs whose bounding box satisfies
  /// [minPx] ≤ width,height ≤ [maxPx].
  static List<_Blob> _connectedComponents(
    Uint8List dark,
    int w,
    int h,
    int minPx,
    int maxPx,
  ) {
    final visited = Uint8List(w * h);
    final blobs   = <_Blob>[];
    final queue   = Queue<int>();

    for (int start = 0; start < w * h; start++) {
      if (dark[start] == 0 || visited[start] != 0) continue;

      visited[start] = 1;
      queue.add(start);

      int bLeft = w, bRight = -1, bTop = h, bBottom = -1;

      while (queue.isNotEmpty) {
        final idx = queue.removeFirst();
        final x   = idx % w;
        final y   = idx ~/ w;

        if (x < bLeft)   bLeft   = x;
        if (x > bRight)  bRight  = x;
        if (y < bTop)    bTop    = y;
        if (y > bBottom) bBottom = y;

        // 8-connected neighbours
        final x0 = x > 0,     x1 = x < w - 1;
        final y0 = y > 0,     y1 = y < h - 1;
        if (x0 && y0 && _visit(visited, dark, idx - w - 1)) queue.add(idx - w - 1);
        if (       y0 && _visit(visited, dark, idx - w    )) queue.add(idx - w    );
        if (x1 && y0 && _visit(visited, dark, idx - w + 1)) queue.add(idx - w + 1);
        if (x0       && _visit(visited, dark, idx     - 1)) queue.add(idx     - 1);
        if (x1       && _visit(visited, dark, idx     + 1)) queue.add(idx     + 1);
        if (x0 && y1 && _visit(visited, dark, idx + w - 1)) queue.add(idx + w - 1);
        if (       y1 && _visit(visited, dark, idx + w    )) queue.add(idx + w    );
        if (x1 && y1 && _visit(visited, dark, idx + w + 1)) queue.add(idx + w + 1);
      }

      final blobW = bRight - bLeft + 1;
      final blobH = bBottom - bTop + 1;
      if (blobW >= minPx && blobH >= minPx && blobW <= maxPx && blobH <= maxPx) {
        // right/bottom are exclusive for crop math
        blobs.add(_Blob(bLeft, bTop, bRight + 1, bBottom + 1));
      }
    }

    return blobs;
  }

  static bool _visit(Uint8List visited, Uint8List dark, int idx) {
    if (dark[idx] == 0 || visited[idx] != 0) return false;
    visited[idx] = 1;
    return true;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Char-index recovery

  /// Return the index in [charRects] whose rect has the greatest overlap with
  /// the PDF-space bounding box [left, top, right, bottom].
  /// Returns [charRects.length] (out-of-range sentinel) if no rect overlaps.
  static int _bestCharIndex(
    List<PdfRect> charRects,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    int    best     = charRects.length; // sentinel → MoveParser will skip it
    double bestArea = 0;

    for (int i = 0; i < charRects.length; i++) {
      final r  = charRects[i];
      final ol = math.max(left,   r.left);
      final or_ = math.min(right, r.right);
      final ot = math.min(top,    r.top);
      final ob = math.max(bottom, r.bottom);
      if (or_ > ol && ot > ob) {
        final area = (or_ - ol) * (ot - ob);
        if (area > bestArea) {
          bestArea = area;
          best = i;
        }
      }
    }

    return best;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Blob {
  const _Blob(this.left, this.top, this.right, this.bottom);

  /// Pixel coordinates; right and bottom are exclusive.
  final int left, top, right, bottom;
}
