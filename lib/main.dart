import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
  Book(this.path, this.title, this.pages, this.images, this.corrections, this.dpi);

  final String path;
  final double dpi; // resolution the page images were rendered at (manifest 'dpi', 200 when absent): 100 % zoom = 96 / dpi px per page px
  final String title;
  final Map<int, Map<String, dynamic>> pages;
  final Map<String, Uint8List> images; // 'diagrams/p2_d1.png' -> bytes
  final Map<String, Map<String, dynamic>> corrections; // target id -> entry of corrections.json

  static String hash(String s) => 'sha256:${sha256.convert(utf8.encode(s))}';

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
    final corrections = <String, Map<String, dynamic>>{};
    if (zip.findFile('corrections.json') != null) {
      for (final c in json('corrections.json')['corrections'] as List) {
        corrections[(c as Map<String, dynamic>)['target'] as String] = c;
      }
    }
    final manifest = json('manifest.json');
    return Book(path, manifest['title'] as String, pages, images, corrections, ((manifest['dpi'] as num?) ?? 200).toDouble());
  }

  /// FEN to show for a diagram: the reviewed value, unless the generated FEN changed since (then it needs review).
  String? fenOf(Map<String, dynamic> d) {
    final generated = d['fen'] as String?;
    final c = corrections[d['id']];
    if (generated == null || c == null || c['type'] != 'diagram_fen') return generated;
    return c['source_hash'] == hash(generated) ? c['value'] as String : generated;
  }

  bool isCorrected(Map<String, dynamic> d) => fenOf(d) != d['fen'];

  bool needsReview(Map<String, dynamic> d) {
    final c = corrections[d['id']];
    final generated = d['fen'] as String?;
    return c != null && generated != null && c['source_hash'] != hash(generated);
  }

  /// Stores a diagram correction in corrections.json (the only file the reader writes): the zip is rewritten to a
  /// temporary file next to the original, then renamed over it.
  void saveDiagramFen(String id, String generatedFen, String value) {
    corrections[id] = {
      'target': id,
      'type': 'diagram_fen',
      'value': value,
      'source_hash': hash(generatedFen),
      'needs_review': false,
    };
    final out = Archive();
    for (final f in ZipDecoder().decodeBytes(io.File(path).readAsBytesSync()).files) {
      if (f.name != 'corrections.json') out.addFile(ArchiveFile.bytes(f.name, f.readBytes()!));
    }
    out.addFile(ArchiveFile.string(
        'corrections.json', jsonEncode({'schema_version': 1, 'corrections': corrections.values.toList()})));
    final tmp = io.File('$path.tmp')..writeAsBytesSync(ZipEncoder().encode(out));
    tmp.renameSync(path);
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
  Side orientation = Side.white;
  // zoom: 'page' = whole page visible, 'width' = page width fills the pane, otherwise a percentage of the real page size
  String fit = 'width';
  double percent = 100;
  double _lastK = 1, _k100 = 1; // scale actually drawn / scale of 100 %, kept to step the zoom from where it is
  static const _presets = [25.0, 50.0, 75.0, 100.0, 125.0, 150.0, 200.0, 300.0];
  String? selected, label, lastUci;
  late final _pageCtl = TextEditingController(text: '$page');
  Map<String, dynamic>? selectedDiagram;
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _pageCtl.dispose();
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  void _pick(Map<String, dynamic> m) => setState(() {
        selected = m['id'] as String;
        selectedDiagram = null;
        lastUci = m['uci'] as String?;
        fen = (m['fen'] as String?) ?? fen;
        // FEN after a white move: black to move, fullmove = n ('3. Cf3'); after a black move: fullmove = n + 1 ('2... d5')
        final f = fen.split(' ');
        final n = int.parse(f[5]);
        label = f[1] == 'b' ? '$n. ${m['raw']}' : '${n - 1}... ${m['raw']}';
      });

  void _pickDiagram(Map<String, dynamic> d) => setState(() {
        selected = d['id'] as String;
        selectedDiagram = d;
        lastUci = null;
        fen = widget.book.fenOf(d)!;
        label = 'Diagramme ${d['id']}${d['flipped'] == true ? ' (retourné : blancs en bas)' : ''}'
            '${widget.book.isCorrected(d) ? ' — corrigé' : ''}${widget.book.needsReview(d) ? ' — correction à revoir' : ''}';
      });

  Move? get lastMove => lastUci == null ? null : Move.parse(lastUci!);

  void _zoomBy(int d) {
    final now = _lastK / _k100 * 100;
    final next = d > 0 ? _presets.firstWhere((p) => p > now + 0.5, orElse: () => _presets.last) : _presets.lastWhere((p) => p < now - 0.5, orElse: () => _presets.first);
    setState(() {
      fit = '';
      percent = next;
    });
  }

  String get _zoomLabel => fit == 'page' ? 'Page entière' : fit == 'width' ? 'Largeur de page' : '${percent.round()} %';

  List<int> get _numbers => widget.book.pages.keys.toList()..sort();

  void _goto(int p) {
    if (!widget.book.pages.containsKey(p)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Page $p absente (pages ${_numbers.first} à ${_numbers.last})')));
      _pageCtl.text = '$page';
      return;
    }
    setState(() {
      page = p;
      fen = kInitialFEN;
      selected = label = lastUci = null;
      selectedDiagram = null;
    });
    _pageCtl.text = '$p';
  }

  void _step(int delta) {
    final n = _numbers;
    final i = n.indexOf(page) + delta;
    if (i >= 0 && i < n.length) _goto(n[i]);
  }

  Future<void> _editDiagram(Map<String, dynamic> d) async {
    final current = widget.book.fenOf(d);
    if (current == null) return;
    final edited = await showDialog<String>(
      context: context,
      builder: (_) => DiagramEditor(placement: current.split(' ').first, image: widget.book.images[d['image']]),
    );
    if (edited == null || edited == current.split(' ').first) return;
    try {
      widget.book.saveDiagramFen(d['id'] as String, d['fen'] as String, '$edited ${(d['fen'] as String).split(' ').skip(1).join(' ')}');
      setState(() => _pickDiagram(d));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Enregistrement impossible : $e')));
    }
  }

  final _fonts = <String, double>{};

  /// Largest font size (page px) at which the block, wrapped to its width, fits its height. Measured with the same spans
  /// as the display, bold moves included (they are wider than plain text).
  double _fit(Map<String, dynamic> block, Map<String, Map<String, dynamic>> moves) =>
      _fonts.putIfAbsent('${widget.book.title}/$page/${block['id']}', () {
        final b = (block['bbox'] as List).cast<num>();
        var f = 80.0;
        while (f > 8) {
          final tp = TextPainter(
              text: TextSpan(children: _spans(block, moves, null), style: TextStyle(fontSize: f, height: 1.25)),
              textDirection: TextDirection.ltr)
            ..layout(maxWidth: b[2].toDouble());
          if (tp.height <= b[3] * 1.02) break;
          f -= 0.5;
        }
        return f;
      });

  /// Spans of a block: plain text with its moves in bold, clickable when [taps] is given (None when only measuring).
  List<InlineSpan> _spans(Map<String, dynamic> block, Map<String, Map<String, dynamic>> moves, List<TapGestureRecognizer>? taps) {
    final text = block['text'] as String;
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final id in (block['moves'] as List).cast<String>()) {
      final m = moves[id]!;
      final s = (m['span'] as List).cast<int>();
      if (s[0] < pos) continue;
      spans.add(TextSpan(text: text.substring(pos, s[0])));
      final ok = m['ok'] as bool;
      TapGestureRecognizer? tap;
      if (taps != null) {
        tap = TapGestureRecognizer()..onTap = ok ? () => _pick(m) : null;
        taps.add(tap);
      }
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
    return spans;
  }

  /// Text of a block, positioned where the block sits on the original page (page px scaled by [k]).
  Widget _block(Map<String, dynamic> block, Map<String, Map<String, dynamic>> moves, double k) {
    final b = (block['bbox'] as List).cast<num>();
    return Positioned(
      left: b[0] * k,
      top: b[1] * k,
      width: b[2] * k,
      child: Text.rich(TextSpan(children: _spans(block, moves, _taps)),
          style: TextStyle(fontSize: _fit(block, moves) * k, height: 1.25, color: Colors.black87)),
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
        onSecondaryTap: d['fen'] == null ? null : () => _editDiagram(d),
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
          IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Page précédente', onPressed: page > _numbers.first ? () => _step(-1) : null),
          SizedBox(
            width: 56,
            child: TextField(
              controller: _pageCtl,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (v) => _goto(int.tryParse(v.trim()) ?? page),
            ),
          ),
          Text(' / ${_numbers.last}'),
          IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Page suivante', onPressed: page < _numbers.last ? () => _step(1) : null),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.zoom_out), tooltip: 'Réduire la page', onPressed: () => _zoomBy(-1)),
          PopupMenuButton<String>(
            tooltip: 'Niveau de zoom',
            onSelected: (v) => setState(() {
              fit = (v == 'page' || v == 'width') ? v : '';
              if (fit.isEmpty) percent = double.parse(v);
            }),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'page', child: Text('Page entière')),
              const PopupMenuItem(value: 'width', child: Text('Largeur de page')),
              const PopupMenuDivider(),
              for (final p in _presets) PopupMenuItem(value: '$p', child: Text('${p.round()} %')),
            ],
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Center(child: Text(_zoomLabel))),
          ),
          IconButton(icon: const Icon(Icons.zoom_in), tooltip: 'Agrandir la page', onPressed: () => _zoomBy(1)),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final pw = (data['width'] as num).toDouble(), ph = (data['height'] as num).toDouble();
            _k100 = 96 / widget.book.dpi;
            final fitWidth = (c.maxWidth - 32) / pw;
            final fitPage = ((c.maxHeight - 72) / ph).clamp(0.05, fitWidth); // 72 = padding + the line above the page
            final k = fit == 'page' ? fitPage : fit == 'width' ? fitWidth : percent / 100 * _k100;
            _lastK = k;
            final w = pw * k;
            final page = SingleChildScrollView(
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
            // zoomed in: the page is wider than the pane, so it also scrolls sideways
            return w + 32 <= c.maxWidth
                ? page
                : SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: w + 32, height: c.maxHeight, child: page));
          }),
        ),
        LayoutBuilder(builder: (context, _) {
          // board fits the window: at most 400 px, at most the height left under the app bar minus the caption
          final side = (MediaQuery.sizeOf(context).height - kToolbarHeight - 90).clamp(120.0, 400.0);
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              StaticChessboard(
                size: side,
                orientation: orientation,
                fen: fen,
                lastMove: lastMove,
                shapes: {
                  if (lastMove is NormalMove)
                    Arrow(color: const Color(0xB3E8A317), orig: (lastMove as NormalMove).from, dest: (lastMove as NormalMove).to),
                },
              ),
              const SizedBox(height: 8),
              Text(label ?? 'Cliquer sur un coup', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                onPressed: () => setState(() => orientation = orientation.opposite),
                icon: const Icon(Icons.swap_vert),
                label: const Text("Retourner l'échiquier"),
              ),
              if (selectedDiagram != null)
                TextButton.icon(
                  onPressed: () => _editDiagram(selectedDiagram!),
                  icon: const Icon(Icons.edit),
                  label: const Text('Corriger ce diagramme (ou clic droit)'),
                ),
            ]),
          );
        }),
      ]),
    );
  }
}


/// Position editor for a diagram: drag a piece from the palette onto a square, drag a piece off the board to delete it.
class DiagramEditor extends StatefulWidget {
  const DiagramEditor({super.key, required this.placement, this.image});

  final String placement; // piece placement part of a FEN
  final Uint8List? image;

  @override
  State<DiagramEditor> createState() => _DiagramEditorState();
}

class _DiagramEditorState extends State<DiagramEditor> {
  late Map<Square, Piece> pieces = Map.of(readFen(widget.placement));
  Side orientation = Side.white; // view only: the saved FEN does not depend on it

  static const _palette = [Role.king, Role.queen, Role.rook, Role.bishop, Role.knight, Role.pawn];

  Widget _paletteRow(Side side) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _palette)
          Draggable<Piece>(
            data: Piece(color: side, role: r),
            feedback: PieceWidget(piece: Piece(color: side, role: r), size: 48, pieceAssets: PieceSet.cburnettAssets),
            child: PieceWidget(piece: Piece(color: side, role: r), size: 48, pieceAssets: PieceSet.cburnettAssets),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    // board + palette + buttons must fit the window height (title, palette, flip button, hint and actions take ~420 px)
    final side = (MediaQuery.sizeOf(context).height - 420).clamp(220.0, 384.0);
    return AlertDialog(
        title: const Text('Corriger le diagramme'),
        content: SingleChildScrollView(child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.image != null) Image.memory(widget.image!, width: 260),
          const SizedBox(width: 16),
          Column(mainAxisSize: MainAxisSize.min, children: [
            ChessboardEditor(
              size: side,
              orientation: orientation,
              pieces: pieces,
              onDroppedPiece: (origin, dest, piece) => setState(() {
                if (origin != null) pieces.remove(origin);
                pieces[dest] = piece;
              }),
              onDiscardedPiece: (sq) => setState(() => pieces.remove(sq)),
            ),
            const SizedBox(height: 8),
            _paletteRow(Side.white),
            _paletteRow(Side.black),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => setState(() => orientation = orientation.opposite),
              icon: const Icon(Icons.swap_vert),
              label: const Text("Retourner l'échiquier"),
            ),
            const Text('Glisser une pièce sur une case ; hors du plateau pour la supprimer.'),
          ]),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, writeFen(pieces)), child: const Text('Enregistrer')),
        ],
      );
  }
}
