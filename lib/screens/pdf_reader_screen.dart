import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../chess/analysis_cache.dart';
import '../chess/models.dart';
import '../chess/move_parser.dart';
import '../chess/moves_panel.dart';

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

  // Per-document page cache.
  Map<int, PageAnalysis> _cache = {};
  // Analysis for the currently displayed page.
  PageAnalysis? _pageAnalysis;
  // Index of the selected move (-1 = show starting position).
  int _selectedMoveIndex = -1;
  // True while the page's move analysis is being computed.
  bool _analysing = false;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
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

  void _changePage(int page) {
    setState(() {
      _currentPage = page;
      _pageAnalysis = _cache[page];
      _selectedMoveIndex = -1;
    });
    _loadPageAnalysis(page);
  }

  // -------------------------------------------------------------------------
  // Analysis

  Future<void> _reanalyse() async {
    await AnalysisCache.clear(widget.filePath);
    setState(() {
      _cache.clear();
      _pageAnalysis = null;
      _selectedMoveIndex = -1;
    });
    await _loadPageAnalysis(_currentPage);
  }

  Future<void> _loadPageAnalysis(int pageNumber, {String? forcedFen}) async {
    // Use cached result if available (and no override is requested).
    if (forcedFen == null && _cache.containsKey(pageNumber)) {
      setState(() {
        _pageAnalysis = _cache[pageNumber];
        _selectedMoveIndex = -1;
      });
      return;
    }

    setState(() => _analysing = true);

    try {
      final page = _document!.pages[pageNumber - 1];
      final rawText = await page.loadText();
      if (rawText == null) {
        _setPageAnalysis(
          pageNumber,
          PageAnalysis(
            startFen: '',
            fenSource: FenSource.standard,
            moves: const [],
          ),
        );
        return;
      }

      final inheritedFen = _inheritedFenForPage(pageNumber, rawText.fullText);

      final analysis = MoveParser.parse(
        rawText,
        page.height,
        inheritedFen: inheritedFen,
        forcedFen: forcedFen,
      );

      _cache[pageNumber] = analysis;
      await AnalysisCache.save(widget.filePath, _cache);

      if (mounted) _setPageAnalysis(pageNumber, analysis);
    } catch (_) {
      if (mounted) {
        _setPageAnalysis(
          pageNumber,
          PageAnalysis(
            startFen: '',
            fenSource: FenSource.standard,
            moves: const [],
          ),
        );
      }
    }
  }

  void _setPageAnalysis(int pageNumber, PageAnalysis analysis) {
    setState(() {
      if (pageNumber == _currentPage) {
        _pageAnalysis = analysis;
        _selectedMoveIndex = -1;
      }
      _analysing = false;
    });
  }

  /// If the page's text does not open a new game (no "1." near the start),
  /// inherit the last FEN from the previous page.
  String? _inheritedFenForPage(int pageNumber, String fullText) {
    if (pageNumber <= 1) return null;
    final prevAnalysis = _cache[pageNumber - 1];
    if (prevAnalysis == null || prevAnalysis.moves.isEmpty) return null;

    final sample =
        fullText.length > 200 ? fullText.substring(0, 200) : fullText;
    if (RegExp(r'\b1\.').hasMatch(sample)) return null;

    return prevAnalysis.moves.last.fenAfter;
  }

  /// Called when the user manually supplies a starting FEN from the dialog.
  void _onStartFenProvided(String fen) {
    _loadPageAnalysis(_currentPage, forcedFen: fen);
  }

  // -------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-analyse moves',
            onPressed: _analysing ? null : _reanalyse,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _document != null ? _buildNavigationBar() : null,
    );
  }

  Widget _buildBody() {
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
            Text('Failed to load PDF:\n$_error', textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            children: [
              PdfPageView(document: _document, pageNumber: _currentPage),
              if (_analysing)
                const Positioned(
                  bottom: 8,
                  right: 8,
                  child: _AnalysingBadge(),
                ),
            ],
          ),
        ),
        Container(
          width: 280,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: Colors.grey.shade300)),
          ),
          child: _buildChessPanel(),
        ),
      ],
    );
  }

  Widget _buildChessPanel() {
    final analysis = _pageAnalysis;
    if (analysis == null) {
      return const Center(child: CircularProgressIndicator());
    }

    const fallbackFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    return MovesPanel(
      moves: analysis.moves,
      startFen: analysis.startFen.isNotEmpty ? analysis.startFen : fallbackFen,
      fenSource: analysis.fenSource,
      selectedIndex: _selectedMoveIndex,
      onMoveSelected: (idx) => setState(() => _selectedMoveIndex = idx),
      onStartFenProvided: _onStartFenProvided,
    );
  }

  Widget _buildNavigationBar() {
    final total = _document!.pages.length;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed: _currentPage > 1 ? _goToPreviousPage : null,
          ),
          Text(
            'Page $_currentPage of $total',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: _currentPage < total ? _goToNextPage : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AnalysingBadge extends StatelessWidget {
  const _AnalysingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 6),
          Text(
            'Analysing…',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
