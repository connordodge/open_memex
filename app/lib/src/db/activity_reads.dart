import '../db.dart';

/// One `agent_changes` row: a change-log entry the agent wrote after touching
/// a note. [day] is the ISO day reviewed, [createdAt] is unix ms and
/// [bullets] are the 1 to 3 change bullets in stored order.
class AgentChangeRow {
  const AgentChangeRow({
    required this.id,
    required this.noteId,
    required this.day,
    required this.createdAt,
    required this.bullets,
  });

  final String id;
  final String noteId;
  final String day;
  final int createdAt;
  final List<String> bullets;
}

/// Activity-log reads (V5). Return an empty list on a vault that lacks the V5
/// tables (or `agent_changes`), never throw. Reads are synchronous.
extension ActivityReads on VaultDb {
  /// [noteId]'s `agent_changes` rows, newest `created_at` first, with
  /// `bullets_json` decoded to [AgentChangeRow.bullets].
  List<AgentChangeRow> agentChanges(String noteId) =>
      throw UnimplementedError();
}
