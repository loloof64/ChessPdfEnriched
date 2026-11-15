import 'dart:io' as io;

import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Dev tool, not a test of behaviour: draws pages of a generated book with real fonts into test/render/*.png.
// Usage: BOOK=pipeline/work/attaque_minorite_2.chessbook PAGES=1,2,3 flutter test test/render_page_test.dart --update-goldens
// Skipped when BOOK is not set.
void main() {
  final book = io.Platform.environment['BOOK'];
  testWidgets('render pages', (tester) async {
    for (final (family, file) in [('Roboto', 'NotoSans-Regular.ttf'), ('Roboto', 'NotoSans-Bold.ttf')]) {
      final bytes = io.File('/usr/share/fonts/truetype/noto/$file').readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    final loaded = Book.load(book!);
    await tester.pumpWidget(ReaderApp(initial: loaded));
    await tester.pumpAndSettle();
    for (final p in (io.Platform.environment['PAGES'] ?? '1').split(',')) {
      await tester.enterText(find.byType(EditableText).first, p);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // widget tests do not decode images by themselves: decode this page's files for real, then draw again
      final ctx = tester.element(find.byType(ReaderPage));
      await tester.runAsync(() async {
        final pad = int.parse(p).toString().padLeft(4, '0');
        for (final n in loaded.names.where((n) => n == 'scans/p$pad.png' || n == 'backgrounds/p$p.png' || n.startsWith('diagrams/p${p}_'))) {
          await precacheImage(MemoryImage(loaded.file(n)!), ctx);
        }
      });
      await tester.pumpAndSettle();
      await expectLater(find.byType(ReaderApp), matchesGoldenFile('render/page$p.png'));
    }
  }, skip: book == null);
}
