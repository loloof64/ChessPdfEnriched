import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal .chessbook reader: text on the left with clickable moves, board on the right.
/// Book to open at start: first program argument, else CHESSBOOK; otherwise the "Ouvrir" screen.
void main(List<String> args) {
  final path = args.firstOrNull ?? io.Platform.environment['CHESSBOOK'];
  runApp(ReaderApp(initial: path == null ? null : Book.load(path)));
}

class Book {
  Book(this.title, this.pages, this.images);

  final String title;
  final Map<int, Map<String, dynamic>> pages;
  final Map<String, Uint8List> images; // 'diagrams/p2_d1.png' -> bytes

  factory Book.load(String path) {
    final zip = ZipDecoder().decodeBytes(io.File(path).readAsBytesSync());
    Map<String, dynamic> json(String name) =>
        jsonDecode(utf8.decode(zip.findFile(name)!.readBytes()!)) as Map<String, dynamic>;
    final pages = <int, Map<String, dynamic>>{};
    for (final f in zip.files) {
      final m = RegExp(r'^pages/p(\d+)\.json$').firstMatch(f.name);
      if (m != null) pages[int.parse(m.group(1)!)] = json(f.name);
    }
    final images = {for (final f in zip.files) if (f.name.startsWith('diagrams/')) f.name: Uint8List.fromList(f.readBytes()!)};
    return Book(json('manifest.json')['title'] as String, pages, images);
  }
}

class ReaderApp extends StatefulWidget {
  const ReaderApp({super.key, this.initial});

  final Book? initial;

  @override
  State<ReaderApp> createState() => _ReaderAppState();
}

class _ReaderAppState extends State<ReaderApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late Book? book = widget.initial;

  Future<void> _open() async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: 'Ouvrir un livre',
        type: FileType.custom,
        allowedExtensions: ['chessbook'],
      );
      final path = picked.firstOrNull?.path;
      if (path != null) setState(() => book = Book.load(path));
    } catch (e) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text('Ouverture impossible : $e')));
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ChessPdfEnriched',
        scaffoldMessengerKey: _messenger,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.brown)),
        home: book == null
            ? Scaffold(
                body: Center(
                  child: FilledButton.icon(
                    onPressed: _open,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Ouvrir un livre (.chessbook)'),
                  ),
                ),
              )
            : ReaderPage(key: ValueKey(book), book: book!, onOpen: _open),
      );
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, required this.onOpen});

  final Book book;
  final VoidCallback onOpen;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int page = widget.book.pages.keys.reduce((a, b) => a < b ? a : b);
  String fen = kInitialFEN;
  String? selected, label;
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  void _pick(Map<String, dynamic> m) => setState(() {
        selected = m['id'] as String;
        fen = (m['fen'] as String?) ?? fen;
        // FEN after a white move: black to move, fullmove = n ('3. Cf3'); after a black move: fullmove = n + 1 ('2... d5')
        final f = fen.split(' ');
        final n = int.parse(f[5]);
        label = f[1] == 'b' ? '$n. ${m['raw']}' : '${n - 1}... ${m['raw']}';
      });

  void _pickDiagram(Map<String, dynamic> d) => setState(() {
        selected = d['id'] as String;
        fen = d['fen'] as String;
        label = 'Diagramme ${d['id']}${d['flipped'] == true ? ' (retourné : blancs en bas)' : ''}';
      });

  /// Text of a block, positioned where the block sits on the original page (page px scaled by [k]).
  Widget _block(Map<String, dynamic> block, Map<String, Map<String, dynamic>> moves, double k) {
    final text = block['text'] as String;
    final b = (block['bbox'] as List).cast<num>();
    // ponytail: font size from the box area and text length (OCR gives no font info); exact only for plain paragraphs
    final font = sqrt(b[2] * b[3] / (text.length.clamp(1, 100000) * 0.62)).clamp(9.0, 60.0) * k;
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final id in (block['moves'] as List).cast<String>()) {
      final m = moves[id]!;
      final s = (m['span'] as List).cast<int>();
      if (s[0] < pos) continue;
      spans.add(TextSpan(text: text.substring(pos, s[0])));
      final ok = m['ok'] as bool;
      final tap = TapGestureRecognizer()..onTap = ok ? () => _pick(m) : null;
      _taps.add(tap);
      spans.add(TextSpan(
        text: text.substring(s[0], s[1]),
        recognizer: tap,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: !ok ? Colors.red : (id == selected ? Colors.white : Colors.brown.shade800),
          backgroundColor: id == selected ? Colors.brown : null,
        ),
      ));
      pos = s[1];
    }
    spans.add(TextSpan(text: text.substring(pos)));
    return Positioned(
      left: b[0] * k,
      top: b[1] * k,
      width: b[2] * k,
      child: Text.rich(TextSpan(children: spans), style: TextStyle(fontSize: font, height: 1.25, color: Colors.black87)),
    );
  }

  Widget _figure(Map<String, dynamic> d, double k) {
    final b = (d['bbox'] as List).cast<num>();
    final bytes = widget.book.images[d['image']];
    return Positioned(
      left: b[0] * k,
      top: b[1] * k,
      width: b[2] * k,
      height: b[3] * k,
      child: InkWell(
        onTap: d['fen'] == null ? null : () => _pickDiagram(d),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: d['id'] == selected ? Colors.brown : Colors.transparent, width: 3)),
          child: bytes == null ? null : Image.memory(bytes, fit: BoxFit.fill),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final data = widget.book.pages[page]!;
    final moves = {for (final m in (data['moves'] as List)) (m as Map<String, dynamic>)['id'] as String: m};
    final nOk = moves.values.where((m) => m['ok'] as bool).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(icon: const Icon(Icons.folder_open), tooltip: 'Ouvrir un livre', onPressed: widget.onOpen),
          DropdownButton<int>(
            value: page,
            items: [for (final p in widget.book.pages.keys.toList()..sort()) DropdownMenuItem(value: p, child: Text('Page $p'))],
            onChanged: (p) => setState(() {
              page = p!;
              fen = kInitialFEN;
              selected = label = null;
            }),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth - 32;
            final k = w / (data['width'] as num);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${moves.length} coups, ${moves.length - nOk} illégaux (en rouge)', style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 8),
                Container(
                  width: w,
                  height: (data['height'] as num) * k,
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26)),
                  child: Stack(children: [
                    for (final d in (data['diagrams'] as List).cast<Map<String, dynamic>>()) _figure(d, k),
                    for (final b in (data['blocks'] as List).cast<Map<String, dynamic>>()) _block(b, moves, k),
                  ]),
                ),
              ]),
            );
          }),
        ),
        LayoutBuilder(builder: (context, _) {
          // board fits the window: at most 400 px, at most the height left under the app bar minus the caption
          final side = (MediaQuery.sizeOf(context).height - kToolbarHeight - 90).clamp(120.0, 400.0);
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              StaticChessboard(size: side, orientation: Side.white, fen: fen),
              const SizedBox(height: 8),
              Text(label ?? 'Cliquer sur un coup', style: Theme.of(context).textTheme.titleMedium),
            ]),
          );
        }),
      ]),
    );
  }
}
