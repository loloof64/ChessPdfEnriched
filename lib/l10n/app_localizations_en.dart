// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get openBook => 'Open a book';

  @override
  String get openBookButton => 'Open a book (.chessbook)';

  @override
  String openFailed(String error) {
    return 'Could not open: $error';
  }

  @override
  String saveFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String pageAbsent(int page, int first, int last) {
    return 'Page $page not found (pages $first to $last)';
  }

  @override
  String get previousPage => 'Previous page';

  @override
  String get nextPage => 'Next page';

  @override
  String get showReconstructedText => 'Show the reconstructed text';

  @override
  String get showOriginalPage => 'Show the original page (facsimile)';

  @override
  String get zoomOut => 'Zoom out';

  @override
  String get zoomIn => 'Zoom in';

  @override
  String get zoomLevel => 'Zoom level';

  @override
  String get zoomFitPage => 'Whole page';

  @override
  String get zoomFitWidth => 'Page width';

  @override
  String get sideWhite => 'White to move';

  @override
  String get sideBlack => 'Black to move';

  @override
  String get clickMove => 'Click a move';

  @override
  String diagramTitle(String id) {
    return 'Diagram $id';
  }

  @override
  String get diagramFlipped => ' (flipped: white at the bottom)';

  @override
  String get diagramCorrected => ' — corrected';

  @override
  String get diagramNeedsReview => ' — correction to review';

  @override
  String get flipBoard => 'Flip the board';

  @override
  String get correctDiagram => 'Correct this diagram (or right click)';

  @override
  String get correctDiagramTitle => 'Correct the diagram';

  @override
  String get dragHint =>
      'Drag a piece onto a square; off the board to remove it.';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String movesSummary(int moves, int illegal) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves moves',
      one: '$moves move',
    );
    return '$_temp0, $illegal illegal (in red)';
  }

  @override
  String get language => 'Language';

  @override
  String get languageAuto => 'Automatic';
}
