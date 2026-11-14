import 'dart:convert';

class HomeActivity {
  HomeActivity.decode(String? saved) {
    if (saved == null) return;
    try {
      final values = jsonDecode(saved);
      if (values is! Map<String, dynamic>) return;
      final week = values['week'];
      _week = week is int ? week : null;
      _opens = _counter(values['opens']);
      _pages = _counter(values['pages']);
      final lastUse = values['lastUse'];
      _lastUse = lastUse is int ? lastUse : null;
      _streak = _counter(values['streak']);
    } on FormatException {
      // Unreadable preferences start with empty statistics.
    }
  }

  int? _week;
  int _opens = 0;
  int _pages = 0;
  int? _lastUse;
  int _streak = 0;

  int weeklyOpens(DateTime now) => _week == _weekOf(now) ? _opens : 0;

  int weeklyPages(DateTime now) => _week == _weekOf(now) ? _pages : 0;

  int streak(DateTime now) {
    final day = _calendarDay(now.toLocal());
    return _lastUse == day || _lastUse == day - 1 ? _streak : 0;
  }

  void recordUse(DateTime now) {
    final day = _calendarDay(now.toLocal());
    final lastUse = _lastUse;
    if (lastUse == null || day > lastUse) {
      _streak = lastUse == day - 1 ? _streak + 1 : 1;
    }
    _lastUse = day;
  }

  void recordOpen(DateTime now, {required int pages}) {
    recordUse(now);
    _setWeek(now);
    _opens++;
    if (pages > 0) _pages += pages;
  }

  String encode() => jsonEncode({
    'week': _week,
    'opens': _opens,
    'pages': _pages,
    'lastUse': _lastUse,
    'streak': _streak,
  });

  void _setWeek(DateTime now) {
    final week = _weekOf(now);
    if (_week == week) return;
    _week = week;
    _opens = 0;
    _pages = 0;
  }

  static int _weekOf(DateTime now) {
    final local = now.toLocal();
    return _calendarDay(local) - (local.weekday - DateTime.monday);
  }

  // Encode local calendar dates as UTC midnights to compare days across DST.
  static int _calendarDay(DateTime local) =>
      DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  static int _counter(Object? value) => value is int && value >= 0 ? value : 0;
}
