// WI #413 (Spec #394 req 16, 43): the hosted vault's embeddings route.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents_sheet/recall/embeddings_status.dart';
import '../../memex_cli.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_state.dart';
import 'hosted_client.dart';

/// `GET /vaults/{name}/api/v1/embeddings` of one hosted vault. Fakes
/// implement it.
abstract class HostedEmbeddingsApi {
  /// [EmbeddingsStatusOk] for a 200; [EmbeddingsServerTooOld] only for
  /// `404 not_found`; [EmbeddingsStatusError] (the server's message, without
  /// the operation prefix) for every other refusal, `vault_not_found` and
  /// `unauthorized` included, and for a body that is not the wire shape. An
  /// unreachable server throws `VaultUnreachableException`.
  Future<EmbeddingsStatusResult> status();
}

/// [HostedEmbeddingsApi] through `HostedClient.vaultRequest`.
class ClientHostedEmbeddingsApi implements HostedEmbeddingsApi {
  ClientHostedEmbeddingsApi({required this.client, required this.vaultName});

  final HostedClient client;

  /// The vault's name on the server.
  final String vaultName;

  static const _operation = 'embeddings status';

  @override
  Future<EmbeddingsStatusResult> status() async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        'GET',
        vaultName,
        '/embeddings',
        operation: _operation,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found') return const EmbeddingsServerTooOld();
      const prefix = '$_operation failed: ';
      return EmbeddingsStatusError(
        e.message.startsWith(prefix)
            ? e.message.substring(prefix.length)
            : e.message,
      );
    }
    try {
      return EmbeddingsStatusOk(EmbeddingsStatus.fromJson(body));
    } on FormatException catch (e) {
      return EmbeddingsStatusError(
        'the server sent an embeddings status the app cannot read: '
        '${e.message}',
      );
    }
  }
}

/// The open hosted vault's embeddings API; null unless the open vault is a
/// hosted vault whose session is for that same vault (as
/// `hostedBackupApiProvider`).
final hostedEmbeddingsApiProvider = Provider<HostedEmbeddingsApi?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return null;
  final session = ref.watch(hostedSessionProvider);
  if (session == null || session.vault != vault) return null;
  return ClientHostedEmbeddingsApi(
    client: session.client,
    vaultName: vault.vaultName,
  );
});
