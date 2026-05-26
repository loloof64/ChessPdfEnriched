import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../chess/analysis_cache.dart';
import '../chess/board_detector.dart';
import '../chess/chess_piece_classifier.dart';
import '../chess/figurine_classifier.dart';
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
  // Figurine glyph classifier — loaded once per document session.
  FigurineClassifier? _figurineClassifier;
  // Notation mode selected by the user in the options dialog.
  NotationMode _notationMode = NotationMode.textSan;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
      _figurineClassifier = await FigurineClassifier.load();

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
      _pageGames = null;
      _selectedGameIndex = 0;
      _selectedMoveIndex = -1;
      _analysing = true;
    });
    try {
      final totalPages = _document!.pages.length;
      for (int page = 1; page <= totalPages; page++) {
        if (!mounted) break;
        await _loadPageAnalysis(page);
        // Keep button disabled between pages during full-document reanalysis.
        if (mounted) setState(() => _analysing = true);
      }
    } finally {
      if (mounted) setState(() => _analysing = false);
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
        _pageGames = _cache[pageNumber];
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

      debugPrint('[ChessPdf] page $pageNumber raw text:\n${rawText.fullText}');
      debugPrint(
        '[ChessPdf] page $pageNumber code units (first 80):\n'
        '${rawText.fullText.runes.take(80).map((r) => 'U+${r.toRadixString(16).padLeft(4, '0')}').join(' ')}',
      );

      final inheritedFen = _inheritedFenForPage(pageNumber, rawText.fullText);

      final boardResult = await BoardDetector.detectBoards(
        page,
        rawText.charRects,
      );

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
        notationMode: notationMode ?? _notationMode,
      );

      debugPrint(
        '[ChessPdf] page $pageNumber → ${games.length} game(s), '
        '${games.map((g) => g.moves.length).join('+')} moves',
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
                  if (_analysing)
                    const Positioned(
                      bottom: 8,
                      right: 8,
                      child: _AnalysingBadge(),
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

class _AnalysingBadge extends StatelessWidget {
  const _AnalysingBadge();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
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
            l.analysing,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
