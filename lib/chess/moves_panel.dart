import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../l10n/app_localizations.dart';
import 'models.dart' show CachedMove, FenSource;

/// Left-side panel showing the start-position banners.
class MovesPanel extends StatelessWidget {
  const MovesPanel({
    super.key,
    required this.startFen,
    required this.fenSource,
    required this.onStartFenProvided,
    this.onMarkAsIntermediate,
    this.onMarkAsNotADiagram,
    this.onResetToDiagram,
    this.header,
  });

  final String startFen;
  final FenSource fenSource;

  /// Called when the user manually enters a starting FEN.
  final ValueChanged<String> onStartFenProvided;

  /// Called when the user overrides a suspected-new-game diagram to be
  /// treated as an intermediate diagram instead.
  final VoidCallback? onMarkAsIntermediate;

  /// Called when the user marks this image as not a board diagram at all.
  final VoidCallback? onMarkAsNotADiagram;

  /// Called when the user undoes a "not a diagram" override, reverting to
  /// the auto-detected suspected-diagram state.
  final VoidCallback? onResetToDiagram;

  /// Game header (player names), e.g. "Alekhine - Duras". Shown above the banners.
  final String? header;

  @override
  Widget build(BuildContext context) {
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
        const Divider(height: 1),
        if (fenSource == FenSource.standard)
          _StandardFenBanner(onStartFenProvided: onStartFenProvided),
        if (fenSource == FenSource.detectedInText)
          _DetectedFenBanner(
            fen: startFen,
            onEdit: onStartFenProvided,
          ),
        if (fenSource == FenSource.inheritedFromPreviousPage)
          _InheritedFenBanner(
            fen: startFen,
            onEdit: onStartFenProvided,
            onMarkAsIntermediate: onMarkAsIntermediate,
            onMarkAsNotADiagram: onMarkAsNotADiagram,
          ),
        if (fenSource == FenSource.suspectedDiagram)
          _DiagramWarningBanner(
            initialFen: startFen,
            onStartFenProvided: onStartFenProvided,
            onMarkAsIntermediate: onMarkAsIntermediate,
            onMarkAsNotADiagram: onMarkAsNotADiagram,
          ),
        if (fenSource == FenSource.suspectedIntermediateDiagram)
          _SuspectedIntermediateDiagramBanner(
            onMarkAsNewGame: onStartFenProvided,
          ),
        if (fenSource == FenSource.userConfirmedIntermediate)
          _ConfirmedIntermediateBanner(
            onMarkAsNewGame: onStartFenProvided,
          ),
        if (fenSource == FenSource.userConfirmedNotADiagram)
          _NotADiagramBanner(
            onUndo: onResetToDiagram,
          ),
        if (fenSource == FenSource.userProvided)
          _UserFenBanner(
            fen: startFen,
            onEdit: onStartFenProvided,
            onMarkAsIntermediate: onMarkAsIntermediate,
            onMarkAsNotADiagram: onMarkAsNotADiagram,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Right-side panel showing only the chess board for the currently selected position.
class PositionPreviewPanel extends StatelessWidget {
  const PositionPreviewPanel({
    super.key,
    required this.moves,
    required this.startFen,
    required this.selectedIndex,
  });

  final List<CachedMove> moves;
  final String startFen;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return StaticChessboard(
          size: constraints.maxWidth,
          orientation: dc.Side.white,
          fen: _currentFen(),
          lastMove: _lastMove(),
          colorScheme: ChessboardColorScheme.brown,
          pieceAssets: PieceSet.cburnettAssets,
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

class _StandardFenBanner extends StatelessWidget {
  const _StandardFenBanner({required this.onStartFenProvided});
  final ValueChanged<String> onStartFenProvided;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 16, color: Colors.blueGrey),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.setStartingPosition,
                style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context, l),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.edit, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.setStartingPosition,
        initialFen: dc.kInitialFEN,
        onConfirm: onStartFenProvided,
      ),
    );
  }
}

class _DetectedFenBanner extends StatelessWidget {
  const _DetectedFenBanner({required this.fen, required this.onEdit});
  final String fen;
  final ValueChanged<String> onEdit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.teal.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.search, size: 16, color: Colors.teal),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.detectedFenLabel,
                style: const TextStyle(fontSize: 11, color: Colors.teal),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context, l),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.edit, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.editStartingPosition,
        initialFen: fen,
        onConfirm: onEdit,
      ),
    );
  }
}

class _InheritedFenBanner extends StatelessWidget {
  const _InheritedFenBanner({
    required this.fen,
    required this.onEdit,
    this.onMarkAsIntermediate,
    this.onMarkAsNotADiagram,
  });
  final String fen;
  final ValueChanged<String> onEdit;
  final VoidCallback? onMarkAsIntermediate;
  final VoidCallback? onMarkAsNotADiagram;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.arrow_forward, size: 16, color: Colors.purple),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.inheritedFenLabel,
                style: const TextStyle(fontSize: 11, color: Colors.purple),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context, l),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.edit, style: const TextStyle(fontSize: 11)),
            ),
            _DiscardPopup(
              label: l.discard,
              intermediateLabel: l.discardBecauseIntermediate,
              newGameLabel: l.discardBecauseNewGame,
              onMarkAsIntermediate: onMarkAsIntermediate,
              onMarkAsNotADiagram: onMarkAsNotADiagram,
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.editStartingPosition,
        initialFen: fen,
        onConfirm: onEdit,
      ),
    );
  }
}

class _DiagramWarningBanner extends StatelessWidget {
  const _DiagramWarningBanner({
    required this.initialFen,
    required this.onStartFenProvided,
    this.onMarkAsIntermediate,
    this.onMarkAsNotADiagram,
  });
  final String initialFen;
  final ValueChanged<String> onStartFenProvided;
  final VoidCallback? onMarkAsIntermediate;
  final VoidCallback? onMarkAsNotADiagram;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.diagramWarning,
                    style: const TextStyle(fontSize: 11, color: Colors.brown),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onMarkAsNotADiagram != null)
                  TextButton(
                    onPressed: onMarkAsNotADiagram,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l.markAsNotADiagram,
                        style: const TextStyle(fontSize: 11)),
                  ),
                if (onMarkAsIntermediate != null)
                  TextButton(
                    onPressed: onMarkAsIntermediate,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l.markAsIntermediate,
                        style: const TextStyle(fontSize: 11)),
                  ),
                TextButton(
                  onPressed: () => _showEditorDialog(context, l),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l.enterFen, style: const TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.setStartingPosition,
        initialFen: initialFen,
        onConfirm: onStartFenProvided,
      ),
    );
  }
}

class _SuspectedIntermediateDiagramBanner extends StatelessWidget {
  const _SuspectedIntermediateDiagramBanner({
    required this.onMarkAsNewGame,
  });
  final ValueChanged<String> onMarkAsNewGame;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.suspectedIntermediateDiagramLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _showEditorDialog(context, l),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l.markAsNewGame,
                      style: const TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.setStartingPosition,
        initialFen: dc.kInitialFEN,
        onConfirm: onMarkAsNewGame,
      ),
    );
  }
}

class _ConfirmedIntermediateBanner extends StatelessWidget {
  const _ConfirmedIntermediateBanner({required this.onMarkAsNewGame});
  final ValueChanged<String> onMarkAsNewGame;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.teal.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 16, color: Colors.teal),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.confirmedIntermediateLabel,
                style: const TextStyle(fontSize: 11, color: Colors.teal),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context, l),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.markAsNewGame, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.setStartingPosition,
        initialFen: dc.kInitialFEN,
        onConfirm: onMarkAsNewGame,
      ),
    );
  }
}

class _NotADiagramBanner extends StatelessWidget {
  const _NotADiagramBanner({this.onUndo});
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.image_not_supported_outlined,
                size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.notADiagramLabel,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            if (onUndo != null)
              TextButton(
                onPressed: onUndo,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(l.markAsSuspectedDiagram,
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }
}

class _UserFenBanner extends StatelessWidget {
  const _UserFenBanner({
    required this.fen,
    required this.onEdit,
    this.onMarkAsIntermediate,
    this.onMarkAsNotADiagram,
  });
  final String fen;
  final ValueChanged<String> onEdit;
  final VoidCallback? onMarkAsIntermediate;
  final VoidCallback? onMarkAsNotADiagram;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 16, color: Colors.green),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.userFenLabel,
                style: const TextStyle(fontSize: 11, color: Colors.green),
              ),
            ),
            TextButton(
              onPressed: () => _showEditorDialog(context, l),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.edit, style: const TextStyle(fontSize: 11)),
            ),
            _DiscardPopup(
              label: l.discard,
              intermediateLabel: l.discardBecauseIntermediate,
              newGameLabel: l.discardBecauseNewGame,
              onMarkAsIntermediate: onMarkAsIntermediate,
              onMarkAsNotADiagram: onMarkAsNotADiagram,
            ),
          ],
        ),
      ),
    );
  }

  void _showEditorDialog(BuildContext context, AppLocalizations l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _BoardEditorDialog(
        title: l.editStartingPosition,
        initialFen: fen,
        onConfirm: onEdit,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DiscardPopup extends StatelessWidget {
  const _DiscardPopup({
    required this.label,
    required this.intermediateLabel,
    required this.newGameLabel,
    this.onMarkAsIntermediate,
    this.onMarkAsNotADiagram,
  });

  final String label;
  final String intermediateLabel;
  final String newGameLabel;
  final VoidCallback? onMarkAsIntermediate;
  final VoidCallback? onMarkAsNotADiagram;

  @override
  Widget build(BuildContext context) {
    if (onMarkAsIntermediate == null && onMarkAsNotADiagram == null) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<_DiscardChoice>(
      tooltip: label,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.red)),
      ),
      onSelected: (choice) {
        if (choice == _DiscardChoice.intermediate) {
          onMarkAsIntermediate?.call();
        } else {
          onMarkAsNotADiagram?.call();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _DiscardChoice.intermediate,
          child: Text(intermediateLabel,
              style: const TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: _DiscardChoice.newGame,
          child: Text(newGameLabel,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

enum _DiscardChoice { intermediate, newGame }

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
  static const _pieceSet = PieceSet.cburnett;
  static const _standardFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  late Pieces _pieces;
  late bool _whiteTurn;
  bool _wK = true, _wQ = true, _bK = true, _bQ = true;
  int _moveNumber = 1;
  late final TextEditingController _moveNumCtrl;
  /// Single file letter a–h, or empty for no en-passant.
  String _epFile = '';
  int _halfMoveClock = 0;
  late final TextEditingController _halfMoveCtrl;

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
    _moveNumCtrl = TextEditingController(text: _moveNumber.toString());
    _halfMoveCtrl = TextEditingController(text: _halfMoveClock.toString());
  }

  @override
  void dispose() {
    _fenCtrl.dispose();
    _moveNumCtrl.dispose();
    _halfMoveCtrl.dispose();
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
    _moveNumber = (parts.length >= 6 ? int.tryParse(parts[5]) : null) ?? 1;
    final ep = parts.length >= 4 ? parts[3] : '-';
    _epFile = (ep != '-' && ep.isNotEmpty) ? ep[0] : '';
    _halfMoveClock = (parts.length >= 5 ? int.tryParse(parts[4]) : null) ?? 0;
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
    final epRank = _whiteTurn ? '6' : '3';
    final ep = _epFile.isNotEmpty ? '$_epFile$epRank' : '-';
    return '$board $side ${castling.isEmpty ? '-' : castling} $ep $_halfMoveClock $_moveNumber';
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
        _moveNumCtrl.text = _moveNumber.toString();
        _halfMoveCtrl.text = _halfMoveClock.toString();
      });
    } catch (_) {
      setState(() => _fenFieldError = AppLocalizations.of(context)!.invalidFen);
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
          _applyError = AppLocalizations.of(context)!.invalidPosition);
      return;
    }
    widget.onConfirm(fen);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
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
                        _buildControls(l),
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
                      _buildFenDisplay(l),
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
                            child: Text(l.cancel),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _apply,
                            child: Text(l.apply),
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

  Widget _buildControls(AppLocalizations l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(l.sideToMove, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                    value: true,
                    label: Text(l.white, style: const TextStyle(fontSize: 12))),
                ButtonSegment(
                    value: false,
                    label: Text(l.black, style: const TextStyle(fontSize: 12))),
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
            Text(l.castling, style: const TextStyle(fontSize: 12)),
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
        const SizedBox(height: 4),
        Row(
          children: [
            Text(l.moveNumber, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _moveNumCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1) {
                    setState(() {
                      _moveNumber = n;
                      _fenCtrl.text = _currentFen;
                    });
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(l.enPassantFile, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: DropdownButtonFormField<String>(
                initialValue: _epFile.isEmpty ? '-' : _epFile,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                items: [
                  const DropdownMenuItem(value: '-', child: Text('-')),
                  for (final f in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (v) => setState(() {
                  _epFile = (v == null || v == '-') ? '' : v;
                  _fenCtrl.text = _currentFen;
                }),
              ),
            ),
            if (_epFile.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                _whiteTurn ? '6' : '3',
                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(l.halfMovesCount, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _halfMoveCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 0) {
                    setState(() {
                      _halfMoveClock = n;
                      _fenCtrl.text = _currentFen;
                    });
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFenDisplay(AppLocalizations l) {
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
          tooltip: l.pasteFromClipboard,
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

