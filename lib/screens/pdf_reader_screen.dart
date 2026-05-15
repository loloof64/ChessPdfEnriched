import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

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

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      setState(() {
        _document = doc;
        _isLoading = false;
      });
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

  void _goToPreviousPage() {
    if (_currentPage > 1) setState(() => _currentPage--);
  }

  void _goToNextPage() {
    final total = _document!.pages.length;
    if (_currentPage < total) setState(() => _currentPage++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
    return Stack(
      children: [
        PdfPageView(
          document: _document,
          pageNumber: _currentPage,
        ),
        // Future: overlay for clickable regions goes here
      ],
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
