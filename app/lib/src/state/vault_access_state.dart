import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/vault_access.dart';

/// The open vault's [VaultAccess] (D13), built from `currentVaultProvider`,
/// `vaultDbProvider` and `memexCliProvider`: null with no open vault, else a
/// `LocalVaultAccess` for the current path (either handle may be null).
/// A hosted vault gives null until #96.
final vaultAccessProvider = Provider<VaultAccess?>((ref) {
  // RED SKELETON (#70 test author): placeholder; the implementer writes it.
  return null;
});

/// True when the open vault is a hosted vault. `VaultAsyncView` reads it to
/// pick the first-load state. Always false until hosted refs exist (#69 adapts
/// it to `currentVaultProvider`'s `HostedVaultRef`).
final vaultIsHostedProvider = Provider<bool>((ref) => false);
