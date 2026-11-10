// WI #321 (A0, D19, D21): the hosted vault's backup routes. The types and
// provider are frozen; `HostedBackupApi`'s bodies and the provider's wiring
// are the stubs A1 (#322) replaces.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/backup_models.dart';
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
  Future<HostedBackupResult> status() =>
      throw UnimplementedError('A1 (#322) fills ClientHostedBackupApi.status');

  @override
  Future<HostedBackupResult> start() =>
      throw UnimplementedError('A1 (#322) fills ClientHostedBackupApi.start');
}

/// The open hosted vault's backup API; null when no hosted vault is open.
/// Stub: A1 builds it from `hostedSessionProvider`.
final hostedBackupApiProvider = Provider<HostedBackupApi?>((ref) => null);
