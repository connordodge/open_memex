import '../../db/activity_reads.dart';
import '../../db/graph_reads.dart';
import '../graph_access.dart';
import 'hosted_client.dart';

/// [GraphAccess] for a hosted vault (D11 V5, D13): every read is one
/// `/vaults/<vaultName>/api/v1` route through [client] (D17). Also reads the
/// vault's schema version from the vault info route, for #96's composite.
class HostedGraphAccess implements GraphAccess {
  HostedGraphAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  /// `GET /graph/notes`: `{"notes": [{id, title, role}]}`.
  @override
  Future<List<GraphNoteRow>> graphNotes() async {
    final body = await _get('/graph/notes', 'graphNotes');
    return [
      for (final n in _list(body, 'notes'))
        GraphNoteRow(
          id: n['id']! as String,
          title: n['title']! as String,
          role: n['role'] as String?,
        ),
    ];
  }

  /// `GET /graph/links`: `{"links": [{from, to, kind, label}]}`.
  @override
  Future<List<GraphLinkRow>> graphLinks() async {
    final body = await _get('/graph/links', 'graphLinks');
    return [
      for (final l in _list(body, 'links'))
        GraphLinkRow(
          from: l['from']! as String,
          to: l['to']! as String,
          kind: l['kind']! as String,
          label: l['label'] as String?,
        ),
    ];
  }

  /// `GET /notes/<noteId>/agent-changes`: `{"changes": [{id, note_id, day,
  /// created_at, bullets}]}`, newest first. [noteId] is one encoded segment.
  @override
  Future<List<AgentChangeRow>> agentChanges(String noteId) async {
    final body = await _get(
      '/notes/${Uri.encodeComponent(noteId)}/agent-changes',
      'agentChanges',
    );
    return [
      for (final c in _list(body, 'changes'))
        AgentChangeRow(
          id: c['id']! as String,
          noteId: c['note_id']! as String,
          day: c['day']! as String,
          createdAt: (c['created_at']! as num).toInt(),
          bullets: [for (final b in c['bullets']! as List) b as String],
        ),
    ];
  }

  /// The `schema_version` of `GET /vaults/<vaultName>/api/v1/info` (req 17).
  /// Not checked here: the app doesn't check it for hosted vaults (req 53).
  Future<int> schemaVersion() async {
    final body = await _get('/info', 'schemaVersion');
    return (body['schema_version']! as num).toInt();
  }

  Future<Map<String, Object?>> _get(String path, String operation) =>
      client.vaultRequest('GET', vaultName, path, operation: operation);

  /// The objects of the list under [key] in [body].
  static Iterable<Map<String, Object?>> _list(
    Map<String, Object?> body,
    String key,
  ) => (body[key]! as List).cast<Map<String, Object?>>();
}
