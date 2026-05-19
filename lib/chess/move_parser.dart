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
    // 6. Castling: "0-0-0" / "0-0" with digit zero → standard "O-O-O" / "O-O".
    //    Many chess books (especially French/Spanish) use zeros instead of O.
    //    Must check 0-0-0 before 0-0 to avoid a partial match.
    if (s.startsWith('0-0-0')) {
      s = 'O-O-O${s.substring(5)}';
    } else if (s.startsWith('0-0')) {
      s = 'O-O${s.substring(3)}';
    }
    // 7. If the first character looks like a non-English piece letter, translate.
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
            // First segment: board at top of page (if detected).
            // Later segments: always preceded by a confirmed board gap.
            forceSuspectedDiagram: i == 0 ? topOfPageBoardDetected : true,
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

    debugPrint('[MoveParser] header=$header  fenSource=$fenSource  FEN=$startFen');

    // ------------------------------------------------------------------
    // 3. Tokenise, skipping comments and variations.

    final tokens = _tokenise(text);

    // ------------------------------------------------------------------
    // 3b. Correct fullmove number from the first move-number token.
    // Board detection always emits fullmove=1; deduce the real number here.
    if (startFen.isNotEmpty) {
      final pureNumRxEarly = RegExp(r'^(\d+)\.+$');
      final combinedRxEarly = RegExp(r'^(\d+)\.{1,3}[^.]');
      for (final tok in tokens) {
        final t = tok.text;
        final pm = pureNumRxEarly.firstMatch(t) ?? combinedRxEarly.firstMatch(t);
        if (pm != null) {
          final num = int.tryParse(pm.group(1)!);
          if (num != null) {
            final parts = startFen.split(' ');
            if (parts.length == 6 && parts[5] != num.toString()) {
              parts[5] = num.toString();
              final correctedFen = parts.join(' ');
              try {
                position = dc.Chess.fromSetup(dc.Setup.parseFen(correctedFen));
                startFen = correctedFen;
              } catch (_) {}
            }
            break;
          }
        }
      }
    }

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
          // Apply fontMap before normalisation so it overrides language mappings.
          final normalised = _normaliseToken(_applyFontMapToFirst(movePart, fontMap));
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

      final normalised = _normaliseToken(_applyFontMapToFirst(raw, fontMap));
      final move = _resolveMove(normalised, position, fontMap);
      if (move == null) {
        debugPrint('[MoveParser] skip "$raw" (norm="$normalised") move=$currentMoveNum black=$expectBlack');
        continue;
      }

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

  /// Replace the first character of [token] using [fontMap] before any
  /// language normalisation, so fontMap entries always take priority over
  /// the French/German piece-letter translations in [_normaliseToken].
  static String _applyFontMapToFirst(String token, Map<String, String>? fontMap) {
    if (fontMap == null || token.isEmpty) return token;
    final mapped = fontMap[token[0]];
    if (mapped == null) return token;
    return mapped + token.substring(1);
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
