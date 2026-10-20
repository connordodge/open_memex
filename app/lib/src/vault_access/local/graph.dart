import '../../db.dart';
import '../../db/activity_reads.dart';
import '../../db/graph_reads.dart';
import '../graph_access.dart';

/// [GraphAccess] for a local vault: reads from [db] (D13); null [db] gives
/// today's empty values.
class LocalGraphAccess implements GraphAccess {
  LocalGraphAccess({required this.vaultPath, this.db});

  final String vaultPath;
  final VaultDb? db;

  @override
  Future<List<GraphNoteRow>> graphNotes() async => db?.graphNotes() ?? const [];

  @override
  Future<List<GraphLinkRow>> graphLinks() async => db?.graphLinks() ?? const [];

  @override
  Future<List<AgentChangeRow>> agentChanges(String noteId) async =>
      db?.agentChanges(noteId) ?? const [];
}
