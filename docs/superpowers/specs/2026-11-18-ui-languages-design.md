# UI languages (en / fr / es) — design

## Intent
Both programs (the Flutter reader and the Python graphical front end) show their interface in the user's language, so the project can
be used by English-, French- and Spanish-speaking readers without editing code.

## Goals
- Supported UI languages: English, French, Spanish.
- Default: the system language when it is one of the three, English otherwise (also when it cannot be detected).
- Manual choice in both programs: a language menu with *Automatic* (= the rule above), *English*, *Français*, *Español*. The choice is
  remembered between runs and applies immediately (no restart).

## Non-goals
- Book content (OCR text, moves) and the book's move-notation language (`fr`/`en` option of the pipeline, "Move language" in the GUI)
  stay as they are: that is a property of the book, not of the interface. Spanish move notation is a separate feature.
- Console messages of `make_chessbook_cli.py` stay in English. Tracebacks, `README.md`, `CHANGELOG.md` stay in English.
- No other languages, no right-to-left layout, no per-platform installer translations.

## Anti-goals
- A language setting that can silently get stuck: *Automatic* must always be selectable again, and an unreadable settings file must fall
  back to Automatic, never crash the app.

## Constraints
- Flutter stays pinned to 3.47.8; the reader is used on Linux and Windows.
- No new tooling beyond what is below; nothing to install for the Python front end (stdlib only).

## Approaches considered
- Reader strings: (A) Flutter's official localization (ARB files + generated code) — chosen; (B) a hand-written dictionary — rejected:
  no checked placeholders, plurals by hand.
- Reader setting storage: (A) `shared_preferences` — chosen; (B) a hand-written JSON file — rejected: needs per-platform folders.
- Python front end: a dictionary `{key: {en, fr, es}}` in a small module; `gettext` is out of proportion for ~20 strings.

## Design

### Reader (Flutter)
- Dependencies: `flutter_localizations` (SDK), `intl`, `shared_preferences`. `flutter: generate: true` and an `l10n.yaml` (template `app_en.arb`).
- `lib/l10n/app_en.arb`, `app_fr.arb`, `app_es.arb`: all user-visible strings of `lib/main.dart` (buttons, tooltips, snackbars, dialog,
  zoom presets), with ICU placeholders and plurals (e.g. number of moves / illegal moves).
  The current French texts move to `app_fr.arb` unchanged.
- `MaterialApp`: `localizationsDelegates`, `supportedLocales` (en, fr, es), and a locale resolution that matches on language code only
  and returns English when nothing matches. An optional saved override (`en`/`fr`/`es`; absent = Automatic) is read at startup.
- A language menu button in the app bar (popup with the four entries, the current one checked); selecting one saves it and rebuilds.
- Check: a test that the three ARB files have exactly the same keys, and one for the resolution rule (fr-CA → fr, de → en, none → en).

### Python front end
- New `pipeline/gui_i18n.py`: `STRINGS`, `detect()` (system language from the locale; en when unknown), `t(key, **fmt)`.
- `make_chessbook_gui.py`: every label, button, message box and status text goes through `t()`; a language combobox (Automatic,
  English, Français, Español); selecting one re-labels the open window at once and saves `ui_lang` in `work/gui_settings.json`
  (absent = Automatic). The existing "Move language" combobox is renamed "Book move notation" to avoid confusion.
- Check: `python gui_i18n.py` self-check: all three languages define the same keys, formats fill, `detect()` falls back to en.

### Docs
- `CHANGELOG.md` entry under `Unreleased`; one line in the README saying the interface languages and where the choice is stored.

## Left to the builder
- Exact key names, wording of the English texts, layout of the language menu, and how the GUI re-labels its widgets.
- Spanish and English texts are written by Claude from the French originals: a Spanish speaker should review them.
- Native dialogs opened by `file_picker` (zenity/Windows) follow the system language, not this setting.
