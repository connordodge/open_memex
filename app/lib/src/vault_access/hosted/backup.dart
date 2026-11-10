// WI #321 (A0, D19, D21): the hosted vault's backup routes. The types and
// provider are frozen; WI #322 (A1) filled `HostedBackupApi`'s bodies and the
// provider's wiring.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../memex_cli.dart';
import '../../state/backup_models.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_state.dart';
import 'hosted_client.dart';

/// What the vault server answered for `GET` or `POST .../backup` (D21). An
/// unreachable server is not a result: it throws the real
/// `VaultUnreachableException`. `404 vault_not_found` is not a result either:
/// it reaches the caller as the `MemexException` the existing vault-gone
/// flow handles.
sealed class HostedBackupResult {
  const HostedBackupResult();
}

/// `GET` 200 or `POST` 202: the server's state.
final class HostedBackupOk extends HostedBackupResult {
  const HostedBackupOk(this.status);

  final BackupStatus status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostedBackupOk && other.status == status;

  @override
  int get hashCode => Object.hash(HostedBackupOk, status);

  @override
  String toString() => 'HostedBackupOk($status)';
}

/// `404 not_found` (no route): the vault server predates backups.
final class HostedBackupServerTooOld extends HostedBackupResult {
  const HostedBackupServerTooOld();

  @override
  bool operator ==(Object other) => other is HostedBackupServerTooOld;

  @override
  int get hashCode => (HostedBackupServerTooOld).hashCode;

  @override
  String toString() => 'HostedBackupServerTooOld()';
}

/// `POST` 409 `backup_in_progress`: the vault is backing up already.
final class HostedBackupAlreadyRunning extends HostedBackupResult {
  const HostedBackupAlreadyRunning();

  @override
  bool operator ==(Object other) => other is HostedBackupAlreadyRunning;

  @override
  int get hashCode => (HostedBackupAlreadyRunning).hashCode;

  @override
  String toString() => 'HostedBackupAlreadyRunning()';
}

/// `POST` 409 `backups_not_configured`: the server has no `--backup-dir`.
final class HostedBackupNotConfigured extends HostedBackupResult {
  const HostedBackupNotConfigured();

  @override
  bool operator ==(Object other) => other is HostedBackupNotConfigured;

  @override
  int get hashCode => (HostedBackupNotConfigured).hashCode;

  @override
  String toString() => 'HostedBackupNotConfigured()';
}

/// The backup routes of one hosted vault. Fakes implement it
/// (`FakeHostedBackupApi`).
abstract class HostedBackupApi {
  /// `GET /backup`.
  Future<HostedBackupResult> status();

  /// `POST /backup`: starts a backup now; the server answers 202 without
  /// waiting.
  Future<HostedBackupResult> start();
}

/// [HostedBackupApi] through `HostedClient.vaultRequest` (A1 fills it).
class ClientHostedBackupApi implements HostedBackupApi {
  ClientHostedBackupApi({required this.client, required this.vaultName});

  final HostedClient client;

  /// The vault's name on the server.
  final String vaultName;

  @override
  Future<HostedBackupResult> status() => _send('GET', 'backup status');

  @override
  Future<HostedBackupResult> start() => _send('POST', 'backup start');

  /// One request (no body, no polling). Only `404 not_found` (both methods)
  /// and, for `POST`, `409 backup_in_progress` / `backups_not_configured` are
  /// results; every other refusal, `vault_not_found` included, is the
  /// client's own [MemexException], and an unreachable server throws
  /// `VaultUnreachableException`.
  Future<HostedBackupResult> _send(String method, String operation) async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        method,
        vaultName,
        '/backup',
        operation: operation,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found') return const HostedBackupServerTooOld();
      if (method == 'POST') {
        if (e.code == 'backup_in_progress') {
          return const HostedBackupAlreadyRunning();
        }
        if (e.code == 'backups_not_configured') {
          return const HostedBackupNotConfigured();
        }
      }
      rethrow;
    }
    try {
      return HostedBackupOk(BackupStatus.fromHostedJson(body));
    } on FormatException catch (e) {
      throw MemexException('$operation failed: ${e.message}');
    }
  }
}

/// The open hosted vault's backup API; null unless the open vault is a hosted
/// vault whose session is for that same vault (as `vaultAccessProvider`). It
/// follows `currentVaultProvider` and `hostedSessionProvider`.
final hostedBackupApiProvider = Provider<HostedBackupApi?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return null;
  final session = ref.watch(hostedSessionProvider);
  if (session == null || session.vault != vault) return null;
  return ClientHostedBackupApi(
    client: session.client,
    vaultName: vault.vaultName,
  );
});
