import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import 'models.dart';

/// Right-side panel showing a chess board and a clickable move list.
///
/// Each move in the list acts as a hyperlink: clicking it updates the board
/// to the position reached after that move.
class MovesPanel extends StatelessWidget {
  const MovesPanel({
    super.key,
    required this.moves,
    required this.startFen,
    required this.fenSource,
    required this.selectedIndex,
    required this.onMoveSelected,
    required this.onStartFenProvided,
    this.header,
  });

  final List<CachedMove> moves;
  final String startFen;
  final FenSource fenSource;
  final int selectedIndex;
  final ValueChanged<int> onMoveSelected;

  /// Called when the user manually enters a starting FEN.
  final ValueChanged<String> onStartFenProvided;

  /// Game header (player names), e.g. "Alekhine - Duras". Shown above the board.
  final String? header;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  header!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            StaticChessboard(
              size: constraints.maxWidth,
              orientation: dc.Side.white,
              fen: _currentFen(),
              lastMove: _lastMove(),
              colorScheme: ChessboardColorScheme.brown,
            ),
            const Divider(height: 1),
            if (fenSource == FenSource.suspectedDiagram)
              _DiagramWarningBanner(
                initialFen: startFen,
                onStartFenProvided: onStartFenProvided,
              ),
            if (fenSource == FenSource.userProvided)
              _UserFenBanner(
                fen: startFen,
                onEdit: onStartFenProvided,
              ),
            Expanded(
              child: _MoveList(
                moves: moves,
                selectedIndex: selectedIndex,
                onMoveSelected: onMoveSelected,
              ),
            ),
          ],
        );
      },
    );
  }

  String _currentFen() {
    if (selectedIndex < 0 || moves.isEmpty) return startFen;
    return moves[selectedIndex].fenAfter;
  }

  dc.Move? _lastMove() {
    if (selectedIndex < 0 || moves.isEmpty) return null;
    final cached = moves[selectedIndex];
    try {
      final setup = dc.Setup.parseFen(cached.fenBefore);
      final pos = dc.Chess.fromSetup(setup);
      return pos.parseSan(cached.san);
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Banners

class _DiagramWarningBanner extends StatelessWidget {
  const _DiagramWarningBanner({
    required this.initialFen,
    required this.onStartFenProvided,
  });
  final String initialFen;
  final ValueChanged<String> onStartFenProvided;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: Colors.orange),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Starting position may come from a board diagram — FEN not detected.',
                style: TextStyle(fontSize: 11, color: Colors.brown),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Enter FEN', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: 'Set starting position',
        initialFen: initialFen,
        onConfirm: onStartFenProvided,
      ),
    );
  }
}

class _UserFenBanner extends StatelessWidget {
  const _UserFenBanner({required this.fen, required this.onEdit});
  final String fen;
  final ValueChanged<String> onEdit;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 16, color: Colors.green),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Starting position: user-provided FEN.',
                style: TextStyle(fontSize: 11, color: Colors.green),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Edit', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: 'Edit starting position',
        initialFen: fen,
        onConfirm: onEdit,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Board editor dialog

class _BoardEditorDialog extends StatefulWidget {
  const _BoardEditorDialog({
    required this.title,
    required this.initialFen,
    required this.onConfirm,
  });

  final String title;
  final String initialFen;
  final ValueChanged<String> onConfirm;

  @override
  State<_BoardEditorDialog> createState() => _BoardEditorDialogState();
}

class _BoardEditorDialogState extends State<_BoardEditorDialog> {
  static const _pieceSet = PieceSet.merida;
  static const _standardFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  late Pieces _pieces;
  late bool _whiteTurn;
  bool _wK = true, _wQ = true, _bK = true, _bQ = true;

  EditorPointerMode _pointerMode = EditorPointerMode.drag;

  /// Piece to paint when in edit mode. Null = delete mode.
  dc.Piece? _brushPiece;

  late final TextEditingController _fenCtrl;

  /// Error shown below the FEN field when the typed/pasted text is invalid.
  String? _fenFieldError;

  /// Error shown on Apply (e.g. missing king).
  String? _applyError;

  Offset _dialogOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadFen(
      widget.initialFen.isNotEmpty ? widget.initialFen : _standardFen,
    );
    _fenCtrl = TextEditingController(text: _currentFen);
  }

  @override
  void dispose() {
    _fenCtrl.dispose();
    super.dispose();
  }

  void _loadFen(String fen) {
    final parts = fen.split(' ');
    _pieces = readFen(fen);
    _whiteTurn = parts.length < 2 || parts[1] != 'b';
    final c = parts.length > 2 ? parts[2] : 'KQkq';
    _wK = c.contains('K');
    _wQ = c.contains('Q');
    _bK = c.contains('k');
    _bQ = c.contains('q');
  }

  String get _currentFen {
    final board = writeFen(_pieces);
    final side = _whiteTurn ? 'w' : 'b';
    final castling = [
      if (_wK) 'K',
      if (_wQ) 'Q',
      if (_bK) 'k',
      if (_bQ) 'q',
    ].join();
    return '$board $side ${castling.isEmpty ? '-' : castling} - 0 1';
  }

  void _applyFenText(String text) {
    final trimmed = text.trim();
    try {
      dc.Chess.fromSetup(dc.Setup.parseFen(trimmed));
      setState(() {
        _loadFen(trimmed);
        _fenFieldError = null;
        _applyError = null;
        // Don't touch _fenCtrl — the text field is the source here.
      });
    } catch (_) {
      setState(() => _fenFieldError = 'Invalid FEN');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _fenCtrl.text = text;
    _applyFenText(text);
  }

  void _apply() {
    final fen = _currentFen;
    try {
      dc.Chess.fromSetup(dc.Setup.parseFen(fen));
    } catch (_) {
      setState(() =>
          _applyError = 'Invalid position — both kings must be on the board.');
      return;
    }
    widget.onConfirm(fen);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final maxHeight = size.height - 24;

    return Align(
      alignment: Alignment.center,
      child: Transform.translate(
        offset: _dialogOffset,
        child: Material(
          elevation: 24,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 500, maxHeight: maxHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Draggable title bar ──────────────────────────────────
                MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) {
                      setState(() {
                        final dx = (_dialogOffset.dx + details.delta.dx).clamp(
                          -(size.width / 2) + 60,
                          size.width / 2 - 60,
                        );
                        final dy = (_dialogOffset.dy + details.delta.dy).clamp(
                          -(size.height / 2) + 20,
                          size.height / 2 - 20,
                        );
                        _dialogOffset = Offset(dx, dy);
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(widget.title,
                                style: Theme.of(context).textTheme.titleLarge),
                          ),
                          const Icon(Icons.drag_indicator,
                              color: Colors.grey, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // ── Scrollable area: board + controls ────────────────────
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBoardSection(),
                        const SizedBox(height: 12),
                        _buildControls(),
                      ],
                    ),
                  ),
                ),
                // ── Fixed footer: FEN input + action buttons ─────────────
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildFenDisplay(),
                      if (_applyError != null) ...[
                        const SizedBox(height: 4),
                        Text(_applyError!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 11)),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _apply,
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoardSection() {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final boardSize = constraints.maxWidth;
        final squareSize = boardSize / 8;
        final settings = ChessboardSettings(
          pieceAssets: _pieceSet.assets,
          colorScheme: ChessboardColorScheme.brown,
        );

        return Column(
          children: [
            _EditorPalette(
              side: dc.Side.black,
              squareSize: squareSize,
              settings: settings,
              brushPiece: _brushPiece?.color == dc.Side.black
                  ? _brushPiece
                  : null,
              pointerMode: _pointerMode,
              onPieceTapped: (role) => setState(() {
                _brushPiece = dc.Piece(role: role, color: dc.Side.black);
                _pointerMode = EditorPointerMode.edit;
              }),
              onDeleteTapped: () => setState(() {
                _brushPiece = null;
                _pointerMode = EditorPointerMode.edit;
              }),
              onDragModeTapped: () =>
                  setState(() => _pointerMode = EditorPointerMode.drag),
            ),
            ChessboardEditor(
              size: boardSize,
              orientation: dc.Side.white,
              pieces: _pieces,
              settings: settings,
              pointerMode: _pointerMode,
              onEditedSquare: (sq) => setState(() {
                _applyError = null;
                if (_brushPiece != null) {
                  _pieces[sq] = _brushPiece!;
                } else {
                  _pieces.remove(sq);
                }
                _fenCtrl.text = _currentFen;
              }),
              onDroppedPiece: (origin, dest, piece) => setState(() {
                _applyError = null;
                _pieces[dest] = piece;
                if (origin != null && origin != dest) {
                  _pieces.remove(origin);
                }
                _fenCtrl.text = _currentFen;
              }),
              onDiscardedPiece: (sq) => setState(() {
                _applyError = null;
                _pieces.remove(sq);
                _fenCtrl.text = _currentFen;
              }),
            ),
            _EditorPalette(
              side: dc.Side.white,
              squareSize: squareSize,
              settings: settings,
              brushPiece: _brushPiece?.color == dc.Side.white
                  ? _brushPiece
                  : null,
              pointerMode: _pointerMode,
              onPieceTapped: (role) => setState(() {
                _brushPiece = dc.Piece(role: role, color: dc.Side.white);
                _pointerMode = EditorPointerMode.edit;
              }),
              onDeleteTapped: () => setState(() {
                _brushPiece = null;
                _pointerMode = EditorPointerMode.edit;
              }),
              onDragModeTapped: () =>
                  setState(() => _pointerMode = EditorPointerMode.drag),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Side to move:', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true,
                    label: Text('White', style: TextStyle(fontSize: 12))),
                ButtonSegment(
                    value: false,
                    label: Text('Black', style: TextStyle(fontSize: 12))),
              ],
              selected: {_whiteTurn},
              onSelectionChanged: (v) => setState(() {
                _whiteTurn = v.first;
                _fenCtrl.text = _currentFen;
              }),
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Text('Castling:', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            _CastleCheckbox(
                label: 'K',
                value: _wK,
                onChanged: (v) => setState(() { _wK = v; _fenCtrl.text = _currentFen; })),
            _CastleCheckbox(
                label: 'Q',
                value: _wQ,
                onChanged: (v) => setState(() { _wQ = v; _fenCtrl.text = _currentFen; })),
            _CastleCheckbox(
                label: 'k',
                value: _bK,
                onChanged: (v) => setState(() { _bK = v; _fenCtrl.text = _currentFen; })),
            _CastleCheckbox(
                label: 'q',
                value: _bQ,
                onChanged: (v) => setState(() { _bQ = v; _fenCtrl.text = _currentFen; })),
          ],
        ),
      ],
    );
  }

  Widget _buildFenDisplay() {
    return TextField(
      controller: _fenCtrl,
      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      decoration: InputDecoration(
        labelText: 'FEN',
        errorText: _fenFieldError,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        suffixIcon: IconButton(
          icon: const Icon(Icons.content_paste, size: 18),
          tooltip: 'Paste from clipboard',
          onPressed: _pasteFromClipboard,
        ),
      ),
      onChanged: _applyFenText,
    );
  }
}

// ---------------------------------------------------------------------------
// Editor piece palette row

class _EditorPalette extends StatelessWidget {
  const _EditorPalette({
    required this.side,
    required this.squareSize,
    required this.settings,
    required this.brushPiece,
    required this.pointerMode,
    required this.onPieceTapped,
    required this.onDeleteTapped,
    required this.onDragModeTapped,
  });

  final dc.Side side;
  final double squareSize;
  final ChessboardSettings settings;

  /// The currently selected brush piece for this side, or null if none selected.
  final dc.Piece? brushPiece;
  final EditorPointerMode pointerMode;
  final void Function(dc.Role role) onPieceTapped;
  final VoidCallback onDeleteTapped;
  final VoidCallback onDragModeTapped;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: squareSize,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Drag mode toggle
          _PaletteCell(
            size: squareSize,
            selected: pointerMode == EditorPointerMode.drag,
            selectedColor: primaryColor,
            onTap: onDragModeTapped,
            child: Icon(Icons.open_with, size: squareSize * 0.6),
          ),
          // Pieces
          for (final role in dc.Role.values)
            _DraggablePaletteCell(
              squareSize: squareSize,
              piece: dc.Piece(role: role, color: side),
              settings: settings,
              selected: brushPiece?.role == role,
              selectedColor: primaryColor,
              onTap: () => onPieceTapped(role),
            ),
          // Delete mode button
          _PaletteCell(
            size: squareSize,
            selected:
                pointerMode == EditorPointerMode.edit && brushPiece == null,
            selectedColor: Colors.red,
            onTap: onDeleteTapped,
            child: Icon(Icons.delete_outline,
                size: squareSize * 0.6, color: Colors.red.shade700),
          ),
        ],
      ),
    );
  }
}

class _PaletteCell extends StatelessWidget {
  const _PaletteCell({
    required this.size,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
    required this.child,
  });

  final double size;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        color: selected ? selectedColor.withAlpha(40) : null,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _DraggablePaletteCell extends StatelessWidget {
  const _DraggablePaletteCell({
    required this.squareSize,
    required this.piece,
    required this.settings,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
  });

  final double squareSize;
  final dc.Piece piece;
  final ChessboardSettings settings;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: squareSize,
        height: squareSize,
        color: selected ? selectedColor.withAlpha(40) : null,
        child: Draggable<dc.Piece>(
          data: piece,
          feedback: PieceDragFeedback(
            squareSize: squareSize,
            pieceAssets: settings.pieceAssets,
            piece: piece,
          ),
          child: PieceWidget(
            piece: piece,
            size: squareSize,
            pieceAssets: settings.pieceAssets,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Castling checkbox

class _CastleCheckbox extends StatelessWidget {
  const _CastleCheckbox({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, fontFamily: 'monospace')),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Move list

class _MoveList extends StatefulWidget {
  const _MoveList({
    required this.moves,
    required this.selectedIndex,
    required this.onMoveSelected,
  });

  final List<CachedMove> moves;
  final int selectedIndex;
  final ValueChanged<int> onMoveSelected;

  @override
  State<_MoveList> createState() => _MoveListState();
}

class _MoveListState extends State<_MoveList> {
  final ScrollController _scroll = ScrollController();
  late List<_MovePair> _pairs;

  @override
  void initState() {
    super.initState();
    _pairs = _buildPairs(widget.moves);
  }

  @override
  void didUpdateWidget(_MoveList old) {
    super.didUpdateWidget(old);
    if (widget.moves != old.moves) {
      _pairs = _buildPairs(widget.moves);
    }
    if (widget.selectedIndex != old.selectedIndex) {
      _scrollToSelected();
    }
  }

  void _scrollToSelected() {
    final idx = widget.selectedIndex;
    if (!_scroll.hasClients) return;
    if (idx < 0) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
      return;
    }
    int row = 0;
    for (int i = 0; i < _pairs.length; i++) {
      if (_pairs[i].whiteIdx == idx || _pairs[i].blackIdx == idx) {
        row = i;
        break;
      }
    }
    final target = (row * 36.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.moves.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'No chess moves found on this page.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black45, fontSize: 12),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _pairs.length,
      itemBuilder: (ctx, i) {
        final pair = _pairs[i];
        return SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  '${pair.moveNumber}.',
                  textAlign: TextAlign.right,
                  style:
                      const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: pair.whiteIdx != null
                    ? _SanButton(
                        san: widget.moves[pair.whiteIdx!].san,
                        index: pair.whiteIdx!,
                        selected: widget.selectedIndex == pair.whiteIdx,
                        onTap: widget.onMoveSelected,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: pair.blackIdx != null
                    ? _SanButton(
                        san: widget.moves[pair.blackIdx!].san,
                        index: pair.blackIdx!,
                        selected: widget.selectedIndex == pair.blackIdx,
                        onTap: widget.onMoveSelected,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
      },
    );
  }

  static List<_MovePair> _buildPairs(List<CachedMove> moves) {
    final pairs = <_MovePair>[];
    int i = 0;
    while (i < moves.length) {
      final m = moves[i];
      if (!m.isBlack) {
        final whiteIdx = i;
        int? blackIdx;
        if (i + 1 < moves.length && moves[i + 1].isBlack) {
          blackIdx = i + 1;
          i++;
        }
        pairs.add(_MovePair(m.moveNumber, whiteIdx, blackIdx));
      } else {
        pairs.add(_MovePair(m.moveNumber, null, i));
      }
      i++;
    }
    return pairs;
  }
}

class _MovePair {
  const _MovePair(this.moveNumber, this.whiteIdx, this.blackIdx);
  final int moveNumber;
  final int? whiteIdx;
  final int? blackIdx;
}

class _SanButton extends StatelessWidget {
  const _SanButton({
    required this.san,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final String san;
  final int index;
  final bool selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => onTap(index),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: selected
            ? BoxDecoration(
                color: primaryColor.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        child: Text(
          san,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? primaryColor : Colors.blue.shade700,
            decoration: TextDecoration.underline,
            decorationColor:
                selected ? primaryColor : Colors.blue.shade700,
          ),
        ),
      ),
    );
  }
}
