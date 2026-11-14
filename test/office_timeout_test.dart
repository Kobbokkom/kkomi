import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/localization.dart';
import 'package:kkomi/screens/document_viewer.dart';

void main() {
  const messages = [
    (
      Locale('de'),
      'Das Öffnen des Dokuments hat zu lange gedauert. Versuche, es erneut zu öffnen.',
    ),
    (
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      '打开文档超时，请重新打开。',
    ),
  ];
  for (final (locale, expected) in messages) {
    testWidgets('Office timeout is displayed in ${locale.toLanguageTag()}', (
      tester,
    ) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      late int viewId;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          viewId = (call.arguments as Map)['id'] as int;
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
          locale: locale,
          supportedLocales: supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: DocumentViewer(
            document: const Document(
              'content://test/pptx',
              'Test.pptx',
              'pptx',
            ),
            onOpened: (_) => fail('The stalled document must not open.'),
          ),
        ),
      );
      await tester.pump();
      await messenger.handlePlatformMessage(
        'kkomi/viewer/$viewId',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('error', '문서를 여는 데 시간이 너무 오래 걸렸습니다. 다시 열어 주세요.'),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text(expected), findsOneWidget);
    });
  }
}
