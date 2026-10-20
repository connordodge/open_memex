import '../state/vault_ref.dart';

/// Skeleton (#78 red tests) of #70's `VaultScoped` (lead update from REVIEW
/// #107): an async vault read's [value] stamped with the [vault] it was
/// loaded for (D14a). When #70's version lands, take it.
class VaultScoped<T> {
  const VaultScoped(this.vault, this.value);

  /// The vault the read ran against; null when no vault was open.
  final VaultRef? vault;

  /// What the read returned.
  final T value;
}
