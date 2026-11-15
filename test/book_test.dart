import 'dart:io';

import 'package:chess_pdf_enriched/main.dart';
import 'package:flutter_test/flutter_test.dart';

// Needs the sample book built by pipeline/build_fabrice.py (not versioned); skipped when absent.
const sample = 'pipeline/work/fab/attaque_minorite.chessbook';

void main() {
  test('generated hash matches the pipeline, corrections apply, save keeps the rest of the book', () {
    final tmp = File('${Directory.systemTemp.path}/chessbook_test.chessbook');
    File(sample).copySync(tmp.path);
    final book = Book.load(tmp.path);
    final d5 = (book.pages[2]!['diagrams'] as List).cast<Map<String, dynamic>>().firstWhere((d) => d['id'] == 'p2_d5');
    // seeded by the pipeline with Python's sha256: Dart must agree, else the correction would be ignored
    expect(book.fenOf(d5), '6k1/4pppp/p2p4/1p1P4/2P5/1P6/P4PPP/6K1 w - - 0 1');
    expect(book.needsReview(d5), isFalse);

    final d1 = (book.pages[2]!['diagrams'] as List).cast<Map<String, dynamic>>().firstWhere((d) => d['id'] == 'p2_d1');
    const fixed = '8/8/8/8/8/8/8/K6k w - - 0 1';
    book.saveDiagramFen(d1['id'] as String, d1['fen'] as String, fixed);

    final again = Book.load(tmp.path);
    final e1 = (again.pages[2]!['diagrams'] as List).cast<Map<String, dynamic>>().firstWhere((d) => d['id'] == 'p2_d1');
    expect(again.fenOf(e1), fixed);
    expect(again.pages.keys, book.pages.keys);
    expect(again.images.length, book.images.length);
    expect(again.corrections.keys, containsAll(['p2_d5', 'p2_d1']));
    // a generated FEN that changes after a rebuild turns the correction into "needs review", never applied silently
    final changed = Map<String, dynamic>.of(e1)..['fen'] = '8/8/8/8/8/8/8/K6k b - - 0 1';
    expect(again.fenOf(changed), changed['fen']);
    expect(again.needsReview(changed), isTrue);
    tmp.deleteSync();
  }, skip: File(sample).existsSync() ? false : 'sample book not built');
}
