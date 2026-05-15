import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/material.dart';

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
  });

  final List<CachedMove> moves;
  final String startFen;
  final FenSource fenSource;
  final int selectedIndex;
  final ValueChanged<int> onMoveSelected;

  /// Called when the user manually enters a starting FEN.
  final ValueChanged<String> onStartFenProvided;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StaticChessboard(
              size: constraints.maxWidth,
              orientation: dc.Side.white,
              fen: _currentFen(),
              lastMove: _lastMove(),
              colorScheme: ChessboardColorScheme.brown,
            ),
            const Divider(height: 1),
            if (fenSource == FenSource.suspectedDiagram)
              _DiagramWarningBanner(onStartFenProvided: onStartFenProvided),
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
  const _DiagramWarningBanner({required this.onStartFenProvided});
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
              onPressed: () => _showFenDialog(context),
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

  void _showFenDialog(BuildContext context) {
    showDialog<String>(
      context: context,
      builder: (ctx) => _FenInputDialog(
        title: 'Enter starting position',
        hint: 'Paste or type the FEN of the diagram position',
        initialFen: '',
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
              onPressed: () => _showFenDialog(context),
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

  void _showFenDialog(BuildContext context) {
    showDialog<String>(
      context: context,
      builder: (ctx) => _FenInputDialog(
        title: 'Edit starting position',
        hint: 'Paste or type the FEN',
        initialFen: fen,
        onConfirm: onEdit,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FEN input dialog

class _FenInputDialog extends StatefulWidget {
  const _FenInputDialog({
    required this.title,
    required this.hint,
    required this.initialFen,
    required this.onConfirm,
  });

  final String title;
  final String hint;
  final String initialFen;
  final ValueChanged<String> onConfirm;

  @override
  State<_FenInputDialog> createState() => _FenInputDialogState();
}

class _FenInputDialogState extends State<_FenInputDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialFen);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _validateAndConfirm() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'FEN cannot be empty.');
      return false;
    }
    try {
      dc.Setup.parseFen(text);
      // Also verify it's a playable Chess position.
      dc.Chess.fromSetup(dc.Setup.parseFen(text));
    } catch (_) {
      setState(() => _error = 'Invalid FEN string.');
      return false;
    }
    widget.onConfirm(text);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.hint,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText:
                  'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              errorText: _error,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) {
              if (_validateAndConfirm()) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_validateAndConfirm()) Navigator.of(context).pop();
          },
          child: const Text('Apply'),
        ),
      ],
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
