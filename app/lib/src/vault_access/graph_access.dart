import '../db/activity_reads.dart';
import '../db/graph_reads.dart';

/// Graph view and activity reads of the open vault (D13, D11 V5). Async
/// mirrors of today's `GraphReads` / `ActivityReads`; today's empty values
/// without a database.
///
/// Frozen at merge (D13). Test doubles `extends LocalGraphAccess` (D21).
abstract interface class GraphAccess {
  /// `GraphReads.graphNotes`.
  Future<List<GraphNoteRow>> graphNotes();

  /// `GraphReads.graphLinks`.
  Future<List<GraphLinkRow>> graphLinks();

  /// `ActivityReads.agentChanges`: newest first.
  Future<List<AgentChangeRow>> agentChanges(String noteId);
}
