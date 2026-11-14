import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/documents.dart';
import 'package:kkomi/home_activity.dart';
import 'package:kkomi/legacy_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 13, 19);

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      documentsChannel,
      null,
    );
  });

  test(
    'restores dates, the weekly counts and the native viewer preference',
    () async {
      SharedPreferences.setMockInitialValues({
        'week_start_date_v1': '2026-11-09T00:00:00.000',
        'current_usage_v1': 3,
        'weekly_limit_v1': 200,
        'pages_week_start_date_v1': '2026-11-09T00:00:00.000',
        'current_pages_v1': 22,
        'last_used_date_v1': '2026-11-12',
        'current_streak_v1': 4,
        'prefer_native_viewer': false,
      });

      final legacy = await LegacyPreferences.read(now: now);
      expect(legacy.history, isNull);
      expect(legacy.preferSystem, isFalse);
      final activity = HomeActivity.decode(legacy.activity);
      expect(activity.weeklyOpens(now), 3);
      expect(activity.weeklyPages(now), 22);
      activity.recordUse(now);
      expect(activity.streak(now), 5);
    },
  );

  test(
    'ignores stale weeks independently and skips data already migrated',
    () async {
      SharedPreferences.setMockInitialValues({
        'week_start_date_v1': '2026-11-02T00:00:00.000',
        'current_usage_v1': 3,
        'pages_week_start_date_v1': '2026-11-09T00:00:00.000',
        'current_pages_v1': 22,
        'last_used_date_v1': 'not a date',
        'current_streak_v1': 4,
        'recent_documents_v1': '[]',
        'prefer_native_viewer': true,
      });

      final legacy = await LegacyPreferences.read(
        now: now,
        restoreHistory: false,
        restoreSystem: false,
      );
      expect(legacy.history, isNull);
      expect(legacy.preferSystem, isNull);
      final activity = HomeActivity.decode(legacy.activity);
      expect(activity.weeklyOpens(now), 0);
      expect(activity.weeklyPages(now), 22);
      expect(activity.streak(now), 0);
    },
  );

  test(
    'passes the original saved file path to the Android URI resolver',
    () async {
      const path =
          '/data/user/0/com.kobbokkom.kkomi/files/file_cache/문서 안내.hwp';
      const name = '문서 안내.hwp';
      const openedAt = '2026-11-12T18:07:06.010';
      const uri =
          'content://com.kobbokkom.kkomi.documents/legacy_documents/sample.hwp';
      SharedPreferences.setMockInitialValues({
        'recent_documents_v1': jsonEncode([
          {'path': path, 'name': name, 'type': 'HWP', 'openedAt': openedAt},
          {'path': '/missing.hwp', 'openedAt': 'bad timestamp'},
        ]),
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        documentsChannel,
        (call) async {
          expect(call.method, 'restoreLegacyDocuments');
          expect(call.arguments, [
            {
              'path': path,
              'name': name,
              'extension': 'hwp',
              'openedAt': openedAt,
            },
          ]);
          return [
            {
              'uri': uri,
              'name': name,
              'extension': 'hwp',
              'openedAt': openedAt,
            },
          ];
        },
      );

      final legacy = await LegacyPreferences.read(now: now);
      expect(legacy.history?.single.toMap(), {
        'uri': uri,
        'name': name,
        'extension': 'hwp',
        'openedAt': openedAt,
      });
      expect(legacy.activity, isNull);
    },
  );
}
