import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'chess_piece_classifier.dart';

/// Detects chess board diagrams in PDF pages using ML + FEN validation.
///
/// New algorithm:
///   1. Render page at 144 DPI (2× scale) for better quality.
///   2. Find candidate image regions using text-gap analysis (areas with no charRects).
///   3. For each region:
///        a. Localize exact board boundary using refined SNR (threshold 1.8) within region.
///        b. Extract 64 squares and classify using TFLite model.
///        c. Build FEN from piece classifications.
///        d. Validate FEN with dartchess.
///        e. If valid → confirmed board.
///   4. Convert confirmed boards to split indices and detected FENs.
class BoardDetector {
  static const _scale = 2.0; // 144 DPI (double resolution)
  static const _snrThresholdForLocalization = 1.8; // lower than absolute threshold

  static Future<({List<int> splitIndices, bool topOfPageBoardDetected, List<String?> detectedFens})>
  detectBoards(PdfPage page, List<PdfRect> charRects) async {
    final iW = (page.width * _scale).round();
    final iH = (page.height * _scale).round();

    debugPrint('[BoardDetector] rendering full page $iW×$iH px…');
    final image = await page.render(
      x: 0, y: 0,
      width: iW, height: iH,
      fullWidth: iW.toDouble(), fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) {
      debugPrint('[BoardDetector] render returned null');
      return (
        splitIndices: const <int>[],
        topOfPageBoardDetected: false,
        detectedFens: const <String?>[],
      );
    }

    try {
      final gray = _toGray(image.pixels, iW, iH);

      // Precompute gradients.
      final dH = Float32List(iW * iH); // horizontal gradient
      final dV = Float32List(iW * iH); // vertical gradient
      for (int y = 0; y < iH; y++) {
        for (int x = 1; x < iW; x++) {
          dH[y * iW + x] = (gray[y * iW + x] - gray[y * iW + x - 1]).abs();
        }
      }
      for (int y = 1; y < iH; y++) {
        for (int x = 0; x < iW; x++) {
          dV[y * iW + x] = (gray[y * iW + x] - gray[(y - 1) * iW + x]).abs();
        }
      }

      // Precompute cumulative structures for fast SNR queries.
      final dHcol = Float64List((iH + 1) * iW);
      for (int y = 0; y < iH; y++) {
        for (int x = 0; x < iW; x++) {
          dHcol[(y + 1) * iW + x] = dHcol[y * iW + x] + dH[y * iW + x];
        }
      }

      final w1 = iW + 1;
      final dVrow = Float64List(iH * w1);
      for (int y = 0; y < iH; y++) {
        for (int x = 0; x < iW; x++) {
          dVrow[y * w1 + x + 1] = dVrow[y * w1 + x] + dV[y * iW + x];
        }
      }

      final dHsat = _sat2d(dH, iW, iH);
      final dVsat = _sat2d(dV, iW, iH);

      // Step 1: Find candidate image regions (text-gap analysis).
      final imageRegions = _findImageRegions(charRects, page.width, page.height, _scale);
      debugPrint('[BoardDetector] found ${imageRegions.length} candidate image region(s)');

      // Step 2: Localize boards within each region and classify.
      final boards = <({int x, int y, int s, double score, String? fen})>[];
      final classifier = await ChessPieceClassifier.load();

      for (final region in imageRegions) {
        final board = await _localizeAndClassifyBoard(
          region, dHcol, dVrow, dHsat, dVsat, iW, iH, w1,
          gray, _scale, classifier,
        );
        if (board != null) boards.add(board);
      }

      classifier?.dispose();

      debugPrint('[BoardDetector] ${boards.length} board(s) confirmed:');
      for (final b in boards) {
        debugPrint(
          '  x=${b.x} y=${b.y}  squarePx=${b.s}  boardPx=${b.s * 8}  SNR=${b.score.toStringAsFixed(2)}  FEN=${b.fen ?? "not detected"}',
        );
      }

      final splits = _toSplits(boards, charRects, page.height);
      final top = _isTopOfPage(boards, charRects, page.height);
      final detectedFens = boards.map((b) => b.fen).toList();

      debugPrint('[BoardDetector] splits=$splits  topBoard=$top  fens=$detectedFens');
      return (
        splitIndices: splits,
        topOfPageBoardDetected: top,
        detectedFens: detectedFens,
      );
    } finally {
      image.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Step 1: Text-gap analysis to find image regions

  static List<({int x, int y, int w, int h})> _findImageRegions(
    List<PdfRect> charRects, double pageW, double pageH, double scale,
  ) {
    final iW = (pageW * scale).round();
    final iH = (pageH * scale).round();
    final minBoardPx = 80; // 10px/sq × 8 sq minimum

    // Build text row coverage: for each y, is there any text?
    final rowHasText = List<bool>.filled(iH, false);
    for (final rect in charRects) {
      if (!rect.isNotEmpty) continue;
      // Convert PDF coords (Y-up) to pixel coords (Y-down).
      final pixelTop = (pageH - rect.bottom) * scale;
      final pixelBottom = (pageH - rect.top) * scale;
      final yStart = math.max(0, pixelTop.round());
      final yEnd = math.min(iH, pixelBottom.round());
      for (int y = yStart; y < yEnd; y++) {
        rowHasText[y] = true;
      }
    }

    // Find vertical runs with no text (potential image rows).
    final regions = <({int x, int y, int w, int h})>[];
    int noTextStart = -1;
    for (int y = 0; y < iH; y++) {
      if (!rowHasText[y]) {
        if (noTextStart < 0) noTextStart = y;
      } else {
        if (noTextStart >= 0) {
          final noTextHeight = y - noTextStart;
          if (noTextHeight >= minBoardPx) {
            // Found a potential image region row range.
            _addImageRegionsInRange(
              regions, rowHasText, iW, noTextStart, y, minBoardPx,
            );
          }
          noTextStart = -1;
        }
      }
    }
    // Handle end-of-page run.
    if (noTextStart >= 0) {
      final noTextHeight = iH - noTextStart;
      if (noTextHeight >= minBoardPx) {
        _addImageRegionsInRange(
          regions, rowHasText, iW, noTextStart, iH, minBoardPx,
        );
      }
    }

    return regions;
  }

  static void _addImageRegionsInRange(
    List<({int x, int y, int w, int h})> regions,
    List<bool> rowHasText, int iW, int yStart, int yEnd, int minBoardPx,
  ) {
    // Within [yStart, yEnd), find column ranges with no text.
    // For simplicity, assume the entire row range is one region.
    // (A more sophisticated approach would find x-ranges too.)
    final h = yEnd - yStart;
    if (h >= minBoardPx && h <= iW) {
      // Region is roughly square-ish.
      // Use full width; a board detector will localize within this region.
      regions.add((x: 0, y: yStart, w: iW, h: h));
    }
  }

  // ---------------------------------------------------------------------------
  // Step 2: Localize board within a region and classify pieces

  static Future<({int x, int y, int s, double score, String? fen})?> _localizeAndClassifyBoard(
    ({int x, int y, int w, int h}) region,
    Float64List dHcol, Float64List dVrow,
    Float64List dHsat, Float64List dVsat,
    int iW, int iH, int w1,
    Float32List gray, double scale, ChessPieceClassifier? classifier,
  ) async {
    // Run SNR scan only within the region.
    final board = _localizeBoard(
      region, dHcol, dVrow, dHsat, dVsat, iW, iH, w1,
    );

    if (board == null) return null; // No grid found in this region.

    // Extract 64 squares and classify pieces.
    String? fen;
    try {
      final squareImages = _extractSquares(gray, iW, board.x, board.y, board.s);
      if (classifier != null) {
        final labels = classifier.classify64Squares(squareImages);
        if (labels != null) {
          fen = _buildAndValidateFen(labels);
        }
      }
    } catch (e) {
      debugPrint('[BoardDetector] failed to classify board at (${board.x}, ${board.y}): $e');
    }

    return (x: board.x, y: board.y, s: board.s, score: board.score, fen: fen);
  }

  // Localize board within region using SNR scan at lower threshold.
  static ({int x, int y, int s, double score})? _localizeBoard(
    ({int x, int y, int w, int h}) region,
    Float64List dHcol, Float64List dVrow,
    Float64List dHsat, Float64List dVsat,
    int iW, int iH, int w1,
  ) {
    ({int x, int y, int s, double score})? best;
    double bestScore = _snrThresholdForLocalization;

    final squareSizes = [10, 13, 17, 22, 28, 36, 46];
    for (final s in squareSizes) {
      final bp = s * 8;
      if (bp > region.w || bp > region.h) continue;

      final step = math.max(2, s ~/ 3);
      final xStart = region.x;
      final xEnd = math.min(region.x + region.w - bp, iW - bp);
      final yStart = region.y;
      final yEnd = math.min(region.y + region.h - bp, iH - bp);

      for (int y0 = yStart; y0 < yEnd; y0 += step) {
        for (int x0 = xStart; x0 < xEnd; x0 += step) {
          final sc = _snr(dHcol, dVrow, dHsat, dVsat, iW, w1, x0, y0, s, bp);
          if (sc > bestScore) {
            bestScore = sc;
            best = (x: x0, y: y0, s: s, score: sc);
          }
        }
      }
    }

    return best;
  }

  /// SNR score calculation (same as original).
  static double _snr(
    Float64List dHcol, Float64List dVrow,
    Float64List dHsat, Float64List dVsat,
    int iW, int w1, int x0, int y0, int s, int bp,
  ) {
    double vGrid = 0;
    for (int k = 1; k <= 7; k++) {
      final x = x0 + k * s;
      vGrid += dHcol[(y0 + bp) * iW + x] - dHcol[y0 * iW + x];
    }
    final dHTot = _satRect(dHsat, w1, y0, x0, y0 + bp, x0 + bp);
    final vBg = dHTot - vGrid;
    final vSNR = (vGrid / 7) / (vBg / (bp * (bp - 7)) * bp + 1e-6);

    double hGrid = 0;
    for (int k = 1; k <= 7; k++) {
      final y = y0 + k * s;
      hGrid += dVrow[y * w1 + x0 + bp] - dVrow[y * w1 + x0];
    }
    final dVTot = _satRect(dVsat, w1, y0, x0, y0 + bp, x0 + bp);
    final hBg = dVTot - hGrid;
    final hSNR = (hGrid / 7) / (hBg / (bp * (bp - 7)) * bp + 1e-6);

    return math.min(vSNR, hSNR);
  }

  // ---------------------------------------------------------------------------
  // Step 3: Extract and classify squares

  static List<Float32List> _extractSquares(
    Float32List gray, int iW, int bx, int by, int squarePx,
  ) {
    const modelInputSize = 64;
    final squares = <Float32List>[];

    for (int rank = 0; rank < 8; rank++) {
      for (int file = 0; file < 8; file++) {
        final x0 = bx + file * squarePx;
        final y0 = by + rank * squarePx;

        // Crop square and resize to 64x64.
        final square = Float32List(modelInputSize * modelInputSize * 3);
        int idx = 0;
        for (int yy = 0; yy < modelInputSize; yy++) {
          for (int xx = 0; xx < modelInputSize; xx++) {
            final sx = x0 + (xx * squarePx) ~/ modelInputSize;
            final sy = y0 + (yy * squarePx) ~/ modelInputSize;
            final grayVal = gray[math.min(sy, iW - 1) * iW + math.min(sx, iW - 1)];
            // RGB from grayscale.
            square[idx++] = grayVal; // R
            square[idx++] = grayVal; // G
            square[idx++] = grayVal; // B
          }
        }
        squares.add(square);
      }
    }

    return squares;
  }

  // Build FEN from piece classifications and validate.
  static String? _buildAndValidateFen(List<String> labels) {
    if (labels.length != 64) return null;

    // Construct 8×8 board. labels[0] = a8, labels[63] = h1 (white on bottom).
    const pieceMap = {
      'empty': ' ',
      'wP': 'P', 'wN': 'N', 'wB': 'B', 'wR': 'R', 'wQ': 'Q', 'wK': 'K',
      'bP': 'p', 'bN': 'n', 'bB': 'b', 'bR': 'r', 'bQ': 'q', 'bK': 'k',
    };

    final fenRows = <String>[];
    for (int rank = 7; rank >= 0; rank--) {
      int empty = 0;
      String row = '';
      for (int file = 0; file < 8; file++) {
        final idx = rank * 8 + file;
        final piece = pieceMap[labels[idx]] ?? ' ';
        if (piece == ' ') {
          empty++;
        } else {
          if (empty > 0) {
            row += '$empty';
            empty = 0;
          }
          row += piece;
        }
      }
      if (empty > 0) row += '$empty';
      fenRows.add(row);
    }

    final fen = '${fenRows.join('/')} w - - 0 1';

    // Validate with dartchess.
    try {
      final setup = dc.Setup.parseFen(fen);
      dc.Chess.fromSetup(setup);
      return fen;
    } catch (e) {
      debugPrint('[BoardDetector] FEN validation failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers: Gradient, summed-area tables

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4    ] / 255.0;
    }
    return g;
  }

  static Float64List _sat2d(Float32List arr, int w, int h) {
    final w1 = w + 1;
    final sat = Float64List((h + 1) * w1);
    for (int y = 0; y < h; y++) {
      double row = 0;
      for (int x = 0; x < w; x++) {
        row += arr[y * w + x];
        sat[(y + 1) * w1 + (x + 1)] = row + sat[y * w1 + (x + 1)];
      }
    }
    return sat;
  }

  static double _satRect(
    Float64List sat, int w1, int y0, int x0, int y1, int x1) {
    return sat[y1 * w1 + x1] - sat[y0 * w1 + x1]
         - sat[y1 * w1 + x0] + sat[y0 * w1 + x0];
  }

  // ---------------------------------------------------------------------------
  // Board positions → char-index splits (keep existing logic)

  static List<int> _toSplits(
    List<({int x, int y, int s, double score, String? fen})> boards,
    List<PdfRect> charRects, double pageH,
  ) {
    final splits = <int>[];
    for (final b in boards) {
      final boardBottomPdf = pageH - (b.y + b.s * 8) / _scale;
      int? first;
      for (int i = 0; i < charRects.length; i++) {
        final r = charRects[i];
        if (!r.isNotEmpty) continue;
        if ((r.top + r.bottom) / 2 < boardBottomPdf) {
          if (first == null || i < first) first = i;
        }
      }
      if (first != null && first > 0) splits.add(first);
    }
    splits.sort();
    return splits;
  }

  static bool _isTopOfPage(
    List<({int x, int y, int s, double score, String? fen})> boards,
    List<PdfRect> charRects, double pageH,
  ) {
    for (final b in boards) {
      final boardTopPdf = pageH - b.y / _scale;
      final hasAbove = charRects.any(
        (r) => r.isNotEmpty && (r.top + r.bottom) / 2 > boardTopPdf,
      );
      if (!hasAbove) return true;
    }
    return false;
  }
}
