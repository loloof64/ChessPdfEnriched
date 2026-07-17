import 'dart:io' show File, FileMode;
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';

import '../chess/analysis_cache.dart';
import '../chess/board_detector.dart';
import '../chess/chess_piece_classifier.dart';
import '../chess/element_parser.dart';
import '../chess/figurine_classifier.dart';
import '../chess/figurine_detector.dart';
import '../chess/glyph_clusterer.dart';
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
  // Per-page parsed elements from element-by-element analysis (debug).
  final Map<int, List<ParsedElement>> _parsedElementsCache = {};
  // Per-page element bounding boxes for debug overlay (FAN mode only).
  final Map<int, List<MoveBounds>> _elementBoxesCache = {};
  // Learnt character→piece mapping for the current document's chess font.
  // Shared across all pages so every fuzzy match discovery benefits later pages.
  final Map<String, String> _fontMap = {};
  // Book-level glyph shape clusters + legality-vote labels (FAN mode).
  // What is constant across a printed book is the glyph *shape*, not its OCR
  // reading — see GlyphClusterer. Reset on full reanalysis.
  GlyphClusterer _glyphClusterer = GlyphClusterer();
  // Per-page CV block assemblies (raw fallback chars + cluster ids), kept so
  // the second analysis pass can re-parse with learnt cluster labels without
  // re-rendering and re-segmenting every page.
  final Map<int, List<CvBlock>> _cvBlocksCache = {};
  // Per-page board detection results, cached for the same reason.
  final Map<
    int,
    ({
      List<int> splitIndices,
      bool topOfPageBoardDetected,
      List<String?> detectedFens,
      List<PdfRect> boardRects,
    })
  > _boardResultCache = {};
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
  // Figurine glyph classifier (6-class {K,Q,R,B,N,NotAFigurine}) — loaded
  // once per document session; its own reject class replaces the former
  // separate NotAFigurine autoencoder.
  FigurineClassifier? _figurineClassifier;
  // Figurine detector — wraps the classifier for per-page glyph detection.
  FigurineDetector? _figurineDetector;
  // Element parser — parses word blocks element-by-element.
  ElementParser? _elementParser;
  // Notation mode selected by the user in the options dialog.
  NotationMode _notationMode = NotationMode.textSan;
  // Render scale used for figurine detection (forwarded from options dialog;
  // placeholder for a future zoom feature — currently always 3.0).
  // Raised from 2.0: at 2.0px/pt, antialiasing blurs tight kerning gaps
  // between touching glyphs (e.g. a figurine piece against an adjacent rank
  // digit) into gray pixels with no real whitespace channel, so the CCL
  // segmentation merges them and the width-based split fallback then cuts
  // through the glyph itself instead of at the true boundary.
  // ignore: prefer_final_fields
  double _renderScale = 3.0;
  // Debug: word blobs detected on the current page.
  List<MoveBounds>? _detectedWordBoxes;
  // Debug: move boxes detected by the CV pipeline on the current page.
  List<MoveBounds>? _detectedMoveBoxes;
  // Debug: element boxes (individual characters/glyphs within word blocks).
  List<MoveBounds>? _detectedElementBoxes;
  // Debug: whether to show word-blob rectangles in red.
  bool _showWordBoxOverlay = false;
  // Debug: whether to show move-box rectangles in blue.
  bool _showMoveBoxOverlay = false;
  // Debug: whether to show element boxes (individual elements within word blocks).
  bool _showElementOverlay = false;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
      _figurineClassifier = await FigurineClassifier.load();
      _figurineDetector = FigurineDetector(classifier: _figurineClassifier!);
      _elementParser = ElementParser(figurineClassifier: _figurineClassifier!);

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
      _detectedWordBoxes = _wordBoxesCache[page];
      _detectedMoveBoxes = _moveBoxesCache[page];
      _detectedElementBoxes = _elementBoxesCache[page];
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
    if (kDebugMode) {
      final docsDir = await getApplicationDocumentsDirectory();
      final logFile = File('${docsDir.path}/figurine_debug.log');
      if (logFile.existsSync()) logFile.deleteSync();
    }
    setState(() {
      _cache.clear();
      _figurinesCache.clear();
      _wordBoxesCache.clear();
      _moveBoxesCache.clear();
      _blobResultsCache.clear();
      _cvBlocksCache.clear();
      _boardResultCache.clear();
      _glyphClusterer = GlyphClusterer();
      _detectedWordBoxes = null;
      _detectedMoveBoxes = null;
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
          setState(
            () => _analysingProgress = (current: page, total: totalPages),
          );
        }
        await _loadPageAnalysis(page);
        if (mounted) setState(() => _analysing = true);
      }

      // Refinement passes: pass 1 accumulated glyph-cluster legality votes
      // across the whole document; once clusters are labeled, re-parse every
      // page with the labels applied (cheap: CV assemblies and board
      // detection are reused, only MoveParser runs again). Each pass can
      // unlock more moves → more votes → more labels, so iterate to a
      // fixpoint: repeat while the label or vote pool still grows (votes are
      // keyed by page:token, so re-parsing overwrites instead of stacking).
      const maxRefinePasses = 4;
      for (int pass = 0; pass < maxRefinePasses; pass++) {
        if (!mounted ||
            _notationMode != NotationMode.figurineFan ||
            _glyphClusterer.labels.isEmpty) {
          break;
        }
        final labelsBefore = _glyphClusterer.labels.length;
        final votesBefore = _glyphClusterer.voteCount;
        for (int page = 1; page <= totalPages; page++) {
          if (!mounted) break;
          setState(
            () => _analysingProgress = (current: page, total: totalPages),
          );
          // Keep any user-confirmed overrides from pass 1 (board-detected
          // FENs re-marked userProvided, confirmed diagrams…).
          final overrides = _collectUserOverrides(page);
          _cache.remove(page);
          await _loadPageAnalysis(
            page,
            reuseCv: true,
            forcedFens:
                overrides.forcedFens.isEmpty ? null : overrides.forcedFens,
            forcedIntermediates: overrides.forcedIntermediates.isEmpty
                ? null
                : overrides.forcedIntermediates,
            forcedNotADiagrams: overrides.forcedNotADiagrams.isEmpty
                ? null
                : overrides.forcedNotADiagrams,
          );
          if (mounted) setState(() => _analysing = true);
        }
        if (_glyphClusterer.labels.length == labelsBefore &&
            _glyphClusterer.voteCount == votesBefore) {
          break; // converged — another pass would parse identically
        }
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
    // Second-pass mode: reuse the cached CV assemblies and board detection
    // from the first pass and only re-run MoveParser — the learnt glyph
    // cluster labels are applied at token-build time, so no re-render or
    // re-segmentation is needed.
    bool reuseCv = false,
  }) async {
    // Use cached result if available (and no override is requested).
    // Still load raw text so the debug button reflects the current page.
    if (forcedFens == null &&
        forcedIntermediates == null &&
        forcedNotADiagrams == null &&
        _cache.containsKey(pageNumber)) {
      setState(() {
        _pageGames = _cache[pageNumber];
        _detectedWordBoxes = _wordBoxesCache[pageNumber];
        _detectedMoveBoxes = _moveBoxesCache[pageNumber];
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

      // Diagnostic logs written straight to a file — terminal/logcat output
      // gets truncated or drops lines under heavy volume, a file never does.
      String? debugLogFile;
      if (kDebugMode) {
        final docsDir = await getApplicationDocumentsDirectory();
        debugLogFile = '${docsDir.path}/figurine_debug.log';
      }

      final boardResult = (reuseCv ? _boardResultCache[pageNumber] : null) ??
          await BoardDetector.detectBoards(
            page,
            rawText.charRects,
            debugLogFile: debugLogFile,
          );
      _boardResultCache[pageNumber] = boardResult;

      _log(
        debugLogFile,
        '[WordBoxes] page $pageNumber page size: '
        '${page.width.toStringAsFixed(2)} × ${page.height.toStringAsFixed(2)} pt',
      );

      // Compute word-level bounding boxes from the PDF text layer.
      // Always needed (FAN mode uses them for per-block figurine detection).
      final wb = _computeWordBoxes(
        rawText,
        pageNumber,
        boardRects: boardResult.boardRects,
        debugLogFile: debugLogFile,
      );
      _wordBoxesCache[pageNumber] = wb.words;
      if (mounted) setState(() => _detectedWordBoxes = wb.words);

      // In FAN mode, run the CV pipeline: segment blobs per word block,
      // classify figurines, OCR non-figurines, test SAN.
      List<DetectedFigurine>? detectedFigurines;
      List<CvBlock>? cvBlocks;
      if (effectiveMode == NotationMode.figurineFan &&
          _figurineDetector != null) {
        if (reuseCv && _cvBlocksCache.containsKey(pageNumber)) {
          // Second pass: the CV assemblies (with cluster ids) are already
          // known — cluster labels are applied inside MoveParser.
          cvBlocks = _cvBlocksCache[pageNumber];
          detectedFigurines = _figurinesCache[pageNumber];
        } else {
          final rendered = await FigurineDetector.renderPage(
            page,
            scale: _renderScale,
          );
          if (rendered != null) {
            String? debugCropDir;
            if (kDebugMode) {
              final docsDir = await getApplicationDocumentsDirectory();
              debugCropDir = '${docsDir.path}/figurine_crops/page$pageNumber';
            }
            final result = await _computeMoveBoxesCv(
              wb.words,
              wb.chars,
              rawText.charRects,
              rawText.fullText,
              rendered,
              page.height,
              _renderScale,
              _figurineDetector!,
              _elementParser!,
              clusterer: _glyphClusterer,
              debugCropDir: debugCropDir,
              debugLogFile: debugLogFile,
            );
            detectedFigurines = result.figurines;
            cvBlocks = result.cvBlocks;
            _cvBlocksCache[pageNumber] = result.cvBlocks;
            _moveBoxesCache[pageNumber] = result.moveBoxes;
            _blobResultsCache[pageNumber] = result.blobs;
            _parsedElementsCache[pageNumber] = result.parsedElements;
            // Extract element bounding boxes from parsed elements
            final elementBoxes = result.parsedElements
                .map((e) => e.bounds)
                .toList();
            _elementBoxesCache[pageNumber] = elementBoxes;
            if (mounted) {
              setState(() {
                _detectedMoveBoxes = result.moveBoxes;
                _detectedElementBoxes = elementBoxes;
              });
            }
          }
          _figurinesCache[pageNumber] = detectedFigurines ?? [];
        }
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
        cvBlocks: cvBlocks,
        clusterLabel: _glyphClusterer.labelFor,
        onPieceVote: (clusterId, piece, tokenIndex) => _glyphClusterer.vote(
          source: '$pageNumber:$tokenIndex',
          clusterId: clusterId,
          piece: piece,
        ),
        debugLogFile: debugLogFile,
      );

      final totalMoves = games.fold(0, (s, g) => s + g.moves.length);
      _log(
        debugLogFile,
        '[ChessPdf] page $pageNumber ($effectiveMode) → '
        '${games.length} game(s), $totalMoves move(s)'
        '${detectedFigurines != null && detectedFigurines.isNotEmpty ? ", ${detectedFigurines.length} figurine(s)" : ""}',
      );
      if (effectiveMode == NotationMode.figurineFan) {
        _log(
          debugLogFile,
          '[GlyphClusterer] ${_glyphClusterer.debugSummary()}',
        );
      }

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
  static const double _kWordSpaceMargin = 0.5;
  static const int _kWindowSize = 6;

  static ({List<MoveBounds> words, List<List<MoveBounds>> chars})
  _computeWordBoxes(
    PdfPageRawText rawText,
    int pageNumber, {
    List<PdfRect> boardRects = const [],
    double minWidthPt = 8.0,
    double minHeightPt = 7.0,
    double boardMarginFactor = 0.15,
    String? debugLogFile,
  }) {
    final rects = rawText.charRects;
    final raw = <MoveBounds>[];
    // Per-word list of the individual PDF character rects (converted 1:1 to
    // MoveBounds) that compose it — kept so the figurine pipeline can crop
    // exactly what the PDF says each character's cell is, instead of trying
    // to re-derive character boundaries from rendered pixels (which fails
    // whenever two glyphs visually touch, e.g. a figurine glued to the next
    // letter with zero background between them).
    final rawChars = <List<MoveBounds>>[];
    var curChars = <MoveBounds>[];

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
      if (gLeft == null || gRight == null || gTop == null || gBottom == null) {
        curChars = [];
        return;
      }
      final lineH = gTop! - gBottom!;
      final extHor =
          lineH * 0.75; // Increased right margin to capture final letters
      raw.add(
        MoveBounds(
          left: gLeft! - lineH * 0.05,
          top: gTop! + lineH * 0.10,
          right: gRight! + extHor,
          bottom: gBottom! - lineH * 0.30,
        ),
      );
      rawChars.add(curChars);
      curChars = [];
      gTop = gBottom = gLeft = gRight = prevRight = null;
    }

    // charRects has exactly one entry per Unicode codepoint (pdfium's own
    // "char" unit); fullText is a UTF-16 Dart string where a codepoint
    // outside the BMP (plausible for figurine glyphs mapped into a
    // supplementary Private Use Area) takes two code units. Indexing
    // fullText by raw position would silently desync from charRects past
    // the first such character — `runes` decodes back to one entry per
    // codepoint, matching charRects 1:1 regardless of plane.
    final runes = rawText.fullText.runes.toList();

    for (int i = 0; i < rects.length; i++) {
      final r = rects[i];
      if (r.isEmpty) continue;
      // Skip whitespace characters — in some PDFs they carry non-empty rects
      // that split the inter-word gap into two small sub-gaps, defeating detection.
      if (i < runes.length && String.fromCharCode(runes[i]).trim().isEmpty) {
        continue;
      }

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

      gLeft ??= r.left;
      gRight = r.right;
      gBottom = gBottom == null
          ? r.bottom
          : (r.bottom < gBottom! ? r.bottom : gBottom);
      gTop = gTop == null ? r.top : (r.top > gTop! ? r.top : gTop);
      prevRight = r.right;
      curChars.add(
        MoveBounds(left: r.left, top: r.top, right: r.right, bottom: r.bottom),
      );
    }
    flushGroup();

    // Filter: drop noise boxes and boxes inside (or near) board diagrams.
    // Kept in lockstep with rawChars via index rather than a predicate
    // closure, since we need to filter both lists identically.
    final words = <MoveBounds>[];
    final wordsChars = <List<MoveBounds>>[];
    for (int i = 0; i < raw.length; i++) {
      final b = raw[i];
      if (b.right - b.left < minWidthPt) continue;
      if (b.top - b.bottom < minHeightPt) continue;
      final cx = (b.left + b.right) / 2;
      final cy = (b.top + b.bottom) / 2;
      var insideBoard = false;
      for (final br in boardRects) {
        final mw = (br.right - br.left) * boardMarginFactor;
        final mh = (br.top - br.bottom) * boardMarginFactor;
        if (cx >= br.left - mw &&
            cx <= br.right + mw &&
            cy >= br.bottom - mh &&
            cy <= br.top + mh) {
          insideBoard = true;
          break;
        }
      }
      if (insideBoard) continue;
      words.add(b);
      wordsChars.add(rawChars[i]);
    }

    _log(
      debugLogFile,
      '[WordBoxes] page $pageNumber → ${words.length} chunk(s)'
      ' (${raw.length - words.length} filtered)',
    );
    for (int wi = 0; wi < words.length && wi < 6; wi++) {
      final b = words[wi];
      _log(
        debugLogFile,
        '[WordBoxes]   [$wi] '
        'left=${b.left.toStringAsFixed(1)} right=${b.right.toStringAsFixed(1)} '
        'width=${(b.right - b.left).toStringAsFixed(1)}pt',
      );
    }
    return (words: words, chars: wordsChars);
  }

  // SAN move pattern (English piece letters only).
  static final _sanMoveRegex = RegExp(
    r'^(O-O-O|O-O|[KQRBN]([a-h]|[1-8]|[a-h][1-8])?x?[a-h][1-8]|[a-h](x[a-h])?[1-8])(=[QRBN])?[+#]?$',
  );

  /// Merges detector-confirmed figurines into the parsed-element list used
  /// for move assembly.
  ///
  /// The detector classifies clean CCL blob crops, while the elements come
  /// from OCR char rects — on scanned books those rects routinely cut a piece
  /// glyph in half or bleed into neighbours, so the element classifier
  /// (rightly) rejects the garbage crops and the piece identity found by the
  /// detector was thrown away (e.g. "♗e3+" assembling to "&e3+" because the
  /// OCR text layer maps the bishop to "&"). Here every element whose x-span
  /// lies mostly inside a confirmed figurine's bounds is replaced by a single
  /// figurine element carrying the detector's piece letter.
  static List<ParsedElement> _mergeFigurinesIntoElements(
    List<ParsedElement> elements,
    List<BlobResult> figurines,
  ) {
    if (figurines.isEmpty) return elements;

    double xOverlapFraction(MoveBounds elem, MoveBounds fig) {
      final overlap = min(elem.right, fig.right) - max(elem.left, fig.left);
      final width = elem.right - elem.left;
      return width <= 0 ? 0 : (overlap / width).clamp(0.0, 1.0);
    }

    final merged = <ParsedElement>[];
    final consumed = <BlobResult>{};
    for (final elem in elements) {
      BlobResult? hit;
      for (final f in figurines) {
        if (xOverlapFraction(elem.bounds, f.bounds) > 0.5) {
          hit = f;
          break;
        }
      }
      if (hit == null) {
        merged.add(elem);
      } else if (consumed.add(hit)) {
        merged.add(ParsedElement(
          text: hit.piece!,
          bounds: hit.bounds,
          type: 'figurine',
          confidence: hit.confidence,
          // Keep the replaced element's shape cluster so the detector's
          // piece identity and the cluster votes stay connected.
          clusterId: elem.clusterId,
        ));
      }
      // Further fragments of an already-consumed figurine are dropped.
    }
    // Figurines that overlapped no element at all still carry a piece letter
    // the assembly would otherwise miss — insert them at their x-position.
    for (final f in figurines) {
      if (!consumed.contains(f)) {
        merged.add(ParsedElement(
          text: f.piece!,
          bounds: f.bounds,
          type: 'figurine',
          confidence: f.confidence,
        ));
      }
    }
    merged.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    return merged;
  }

  /// Per-block CV pipeline:
  ///   • No figurine in block → OCR the whole block text.
  ///   • Figurine(s) found    → OCR left part + piece letter + OCR right part.
  ///   Then strip move number / annotations and test against the SAN regex.
  static Future<
    ({
      List<MoveBounds> moveBoxes,
      List<DetectedFigurine> figurines,
      List<BlobResult> blobs,
      List<ParsedElement> parsedElements,
      List<CvBlock> cvBlocks,
    })
  >
  _computeMoveBoxesCv(
    List<MoveBounds> wordBlocks,
    List<List<MoveBounds>> wordCharBounds,
    List<PdfRect> charRects,
    String fullText,
    RenderedPage rendered,
    double pageHeight,
    double renderScale,
    FigurineDetector detector,
    ElementParser elementParser, {
    GlyphClusterer? clusterer,
    String? debugCropDir,
    String? debugLogFile,
  }) async {
    final moveBoxes = <MoveBounds>[];
    final allFigurines = <DetectedFigurine>[];
    final allBlobs = <BlobResult>[];
    final allParsedElements = <ParsedElement>[];
    final cvBlocks = <CvBlock>[];

    for (int i = 0; i < wordBlocks.length; i++) {
      final blockBounds = wordBlocks[i];

      // NOTE: word blocks used to be pre-filtered here to skip the CV
      // pipeline on anything that "looked like plain prose" (decoded as
      // ordinary letters/digits/punctuation). That worked for PDFs with a
      // genuine custom figurine font (unmapped/private-use codepoints), but
      // this app also targets SCANNED books whose "text layer" is Tesseract
      // OCR output — piece icons there get OCR'd as ordinary ASCII letters
      // (e.g. a knight read as "4)", a queen as "W"), so real move blocks
      // like "23.4)xf7!" also "look like plain prose" and were being skipped
      // — silently discarding every move on the page. Now that the figurine
      // classifier is a properly calibrated 6-class model {K,Q,R,B,N,
      // NotAFigurine} (see project memory), it reliably rejects real prose
      // itself, so this pre-filter is no longer needed to avoid false
      // positives — it was only ever hiding real moves on OCR'd books.
      _log(
        debugLogFile,
        '[ComputeMoveBoxesCv] Processing word block[$i] at left=${blockBounds.left.toStringAsFixed(1)}',
      );

      // Detect figurines (if any) inside this block.
      final blobs = detector.analyseWordBlock(
        rendered,
        blockBounds,
        pageHeight,
        renderScale,
        minConfidence: 0.60,
        debugCropDir: debugCropDir == null ? null : '$debugCropDir/block$i',
        debugLogFile: debugLogFile,
      );
      allBlobs.addAll(blobs);
      final figurines = blobs.where((b) => b.piece != null).toList();

      _log(
        debugLogFile,
        '[ComputeMoveBoxesCv]   → ${blobs.length} blob(s), ${figurines.length} figurine(s)',
      );

      // Parse elements for all blocks to catch moves with figurines that may have
      // been missed by the figurine detector (low confidence, segmentation issues, etc).
      // Using the PDF's own per-character rects (when available) rather than CCL blob
      // bounds sidesteps the "glyphs touch with zero pixel gap" problem that pixel-based
      // segmentation can't solve.
      final charBounds = wordCharBounds[i];
      var parsedElements = await elementParser.parseWordBlock(
        rendered,
        blockBounds,
        pageHeight,
        renderScale,
        blobBounds: charBounds.isNotEmpty
            ? charBounds
            : blobs.map((b) => b.bounds).toList(),
        debugCropDir: debugCropDir == null
            ? null
            : '$debugCropDir/block${i}_elements',
        debugLogFile: debugLogFile,
        clusterer: clusterer,
      );
      // Re-inject the piece identities found on clean CCL blob crops: the
      // char-rect-derived element crops above are unreliable on scanned books
      // and their classification alone loses every figurine (see helper doc).
      if (figurines.isNotEmpty) {
        final before = parsedElements.where((e) => e.type == 'figurine').length;
        parsedElements = _mergeFigurinesIntoElements(parsedElements, figurines);
        final after = parsedElements.where((e) => e.type == 'figurine').length;
        if (after != before) {
          _log(
            debugLogFile,
            '[ComputeMoveBoxesCv]   → merged ${after - before} detector figurine(s) into elements',
          );
        }
      }
      allParsedElements.addAll(parsedElements);

      if (parsedElements.isNotEmpty) {
        final figElemCount = parsedElements
            .where((e) => e.type == 'figurine')
            .length;
        final textElemCount = parsedElements
            .where((e) => e.type == 'text')
            .length;
        _log(
          debugLogFile,
          '[ComputeMoveBoxesCv]   → ${parsedElements.length} element(s): '
          '$figElemCount figurine(s) [green], $textElemCount notAFigurine(s) [purple]',
        );
      }

      _log(
        debugLogFile,
        '[ComputeMoveBoxesCv]   → ${parsedElements.length} element(s) used for move assembly',
      );

      String assembled;
      // Per-glyph elements aligned with [assembled]: fallback char + shape
      // cluster id, so MoveParser can override chars with learnt cluster
      // labels and cast legality votes (empty for the fallback paths below).
      var blockElems = const <CvElement>[];

      // Build move string from parsed elements (both figurines and text)
      if (parsedElements.isNotEmpty) {
        final runes = fullText.runes.toList();

        // Convert block's PDF charRects to searchable format
        final pdfCharRects = <({MoveBounds bounds, String char, int index})>[];
        int charIndex = 0;
        for (int j = 0; j < charRects.length && j < runes.length; j++) {
          final r = charRects[j];
          if (r.isEmpty) continue;
          final ch = String.fromCharCode(runes[j]);
          if (ch.trim().isEmpty) continue; // Skip whitespace

          // Check if this PDF char is within the block bounds
          if (r.left >= blockBounds.left - 1 && r.right <= blockBounds.right + 1 &&
              r.top >= blockBounds.bottom - 1 && r.bottom <= blockBounds.top + 1) {
            pdfCharRects.add((
              bounds: MoveBounds(left: r.left, top: r.top, right: r.right, bottom: r.bottom),
              char: ch,
              index: charIndex,
            ));
            charIndex++;
          }
        }

        // Resolve text elements: for each text element, find closest PDF char by position
        final buf = StringBuffer();
        final elems = <CvElement>[];
        for (int elemIdx = 0; elemIdx < parsedElements.length; elemIdx++) {
          final elem = parsedElements[elemIdx];
          if (elem.type == 'figurine') {
            buf.write(elem.text);
            elems.add((char: elem.text, clusterId: elem.clusterId));
            _log(debugLogFile, '[BlockAnalysis] block[$i] elem[$elemIdx] fig="${elem.text}"');
          } else {
            // Find PDF character closest to this element by left position
            var bestMatch = pdfCharRects.firstOrNull;
            var bestDist = double.infinity;
            for (final pdfChar in pdfCharRects) {
              final dist = (elem.bounds.left - pdfChar.bounds.left).abs();
              if (dist < bestDist) {
                bestDist = dist;
                bestMatch = pdfChar;
              }
            }

            if (bestMatch != null && bestDist < 5.0) { // Tolerance: 5 pt
              buf.write(bestMatch.char);
              elems.add((char: bestMatch.char, clusterId: elem.clusterId));
              _log(debugLogFile, '[BlockAnalysis] block[$i] elem[$elemIdx] text="${bestMatch.char}" (dist=${bestDist.toStringAsFixed(1)})');
              // Remove matched char so we don't reuse it
              pdfCharRects.removeWhere((p) => p.index == bestMatch!.index);
            } else {
              // No OCR char matched this glyph. A '?' placeholder keeps the
              // glyph visible in the token so MoveParser can fuzzy-resolve
              // it by legality (e.g. "?xf4" → unique Qxf4) and cast a
              // cluster vote for it; once its shape cluster is labeled the
              // '?' is replaced by the real piece letter at token-build
              // time. An empty char hid the glyph entirely: the token
              // became "xf4", unresolvable and unable to vote.
              buf.write('?');
              elems.add((char: '?', clusterId: elem.clusterId));
              _log(debugLogFile, '[BlockAnalysis] block[$i] elem[$elemIdx] text=? (no match, bestDist=${bestDist.toStringAsFixed(1)})');
            }
          }
        }
        assembled = buf.toString();
        blockElems = elems;
        _log(
          debugLogFile,
          '[BlockAnalysis] block[$i] assembled (from elements) → "$assembled"',
        );

        // Also collect figurines for overlay
        for (final elem in parsedElements.where((e) => e.type == 'figurine')) {
          allFigurines.add(
            DetectedFigurine(
              bounds: elem.bounds,
              piece: elem.text,
              confidence: elem.confidence,
            ),
          );
        }
      } else {
        // Fallback: if no elements found, try old blob-based assembly
        if (figurines.isNotEmpty) {
          for (final f in figurines) {
            allFigurines.add(
              DetectedFigurine(
                bounds: f.bounds,
                piece: f.piece!,
                confidence: f.confidence,
              ),
            );
          }
          figurines.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
          final buf = StringBuffer();
          double segLeft = blockBounds.left;
          for (final f in figurines) {
            final leftRegion = MoveBounds(
              left: segLeft,
              right: f.bounds.left,
              top: blockBounds.top,
              bottom: blockBounds.bottom,
            );
            buf.write(_ocrRegion(leftRegion, charRects, fullText));
            buf.write(f.piece);
            segLeft = f.bounds.right;
          }
          final rightRegion = MoveBounds(
            left: segLeft,
            right: blockBounds.right,
            top: blockBounds.top,
            bottom: blockBounds.bottom,
          );
          buf.write(_ocrRegion(rightRegion, charRects, fullText));
          assembled = buf.toString();
          _log(
            debugLogFile,
            '[BlockAnalysis] block[$i] assembled (fallback) → "$assembled"',
          );
        } else {
          // No elements or figurines: OCR whole block
          assembled = _ocrRegion(blockBounds, charRects, fullText);
          if (assembled.isNotEmpty) {
            _log(
              debugLogFile,
              '[BlockAnalysis] block[$i] no figurine → ocr "$assembled"',
            );
          }
        }
      }

      _log(debugLogFile, '[BlockString] block[$i] → "$assembled"');
      // Keep empty assemblies when they carry clustered glyphs: a later
      // cluster label can still recover their text at token-build time.
      if (assembled.isEmpty && blockElems.every((e) => e.clusterId == null)) {
        continue;
      }

      // Every assembled block feeds MoveParser as one pre-built token: move
      // numbers ("14."), moves ("23.Nxf7!"), results and prose alike — the
      // parser's own tokenisation of the OCR text layer is bypassed entirely
      // for scanned books (prose tokens are skipped by the parser as usual).
      cvBlocks.add((text: assembled, bounds: blockBounds, elements: blockElems));

      // Strip move-number prefix and trailing annotations, then test SAN.
      var text = assembled.trim();
      text = text.replaceFirst(RegExp(r'^\d+\.+\s*'), '');
      text = text.replaceFirst(RegExp(r'[!?]+$'), '');

      if (text.isNotEmpty && _sanMoveRegex.hasMatch(text)) {
        _log(debugLogFile, '[MoveCheck] block[$i] "$text" → MATCH');
        moveBoxes.add(blockBounds);
      } else {
        if (text.isNotEmpty) {
          _log(debugLogFile, '[MoveCheck] block[$i] "$text" → no match');
        }
      }
    }

    _log(
      debugLogFile,
      '[MoveBoxesCv] → ${moveBoxes.length} move(s)'
      ', ${allFigurines.length} figurine(s), ${allBlobs.length} blob(s) tested',
    );
    return (
      moveBoxes: moveBoxes,
      figurines: allFigurines,
      blobs: allBlobs,
      parsedElements: allParsedElements,
      cvBlocks: cvBlocks,
    );
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
      debugPrint('[PdfReaderScreen] failed to write log: $e');
    }
  }

  /// Returns the concatenation of all PDF text chars whose rect centre falls
  /// within [region], in left-to-right order.  Skips whitespace characters.
  static String _ocrRegion(
    MoveBounds region,
    List<PdfRect> charRects,
    String fullText,
  ) {
    // charRects has exactly one entry per Unicode codepoint (pdfium's own
    // "char" unit), but fullText is a UTF-16 Dart string where any codepoint
    // outside the BMP (e.g. a figurine glyph mapped into a supplementary
    // Private Use Area) takes two code units. Indexing fullText by raw
    // position would silently desync from charRects after the first such
    // character. `runes` decodes surrogate pairs back into one entry per
    // codepoint, matching charRects 1:1 regardless of plane.
    final runes = fullText.runes.toList();
    final chars = <(double x, String ch)>[];
    for (int i = 0; i < charRects.length; i++) {
      final r = charRects[i];
      if (r.isEmpty) continue;
      final cx = (r.left + r.right) / 2;
      final cy = (r.top + r.bottom) / 2;
      if (cx >= region.left &&
          cx <= region.right &&
          cy >= region.bottom &&
          cy <= region.top) {
        if (i < runes.length) {
          final ch = String.fromCharCode(runes[i]);
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
          if (kDebugMode &&
              !_analysing &&
              _elementBoxesCache.containsKey(_currentPage))
            IconButton(
              icon: Text(
                'E',
                style: TextStyle(
                  color: _showElementOverlay ? Colors.purple : null,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  decoration: _showElementOverlay
                      ? TextDecoration.lineThrough
                      : null,
                  decorationColor: Colors.purple,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip:
                  'Toggle element overlay (individual chars/glyphs within word blocks)',
              onPressed: () {
                setState(() {
                  _detectedElementBoxes = _elementBoxesCache[_currentPage];
                  _showElementOverlay = !_showElementOverlay;
                });
              },
            ),
          if (kDebugMode &&
              !_analysing &&
              _moveBoxesCache.containsKey(_currentPage))
            IconButton(
              icon: Text(
                '♛',
                style: TextStyle(
                  color: _showMoveBoxOverlay ? Colors.blue : null,
                  fontSize: 20,
                  decoration: _showMoveBoxOverlay
                      ? TextDecoration.lineThrough
                      : null,
                  decorationColor: Colors.blue,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip: 'Toggle move-box overlay',
              onPressed: () {
                setState(() {
                  _detectedMoveBoxes = _moveBoxesCache[_currentPage];
                  _showMoveBoxOverlay = !_showMoveBoxOverlay;
                });
              },
            ),
          if (kDebugMode &&
              !_analysing &&
              _wordBoxesCache.containsKey(_currentPage))
            IconButton(
              icon: Text(
                'W',
                style: TextStyle(
                  color: _showWordBoxOverlay ? Colors.red : null,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  decoration: _showWordBoxOverlay
                      ? TextDecoration.lineThrough
                      : null,
                  decorationColor: Colors.red,
                  decorationThickness: 2.5,
                ),
              ),
              tooltip: 'Toggle word-blob overlay',
              onPressed: () {
                setState(() {
                  _detectedWordBoxes = _wordBoxesCache[_currentPage];
                  _showWordBoxOverlay = !_showWordBoxOverlay;
                });
              },
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
                      _showElementOverlay &&
                      _detectedElementBoxes != null)
                    _ElementOverlay(
                      elements: _detectedElementBoxes!,
                      pageWidth: page.width,
                      pageHeight: page.height,
                      widgetSize: constraints.biggest,
                      parsedElements: _parsedElementsCache[_currentPage] ?? [],
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

    final scale = min(W / pageWidth, H / pageHeight);
    final xOffset = (W - pageWidth * scale) / 2;
    final yOffset = (H - pageHeight * scale) / 2;

    // One-shot diagnostic on first build.
    debugPrint(
      '[WordBoxOverlay] widgetSize=${W.toStringAsFixed(1)}×${H.toStringAsFixed(1)} '
      'page=${pageWidth.toStringAsFixed(1)}×${pageHeight.toStringAsFixed(1)} '
      'scale=${scale.toStringAsFixed(4)} xOff=${xOffset.toStringAsFixed(1)} yOff=${yOffset.toStringAsFixed(1)}',
    );
    if (wordBoxes.isNotEmpty) {
      final b = wordBoxes.first;
      final px = xOffset + b.left * scale;
      final pw = (b.right - b.left) * scale;
      debugPrint(
        '[WordBoxOverlay]   first box px: left=${px.toStringAsFixed(1)} '
        'width=${pw.toStringAsFixed(1)} '
        '(pdf left=${b.left.toStringAsFixed(2)} right=${b.right.toStringAsFixed(2)})',
      );
    }

    return Stack(
      children: [
        for (final b in wordBoxes)
          Positioned(
            left: xOffset + b.left * scale,
            top: yOffset + (pageHeight - b.top) * scale,
            width: ((b.right - b.left) * scale).clamp(1.0, double.infinity),
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

/// Shows parsed elements (individual characters/glyphs within word blocks).
/// Green = classified as a figurine (chess piece).
/// Purple = classified as text (regular character).
/// The element text and confidence are shown as small text inside each box.
class _ElementOverlay extends StatelessWidget {
  const _ElementOverlay({
    required this.elements,
    required this.pageWidth,
    required this.pageHeight,
    required this.widgetSize,
    required this.parsedElements,
  });

  final List<MoveBounds> elements;
  final List<ParsedElement> parsedElements;
  final double pageWidth;
  final double pageHeight;
  final Size widgetSize;

  @override
  Widget build(BuildContext context) {
    if (elements.isEmpty) return const SizedBox.shrink();
    final W = widgetSize.width;
    final H = widgetSize.height;
    if (W == 0 || H == 0) return const SizedBox.shrink();

    final scale = min(W / pageWidth, H / pageHeight);
    final xOffset = (W - pageWidth * scale) / 2;
    final yOffset = (H - pageHeight * scale) / 2;

    return Stack(
      children: [
        for (int i = 0; i < elements.length && i < parsedElements.length; i++)
          _buildElementBox(
            elements[i],
            parsedElements[i],
            scale,
            xOffset,
            yOffset,
          ),
      ],
    );
  }

  Widget _buildElementBox(
    MoveBounds bounds,
    ParsedElement parsed,
    double scale,
    double xOffset,
    double yOffset,
  ) {
    final isFigurine = parsed.type == 'figurine';
    final color = isFigurine ? Colors.green : Colors.deepPurple;
    final textColor = isFigurine ? Colors.green : Colors.deepPurple;

    return Positioned(
      left: xOffset + bounds.left * scale,
      top: yOffset + (pageHeight - bounds.top) * scale,
      width: ((bounds.right - bounds.left) * scale).clamp(2.0, double.infinity),
      height: ((bounds.top - bounds.bottom) * scale).clamp(
        2.0,
        double.infinity,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            '${parsed.text}${(parsed.confidence * 100).round()}',
            style: TextStyle(
              color: textColor,
              fontSize: 7,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
