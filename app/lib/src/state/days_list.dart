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
DaysList buildDaysList(List<DailyNoteRow> notes, {required String today}) =>
    throw UnimplementedError();
