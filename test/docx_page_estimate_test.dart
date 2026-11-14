import 'dart:io';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/docx_page_estimate.dart';

const _fixtures = 'test/fixtures/android';

DocxParagraph _paragraph(String text) =>
    DocxParagraph(children: [DocxText(text)]);

DocxBuiltDocument _document(List<DocxNode> elements) =>
    DocxBuiltDocument(elements: elements);

void main() {
  test(
    'estimates DOCX fixtures independently of the visible page count',
    () async {
      expect(
        await estimateDocxPages(
          await File('$_fixtures/word.docx').readAsBytes(),
        ),
        1,
      );
      expect(
        await estimateDocxPages(
          await File('$_fixtures/complex.docx').readAsBytes(),
        ),
        2,
      );
    },
  );

  test(
    'estimates a long continuous DOCX using the original batch limits',
    () async {
      final document = _document(
        List.generate(
          120,
          (index) => _paragraph('Long fixture row ${index + 1}'),
        ),
      );
      final bytes = await DocxExporter().exportToBytes(document);
      expect(await estimateDocxPages(bytes), 15);
    },
  );

  test('keeps the first oversized batch and measures text in UTF-16 units', () {
    final short = _paragraph('Short line.');
    expect(estimateDocxDocumentPages(_document([])), 1);
    expect(estimateDocxDocumentPages(_document(List.filled(8, short))), 1);
    expect(estimateDocxDocumentPages(_document(List.filled(9, short))), 2);

    int pagesAtSection(String text) => estimateDocxDocumentPages(
      _document([
        ...List.filled(6, short),
        _paragraph(text),
        const DocxTable(rows: []),
        const DocxSectionBreakBlock(DocxSectionDef()),
      ]),
    );
    expect(pagesAtSection('A' * 33), 1);
    expect(pagesAtSection('A' * 34), 2);
    expect(pagesAtSection('🙂' * 17), 2);
  });

  test('keeps a floating table in the same batch as following text', () {
    final table = DocxTable.fromData(List.generate(11, (index) => ['$index']));
    final floatingTable = DocxTable(
      rows: table.rows,
      position: const DocxTablePosition(),
    );
    final short = _paragraph('Short line.');
    expect(estimateDocxDocumentPages(_document([table, short])), 2);
    expect(estimateDocxDocumentPages(_document([floatingTable, short])), 1);
  });

  test(
    'returns null for malformed, oversized and encrypted documents',
    () async {
      expect(
        await estimateDocxPages(Uint8List.fromList([0x50, 0x4b, 3, 4])),
        isNull,
      );
      final oversized = Uint8List(8 * 1024 * 1024 + 1)
        ..setAll(0, [0x50, 0x4b, 3, 4]);
      expect(await estimateDocxPages(oversized), isNull);
      expect(
        await estimateDocxPages(
          await File('$_fixtures/locked-office.docx').readAsBytes(),
        ),
        isNull,
      );
    },
  );
}
