// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get openBook => 'Abrir un libro';

  @override
  String get openBookButton => 'Abrir un libro (.chessbook)';

  @override
  String openFailed(String error) {
    return 'No se pudo abrir: $error';
  }

  @override
  String saveFailed(String error) {
    return 'No se pudo guardar: $error';
  }

  @override
  String pageAbsent(int page, int first, int last) {
    return 'Página $page no encontrada (páginas $first a $last)';
  }

  @override
  String get previousPage => 'Página anterior';

  @override
  String get nextPage => 'Página siguiente';

  @override
  String get showReconstructedText => 'Mostrar el texto reconstruido';

  @override
  String get showOriginalPage => 'Mostrar la página original (facsímil)';

  @override
  String get zoomOut => 'Reducir la página';

  @override
  String get zoomIn => 'Ampliar la página';

  @override
  String get zoomLevel => 'Nivel de zoom';

  @override
  String get zoomFitPage => 'Página completa';

  @override
  String get zoomFitWidth => 'Ancho de página';

  @override
  String get sideWhite => 'Juegan las blancas';

  @override
  String get sideBlack => 'Juegan las negras';

  @override
  String get clickMove => 'Haga clic en una jugada';

  @override
  String diagramTitle(String id) {
    return 'Diagrama $id';
  }

  @override
  String get diagramFlipped => ' (girado: blancas abajo)';

  @override
  String get diagramCorrected => ' — corregido';

  @override
  String get diagramNeedsReview => ' — corrección por revisar';

  @override
  String get flipBoard => 'Girar el tablero';

  @override
  String get correctDiagram => 'Corregir este diagrama (o clic derecho)';

  @override
  String get correctDiagramTitle => 'Corregir el diagrama';

  @override
  String get dragHint =>
      'Arrastre una pieza a una casilla; fuera del tablero para quitarla.';

  @override
  String get cancel => 'Cancelar';

  @override
  String get save => 'Guardar';

  @override
  String movesSummary(int moves, int illegal) {
    String _temp0 = intl.Intl.pluralLogic(
      moves,
      locale: localeName,
      other: '$moves jugadas',
      one: '$moves jugada',
    );
    String _temp1 = intl.Intl.pluralLogic(
      illegal,
      locale: localeName,
      other: '$illegal ilegales',
      one: '$illegal ilegal',
    );
    return '$_temp0, $_temp1 (en rojo)';
  }

  @override
  String get language => 'Idioma';

  @override
  String get languageAuto => 'Automático';
}
