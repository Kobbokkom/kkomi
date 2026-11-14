import 'package:flutter_test/flutter_test.dart';
import 'package:kkomi/home_activity.dart';

void main() {
  test('weekly reading counts reset on local Monday', () {
    final activity = HomeActivity.decode(null);
    final sunday = DateTime(2026, 11, 15, 23, 59);
    final monday = DateTime(2026, 11, 16);

    activity.recordOpen(sunday, pages: 4);
    expect(activity.weeklyOpens(sunday), 1);
    expect(activity.weeklyPages(sunday), 4);
    expect(activity.daysUntilReset(DateTime(2026, 11, 13, 19)), 2);
    expect(activity.daysUntilReset(sunday), 0);
    expect(activity.weeklyOpens(monday), 0);
    expect(activity.weeklyPages(monday), 0);

    activity.recordOpen(monday, pages: 1);
    expect(activity.weeklyOpens(monday), 1);
    expect(activity.weeklyPages(monday), 1);
    expect(activity.streak(monday), 2);
  });

  test('consecutive calendar days persist and restart after a missed day', () {
    final activity = HomeActivity.decode(null);
    final start = DateTime(2026, 10, 31, 23);
    final next = DateTime(2026, 11, 1, 1);
    final missed = DateTime(2026, 11, 3);

    activity.recordUse(start);
    activity.recordUse(start);
    activity.recordOpen(next, pages: 0);
    final loaded = HomeActivity.decode(activity.encode());
    expect(loaded.weeklyOpens(next), 1);
    expect(loaded.streak(next), 2);
    expect(loaded.streak(missed), 0);
    loaded.recordUse(missed);
    expect(loaded.streak(missed), 1);
  });

  test('moving the clock back keeps the streak and rebases the last day', () {
    final activity = HomeActivity.decode(null)
      ..recordUse(DateTime(2026, 11, 12))
      ..recordUse(DateTime(2026, 11, 13));
    final earlier = DateTime(2026, 11, 10);

    activity.recordUse(earlier);
    final restored = HomeActivity.decode(activity.encode());
    expect(restored.streak(earlier), 2);

    final next = DateTime(2026, 11, 11);
    restored.recordUse(next);
    expect(restored.streak(next), 3);
  });

  test('unreadable persisted statistics start empty', () {
    final now = DateTime(2026, 11, 13);
    for (final saved in ['{', '{"week": "wrong"}', '[]']) {
      final activity = HomeActivity.decode(saved);
      expect(activity.weeklyOpens(now), 0);
      expect(activity.weeklyPages(now), 0);
      expect(activity.streak(now), 0);
    }
  });
}
