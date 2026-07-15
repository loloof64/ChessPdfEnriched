import 'dart:async';
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
/// Pre-rendered page image shared between analysis steps.
typedef RenderedPage = ({
  Float32List gray,
  Uint8List binary,
  int width,
  int height,
});

/// One blob inside a word block, with its figurine classification result.
typedef BlobResult = ({
  MoveBounds bounds, // PDF-coordinate bounding box
  String? piece, // piece letter if classified as figurine, null otherwise
  double confidence, // classifier confidence (0 if NotAFigurine)
});

class FigurineDetector {
  FigurineDetector({required this.classifier});

  final FigurineClassifier classifier;

  // ─────────────────────────────────────────────────────────────────────────
  // Page rendering

  /// Renders [page] to grayscale + binary at [scale] px/pt.
  static Future<RenderedPage?> renderPage(
    PdfPage page, {
    double scale = 2.0,
    double binarizeThreshold = 0.85,
  }) async {
    final iW = (page.width * scale).round();
    final iH = (page.height * scale).round();
    final image = await page.render(
      x: 0,
      y: 0,
      width: iW,
      height: iH,
      fullWidth: iW.toDouble(),
      fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) return null;
    try {
      final gray = _toGray(image.pixels, iW, iH);
      final binary = _binarize(gray, iW, iH, binarizeThreshold);
      return (gray: gray, binary: binary, width: iW, height: iH);
    } finally {
      image.dispose();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Per-block analysis

  /// Segments all character blobs within [blockBounds] and classifies each
  /// with the figurine classifier.  Returns one [BlobResult] per blob,
  /// sorted left-to-right.  Non-figurine blobs have [BlobResult.piece] == null.
  /// Find character boundaries using horizontal projection profile.
  /// Scans for vertical gaps in ink to split wide blobs into individual characters.
  static List<int> _findCharacterBoundaries(
    Uint8List binary,
    int imgW,
    int x0,
    int y0,
    int w,
    int h,
  ) {
    // Count ink pixels per column within the blob
    final colSums = List<int>.filled(w, 0);
    for (int dy = 0; dy < h; dy++) {
      for (int dx = 0; dx < w; dx++) {
        final idx = (y0 + dy) * imgW + (x0 + dx);
        if (binary[idx] != 0) colSums[dx]++;
      }
    }

    // Find gaps (columns with few/no ink pixels) — true whitespace between glyphs.
    final gaps = <int>[];
    final gapThreshold = (h * 0.1)
        .round(); // Less than 10% ink = gap (more sensitive)
    for (int dx = 1; dx < w; dx++) {
      if (colSums[dx] < gapThreshold && colSums[dx - 1] >= gapThreshold) {
        gaps.add(x0 + dx);
      }
    }
    if (gaps.isNotEmpty) return gaps;

    // Fallback: no straight-column gap found — happens whenever the
    // whitespace between two glyphs is not a straight vertical corridor,
    // e.g. a round "P" bowl kerned tightly against a diagonal "A" leg: at
    // the top of the pair the gap sits to the left, at the bottom it sits
    // to the right, so no single column is ever ink-free even though the
    // characters don't actually overlap.
    //
    // Model the gap as the cheapest top-to-bottom path through the ink
    // profile, letting the path drift ±1 column per row (a "seam", as in
    // seam carving). `seamCost[x]` is the total ink crossed by the
    // cheapest such path ending at column x — a diagonal/curved channel of
    // whitespace shows up as a local minimum here even when the straight
    // per-column ink sum never drops near zero.
    final seamCost = _seamCostProfile(binary, imgW, x0, y0, w, h);
    final windowRadius = (w / 20).clamp(2, 6).round();
    for (int dx = windowRadius; dx < w - windowRadius; dx++) {
      final v = seamCost[dx];
      var isLocalMin = true;
      for (int k = 1; k <= windowRadius; k++) {
        if (seamCost[dx - k] < v || seamCost[dx + k] < v) {
          isLocalMin = false;
          break;
        }
      }
      if (!isLocalMin) continue;

      var leftPeak = 0;
      for (int k = 1; k <= windowRadius; k++) {
        if (seamCost[dx - k] > leftPeak) leftPeak = seamCost[dx - k];
      }
      var rightPeak = 0;
      for (int k = 1; k <= windowRadius; k++) {
        if (seamCost[dx + k] > rightPeak) rightPeak = seamCost[dx + k];
      }
      final peak = leftPeak < rightPeak ? leftPeak : rightPeak;
      // The seam must cross markedly less ink than the surrounding peaks to
      // count as a character boundary, not just a thin stroke within a glyph.
      if (peak > 0 && v < peak * 0.5) {
        gaps.add(x0 + dx);
      }
    }
    return gaps;
  }

  /// For each column x, the total ink crossed by the cheapest top-to-bottom
  /// path ending at x, where the path may shift by at most one column per
  /// row (dynamic programming / seam-carving cost). Lets a whitespace
  /// "channel" between two glyphs be found even when it isn't a straight
  /// vertical line (e.g. it bends around a kerned round/diagonal pair).
  static List<int> _seamCostProfile(
    Uint8List binary,
    int imgW,
    int x0,
    int y0,
    int w,
    int h,
  ) {
    var prev = List<int>.filled(w, 0);
    for (int dx = 0; dx < w; dx++) {
      prev[dx] = binary[y0 * imgW + (x0 + dx)] != 0 ? 1 : 0;
    }
    for (int dy = 1; dy < h; dy++) {
      final cur = List<int>.filled(w, 0);
      final rowBase = (y0 + dy) * imgW + x0;
      for (int dx = 0; dx < w; dx++) {
        var best = prev[dx];
        if (dx > 0 && prev[dx - 1] < best) best = prev[dx - 1];
        if (dx < w - 1 && prev[dx + 1] < best) best = prev[dx + 1];
        final ink = binary[rowBase + dx] != 0 ? 1 : 0;
        cur[dx] = best + ink;
      }
      prev = cur;
    }
    return prev;
  }

  List<BlobResult> analyseWordBlock(
    RenderedPage rendered,
    MoveBounds blockBounds,
    double pageHeight,
    double renderScale, {
    double minConfidence = 0.95,
    double minGlyphSizePt = 8.0,
    double maxAspectRatio = 2.0,
    // When set, every 32×32 crop fed to the classifier is dumped as a
    // .pgm file in this directory, named with its classification result,
    // for visual debugging of segmentation quality.
    String? debugCropDir,
    // When set, diagnostic lines are appended straight to this file instead
    // of going through debugPrint — terminal/logcat output gets truncated
    // or drops lines under heavy volume, a file never does.
    String? debugLogFile,
  }) {
    final iW = rendered.width;
    final iH = rendered.height;

    final px0 = (blockBounds.left * renderScale).round().clamp(0, iW);
    final py0 = ((pageHeight - blockBounds.top) * renderScale).round().clamp(
      0,
      iH,
    );
    final px1 = (blockBounds.right * renderScale).round().clamp(0, iW);
    final py1 = ((pageHeight - blockBounds.bottom) * renderScale).round().clamp(
      0,
      iH,
    );
    if (px1 <= px0 || py1 <= py0) return [];

    // Reversed-video text (light glyphs on a dark banner, e.g. chapter
    // titles) inverts what "ink" means: the background becomes one giant
    // foreground blob and the letters become holes in it, so connected-
    // component analysis never sees separate characters at all. Detect
    // this by checking the ink ratio in the block: normal text covers a
    // small fraction of its bounding box, a solid banner covers most of
    // it. If so, flip both the binary and grayscale buffers within this
    // block's region so the rest of the pipeline sees ordinary dark-on-
    // light glyphs, then restore them afterwards (the buffers are shared
    // across all blocks on the page).
    var inkCount = 0;
    for (int y = py0; y < py1; y++) {
      final rowBase = y * iW;
      for (int x = px0; x < px1; x++) {
        if (rendered.binary[rowBase + x] != 0) inkCount++;
      }
    }
    final inkRatio = inkCount / ((px1 - px0) * (py1 - py0));
    final inverted = inkRatio > 0.5;
    _log(
      debugLogFile,
      '[FigurineDetector] block px[$px0,$py0]-[$px1,$py1] '
      '${px1 - px0}x${py1 - py0} inkRatio=${inkRatio.toStringAsFixed(2)} '
      'inverted=$inverted',
    );
    if (inverted) {
      for (int y = py0; y < py1; y++) {
        final rowBase = y * iW;
        for (int x = px0; x < px1; x++) {
          final idx = rowBase + x;
          rendered.binary[idx] = rendered.binary[idx] == 0 ? 1 : 0;
          rendered.gray[idx] = 1.0 - rendered.gray[idx];
        }
      }
    }

    try {
      final allBlobs = _connectedBoxes(
        rendered.binary,
        iW,
        iH,
        clipX0: px0,
        clipY0: py0,
        clipX1: px1,
        clipY1: py1,
      );
      if (allBlobs.isEmpty) return [];

      final minSizePx = (minGlyphSizePt * renderScale).round();
      // Use light merge gap to separate most adjacent characters
      final mergeGap = 1;
      final merged = _mergeNearbyBlobs(allBlobs, mergeGap);

      // Split wide blobs using horizontal projection profile to find actual character gaps
      final candidates = <({int x0, int y0, int x1, int y1})>[];
      for (final cb in merged) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;

        // If blob is wider than tall, find character boundaries and split there
        if (cw > ch * 1.2) {
          final gaps = _findCharacterBoundaries(
            rendered.binary,
            iW,
            cb.x0,
            cb.y0,
            cw,
            ch,
          );

          if (gaps.isNotEmpty) {
            // Split at gap boundaries
            var prevX = cb.x0;
            for (final gap in gaps) {
              if (gap > prevX + minSizePx) {
                candidates.add((x0: prevX, y0: cb.y0, x1: gap - 1, y1: cb.y1));
                prevX = gap;
              }
            }
            // Add remaining segment
            if (prevX < cb.x1) {
              candidates.add((x0: prevX, y0: cb.y0, x1: cb.x1, y1: cb.y1));
            }
          } else {
            // No ink-density or seam-based boundary found at all — happens
            // when glyphs physically touch with zero background between
            // them (tight bold kerning). Fall back to a vertical-density
            // split, then force-slice any piece still too wide into
            // equal-width chunks sized like a plausible character, rather
            // than handing a multi-glyph run to the classifier as one crop.
            final densitySplit = _splitBlobVertically(
              rendered.binary,
              iW,
              cb,
              1.2,
            );
            for (final piece in densitySplit) {
              candidates.addAll(
                _forceSplitByWidth(
                  rendered.binary,
                  rendered.gray,
                  iW,
                  iH,
                  piece,
                  ch,
                  classifier,
                  debugLogFile,
                ),
              );
            }
          }
        } else {
          candidates.add(cb);
        }
      }

      final results = <BlobResult>[];
      // Use 50% of minSizePx for small characters (punctuation, diacritics)
      final minSmallSize = (minSizePx * 0.5).round().clamp(1, minSizePx);
      var cropIndex = 0;
      for (final cb in candidates) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;
        // At least one dimension must meet minimum size
        if ((cw < minSmallSize || ch < minSmallSize) &&
            (cw < minSizePx && ch < minSizePx)) {
          continue;
        }
        final ar = cw / ch;
        // Allow wider aspect ratios for small characters
        if (ar < 0.2 || ar > 5.0) continue;

        final pdfBounds = MoveBounds(
          left: cb.x0 / renderScale,
          top: pageHeight - cb.y0 / renderScale,
          right: (cb.x1 + 1) / renderScale,
          bottom: pageHeight - (cb.y1 + 1) / renderScale,
        );

        final pixels = _cropAndResize32(
          rendered.gray,
          iW,
          iH,
          cb.x0,
          cb.y0,
          cw,
          ch,
        );
        final features = HogExtractor.extract(pixels, cw, ch);
        final hit = classifier.classifyWithConfidence(features);

        if (debugCropDir != null) {
          final label = hit != null
              ? '${hit.$1}_${(hit.$2 * 100).round()}pct'
              : 'notafig';
          _dumpCropPgm(
            debugCropDir,
            pixels,
            'blob${cropIndex}_${cb.x0}x${cb.y0}_$label.pgm',
          );
        }
        cropIndex++;

        if (hit != null && hit.$2 >= minConfidence) {
          results.add((bounds: pdfBounds, piece: hit.$1, confidence: hit.$2));
        } else {
          results.add((
            bounds: pdfBounds,
            piece: null,
            confidence: hit?.$2 ?? 0.0,
          ));
        }
      }

      results.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      return results;
    } finally {
      if (inverted) {
        for (int y = py0; y < py1; y++) {
          final rowBase = y * iW;
          for (int x = px0; x < px1; x++) {
            final idx = rowBase + x;
            rendered.binary[idx] = rendered.binary[idx] == 0 ? 1 : 0;
            rendered.gray[idx] = 1.0 - rendered.gray[idx];
          }
        }
      }
    }
  }

  /// Scans candidate vertical cut positions within [blob] (25%-75% of its
  /// width) and asks [classifier] to score the piece that each cut would
  /// produce on the left, resizing that sub-crop to 32×32 exactly like the
  /// real classification path does. Returns the cut position with the
  /// highest-confidence figurine hit on either side, or null if nothing
  /// scores above a usable threshold — used when a blob has zero true ink
  /// gap (physically touching glyphs) so no gap/seam method can locate the
  /// boundary, but the classifier itself can recognise where the piece ends.
  static (int, double)? _findBoundaryByClassifier(
    Float32List gray,
    int imgW,
    int imgH,
    ({int x0, int y0, int x1, int y1}) blob,
    int bw,
    int bh,
    FigurineClassifier classifier, {
    double minConfidence = 0.90,
  }) {
    if (bw < 4) return null; // too narrow for a meaningful two-way split
    final minX = (bw * 0.25).round().clamp(1, bw - 1);
    final maxXUpper = bw - 1;
    if (minX + 1 > maxXUpper) return null;
    final maxX = (bw * 0.75).round().clamp(minX + 1, maxXUpper);
    if (minX >= maxX) return null;
    final step = ((maxX - minX) / 20).round().clamp(1, bw);

    int? bestX;
    double bestConf = 0.0;
    for (int x = minX; x <= maxX; x += step) {
      final rightW = bw - x;
      if (x < 1 || rightW < 1) continue;

      final leftPixels = _cropAndResize32(
        gray,
        imgW,
        imgH,
        blob.x0,
        blob.y0,
        x,
        bh,
      );
      final leftHit = classifier.classifyWithConfidence(
        HogExtractor.extract(leftPixels, x, bh),
      );
      if (leftHit != null && leftHit.$2 > bestConf) {
        bestConf = leftHit.$2;
        bestX = x;
      }

      final rightPixels = _cropAndResize32(
        gray,
        imgW,
        imgH,
        blob.x0 + x,
        blob.y0,
        rightW,
        bh,
      );
      final rightHit = classifier.classifyWithConfidence(
        HogExtractor.extract(rightPixels, rightW, bh),
      );
      if (rightHit != null && rightHit.$2 > bestConf) {
        bestConf = rightHit.$2;
        bestX = x;
      }
    }

    if (bestX == null || bestConf < minConfidence) return null;
    return (bestX, bestConf);
  }

  /// Last-resort fallback when no ink-density or seam-based boundary passes
  /// the strict relative-dip threshold (glyphs that physically touch, with
  /// near-zero background separating them). Rather than slicing at blind
  /// uniform grid positions — which can cut a real letter in half or land
  /// exactly on a thin one like "I" and filter it out downstream — each
  /// expected cut position is snapped to the nearest local minimum in the
  /// seam-cost profile within a small search window, so the cut still
  /// respects whatever faint boundary actually exists in the ink.
  static List<({int x0, int y0, int x1, int y1})> _forceSplitByWidth(
    Uint8List binary,
    Float32List gray,
    int imgW,
    int imgH,
    ({int x0, int y0, int x1, int y1}) blob,
    int ch,
    FigurineClassifier classifier,
    String? debugLogFile,
  ) {
    final bw = blob.x1 - blob.x0 + 1;
    final bh = blob.y1 - blob.y0 + 1;
    final expectedCharW = (ch * 0.75).round().clamp(1, bw);
    if (bw <= expectedCharW * 1.5) return [blob]; // already close to one char

    final count = (bw / expectedCharW).round().clamp(2, 100);

    // Physically-touching glyphs have zero true ink gap, so no column-based
    // or seam-based method has anything to detect. When exactly two glyphs
    // are involved (the common case — a figurine piece touching an adjacent
    // rank digit), let the classifier itself find the boundary: scan
    // candidate cut positions and keep the one where either side is
    // recognised as a figurine with the highest confidence. This directly
    // uses the trained model instead of guessing from an expected width,
    // which can slice straight through the piece glyph itself.
    if (count == 2) {
      final classifierCut = _findBoundaryByClassifier(
        gray,
        imgW,
        imgH,
        blob,
        bw,
        bh,
        classifier,
      );
      if (classifierCut != null) {
        _log(
          debugLogFile,
          '[FigurineDetector] classifier-guided split blob[${blob.x0},${blob.y0}] '
          '${bw}x$bh cut=$classifierCut (conf=${classifierCut.$2.toStringAsFixed(2)})',
        );
        final cutX = classifierCut.$1;
        return [
          (x0: blob.x0, y0: blob.y0, x1: blob.x0 + cutX - 1, y1: blob.y1),
          (x0: blob.x0 + cutX, y0: blob.y0, x1: blob.x1, y1: blob.y1),
        ];
      }
    }
    final seamCost = _seamCostProfile(binary, imgW, blob.x0, blob.y0, bw, bh);
    final searchRadius = (expectedCharW * 0.4).round().clamp(1, expectedCharW);

    final cuts = <int>[];
    for (int i = 1; i < count; i++) {
      final ideal = (bw * i / count).round().clamp(0, bw - 1);
      var bestX = ideal;
      var bestCost = seamCost[ideal];
      for (int d = 1; d <= searchRadius; d++) {
        final lo = ideal - d;
        if (lo >= 0 && seamCost[lo] < bestCost) {
          bestCost = seamCost[lo];
          bestX = lo;
        }
        final hi = ideal + d;
        if (hi < bw && seamCost[hi] < bestCost) {
          bestCost = seamCost[hi];
          bestX = hi;
        }
      }
      cuts.add(bestX);
    }
    cuts.sort();
    _log(
      debugLogFile,
      '[FigurineDetector] forceSplit blob[${blob.x0},${blob.y0}] '
      '${bw}x$bh expectedCharW=$expectedCharW count=$count cuts=$cuts',
    );

    final pieces = <({int x0, int y0, int x1, int y1})>[];
    var prevX = 0;
    for (final c in cuts) {
      if (c <= prevX) continue; // skip degenerate/too-close cuts
      pieces.add((x0: blob.x0 + prevX, y0: blob.y0, x1: blob.x0 + c - 1, y1: blob.y1));
      prevX = c;
    }
    pieces.add((x0: blob.x0 + prevX, y0: blob.y0, x1: blob.x1, y1: blob.y1));
    return pieces;
  }

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
      final binary = _binarize(gray, iW, iH, binarizeThreshold);

      // --- 2. Single-pass CCL: find all ink blobs directly ---
      final allBlobs = _connectedBoxes(binary, iW, iH);

      // Board exclusion zones in pixel coordinates.
      final boardPx = boardRects
          .map(
            (b) => (
              x0: (b.left * renderScale).round(),
              y0: ((page.height - b.top) * renderScale).round(),
              x1: (b.right * renderScale).round(),
              y1: ((page.height - b.bottom) * renderScale).round(),
            ),
          )
          .toList();

      final minSizePx = (minGlyphSizePt * renderScale).round();
      int filteredSize = 0,
          filteredAspect = 0,
          filteredBoard = 0,
          classified = 0;

      // Candidate blobs (passed size + aspect + board filters) for debug overlay.
      final candidateBoxes = <({int x0, int y0, int x1, int y1})>[];

      final log = debugLogPath != null ? StringBuffer() : null;
      if (log != null) {
        log.writeln(
          '=== Page ${debugPageNumber ?? '?'} '
          '| ${allBlobs.length} ink blob(s) '
          '| page ${page.width.toStringAsFixed(1)}×${page.height.toStringAsFixed(1)}pt '
          '| renderScale=$renderScale ===',
        );
      }

      // Merge horizontally close blobs that are vertically overlapping (fragments
      // of the same glyph — e.g. counters, dots, serifs separated by CCL).
      final mergeGapPx = (minGlyphSizePt * renderScale * 0.4).round().clamp(
        2,
        8,
      );
      final merged = _mergeNearbyBlobs(allBlobs, mergeGapPx);

      // Expand wide blobs by vertical splitting so each character is processed.
      final candidates = <({int x0, int y0, int x1, int y1})>[];
      for (final cb in merged) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;
        if (cw > ch * maxAspectRatio) {
          candidates.addAll(
            _splitBlobVertically(binary, iW, cb, maxAspectRatio),
          );
        } else {
          candidates.add(cb);
        }
      }

      for (final cb in candidates) {
        final cw = cb.x1 - cb.x0 + 1;
        final ch = cb.y1 - cb.y0 + 1;
        final cLeftPt = cb.x0 / renderScale;
        final cTopPt = page.height - cb.y0 / renderScale;

        // Size gate
        if (cw < minSizePx || ch < minSizePx) {
          filteredSize++;
          log?.writeln(
            '  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
            'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → too_small',
          );
          continue;
        }

        // Aspect ratio gate
        final ar = cw / ch;
        if (ar < 1.0 / maxAspectRatio || ar > maxAspectRatio) {
          filteredAspect++;
          log?.writeln(
            '  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
            'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → bad_aspect(${ar.toStringAsFixed(2)})',
          );
          continue;
        }

        // Board exclusion
        final cx = (cb.x0 + cb.x1) / 2.0;
        final cy = (cb.y0 + cb.y1) / 2.0;
        if (boardPx.any(
          (b) => cx >= b.x0 && cx <= b.x1 && cy >= b.y0 && cy <= b.y1,
        )) {
          filteredBoard++;
          log?.writeln(
            '  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
            'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → in_board',
          );
          continue;
        }

        candidateBoxes.add(cb);

        // --- 3. Classify ---
        final pixels = _cropAndResize32(gray, iW, iH, cb.x0, cb.y0, cw, ch);
        final features = HogExtractor.extract(pixels, cw, ch);
        final hit = classifier.classifyWithConfidence(features);
        if (hit == null) {
          log?.writeln(
            '  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
            'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] → NotAFigurine',
          );
          continue;
        }

        final (piece, confidence) = hit;
        final passes = confidence >= minConfidence;
        final pct = (confidence * 100).toStringAsFixed(0);

        log?.writeln(
          '  blob px[${cb.x0},${cb.y0}] $cw×${ch}px '
          'pt[${cLeftPt.toStringAsFixed(1)},${cTopPt.toStringAsFixed(1)}] '
          '→ $piece $pct%${passes ? ' PASS' : ' skip'}',
        );

        if (verbose) {
          debugPrint(
            '[FigurineDetector] blob $cw×${ch}px'
            ' → $piece $pct%'
            '${passes ? '' : ' (skip)'}',
          );
        }

        if (!passes) continue;

        // Convert pixel bbox → PDF coordinates (Y-axis flip: PDF y=0 at bottom)
        results.add(
          DetectedFigurine(
            bounds: MoveBounds(
              left: cb.x0 / renderScale,
              top: page.height - cb.y0 / renderScale,
              right: (cb.x1 + 1) / renderScale,
              bottom: page.height - (cb.y1 + 1) / renderScale,
            ),
            piece: piece,
            confidence: confidence,
          ),
        );
        classified++;
      }

      if (onWordBoxes != null) {
        onWordBoxes(
          candidateBoxes
              .map(
                (b) => MoveBounds(
                  left: b.x0 / renderScale,
                  top: page.height - b.y0 / renderScale,
                  right: (b.x1 + 1) / renderScale,
                  bottom: page.height - (b.y1 + 1) / renderScale,
                ),
              )
              .toList(),
        );
      }

      if (log != null) {
        File(
          debugLogPath!,
        ).writeAsStringSync(log.toString(), mode: FileMode.append);
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
      g[i] =
          0.299 * bgra[i * 4 + 2] / 255.0 +
          0.587 * bgra[i * 4 + 1] / 255.0 +
          0.114 * bgra[i * 4] / 255.0;
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
    final parent = <int>[0]; // index 0 is a sentinel (no-label)

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
        final left = rx > 0 ? labels[ry * rw + rx - 1] : 0;

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
          bx0[lbl] = gx;
          by0[lbl] = gy;
          bx1[lbl] = gx;
          by1[lbl] = gy;
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
    final sorted = blobs.toList()..sort((a, b) => a.x0.compareTo(b.x0));

    final out = <({int x0, int y0, int x1, int y1})>[];
    var cur = sorted[0];

    for (int i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      final hGap =
          next.x0 - cur.x1 - 1; // pixels between right of cur and left of next
      final vOverlap =
          cur.y1 >= next.y0 && next.y1 >= cur.y0; // vertical bands overlap
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

    final left = (
      x0: blob.x0,
      y0: blob.y0,
      x1: blob.x0 + minRx - 1,
      y1: blob.y1,
    );
    final right = (
      x0: blob.x0 + minRx + 1,
      y0: blob.y0,
      x1: blob.x1,
      y1: blob.y1,
    );

    return [
      ..._splitBlobVertically(binary, iW, left, maxAspectRatio),
      ..._splitBlobVertically(binary, iW, right, maxAspectRatio),
    ];
  }

  static bool _boundsOverlap(MoveBounds a, MoveBounds b) {
    return a.left < b.right &&
        a.right > b.left &&
        a.bottom < b.top &&
        a.top > b.bottom;
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
      debugPrint('[FigurineDetector] failed to write log: $e');
    }
  }

  /// Writes a 32×32 grayscale [pixels] buffer (values 0.0–1.0) as a binary
  /// PGM (P5) file — a trivial uncompressed format viewable with most image
  /// tools (e.g. GIMP, `convert crop.pgm crop.png`) without extra
  /// dependencies. Used to visually inspect what the classifier receives.
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
      debugPrint('[FigurineDetector] failed to dump crop $filename: $e');
    }
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
