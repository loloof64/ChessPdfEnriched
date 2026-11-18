import 'package:archive/archive.dart';
import 'package:chessground/chessground.dart';

import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

  testWidgets('the board of a chosen diagram shows its coordinates (a-h, 1-8)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final book = Book('t.chessbook', 'T', {
      1: {
        'width': 600,
        'height': 800,
        'moves': [],
        'blocks': [],
        'diagrams': [
          {'id': 'p1_d1', 'fen': '8/8/8/8/8/8/8/K6k w - - 0 1', 'bbox': [10, 10, 200, 200]},
        ],
      },
    }, Archive(), {}, 200);
    await tester.pumpWidget(ReaderApp(initial: book));
    await tester.tap(find.byWidgetPredicate((w) => w is InkWell && w.onSecondaryTap != null));
    await tester.pump();
    expect(tester.widget<StaticChessboard>(find.byType(StaticChessboard)).settings.enableCoordinates, isTrue);
  });
}
