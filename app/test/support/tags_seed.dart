// WI #249 (A3): seeds `tags` rows with their V6 columns on a FakeVaultDb.
import 'fake_vault_db.dart';

extension TagsSeed on FakeVaultDb {
  /// One `tags` row on a V6 vault. [origin] is `body`, `agent` or `person`;
  /// [firstLine] is the stored person-section line (a `body` tag's).
  void seedTag(
    String noteId,
    String tag, {
    String origin = 'person',
    String? firstLine,
  }) {
    db.execute(
      'INSERT INTO tags (note_id, tag, origin, first_line) '
      'VALUES (?, ?, ?, ?)',
      [noteId, tag, origin, firstLine],
    );
  }
}
