import 'dart:convert';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal .chessbook reader: text on the left with clickable moves, board on the right.
/// Book path comes from the CHESSBOOK environment variable (no file picker yet).
void main() {
  final path = io.Platform.environment['CHESSBOOK'];
  runApp(ReaderApp(book: path == null ? null : Book.load(path)));
}

class Book {
  Book(this.title, this.pages);

  final String title;
  final Map<int, Map<String, dynamic>> pages;

  factory Book.load(String path) {
    final zip = ZipDecoder().decodeBytes(io.File(path).readAsBytesSync());
    Map<String, dynamic> json(String name) =>
        jsonDecode(utf8.decode(zip.findFile(name)!.readBytes()!)) as Map<String, dynamic>;
    final pages = <int, Map<String, dynamic>>{};
    for (final f in zip.files) {
      final m = RegExp(r'^pages/p(\d+)\.json$').firstMatch(f.name);
      if (m != null) pages[int.parse(m.group(1)!)] = json(f.name);
    }
    return Book(json('manifest.json')['title'] as String, pages);
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
            ? const Scaffold(body: Center(child: Text('Aucun livre : lancer avec CHESSBOOK=chemin.chessbook')))
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
        label = m['san'] as String?;
        fen = (m['fen'] as String?) ?? fen;
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
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            StaticChessboard(size: 400, orientation: Side.white, fen: fen),
            const SizedBox(height: 8),
            Text(label ?? 'Cliquer sur un coup', style: Theme.of(context).textTheme.titleMedium),
          ]),
        ),
      ]),
    );
  }
}
