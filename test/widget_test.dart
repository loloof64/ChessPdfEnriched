import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a hint when no book is given', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderApp(book: null));
    expect(find.textContaining('Aucun livre'), findsOneWidget);
  });
}
