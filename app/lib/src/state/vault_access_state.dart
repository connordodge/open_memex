import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/local/local_vault_access.dart';
import '../vault_access/vault_access.dart';
import 'vault_state.dart';

/// The open vault's [VaultAccess] (D13), built from `currentVaultProvider`,
/// `vaultDbProvider` and `memexCliProvider`: null with no open vault, else a
/// `LocalVaultAccess` for a [LocalVaultRef]'s folder (either handle may be
/// null). A [HostedVaultRef] gives null until #96.
final vaultAccessProvider = Provider<VaultAccess?>((ref) {
  final path = ref.watch(currentVaultProvider).localPath;
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
