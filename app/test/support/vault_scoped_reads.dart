// WI #105 (F1, D14a): the synchronous facades are deleted. Tests read an
// async vault read the way its readers render it (`VaultAsyncView`,
// `watchVaultValue`): the current vault's data when the read has it (a
// same-vault reload keeps the previous value), else [empty] (first load in
// flight, a first-load error, or data from the previous vault).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

/// What a reader of [read] shows now in [c].
T readScoped<T>(
  ProviderContainer c,
  ProviderListenable<AsyncValue<VaultScoped<T>>> read,
  T empty,
) {
  final scoped = currentVaultData(c.read(read), c.read(currentVaultProvider));
  return scoped == null ? empty : scoped.value;
}

/// Subscribes to [read] (open until [c] is disposed), lets every queued
/// async read finish, and returns what a reader shows.
Future<T> settledScoped<T>(
  ProviderContainer c,
  ProviderListenable<AsyncValue<VaultScoped<T>>> read,
  T empty,
) async {
  c.listen(read, (_, _) {});
  await pumpEventQueue();
  return readScoped(c, read, empty);
}

/// Listens to what a reader of [read] shows: [listener] runs each time the
/// read's value or the current vault changes it.
ProviderSubscription<T> listenScoped<T>(
  ProviderContainer c,
  ProviderListenable<AsyncValue<VaultScoped<T>>> read,
  T empty,
  void Function(T? previous, T next) listener, {
  bool fireImmediately = false,
}) {
  final view = Provider<T>((ref) {
    final scoped = currentVaultData(
      ref.watch(read),
      ref.watch(currentVaultProvider),
    );
    return scoped == null ? empty : scoped.value;
  });
  return c.listen<T>(view, listener, fireImmediately: fireImmediately);
}
