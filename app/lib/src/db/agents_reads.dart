import '../db.dart';
import '../vault_access/agents_access.dart';

/// Agent activity log reads (V7, #390 req 14/15, D22). Synchronous.
extension AgentsReads on VaultDb {
  /// The newest 20 `agent_activity` rows, newest first (`created_at DESC,
  /// id DESC`). Empty when the vault's schema has no `agent_activity` table
  /// (a V6 or older vault). Throws when the read itself fails (e.g. the
  /// database is locked).
  ///
  /// Probes for the table on every call ([VaultDb.hasTables] never caches a
  /// negative answer), so it sees the table once the CLI migrates an open V6
  /// handle to V7. Each statement runs in autocommit: no read transaction is
  /// left open.
  List<AgentActivityEntry> recentAgentActivity() {
    if (!hasTables(const ['agent_activity'])) return const [];
    return db
        .select(
          'SELECT id, session_id, client_name, tool, summary, note_id, '
          'created_at FROM agent_activity '
          'ORDER BY created_at DESC, id DESC LIMIT 20',
        )
        .map(
          (r) => AgentActivityEntry(
            id: r['id'] as String,
            sessionId: r['session_id'] as String,
            clientName: r['client_name'] as String,
            tool: r['tool'] as String,
            summary: r['summary'] as String,
            noteId: r['note_id'] as String?,
            createdAt: (r['created_at'] as num).toInt(),
          ),
        )
        .toList();
  }
}
