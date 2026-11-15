import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offers to open a book when none is given', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderApp());
    expect(find.textContaining('Ouvrir un livre'), findsOneWidget);
  });
}
