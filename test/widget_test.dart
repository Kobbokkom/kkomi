import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/home_tips.dart';
import 'package:kkomi/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  testWidgets('꼬미 홈에서 파일 열기와 최근 문서를 찾을 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(const MyApp());
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
    expect(find.text('파일 열기로 문서를 추가해보세요'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('시스템 뷰어 선호'), findsOneWidget);
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

    await tester.pumpWidget(const MyApp());
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

    await tester.pumpWidget(const MyApp());
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
    await tester.pumpWidget(const MyApp());
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

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(await saved.getString('home-reading-activity'), isNull);

    SharedPreferences.setMockInitialValues({
      'week_start_date_v1': monday.toIso8601String(),
      'current_usage_v1': 4,
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MyApp());
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

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('old.pdf'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(find.text('1 / ∞'), findsOneWidget);
    expect(find.text('0p'), findsOneWidget);
    expect(await saved.getStringList('document-history'), entries);
  });
}

class _UnavailableLegacyPreferences extends InMemorySharedPreferencesStore {
  _UnavailableLegacyPreferences() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async {
    throw PlatformException(code: 'legacy-preferences-unavailable');
  }
}
