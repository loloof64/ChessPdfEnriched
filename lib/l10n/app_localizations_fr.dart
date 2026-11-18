// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get openBook => 'Ouvrir un livre';

  @override
  String get openBookButton => 'Ouvrir un livre (.chessbook)';

  @override
  String openFailed(String error) {
    return 'Ouverture impossible : $error';
  }

  @override
  String saveFailed(String error) {
    return 'Enregistrement impossible : $error';
  }

  @override
  String pageAbsent(int page, int first, int last) {
    return 'Page $page absente (pages $first à $last)';
  }

  @override
  String get previousPage => 'Page précédente';

  @override
  String get nextPage => 'Page suivante';

  @override
  String get showReconstructedText => 'Afficher le texte reconstitué';

  @override
  String get showOriginalPage => 'Afficher la page d\'origine (fac-similé)';

  @override
  String get zoomOut => 'Réduire la page';

  @override
  String get zoomIn => 'Agrandir la page';

  @override
  String get zoomLevel => 'Niveau de zoom';

  @override
  String get zoomFitPage => 'Page entière';

  @override
  String get zoomFitWidth => 'Largeur de page';

  @override
  String get sideWhite => 'Trait aux Blancs';

  @override
  String get sideBlack => 'Trait aux Noirs';

  @override
  String get clickMove => 'Cliquer sur un coup';

  @override
  String diagramTitle(String id) {
    return 'Diagramme $id';
  }

  @override
  String get diagramFlipped => ' (retourné : blancs en bas)';

  @override
  String get diagramCorrected => ' — corrigé';

  @override
  String get diagramNeedsReview => ' — correction à revoir';

  @override
  String get flipBoard => 'Retourner l\'échiquier';

  @override
  String get correctDiagram => 'Corriger ce diagramme (ou clic droit)';

  @override
  String get correctDiagramTitle => 'Corriger le diagramme';

  @override
  String get dragHint =>
      'Glisser une pièce sur une case ; hors du plateau pour la supprimer.';

  @override
  String get cancel => 'Annuler';

  @override
  String get save => 'Enregistrer';

  @override
  String movesSummary(int moves, int illegal) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves coups',
      one: '$moves coup',
    );
    String _temp1 = intl.Intl.pluralLogic(
      illegal,
      locale: localeName,
      other: '$illegal illégaux',
      one: '$illegal illégal',
    );
    return '$_temp0, $_temp1 (en rouge)';
  }

  @override
  String get language => 'Langue';

  @override
  String get languageAuto => 'Automatique';
}
