import '../dates.dart';
import '../db/daily_reads.dart';

/// The `Today` row of the Days list (Req 49): backed by today's daily
/// [note] when it exists, or by the virtual Today note when [note] is null.
class DaysTodayRow {
  const DaysTodayRow({required this.date, this.note});

  /// Today's ISO date (`YYYY-MM-DD`).
  final String date;

  /// Today's daily note, or null when it does not exist yet.
  final DailyNoteRow? note;

  bool get isVirtual => note == null;
}

/// One month of dated Days rows.
class DaysMonthGroup {
  const DaysMonthGroup({
    required this.month,
    required this.header,
    required this.rows,
  });

  /// `YYYY-MM` (the `days-month-<yyyy-mm>` Key suffix).
  final String month;

  /// The C5 month header, e.g. `October 2026`.
  final String header;

  /// The month's daily notes, newest first.
  final List<DailyNoteRow> rows;
}

/// The Days list: the [today] row first, then the month [groups] newest
/// first. Today's daily note is never also a dated row in [groups].
class DaysList {
  const DaysList({required this.today, required this.groups});

  final DaysTodayRow today;
  final List<DaysMonthGroup> groups;
}

/// Group [notes] (from `dailyNotesProvider`, any order) into the Days list
/// for [today] (ISO date). Days with no daily note are not rows (Req 51).
///
/// A note whose title is not a real ISO date has no day to sit on and is
/// left out. When two notes claim one date, the smallest note id wins (the
/// note `dailyNoteForDate` resolves), so every date is one row.
DaysList buildDaysList(List<DailyNoteRow> notes, {required String today}) {
  final sorted = [
    for (final n in notes)
      if (parseIsoDate(n.date) != null) n,
  ]..sort(_newestFirst);
  DailyNoteRow? todayNote;
  final groups = <DaysMonthGroup>[];
  String? previousDate;
  for (final row in sorted) {
    if (row.date == previousDate) continue;
    previousDate = row.date;
    if (row.date == today) {
      todayNote = row;
      continue;
    }
    final month = row.date.substring(0, 7);
    if (groups.isEmpty || groups.last.month != month) {
      groups.add(
        DaysMonthGroup(
          month: month,
          header: formatMonthHeader(parseIsoDate(row.date)!),
          rows: [],
        ),
      );
    }
    groups.last.rows.add(row);
  }
  return DaysList(
    today: DaysTodayRow(date: today, note: todayNote),
    groups: groups,
  );
}

/// Date descending (ISO dates sort as text), then note id ascending.
int _newestFirst(DailyNoteRow a, DailyNoteRow b) {
  final byDate = b.date.compareTo(a.date);
  return byDate != 0 ? byDate : a.noteId.compareTo(b.noteId);
}
