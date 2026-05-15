import 'package:flutter_test/flutter_test.dart';
import 'package:chess_pdf_enriched/main.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ChessPdfApp());
    expect(find.text('Chess PDF Enriched'), findsOneWidget);
    expect(find.text('Open PDF'), findsOneWidget);
  });
}
