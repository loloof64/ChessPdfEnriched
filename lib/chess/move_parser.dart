import 'package:dartchess/dartchess.dart' as dc;
import 'package:pdfrx/pdfrx.dart';

import 'models.dart';

/// Parses chess moves from a PDF page's raw text.
///
/// Starting position detection (in priority order):
///   1. Forced FEN — caller supplies it (e.g. user entered it manually).
///   2. PGN [FEN "…"] tag together with [SetUp "1"] — the canonical way to
///      signal a custom starting position in PGN files.
///   3. Bare FEN string detected anywhere in the text.
///   4. Inherited FEN from the previous page (game continuation heuristic).
///   5. Standard starting position.
///
/// Diagram detection (→ [FenSource.suspectedDiagram]):
///   When none of the above provides a FEN, the page starts a new game
///   (first move number = 1), AND the top third of the page has very few
///   text characters — suggesting a board diagram image occupies that area.
///   In this case the parser still uses the standard FEN but marks the
///   analysis so the UI can warn the user and offer manual FEN entry.
///
/// Notation support:
///   - Standard algebraic notation
///   - Figurine notation (♔♕♖♗♘♙ / ♚♛♜♝♞♟)
///   - {Brace comments}, (parenthetical variations), NAG codes ($n) — skipped
class MoveParser {
  static const _standardFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  // --------------------------------------------------------------------------
  // Figurine map

  static const _figurineMap = {
    '♔': 'K', '♕': 'Q', '♖': 'R', '♗': 'B', '♘': 'N', '♙': '',
    '♚': 'K', '♛': 'Q', '♜': 'R', '♝': 'B', '♞': 'N', '♟': '',
  };

  static String _normaliseFigurines(String token) {
    var s = token;
    for (final entry in _figurineMap.entries) {
      s = s.replaceAll(entry.key, entry.value);
    }
    return s;
  }

  // --------------------------------------------------------------------------
  // FEN detection

  // PGN standard: [SetUp "1"] + [FEN "…"] mark a custom starting position.
  static final _pgnFenTagRegex = RegExp(
    r'\[FEN\s+"([^"]+)"\]',
    caseSensitive: false,
  );
  static final _pgnSetupTagRegex = RegExp(
    r'\[SetUp\s+"1"\]',
    caseSensitive: false,
  );

  // Plain-text game headers that chess books typically write above or below a
  // starting-position diagram.  Common forms:
  //   "Fischer - Korchnoi"          (player names separated by " - " or " vs ")
  //   "London 1957"                  (venue / year)
  //   "London 1957, Round 3"
  // We match a line that looks like "Name - Name" (at least two capitalised
  // words with a separator), optionally followed by a location/year line.
  static final _plainHeaderRegex = RegExp(
    r'[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ][a-zA-Zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+\s+'
    r'(?:-|vs\.?)\s+'
    r'[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ][a-zA-Zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+',
  );

  // Bare FEN string anywhere in the text (last resort).
  static final _bareFenRegex = RegExp(
    r'[rnbqkpRNBQKP1-8]{1,8}(?:/[rnbqkpRNBQKP1-8]{1,8}){7}'
    r'\s+[wb]\s+[KQkq-]+\s+(?:[a-h][36]|-)\s+\d+\s+\d+',
  );

  /// Try to extract a starting FEN from the page text.
  /// Returns `(fen, source)` where source is [FenSource.detectedInText] on
  /// success, or `null` if none was found.
  static (String, FenSource)? _detectFenInText(String text) {
    // Priority 1 – PGN [SetUp "1"] + [FEN "…"] tags.
    if (_pgnSetupTagRegex.hasMatch(text)) {
      final m = _pgnFenTagRegex.firstMatch(text);
      if (m != null) {
        return (m.group(1)!.trim(), FenSource.detectedInText);
      }
    }

    // Priority 2 – standalone [FEN "…"] tag (SetUp missing but FEN present).
    final pgnFenMatch = _pgnFenTagRegex.firstMatch(text);
    if (pgnFenMatch != null) {
      return (pgnFenMatch.group(1)!.trim(), FenSource.detectedInText);
    }

    // Priority 3 – bare FEN string.
    final bareMatch = _bareFenRegex.firstMatch(text);
    if (bareMatch != null) {
      return (
        bareMatch.group(0)!.replaceAll(RegExp(r'\s+'), ' '),
        FenSource.detectedInText,
      );
    }

    return null;
  }

  // --------------------------------------------------------------------------
  // Diagram detection

  /// Returns true when the page looks like it starts with a board-diagram
  /// image — i.e. the top third of the page has very few text characters.
  ///
  /// [charRects] are in PDF coordinates (origin bottom-left, y up).
  /// [pageHeight] is the page height in the same unit.
  static bool _suspectDiagram({
    required List<PdfRect> charRects,
    required double pageHeight,
    required bool newGameStartsHere,
    required bool hasGameHeader,
  }) {
    // Only flag when a new game is starting (move 1) or game headers are seen.
    if (!newGameStartsHere && !hasGameHeader) return false;

    // Count non-whitespace characters whose top is in the upper third.
    final upperThreshold = pageHeight * (2 / 3);
    int charsInUpperThird = 0;
    for (final r in charRects) {
      if (r.isNotEmpty && r.top > upperThreshold) charsInUpperThird++;
    }

    // If the upper third has very few text characters, it's likely an image.
    return charsInUpperThird < 8;
  }

  // --------------------------------------------------------------------------
  // Public API

  /// Parse [rawText] into a [PageAnalysis].
  ///
  /// - [pageHeight]: height of the PDF page in points (needed for diagram
  ///   detection).  Pass 0 to skip diagram detection.
  /// - [inheritedFen]: FEN from the last move of the previous page, used when
  ///   this page continues a game (first move number > 1).
  /// - [forcedFen]: user-supplied FEN that overrides everything.
  static PageAnalysis parse(
    PdfPageRawText rawText,
    double pageHeight, {
    String? inheritedFen,
    String? forcedFen,
  }) {
    final fullText = rawText.fullText;
    final charRects = rawText.charRects;

    // ------------------------------------------------------------------
    // 1. Determine starting position.

    String startFen;
    FenSource fenSource;

    if (forcedFen != null) {
      startFen = forcedFen;
      fenSource = FenSource.userProvided;
    } else {
      final detected = _detectFenInText(fullText);
      if (detected != null) {
        (startFen, fenSource) = detected;
      } else if (inheritedFen != null) {
        startFen = inheritedFen;
        fenSource = FenSource.inheritedFromPreviousPage;
      } else {
        startFen = _standardFen;
        fenSource = FenSource.standard;
      }
    }

    dc.Position position;
    try {
      position = dc.Chess.fromSetup(dc.Setup.parseFen(startFen));
    } catch (_) {
      position = dc.Chess.initial;
      startFen = _standardFen;
      fenSource = FenSource.standard;
    }

    // ------------------------------------------------------------------
    // 2. Tokenise, skipping comments and variations.

    final tokens = _tokenise(fullText);

    // ------------------------------------------------------------------
    // 3. Parse chess moves.

    final moves = <CachedMove>[];
    int? currentMoveNum;
    bool expectBlack = false;
    int? firstMoveNumber;

    for (final tok in tokens) {
      final raw = tok.text;

      if (raw == '1-0' || raw == '0-1' || raw == '1/2-1/2' || raw == '*') {
        break;
      }

      final numMatch = RegExp(r'^(\d+)(\.+)$').firstMatch(raw);
      if (numMatch != null) {
        currentMoveNum = int.parse(numMatch.group(1)!);
        firstMoveNumber ??= currentMoveNum;
        expectBlack = numMatch.group(2)!.length > 1;
        continue;
      }

      if (currentMoveNum == null) continue;

      final move = position.parseSan(_normaliseFigurines(raw));
      if (move == null) continue;

      final fenBefore = position.fen;
      final (newPosition, san) = position.makeSan(move);
      final fenAfter = newPosition.fen;
      final bounds = _computeBounds(charRects, tok.start, tok.end);

      moves.add(
        CachedMove(
          moveNumber: currentMoveNum,
          isBlack: expectBlack,
          san: san,
          rawToken: raw,
          fenBefore: fenBefore,
          fenAfter: fenAfter,
          bounds: bounds,
        ),
      );

      position = newPosition;
      expectBlack = !expectBlack;
      if (!expectBlack) currentMoveNum++;
    }

    // ------------------------------------------------------------------
    // 4. Upgrade to suspectedDiagram if conditions are met.

    if (fenSource == FenSource.standard && pageHeight > 0) {
      final newGameStartsHere = firstMoveNumber == 1;
      final hasGameHeader = _plainHeaderRegex.hasMatch(fullText);
      if (_suspectDiagram(
        charRects: charRects,
        pageHeight: pageHeight,
        newGameStartsHere: newGameStartsHere,
        hasGameHeader: hasGameHeader,
      )) {
        fenSource = FenSource.suspectedDiagram;
      }
    }

    return PageAnalysis(
      startFen: startFen,
      fenSource: fenSource,
      moves: moves,
    );
  }

  // --------------------------------------------------------------------------
  // Helpers

  static List<_Token> _tokenise(String text) {
    final result = <_Token>[];
    int i = 0;
    int braceDepth = 0;
    int parenDepth = 0;

    while (i < text.length) {
      final c = text[i];

      if (c == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (c == '}') {
        if (braceDepth > 0) braceDepth--;
        i++;
        continue;
      }
      if (braceDepth > 0) {
        i++;
        continue;
      }

      if (c == '(') {
        parenDepth++;
        i++;
        continue;
      }
      if (c == ')') {
        if (parenDepth > 0) parenDepth--;
        i++;
        continue;
      }
      if (parenDepth > 0) {
        i++;
        continue;
      }

      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        i++;
        continue;
      }

      // Skip NAG codes: $1, $12 …
      if (c == '\$') {
        i++;
        while (i < text.length && _isDigit(text[i])) {
          i++;
        }
        continue;
      }

      // Collect a non-whitespace token.
      final start = i;
      while (i < text.length) {
        final ch = text[i];
        if (ch == ' ' ||
            ch == '\n' ||
            ch == '\r' ||
            ch == '\t' ||
            ch == '(' ||
            ch == ')' ||
            ch == '{' ||
            ch == '}') {
          break;
        }
        i++;
      }
      result.add(_Token(text.substring(start, i), start, i));
    }
    return result;
  }

  static bool _isDigit(String c) {
    final code = c.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  static MoveBounds? _computeBounds(
    List<PdfRect> charRects,
    int start,
    int end,
  ) {
    if (start >= charRects.length || end > charRects.length || start >= end) {
      return null;
    }
    double? left, top, right, bottom;
    for (int i = start; i < end && i < charRects.length; i++) {
      final r = charRects[i];
      if (r.isEmpty) continue;
      left = left == null ? r.left : (r.left < left ? r.left : left);
      top = top == null ? r.top : (r.top > top ? r.top : top);
      right = right == null ? r.right : (r.right > right ? r.right : right);
      bottom =
          bottom == null ? r.bottom : (r.bottom < bottom ? r.bottom : bottom);
    }
    if (left == null) return null;
    return MoveBounds(left: left, top: top!, right: right!, bottom: bottom!);
  }
}

class _Token {
  const _Token(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}
