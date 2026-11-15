import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/localization.dart';
import 'package:kkomi/screens/document_viewer_strings.dart';

// Dart or the renderer replaces these with its own translated message.
const _internalMessages = {
  '변환에 필요한 문서 정보가 없습니다.',
  '문서를 PDF로 변환할 수 없습니다.',
  '기존 문서 기록을 읽을 수 없습니다.',
  '이 형식을 열 수 있는 다른 앱이 설치되어 있지 않습니다.',
  'iOS 미리보기를 사용할 수 없습니다.',
  '이미지를 열 수 없습니다.',
};

void main() {
  testWidgets('every Korean native and renderer message is translated', (
    tester,
  ) async {
    final sources = [
      ...Directory(
        'android/app/src/main/kotlin',
      ).listSync(recursive: true).whereType<File>(),
      ...Directory(
        'ios/Runner',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.swift')),
      File('assets/js/viewer.js'),
    ];
    final sentence = RegExp(r'''["']([^"'\n]*[가-힣][^"'\n]*\.)["']''');
    final messages = {
      for (final file in sources)
        for (final match in sentence.allMatches(file.readAsStringSync()))
          match.group(1)!,
    };
    expect(messages, isNotEmpty);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    final untranslated = messages.where(
      (message) =>
          !_internalMessages.contains(message) &&
          !viewerStrings.containsKey(message) &&
          nativeMessage(context, message, '').isEmpty,
    );
    expect(untranslated, isEmpty);
  });
}
