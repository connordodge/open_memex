/// Display formats for dates and times (C5). Hand-written: no `intl`.
/// Every formatter uses the machine's local time zone (Req 3), a 24-hour
/// clock with two-digit hours and minutes, and no leading zero on the day.
library;

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _monthName(DateTime local) => _months[local.month - 1];

String _monthAbbr(DateTime local) => _monthName(local).substring(0, 3);

String _two(int n) => n.toString().padLeft(2, '0');

/// `14:32`: 24-hour local time, two-digit hours and minutes.
String _hhmm(DateTime local) => '${_two(local.hour)}:${_two(local.minute)}';

/// Daily note header, e.g. `Saturday, 5 September 2026`.
String formatDailyHeader(DateTime date) {
  final d = date.toLocal();
  return '${_weekdays[d.weekday - 1]}, ${d.day} ${_monthName(d)} ${d.year}';
}

/// Date and time, e.g. `5 Sep 2026, 14:32` (the C5 date-time part).
String formatDateTime(DateTime at) {
  final d = at.toLocal();
  return '${d.day} ${_monthAbbr(d)} ${d.year}, ${_hhmm(d)}';
}

/// Reviewed-state hover, e.g. `Reviewed by agent at 5 Sep 2026, 14:32`.
String formatReviewedAt(DateTime at) =>
    'Reviewed by agent at ${formatDateTime(at)}';

/// Gutter hover for an agent-captured block, e.g. `captured via agent, 14:32`.
String formatCapturedViaAgent(DateTime at) =>
    'captured via agent, ${_hhmm(at.toLocal())}';

/// Gutter hover for a quick-entry block, e.g. `added via quick entry, 14:32`.
String formatAddedViaQuickEntry(DateTime at) =>
    'added via quick entry, ${_hhmm(at.toLocal())}';

/// Days month group header, e.g. `October 2026`.
String formatMonthHeader(DateTime date) {
  final d = date.toLocal();
  return '${_monthName(d)} ${d.year}';
}

/// ISO calendar date (daily note title, excerpt caption), e.g. `2026-09-05`.
String isoDate(DateTime date) {
  final d = date.toLocal();
  return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
}

final _isoDateShape = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Parse a strict `YYYY-MM-DD` date to local midnight; null when [text] is not
/// a real calendar date in exactly that shape.
DateTime? parseIsoDate(String text) {
  final m = _isoDateShape.firstMatch(text);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  // DateTime normalises out-of-range parts (2026-02-30 → 2026-03-02,
  // 2026-13-01 → 2027-01-01); a real date round-trips unchanged. The year
  // can only change together with the month, so month and day suffice.
  final d = DateTime(year, month, day);
  if (d.month != month || d.day != day) return null;
  return d;
}

/// Local midnight at the start of the calendar day after [t] (DST-safe: a
/// calendar step, not `+ Duration(days: 1)`, which lands at 23:00 or 01:00 on
/// a day with a DST change).
DateTime startOfNextLocalDay(DateTime t) {
  final d = t.toLocal();
  return DateTime(d.year, d.month, d.day + 1);
}
