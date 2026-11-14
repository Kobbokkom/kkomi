import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/home_tips.dart';
import 'package:kkomi/home_strings.dart';
import 'package:kkomi/localization.dart';
import 'package:kkomi/main.dart';
import 'package:kkomi/screens/document_viewer_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  testWidgets('10개 언어로 좁은 화면의 홈과 설정을 표시한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final (index, language) in supportedLanguages.keys.indexed) {
      String label(String key) =>
          index == 0 ? key : homeStrings[key]![index - 1];
      await tester.pumpWidget(
        MyApp(key: ValueKey(language), initialLanguage: language),
      );
      await tester.pumpAndSettle();
      expect(find.text(label('홈')), findsOneWidget, reason: language);
      final empty = find.text(label('최근에 연 문서가 없어요'));
      await tester.scrollUntilVisible(empty, 120);
      expect(empty, findsOneWidget);
      await tester.tap(find.byTooltip(label('설정')));
      await tester.pumpAndSettle();
      expect(find.text(label('언어')), findsOneWidget);
      expect(find.text(label('시스템 뷰어 우선 사용')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: language);
    }
  });

  test('번역마다 자리표시자와 10개 언어 구성이 유지된다', () {
    final placeholder = RegExp(r'\{\w+\}');
    Set<String> placeholders(String text) =>
        placeholder.allMatches(text).map((match) => match.group(0)!).toSet();

    for (final table in [homeStrings, viewerStrings]) {
      for (final entry in table.entries) {
        expect(entry.value.length, supportedLanguages.length - 1);
        for (final text in entry.value) {
          expect(text.trim(), isNotEmpty, reason: entry.key);
          expect(
            placeholders(text),
            placeholders(entry.key),
            reason: entry.key,
          );
        }
      }
    }
  });

  testWidgets('언어 선택이 설정과 홈에 반영되고 저장된다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(await SharedPreferencesAsync().getString('app-language'), 'en');
  });

  testWidgets('꼬미 홈에서 파일 열기와 최근 문서를 찾을 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();

    expect(find.text('홈'), findsOneWidget);
    expect(find.text('주간 열람'), findsOneWidget);
    expect(find.text('연속 사용'), findsOneWidget);
    expect(find.text('이번 주 페이지'), findsOneWidget);
    expect(find.text('1일'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && homeTips.contains(widget.data),
      ),
      findsOneWidget,
    );
    expect(find.text('파일 열기'), findsOneWidget);
    expect(find.text('최근 문서 (최대 10개)'), findsOneWidget);
    expect(find.text('파일을 열면 여기에 표시돼요'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('시스템 뷰어 우선 사용'), findsOneWidget);
  });

  testWidgets('홈의 열람 요약과 최근 문서 시간 형식을 복원한다', (tester) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final localDay =
        DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    final saved = SharedPreferencesAsync();
    await saved.setString(
      'home-reading-activity',
      jsonEncode({
        'week': localDay - (now.weekday - DateTime.monday),
        'opens': 50,
        'pages': 1005,
        'lastUse': localDay,
        'streak': 1001,
      }),
    );
    await saved.setStringList('document-history', [
      jsonEncode({
        'uri': 'content://preview/test',
        'name': 'fixture.hwp',
        'extension': 'hwp',
        'openedAt': now.subtract(const Duration(days: 180)).toIso8601String(),
      }),
    ]);

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pump();
    expect(find.text('50 / ∞'), findsNothing);
    await tester.pumpAndSettle();

    expect(find.text('50 / ∞'), findsOneWidget);
    expect(find.text('999+일'), findsOneWidget);
    expect(find.text('999+p'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    expect(find.text('6달 전'), findsOneWidget);
  });

  testWidgets('이전 최근 문서 복원에 실패해도 통계와 설정을 복원하고 재시도한다', (tester) async {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
    final openedAt = now.toIso8601String();
    SharedPreferences.setMockInitialValues({
      'week_start_date_v1': monday.toIso8601String(),
      'current_usage_v1': 3,
      'prefer_native_viewer': false,
      'recent_documents_v1': jsonEncode([
        {
          'path': '/old.hwp',
          'name': 'old.hwp',
          'type': 'HWP',
          'openedAt': openedAt,
        },
      ]),
    });
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final saved = SharedPreferencesAsync();
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(documentsChannel, null),
    );
    messenger.setMockMethodCallHandler(documentsChannel, (_) async {
      throw PlatformException(code: 'restore-failed');
    });

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    expect(find.text('3 / ∞'), findsOneWidget);
    expect(await saved.getBool('prefer-system-viewer'), isFalse);
    expect(await saved.getStringList('document-history'), isNull);

    // Simulate an entry saved while the previous Android session was active.
    await saved.setBool('legacy-document-history-pending', true);
    await saved.setStringList('document-history', [
      jsonEncode({
        'uri': 'content://new',
        'name': 'new.hwp',
        'extension': 'hwp',
      }),
    ]);
    messenger.setMockMethodCallHandler(documentsChannel, (call) async {
      expect(call.method, 'restoreLegacyDocuments');
      return [
        {
          'uri': 'content://old',
          'name': 'old.hwp',
          'extension': 'hwp',
          'openedAt': openedAt,
        },
      ];
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    expect(find.text('3 / ∞'), findsOneWidget);
    expect(find.text('new.hwp'), findsOneWidget);
    expect(find.text('old.hwp'), findsOneWidget);
    expect(await saved.getBool('legacy-document-history-pending'), isNull);
  });

  testWidgets('이전 설정을 읽지 못하면 빈 통계를 저장하지 않는다', (tester) async {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _UnavailableLegacyPreferences();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final saved = SharedPreferencesAsync();

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    expect(await saved.getString('home-reading-activity'), isNull);

    SharedPreferences.setMockInitialValues({
      'week_start_date_v1': monday.toIso8601String(),
      'current_usage_v1': 4,
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    expect(find.text('4 / ∞'), findsOneWidget);
    expect(await saved.getString('home-reading-activity'), isNotNull);
  });

  testWidgets('최근 문서 다시 열기는 저장된 시간과 순서를 유지한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final saved = SharedPreferencesAsync();
    final entries = [
      jsonEncode({
        'uri': 'content://new',
        'name': 'new.pdf',
        'extension': 'pdf',
        'openedAt': '2026-11-12T18:07:06.010',
      }),
      jsonEncode({
        'uri': 'content://old',
        'name': 'old.pdf',
        'extension': 'pdf',
        'openedAt': '2026-11-11T18:07:06.010',
      }),
    ];
    await saved.setStringList('document-history', entries);
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(documentsChannel, null),
    );
    var opened = false;
    messenger.setMockMethodCallHandler(documentsChannel, (call) async {
      expect(call.method, 'openExternal');
      expect((call.arguments as Map)['uri'], 'content://old');
      opened = true;
      return null;
    });

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('old.pdf'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(find.text('1 / ∞'), findsOneWidget);
    expect(find.text('0p'), findsOneWidget);
    expect(await saved.getStringList('document-history'), entries);
  });

  testWidgets('최근 문서 목록에서 제거를 저장한 뒤에만 파일 접근을 해제한다', (tester) async {
    final entry = jsonEncode({
      'uri': 'content://test/recent',
      'name': 'recent.hwp',
      'extension': 'hwp',
    });
    SharedPreferences.setMockInitialValues({});
    final store = _HistoryPreferences({
      'document-history': <String>[entry],
    });
    SharedPreferencesAsyncPlatform.instance = store;
    final saved = SharedPreferencesAsync();
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(documentsChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(documentsChannel, null),
    );

    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('최근 문서 목록에서 제거'));
    await tester.pumpAndSettle();
    expect(await saved.getStringList('document-history'), [entry]);
    expect(calls, isNot(contains('forget')));

    store.fail = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('최근 문서 목록에서 제거'));
    await tester.pumpAndSettle();
    expect(await saved.getStringList('document-history'), isEmpty);
    expect(calls, ['forget']);
  });
}

final class _HistoryPreferences extends InMemorySharedPreferencesAsync {
  _HistoryPreferences(super.data) : super.withData();

  bool fail = true;

  @override
  Future<bool> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    if (fail) throw PlatformException(code: 'history-write-failed');
    return super.setStringList(key, value, options);
  }
}

class _UnavailableLegacyPreferences extends InMemorySharedPreferencesStore {
  _UnavailableLegacyPreferences() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async {
    throw PlatformException(code: 'legacy-preferences-unavailable');
  }
}
