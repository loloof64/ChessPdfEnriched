# UI languages (en / fr / es) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both programs show their interface in English, French or Spanish: system language when supported (English otherwise), with a remembered manual choice.

**Architecture:** Python front end: a small `gui_i18n.py` module (dictionary + detection) used by `make_chessbook_gui.py`. Reader: Flutter's official localization (ARB files, generated `AppLocalizations`) plus a locale override stored with `shared_preferences`. Strings are built at render time from data, never stored translated.

**Tech Stack:** Python 3.13 stdlib + tkinter; Flutter 3.47.8 (pinned), `flutter_localizations`, `intl`, `shared_preferences`.

**Spec:** `docs/superpowers/specs/2026-11-18-ui-languages-design.md`

## Global Constraints

- Languages: `en`, `fr`, `es`. Default: system language if one of them, else `en` (also when undetectable).
- Manual menu entries, in this order: *Automatic*, *English*, *Français*, *Español* (language names are never translated). Choice is remembered and applies immediately, no restart.
- Settings: reader = `shared_preferences` key `ui_lang` (`en`/`fr`/`es`, absent = Automatic); Python = key `ui_lang` in `work/gui_settings.json` (absent = Automatic). The existing key `lang` of that file is the BOOK move notation: do not touch it.
- Unreadable or unknown settings value => Automatic, never a crash.
- Not translated: book content, move-notation option (`fr`/`en`, renamed "Book move notation" in the GUI), CLI console messages, README/CHANGELOG.
- Code and comments in English; the current French reader texts move to `app_fr.arb` unchanged. English and Spanish texts are written from the French; the report must say a Spanish speaker should review `app_es.arb` and the `es` entries.
- Flutter stays 3.47.8. Nothing new to install for the Python side. Commit only where a task says so, no tags.

## Review Focus

1. System locale variants: `fr_CA`, `es_MX`, `fr_FR.UTF-8`, `pt_BR`, `C`, `POSIX`, empty/None → match on language code, anything else `en`.
2. Bad settings: invalid JSON, `ui_lang: "de"`, wrong type, or `shared_preferences` throwing → Automatic, app starts.
3. Switching language while state is selected (a move/diagram chosen in the reader, a job running in the GUI): selected-item label and side-to-move text re-render in the new language; GUI progress keeps working (the CLI's progress labels are identifiers, not display text).
4. Plurals of "moves / illegal moves" for 0, 1, 2 in all three languages (French uses *one* for 0 and 1).
5. Same keys and same placeholders in the three languages (a missing key must fail a test, not show `null` at runtime).

---

## File Structure

- Create `pipeline/gui_i18n.py` — strings, `detect()`, `t()`, self-check. One responsibility: text lookup.
- Modify `pipeline/make_chessbook_gui.py` — all text through `t()`, language combobox, live re-labelling.
- Create `l10n.yaml`, `lib/l10n/app_{en,fr,es}.arb` (+ generated `app_localizations*.dart`, committed).
- Create `lib/ui_language.dart` — `Locale resolveLocale(...)`, `loadUiLanguage()`, `saveUiLanguage()`. Pure/small, testable.
- Modify `lib/main.dart` (strings → `AppLocalizations`, language menu, async `main`), `pubspec.yaml`, `test/widget_test.dart`.
- Create `test/l10n_test.dart`. Modify `CHANGELOG.md`, `README.md`.

---

### Task 1: Python string module

**Files:** Create `pipeline/gui_i18n.py`.

**Interfaces:**
- Produces: `LANGUAGES = ("en", "fr", "es")`; `STRINGS: dict[str, dict[str, str]]` (key → {lang → text}, `{name}` placeholders for `str.format`); `detect(env=None, locale_name=None) -> str` returning one of `LANGUAGES`; `set_language(setting: str | None) -> None` (`None`/unknown = Automatic → `detect()`); `current() -> str`; `t(key: str, **fmt) -> str`.

- [ ] **Step 1: Write the self-check** in `if __name__ == "__main__":` (run with `.venv/bin/python gui_i18n.py`), as asserts:
  - every key has exactly `en`, `fr`, `es`, and the set of `{placeholders}` (use `string.Formatter().parse`) is identical across the three;
  - `detect(env={"LANG": "fr_CA.UTF-8"}) == "fr"`, `"es_MX"` → `"es"`, `"en_GB"` → `"en"`, `"pt_BR"` → `"en"`, `"C"`, `"POSIX"`, `""`, and `env={}` with `locale_name=None` → `"en"`; `LANGUAGE="es:en"` wins over `LANG=fr_FR` (first entry of `LANGUAGE`, then `LC_ALL`, `LC_MESSAGES`, `LANG`, as gettext does);
  - `set_language("de")` and `set_language(5)` behave as Automatic; `set_language("es")` then `t("start") == STRINGS["start"]["es"]`; `t("overall_step", n=2, total=4, time="01:05")` fills all fields.
- [ ] **Step 2: Run it, expect failure** (`ModuleNotFoundError`/assert).
- [ ] **Step 3: Implement.** `detect` reads the env vars in the order above (default `os.environ`), falls back to `locale.getlocale()[0]` when `locale_name` is not given and no env var is set; takes the first two letters lowercase; `en` when not in `LANGUAGES`. Keys and English copy (verbatim from the current GUI): `window_title` "Chess PDF Enriched : make chessbook", `book` "Book (PDF)", `choose` "Choose…", `output` "Output (.chessbook)", `notation` "Book move notation", `ui_language` "Interface language", `auto` "Automatic", `start` "Start", `cancel` "Cancel", `step` "Step", `overall` "Overall", `overall_time` "Overall: {time}", `overall_step` "Overall: step {n} of {total}, {time}", `starting` "Starting (loading the models, can take a minute)…", `done` "Done", `stopped` "Stopped (exit code {code})", `cancelled` "Cancelled.", `missing_title` "Missing file", `missing_msg` "Choose an existing PDF and an output file.", `pick_pdf` "Choose the PDF", `pick_out` "Write the .chessbook to", plus `step_ocr`, `step_moves`, `step_locate`, `step_diagrams` = "Reading pages (OCR)", "Moves from diagrams", "Locating moves", "Reading diagrams". Add any other user-visible string found in `make_chessbook_gui.py`. Language names (`English`, `Français`, `Español`) are constants, not entries.
- [ ] **Step 4: Run it, expect `gui_i18n self-check ok`.**
- [ ] **Step 5: Commit** `git add pipeline/gui_i18n.py && git commit -m "GUI: i18n module (en/fr/es) with locale detection"`.

### Task 2: Python front end uses it

**Files:** Modify `pipeline/make_chessbook_gui.py`.

**Interfaces:** Consumes Task 1. Produces: setting `ui_lang` in `work/gui_settings.json`.

- [ ] **Step 1: Wire it.** At startup `set_language(self.settings.get("ui_lang"))`. Replace every literal by `t(...)`. Keep widgets in a list of `(widget, option, key)` (or equivalent) so `retranslate()` re-applies all texts, the window title and the combobox lists at once. Add a read-only combobox "Interface language" with values `[t("auto"), "English", "Français", "Español"]` (row 3, push the following rows down); selecting an entry calls `set_language`, `remember(ui_lang=...)` (remove the key for Automatic), then `retranslate()`.
- [ ] **Step 2: Keep CLI labels as identifiers.** `STEPS` stays the list of the CLI's English labels (they match `@@PROGRESS` lines); only the display goes through `t("step_ocr")`, … via a `{label: key}` map. The status text and the overall line are rebuilt from stored data (current label, i, n, note, stage, elapsed) so `retranslate()` can redraw them without waiting for the next progress line.
- [ ] **Step 3: Check headlessly** (a display exists on this machine; otherwise skip and say so): a throwaway script instantiates `App()`, calls `progress("Reading diagrams", 3, 12, "p4")`, switches to `es` via the combobox handler, asserts the step and overall texts are Spanish and the saved JSON has `ui_lang: "es"` while `lang` is untouched; sets Automatic and asserts the key is gone; starts with a settings file containing `{"ui_lang": "de"}` and with invalid JSON and asserts no exception.
- [ ] **Step 4: Run** `.venv/bin/python gui_i18n.py` and `.venv/bin/python -m py_compile make_chessbook_gui.py`, expect both OK.
- [ ] **Step 5: Commit** `git add pipeline/make_chessbook_gui.py && git commit -m "GUI: interface language (auto/en/fr/es) with live switching"`.

### Task 3: Reader strings through AppLocalizations

**Files:** Modify `pubspec.yaml` (add `flutter_localizations: {sdk: flutter}`, `intl`, `shared_preferences`; `flutter: generate: true`); create `l10n.yaml` (`arb-dir: lib/l10n`, `template-arb-file: app_en.arb`, `output-localization-file: app_localizations.dart`, `output-dir: lib/l10n`, `synthetic-package: false`); create `lib/l10n/app_{en,fr,es}.arb`; modify `lib/main.dart`, `test/widget_test.dart`; create `test/l10n_test.dart`.

**Interfaces:** Produces: generated class `AppLocalizations` (`import 'package:chess_pdf_enriched/l10n/app_localizations.dart'`), `AppLocalizations.of(context)!`, `AppLocalizations.supportedLocales`; getters/methods named after the keys below.

- [ ] **Step 1: Write the failing tests** in `test/l10n_test.dart`:
  - `'the three ARB files have the same keys and placeholders'`: parse the JSON files; for each non-`@` key, same key set and same `{placeholder}` set in en/fr/es;
  - `'moves count plural'`: with `AppLocalizations` built per locale, `movesSummary(0, 0)`, `(1, 0)`, `(2, 1)` in `en`, `fr`, `es` contain the right numbers and singular/plural forms (e.g. en "1 move, 0 illegal (in red)"; fr "1 coup, 0 illégal (en rouge)" and "0 coup" for 0; es "1 jugada"), exact strings fixed by the ARB;
  - update `widget_test.dart`: expects `find.textContaining('Open a book')` (test environment locale is `en_US`), plus a second test pumping the app with `locale: Locale('fr')` expecting `'Ouvrir un livre'`.
- [ ] **Step 2: Run** `flutter test test/l10n_test.dart test/widget_test.dart`, expect failure (no ARB / no localizations).
- [ ] **Step 3: Extract every user-visible string** of `lib/main.dart` (≈30: open button and dialog title, errors `Ouverture impossible : $e` / `Enregistrement impossible : $e`, `Page $p absente (pages $a à $b)`, tooltips, zoom presets, `Trait aux Blancs/Noirs`, diagram label with *flipped / corrected / to review* suffixes, `Cliquer sur un coup`, the moves summary with two plurals, board flip, correction dialog texts, Cancel/Save) into the three ARB files. English is the template. `app_fr.arb` = current French verbatim. Placeholders typed (`int`, `String`); the moves summary uses ICU `plural` for both counts. Run `flutter gen-l10n` and commit the generated files.
- [ ] **Step 4: Replace the literals** with `AppLocalizations.of(context)!.<key>`. State must hold data, not text: replace the stored `trait` and `label` strings by values (side to move `bool?`, selected diagram, flags) and build the text in `build()`. Strings needed outside a widget `build` (picker error in `_open`) use `AppLocalizations.of(_messenger.currentContext!)`. `MaterialApp` gets `localizationsDelegates: AppLocalizations.localizationsDelegates`, `supportedLocales: AppLocalizations.supportedLocales`, `onGenerateTitle`.
- [ ] **Step 5: Run** `flutter gen-l10n && flutter analyze && flutter test`, expect no analyzer issue and all tests pass (other tests may contain French strings: update them to the English default or an explicit locale).
- [ ] **Step 6: Commit** `git add pubspec.yaml pubspec.lock l10n.yaml lib test && git commit -m "Reader: localized strings (en/fr/es) with Flutter l10n"`.

### Task 4: Reader language menu and persistence

**Files:** Create `lib/ui_language.dart`; modify `lib/main.dart`, `test/l10n_test.dart`.

**Interfaces:**
- Produces in `lib/ui_language.dart`: `Locale resolveLocale(Locale? setting, List<Locale> system)` (`setting` wins if supported; else first system locale whose `languageCode` is supported; else `Locale('en')`); `Future<Locale?> loadUiLanguage()` (reads `ui_lang`; null for absent, unknown value, wrong type or any exception); `Future<void> saveUiLanguage(Locale? l)` (null removes the key; exceptions swallowed). `ReaderApp({Book? initial, Locale? initialLocale})`.

- [ ] **Step 1: Write the failing tests** (`test/l10n_test.dart`): `resolveLocale(null, [Locale('fr','CA')]) == Locale('fr')`; `[Locale('es','MX')]` → `es`; `[Locale('de')]`, `[Locale('pt','BR')]`, `[]` → `en`; `[Locale('de'), Locale('es')]` → `es` (first supported); `resolveLocale(Locale('fr'), [Locale('es')]) == Locale('fr')`. With `SharedPreferences.setMockInitialValues`: `{'ui_lang': 'fr'}` → `Locale('fr')`; `{'ui_lang': 'de'}` and `{'ui_lang': 5}` → null; no key → null; `save(Locale('es'))` then load → `es`; `save(null)` then load → null. Widget test: pump `ReaderApp(initialLocale: Locale('es'))`, expect the Spanish open button; open the language menu, choose *English*, `pumpAndSettle`, expect the English button; with a book loaded and a move selected (use the existing sample book of `test/book_test.dart` if present, otherwise a minimal in-memory one), switching language changes the side-to-move text without reselecting.
- [ ] **Step 2: Run** `flutter test test/l10n_test.dart`, expect failure.
- [ ] **Step 3: Implement** `lib/ui_language.dart` per the interfaces. In `main.dart`: `main` becomes `async`, calls `WidgetsFlutterBinding.ensureInitialized()` and `loadUiLanguage()` before `runApp(ReaderApp(initial: ..., initialLocale: ...))`; `_ReaderAppState` holds `Locale? uiLocale` and passes `locale: uiLocale` (null = follow the system, which Flutter resolves with `localeResolutionCallback: (l, supported) => resolveLocale(null, l == null ? [] : [l])` kept consistent with the unit-tested function). Add a popup-menu icon button (`Icons.language`, tooltip localized) with the four entries (Automatic localized, the three language names unlocalized, current one checked) in the reader app bar and on the "open a book" start screen (an app bar action there too); choosing an entry sets `uiLocale`, calls `saveUiLanguage`.
- [ ] **Step 4: Run** `flutter analyze && flutter test`, expect all pass.
- [ ] **Step 5: Commit** `git add lib test pubspec.lock && git commit -m "Reader: language menu (auto/en/fr/es) remembered with shared_preferences"`.

### Task 5: Docs and final check

**Files:** Modify `CHANGELOG.md`, `README.md`.

- [ ] **Step 1:** `CHANGELOG.md` under `[Unreleased]`: "Interface languages: English, French and Spanish in the reader and in the graphical front end; follows the system language (English otherwise); manual choice from a menu, remembered." README: one short paragraph (languages, Automatic rule, where the choice is stored: `shared_preferences` for the reader, `work/gui_settings.json` for the front end; move notation is a separate option).
- [ ] **Step 2: Run the full checks:** `.venv/bin/python pipeline/gui_i18n.py` (from `pipeline/` with its venv), `flutter analyze`, `flutter test`; expect all green. Launch the reader once with `LANG=es_ES.UTF-8` and once with `LANG=de_DE.UTF-8` (`flutter run -d linux`, or report that it was not possible) and say what language each showed.
- [ ] **Step 3: Commit** `git add CHANGELOG.md README.md && git commit -m "Docs: interface languages"`; report that Spanish needs review by a Spanish speaker.
