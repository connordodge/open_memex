import '../db.dart';

/// A daily note's review state (Req 19). Labels are the Spec's exact words.
enum ReviewState {
  unreviewed,
  reviewed,
  changedSinceReview;

  /// `Unreviewed`, `Reviewed` or `Changed since review`.
  String get label => switch (this) {
    ReviewState.unreviewed => 'Unreviewed',
    ReviewState.reviewed => 'Reviewed',
    ReviewState.changedSinceReview => 'Changed since review',
  };
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

/// `notes.frontmatter` role, guarded so a row with invalid JSON counts as
/// role-less instead of aborting the whole query.
const _dailyRoleSql =
    '(CASE WHEN json_valid(n.frontmatter) '
    "THEN json_extract(n.frontmatter, '\$.role') END) = 'daily'";

const _dailyNoteSelect =
    'SELECT n.id AS id, n.title AS title, '
    'r.content_version AS content_version, '
    'r.reviewed_content_version AS reviewed_content_version, '
    '(SELECT b.text FROM blocks b WHERE b.note_id = n.id '
    'ORDER BY b.ord LIMIT 1) AS first_block '
    'FROM notes n LEFT JOIN day_reviews r ON r.note_id = n.id '
    'WHERE $_dailyRoleSql';

ReviewState _stateOf(int? contentVersion, int? reviewedContentVersion) {
  if (contentVersion == null || reviewedContentVersion == null) {
    return ReviewState.unreviewed;
  }
  return contentVersion == reviewedContentVersion
      ? ReviewState.reviewed
      : ReviewState.changedSinceReview;
}

DailyNoteRow _dailyRow(Map<String, Object?> r) {
  final text = (r['first_block'] as String?) ?? '';
  final newline = text.indexOf('\n');
  return DailyNoteRow(
    date: r['title'] as String,
    noteId: r['id'] as String,
    preview: newline < 0 ? text : text.substring(0, newline),
    reviewState: _stateOf(
      (r['content_version'] as num?)?.toInt(),
      (r['reviewed_content_version'] as num?)?.toInt(),
    ),
  );
}

/// Daily-note reads (V5). Every method returns an empty list / null on a
/// vault that lacks the V5 tables, never throws. Reads are synchronous.
extension DailyReads on VaultDb {
  bool get _v5Ready => hasTables(VaultDb.v5TableNames);

  /// Every `role: daily` note, newest date first.
  List<DailyNoteRow> dailyNotes() {
    if (!_v5Ready) return const [];
    final rows = db.select('$_dailyNoteSelect ORDER BY n.title DESC, n.id');
    return rows.map(_dailyRow).toList();
  }

  /// The `role: daily` note titled [isoDate], or null.
  DailyNoteRow? dailyNoteForDate(String isoDate) {
    if (!_v5Ready) return null;
    final rows = db.select(
      '$_dailyNoteSelect AND n.title = ? ORDER BY n.id LIMIT 1',
      [isoDate],
    );
    return rows.isEmpty ? null : _dailyRow(rows.first);
  }

  /// [noteId]'s review state, or null on a vault below V5.
  ReviewInfo? reviewState(String noteId) {
    if (!_v5Ready) return null;
    final rows = db.select(
      'SELECT content_version, reviewed_content_version, reviewed_at '
      'FROM day_reviews WHERE note_id = ?',
      [noteId],
    );
    if (rows.isEmpty) return const ReviewInfo(state: ReviewState.unreviewed);
    final r = rows.first;
    return ReviewInfo(
      state: _stateOf(
        (r['content_version'] as num?)?.toInt(),
        (r['reviewed_content_version'] as num?)?.toInt(),
      ),
      reviewedAt: (r['reviewed_at'] as num?)?.toInt(),
    );
  }

  /// [noteId]'s blocks in `ord` order.
  List<BlockRow> blocksForNote(String noteId) {
    if (!_v5Ready) return const [];
    final rows = db.select(
      'SELECT block_id, ord, text, source, created_version, created_at, '
      'start_byte, end_byte FROM blocks WHERE note_id = ? ORDER BY ord',
      [noteId],
    );
    return rows
        .map(
          (r) => BlockRow(
            blockId: r['block_id'] as String,
            ord: (r['ord'] as num).toInt(),
            text: r['text'] as String,
            source: r['source'] as String,
            createdVersion: (r['created_version'] as num).toInt(),
            createdAt: (r['created_at'] as num).toInt(),
            startByte: (r['start_byte'] as num).toInt(),
            endByte: (r['end_byte'] as num).toInt(),
          ),
        )
        .toList();
  }

  /// [dailyNoteId]'s footer chips in insertion (rowid) order.
  List<FooterChipRow> footerChips(String dailyNoteId) {
    if (!_v5Ready) return const [];
    final rows = db.select(
      'SELECT c.topic_note_id AS topic_note_id, n.title AS title, '
      'c.origin AS origin FROM footer_chips c '
      'JOIN notes n ON n.id = c.topic_note_id '
      'WHERE c.daily_note_id = ? ORDER BY c.rowid',
      [dailyNoteId],
    );
    return rows
        .map(
          (r) => FooterChipRow(
            topicNoteId: r['topic_note_id'] as String,
            topicTitle: r['title'] as String,
            origin: r['origin'] as String,
          ),
        )
        .toList();
  }
}
