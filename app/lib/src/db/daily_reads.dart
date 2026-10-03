import '../db.dart';

/// A daily note's review state (Req 19). Labels are the Spec's exact words.
enum ReviewState {
  unreviewed,
  reviewed,
  changedSinceReview;

  /// `Unreviewed`, `Reviewed` or `Changed since review`.
  String get label => throw UnimplementedError();
}

/// A note's review state plus when it was last reviewed (unix ms, null when
/// never reviewed).
class ReviewInfo {
  const ReviewInfo({required this.state, this.reviewedAt});

  final ReviewState state;
  final int? reviewedAt;
}

/// One Days row: a note with `role: daily`. [date] is the ISO title.
class DailyNoteRow {
  const DailyNoteRow({
    required this.date,
    required this.noteId,
    required this.preview,
    required this.reviewState,
  });

  final String date;
  final String noteId;
  final String preview;
  final ReviewState reviewState;
}

/// One row of `blocks`. [source] is `person`, `agent` or `quick-entry`;
/// [createdAt] is unix ms.
class BlockRow {
  const BlockRow({
    required this.blockId,
    required this.ord,
    required this.text,
    required this.source,
    required this.createdVersion,
    required this.createdAt,
    required this.startByte,
    required this.endByte,
  });

  final String blockId;
  final int ord;
  final String text;
  final String source;
  final int createdVersion;
  final int createdAt;
  final int startByte;
  final int endByte;
}

/// One Topics footer chip of a daily note. [origin] is `excerpt` or `person`.
class FooterChipRow {
  const FooterChipRow({
    required this.topicNoteId,
    required this.topicTitle,
    required this.origin,
  });

  final String topicNoteId;
  final String topicTitle;
  final String origin;
}

/// Daily-note reads (V5). Every method returns an empty list / null on a
/// vault that lacks the V5 tables, never throws.
extension DailyReads on VaultDb {
  List<DailyNoteRow> dailyNotes() => throw UnimplementedError();

  DailyNoteRow? dailyNoteForDate(String isoDate) => throw UnimplementedError();

  ReviewInfo? reviewState(String noteId) => throw UnimplementedError();

  List<BlockRow> blocksForNote(String noteId) => throw UnimplementedError();

  List<FooterChipRow> footerChips(String dailyNoteId) =>
      throw UnimplementedError();
}
