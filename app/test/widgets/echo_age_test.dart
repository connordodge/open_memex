// #427 (391-A3): the echo row's age wording (Spec #391 req 26, lead ruling
// "Age copy").
//
// - A daily echo: its `day` against today's local date from `clockProvider`,
//   in calendar days: `today`, `yesterday`, `N days ago` (2-13),
//   `N weeks ago` (14-59, d ~/ 7), `N months ago` (60-364, d ~/ 30),
//   `N years ago` (d ~/ 365). The time of day and DST changes never move it.
// - Any other echo: `note_updated_at` on `formatUpdatedAgo`'s scale (just
//   now / minutes / hours / days) up to 13 days, then the same week, month
//   and year buckets.
// - `formatUpdatedAgo` itself (the meta rail) is unchanged.
//
// Pure functions in widgets/editor/note_header.dart; no widgets pumped.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';

/// The local date [days] calendar days before [from]'s date, as `YYYY-MM-DD`
/// (computed on UTC dates, so DST never shifts it).
String _isoDaysBefore(DateTime from, int days) {
  final d = DateTime.utc(from.year, from.month, from.day - days);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

void main() {
  // Built from run-time values, never const (a const DateTime is still
  // constructed, but this keeps the fixture shared and explicit).
  final now = DateTime(2026, 10, 3, 9);
  final nowMs = now.millisecondsSinceEpoch;
  int msAgo(Duration d) => nowMs - d.inMilliseconds;

  group('formatDayAgo', () {
    test('formatDayAgo names today and yesterday', () {
      expect(formatDayAgo('2026-10-03', now: now), 'today');
      expect(formatDayAgo('2026-10-02', now: now), 'yesterday');
    });

    test('formatDayAgo counts 2 to 13 days in days', () {
      expect(formatDayAgo('2026-10-01', now: now), '2 days ago');
      expect(formatDayAgo('2026-09-28', now: now), '5 days ago');
      expect(formatDayAgo(_isoDaysBefore(now, 13), now: now), '13 days ago');
    });

    test('formatDayAgo counts 14 to 59 days in whole weeks', () {
      expect(formatDayAgo(_isoDaysBefore(now, 14), now: now), '2 weeks ago');
      expect(formatDayAgo(_isoDaysBefore(now, 20), now: now), '2 weeks ago');
      expect(formatDayAgo('2026-09-12', now: now), '3 weeks ago');
      expect(formatDayAgo(_isoDaysBefore(now, 59), now: now), '8 weeks ago');
    });

    test('formatDayAgo counts 60 to 364 days in 30 day months', () {
      expect(formatDayAgo(_isoDaysBefore(now, 60), now: now), '2 months ago');
      expect(formatDayAgo(_isoDaysBefore(now, 120), now: now), '4 months ago');
      expect(formatDayAgo(_isoDaysBefore(now, 149), now: now), '4 months ago');
      expect(formatDayAgo(_isoDaysBefore(now, 364), now: now), '12 months ago');
    });

    test('formatDayAgo counts 365 days and more in years with a singular', () {
      expect(formatDayAgo(_isoDaysBefore(now, 365), now: now), '1 year ago');
      expect(formatDayAgo(_isoDaysBefore(now, 729), now: now), '1 year ago');
      expect(formatDayAgo(_isoDaysBefore(now, 730), now: now), '2 years ago');
    });

    test('formatDayAgo ignores the time of day', () {
      final justAfterMidnight = DateTime(2026, 10, 3, 0, 1);
      final justBeforeMidnight = DateTime(2026, 10, 3, 23, 59);
      expect(formatDayAgo('2026-10-02', now: justAfterMidnight), 'yesterday');
      expect(formatDayAgo('2026-10-02', now: justBeforeMidnight), 'yesterday');
      expect(formatDayAgo('2026-10-03', now: justAfterMidnight), 'today');
      expect(formatDayAgo('2026-10-03', now: justBeforeMidnight), 'today');
      expect(formatDayAgo('2026-09-28', now: justBeforeMidnight), '5 days ago');
    });

    test('formatDayAgo counts calendar days across DST changes', () {
      // US: spring forward 2026-03-08, fall back 2026-11-01. EU: 2026-03-29
      // and 2026-10-25. In a zone with DST, a duration-based count is an hour
      // short (or long) across these and lands on the wrong day.
      expect(
        formatDayAgo('2026-03-07', now: DateTime(2026, 3, 9, 0, 30)),
        '2 days ago',
      );
      expect(
        formatDayAgo('2026-10-31', now: DateTime(2026, 11, 2, 23, 30)),
        '2 days ago',
      );
      expect(
        formatDayAgo('2026-03-28', now: DateTime(2026, 3, 30, 0, 30)),
        '2 days ago',
      );
      expect(
        formatDayAgo('2026-10-24', now: DateTime(2026, 10, 26, 23, 30)),
        '2 days ago',
      );
      expect(
        formatDayAgo('2026-03-08', now: DateTime(2026, 3, 9, 0, 30)),
        'yesterday',
      );
    });

    test('formatDayAgo shows a day after today as today', () {
      // A clock set back (NTP, a manual change) never shows a negative age.
      expect(formatDayAgo('2026-10-04', now: now), 'today');
      expect(formatDayAgo('2027-01-01', now: now), 'today');
    });

    test('formatDayAgo counts across a year end and a leap day', () {
      expect(
        formatDayAgo('2027-12-31', now: DateTime(2028, 1, 1, 8)),
        'yesterday',
      );
      // 2028-02-29 exists: 2028-02-28 to 2028-03-01 is 2 days.
      expect(
        formatDayAgo('2028-02-28', now: DateTime(2028, 3, 1, 8)),
        '2 days ago',
      );
    });
  });

  group('formatRelativeAgo', () {
    test('formatRelativeAgo keeps the meta rail scale under 14 days', () {
      expect(
        formatRelativeAgo(msAgo(const Duration(seconds: 30)), now: now),
        'just now',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(minutes: 1)), now: now),
        '1 minute ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(minutes: 59)), now: now),
        '59 minutes ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(hours: 23)), now: now),
        '23 hours ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 1)), now: now),
        '1 day ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 13, hours: 23)), now: now),
        '13 days ago',
      );
    });

    test('formatRelativeAgo counts 14 to 59 days in whole weeks', () {
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 14)), now: now),
        '2 weeks ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 21)), now: now),
        '3 weeks ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 59, hours: 23)), now: now),
        '8 weeks ago',
      );
    });

    test('formatRelativeAgo counts 60 to 364 days in 30 day months', () {
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 60)), now: now),
        '2 months ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 120)), now: now),
        '4 months ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 364)), now: now),
        '12 months ago',
      );
    });

    test('formatRelativeAgo counts 365 days and more in years', () {
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 365)), now: now),
        '1 year ago',
      );
      expect(
        formatRelativeAgo(msAgo(const Duration(days: 730)), now: now),
        '2 years ago',
      );
    });

    test('formatRelativeAgo shows a time after now as just now', () {
      // Backward clock jump: an updated_at ahead of the clock.
      expect(
        formatRelativeAgo(
          nowMs + const Duration(hours: 5).inMilliseconds,
          now: now,
        ),
        'just now',
      );
    });
  });

  test(
    'formatUpdatedAgo still counts days past two weeks for the meta rail',
    () {
      // Regression guard: the sibling formatter leaves the meta rail as it is.
      expect(
        formatUpdatedAgo(msAgo(const Duration(days: 30)), now: now),
        '30 days ago',
      );
      expect(
        formatUpdatedAgo(msAgo(const Duration(days: 400)), now: now),
        '400 days ago',
      );
    },
  );
}
