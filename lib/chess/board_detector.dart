import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'chess_piece_classifier.dart';

/// Detects chess board diagrams in PDF pages.
///
/// Algorithm:
///   1. Render page at 144 DPI.
///   2. For each row, compute the longest contiguous run of high-contrast pixels
///      in the vertical gradient → rows with long runs are drawn horizontal lines.
///      Same for columns / horizontal gradient → drawn vertical lines.
///   3. Among those line positions, find 9 evenly-spaced horizontal lines and
///      9 evenly-spaced vertical lines (= the chess board grid).
///   4. The spacing must match between horizontal and vertical sets (square board).
///   5. Extract 64 squares, classify with TFLite, validate FEN.
class BoardDetector {
  static const _scale = 2.0; // 144 DPI

  // A "line pixel" must have at least this much contrast with its neighbour.
  static const _linePixelThreshold = 0.10;

  // A row/column must have a contiguous run this long to count as a drawn line.
  static const _minLineRunPx = 50;

  // Minimum gap between two distinct line positions (handles thick lines).
  static const _minLineGapPx = 4;

  // Minimum / maximum square size accepted (in pixels at 144 DPI).
  static const _minSquarePx = 20; // 160 px board ≈ 1.1 in
  static const _maxSquarePx = 100; // 800 px board ≈ 5.6 in

  // Max deviation from square (|h-w|/max).
  static const _maxSquareness = 0.15;

  // Fraction of pixels along each side that must show gradient for rectangle verification.
  static const _minSideCoverage = 0.35;

  // ─────────────────────────────────────────────────────────────────────────
  // Public entry point

  static Future<({List<int> splitIndices, bool topOfPageBoardDetected, List<String?> detectedFens})>
  detectBoards(PdfPage page, List<PdfRect> charRects) async {
    final iW = (page.width * _scale).round();
    final iH = (page.height * _scale).round();

    debugPrint('[BoardDetector] rendering $iW×$iH px…');
    final image = await page.render(
      x: 0, y: 0,
      width: iW, height: iH,
      fullWidth: iW.toDouble(), fullHeight: iH.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) {
      return (splitIndices: const <int>[], topOfPageBoardDetected: false, detectedFens: const <String?>[]);
    }

    try {
      final gray = _toGray(image.pixels, iW, iH);

      // Vertical gradient dV[y,x] = |gray[y,x] - gray[y-1,x]|.
      // Horizontal gradient dH[y,x] = |gray[y,x] - gray[y,x-1]|.
      final dV = Float32List(iW * iH);
      for (int y = 1; y < iH; y++) {
        for (int x = 0; x < iW; x++) {
          dV[y * iW + x] = (gray[y * iW + x] - gray[(y - 1) * iW + x]).abs();
        }
      }
      final dH = Float32List(iW * iH);
      for (int y = 0; y < iH; y++) {
        for (int x = 1; x < iW; x++) {
          dH[y * iW + x] = (gray[y * iW + x] - gray[y * iW + x - 1]).abs();
        }
      }

      // For each row: longest contiguous run where dV > threshold.
      // A long run means a drawn horizontal line spans many pixels.
      final hRun = _maxRunPerRow(dV, iW, iH);

      // For each column: longest contiguous run where dH > threshold.
      final vRun = _maxRunPerCol(dH, iW, iH);

      // Extract positions of drawn lines.
      final hLines = _linePositions(hRun, iH);
      final vLines = _linePositions(vRun, iW);

      debugPrint('[BoardDetector] drawn hLines=${hLines.length}  vLines=${vLines.length}');

      final classifier = await ChessPieceClassifier.load();

      final boards = <({int x, int y, int s, String fen})>[];

      // Try every pair of hLines × vLines whose span/8 gives a valid square size.
      // Only the outer board borders need to be detected; FEN validation is the gate.
      for (int hi = 0; hi < hLines.length; hi++) {
        for (int hj = hi + 1; hj < hLines.length; hj++) {
          final hSpan = hLines[hj] - hLines[hi];
          final hS = hSpan / 8.0;
          if (hS < _minSquarePx || hS > _maxSquarePx) continue;

          for (int vi = 0; vi < vLines.length; vi++) {
            for (int vj = vi + 1; vj < vLines.length; vj++) {
              final vSpan = vLines[vj] - vLines[vi];
              final vS = vSpan / 8.0;
              if (vS < _minSquarePx || vS > _maxSquarePx) continue;

              final squareness = (hS - vS).abs() / math.max(hS, vS);
              if (squareness > _maxSquareness) continue;

              final s = ((hS + vS) / 2).round();
              final x0 = vLines[vi];
              final y0 = hLines[hi];

              // Skip if this region overlaps an already-confirmed board.
              if (boards.any((b) => (b.x - x0).abs() < s ~/ 2 && (b.y - y0).abs() < s ~/ 2)) continue;

              // Verify all 4 sides of the rectangle are actually drawn in the image.
              final cTop   = _rowCoverage(dV, iW, hLines[hi], vLines[vi], vLines[vj]);
              final cBot   = _rowCoverage(dV, iW, hLines[hj], vLines[vi], vLines[vj]);
              final cLeft  = _colCoverage(dH, iW, vLines[vi], hLines[hi], hLines[hj]);
              final cRight = _colCoverage(dH, iW, vLines[vj], hLines[hi], hLines[hj]);
              debugPrint('[BoardDetector] rect x=$x0 y=$y0 s=$s '
                  'cov top=${cTop.toStringAsFixed(2)} bot=${cBot.toStringAsFixed(2)} '
                  'left=${cLeft.toStringAsFixed(2)} right=${cRight.toStringAsFixed(2)}');
              if (cTop < _minSideCoverage || cBot < _minSideCoverage ||
                  cLeft < _minSideCoverage || cRight < _minSideCoverage) { continue; }

              debugPrint('[BoardDetector] candidate x=$x0 y=$y0 s=$s (hS=${hS.toStringAsFixed(1)} vS=${vS.toStringAsFixed(1)})');

              try {
                final squareImages = _extractSquares(gray, iW, iH, x0, y0, s);
                final labels = classifier.classify64Squares(squareImages);
                if (labels != null) {
                  final fen = _buildFen(labels);
                  if (fen != null) {
                    debugPrint('[BoardDetector] confirmed board x=$x0 y=$y0 s=$s FEN=$fen');
                    boards.add((x: x0, y: y0, s: s, fen: fen));
                  }
                }
              } catch (e) {
                debugPrint('[BoardDetector] classification error: $e');
              }
            }
          }
        }
      }

      classifier.dispose();

      debugPrint('[BoardDetector] ${boards.length} board(s) confirmed');

      final splits = _toSplits(boards, charRects, page.height);
      final top = _isTopOfPage(boards, charRects, page.height);
      final detectedFens = boards.map((b) => b.fen as String?).toList();

      debugPrint('[BoardDetector] splits=$splits  topBoard=$top  fens=$detectedFens');
      return (splitIndices: splits, topOfPageBoardDetected: top, detectedFens: detectedFens);
    } finally {
      image.dispose();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Line detection

  /// For each row y, compute the longest contiguous run of pixels where
  /// dV[y,x] > [_linePixelThreshold].  A long run = a drawn horizontal line.
  static List<int> _maxRunPerRow(Float32List dV, int iW, int iH) {
    final result = List<int>.filled(iH, 0);
    for (int y = 0; y < iH; y++) {
      int maxRun = 0, run = 0;
      for (int x = 0; x < iW; x++) {
        if (dV[y * iW + x] > _linePixelThreshold) {
          run++;
          if (run > maxRun) maxRun = run;
        } else {
          run = 0;
        }
      }
      result[y] = maxRun;
    }
    return result;
  }

  /// For each column x, compute the longest contiguous run of pixels where
  /// dH[y,x] > [_linePixelThreshold].  A long run = a drawn vertical line.
  static List<int> _maxRunPerCol(Float32List dH, int iW, int iH) {
    final result = List<int>.filled(iW, 0);
    for (int x = 0; x < iW; x++) {
      int maxRun = 0, run = 0;
      for (int y = 0; y < iH; y++) {
        if (dH[y * iW + x] > _linePixelThreshold) {
          run++;
          if (run > maxRun) maxRun = run;
        } else {
          run = 0;
        }
      }
      result[x] = maxRun;
    }
    return result;
  }

  /// From a run-length array, extract positions of drawn lines: local maxima
  /// above [_minLineRunPx], separated by at least [_minLineGapPx].
  static List<int> _linePositions(List<int> runs, int size) {
    final lines = <int>[];
    for (int i = 1; i < size - 1; i++) {
      if (runs[i] < _minLineRunPx) continue;
      if (runs[i] < runs[i - 1] || runs[i] < runs[i + 1]) continue;
      if (lines.isNotEmpty && i - lines.last < _minLineGapPx) {
        if (runs[i] > runs[lines.last]) lines[lines.length - 1] = i;
      } else {
        lines.add(i);
      }
    }
    return lines;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Rectangle verification helpers

  /// Fraction of pixels in row [y] over [x1..x2] that have dV > threshold.
  static double _rowCoverage(Float32List dV, int iW, int y, int x1, int x2) {
    if (x2 <= x1) return 0;
    int count = 0;
    for (int x = x1; x <= x2; x++) {
      if (dV[y * iW + x] > _linePixelThreshold) count++;
    }
    return count / (x2 - x1 + 1);
  }

  /// Fraction of pixels in column [x] over [y1..y2] that have dH > threshold.
  static double _colCoverage(Float32List dH, int iW, int x, int y1, int y2) {
    if (y2 <= y1) return 0;
    int count = 0;
    for (int y = y1; y <= y2; y++) {
      if (dH[y * iW + x] > _linePixelThreshold) count++;
    }
    return count / (y2 - y1 + 1);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Square extraction and FEN building

  static List<Float32List> _extractSquares(
    Float32List gray, int iW, int iH, int bx, int by, int squarePx,
  ) {
    const modelSize = 64;
    final squares = <Float32List>[];
    for (int rank = 0; rank < 8; rank++) {
      for (int file = 0; file < 8; file++) {
        final x0 = bx + file * squarePx;
        final y0 = by + rank * squarePx;
        final sq = Float32List(modelSize * modelSize * 3);
        int idx = 0;
        for (int yy = 0; yy < modelSize; yy++) {
          for (int xx = 0; xx < modelSize; xx++) {
            final sx = math.min(x0 + (xx * squarePx) ~/ modelSize, iW - 1);
            final sy = math.min(y0 + (yy * squarePx) ~/ modelSize, iH - 1);
            final v = gray[sy * iW + sx];
            sq[idx++] = v; sq[idx++] = v; sq[idx++] = v;
          }
        }
        squares.add(sq);
      }
    }
    return squares;
  }

  /// Build a FEN string from classifier labels. Returns it even if the position
  /// is illegal — the user can correct it manually in the UI.
  static String? _buildFen(List<String> labels) {
    if (labels.length != 64) return null;
    const pieceMap = {
      'empty': ' ', 'wP': 'P', 'wN': 'N', 'wB': 'B', 'wR': 'R', 'wQ': 'Q', 'wK': 'K',
      'bP': 'p', 'bN': 'n', 'bB': 'b', 'bR': 'r', 'bQ': 'q', 'bK': 'k',
    };
    final fenRows = <String>[];
    for (int rank = 7; rank >= 0; rank--) {
      int empty = 0; String row = '';
      for (int file = 0; file < 8; file++) {
        final piece = pieceMap[labels[rank * 8 + file]] ?? ' ';
        if (piece == ' ') { empty++; }
        else { if (empty > 0) { row += '$empty'; empty = 0; } row += piece; }
      }
      if (empty > 0) row += '$empty';
      fenRows.add(row);
    }
    final fen = '${fenRows.join('/')} w - - 0 1';
    debugPrint('[BoardDetector] FEN: $fen');
    final labelCounts = <String, int>{};
    for (final l in labels) { labelCounts[l] = (labelCounts[l] ?? 0) + 1; }
    debugPrint('[BoardDetector] label counts: $labelCounts');
    try {
      dc.Chess.fromSetup(dc.Setup.parseFen(fen));
    } catch (e) {
      debugPrint('[BoardDetector] FEN is illegal (user can correct): $e');
    }
    return fen;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers

  static Float32List _toGray(Uint8List bgra, int w, int h) {
    final g = Float32List(w * h);
    for (int i = 0; i < w * h; i++) {
      g[i] = 0.299 * bgra[i * 4 + 2] / 255.0
           + 0.587 * bgra[i * 4 + 1] / 255.0
           + 0.114 * bgra[i * 4    ] / 255.0;
    }
    return g;
  }

  static List<int> _toSplits(
    List<({int x, int y, int s, String fen})> boards,
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
    List<({int x, int y, int s, String fen})> boards,
    List<PdfRect> charRects, double pageH,
  ) {
    for (final b in boards) {
      final boardTopPdf = pageH - b.y / _scale;
      if (!charRects.any((r) => r.isNotEmpty && (r.top + r.bottom) / 2 > boardTopPdf)) {
        return true;
      }
    }
    return false;
  }
}
