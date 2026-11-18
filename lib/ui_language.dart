import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_localizations.dart';

const supportedLanguages = ['en', 'fr', 'es'];
const _languageNames = {'en': 'English', 'fr': 'Français', 'es': 'Español'}; // never translated
const _key = 'ui_lang';

/// The language to show: the manual choice when there is one, else the first system language that is supported (matched on the
/// language code, so fr_CA gives fr), else English.
Locale resolveLocale(Locale? setting, List<Locale> system) {
  if (setting != null && supportedLanguages.contains(setting.languageCode)) return Locale(setting.languageCode);
  for (final l in system) {
    if (supportedLanguages.contains(l.languageCode)) return Locale(l.languageCode);
  }
  return const Locale('en');
}

/// The saved manual choice; null (Automatic) when absent, unknown, wrongly typed or when the storage fails.
Future<Locale?> loadUiLanguage() async {
  try {
    final v = (await SharedPreferences.getInstance()).get(_key);
    return v is String && supportedLanguages.contains(v) ? Locale(v) : null;
  } catch (_) {
    return null;
  }
}

/// Saves the manual choice (null = Automatic removes it); a storage failure only costs the memory of the choice.
Future<void> saveUiLanguage(Locale? locale) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, locale.languageCode);
    }
  } catch (_) {}
}

/// App bar button: Automatic, English, Français, Español (the current one checked).
class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key, required this.current, required this.onChanged});

  final Locale? current;
  final ValueChanged<Locale?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.language),
      tooltip: l.language,
      onSelected: (v) => onChanged(v == 'auto' ? null : Locale(v)),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'auto', checked: current == null, child: Text(l.languageAuto)),
        for (final c in supportedLanguages) CheckedPopupMenuItem(value: c, checked: current?.languageCode == c, child: Text(_languageNames[c]!)),
      ],
    );
  }
}
