import 'fake_vault_db.dart';

/// Seed helpers for the V5 daily/topic tables (D21). Raw inserts against the
/// real V5 schema: nothing here goes through production read code.
extension DailySeed on FakeVaultDb {
  /// A note with `role: daily` titled [date] (ISO). Returns the note id.
  String seedDailyNote(
    String date, {
    String? id,
    int version = 1,
    int createdAt = 1759500000000,
    int? updatedAt,
  }) => seedNote(
    id: id ?? 'daily-$date',
    title: date,
    role: 'daily',
    version: version,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  /// A note with `role: topic`.
  String seedTopicNote(String id, String title) =>
      seedNote(id: id, title: title, role: 'topic');

  void seedBlock(
    String noteId,
    String blockId, {
    required int ord,
    required String text,
    String source = 'person',
    int startByte = 0,
    int? endByte,
    int createdVersion = 1,
    int createdAt = 1759500000000,
    String? contentHash,
  }) {
    db.execute(
      'INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, '
      'text, content_hash, source, created_version, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        noteId,
        blockId,
        ord,
        startByte,
        endByte ?? startByte + text.length,
        text,
        contentHash ?? 'h-$blockId',
        source,
        createdVersion,
        createdAt,
      ],
    );
  }

  void seedDayReview(
    String noteId, {
    required int contentVersion,
    int? reviewedContentVersion,
    int? reviewedAt,
  }) {
    db.execute(
      'INSERT INTO day_reviews (note_id, content_version, '
      'reviewed_content_version, reviewed_at) VALUES (?, ?, ?, ?)',
      [noteId, contentVersion, reviewedContentVersion, reviewedAt],
    );
  }

  /// Insert order is the rowid order the footer renders in (D11).
  void seedFooterChip(
    String dailyNoteId,
    String topicNoteId, {
    String origin = 'excerpt',
    int createdAt = 1759500000000,
  }) {
    db.execute(
      'INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, '
      'created_at) VALUES (?, ?, ?, ?)',
      [dailyNoteId, topicNoteId, origin, createdAt],
    );
  }

  void seedSmartFolder(
    String id,
    String name, {
    String? parentId,
    bool pinned = false,
    int createdAt = 1759500000000,
  }) {
    db.execute(
      'INSERT INTO smart_folders (id, name, parent_id, pinned, created_at, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      [id, name, parentId, pinned ? 1 : 0, createdAt, createdAt],
    );
  }

  void seedFolderMember(String folderId, String noteId, {bool pinned = false}) {
    db.execute(
      'INSERT INTO smart_folder_members (smart_folder_id, note_id, pinned) '
      'VALUES (?, ?, ?)',
      [folderId, noteId, pinned ? 1 : 0],
    );
  }
}
