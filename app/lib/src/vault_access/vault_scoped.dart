import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_ref.dart';
import '../state/vault_state.dart';

/// The type `currentVaultProvider` holds: the open vault's ref, or null with
/// no open vault. Everything stamped with it follows this one alias.
typedef CurrentVault = VaultRef?;

/// A vault read stamped with the vault it was loaded for (D14a).
///
/// Async reader providers return `VaultScoped<T>` built from
/// `ref.watch(currentVaultProvider)`, so a value left over from the previous
/// vault after a switch can be told apart from the current vault's data.
/// [VaultAsyncView] and [vaultFacadeValue] treat a value whose [vault] is not
/// the current vault as no data.
final class VaultScoped<T> {
  const VaultScoped(this.vault, this.value);

  /// The vault [value] was loaded for.
  final CurrentVault vault;

  /// The read's result.
  final T value;
}

/// The current vault's data in [value], or null when [value] has none or its
/// data was loaded for a vault other than [current].
VaultScoped<T>? currentVaultData<T>(
  AsyncValue<VaultScoped<T>> value,
  CurrentVault current,
) {
  final scoped = value.valueOrNull;
  if (scoped == null || scoped.vault != current) return null;
  return scoped;
}

/// The value a D14a synchronous facade returns for an async reader's
/// [value]: its data when that was loaded for `currentVaultProvider`'s
/// vault (a same-vault reload keeps the previous data), else [empty]
/// (first load in flight, a first-load error, or data from the previous
/// vault after a switch). Watches `currentVaultProvider` through [ref].
T vaultFacadeValue<T>(
  Ref<Object?> ref,
  AsyncValue<VaultScoped<T>> value,
  T empty,
) {
  final scoped = currentVaultData(value, ref.watch(currentVaultProvider));
  return scoped == null ? empty : scoped.value;
}
