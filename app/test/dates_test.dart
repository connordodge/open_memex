import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/dates.dart';

void main() {
  group('C5 display formats (AC9)', () {
    final sat = DateTime(2026, 9, 5, 14, 32);

    test('daily header formats 2026-09-05 as Saturday, 5 September 2026', () {
      expect(formatDailyHeader(sat), 'Saturday, 5 September 2026');
      expect(
        formatDailyHeader(DateTime(2026, 9, 4)),
        'Friday, 4 September 2026',
      );
    });

    test(
      'daily header names every weekday and has no leading zero on the day',
      () {
        // 2026-09-07 is a Monday.
        const expected = [
          'Monday, 7 September 2026',
          'Tuesday, 8 September 2026',
          'Wednesday, 9 September 2026',
          'Thursday, 10 September 2026',
          'Friday, 11 September 2026',
          'Saturday, 12 September 2026',
          'Sunday, 13 September 2026',
        ];
        for (var i = 0; i < 7; i++) {
          expect(formatDailyHeader(DateTime(2026, 9, 7 + i)), expected[i]);
        }
        expect(
          formatDailyHeader(DateTime(2026, 10, 1)),
          'Thursday, 1 October 2026',
        );
        expect(
          formatDailyHeader(DateTime(2026, 12, 31, 23, 59)),
          'Thursday, 31 December 2026',
        );
      },
    );

    test('review hover reads Reviewed by agent at 5 Sep 2026, 14:32', () {
      expect(formatReviewedAt(sat), 'Reviewed by agent at 5 Sep 2026, 14:32');
      expect(
        formatReviewedAt(DateTime(2026, 1, 9, 0, 0)),
        'Reviewed by agent at 9 Jan 2026, 00:00',
      );
      expect(
        formatReviewedAt(DateTime(2026, 5, 31, 23, 59)),
        'Reviewed by agent at 31 May 2026, 23:59',
      );
    });

    test('review hover uses every three-letter month name', () {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      for (var m = 1; m <= 12; m++) {
        expect(
          formatReviewedAt(DateTime(2026, m, 15, 8, 7)),
          'Reviewed by agent at 15 ${months[m - 1]} 2026, 08:07',
        );
      }
    });

    test(
      'gutter hovers read captured via agent and added via quick entry with the time',
      () {
        expect(formatCapturedViaAgent(sat), 'captured via agent, 14:32');
        expect(formatAddedViaQuickEntry(sat), 'added via quick entry, 14:32');
      },
    );

    test(
      '2026-10-03 09:05 gives captured via agent, 09:05 (two-digit hours and minutes)',
      () {
        final t = DateTime(2026, 10, 3, 9, 5);
        expect(formatCapturedViaAgent(t), 'captured via agent, 09:05');
        expect(formatAddedViaQuickEntry(t), 'added via quick entry, 09:05');
        expect(
          formatCapturedViaAgent(DateTime(2026, 10, 3, 0, 0)),
          'captured via agent, 00:00',
        );
        expect(
          formatCapturedViaAgent(DateTime(2026, 10, 3, 10, 10)),
          'captured via agent, 10:10',
        );
        expect(
          formatCapturedViaAgent(DateTime(2026, 10, 3, 23, 59, 59)),
          'captured via agent, 23:59',
        );
      },
    );

    test('timestamps given in UTC are shown in local time', () {
      final local = DateTime(2026, 9, 5, 14, 32);
      final utc = local.toUtc();
      expect(formatCapturedViaAgent(utc), 'captured via agent, 14:32');
      expect(formatAddedViaQuickEntry(utc), 'added via quick entry, 14:32');
      expect(formatReviewedAt(utc), 'Reviewed by agent at 5 Sep 2026, 14:32');
      // Unix-ms timestamps from the vault become local DateTimes.
      final fromMs = DateTime.fromMillisecondsSinceEpoch(
        local.millisecondsSinceEpoch,
      );
      expect(formatCapturedViaAgent(fromMs), 'captured via agent, 14:32');
    });

    test('month header formats September 2026 and every month name', () {
      expect(formatMonthHeader(sat), 'September 2026');
      expect(formatMonthHeader(DateTime(2026, 10, 3)), 'October 2026');
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June', //
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      for (var m = 1; m <= 12; m++) {
        expect(
          formatMonthHeader(DateTime(2025, m, 28)),
          '${months[m - 1]} 2025',
        );
      }
    });

    test('isoDate formats 2026-09-05 with zero-padded month and day', () {
      expect(isoDate(sat), '2026-09-05');
      expect(isoDate(DateTime(2026, 1, 2, 23, 59)), '2026-01-02');
      expect(isoDate(DateTime(2026, 12, 31)), '2026-12-31');
      expect(isoDate(DateTime(2026, 10, 13)), '2026-10-13');
    });

    test(
      'parseIsoDate returns local midnight for a valid date and round-trips',
      () {
        final d = parseIsoDate('2026-09-05')!;
        expect(d, DateTime(2026, 9, 5));
        expect(d.isUtc, isFalse);
        expect(isoDate(d), '2026-09-05');
        expect(parseIsoDate('2024-02-29'), DateTime(2024, 2, 29));
        expect(parseIsoDate('2026-12-31'), DateTime(2026, 12, 31));
        expect(parseIsoDate('2026-01-01'), DateTime(2026, 1, 1));
      },
    );

    test(
      'parseIsoDate returns null for anything but a real YYYY-MM-DD date',
      () {
        for (final s in [
          '',
          'Player Loop',
          '2026-9-5',
          '2026-09-5',
          '26-09-05',
          '2026/09/05',
          '2026-09-05x',
          ' 2026-09-05',
          '2026-09-05T00:00',
          '2026-02-29',
          '2026-02-30',
          '2026-04-31',
          '2026-13-01',
          '2026-00-10',
          '2026-01-00',
          '2026-01-32',
        ]) {
          expect(parseIsoDate(s), isNull, reason: '"$s"');
        }
      },
    );
  });

  group('startOfNextLocalDay (AC10)', () {
    void expectNextMidnight(DateTime t) {
      final next = startOfNextLocalDay(t);
      final expectedDay = DateTime(t.year, t.month, t.day + 1);
      expect(next.isUtc, isFalse, reason: '$t');
      expect(next.year, expectedDay.year, reason: '$t');
      expect(next.month, expectedDay.month, reason: '$t');
      expect(next.day, expectedDay.day, reason: '$t');
      expect(next.hour, 0, reason: '$t');
      expect(next.minute, 0, reason: '$t');
      expect(next.second, 0, reason: '$t');
      expect(next.millisecond, 0, reason: '$t');
      expect(next.isAfter(t), isTrue, reason: '$t');
    }

    test(
      'startOfNextLocalDay returns local midnight of the next calendar day',
      () {
        expect(
          startOfNextLocalDay(DateTime(2026, 10, 3, 9, 5)),
          DateTime(2026, 10, 4),
        );
        expect(
          startOfNextLocalDay(DateTime(2026, 10, 3)),
          DateTime(2026, 10, 4),
        );
        expect(
          startOfNextLocalDay(DateTime(2026, 10, 3, 23, 59, 59, 999)),
          DateTime(2026, 10, 4),
        );
        expect(
          startOfNextLocalDay(DateTime(2026, 9, 30, 12)),
          DateTime(2026, 10),
        );
        expect(startOfNextLocalDay(DateTime(2026, 12, 31, 18)), DateTime(2027));
        expect(
          startOfNextLocalDay(DateTime(2028, 2, 28, 1)),
          DateTime(2028, 2, 29),
        );
      },
    );

    test('startOfNextLocalDay is local midnight across DST change dates', () {
      // US (America/*) and EU (Europe/*) 2026 transitions, both directions.
      final dstDays = [
        DateTime(2026, 3, 7),
        DateTime(2026, 3, 8),
        DateTime(2026, 3, 28),
        DateTime(2026, 3, 29),
        DateTime(2026, 10, 24),
        DateTime(2026, 10, 25),
        DateTime(2026, 10, 31),
        DateTime(2026, 11, 1),
      ];
      for (final d in dstDays) {
        for (final h in [0, 1, 2, 3, 12, 23]) {
          expectNextMidnight(DateTime(d.year, d.month, d.day, h, 30));
        }
      }
      // And every day of the year, whatever this machine's time zone.
      for (
        var day = DateTime(2026, 1, 1, 12);
        day.year == 2026;
        day = DateTime(day.year, day.month, day.day + 1, 12)
      ) {
        expectNextMidnight(day);
        expectNextMidnight(DateTime(day.year, day.month, day.day, 23, 59));
      }
    });

    test(
      'startOfNextLocalDay of a UTC instant uses the local calendar day',
      () {
        final local = DateTime(2026, 10, 3, 23, 30);
        expect(startOfNextLocalDay(local.toUtc()), DateTime(2026, 10, 4));
      },
    );
  });
}
