import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'documents.dart';

class LegacyPreferences {
  const LegacyPreferences._(
    this.history,
    this.preferSystem,
    this.activity, {
    this.historyRestoreFailed = false,
  });

  final List<Document>? history;
  final bool? preferSystem;
  final String? activity;
  final bool historyRestoreFailed;

  static Future<LegacyPreferences> read({
    required DateTime now,
    bool restoreHistory = true,
    bool restoreSystem = true,
    bool restoreActivity = true,
  }) async {
    if (!restoreHistory && !restoreSystem && !restoreActivity) {
      return const LegacyPreferences._(null, null, null);
    }
    final saved = await SharedPreferences.getInstance();
    List<Document>? history;
    var historyRestoreFailed = false;
    if (restoreHistory) {
      try {
        history = await _restoreHistory(saved.get('recent_documents_v1'));
      } on PlatformException {
        historyRestoreFailed = true;
      }
    }
    final preferSystem = restoreSystem
        ? saved.get('prefer_native_viewer')
        : null;
    final activity = restoreActivity ? _restoreActivity(saved, now) : null;
    return LegacyPreferences._(
      history,
      preferSystem is bool ? preferSystem : null,
      activity,
      historyRestoreFailed: historyRestoreFailed,
    );
  }

  static Future<List<Document>?> _restoreHistory(Object? saved) async {
    if (saved == null) return null;
    if (saved is! String) return [];
    final Object? decoded;
    try {
      decoded = jsonDecode(saved);
    } on FormatException {
      return [];
    }
    if (decoded is! List) return [];

    final entries = <Map<String, String>>[];
    for (final entry in decoded) {
      if (entry
          case {
            'path': final String path,
            'name': final String name,
            'type': final String type,
            'openedAt': final String openedAt,
          }
          when path.isNotEmpty &&
              name.isNotEmpty &&
              type.isNotEmpty &&
              DateTime.tryParse(openedAt) != null) {
        entries.add({
          'path': path,
          'name': name,
          'extension': type.toLowerCase(),
          'openedAt': openedAt,
        });
      }
    }
    if (entries.isEmpty) return [];

    final restored = await documentsChannel.invokeListMethod<Object?>(
      'restoreLegacyDocuments',
      entries,
    );
    return (restored ?? [])
        .whereType<Map<Object?, Object?>>()
        .map(Document.fromMap)
        .toList();
  }

  static String? _restoreActivity(SharedPreferences saved, DateTime now) {
    final day = _day(now.toLocal());
    final week = day - (now.toLocal().weekday - DateTime.monday);
    final opensWeek = _savedDay(saved.get('week_start_date_v1'));
    final pagesWeek = _savedDay(saved.get('pages_week_start_date_v1'));
    final lastUse = _savedDay(saved.get('last_used_date_v1'));
    if (opensWeek == null && pagesWeek == null && lastUse == null) return null;

    return jsonEncode({
      'week': week,
      'opens': opensWeek == week ? _count(saved.get('current_usage_v1')) : 0,
      'pages': pagesWeek == week ? _count(saved.get('current_pages_v1')) : 0,
      'lastUse': lastUse,
      'streak': lastUse == null ? 0 : _count(saved.get('current_streak_v1')),
    });
  }

  static int? _savedDay(Object? value) {
    final date = value is String ? DateTime.tryParse(value) : null;
    return date == null ? null : _day(date.toLocal());
  }

  static int _day(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  static int _count(Object? value) => value is int && value >= 0 ? value : 0;
}
