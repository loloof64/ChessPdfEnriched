import 'dart:convert';
import 'dart:io';

import 'package:chess_pdf_enriched/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String lang) => jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, dynamic>;

/// `{name}` placeholders of an ICU message, including those inside plural branches.
Set<String> _placeholders(String message) => RegExp(r'\{(\w+)[,}]|\{(\w+)\}').allMatches(message).map((m) => m.group(1) ?? m.group(2)!).toSet()
  ..removeWhere((p) => const {'one', 'other', 'zero', 'few', 'many'}.contains(p));

void main() {
  test('the three ARB files have the same keys and placeholders', () {
    final en = _arb('en');
    final keys = en.keys.where((k) => !k.startsWith('@')).toSet();
    expect(keys, isNotEmpty);
    for (final lang in ['fr', 'es']) {
      final other = _arb(lang);
      expect(other.keys.where((k) => !k.startsWith('@')).toSet(), keys, reason: 'keys of app_$lang.arb');
      for (final k in keys) {
        expect(_placeholders(other[k] as String), _placeholders(en[k] as String), reason: 'placeholders of $k in $lang');
      }
    }
  });

  test('moves count: plural forms in en, fr and es (French uses "one" for 0 and 1)', () {
    String s(String lang, int moves, int illegal) => lookupAppLocalizations(Locale(lang)).movesSummary(moves, illegal);
    expect(s('en', 0, 0), '0 moves, 0 illegal (in red)');
    expect(s('en', 1, 0), '1 move, 0 illegal (in red)');
    expect(s('en', 2, 1), '2 moves, 1 illegal (in red)');
    expect(s('fr', 0, 0), '0 coup, 0 illégal (en rouge)');
    expect(s('fr', 1, 0), '1 coup, 0 illégal (en rouge)');
    expect(s('fr', 2, 1), '2 coups, 1 illégal (en rouge)');
    expect(s('es', 0, 0), '0 jugadas, 0 ilegales (en rojo)');
    expect(s('es', 1, 0), '1 jugada, 0 ilegales (en rojo)');
    expect(s('es', 2, 1), '2 jugadas, 1 ilegal (en rojo)');
  });
}
