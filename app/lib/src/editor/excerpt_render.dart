// Excerpt card text (contracts C4 render rule, architect D13, WI #27).
//
// Pure Dart: reads the referenced daily note and its blocks through the
// vault's daily domain (`DailyAccess`, #78) and never re-parses the body (the
// token comes from `segments.dart`).
import 'dart:math' show max, min;

import '../vault_access/daily_access.dart';

/// The rendered text of one transclusion token (C4).
class RenderedExcerpt {
  const RenderedExcerpt({
    required this.date,
    required this.text,
    required this.removed,
  });

  /// The token's `YYYY-MM-DD` date (the card's caption).
  final String date;

  /// The referenced blocks' text joined with `\n`, or the stub
  /// `removed from <date>` when [removed].
  final String text;

  /// True when the daily note for [date] or either endpoint block is missing.
  final bool removed;
}

/// Renders the transclusion `![[date#^from(..^to)?]]` through [daily]'s
/// `dailyNoteForDate` and `blocksForNote` (C4):
/// when the `role: daily` note titled [date] and both endpoint blocks exist,
/// the text of every block of that note with
/// `min(from.ord, to.ord) <= ord <= max(from.ord, to.ord)`, in ord order,
/// joined with `\n`; otherwise `removed from <date>`. [to] is null for a
/// single-block token. A local vault below V5 renders the stub; a failed
/// read completes with its error.
Future<RenderedExcerpt> renderExcerpt(
  DailyAccess daily, {
  required String date,
  required String from,
  String? to,
}) async {
  final removed = RenderedExcerpt(
    date: date,
    text: 'removed from $date',
    removed: true,
  );
  final note = await daily.dailyNoteForDate(date);
  if (note == null) return removed;
  final blocks = await daily.blocksForNote(note.noteId);
  int? ordOf(String id) {
    for (final b in blocks) {
      if (b.blockId == id) return b.ord;
    }
    return null;
  }

  final fromOrd = ordOf(from);
  final toOrd = to == null ? fromOrd : ordOf(to);
  if (fromOrd == null || toOrd == null) return removed;
  final lo = min(fromOrd, toOrd);
  final hi = max(fromOrd, toOrd);
  return RenderedExcerpt(
    date: date,
    text: [
      for (final b in blocks)
        if (b.ord >= lo && b.ord <= hi) b.text,
    ].join('\n'),
    removed: false,
  );
}
