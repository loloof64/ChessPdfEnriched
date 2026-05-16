// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Chess PDF Enriched';

  @override
  String get openPdf => 'Abrir PDF';

  @override
  String get showRawText => 'Mostrar texto extraído';

  @override
  String get reanalyse => 'Reanalizar movimientos';

  @override
  String rawTextDialogTitle(int pageNumber) {
    return 'Texto bruto — página $pageNumber';
  }

  @override
  String get emptyText => '(vacío)';

  @override
  String get close => 'Cerrar';

  @override
  String failedToLoad(String error) {
    return 'Error al cargar el PDF:\n$error';
  }

  @override
  String pageOf(int current, int total) {
    return 'Página $current de $total';
  }

  @override
  String get previousPage => 'Página anterior';

  @override
  String get nextPage => 'Página siguiente';

  @override
  String get analysing => 'Analizando…';

  @override
  String gameNumber(int n) {
    return 'Partida $n';
  }

  @override
  String get diagramWarning =>
      'La posición inicial puede provenir de un diagrama — FEN no detectado.';

  @override
  String get enterFen => 'Introducir FEN';

  @override
  String get userFenLabel =>
      'Posición inicial: FEN introducido por el usuario.';

  @override
  String get edit => 'Editar';

  @override
  String get setStartingPosition => 'Establecer posición inicial';

  @override
  String get editStartingPosition => 'Editar posición inicial';

  @override
  String get detectedFenLabel => 'Posición inicial: FEN detectado en el texto.';

  @override
  String get inheritedFenLabel => 'Posición heredada de la página anterior.';

  @override
  String get sideToMove => 'Turno:';

  @override
  String get white => 'Blancas';

  @override
  String get black => 'Negras';

  @override
  String get castling => 'Enroques:';

  @override
  String get pasteFromClipboard => 'Pegar desde el portapapeles';

  @override
  String get invalidFen => 'FEN no válido';

  @override
  String get invalidPosition =>
      'Posición inválida — ambos reyes deben estar en el tablero.';

  @override
  String get cancel => 'Cancelar';

  @override
  String get apply => 'Aplicar';

  @override
  String get noMovesFound =>
      'No se encontraron movimientos de ajedrez en esta página.';

  @override
  String get editingStartPositions => 'Edición de posiciones iniciales';
}
