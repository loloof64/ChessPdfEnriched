// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'Chess PDF Enriched';

  @override
  String get openPdf => 'Ouvrir un PDF';

  @override
  String get showRawText => 'Afficher le texte brut extrait';

  @override
  String get reanalyse => 'Réanalyser les coups';

  @override
  String rawTextDialogTitle(int pageNumber) {
    return 'Texte brut — page $pageNumber';
  }

  @override
  String get emptyText => '(vide)';

  @override
  String get close => 'Fermer';

  @override
  String failedToLoad(String error) {
    return 'Impossible de charger le PDF :\n$error';
  }

  @override
  String pageOf(int current, int total) {
    return 'Page $current sur $total';
  }

  @override
  String get previousPage => 'Page précédente';

  @override
  String get nextPage => 'Page suivante';

  @override
  String get analysing => 'Analyse en cours…';

  @override
  String gameNumber(int n) {
    return 'Partie $n';
  }

  @override
  String get diagramWarning =>
      'La position de départ peut provenir d\'un diagramme — FEN non détecté.';

  @override
  String get enterFen => 'Saisir le FEN';

  @override
  String get userFenLabel =>
      'Position de départ : FEN fourni par l\'utilisateur.';

  @override
  String get edit => 'Modifier';

  @override
  String get setStartingPosition => 'Définir la position de départ';

  @override
  String get editStartingPosition => 'Modifier la position de départ';

  @override
  String get detectedFenLabel =>
      'Position de départ : FEN détecté dans le texte.';

  @override
  String get inheritedFenLabel => 'Position héritée de la page précédente.';

  @override
  String get sideToMove => 'Trait :';

  @override
  String get white => 'Blancs';

  @override
  String get black => 'Noirs';

  @override
  String get castling => 'Roques :';

  @override
  String get pasteFromClipboard => 'Coller depuis le presse-papiers';

  @override
  String get invalidFen => 'FEN invalide';

  @override
  String get invalidPosition =>
      'Position invalide — les deux rois doivent être sur l\'échiquier.';

  @override
  String get cancel => 'Annuler';

  @override
  String get apply => 'Appliquer';

  @override
  String get noMovesFound => 'Aucun coup d\'échecs trouvé sur cette page.';

  @override
  String get editingStartPositions => 'Édition des positions de départ';

  @override
  String get suspectedIntermediateDiagramLabel =>
      'Diagramme détecté — semble être une position intermédiaire (la partie continue).';

  @override
  String get confirmedIntermediateLabel =>
      'Diagramme intermédiaire — la partie continue depuis la position actuelle.';

  @override
  String get markAsNewGame => 'Nouvelle partie';

  @override
  String get markAsIntermediate => 'Intermédiaire';

  @override
  String get markAsNotADiagram => 'Pas un diagramme';

  @override
  String get notADiagramLabel =>
      'Confirmé : pas un diagramme d\'échecs — la partie continue.';

  @override
  String get markAsSuspectedDiagram => 'Annuler';
}
