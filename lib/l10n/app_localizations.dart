import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('fr'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Chess PDF Enriched'**
  String get appTitle;

  /// No description provided for @openPdf.
  ///
  /// In en, this message translates to:
  /// **'Open PDF'**
  String get openPdf;

  /// No description provided for @showRawText.
  ///
  /// In en, this message translates to:
  /// **'Show raw extracted text'**
  String get showRawText;

  /// No description provided for @reanalyse.
  ///
  /// In en, this message translates to:
  /// **'Re-analyse moves'**
  String get reanalyse;

  /// No description provided for @rawTextDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Raw text — page {pageNumber}'**
  String rawTextDialogTitle(int pageNumber);

  /// No description provided for @emptyText.
  ///
  /// In en, this message translates to:
  /// **'(empty)'**
  String get emptyText;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @failedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load PDF:\n{error}'**
  String failedToLoad(String error);

  /// No description provided for @pageOf.
  ///
  /// In en, this message translates to:
  /// **'Page {current} of {total}'**
  String pageOf(int current, int total);

  /// No description provided for @previousPage.
  ///
  /// In en, this message translates to:
  /// **'Previous page'**
  String get previousPage;

  /// No description provided for @nextPage.
  ///
  /// In en, this message translates to:
  /// **'Next page'**
  String get nextPage;

  /// No description provided for @analysing.
  ///
  /// In en, this message translates to:
  /// **'Analysing…'**
  String get analysing;

  /// No description provided for @gameNumber.
  ///
  /// In en, this message translates to:
  /// **'Game {n}'**
  String gameNumber(int n);

  /// No description provided for @diagramWarning.
  ///
  /// In en, this message translates to:
  /// **'Starting position may come from a board diagram — FEN not detected.'**
  String get diagramWarning;

  /// No description provided for @enterFen.
  ///
  /// In en, this message translates to:
  /// **'Enter FEN'**
  String get enterFen;

  /// No description provided for @userFenLabel.
  ///
  /// In en, this message translates to:
  /// **'Starting position: user-provided FEN.'**
  String get userFenLabel;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @setStartingPosition.
  ///
  /// In en, this message translates to:
  /// **'Set starting position'**
  String get setStartingPosition;

  /// No description provided for @editStartingPosition.
  ///
  /// In en, this message translates to:
  /// **'Edit starting position'**
  String get editStartingPosition;

  /// No description provided for @detectedFenLabel.
  ///
  /// In en, this message translates to:
  /// **'Starting position: FEN detected in text.'**
  String get detectedFenLabel;

  /// No description provided for @inheritedFenLabel.
  ///
  /// In en, this message translates to:
  /// **'Position inherited from previous page.'**
  String get inheritedFenLabel;

  /// No description provided for @sideToMove.
  ///
  /// In en, this message translates to:
  /// **'Side to move:'**
  String get sideToMove;

  /// No description provided for @white.
  ///
  /// In en, this message translates to:
  /// **'White'**
  String get white;

  /// No description provided for @black.
  ///
  /// In en, this message translates to:
  /// **'Black'**
  String get black;

  /// No description provided for @castling.
  ///
  /// In en, this message translates to:
  /// **'Castling:'**
  String get castling;

  /// No description provided for @moveNumber.
  ///
  /// In en, this message translates to:
  /// **'Move number:'**
  String get moveNumber;

  /// No description provided for @enPassantFile.
  ///
  /// In en, this message translates to:
  /// **'En passant file:'**
  String get enPassantFile;

  /// No description provided for @halfMovesCount.
  ///
  /// In en, this message translates to:
  /// **'Half-moves (draw):'**
  String get halfMovesCount;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get pasteFromClipboard;

  /// No description provided for @invalidFen.
  ///
  /// In en, this message translates to:
  /// **'Invalid FEN'**
  String get invalidFen;

  /// No description provided for @invalidPosition.
  ///
  /// In en, this message translates to:
  /// **'Invalid position — both kings must be on the board.'**
  String get invalidPosition;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @noMovesFound.
  ///
  /// In en, this message translates to:
  /// **'No chess moves found on this page.'**
  String get noMovesFound;

  /// No description provided for @editingStartPositions.
  ///
  /// In en, this message translates to:
  /// **'Editing start positions'**
  String get editingStartPositions;

  /// No description provided for @suspectedIntermediateDiagramLabel.
  ///
  /// In en, this message translates to:
  /// **'Diagram detected — looks like a mid-game position (game continues).'**
  String get suspectedIntermediateDiagramLabel;

  /// No description provided for @confirmedIntermediateLabel.
  ///
  /// In en, this message translates to:
  /// **'Intermediate diagram — game continues from current position.'**
  String get confirmedIntermediateLabel;

  /// No description provided for @markAsNewGame.
  ///
  /// In en, this message translates to:
  /// **'New game'**
  String get markAsNewGame;

  /// No description provided for @markAsIntermediate.
  ///
  /// In en, this message translates to:
  /// **'Intermediate'**
  String get markAsIntermediate;

  /// No description provided for @markAsNotADiagram.
  ///
  /// In en, this message translates to:
  /// **'Not a diagram'**
  String get markAsNotADiagram;

  /// No description provided for @notADiagramLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirmed: not a board diagram — game continues.'**
  String get notADiagramLabel;

  /// No description provided for @markAsSuspectedDiagram.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get markAsSuspectedDiagram;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get discard;

  /// No description provided for @discardBecauseIntermediate.
  ///
  /// In en, this message translates to:
  /// **'because is intermediate'**
  String get discardBecauseIntermediate;

  /// No description provided for @discardBecauseNewGame.
  ///
  /// In en, this message translates to:
  /// **'because is new game'**
  String get discardBecauseNewGame;

  /// No description provided for @analysisOptions.
  ///
  /// In en, this message translates to:
  /// **'Analysis options'**
  String get analysisOptions;

  /// No description provided for @notationModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Notation type'**
  String get notationModeLabel;

  /// No description provided for @textSanNotation.
  ///
  /// In en, this message translates to:
  /// **'Text (SAN)'**
  String get textSanNotation;

  /// No description provided for @figurineFanNotation.
  ///
  /// In en, this message translates to:
  /// **'Figurine (FAN)'**
  String get figurineFanNotation;

  /// No description provided for @analyse.
  ///
  /// In en, this message translates to:
  /// **'Analyse'**
  String get analyse;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
