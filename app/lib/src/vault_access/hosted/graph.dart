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

  @override
  Future<List<GraphNoteRow>> graphNotes() => throw UnimplementedError('#85');

  @override
  Future<List<GraphLinkRow>> graphLinks() => throw UnimplementedError('#85');

  @override
  Future<List<AgentChangeRow>> agentChanges(String noteId) =>
      throw UnimplementedError('#85');

  /// The `schema_version` of `GET /vaults/<vaultName>/api/v1/info` (req 17).
  /// Not checked here: the app doesn't check it for hosted vaults (req 53).
  Future<int> schemaVersion() => throw UnimplementedError('#85');
}
