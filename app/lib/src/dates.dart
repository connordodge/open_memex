/// Display formats for dates and times (C5). Hand-written: no `intl`.
/// Every formatter uses the machine's local time zone (Req 3), a 24-hour
/// clock with two-digit hours and minutes, and no leading zero on the day.
library;

/// Daily note header, e.g. `Saturday, 5 September 2026`.
String formatDailyHeader(DateTime date) =>
    throw UnimplementedError('formatDailyHeader');

/// Reviewed-state hover, e.g. `Reviewed by agent at 5 Sep 2026, 14:32`.
String formatReviewedAt(DateTime at) =>
    throw UnimplementedError('formatReviewedAt');

/// Gutter hover for an agent-captured block, e.g. `captured via agent, 14:32`.
String formatCapturedViaAgent(DateTime at) =>
    throw UnimplementedError('formatCapturedViaAgent');

/// Gutter hover for a quick-entry block, e.g. `added via quick entry, 14:32`.
String formatAddedViaQuickEntry(DateTime at) =>
    throw UnimplementedError('formatAddedViaQuickEntry');

/// Days month group header, e.g. `October 2026`.
String formatMonthHeader(DateTime date) =>
    throw UnimplementedError('formatMonthHeader');

/// ISO calendar date (daily note title, excerpt caption), e.g. `2026-09-05`.
String isoDate(DateTime date) => throw UnimplementedError('isoDate');

/// Parse a strict `YYYY-MM-DD` date to local midnight; null when [text] is not
/// a real calendar date in exactly that shape.
DateTime? parseIsoDate(String text) => throw UnimplementedError('parseIsoDate');

/// Local midnight at the start of the calendar day after [t] (DST-safe).
DateTime startOfNextLocalDay(DateTime t) =>
    throw UnimplementedError('startOfNextLocalDay');
