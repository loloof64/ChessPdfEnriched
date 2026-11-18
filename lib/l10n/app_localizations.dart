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

  /// No description provided for @openBook.
  ///
  /// In en, this message translates to:
  /// **'Open a book'**
  String get openBook;

  /// No description provided for @openBookButton.
  ///
  /// In en, this message translates to:
  /// **'Open a book (.chessbook)'**
  String get openBookButton;

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open: {error}'**
  String openFailed(String error);

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save: {error}'**
  String saveFailed(String error);

  /// No description provided for @pageAbsent.
  ///
  /// In en, this message translates to:
  /// **'Page {page} not found (pages {first} to {last})'**
  String pageAbsent(int page, int first, int last);

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

  /// No description provided for @showReconstructedText.
  ///
  /// In en, this message translates to:
  /// **'Show the reconstructed text'**
  String get showReconstructedText;

  /// No description provided for @showOriginalPage.
  ///
  /// In en, this message translates to:
  /// **'Show the original page (facsimile)'**
  String get showOriginalPage;

  /// No description provided for @zoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get zoomOut;

  /// No description provided for @zoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get zoomIn;

  /// No description provided for @zoomLevel.
  ///
  /// In en, this message translates to:
  /// **'Zoom level'**
  String get zoomLevel;

  /// No description provided for @zoomFitPage.
  ///
  /// In en, this message translates to:
  /// **'Whole page'**
  String get zoomFitPage;

  /// No description provided for @zoomFitWidth.
  ///
  /// In en, this message translates to:
  /// **'Page width'**
  String get zoomFitWidth;

  /// No description provided for @sideWhite.
  ///
  /// In en, this message translates to:
  /// **'White to move'**
  String get sideWhite;

  /// No description provided for @sideBlack.
  ///
  /// In en, this message translates to:
  /// **'Black to move'**
  String get sideBlack;

  /// No description provided for @clickMove.
  ///
  /// In en, this message translates to:
  /// **'Click a move'**
  String get clickMove;

  /// No description provided for @diagramTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagram {id}'**
  String diagramTitle(String id);

  /// No description provided for @diagramFlipped.
  ///
  /// In en, this message translates to:
  /// **' (flipped: white at the bottom)'**
  String get diagramFlipped;

  /// No description provided for @diagramCorrected.
  ///
  /// In en, this message translates to:
  /// **' — corrected'**
  String get diagramCorrected;

  /// No description provided for @diagramNeedsReview.
  ///
  /// In en, this message translates to:
  /// **' — correction to review'**
  String get diagramNeedsReview;

  /// No description provided for @flipBoard.
  ///
  /// In en, this message translates to:
  /// **'Flip the board'**
  String get flipBoard;

  /// No description provided for @correctDiagram.
  ///
  /// In en, this message translates to:
  /// **'Correct this diagram (or right click)'**
  String get correctDiagram;

  /// No description provided for @correctDiagramTitle.
  ///
  /// In en, this message translates to:
  /// **'Correct the diagram'**
  String get correctDiagramTitle;

  /// No description provided for @dragHint.
  ///
  /// In en, this message translates to:
  /// **'Drag a piece onto a square; off the board to remove it.'**
  String get dragHint;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @movesSummary.
  ///
  /// In en, this message translates to:
  /// **'{moves, plural, one{{moves} move} other{{moves} moves}}, {illegal} illegal (in red)'**
  String movesSummary(int moves, int illegal);

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get languageAuto;
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
