import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/screens/document_viewer.dart';

void main() {
  testWidgets('PDF toolbar moves pages and individual search matches', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    late MethodChannel viewer;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'];
        viewer = MethodChannel('kkomi/viewer/$id');
        return 0;
      }
      if (call.method == 'resize') {
        final size = call.arguments as Map;
        return {'width': size['width'], 'height': size['height']};
      }
      return null;
    });

    var pageCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentViewer(
          document: const Document('content://test/pdf', 'test.pdf', 'pdf'),
          onOpened: (pages) => pageCount = pages,
        ),
      ),
    );
    await tester.pump();

    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(viewer, (call) async {
      calls.add(call);
      return null;
    });

    Future<void> report(String method, Object? args) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        viewer.name,
        codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pump();
    }

    await report('ready', 4);
    expect(pageCount, 4);
    expect(find.text('1 / 4'), findsOneWidget);
    final toolbar = tester.getRect(find.byTooltip('검색'));
    expect(toolbar.center.dy, greaterThan(500));

    await tester.tap(find.byTooltip('다음 페이지'));
    expect(calls.last.method, 'page');
    expect(calls.last.arguments, 1);
    await report('page', 1);
    expect(find.text('2 / 4'), findsOneWidget);

    await tester.tap(find.byTooltip('검색'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Proof');
    await tester.pump(const Duration(milliseconds: 220));
    expect(calls.last.method, 'find');
    final query = calls.last.arguments as Map;
    await report('matches', {
      'request': query['request'],
      'count': 5,
      'current': 1,
    });
    expect(find.text('1 / 5'), findsOneWidget);

    await tester.tap(find.byTooltip('다음 검색 결과'));
    expect(calls.last.method, 'match');
    expect(calls.last.arguments, 1);
    await report('matches', {
      'request': query['request'],
      'count': 5,
      'current': 2,
    });
    expect(find.text('2 / 5'), findsOneWidget);
    expect(find.text('test.pdf'), findsOneWidget);

    await tester.tap(find.byTooltip('검색 닫기'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'find');
    expect((calls.last.arguments as Map)['query'], '');
    expect(find.text('2 / 4'), findsOneWidget);

    await tester.tap(find.byTooltip('문서 메뉴'));
    await tester.pumpAndSettle();
    expect(find.text('검색'), findsOneWidget);
    expect(find.text('PDF로 저장'), findsNothing);
    await tester.tap(find.text('페이지 이동'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.text('이동'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls.last.method, 'page');
    expect(calls.last.arguments, 3);
  });
}
