import '../../memex_cli.dart';
import '../agents_access.dart';
import 'hosted_client.dart';

/// [AgentsAccess] for a hosted vault (#390 req 17): one
/// `GET /vaults/<vaultName>/api/v1/agents` through [client] (D20) per
/// [activity] call.
class HostedAgentsAccess implements AgentsAccess {
  HostedAgentsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  static const _operation = 'agents';

  /// The server's agents and recent entries, in the server's order. A
  /// `404 not_found` (an older server with no agents route, D21) is
  /// `available: false` with no agents and no entries. Every other refusal,
  /// `vault_not_found` and `unauthorized` included, is the client's own
  /// [MemexException]; an unreachable server throws
  /// `VaultUnreachableException`. A body that is not the contract shape
  /// throws a null-code [MemexException].
  @override
  Future<AgentActivity> activity() async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        'GET',
        vaultName,
        '/agents',
        operation: _operation,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found') {
        return const AgentActivity(agents: [], recent: [], available: false);
      }
      rethrow;
    }
    try {
      return AgentActivity.fromJson(body);
    } on FormatException catch (e) {
      throw MemexException('$_operation failed: ${e.message}');
    }
  }
}
