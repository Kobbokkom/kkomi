import 'dart:isolate';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';

const _maxDocxBytes = 8 * 1024 * 1024;
const _estimateTimeout = Duration(seconds: 5);

/// Estimates activity pages from the DOCX bytes validated by the Android bridge.
/// Returns null when the archive cannot be parsed within the estimate budget.
Future<int?> estimateDocxPages(Uint8List bytes) async {
  if (bytes.length < 4 ||
      bytes.length > _maxDocxBytes ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      bytes[2] != 3 ||
      bytes[3] != 4) {
    return null;
  }

  final replies = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(_estimateInWorker, (
      TransferableTypedData.fromList([bytes]),
      replies.sendPort,
    ), onError: replies.sendPort);
    final result = await replies.first.timeout(_estimateTimeout);
    return result is int ? result : null;
  } catch (_) {
    return null;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

Future<void> _estimateInWorker(
  (TransferableTypedData, SendPort) request,
) async {
  final (data, reply) = request;
  final document = await DocxReader.loadFromBytes(
    data.materialize().asUint8List(),
  );
  Isolate.exit(reply, estimateDocxDocumentPages(document));
}

/// Reproduces the original DOCX activity estimate at its fixed 360px width.
/// The estimate is independent of continuous viewer layout and PDF pagination.
int estimateDocxDocumentPages(DocxBuiltDocument document) {
  const pageWidth = 360.0;
  const pagePadding = 96.0;
  const headerFooterAllowance = 100.0;
  const availableHeight =
      pageWidth * 1.414 - pagePadding - headerFooterAllowance;
  final charactersPerLine = ((pageWidth - pagePadding) / 8).floor();
  var pages = 1;
  var pageHeight = 0;
  var batchHeight = 0;

  void flushBatch() {
    if (batchHeight == 0) return;
    if (pageHeight + batchHeight > availableHeight && pageHeight > 0) {
      pages++;
      pageHeight = 0;
    }
    pageHeight += batchHeight;
    batchHeight = 0;
  }

  for (final element in document.elements) {
    switch (element) {
      case DocxSectionBreakBlock():
        flushBatch();
        if (pageHeight > availableHeight) {
          pages++;
          pageHeight = 0;
        }
        continue;
      case DocxParagraph():
        final length = element.children.whereType<DocxText>().fold(
          0,
          (length, run) => length + run.content.length,
        );
        final lines = (length / charactersPerLine).ceil().clamp(1, 100);
        batchHeight += 24 * lines + 16;
      case DocxTable():
        batchHeight += 30 * element.rows.length + 16;
        if (element.position != null) continue;
      case DocxList():
        batchHeight += 30 * element.items.length + 10;
      case DocxDropCap():
        batchHeight += 80;
      default:
        batchHeight += 40;
    }
    if (batchHeight > availableHeight) flushBatch();
  }
  flushBatch();
  return pages;
}
