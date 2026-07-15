import 'dart:io';
import 'dart:math' as math;

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

  static String _normaliseToken(
    String token, {
    bool skipPieceTranslation = false,
    NotationMode notationMode = NotationMode.textSan,
  }) {
    var s = token;
    // 1. Replace figurine symbols (only in figurine mode; text mode uses letters).
    if (notationMode == NotationMode.figurineFan) {
      for (final entry in _figurineMap.entries) {
        s = s.replaceAll(entry.key, entry.value);
      }
    }
    // 2. Replace custom-font file-letter substitutions (anywhere in the token).
    //    Some PDF chess fonts render 'c' as ¢ and 'f' as £.
    s = s.replaceAll('¢', 'c').replaceAll('£', 'f');
    // 3. Strip a leading backslash (some fonts emit \ before piece glyphs).
    if (s.startsWith('\\')) s = s.substring(1);
    // 4. Remove ) or . that appears between chars in a move token — some fonts
    //    use multi-char sequences like "2)xf7" or "2.d6" for a piece+move.
    s = s.replaceAll(RegExp(r'[).](?=[a-hx=1-8])'), '');
    // 5. Strip trailing prose punctuation and human annotations — they are not
    //    part of SAN and cause parseSan to fail.
    s = s.replaceAll(RegExp(r'[!?,;:.]+$'), '');
    // 6. Castling: "0-0-0" / "0-0" with digit zero → standard "O-O-O" / "O-O".
    //    Many chess books (especially French/Spanish) use zeros instead of O.
    //    Must check 0-0-0 before 0-0 to avoid a partial match.
    if (s.startsWith('0-0-0')) {
      s = 'O-O-O${s.substring(5)}';
    } else if (s.startsWith('0-0')) {
      s = 'O-O${s.substring(3)}';
    }
    // 7. If the first character looks like a non-English piece letter, translate.
    // Skip when fontMap already resolved it to an English letter.
    if (!skipPieceTranslation && s.isNotEmpty) {
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
      final pieceStr = fontMap[token[0]]!;
      // Empty mapping means pawn glyph: the file letter is already token[0], keep it.
      if (pieceStr.isNotEmpty) remapped = pieceStr + token.substring(1);
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

    // 4. Legality-constrained matching: generate all legal moves and try to
    // match the token against them when strict SAN parsing fails.
    final legalMove = _matchTokenToLegalMove(remapped, pos);
    if (legalMove != null) return legalMove;

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

  /// Minimum vertical gap (pt) between text blocks to suspect a board diagram.
  static const _minDiagramGap = 90.0;

  /// Minimum gap (pt) between the top of the page and the highest text
  /// character to suspect a board diagram at the top of the page.
  static const _minDiagramGapAtPageEdge = 120.0;

  /// A gap larger than this fraction of the page height is almost certainly
  /// a full-page illustration or cover image, not a chess board.
  /// Chess boards typically occupy 20–55 % of a page; full-page images 80–95 %.
  static const _maxDiagramGapRatio = 0.75;

  /// Returns [FenSource.suspectedDiagram] when a board-diagram image is
  /// detected in [charRects], or `null` when no gap is found.
  ///
  /// Logs the largest Y-gaps in the segment so that diagram-detection noise
  /// can be diagnosed in the debug console.
  static FenSource? _detectDiagramFenSource({
    required List<PdfRect> charRects,
    double? pageHeight,
  }) {
    final ys = charRects
        .where((r) => r.isNotEmpty)
        .map((r) => (r.top + r.bottom) / 2)
        .toList()
      ..sort();

    if (ys.length < 4) {
      debugPrint('[Diagram] too few chars (${ys.length}) — treated as suspected diagram');
      return FenSource.suspectedDiagram;
    }

    // Log the three largest gaps to help diagnose false positives / misses.
    final gaps = <double>[];
    for (int i = 1; i < ys.length; i++) {
      gaps.add(ys[i] - ys[i - 1]);
    }
    gaps.sort((a, b) => b.compareTo(a)); // descending
    debugPrint(
      '[Diagram] top-3 Y-gaps: '
      '${gaps.take(3).map((g) => g.toStringAsFixed(1)).join(' / ')} pt'
      '  (threshold: $_minDiagramGap pt)',
    );

    // Gap between page top and highest text character.
    if (pageHeight != null) {
      final topGap = pageHeight - ys.last;
      final maxGap = pageHeight * _maxDiagramGapRatio;
      debugPrint(
        '[Diagram] top-of-page gap: ${topGap.toStringAsFixed(1)} pt'
        '  (text starts at Y ${ys.last.toStringAsFixed(1)}, page H: ${pageHeight.toStringAsFixed(1)})'
        '  range: $_minDiagramGapAtPageEdge–${maxGap.toStringAsFixed(1)} pt',
      );
      if (topGap > _minDiagramGapAtPageEdge && topGap < maxGap) {
        debugPrint('[Diagram] → diagram suspected at TOP of page');
        return FenSource.suspectedDiagram;
      }
    }

    final maxGap = pageHeight != null ? pageHeight * _maxDiagramGapRatio : double.infinity;
    for (int i = 1; i < ys.length; i++) {
      final gap = ys[i] - ys[i - 1];
      if (gap > _minDiagramGap && gap < maxGap) {
        debugPrint(
          '[Diagram] → diagram suspected: gap ${gap.toStringAsFixed(1)} pt'
          '  between Y ${ys[i - 1].toStringAsFixed(1)} and Y ${ys[i].toStringAsFixed(1)}'
          '  (max allowed: ${maxGap.toStringAsFixed(1)} pt)',
        );
        return FenSource.suspectedDiagram;
      }
    }

    debugPrint('[Diagram] no diagram gap detected in this segment');
    return null;
  }

  /// Scans [charRects] for large vertical gaps caused by board-diagram images
  /// and returns the character indices where a new game segment starts (i.e.
  /// the first character of the text block that follows each diagram).
  ///
  /// Algorithm: sort character Y-centers ascending (bottom→top in PDF space).
  /// A gap > [_minDiagramGap] between sorted neighbours means a diagram sits
  /// between those two text blocks.  The split point is the minimum original
  /// text index of characters below the gap (they come *after* the diagram in
  /// reading order because the page is read top-to-bottom = Y decreasing).
  static List<int> _findDiagramSplitIndices(
    List<PdfRect> charRects, {
    double? pageHeight,
  }) {
    final entries = <({double y, int idx})>[];
    for (int i = 0; i < charRects.length; i++) {
      final r = charRects[i];
      if (r.isNotEmpty) entries.add((y: (r.top + r.bottom) / 2, idx: i));
    }
    if (entries.length < 4) return const [];

    // Sort ascending by Y (small Y = bottom of page = later in reading order).
    entries.sort((a, b) => a.y.compareTo(b.y));

    final maxGap = pageHeight != null ? pageHeight * _maxDiagramGapRatio : double.infinity;
    final splits = <int>[];
    // runningMin tracks min(original text index of entries[0..i-1]) — i.e. the
    // earliest text position of all characters below the current candidate gap.
    int runningMin = entries[0].idx;

    for (int i = 1; i < entries.length; i++) {
      final gap = entries[i].y - entries[i - 1].y;
      if (gap > _minDiagramGap && gap < maxGap) {
        debugPrint(
          '[Diagram] multi-split gap ${gap.toStringAsFixed(1)} pt'
          '  Y ${entries[i - 1].y.toStringAsFixed(1)}→${entries[i].y.toStringAsFixed(1)}'
          '  (max: ${maxGap.toStringAsFixed(1)} pt)'
          '  → new game segment starts at char $runningMin',
        );
        splits.add(runningMin);
      } else if (gap >= maxGap) {
        debugPrint(
          '[Diagram] multi-split gap ${gap.toStringAsFixed(1)} pt IGNORED'
          '  (exceeds max ${maxGap.toStringAsFixed(1)} pt — likely not a chess board)',
        );
      }
      // Update for next iteration: include entries[i] in the running minimum.
      if (entries[i].idx < runningMin) runningMin = entries[i].idx;
    }

    if (splits.isNotEmpty) {
      debugPrint('[Diagram] ${splits.length} diagram split(s) found → ${splits.length + 1} segments');
    }
    splits.sort();
    return splits;
  }

  // --------------------------------------------------------------------------
  // Public API

  /// Parse [rawText] into one [PageAnalysis] per game found on the page.
  ///
  /// Game boundaries come exclusively from pixel-confirmed board detection
  /// ([preComputedSplits] / [topOfPageBoardDetected]).  When no pixel splits
  /// are supplied the text-gap heuristic is used as a fallback.
  ///
  /// - [inheritedFen]: FEN from the last move of the previous page, applied
  ///   to the first segment when the page is a game continuation.
  /// - [forcedFens]: user-supplied FENs keyed by game index (0-based) that
  ///   override every other source for the corresponding game.
  /// - [forcedIntermediates]: game indices (0-based) the user has confirmed as
  ///   intermediate diagrams; diagram detection is skipped and fenSource is set
  ///   to [FenSource.userConfirmedIntermediate].
  /// - [forcedNotADiagrams]: game indices (0-based) the user has confirmed as
  ///   non-diagram images; diagram detection is skipped and fenSource is set
  ///   to [FenSource.userConfirmedNotADiagram].
  /// - [preComputedSplits]: char-index split points from [BoardDetector].
  ///   When supplied, the internal text-gap split detection is skipped.
  /// - [topOfPageBoardDetected]: if true, the first game segment is flagged as
  ///   [FenSource.suspectedDiagram] (board detected above the first text line).
  /// - [fontMap]: mutable character→piece mapping shared across all pages.
  static List<PageAnalysis> parse(
    PdfPageRawText rawText,
    double pageHeight, {
    List<int>? preComputedSplits,
    bool topOfPageBoardDetected = false,
    String? inheritedFen,
    Map<int, String>? forcedFens,
    Set<int>? forcedIntermediates,
    Set<int>? forcedNotADiagrams,
    Map<String, String>? fontMap,
    NotationMode notationMode = NotationMode.textSan,
    List<DetectedFigurine>? detectedFigurines,
    /// When set, diagnostic lines are appended straight to this file instead
    /// of going through debugPrint — terminal/logcat output gets truncated
    /// or drops lines under heavy volume, a file never does.
    String? debugLogFile,
  }) {
    final fullText = rawText.fullText;
    final charRects = rawText.charRects;
    final pixelDetectionUsed = preComputedSplits != null;

    // Game boundaries come exclusively from pixel-confirmed board detection.
    // Fall back to the text-gap heuristic only when no pixel splits were supplied.
    final diagramSplits = preComputedSplits ??
        _findDiagramSplitIndices(charRects, pageHeight: pageHeight);

    PageAnalysis maybeMarkIntermediate(PageAnalysis a, int idx) {
      // Explicit user overrides take priority over everything, including a
      // userProvided FEN — this is what lets the user re-label a detected board.
      if (forcedNotADiagrams != null && forcedNotADiagrams.contains(idx)) {
        return PageAnalysis(
          startFen: a.startFen,
          fenSource: FenSource.userConfirmedNotADiagram,
          moves: a.moves,
          header: a.header,
        );
      }
      if (forcedIntermediates != null && forcedIntermediates.contains(idx)) {
        return PageAnalysis(
          startFen: a.startFen,
          fenSource: FenSource.userConfirmedIntermediate,
          moves: a.moves,
          header: a.header,
        );
      }
      // Skip automatic diagram detection for user-provided FENs.
      if (a.fenSource == FenSource.userProvided) return a;
      return a;
    }

    if (diagramSplits.isEmpty) {
      final userOverride =
          (forcedIntermediates?.contains(0) ?? false) ||
          (forcedNotADiagrams?.contains(0) ?? false);
      final a = _parseSegment(
        text: fullText,
        charRects: charRects,
        header: null,
        pageHeight: pageHeight,
        inheritedFen: inheritedFen,
        forcedFen: forcedFens?[0],
        fontMap: fontMap,
        skipDiagramDetection: userOverride,
        pixelDetectionUsed: pixelDetectionUsed,
        forceSuspectedDiagram: topOfPageBoardDetected,
        notationMode: notationMode,
        detectedFigurines: detectedFigurines,
        debugLogFile: debugLogFile,
      );
      return [maybeMarkIntermediate(a, 0)];
    }

    // Multiple board-confirmed segments.
    // splitPoints[0] = 0 (page start), splitPoints.last = fullText.length.
    final splitPoints = [0, ...diagramSplits, fullText.length];
    final segments = [
      for (int i = 0; i < splitPoints.length - 1; i++)
        maybeMarkIntermediate(
          _parseSegment(
            text: fullText.substring(splitPoints[i], splitPoints[i + 1]),
            charRects: _sliceRects(charRects, splitPoints[i], splitPoints[i + 1]),
            header: null,
            pageHeight: pageHeight,
            inheritedFen: i == 0 ? inheritedFen : null,
            forcedFen: forcedFens?[i],
            fontMap: fontMap,
            skipDiagramDetection:
                (forcedIntermediates?.contains(i) ?? false) ||
                (forcedNotADiagrams?.contains(i) ?? false),
            pixelDetectionUsed: pixelDetectionUsed,
            forceSuspectedDiagram: i == 0 ? topOfPageBoardDetected : true,
            notationMode: notationMode,
            detectedFigurines: detectedFigurines,
            debugLogFile: debugLogFile,
          ),
          i,
        ),
    ];

    // Drop empty first segment (header/prose text that precedes the first board
    // diagram on the page — it carries no FEN and typically contains no moves).
    // Keep it when it has an inherited FEN: the user may want to see the
    // continued position and can dismiss it manually.
    if (segments.length > 1 &&
        segments.first.moves.isEmpty &&
        segments.first.fenSource != FenSource.inheritedFromPreviousPage &&
        (forcedFens == null || !forcedFens.containsKey(0))) {
      segments.removeAt(0);
    }

    // N boards produce N+1 segments; the last covers text after the final board
    // and has no associated detected FEN. Drop it when it has no moves and the
    // user has not explicitly provided a FEN for it.
    final lastIdx = segments.length - 1;
    if (segments.length > 1 &&
        segments.last.moves.isEmpty &&
        (forcedFens == null || !forcedFens.containsKey(lastIdx))) {
      segments.removeLast();
    }

    return segments;
  }

  /// Appends [message] to [logFile] if set, otherwise falls back to
  /// [debugPrint]. Terminal/logcat output gets truncated or drops lines
  /// under heavy volume — writing straight to a file never does.
  static void _log(String? logFile, String message) {
    if (logFile == null) {
      debugPrint(message);
      return;
    }
    try {
      File(logFile).writeAsStringSync('$message\n', mode: FileMode.append);
    } catch (e) {
      debugPrint('[MoveParser] failed to write log: $e');
    }
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
    double? pageHeight,
    String? inheritedFen,
    String? forcedFen,
    Map<String, String>? fontMap,
    bool skipDiagramDetection = false,
    bool pixelDetectionUsed = false,
    bool forceSuspectedDiagram = false,
    NotationMode notationMode = NotationMode.textSan,
    List<DetectedFigurine>? detectedFigurines,
    String? debugLogFile,
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
      // Keep startFen so the user can see and correct the illegal position.
      // Mark as suspectedDiagram so the warning banner opens the editor pre-filled.
      fenSource = FenSource.suspectedDiagram;
    }

    // ------------------------------------------------------------------
    // 2. Diagram detection (independent of move parsing).
    // Applies when no explicit FEN was found and the user hasn't overridden.
    // Covers both the standard fallback and pages that inherit a position.

    if (!skipDiagramDetection &&
        (fenSource == FenSource.standard ||
            fenSource == FenSource.inheritedFromPreviousPage)) {
      if (forceSuspectedDiagram) {
        debugPrint('[Diagram] segment preceded by confirmed board → suspectedDiagram  FEN: $startFen');
        fenSource = FenSource.suspectedDiagram;
      } else if (!pixelDetectionUsed) {
        // Fall back to text-gap heuristic only when no pixel detection was done.
        final diagramSource = _detectDiagramFenSource(
          charRects: charRects,
          pageHeight: pageHeight,
        );
        if (diagramSource != null) fenSource = diagramSource;
      }
    }

    // ------------------------------------------------------------------
    // 3. (Visual detection — no charIndex / fontMap pre-population needed.)
    //    Figurine identification is done spatially via DetectedFigurine.bounds.

    final figurines = detectedFigurines ?? const <DetectedFigurine>[];

    // ------------------------------------------------------------------
    // 4. Tokenise, skipping comments and variations.

    var tokens = _tokenise(text);

    // ------------------------------------------------------------------
    // 4b. Spatially merge standalone figurine tokens with adjacent move text.
    //     e.g. "♘" token + "f3" token → "Nf3" token (if spatially adjacent).

    if (figurines.isNotEmpty) {
      tokens = _mergeFigurineTokens(tokens, charRects, figurines);
    }

    // ------------------------------------------------------------------
    // 4c. Correct fullmove number AND side to move from the first move-number
    // token. Board detection always emits fullmove=1 and side=white; the dots
    // ("." vs "...") tell us which side actually moves first.
    if (startFen.isNotEmpty) {
      final pureNumRxEarly = RegExp(r'^(\d+)(\.+)$');
      final combinedRxEarly = RegExp(r'^(\d+)(\.{1,3})[^.]');
      for (final tok in tokens) {
        final t = tok.text;
        final pm = pureNumRxEarly.firstMatch(t) ?? combinedRxEarly.firstMatch(t);
        if (pm != null) {
          final num = int.tryParse(pm.group(1)!);
          if (num != null) {
            final dots = pm.group(2) ?? '.';
            final firstMoveIsBlack = dots.length > 1;
            final parts = startFen.split(' ');
            if (parts.length == 6) {
              bool changed = false;
              if (parts[5] != num.toString()) {
                parts[5] = num.toString();
                changed = true;
              }
              final expectedSide = firstMoveIsBlack ? 'b' : 'w';
              if (parts[1] != expectedSide) {
                parts[1] = expectedSide;
                changed = true;
              }
              if (changed) {
                final correctedFen = parts.join(' ');
                try {
                  position = dc.Chess.fromSetup(dc.Setup.parseFen(correctedFen));
                  startFen = correctedFen;
                } catch (_) {}
              }
            }
            break;
          }
        }
      }
    }

    // ------------------------------------------------------------------
    // 5. Parse chess moves.

    final moves = <CachedMove>[];
    int skippedTokens = 0;
    // Position tree: one checkpoint saved *before* each accepted move.
    // Enables backtracking when commentary moves corrupt currentMoveNum/position.
    final checkpoints = <_PositionCheckpoint>[];
    int? currentMoveNum;
    bool expectBlack = false;

    // Regex for a pure move number ("22." or "22...").
    final pureNumRx = RegExp(r'^(\d+)(\.+)$');
    // Regex for a move number glued to a move with no space ("22.g4!" or "22...2d6").
    // The move part must start with a non-dot character.
    final combinedRx = RegExp(r'^(\d+)(\.{1,3})([^.].*)$');

    for (int ti = 0; ti < tokens.length; ti++) {
      final tok = tokens[ti];
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
        final targetIsBlack = dots.length > 1;
        // Apply fontMap before normalisation so it overrides language mappings.
        final (mapped1, wasMapped1) = _applyFontMapToFirst(movePart, fontMap);
        final normalised = _normaliseToken(mapped1, skipPieceTranslation: wasMapped1, notationMode: notationMode);
        // Treat as a move number when plausible (not a huge backward jump).
        var isPlausible = currentMoveNum == null || num >= currentMoveNum - 1;
        if (isPlausible) {
          currentMoveNum = num;
          expectBlack = targetIsBlack;
        }
        // Try to resolve the move at the current position.
        var move = _resolveMove(normalised, position, fontMap);
        // If implausible and resolution failed, search the checkpoint tree for a
        // saved position that matches this move number and side, then backtrack.
        if (move == null && !isPlausible) {
          final idx = checkpoints.lastIndexWhere(
            (cp) => cp.moveNum == num && cp.isBlack == targetIsBlack,
          );
          if (idx >= 0) {
            final cp = checkpoints[idx];
            // Restore position and moves list to the state before commentary diverged.
            try {
              position = dc.Chess.fromSetup(dc.Setup.parseFen(cp.fen));
            } catch (_) {
              position = dc.Chess.initial;
            }
            moves.removeRange(cp.moveCount, moves.length);
            checkpoints.removeRange(idx, checkpoints.length);
            currentMoveNum = num;
            expectBlack = targetIsBlack;
            move = _resolveMove(normalised, position, fontMap);
            _log(
              debugLogFile,
              '[MoveParser] backtrack to move $num ${targetIsBlack ? "b" : "w"} for "$raw": ${move != null ? "ok" : "still failed"}',
            );
          }
        }
        // Dotted-piece fallback: "2.d6?" has num=2 (implausible) but the "2"
        // is actually a figurine piece glyph. Re-try as piece+rest at the
        // current (unchanged) position/moveNum.
        if (move == null && !isPlausible && num >= 1 && num <= 9 &&
            movePart.isNotEmpty) {
          final pieceAndRest = num.toString() + movePart;
          final (pm, wm) = _applyFontMapToFirst(pieceAndRest, fontMap);
          final pieceNorm = _normaliseToken(pm, skipPieceTranslation: wm, notationMode: notationMode);
          move = _resolveMove(pieceNorm, position, fontMap);
          if (move != null) {
            isPlausible = true; // use current currentMoveNum/expectBlack
            _log(debugLogFile, '[MoveParser] dotted-piece "$raw" → "$pieceNorm"');
          }
        }
        // Split-token lookahead: figurine glyph in one font run, rest in next.
        // e.g. "23.2" + "xf7!" → try "2xf7".
        if (move == null && movePart.length <= 2 && ti + 1 < tokens.length) {
          final nextText = tokens[ti + 1].text;
          if (nextText.isNotEmpty &&
              (nextText[0] == 'x' ||
               (nextText[0].compareTo('a') >= 0 && nextText[0].compareTo('h') <= 0))) {
            final joined = movePart + nextText;
            final (jm, jw) = _applyFontMapToFirst(joined, fontMap);
            final joinedNorm = _normaliseToken(jm, skipPieceTranslation: jw, notationMode: notationMode);
            final joinedMove = _resolveMove(joinedNorm, position, fontMap);
            if (joinedMove != null) {
              move = joinedMove;
              ti++; // consume the next token too
              _log(debugLogFile, '[MoveParser] split-token "$raw"+"${tokens[ti].text}" → "$joinedNorm"');
            }
          }
        }
        if (move != null) {
          if (!isPlausible) {
            // Legal at current or backtracked position — adopt the embedded number.
            currentMoveNum = num;
            expectBlack = targetIsBlack;
          }
          final moveNum = currentMoveNum; // non-null: set by isPlausible or !isPlausible branch above
          checkpoints.add(_PositionCheckpoint(
            moveNum: moveNum,
            isBlack: expectBlack,
            fen: position.fen,
            moveCount: moves.length,
          ));
          final fenBefore = position.fen;
          final (newPosition, san) = position.makeSan(move);
          final combinedBoundsStart = _startsWithFigurine(tok.start, charRects, figurines)
              ? tok.start + 1
              : tok.start;
          moves.add(CachedMove(
            moveNumber: moveNum,
            isBlack: expectBlack,
            san: san,
            rawToken: raw,
            fenBefore: fenBefore,
            fenAfter: newPosition.fen,
            bounds: _computeBounds(charRects, combinedBoundsStart, tok.end),
          ));
          position = newPosition;
          expectBlack = !expectBlack;
          if (!expectBlack) currentMoveNum = moveNum + 1;
        } else {
          skippedTokens++;
        }
        continue; // never fall through to plain-token path for combined tokens
      }

      if (currentMoveNum == null) continue;

      final (mapped2, wasMapped2) = _applyFontMapToFirst(raw, fontMap);
      final normalised = _normaliseToken(mapped2, skipPieceTranslation: wasMapped2, notationMode: notationMode);
      final move = _resolveMove(normalised, position, fontMap);
      if (move == null) {
        skippedTokens++;
        continue;
      }

      checkpoints.add(_PositionCheckpoint(
        moveNum: currentMoveNum,
        isBlack: expectBlack,
        fen: position.fen,
        moveCount: moves.length,
      ));
      final fenBefore = position.fen;
      final (newPosition, san) = position.makeSan(move);
      // Skip figurine prefix char when computing bounds so the overlay
      // highlights only the square/file part (e.g. "f3" not "♘f3").
      final boundsStart = _startsWithFigurine(tok.start, charRects, figurines)
          ? tok.start + 1
          : tok.start;
      moves.add(
        CachedMove(
          moveNumber: currentMoveNum,
          isBlack: expectBlack,
          san: san,
          rawToken: raw,
          fenBefore: fenBefore,
          fenAfter: newPosition.fen,
          bounds: _computeBounds(charRects, boundsStart, tok.end),
        ),
      );

      position = newPosition;
      expectBlack = !expectBlack;
      if (!expectBlack) currentMoveNum++;
    }

    _log(
      debugLogFile,
      '[MoveParser] fenSource=$fenSource  ${moves.length} move(s) parsed'
      '${skippedTokens > 0 ? "  ($skippedTokens token(s) skipped)" : ""}'
      '${figurines.isNotEmpty ? "  figurines=${figurines.length}" : ""}',
    );

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

  /// Merge standalone figurine tokens with the immediately following move-text
  /// token when they are spatially adjacent (same text line, no significant gap).
  ///
  /// E.g. a "♘" token followed by a "f3" token becomes a single "Nf3" token.
  /// Merges a standalone figurine token with the immediately following move text
  /// when they are spatially adjacent (same text line, no significant gap).
  ///
  /// E.g. a "♘" token followed by a "f3" token becomes a single "Nf3" token.
  /// The piece letter comes directly from the matching [DetectedFigurine].
  static List<_Token> _mergeFigurineTokens(
    List<_Token> tokens,
    List<PdfRect> charRects,
    List<DetectedFigurine> figurines,
  ) {
    const sameLineYTolerance = 12.0; // pt
    const adjacentXTolerance = 10.0; // pt

    final result = <_Token>[];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];

      // A standalone single-char token that spatially matches a figurine.
      if (tok.end - tok.start == 1 && i + 1 < tokens.length) {
        final fig = _figurineForCharPos(tok.start, charRects, figurines);
        if (fig != null) {
          final next = tokens[i + 1];

          // Use the figurine's own bounds for proximity; fall back to charRects.
          final figRight = fig.bounds.right;
          final figMidY  = (fig.bounds.top + fig.bounds.bottom) / 2;
          final textLeft = _tokenLeft(charRects, next.start, next.end);
          final textMidY = _tokenMidY(charRects, next.start, next.end);

          final sameY = textMidY != null &&
              (figMidY - textMidY).abs() < sameLineYTolerance;
          final close = textLeft != null &&
              textLeft - figRight < adjacentXTolerance;

          if (sameY && close) {
            result.add(_Token(fig.piece + next.text, tok.start, next.end));
            i++; // consume next token
            continue;
          }
        }
      }

      result.add(tok);
    }
    return result;
  }

  /// Returns the [DetectedFigurine] whose visual bounds overlap the charRect at
  /// [charIdx], or null if none matches. Used to identify figurine tokens.
  static DetectedFigurine? _figurineForCharPos(
    int charIdx,
    List<PdfRect> charRects,
    List<DetectedFigurine> figurines,
  ) {
    if (charIdx >= charRects.length || figurines.isEmpty) return null;
    const yTol = 15.0;
    const xTol =  5.0;
    final r = charRects[charIdx];
    if (r.isEmpty) return null;
    final midY = (r.top + r.bottom) / 2;
    for (final fig in figurines) {
      final figMidY = (fig.bounds.top + fig.bounds.bottom) / 2;
      if ((midY - figMidY).abs() > yTol) continue;
      if (r.right < fig.bounds.left - xTol) continue;
      if (r.left  > fig.bounds.right + xTol) continue;
      return fig;
    }
    return null;
  }

  /// Returns true if the character at [charIdx] spatially overlaps a detected
  /// figurine. Used to skip the figurine glyph when computing move bounds.
  static bool _startsWithFigurine(
    int charIdx,
    List<PdfRect> charRects,
    List<DetectedFigurine> figurines,
  ) =>
      _figurineForCharPos(charIdx, charRects, figurines) != null;

  static double? _tokenLeft(List<PdfRect> rects, int start, int end) {
    double? v;
    for (int i = start; i < end && i < rects.length; i++) {
      if (rects[i].isEmpty) continue;
      v = v == null ? rects[i].left : math.min(v, rects[i].left);
    }
    return v;
  }

  static double? _tokenMidY(List<PdfRect> rects, int start, int end) {
    double? top, bottom;
    for (int i = start; i < end && i < rects.length; i++) {
      final r = rects[i];
      if (r.isEmpty) continue;
      top = top == null ? r.top : math.max(top, r.top);
      bottom = bottom == null ? r.bottom : math.min(bottom, r.bottom);
    }
    return (top != null && bottom != null) ? (top + bottom) / 2 : null;
  }

  /// Replace the first character of [token] using [fontMap] before any
  /// language normalisation, so fontMap entries always take priority over
  /// the French/German piece-letter translations in [_normaliseToken].
  ///
  /// Returns the (possibly modified) token and a flag that is true when a
  /// fontMap entry was found (so the caller can skip redundant language
  /// translation — the mapped value is already an English piece letter).
  /// When the mapping is "" (pawn glyph) the token is returned unchanged
  /// because the file letter is already the first character of the move.
  static (String, bool) _applyFontMapToFirst(
      String token, Map<String, String>? fontMap) {
    if (fontMap == null || token.isEmpty) return (token, false);
    final mapped = fontMap[token[0]];
    if (mapped == null) return (token, false);
    // Pawn glyph: the file letter is already present — keep token as-is.
    if (mapped.isEmpty) return (token, true);
    return (mapped + token.substring(1), true);
  }

  static bool _isDigit(String c) {
    final code = c.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  /// Legality-constrained move matching: when strict SAN parsing fails, try to
  /// match the token against all legal moves by extracting destination squares.
  ///
  /// Strategy: extract all square references (e.g. "e4", "f7") from the token,
  /// then for each destination square, try to construct valid SAN patterns that
  /// would reach it. This handles malformed tokens where strict parsing fails.
  static dc.Move? _matchTokenToLegalMove(String token, dc.Position pos) {
    if (token.isEmpty) return null;

    // Extract all square references (e.g. "e4", "f7") from token.
    final squarePattern = RegExp(r'[a-h][1-8]');
    final tokenSquares = squarePattern.allMatches(token)
        .map((m) => m.group(0)!)
        .toList();

    if (tokenSquares.isEmpty) return null;

    try {
      // For each destination square found in token, try all piece + destination
      // combinations that could be legal moves.
      for (final destSquare in tokenSquares) {
        // Try: piece + dest, capture + dest, just dest, etc.
        final patterns = [
          destSquare,
          'K$destSquare',
          'Q$destSquare',
          'R$destSquare',
          'B$destSquare',
          'N$destSquare',
          'x$destSquare',
          'Kx$destSquare',
          'Qx$destSquare',
          'Rx$destSquare',
          'Bx$destSquare',
          'Nx$destSquare',
        ];

        for (final pattern in patterns) {
          final move = _parseSan(pos, pattern);
          if (move != null) {
            // Extra validation: if token has a piece letter, verify it matches.
            final moveSan = pos.makeSan(move).$2;
            final tokenPiece = RegExp(r'([KQRBN])').firstMatch(token)?.group(1);
            final sanPiece = RegExp(r'([KQRBN])').firstMatch(moveSan)?.group(1);

            if (tokenPiece != null && sanPiece != null && tokenPiece != sanPiece) {
              continue;
            }
            return move;
          }
        }
      }
    } catch (_) {
      return null;
    }

    return null;
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

/// One node in the FEN tree built during move parsing.
/// Saved *before* each accepted move so we can backtrack when commentary
/// moves corrupt [position] or [currentMoveNum].
class _PositionCheckpoint {
  const _PositionCheckpoint({
    required this.moveNum,
    required this.isBlack,
    required this.fen,
    required this.moveCount,
  });
  final int moveNum;
  final bool isBlack;
  final String fen;
  final int moveCount;
}
