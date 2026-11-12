// WI #412 (Spec #394 req 16, 35; D20): the hosted vault's tools route.
// Skeleton: the types and the provider are frozen.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents_sheet/tools/tool_catalog.dart';
import '../../memex_cli.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_state.dart';
import 'hosted_client.dart';

/// `GET /vaults/{name}/api/v1/tools` of one hosted vault. Fakes implement it.
abstract class HostedToolsApi {
  /// [ToolCatalogOk] for a 200; [ToolCatalogServerTooOld] only for
  /// `404 not_found`; [ToolCatalogError] (the server's message, without the
  /// operation prefix) for every other refusal, `vault_not_found` and
  /// `unauthorized` included, and for a body that is not the wire shape. An
  /// unreachable server throws `VaultUnreachableException`.
  Future<ToolCatalogResult> list();
}

/// [HostedToolsApi] through `HostedClient.vaultRequest`.
class ClientHostedToolsApi implements HostedToolsApi {
  ClientHostedToolsApi({required this.client, required this.vaultName});

  final HostedClient client;

  /// The vault's name on the server.
  final String vaultName;

  @override
  Future<ToolCatalogResult> list() async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        'GET',
        vaultName,
        '/tools',
        operation: _operation,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found') return const ToolCatalogServerTooOld();
      const prefix = '$_operation failed: ';
      return ToolCatalogError(
        e.message.startsWith(prefix)
            ? e.message.substring(prefix.length)
            : e.message,
      );
    }
    try {
      return ToolCatalogOk(ToolCatalog.fromJson(body));
    } on FormatException catch (e) {
      return ToolCatalogError(
        'the server sent a tool list the app cannot read: ${e.message}',
      );
    }
  }

  static const _operation = 'tools';
}

/// The open hosted vault's tools API; null unless the open vault is a hosted
/// vault whose session is for that same vault (as `hostedBackupApiProvider`).
final hostedToolsApiProvider = Provider<HostedToolsApi?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return null;
  final session = ref.watch(hostedSessionProvider);
  if (session == null || session.vault != vault) return null;
  return ClientHostedToolsApi(
    client: session.client,
    vaultName: vault.vaultName,
  );
});
