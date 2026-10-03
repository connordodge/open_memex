// WI #23 (A6): the Days grouping builder (Spec TS3), a pure function.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/days_list.dart';

DailyNoteRow _row(
  String date, {
  String? id,
  String preview = '',
  ReviewState state = ReviewState.unreviewed,
}) => DailyNoteRow(
  date: date,
  noteId: id ?? 'daily-$date',
  preview: preview,
  reviewState: state,
);

List<String> _months(DaysList l) => [for (final g in l.groups) g.month];

List<String> _headers(DaysList l) => [for (final g in l.groups) g.header];

List<List<String>> _dates(DaysList l) => [
  for (final g in l.groups) [for (final r in g.rows) r.date],
];

void main() {
  group('month groups (AC3)', () {
    test(
      'groups daily notes by month newest first with headers like October 2026',
      () {
        // Deliberately not in date order: the builder sorts.
        final list = buildDaysList([
          _row('2026-09-05'),
          _row('2026-10-02'),
          _row('2026-08-15'),
          _row('2026-10-01'),
          _row('2026-09-30'),
        ], today: '2026-10-03');

        expect(_months(list), ['2026-10', '2026-09', '2026-08']);
        expect(_headers(list), [
          'October 2026',
          'September 2026',
          'August 2026',
        ]);
        expect(_dates(list), [
          ['2026-10-02', '2026-10-01'],
          ['2026-09-30', '2026-09-05'],
          ['2026-08-15'],
        ]);
      },
    );

    test('rows inside one month are newest first', () {
      final list = buildDaysList([
        _row('2026-07-01'),
        _row('2026-07-15'),
        _row('2026-07-09'),
        _row('2026-07-10'),
      ], today: '2026-10-03');

      expect(_months(list), ['2026-07']);
      expect(_dates(list), [
        ['2026-07-15', '2026-07-10', '2026-07-09', '2026-07-01'],
      ]);
    });

    test('dates without a daily note produce no rows and no month header', () {
      final list = buildDaysList([
        _row('2026-09-28'),
        _row('2026-09-25'),
        _row('2026-07-04'),
      ], today: '2026-10-03');

      // No October rows (only the Today row lives there), no August.
      expect(_months(list), ['2026-09', '2026-07']);
      expect(_dates(list), [
        ['2026-09-28', '2026-09-25'],
        ['2026-07-04'],
      ]);
    });

    test('a year boundary splits January 2026 from December 2025', () {
      final list = buildDaysList([
        _row('2025-12-31'),
        _row('2025-01-15'),
        _row('2026-01-02'),
        _row('2025-12-01'),
      ], today: '2026-01-05');

      expect(_months(list), ['2026-01', '2025-12', '2025-01']);
      expect(_headers(list), ['January 2026', 'December 2025', 'January 2025']);
      expect(_dates(list), [
        ['2026-01-02'],
        ['2025-12-31', '2025-12-01'],
        ['2025-01-15'],
      ]);
    });

    test('the same month in two years forms two groups', () {
      final list = buildDaysList([
        _row('2025-10-20'),
        _row('2026-10-01'),
      ], today: '2026-10-03');

      expect(_months(list), ['2026-10', '2025-10']);
      expect(_headers(list), ['October 2026', 'October 2025']);
    });

    test('each dated row carries its note id, preview and review state', () {
      final list = buildDaysList([
        _row(
          '2026-10-02',
          id: 'n-a',
          preview: 'Called the bank',
          state: ReviewState.reviewed,
        ),
        _row(
          '2026-09-30',
          id: 'n-b',
          preview: 'September wrap',
          state: ReviewState.changedSinceReview,
        ),
      ], today: '2026-10-03');

      final rows = [for (final g in list.groups) ...g.rows];
      expect([for (final r in rows) r.noteId], ['n-a', 'n-b']);
      expect(
        [for (final r in rows) r.preview],
        ['Called the bank', 'September wrap'],
      );
      expect(
        [for (final r in rows) r.reviewState],
        [ReviewState.reviewed, ReviewState.changedSinceReview],
      );
    });

    test(
      'a daily note dated after today is still a dated row, newest first',
      () {
        final list = buildDaysList([
          _row('2026-10-01'),
          _row('2026-10-05'),
        ], today: '2026-10-03');

        expect(list.today.date, '2026-10-03');
        expect(list.today.isVirtual, isTrue);
        expect(_dates(list), [
          ['2026-10-05', '2026-10-01'],
        ]);
      },
    );
  });

  group('the Today row (AC4)', () {
    test(
      'the Today row is backed by the daily note of today with no second dated row for today',
      () {
        final list = buildDaysList([
          _row('2026-10-02'),
          _row('2026-10-03', id: 'today-id', preview: 'Late thoughts'),
          _row('2026-09-30'),
        ], today: '2026-10-03');

        expect(list.today.date, '2026-10-03');
        expect(list.today.isVirtual, isFalse);
        expect(list.today.note, isNotNull);
        expect(list.today.note!.noteId, 'today-id');
        expect(list.today.note!.preview, 'Late thoughts');
        expect(_dates(list), [
          ['2026-10-02'],
          ['2026-09-30'],
        ]);
        final all = [for (final g in list.groups) ...g.rows];
        expect(all.where((r) => r.date == '2026-10-03'), isEmpty);
      },
    );

    test('the Today row is virtual when today has no daily note', () {
      final list = buildDaysList([
        _row('2026-10-02'),
        _row('2026-09-30'),
      ], today: '2026-10-03');

      expect(list.today.date, '2026-10-03');
      expect(list.today.isVirtual, isTrue);
      expect(list.today.note, isNull);
      expect(_dates(list), [
        ['2026-10-02'],
        ['2026-09-30'],
      ]);
    });

    test('with no daily notes the list is only a virtual Today row', () {
      final list = buildDaysList(const [], today: '2026-10-03');

      expect(list.today.date, '2026-10-03');
      expect(list.today.isVirtual, isTrue);
      expect(list.groups, isEmpty);
    });

    test(
      'the Today row follows the date passed in rather than the newest note',
      () {
        // The newest note is yesterday: it stays a dated row, and today is
        // the virtual row.
        final list = buildDaysList([
          _row('2026-10-03', id: 'yesterday'),
        ], today: '2026-10-04');

        expect(list.today.date, '2026-10-04');
        expect(list.today.isVirtual, isTrue);
        expect(_months(list), ['2026-10']);
        expect(_dates(list), [
          ['2026-10-03'],
        ]);
        expect(list.groups.single.rows.single.noteId, 'yesterday');
      },
    );

    test(
      'the note of today backs the Today row even when a later-dated note exists',
      () {
        final list = buildDaysList([
          _row('2026-10-03', id: 'today-id'),
          _row('2026-10-09'),
        ], today: '2026-10-03');

        expect(list.today.note!.noteId, 'today-id');
        expect(_dates(list), [
          ['2026-10-09'],
        ]);
      },
    );
  });
}
