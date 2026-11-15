import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final (name, size, left, right) in [
    ('iPhone portrait', const Size(402, 874), 0.0, 0.0),
    ('iPhone landscape', const Size(874, 402), 62.0, 62.0),
    ('iPhone Duo open', const Size(951, 669), 0.0, 84.0),
  ]) {
    testWidgets('$name keeps recent rows inside the safe area', (tester) async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform
          .instance = InMemorySharedPreferencesAsync.withData({
        'document-history': [
          jsonEncode({
            'uri':
                'kkomi-import://00000000-0000-0000-0000-000000000001/report.hwp',
            'name': 'report.hwp',
            'extension': 'hwp',
            'openedAt': DateTime.now()
                .subtract(const Duration(minutes: 5))
                .toIso8601String(),
          }),
        ],
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = FakeViewPadding(left: left, right: right);
      tester.view.viewPadding = FakeViewPadding(left: left, right: right);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MyApp(initialLanguage: 'ko'));
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text('report.hwp'));
      final elapsed = tester.getRect(find.text('5분 전'));
      final close = tester.getRect(find.byTooltip('최근 문서 목록에서 제거'));
      // The row stays clear of the system area the device reserves.
      expect(close.right, lessThanOrEqualTo(size.width - right - 32 + 1));
      expect(
        tester.getRect(find.text('HWP')).left,
        greaterThanOrEqualTo(left + 32),
      );
      // The tile applies that inset once, so the time stays beside the button.
      expect(close.left - elapsed.right, lessThan(24));
      expect(elapsed.left, greaterThan(title.right));
      expect(tester.takeException(), isNull);
    });
  }
}
