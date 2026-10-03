import 'dart:convert';

import 'fake_vault_db.dart';

/// Seed helper for `agent_changes` (V5). A raw insert against the real V5
/// schema: nothing here goes through production read code. Insert order is
/// the rowid order, so tests can seed out of display order on purpose.
extension ActivitySeed on FakeVaultDb {
  /// One change-log entry for [noteId]. [createdAt] is unix ms, [day] the ISO
  /// day reviewed, [bullets] are stored as `bullets_json` in the given order.
  void seedAgentChange(
    String id,
    String noteId, {
    required String day,
    required int createdAt,
    required List<String> bullets,
  }) {
    db.execute(
      'INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, noteId, day, createdAt, jsonEncode(bullets)],
    );
  }
}
