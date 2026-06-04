import 'dart:math' show min;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../chess/analysis_cache.dart';
import '../chess/board_detector.dart';
import '../chess/chess_piece_classifier.dart';
import '../chess/figurine_classifier.dart';
import '../chess/figurine_detector.dart';
import '../chess/models.dart';
import '../chess/move_parser.dart';
import '../chess/moves_panel.dart';
import '../l10n/app_localizations.dart';

class PdfReaderScreen extends StatefulWidget {
  final String filePath;

  const PdfReaderScreen({super.key, required this.filePath});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  PdfDocument? _document;
  int _currentPage = 1;
  bool _isLoading = true;
  String? _error;

  // Per-document page cache: page number → list of games on that page.
  Map<int, List<PageAnalysis>> _cache = {};
  // Per-page figurine detection results (FAN mode only).
  final Map<int, List<DetectedFigurine>> _figurinesCache = {};
  // Per-page candidate blob boxes for debug overlay (FAN mode only).
  final Map<int, List<MoveBounds>> _wordBoxesCache = {};
  // Per-page move bounding boxes detected by the CV pipeline (FAN mode only).
  final Map<int, List<MoveBounds>> _moveBoxesCache = {};
  // Per-page ALL blobs tested by the figurine classifier (debug).
  final Map<int, List<BlobResult>> _blobResultsCache = {};
  // Learnt character→piece mapping for the current document's chess font.
  // Shared across all pages so every fuzzy match discovery benefits later pages.
  final Map<String, String> _fontMap = {};
  // Games for the currently displayed page.
  List<PageAnalysis>? _pageGames;
  // Index of the selected game within the current page (for multi-game pages).
  int _selectedGameIndex = 0;
  // Index of the selected move (-1 = show starting position).
  int _selectedMoveIndex = -1;
  // True while the page's move analysis is being computed.
  bool _analysing = false;
  // Progress during a full-document reanalysis: (current page, total pages).
  // Null when analysing a single page or not analysing.
  ({int current, int total})? _analysingProgress;
  // Figurine glyph classifier — loaded once per document session.
  FigurineClassifier? _figurineClassifier;
  // Figurine detector — wraps the classifier for per-page glyph detection.
  FigurineDetector? _figurineDetector;
  // Notation mode selected by the user in the options dialog.
  NotationMode _notationMode = NotationMode.textSan;
  // Render scale used for figurine detection (forwarded from options dialog;
  // placeholder for a future zoom feature — currently always 2.0).
  // ignore: prefer_final_fields
  double _renderScale = 2.0;
  // Figurines detected on the current page (FAN mode only).
  List<DetectedFigurine>? _detectedFigurines;
  // Debug: word blobs detected on the current page.
  List<MoveBounds>? _detectedWordBoxes;
  // Debug: move boxes detected by the CV pipeline on the current page.
  List<MoveBounds>? _detectedMoveBoxes;
  // Debug: all blobs tested by the figurine classifier on the current page.
  List<BlobResult>? _detectedBlobResults;
  // Debug: whether to show word-blob rectangles in red.
  bool _showWordBoxOverlay = false;
  // Debug: whether to show move-box rectangles in blue.
  bool _showMoveBoxOverlay = false;
  // Debug: whether to show all classifier-tested blobs.
  bool _showBlobOverlay = false;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
      _figurineClassifier = await FigurineClassifier.load();
      _figurineDetector = FigurineDetector(classifier: _figurineClassifier!);

      final doc = await PdfDocument.openFile(widget.filePath);
      final cached = await AnalysisCache.load(widget.filePath);

      setState(() {
        _document = doc;
        _isLoading = false;
        if (cached != null) _cache = cached;
      });

      await _loadPageAnalysis(1);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _document?.dispose();
    _figurineClassifier?.dispose();
    super.dispose();
  }

  String get _fileName {
    final sep = widget.filePath.contains('/') ? '/' : '\\';
    return widget.filePath.split(sep).last;
  }

  // -------------------------------------------------------------------------
  // Navigation

  void _goToPreviousPage() {
    if (_currentPage > 1) _changePage(_currentPage - 1);
  }

  void _goToNextPage() {
    final total = _document!.pages.length;
    if (_currentPage < total) _changePage(_currentPage + 1);
  }

  void _goToFirstPage() {
    if (_currentPage != 1) _changePage(1);
  }

  void _goToLastPage() {
    final total = _document!.pages.length;
    if (_currentPage != total) _changePage(total);
  }

  Future<void> _showGoToPageDialog() async {
    final total = _document!.pages.length;
    final controller = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Icon(Icons.find_in_page),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '1 – $total'),
          autofocus: true,
          onSubmitted: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1 && n <= total) Navigator.pop(ctx, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () {
              final n = int.tryParse(controller.text);
              if (n != null && n >= 1 && n <= total) Navigator.pop(ctx, n);
            },
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
    if (result != null) _changePage(result);
  }

  void _changePage(int page) {
    setState(() {
      _currentPage = page;
      _pageGames = _cache[page];
      _detectedFigurines  = _figurinesCache[page];
      _detectedWordBoxes  = _wordBoxesCache[page];
      _detectedMoveBoxes  = _moveBoxesCache[page];
      _detectedBlobResults = _blobResultsCache[page];
      _selectedGameIndex = 0;
      _selectedMoveIndex = -1;
    });
    _loadPageAnalysis(page);
  }

  // -------------------------------------------------------------------------
  // Analysis

  Future<void> _showGenerateOptionsDialog() async {
    final l = AppLocalizations.of(context)!;
    NotationMode selectedMode = _notationMode;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l.analysisOptions),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.notationModeLabel),
              const SizedBox(height: 8),
              RadioGroup<NotationMode>(
                groupValue: selectedMode,
                onChanged: (v) {
                  if (v != null) setDialogState(() => selectedMode = v);
                },
                child: Column(
                  children: [
                    RadioListTile<NotationMode>(
                      title: Text(l.textSanNotation),
                      value: NotationMode.textSan,
                    ),
                    RadioListTile<NotationMode>(
                      title: Text(l.figurineFanNotation),
                      value: NotationMode.figurineFan,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.analyse),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _notationMode = selectedMode);
      await _reanalyse();
    }
  }

  Future<void> _reanalyse() async {
    await AnalysisCache.clear(widget.filePath);
    setState(() {
      _cache.clear();
      _figurinesCache.clear();
      _wordBoxesCache.clear();
      _moveBoxesCache.clear();
      _blobResultsCache.clear();
      _detectedFigurines   = null;
      _detectedWordBoxes   = null;
      _detectedMoveBoxes   = null;
      _detectedBlobResults = null;
      _pageGames = null;
      _selectedGameIndex = 0;
      _selectedMoveIndex = -1;
      _analysing = true;
    });
    try {
      final totalPages = _document!.pages.length;
      for (int page = 1; page <= totalPages; page++) {
        if (!mounted) break;
        if (mounted) {
          setState(() => _analysingProgress = (current: page, total: totalPages));
        }
        await _loadPageAnalysis(page);
        if (mounted) setState(() => _analysing = true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _analysing = false;
          _analysingProgress = null;
        });
      }
    }
  }

  Future<void> _loadPageAnalysis(
    int pageNumber, {
    Map<int, String>? forcedFens,
    Set<int>? forcedIntermediates,
    Set<int>? forcedNotADiagrams,
    NotationMode? notationMode,
  }) async {
    // Use cached result if available (and no override is requested).
    // Still load raw text so the debug button reflects the current page.
    if (forcedFens == null &&
        forcedIntermediates == null &&
        forcedNotADiagrams == null &&
        _cache.containsKey(pageNumber)) {
      setState(() {
        _pageGames           = _cache[pageNumber];
        _detectedFigurines   = _figurinesCache[pageNumber];
        _detectedWordBoxes   = _wordBoxesCache[pageNumber];
        _detectedMoveBoxes   = _moveBoxesCache[pageNumber];
        _detectedBlobResults = _blobResultsCache[pageNumber];
        _selectedGameIndex = 0;
        _selectedMoveIndex = -1;
      });
      return;
    }

    setState(() => _analysing = true);

    try {
      final page = _document!.pages[pageNumber - 1];
      final rawText = await page.loadText();
      if (rawText == null) {
        _setPageGames(pageNumber, [
          PageAnalysis(
            startFen: '',
            fenSource: FenSource.standard,
            moves: const [],
          ),
        ]);
        return;
      }

      final effectiveMode = notationMode ?? _notationMode;

      final inheritedFen = _inheritedFenForPage(pageNumber, rawText.fullText);

      final boardResult = await BoardDetector.detectBoards(
        page,
        rawText.charRects,
      );

      // Compute word-level bounding boxes from the PDF text layer.
      // Always needed (FAN mode uses them for per-block figurine detection).
      if (kDebugMode) {
        debugPrint('[WordBoxes] page $pageNumber page size: '
            '${page.width.toStringAsFixed(2)} × ${page.height.toStringAsFixed(2)} pt');
      }
      final wb = _computeWordBoxes(rawText, pageNumber,
          boardRects: boardResult.boardRects);
      _wordBoxesCache[pageNumber] = wb;
      if (mounted) setState(() => _detectedWordBoxes = wb);

      // In FAN mode, run the CV pipeline: segment blobs per word block,
      // classify figurines, OCR non-figurines, test SAN.
      List<DetectedFigurine>? detectedFigurines;
      if (effectiveMode == NotationMode.figurineFan &&
          _figurineDetector != null) {
        final rendered = await FigurineDetector.renderPage(page,
            scale: _renderScale);
        if (rendered != null) {
          final result = _computeMoveBoxesCv(
            wb, rawText.charRects, rawText.fullText,
            rendered, page.height, _renderScale, _figurineDetector!,
          );
          detectedFigurines = result.figurines;
          _moveBoxesCache[pageNumber]    = result.moveBoxes;
          _blobResultsCache[pageNumber]  = result.blobs;
          if (mounted) {
            setState(() {
              _detectedMoveBoxes   = result.moveBoxes;
              _detectedBlobResults = result.blobs;
            });
          }
        }
        _figurinesCache[pageNumber] = detectedFigurines ?? [];
        if (mounted) { setState(() => _detectedFigurines = detectedFigurines); }
      }

      // Use auto-detected FENs if available (user override takes precedence).
      // Board i's FEN belongs to segment i+1 (the text that follows the board diagram).
      final autoDetectedFens = <int, String>{};
      for (int i = 0; i < boardResult.detectedFens.length; i++) {
        final fen = boardResult.detectedFens[i];
        if (fen != null) autoDetectedFens[i + 1] = fen;
      }

      final games = MoveParser.parse(
        rawText,
        page.height,
        preComputedSplits: boardResult.splitIndices,
        topOfPageBoardDetected: boardResult.topOfPageBoardDetected,
        inheritedFen: inheritedFen,
        forcedFens:
            forcedFens ?? (autoDetectedFens.isEmpty ? null : autoDetectedFens),
        forcedIntermediates: forcedIntermediates,
        forcedNotADiagrams: forcedNotADiagrams,
        fontMap: _fontMap,
        notationMode: effectiveMode,
        detectedFigurines: detectedFigurines,
      );

      final totalMoves = games.fold(0, (s, g) => s + g.moves.length);
      debugPrint(
        '[ChessPdf] page $pageNumber ($effectiveMode) → '
        '${games.length} game(s), $totalMoves move(s)'
        '${detectedFigurines != null && detectedFigurines.isNotEmpty ? ", ${detectedFigurines.length} figurine(s)" : ""}',
      );

      _cache[pageNumber] = games;
      await AnalysisCache.save(widget.filePath, _cache);

      if (mounted) _setPageGames(pageNumber, games);
    } on ChessPieceClassifierException catch (e) {
      debugPrint('[ChessPdf] classifier error: $e');
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('TFLite model error'),
            content: Text(e.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[ChessPdf] page $pageNumber analysis error: $e\n$st');
      if (mounted) {
        _setPageGames(pageNumber, [
          PageAnalysis(
            startFen: '',
            fenSource: FenSource.standard,
            moves: const [],
          ),
        ]);
      }
    }
  }

  void _setPageGames(int pageNumber, List<PageAnalysis> games) {
    setState(() {
      if (pageNumber == _currentPage) {
        _pageGames = games;
        _selectedGameIndex = 0;
        _selectedMoveIndex = -1;
      }
      _analysing = false;
    });
  }

  /// Groups charRects into content chunks using local gap context.
  ///
  /// A "chunk" is any contiguous unit: a chess move ("1.♕xf7+"), a word,
  /// a hyphenated fragment, or a mix of text and figurine glyphs.
  ///
  /// Instead of a global per-page threshold, each gap is compared to the
  /// recent local context: a rolling window of the last [_kWindowSize] gaps.
  /// A gap is a chunk boundary when it is more than [_kSplitFactor]× the
  /// local median — or when it goes negative (line / column wrap).
  ///
  /// This is naturally generic: tight body text, wide-spaced titles, and
  /// figurine notation all self-calibrate from their own surroundings.
  // A gap larger than this is always a line-wrap / column-change.
  // Kerning produces at most a few pt of overlap; real wraps jump 50–400 pt.
  static const double _kLineWrapThreshold = -5.0;
  // A gap is a word boundary when it exceeds the 25th-percentile of recent
  // gaps by at least this margin.  Using p25 (not median) keeps the baseline
  // anchored to the intra-char spacing even when many short words appear and
  // word-space gaps start to outnumber intra-char gaps in the window.
  static const double _kWordSpaceMargin  = 0.5;
  static const int    _kWindowSize       = 6;

  static List<MoveBounds> _computeWordBoxes(
    PdfPageRawText rawText,
    int pageNumber, {
    List<PdfRect> boardRects = const [],
    double minWidthPt = 8.0,
    double minHeightPt = 7.0,
    double boardMarginFactor = 0.15,
  }) {
    final rects = rawText.charRects;
    final raw = <MoveBounds>[];

    // Rolling window of ALL recent gaps (positive AND negative), so that
    // even fonts whose intra-char gaps are slightly negative establish the
    // correct local baseline without being excluded from the window.
    final window = <double>[];
    double localThreshold() {
      if (window.isEmpty) return _kWordSpaceMargin;
      final s = [...window]..sort();
      final p25 = s[s.length ~/ 4]; // 25th-percentile ≈ typical intra-char gap
      // Split when gap exceeds p25 by the margin, but never below 1.0 pt
      // (avoid splitting on tight kerning pairs).
      return (p25 + _kWordSpaceMargin).clamp(1.0, double.infinity);
    }

    double? gTop, gBottom, gLeft, gRight;
    double? prevRight;

    void flushGroup() {
      if (gLeft == null || gRight == null || gTop == null || gBottom == null) return;
      final lineH = gTop! - gBottom!;
      final ext = lineH * 0.35;
      raw.add(MoveBounds(
        left:   gLeft!   - lineH * 0.05,
        top:    gTop!    + lineH * 0.10,
        right:  gRight!  + ext,
        bottom: gBottom! - lineH * 0.30,
      ));
      gTop = gBottom = gLeft = gRight = prevRight = null;
    }

    final fullText = rawText.fullText;

    for (int i = 0; i < rects.length; i++) {
      final r = rects[i];
      if (r.isEmpty) continue;
      // Skip whitespace characters — in some PDFs they carry non-empty rects
      // that split the inter-word gap into two small sub-gaps, defeating detection.
      if (i < fullText.length && fullText[i].trim().isEmpty) continue;

      if (prevRight != null) {
        final gap = r.left - prevRight!;
        if (gap < _kLineWrapThreshold) {
          flushGroup();
          window.clear();
        } else {
          if (gap > localThreshold()) {
            flushGroup();
            // Don't add word-space gaps to the window — they inflate p25
            // and make the next boundary harder to detect.
          } else {
            window.add(gap);
            if (window.length > _kWindowSize) window.removeAt(0);
          }
        }
      }

      gLeft   ??= r.left;
      gRight  = r.right;
      gBottom = gBottom == null ? r.bottom : (r.bottom < gBottom! ? r.bottom : gBottom);
      gTop    = gTop    == null ? r.top    : (r.top    > gTop!    ? r.top    : gTop);
      prevRight = r.right;
    }
    flushGroup();

    // Filter: drop noise boxes and boxes inside (or near) board diagrams.
    final words = raw.where((b) {
      if (b.right - b.left < minWidthPt) return false;
      if (b.top - b.bottom < minHeightPt) return false;
      final cx = (b.left + b.right) / 2;
      final cy = (b.top  + b.bottom) / 2;
      for (final br in boardRects) {
        final mw = (br.right - br.left) * boardMarginFactor;
        final mh = (br.top - br.bottom) * boardMarginFactor;
        if (cx >= br.left - mw && cx <= br.right + mw &&
            cy >= br.bottom - mh && cy <= br.top + mh) { return false; }
      }
      return true;
    }).toList();

    debugPrint('[WordBoxes] page $pageNumber → ${words.length} chunk(s)'
        ' (${raw.length - words.length} filtered)');
    for (int wi = 0; wi < words.length && wi < 6; wi++) {
      final b = words[wi];
      debugPrint('[WordBoxes]   [$wi] '
          'left=${b.left.toStringAsFixed(1)} right=${b.right.toStringAsFixed(1)} '
          'width=${(b.right - b.left).toStringAsFixed(1)}pt');
    }
    return words;
  }

  // SAN move pattern (English piece letters only).
  static final _sanMoveRegex = RegExp(
    r'^(O-O-O|O-O|[KQRBN]([a-h]|[1-8]|[a-h][1-8])?x?[a-h][1-8]|[a-h](x[a-h])?[1-8])(=[QRBN])?[+#]?$',
  );


  /// Per-block CV pipeline:
  ///   • No figurine in block → OCR the whole block text.
  ///   • Figurine(s) found    → OCR left part + piece letter + OCR right part.
  ///   Then strip move number / annotations and test against the SAN regex.
  static ({List<MoveBounds> moveBoxes, List<DetectedFigurine> figurines, List<BlobResult> blobs})
      _computeMoveBoxesCv(
    List<MoveBounds> wordBlocks,
    List<PdfRect> charRects,
    String fullText,
    RenderedPage rendered,
    double pageHeight,
    double renderScale,
    FigurineDetector detector,
  ) {
    final moveBoxes    = <MoveBounds>[];
    final allFigurines = <DetectedFigurine>[];
    final allBlobs     = <BlobResult>[];

    for (int i = 0; i < wordBlocks.length; i++) {
      final blockBounds = wordBlocks[i];

      // Detect figurines (if any) inside this block.
      final blobs = detector.analyseWordBlock(
          rendered, blockBounds, pageHeight, renderScale);
      allBlobs.addAll(blobs);
      final figurines = blobs.where((b) => b.piece != null).toList();

      String assembled;

      if (figurines.isEmpty) {
        // No figurine → OCR the whole block.
        assembled = _ocrRegion(blockBounds, charRects, fullText);
        if (kDebugMode && assembled.isNotEmpty) {
          debugPrint('[BlockAnalysis] block[$i] no figurine → ocr "$assembled"');
        }
      } else {
        // Has figurine(s): collect them for the overlay and build the string.
        for (final f in figurines) {
          allFigurines.add(DetectedFigurine(
              bounds: f.bounds, piece: f.piece!, confidence: f.confidence));
          if (kDebugMode) {
            debugPrint('[BlockAnalysis] block[$i] '
                'figurine@${f.bounds.left.toStringAsFixed(1)}'
                ' → ${f.piece}(conf=${f.confidence.toStringAsFixed(2)})');
          }
        }

        // Sort figurines left→right, then interleave OCR segments.
        figurines.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
        final buf = StringBuffer();
        double segLeft = blockBounds.left;
        for (final f in figurines) {
          // OCR text to the left of this figurine.
          final leftRegion = MoveBounds(
            left: segLeft, right: f.bounds.left,
            top: blockBounds.top, bottom: blockBounds.bottom,
          );
          buf.write(_ocrRegion(leftRegion, charRects, fullText));
          buf.write(f.piece);
          segLeft = f.bounds.right;
        }
        // OCR text to the right of the last figurine.
        final rightRegion = MoveBounds(
          left: segLeft, right: blockBounds.right,
          top: blockBounds.top, bottom: blockBounds.bottom,
        );
        buf.write(_ocrRegion(rightRegion, charRects, fullText));
        assembled = buf.toString();
        if (kDebugMode) {
          debugPrint('[BlockAnalysis] block[$i] assembled → "$assembled"');
        }
      }

      if (kDebugMode) debugPrint('[BlockString] block[$i] → "$assembled"');
      if (assembled.isEmpty) continue;

      // Strip move-number prefix and trailing annotations, then test SAN.
      var text = assembled.trim();
      text = text.replaceFirst(RegExp(r'^\d+\.+\s*'), '');
      text = text.replaceFirst(RegExp(r'[!?]+$'), '');

      if (text.isNotEmpty && _sanMoveRegex.hasMatch(text)) {
        if (kDebugMode) debugPrint('[MoveCheck] block[$i] "$text" → MATCH');
        moveBoxes.add(blockBounds);
      } else {
        if (kDebugMode && text.isNotEmpty) {
          debugPrint('[MoveCheck] block[$i] "$text" → no match');
        }
      }
    }

    debugPrint('[MoveBoxesCv] → ${moveBoxes.length} move(s)'
        ', ${allFigurines.length} figurine(s), ${allBlobs.length} blob(s) tested');
    return (moveBoxes: moveBoxes, figurines: allFigurines, blobs: allBlobs);
  }

  /// Returns the concatenation of all PDF text chars whose rect centre falls
  /// within [region], in left-to-right order.  Skips whitespace characters.
  static String _ocrRegion(
    MoveBounds region,
    List<PdfRect> charRects,
    String fullText,
  ) {
    final chars = <(double x, String ch)>[];
    for (int i = 0; i < charRects.length; i++) {
      final r = charRects[i];
      if (r.isEmpty) continue;
      final cx = (r.left + r.right) / 2;
      final cy = (r.top  + r.bottom) / 2;
      if (cx >= region.left  && cx <= region.right &&
          cy >= region.bottom && cy <= region.top) {
        if (i < fullText.length) {
          final ch = fullText[i];
          if (ch.trim().isNotEmpty) chars.add((cx, ch));
        }
      }
    }
    chars.sort((a, b) => a.$1.compareTo(b.$1));
    return chars.map((e) => e.$2).join();
  }

  /// Returns the PDF text character whose rect centre is closest to [blobBounds].
  /// Returns null for whitespace or if no match is found.

  /// If the page's text does not open a new game (no "1." near the start),
  /// inherit the last FEN from the last game of the previous page.
  String? _inheritedFenForPage(int pageNumber, String fullText) {
    if (pageNumber <= 1) return null;
    final prevGames = _cache[pageNumber - 1];
    if (prevGames == null || prevGames.isEmpty) return null;
    final lastGame = prevGames.last;

    // Inherit the last-reached position; if no moves were parsed yet on that
    // page (board detected but all analysis is on the next page), fall back to
    // the game's start FEN — but only when it came from a real source.
    final String? fenToInherit;
    if (lastGame.moves.isNotEmpty) {
      fenToInherit = lastGame.moves.last.fenAfter;
    } else if (lastGame.fenSource == FenSource.userProvided ||
        lastGame.fenSource == FenSource.detectedInText ||
        lastGame.fenSource == FenSource.userConfirmedIntermediate) {
      fenToInherit = lastGame.startFen;
    } else {
      fenToInherit = null;
    }
    if (fenToInherit == null) return null;

    final sample = fullText.length > 200
        ? fullText.substring(0, 200)
        : fullText;
    if (RegExp(r'\b1\.').hasMatch(sample)) return null;

    return fenToInherit;
  }


  /// Collects user overrides already persisted in the page cache so they
  /// survive a re-parse triggered by a new user action.
  ({
    Map<int, String> forcedFens,
    Set<int> forcedIntermediates,
    Set<int> forcedNotADiagrams,
  })
  _collectUserOverrides(int pageNumber) {
    final existing = _cache[pageNumber];
    final forcedFens = <int, String>{};
    final forcedIntermediates = <int>{};
    final forcedNotADiagrams = <int>{};
    if (existing != null) {
      for (int i = 0; i < existing.length; i++) {
        if (existing[i].fenSource == FenSource.userProvided) {
          forcedFens[i] = existing[i].startFen;
        }
        if (existing[i].fenSource == FenSource.userConfirmedIntermediate) {
          forcedIntermediates.add(i);
        }
        if (existing[i].fenSource == FenSource.userConfirmedNotADiagram) {
          forcedNotADiagrams.add(i);
        }
      }
    }
    return (
      forcedFens: forcedFens,
      forcedIntermediates: forcedIntermediates,
      forcedNotADiagrams: forcedNotADiagrams,
    );
  }

  /// Called when the user manually supplies a starting FEN from the dialog.
  void _onStartFenProvided(String fen, int gameIndex) {
    final overrides = _collectUserOverrides(_currentPage);
    overrides.forcedFens[gameIndex] = fen;
    overrides.forcedIntermediates.remove(gameIndex);
    overrides.forcedNotADiagrams.remove(gameIndex);
    _loadPageAnalysis(
      _currentPage,
      forcedFens: overrides.forcedFens,
      forcedIntermediates: overrides.forcedIntermediates.isEmpty
          ? null
          : overrides.forcedIntermediates,
      forcedNotADiagrams: overrides.forcedNotADiagrams.isEmpty
          ? null
          : overrides.forcedNotADiagrams,
    );
  }

  /// Called when the user overrides a diagram to be treated as intermediate.
  /// The forced FEN (if any) is kept so the board position is preserved.
  void _onMarkAsIntermediate(int gameIndex) {
    final overrides = _collectUserOverrides(_currentPage);
    // Do NOT remove forcedFens[gameIndex] — the position shown before discarding
    // must be preserved as the starting point of the intermediate game.
    overrides.forcedIntermediates.add(gameIndex);
    overrides.forcedNotADiagrams.remove(gameIndex);
    _loadPageAnalysis(
      _currentPage,
      forcedFens: overrides.forcedFens.isEmpty ? null : overrides.forcedFens,
      forcedIntermediates: overrides.forcedIntermediates,
      forcedNotADiagrams: overrides.forcedNotADiagrams.isEmpty
          ? null
          : overrides.forcedNotADiagrams,
    );
  }

  /// Called when the user marks a suspected diagram as not a chess board.
  void _onMarkAsNotADiagram(int gameIndex) {
    final overrides = _collectUserOverrides(_currentPage);
    overrides.forcedFens.remove(gameIndex);
    overrides.forcedIntermediates.remove(gameIndex);
    overrides.forcedNotADiagrams.add(gameIndex);
    _loadPageAnalysis(
      _currentPage,
      forcedFens: overrides.forcedFens.isEmpty ? null : overrides.forcedFens,
      forcedIntermediates: overrides.forcedIntermediates.isEmpty
          ? null
          : overrides.forcedIntermediates,
      forcedNotADiagrams: overrides.forcedNotADiagrams,
    );
  }

  /// Called when the user undoes a "not a diagram" override, reverting to
  /// the auto-detected suspected-diagram state.
  void _onResetToDiagram(int gameIndex) {
    final overrides = _collectUserOverrides(_currentPage);
    overrides.forcedFens.remove(gameIndex);
    overrides.forcedIntermediates.remove(gameIndex);
    overrides.forcedNotADiagrams.remove(gameIndex);
    _loadPageAnalysis(
      _currentPage,
      forcedFens: overrides.forcedFens.isEmpty ? null : overrides.forcedFens,
      forcedIntermediates: overrides.forcedIntermediates.isEmpty
          ? null
          : overrides.forcedIntermediates,
      forcedNotADiagrams: overrides.forcedNotADiagrams.isEmpty
          ? null
          : overrides.forcedNotADiagrams,
    );
  }

  // -------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (kDebugMode && _detectedBlobResults != null)
            IconButton(
              icon: Text(
                'B',
                style: TextStyle(
                  color: _showBlobOverlay ? Colors.orange : null,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  decoration: _showBlobOverlay ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.orange,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip: 'Toggle classifier blob overlay',
              onPressed: () =>
                  setState(() => _showBlobOverlay = !_showBlobOverlay),
            ),
          if (kDebugMode && _detectedMoveBoxes != null)
            IconButton(
              icon: Text(
                '♛',
                style: TextStyle(
                  color: _showMoveBoxOverlay ? Colors.blue : null,
                  fontSize: 20,
                  decoration: _showMoveBoxOverlay ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.blue,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip: 'Toggle move-box overlay',
              onPressed: () =>
                  setState(() => _showMoveBoxOverlay = !_showMoveBoxOverlay),
            ),
          if (kDebugMode && _detectedFigurines != null)
            IconButton(
              icon: Text(
                'W',
                style: TextStyle(
                  color: _showWordBoxOverlay ? Colors.red : null,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  decoration: _showWordBoxOverlay ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.red,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip: 'Toggle word-blob overlay',
              onPressed: () =>
                  setState(() => _showWordBoxOverlay = !_showWordBoxOverlay),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l.reanalyse,
            onPressed: _analysing ? null : _showGenerateOptionsDialog,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _document != null ? _buildNavigationBar() : null,
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 8),
            Text(l.failedToLoad(_error!), textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 300,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Text(
                  l.editingStartPositions,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(child: _buildChessPanel()),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final page = _document!.pages[_currentPage - 1];
              final games = _pageGames;
              final moves = (games != null && games.isNotEmpty)
                  ? games[_selectedGameIndex.clamp(0, games.length - 1)].moves
                  : const <CachedMove>[];
              return Stack(
                children: [
                  PdfPageView(document: _document, pageNumber: _currentPage),
                  _PdfMoveOverlay(
                    moves: moves,
                    pageWidth: page.width,
                    pageHeight: page.height,
                    widgetSize: constraints.biggest,
                    selectedIndex: _selectedMoveIndex,
                    onMoveSelected: (idx) =>
                        setState(() => _selectedMoveIndex = idx),
                  ),
                  if (kDebugMode &&
                      _showWordBoxOverlay &&
                      _detectedWordBoxes != null)
                    _WordBoxOverlay(
                      wordBoxes: _detectedWordBoxes!,
                      pageWidth: page.width,
                      pageHeight: page.height,
                      widgetSize: constraints.biggest,
                    ),
                  if (kDebugMode &&
                      _showMoveBoxOverlay &&
                      _detectedMoveBoxes != null)
                    _WordBoxOverlay(
                      wordBoxes: _detectedMoveBoxes!,
                      pageWidth: page.width,
                      pageHeight: page.height,
                      widgetSize: constraints.biggest,
                      color: Colors.blue,
                    ),
                  if (kDebugMode &&
                      _showBlobOverlay &&
                      _detectedBlobResults != null)
                    _BlobOverlay(
                      blobs: _detectedBlobResults!,
                      pageWidth: page.width,
                      pageHeight: page.height,
                      widgetSize: constraints.biggest,
                    ),
                  if (_analysing)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: _AnalysingBadge(progress: _analysingProgress),
                    ),
                ],
              );
            },
          ),
        ),
        Container(
          width: 300,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: Colors.grey.shade300)),
          ),
          child: _buildPreviewPanel(),
        ),
      ],
    );
  }

  Widget _buildChessPanel() {
    final l = AppLocalizations.of(context)!;
    final games = _pageGames;
    if (games == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (games.length == 1) {
      return _buildGamePanel(games[0], 0);
    }

    // Multiple games on this page: show a selector at the top.
    final safeIdx = _selectedGameIndex.clamp(0, games.length - 1);
    return Column(
      children: [
        _buildGameSelector(games, safeIdx, l),
        Expanded(child: _buildGamePanel(games[safeIdx], safeIdx)),
      ],
    );
  }

  Widget _buildGameSelector(
    List<PageAnalysis> games,
    int selectedIdx,
    AppLocalizations l,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (int i = 0; i < games.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text(
                  games[i].header ?? l.gameNumber(i + 1),
                  style: const TextStyle(fontSize: 11),
                ),
                selected: selectedIdx == i,
                onSelected: (_) => setState(() {
                  _selectedGameIndex = i;
                  _selectedMoveIndex = -1;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGamePanel(PageAnalysis analysis, int gameIndex) {
    const fallbackFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    return MovesPanel(
      startFen: analysis.startFen.isNotEmpty ? analysis.startFen : fallbackFen,
      fenSource: analysis.fenSource,
      header: analysis.header,
      onStartFenProvided: (fen) => _onStartFenProvided(fen, gameIndex),
      onMarkAsIntermediate: () => _onMarkAsIntermediate(gameIndex),
      onMarkAsNotADiagram: () => _onMarkAsNotADiagram(gameIndex),
      onResetToDiagram: () => _onResetToDiagram(gameIndex),
    );
  }

  Widget _buildPreviewPanel() {
    const fallbackFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final games = _pageGames;
    if (games == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final safeIdx = _selectedGameIndex.clamp(0, games.length - 1);
    final analysis = games[safeIdx];
    return PositionPreviewPanel(
      moves: analysis.moves,
      startFen: analysis.startFen.isNotEmpty ? analysis.startFen : fallbackFen,
      selectedIndex: _selectedMoveIndex,
    );
  }

  Widget _buildNavigationBar() {
    final l = AppLocalizations.of(context)!;
    final total = _document!.pages.length;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.first_page),
            onPressed: _currentPage > 1 ? _goToFirstPage : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: l.previousPage,
            onPressed: _currentPage > 1 ? _goToPreviousPage : null,
          ),
          Text(
            l.pageOf(_currentPage, total),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          IconButton(
            icon: const Icon(Icons.find_in_page),
            onPressed: _showGoToPageDialog,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: l.nextPage,
            onPressed: _currentPage < total ? _goToNextPage : null,
          ),
          IconButton(
            icon: const Icon(Icons.last_page),
            onPressed: _currentPage < total ? _goToLastPage : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PdfMoveOverlay extends StatelessWidget {
  const _PdfMoveOverlay({
    required this.moves,
    required this.pageWidth,
    required this.pageHeight,
    required this.widgetSize,
    required this.selectedIndex,
    required this.onMoveSelected,
  });

  final List<CachedMove> moves;
  final double pageWidth;
  final double pageHeight;
  final Size widgetSize;
  final int selectedIndex;
  final ValueChanged<int> onMoveSelected;

  @override
  Widget build(BuildContext context) {
    if (moves.isEmpty) return const SizedBox.shrink();
    final W = widgetSize.width;
    final H = widgetSize.height;
    if (W == 0 || H == 0) return const SizedBox.shrink();

    final scale = min(W / pageWidth, H / pageHeight);
    final xOffset = (W - pageWidth * scale) / 2;
    final yOffset = (H - pageHeight * scale) / 2;

    final primary = Theme.of(context).colorScheme.primary;
    final link = Colors.blue.shade700;

    return Stack(
      children: [
        for (int i = 0; i < moves.length; i++)
          if (moves[i].bounds case final b?)
            _buildHotspot(i, b, scale, xOffset, yOffset, primary, link),
      ],
    );
  }

  Widget _buildHotspot(
    int index,
    MoveBounds b,
    double scale,
    double xOffset,
    double yOffset,
    Color primary,
    Color link,
  ) {
    final fl = xOffset + b.left * scale;
    final ft = yOffset + (pageHeight - b.top) * scale;
    final fw = ((b.right - b.left) * scale).clamp(4.0, double.infinity);
    final fh = ((b.top - b.bottom) * scale).clamp(4.0, double.infinity);
    final isSelected = selectedIndex == index;

    return Positioned(
      left: fl,
      top: ft,
      width: fw,
      height: fh,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onMoveSelected(index),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected ? primary.withAlpha(55) : link.withAlpha(18),
              border: isSelected ? Border.all(color: primary, width: 1) : null,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

class _WordBoxOverlay extends StatelessWidget {
  const _WordBoxOverlay({
    required this.wordBoxes,
    required this.pageWidth,
    required this.pageHeight,
    required this.widgetSize,
    this.color = Colors.red,
  });

  final List<MoveBounds> wordBoxes;
  final double pageWidth;
  final Color color;
  final double pageHeight;
  final Size widgetSize;

  @override
  Widget build(BuildContext context) {
    if (wordBoxes.isEmpty) return const SizedBox.shrink();
    final W = widgetSize.width;
    final H = widgetSize.height;
    if (W == 0 || H == 0) return const SizedBox.shrink();

    final scale   = min(W / pageWidth, H / pageHeight);
    final xOffset = (W - pageWidth  * scale) / 2;
    final yOffset = (H - pageHeight * scale) / 2;

    // One-shot diagnostic on first build.
    debugPrint('[WordBoxOverlay] widgetSize=${W.toStringAsFixed(1)}×${H.toStringAsFixed(1)} '
        'page=${pageWidth.toStringAsFixed(1)}×${pageHeight.toStringAsFixed(1)} '
        'scale=${scale.toStringAsFixed(4)} xOff=${xOffset.toStringAsFixed(1)} yOff=${yOffset.toStringAsFixed(1)}');
    if (wordBoxes.isNotEmpty) {
      final b = wordBoxes.first;
      final px = xOffset + b.left * scale;
      final pw = (b.right - b.left) * scale;
      debugPrint('[WordBoxOverlay]   first box px: left=${px.toStringAsFixed(1)} '
          'width=${pw.toStringAsFixed(1)} '
          '(pdf left=${b.left.toStringAsFixed(2)} right=${b.right.toStringAsFixed(2)})');
    }

    return Stack(
      children: [
        for (final b in wordBoxes)
          Positioned(
            left:   xOffset + b.left * scale,
            top:    yOffset + (pageHeight - b.top) * scale,
            width:  ((b.right - b.left) * scale).clamp(1.0, double.infinity),
            height: ((b.top - b.bottom) * scale).clamp(1.0, double.infinity),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 1),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _AnalysingBadge extends StatelessWidget {
  const _AnalysingBadge({this.progress});

  final ({int current, int total})? progress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final String label;
    if (progress != null) {
      final pct = (progress!.current / progress!.total * 100).round();
      label = '${l.analysing} ${progress!.current}/${progress!.total} ($pct%)';
    } else {
      label = l.analysing;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Shows every blob tested by the figurine classifier.
/// Green = classified as a piece (figurine hit).
/// Red   = rejected (NotAFigurine).
/// The piece letter and confidence are shown as small text inside each box.
class _BlobOverlay extends StatelessWidget {
  const _BlobOverlay({
    required this.blobs,
    required this.pageWidth,
    required this.pageHeight,
    required this.widgetSize,
  });

  final List<BlobResult> blobs;
  final double pageWidth;
  final double pageHeight;
  final Size widgetSize;

  @override
  Widget build(BuildContext context) {
    if (blobs.isEmpty) return const SizedBox.shrink();
    final W = widgetSize.width;
    final H = widgetSize.height;
    if (W == 0 || H == 0) return const SizedBox.shrink();

    final scale   = min(W / pageWidth, H / pageHeight);
    final xOffset = (W - pageWidth  * scale) / 2;
    final yOffset = (H - pageHeight * scale) / 2;

    return Stack(
      children: [
        for (final blob in blobs)
          Positioned(
            left:   xOffset + blob.bounds.left * scale,
            top:    yOffset + (pageHeight - blob.bounds.top) * scale,
            width:  ((blob.bounds.right - blob.bounds.left) * scale)
                .clamp(2.0, double.infinity),
            height: ((blob.bounds.top - blob.bounds.bottom) * scale)
                .clamp(2.0, double.infinity),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: blob.piece != null ? Colors.green : Colors.red,
                  width: 1,
                ),
              ),
              child: blob.piece != null
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        '${blob.piece}${(blob.confidence * 100).round()}',
                        style: const TextStyle(
                          color: Colors.green,
                          fontSize: 7,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
      ],
    );
  }
}
