import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chess_pdf_enriched/l10n/app_localizations.dart';
import 'package:chess_pdf_enriched/main.dart';
import 'package:chess_pdf_enriched/ui_language.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('resolveLocale', () {
    test('a supported system language wins by language code, otherwise English', () {
      expect(resolveLocale(null, [const Locale('fr', 'CA')]), const Locale('fr'));
      expect(resolveLocale(null, [const Locale('es', 'MX')]), const Locale('es'));
      expect(resolveLocale(null, [const Locale('de')]), const Locale('en'));
      expect(resolveLocale(null, [const Locale('pt', 'BR')]), const Locale('en'));
      expect(resolveLocale(null, []), const Locale('en'));
      expect(resolveLocale(null, [const Locale('de'), const Locale('es')]), const Locale('es'));
    });
    test('the manual choice wins over the system', () {
      expect(resolveLocale(const Locale('fr'), [const Locale('es')]), const Locale('fr'));
    });
  });

  group('saved language', () {
    test('absent, unknown or wrongly typed value means Automatic', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadUiLanguage(), isNull);
      SharedPreferences.setMockInitialValues({'ui_lang': 'de'});
      expect(await loadUiLanguage(), isNull);
      SharedPreferences.setMockInitialValues({'ui_lang': 5});
      expect(await loadUiLanguage(), isNull);
      SharedPreferences.setMockInitialValues({'ui_lang': 'fr'});
      expect(await loadUiLanguage(), const Locale('fr'));
    });
    test('save then load, and null removes the choice', () async {
      SharedPreferences.setMockInitialValues({});
      await saveUiLanguage(const Locale('es'));
      expect(await loadUiLanguage(), const Locale('es'));
      await saveUiLanguage(null);
      expect(await loadUiLanguage(), isNull);
    });
  });

  testWidgets('the language menu switches the interface at once and remembers the choice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ReaderApp(initialLocale: Locale('es')));
    expect(find.text('Abrir un libro (.chessbook)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Open a book (.chessbook)'), findsOneWidget);
    expect(await loadUiLanguage(), const Locale('en'));
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    expect(await loadUiLanguage(), isNull);
  });

  testWidgets('switching language keeps the selected diagram and re-renders its texts', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000); // the reader lays out a page next to a board: the default 800x600 is too small
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final book = Book('t.chessbook', 'T', {
      1: {
        'width': 600,
        'height': 800,
        'moves': [],
        'blocks': [],
        'diagrams': [
          {'id': 'p1_d1', 'fen': '8/8/8/8/8/8/8/K6k w - - 0 1', 'bbox': [10, 10, 200, 200], 'side_known': true, 'flipped': true},
        ],
      },
    }, Archive(), {}, 200);
    await tester.pumpWidget(ReaderApp(initial: book, initialLocale: const Locale('en')));
    await tester.tap(find.byWidgetPredicate((w) => w is InkWell && w.onSecondaryTap != null));
    await tester.pump();
    expect(find.text('Diagram p1_d1 (flipped: white at the bottom)'), findsOneWidget);
    expect(find.text('White to move'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();
    expect(find.text('Diagrama p1_d1 (girado: blancas abajo)'), findsOneWidget);
    expect(find.text('Juegan las blancas'), findsOneWidget);
  });
}
