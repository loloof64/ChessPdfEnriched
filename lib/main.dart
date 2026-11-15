import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal .chessbook reader: text on the left with clickable moves, board on the right.
/// Book path: first program argument, else CHESSBOOK, else the dev sample (no file picker yet).
void main(List<String> args) {
  // ponytail: dev default relative to the project root (what an IDE run uses); replace by a file picker
  const sample = 'pipeline/work/fab/attaque_minorite.chessbook';
  final path = args.firstOrNull ?? io.Platform.environment['CHESSBOOK'] ?? (io.File(sample).existsSync() ? sample : null);
  runApp(ReaderApp(book: path == null ? null : Book.load(path)));
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

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key, required this.book});

  final Book? book;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ChessPdfEnriched',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.brown)),
        home: book == null
            ? const Scaffold(body: Center(child: Text('Aucun livre : passer le chemin du .chessbook en argument ou dans CHESSBOOK')))
            : ReaderPage(book: book!),
      );
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book});

  final Book book;

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

  Widget _block(Map<String, dynamic> block, Map<String, Map<String, dynamic>> moves) {
    final text = block['text'] as String;
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: 16, height: 1.4)),
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
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('${moves.length} coups, ${moves.length - nOk} illégaux (en rouge)', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            for (final b in (data['blocks'] as List)) _block(b as Map<String, dynamic>, moves),
            if ((data['diagrams'] as List).isNotEmpty)
              Wrap(spacing: 12, runSpacing: 12, children: [
                for (final d in (data['diagrams'] as List).cast<Map<String, dynamic>>())
                  InkWell(
                    onTap: () => _pickDiagram(d),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: d['id'] == selected ? Colors.brown : Colors.transparent, width: 3)),
                      child: Column(children: [
                        if (widget.book.images[d['image']] != null) Image.memory(widget.book.images[d['image']]!, width: 150),
                        Text('${d['id']}  (confiance ${d['confidence']})', style: Theme.of(context).textTheme.labelSmall),
                      ]),
                    ),
                  ),
              ]),
          ]),
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
