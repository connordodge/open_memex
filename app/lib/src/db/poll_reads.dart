import '../db.dart';

/// The live-update poller's read (WI #28, Req 61): one
/// `SELECT updated_at FROM notes WHERE id = ?` per poll, run outside any
/// transaction so no read transaction is held across awaits (WAL).
extension PollReads on VaultDb {
  /// The `updated_at` (unix ms) of note [noteId]; null when it does not
  /// exist.
  int? noteUpdatedAt(String noteId) => throw UnimplementedError();
}
