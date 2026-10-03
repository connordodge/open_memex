// Excerpt card text (contracts C4 render rule, architect D13, WI #27).
//
// Pure Dart: reads the referenced daily note and its blocks through #21's
// `DailyReads` and never re-parses the body (the token comes from
// `segments.dart`).
import '../db.dart';

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

/// Renders the transclusion `![[date#^from(..^to)?]]` against [db] (C4):
/// when the `role: daily` note titled [date] and both endpoint blocks exist,
/// the text of every block of that note with
/// `min(from.ord, to.ord) <= ord <= max(from.ord, to.ord)`, in ord order,
/// joined with `\n`; otherwise `removed from <date>`. [to] is null for a
/// single-block token. Never throws (a vault below V5 renders the stub).
RenderedExcerpt renderExcerpt(
  VaultDb db, {
  required String date,
  required String from,
  String? to,
}) {
  throw UnimplementedError('renderExcerpt (WI #27)');
}
