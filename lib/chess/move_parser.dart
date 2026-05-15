import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/foundation.dart';
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
  // Figurine + language normalisation

  static const _figurineMap = {
    '♔': 'K', '♕': 'Q', '♖': 'R', '♗': 'B', '♘': 'N', '♙': '',
    '♚': 'K', '♛': 'Q', '♜': 'R', '♝': 'B', '♞': 'N', '♟': '',
  };

  // French algebraic piece letters → English SAN letters.
  // German (T=Turm→R, D=Dame→Q, L=Läufer→B, S=Springer→N, K→K) also handled.
  // Only the initial letter of a token is translated; file letters (a–h) and
  // castling (O-O) are left alone.
  static const _frenchPieces = {'R': 'K', 'D': 'Q', 'T': 'R', 'F': 'B', 'C': 'N'};
  static const _germanPieces = {'K': 'K', 'D': 'Q', 'T': 'R', 'L': 'B', 'S': 'N'};

  static String _normaliseToken(String token) {
    var s = token;
    // 1. Replace figurine symbols.
    for (final entry in _figurineMap.entries) {
      s = s.replaceAll(entry.key, entry.value);
    }
    // 2. Replace custom-font file-letter substitutions (anywhere in the token).
    //    Some PDF chess fonts render 'c' as ¢ and 'f' as £.
    s = s.replaceAll('¢', 'c').replaceAll('£', 'f');
    // 3. Strip a leading backslash (some fonts emit \ before piece glyphs).
    if (s.startsWith('\\')) s = s.substring(1);
    // 4. Remove ) or . that appears between chars in a move token — some fonts
    //    use multi-char sequences like "2)xf7" or "2.d6" for a piece+move.
    s = s.replaceAll(RegExp(r'[).](?=[a-hx=1-8])'), '');
    // 5. Strip trailing human annotations (!, ?, !?, ?!, !!, ??) — they are not
    //    part of SAN and cause parseSan to fail.
    s = s.replaceAll(RegExp(r'[!?]+$'), '');
    // 6. If the first character looks like a non-English piece letter, translate.
    if (s.isNotEmpty) {
      final first = s[0];
      final rest = s.substring(1);
      // Only translate when the rest looks like a valid SAN suffix (file/rank/x…)
      // to avoid mangling words like "Cavalier" appearing in prose.
      if (_looksLikeSanSuffix(rest)) {
        final eng = _frenchPieces[first] ?? _germanPieces[first];
        if (eng != null) s = eng + rest;
      }
    }
    return s;
  }

  static bool _looksLikeSanSuffix(String s) {
    if (s.isEmpty) return false;
    final first = s[0];
    // Valid SAN suffixes start with a file letter, 'x' (capture), or '=' (promotion).
    return (first.compareTo('a') >= 0 && first.compareTo('h') <= 0) ||
        first == 'x' ||
        first == '=';
  }

  /// Resolve a normalised token to a legal move, updating [fontMap] when a
  /// new character→piece mapping is discovered via fuzzy matching.
  ///
  /// Resolution order:
  ///   1. Apply any previously learnt font mapping for the leading character.
  ///   2. Try [parseSan] on the (possibly remapped) token.
  ///   3. If that fails and the leading character is non-standard, try each
  ///      piece letter (K/Q/R/B/N) in turn; on the first hit, record the
  ///      mapping in [fontMap] so future tokens are resolved deterministically.
  static dc.Move? _resolveMove(
    String token,
    dc.Position pos,
    Map<String, String>? fontMap,
  ) {
    if (token.isEmpty) return null;

    // 1. Apply learnt font mapping to the leading character.
    String remapped = token;
    if (fontMap != null && fontMap.containsKey(token[0])) {
      remapped = fontMap[token[0]]! + token.substring(1);
    }

    // 2. Standard parseSan.
    final direct = pos.parseSan(remapped);
    if (direct != null) return direct;

    // 3. Fuzzy piece substitution.
    final first = remapped[0];
    final rest = remapped.substring(1);

    // 3a. Non-standard leading character (not already a SAN piece/file/digit).
    final isStandardStart = RegExp(r'^[KQRBNa-hO0-9x=+#]').hasMatch(first);
    if (!isStandardStart && _looksLikeSanSuffix(rest)) {
      for (final piece in const ['K', 'Q', 'R', 'B', 'N']) {
        final move = pos.parseSan(piece + rest);
        if (move != null) {
          fontMap?[token[0]] = piece; // learn for the rest of the document
          return move;
        }
      }
    }

    // 3b. Digit-first token: some fonts encode piece glyphs as digits (e.g. 2→N).
    //     Only attempt when the rest looks like a capture or file+rank, so we
    //     don't confuse move numbers ("22.") with piece tokens.
    if (_isDigit(first) && _looksLikeSanSuffix(rest)) {
      for (final piece in const ['N', 'B', 'R', 'Q', 'K']) {
        final move = pos.parseSan(piece + rest);
        if (move != null) {
          fontMap?[token[0]] = piece;
          return move;
        }
      }
    }

    return null;
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

  // Line 1 of a game header: "Alekhine - Duras", "Van der Wiel - Short",
  // "R. Williams - LeMoir", etc.
  //
  // multiLine: true + ^ + $ anchor to a single line.  The line must contain
  // nothing after the last name (modulo trailing whitespace), which is what
  // distinguishes "Alekhine - Duras" from book-title lines like
  // "David LeMoir - Comment devenir un Super Attaquant" (extra words after).
  //
  // Each side allows one or more capitalised words (to support "Van der Wiel",
  // "De la Bourdonnais", etc.) plus an optional leading initial ("R. ").
  static final _playerLineRegex = RegExp(
    r'^'
    r'(?:[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ]\.\s+)*'  // optional initials
    r'[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ]'
    r'[a-zA-Zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+'
    r'(?:\s+[A-Za-zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+)*'  // extra name words
    r'\s+[-]\s+'
    r'(?:[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ]\.\s+)*'
    r'[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝ]'
    r'[a-zA-Zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+'
    r'(?:\s+[A-Za-zàáâãäåæçèéêëìíîïðñòóôõöøùúûüý]+)*'  // extra name words
    r'\s*$',                                              // end of line
    multiLine: true,
  );

  // Line 2 of a game header: "Saint-Petersbourg, 1913" or "London, 1851".
  static final _locationYearRegex = RegExp(r'[A-Za-z][A-Za-z\s-]*,\s*\d{4}');

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

  /// Returns true when the page likely needs a user-supplied starting FEN.
  ///
  /// A diagram is suspected when any of these signals are present:
  ///   1. A player-name line ("Alekhine - Duras") is found AND the game does
  ///      not start from move 1 (move 1 → standard initial position, no FEN needed).
  ///   2. A location/year line ("Saint-Petersbourg, 1913") is found alongside
  ///      a player-name line — confirms this is a game excerpt, not prose.
  ///   3. A large vertical gap (≥ 90 pt) exists in the character distribution,
  ///      indicating a board-diagram image above the game text.
  static const _minDiagramGap = 90.0;

  static bool _suspectDiagram({
    required bool hasPlayerHeader,
    required bool hasLocationYear,
    required List<PdfRect> charRects,
    required int? firstMoveNumber,
  }) {
    final hasContextHeader = hasPlayerHeader || hasLocationYear;

    // Signal 1 & 2: semantic game header detected.
    if (hasContextHeader && firstMoveNumber != 1) return true;

    // Signal 3: visible gap in character layout → board image present.
    if (hasContextHeader && _hasImageGap(charRects)) return true;

    return false;
  }

  static bool _hasImageGap(List<PdfRect> charRects) {
    final ys = charRects
        .where((r) => r.isNotEmpty)
        .map((r) => (r.top + r.bottom) / 2)
        .toList()
      ..sort();
    if (ys.length < 4) return true;
    for (int i = 1; i < ys.length; i++) {
      if (ys[i] - ys[i - 1] > _minDiagramGap) return true;
    }
    return false;
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
  /// - [fontMap]: mutable map of unrecognised piece characters → standard SAN
  ///   piece letters, shared across all pages of a document.  The parser adds
  ///   new entries whenever fuzzy matching resolves an unknown character, so
  ///   the map grows as pages are processed and subsequent pages benefit from
  ///   mappings already learnt.  Pass the same instance for every page.
  static PageAnalysis parse(
    PdfPageRawText rawText,
    double pageHeight, {
    String? inheritedFen,
    String? forcedFen,
    Map<String, String>? fontMap,
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

    // Regex for a pure move number ("22." or "22...").
    final pureNumRx = RegExp(r'^(\d+)(\.+)$');
    // Regex for a move number glued to a move with no space ("22.g4!" or "22...2d6").
    // The move part must start with a non-dot character.
    final combinedRx = RegExp(r'^(\d+)(\.{1,3})([^.].*)$');

    for (final tok in tokens) {
      final raw = tok.text;

      if (raw == '1-0' || raw == '0-1' || raw == '1/2-1/2' || raw == '*') {
        break;
      }

      // Pure move number token: "22." or "22..."
      final numMatch = pureNumRx.firstMatch(raw);
      if (numMatch != null) {
        currentMoveNum = int.parse(numMatch.group(1)!);
        firstMoveNumber ??= currentMoveNum;
        expectBlack = numMatch.group(2)!.length > 1;
        continue;
      }

      // Combined move-number+move token: "22.g4!" or "22...2d6"
      // This happens when the PDF font leaves no space between the move number
      // and the move (common in older chess book layouts).
      final combined = combinedRx.firstMatch(raw);
      if (combined != null) {
        final num = int.parse(combined.group(1)!);
        final dots = combined.group(2)!;
        final movePart = combined.group(3)!;
        // Treat as a move number only when it's plausible (not a huge backward
        // jump, which would indicate the digit is actually a piece glyph).
        if (currentMoveNum == null || num >= currentMoveNum - 1) {
          currentMoveNum = num;
          firstMoveNumber ??= num;
          expectBlack = dots.length > 1;
          // Fall through to try parsing movePart as the move below.
          final normalised = _normaliseToken(movePart);
          final move = _resolveMove(normalised, position, fontMap);
          if (move != null) {
            final fenBefore = position.fen;
            final (newPosition, san) = position.makeSan(move);
            moves.add(CachedMove(
              moveNumber: currentMoveNum,
              isBlack: expectBlack,
              san: san,
              rawToken: raw,
              fenBefore: fenBefore,
              fenAfter: newPosition.fen,
              bounds: _computeBounds(charRects, tok.start, tok.end),
            ));
            position = newPosition;
            expectBlack = !expectBlack;
            if (!expectBlack) currentMoveNum = currentMoveNum + 1;
          }
          continue;
        }
        // Number not plausible as move number — fall through to treat the
        // whole token as a move (e.g. "2.d6" where "2" is a piece glyph).
      }

      if (currentMoveNum == null) continue;

      final normalised = _normaliseToken(raw);
      final move = _resolveMove(normalised, position, fontMap);
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

    if (fenSource == FenSource.standard) {
      final playerMatch = _playerLineRegex.firstMatch(fullText);
      final locationMatch = _locationYearRegex.firstMatch(fullText);
      debugPrint('[MoveParser] player header: '
          '${playerMatch != null ? '"${playerMatch.group(0)}"' : 'none'}');
      debugPrint('[MoveParser] location/year: '
          '${locationMatch != null ? '"${locationMatch.group(0)}"' : 'none'}');
      if (_suspectDiagram(
        hasPlayerHeader: playerMatch != null,
        hasLocationYear: locationMatch != null,
        charRects: charRects,
        firstMoveNumber: firstMoveNumber,
      )) {
        fenSource = FenSource.suspectedDiagram;
      }
    }

    debugPrint('[MoveParser] fenSource=$fenSource  startFen=$startFen');

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
