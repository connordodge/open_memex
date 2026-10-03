import 'dart:convert';

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
  List<AgentChangeRow> agentChanges(String noteId) {
    if (!hasTables(const ['agent_changes'])) return const [];
    final rows = db.select(
      'SELECT id, note_id, day, created_at, bullets_json FROM agent_changes '
      'WHERE note_id = ? ORDER BY created_at DESC, rowid DESC',
      [noteId],
    );
    return rows
        .map(
          (r) => AgentChangeRow(
            id: r['id'] as String,
            noteId: r['note_id'] as String,
            day: r['day'] as String,
            createdAt: (r['created_at'] as num).toInt(),
            bullets: _decodeBullets(r['bullets_json']),
          ),
        )
        .toList();
  }
}

List<String> _decodeBullets(Object? raw) {
  if (raw is! String) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.map((b) => '$b').toList();
  } on FormatException {
    return const [];
  }
}
