import 'dart:ui';

import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offers to open a book when none is given (English by default)', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderApp());
    expect(find.textContaining('Open a book'), findsOneWidget);
  });

  testWidgets('follows the system language when it is supported', (WidgetTester tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('fr', 'CA')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const ReaderApp());
    await tester.pump();
    expect(find.textContaining('Ouvrir un livre'), findsOneWidget);
  });
}
