import 'hosted_client.dart';

/// The revision of one hosted vault (D9, req 22): `VaultAccess.revision()`
/// for a vault on a vault server, which #96 composes into the hosted
/// `VaultAccess`.
///
/// It reads `GET /vaults/<vaultName>/api/v1/revision` through [HostedClient]
/// and returns the server's opaque `revision` string unchanged. Errors are
/// `HostedClient`'s (`MemexException` from its one C1 parser, or
/// `VaultUnreachableException`); this class parses none itself.
class HostedRevision {
  HostedRevision(this._client, this.vaultName);

  // ignore: unused_field
  final HostedClient _client;

  /// The served vault's name on the server.
  final String vaultName;

  /// The vault's opaque revision. It changes after every committed write by
  /// any writer, and may change with no visible change.
  Future<String> revision() => throw UnimplementedError();
}
