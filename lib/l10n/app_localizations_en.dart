// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Chess PDF Enriched';

  @override
  String get openPdf => 'Open PDF';

  @override
  String get showRawText => 'Show raw extracted text';

  @override
  String get reanalyse => 'Re-analyse moves';

  @override
  String rawTextDialogTitle(int pageNumber) {
    return 'Raw text — page $pageNumber';
  }

  @override
  String get emptyText => '(empty)';

  @override
  String get close => 'Close';

  @override
  String failedToLoad(String error) {
    return 'Failed to load PDF:\n$error';
  }

  @override
  String pageOf(int current, int total) {
    return 'Page $current of $total';
  }

  @override
  String get previousPage => 'Previous page';

  @override
  String get nextPage => 'Next page';

  @override
  String get analysing => 'Analysing…';

  @override
  String gameNumber(int n) {
    return 'Game $n';
  }

  @override
  String get diagramWarning =>
      'Starting position may come from a board diagram — FEN not detected.';

  @override
  String get enterFen => 'Enter FEN';

  @override
  String get userFenLabel => 'Starting position: user-provided FEN.';

  @override
  String get edit => 'Edit';

  @override
  String get setStartingPosition => 'Set starting position';

  @override
  String get editStartingPosition => 'Edit starting position';

  @override
  String get detectedFenLabel => 'Starting position: FEN detected in text.';

  @override
  String get inheritedFenLabel => 'Position inherited from previous page.';

  @override
  String get sideToMove => 'Side to move:';

  @override
  String get white => 'White';

  @override
  String get black => 'Black';

  @override
  String get castling => 'Castling:';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get invalidFen => 'Invalid FEN';

  @override
  String get invalidPosition =>
      'Invalid position — both kings must be on the board.';

  @override
  String get cancel => 'Cancel';

  @override
  String get apply => 'Apply';

  @override
  String get noMovesFound => 'No chess moves found on this page.';

  @override
  String get editingStartPositions => 'Editing start positions';
}
