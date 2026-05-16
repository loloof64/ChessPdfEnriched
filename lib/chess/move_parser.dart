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
  // Wrapper around dartchess parseSan that never throws: returns null for any
  // malformed input that the library cannot handle gracefully.
  static dc.Move? _parseSan(dc.Position pos, String san) {
    if (san.length < 2) return null;
    try {
      return pos.parseSan(san);
    } catch (_) {
      return null;
    }
  }

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
    final direct = _parseSan(pos, remapped);
    if (direct != null) return direct;

    // 3. Fuzzy piece substitution.
    if (remapped.isEmpty) return null;
    final first = remapped[0];
    final rest = remapped.substring(1);

    // 3a. Non-standard leading character (not already a SAN piece/file/digit).
    final isStandardStart = RegExp(r'^[KQRBNa-hO0-9x=+#]').hasMatch(first);
    if (!isStandardStart && _looksLikeSanSuffix(rest)) {
      for (final piece in const ['K', 'Q', 'R', 'B', 'N']) {
        final move = _parseSan(pos, piece + rest);
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
        final move = _parseSan(pos, piece + rest);
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

  // Location/year line: "Saint-Pétersbourg, 1913", "London, 1851", etc.
  // \xC0-\xFF covers the Latin-1 Supplement block (À–ÿ): all accented letters
  // used in French, German, Spanish, Russian transliterations, etc.
  static final _locationYearRegex = RegExp(
    r'[A-Za-z\xC0-\xFF][A-Za-z\xC0-\xFF\s-]*,\s*(?:1[0-9]|20)\d{2}\b',
  );

  /// Returns the first move number found in [fullText] using a simple regex scan,
  /// without any chess move parsing.  E.g. "22.g4" → 22, "1. e4" → 1.
  static int? _scanFirstMoveNumber(String fullText) {
    final m = RegExp(r'\b(\d+)\.').firstMatch(fullText);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Scans [fullText] for game headers (any non-empty line immediately followed
  /// by a location/year line) and returns their byte-offsets in [fullText]
  /// together with the detected player-line text.
  ///
  /// Each returned record marks the start of a game segment: from that offset
  /// to the next segment's start (or end of text).
  static List<({int start, String header})> _findGameSegments(String fullText) {
    final lines = fullText.split('\n');
    final segments = <({int start, String header})>[];

    int offset = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isNotEmpty && i + 1 < lines.length) {
        final nextTrimmed = lines[i + 1].trim();
        if (_locationYearRegex.hasMatch(nextTrimmed)) {
          debugPrint('[MoveParser] game header: "$trimmed" / "$nextTrimmed"');
          segments.add((start: offset, header: trimmed));
        }
      }

      offset += line.length + 1; // +1 for the '\n' consumed by split
    }
    return segments;
  }

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
  /// A diagram is suspected when a game header is present AND either:
  ///   1. The first move number is not 1 (game excerpt → non-standard position).
  ///   2. A large vertical gap (≥ 90 pt) exists in the character distribution,
  ///      indicating a board-diagram image above the game text.
  static const _minDiagramGap = 90.0;

  static bool _suspectDiagram({
    required bool hasGameHeader,
    required List<PdfRect> charRects,
    required int? firstMoveNumber,
  }) {
    if (!hasGameHeader) return false;
    if (firstMoveNumber != 1) return true;
    if (_hasImageGap(charRects)) return true;
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

  /// Parse [rawText] into one [PageAnalysis] per game found on the page.
  ///
  /// When the page contains multiple game headers (player line + location/year),
  /// the text is split at each header boundary and parsed independently so that
  /// each game gets its own starting FEN and move list.
  ///
  /// - [inheritedFen]: FEN from the last move of the previous page, applied
  ///   to the first segment when the page is a game continuation.
  /// - [forcedFens]: user-supplied FENs keyed by game index (0-based) that
  ///   override every other source for the corresponding game.
  /// - [fontMap]: mutable character→piece mapping shared across all pages.
  static List<PageAnalysis> parse(
    PdfPageRawText rawText,
    double pageHeight, {
    String? inheritedFen,
    Map<int, String>? forcedFens,
    Map<String, String>? fontMap,
  }) {
    final fullText = rawText.fullText;
    final charRects = rawText.charRects;

    final segments = _findGameSegments(fullText);

    if (segments.isEmpty) {
      return [
        _parseSegment(
          text: fullText,
          charRects: charRects,
          header: null,
          inheritedFen: inheritedFen,
          forcedFen: forcedFens?[0],
          fontMap: fontMap,
        ),
      ];
    }

    return [
      for (int i = 0; i < segments.length; i++)
        _parseSegment(
          text: fullText.substring(
            segments[i].start,
            i + 1 < segments.length ? segments[i + 1].start : fullText.length,
          ),
          charRects: _sliceRects(
            charRects,
            segments[i].start,
            i + 1 < segments.length ? segments[i + 1].start : fullText.length,
          ),
          header: segments[i].header,
          inheritedFen: i == 0 ? inheritedFen : null,
          forcedFen: forcedFens?[i],
          fontMap: fontMap,
        ),
    ];
  }

  static List<PdfRect> _sliceRects(List<PdfRect> rects, int start, int end) {
    if (start >= rects.length) return const [];
    return rects.sublist(start, end.clamp(0, rects.length));
  }

  /// Parse one game segment ([text] + its [charRects] slice) into a [PageAnalysis].
  static PageAnalysis _parseSegment({
    required String text,
    required List<PdfRect> charRects,
    required String? header,
    String? inheritedFen,
    String? forcedFen,
    Map<String, String>? fontMap,
  }) {
    // ------------------------------------------------------------------
    // 1. Determine starting position.

    String startFen;
    FenSource fenSource;

    if (forcedFen != null) {
      startFen = forcedFen;
      fenSource = FenSource.userProvided;
    } else {
      final detected = _detectFenInText(text);
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
    // 2. Diagram detection (pure text — independent of move parsing).

    if (fenSource == FenSource.standard) {
      final firstMoveNumber = _scanFirstMoveNumber(text);
      if (_suspectDiagram(
        hasGameHeader: header != null,
        charRects: charRects,
        firstMoveNumber: firstMoveNumber,
      )) {
        fenSource = FenSource.suspectedDiagram;
      }
    }

    debugPrint('[MoveParser] header=$header  fenSource=$fenSource  startFen=$startFen');

    // ------------------------------------------------------------------
    // 3. Tokenise, skipping comments and variations.

    final tokens = _tokenise(text);

    // ------------------------------------------------------------------
    // 4. Parse chess moves.

    final moves = <CachedMove>[];
    int? currentMoveNum;
    bool expectBlack = false;

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

    return PageAnalysis(
      startFen: startFen,
      fenSource: fenSource,
      moves: moves,
      header: header,
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
