import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/hosted/hosted_vault_access.dart';
import '../vault_access/local/local_vault_access.dart';
import '../vault_access/vault_access.dart';
import 'vault_open_controller.dart';
import 'vault_open_hosted.dart';
import 'vault_state.dart';

/// The open vault's [VaultAccess] (D13), built from `currentVaultProvider`,
/// `vaultDbProvider` and `memexCliProvider`: null with no open vault, else a
/// `LocalVaultAccess` for a [LocalVaultRef]'s folder (either handle may be
/// null). A [HostedVaultRef] gives the [HostedVaultAccess] over the client
/// its open made (`hostedSessionProvider`), or null when no open made one;
/// the composite is disposed when the open vault changes (D19).
final vaultAccessProvider = Provider<VaultAccess?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is HostedVaultRef) {
    final session = ref.watch(hostedSessionProvider);
    if (session == null || session.vault != vault) return null;
    final controller = ref.read(vaultOpenControllerProvider);
    final access = HostedVaultAccess(
      client: session.client,
      vaultName: vault.vaultName,
      onVaultGone: () => controller.hostedVaultGoneWhileOpen(vault),
    );
    ref.onDispose(access.dispose);
    return access;
  }
  final path = vault.localPath;
  if (path == null) return null;
  return LocalVaultAccess(
    vaultPath: path,
    db: ref.watch(vaultDbProvider),
    cli: ref.watch(memexCliProvider),
  );
});

/// True when the open vault is a hosted vault: `currentVaultProvider` holds a
/// [HostedVaultRef]. False with no vault or a local vault. `VaultAsyncView`
/// reads it to pick the first-load state.
final vaultIsHostedProvider = Provider<bool>(
  (ref) => ref.watch(currentVaultProvider) is HostedVaultRef,
);
