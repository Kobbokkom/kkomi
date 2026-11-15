import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/localization.dart';
import 'package:kkomi/screens/document_viewer.dart';

void main() {
  testWidgets('Viewer controls fit a compact view with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    late MethodChannel viewer;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'];
        viewer = MethodChannel('kkomi/viewer/$id');
        messenger.setMockMethodCallHandler(viewer, (call) async {
          calls.add(call);
          return null;
        });
        return 0;
      }
      if (call.method == 'resize') {
        final size = call.arguments as Map;
        return {'width': size['width'], 'height': size['height']};
      }
      return null;
    });
    Future<void> report(String method, Object? args) async {
      await messenger.handlePlatformMessage(
        viewer.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        supportedLocales: supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: DocumentViewer(
          document: const Document('content://test/pdf', 'test.pdf', 'pdf'),
          onOpened: (_) {},
        ),
      ),
    );
    await tester.pump();
    await report('ready', 4);

    await report('password', true);
    tester.view.viewInsets = const FakeViewPadding(bottom: 262);
    await tester.pumpAndSettle();
    final error = find.text('Das Passwort ist falsch.');
    await tester.ensureVisible(error);
    await tester.pumpAndSettle();
    expect(error.hitTestable(), findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(error).didExceedMaxLines,
      isFalse,
    );

    final field = find.byType(EditableText);
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(field.hitTestable(), findsOneWidget);
    await tester.enterText(field, 'second attempt');
    final open = find.text('Öffnen');
    expect(open.hitTestable(), findsOneWidget);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'password');
    expect(calls.last.arguments, 'second attempt');

    await tester.tap(find.text('1 / 4'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(field.hitTestable(), findsOneWidget);
    await tester.enterText(field, '5');
    final go = find.text('Los');
    expect(go.hitTestable(), findsOneWidget);
    await tester.tap(go);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(field, '4');
    await tester.tap(go);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls.last.method, 'page');
    expect(calls.last.arguments, 3);

    await tester.tap(find.byTooltip('Suchen'));
    await tester.pumpAndSettle();
    await tester.enterText(field, 'needle');
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls.last.method, 'find');
    final request = (calls.last.arguments as Map)['request'];
    await report('matches', {
      'request': request,
      'count': 20000,
      'current': 20000,
    });
    expect(tester.getSize(field).width, greaterThanOrEqualTo(112));
    expect(find.text('20000 / 20000'), findsOneWidget);
    expect(find.byTooltip('Nächster Treffer').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Suche schließen').hitTestable(), findsOneWidget);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DOCX menu search focuses the bottom search field', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    late MethodChannel viewer;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        viewer = MethodChannel('kkomi/viewer/${(call.arguments as Map)['id']}');
        messenger.setMockMethodCallHandler(viewer, (_) async => null);
        return 0;
      }
      if (call.method == 'resize') {
        final size = call.arguments as Map;
        return {'width': size['width'], 'height': size['height']};
      }
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: DocumentViewer(
          document: const Document('content://test/dotx', 'a.dotx', 'dotx'),
          onOpened: (_) {},
        ),
      ),
    );
    await tester.pump();
    await messenger.handlePlatformMessage(
      viewer.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('ready', 1)),
      (_) {},
    );
    await tester.pumpAndSettle();

    final field = find.byType(EditableText);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);
    await tester.tap(find.byTooltip('Document menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
  });
}
