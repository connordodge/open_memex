import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'tabs_state.dart' show VirtualTodayTab;
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The selected note read through `VaultAccess.notes.getNote`, with the vault
/// it was loaded for (D14a). Null with no vault, no note selected, or a
/// virtual Today tab selected: its id is never a vault note id, so it is
/// never read. [selectedNoteProvider] is its synchronous facade.
final selectedNoteAsyncProvider = FutureProvider<VaultScoped<Note?>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  final id = ref.watch(selectedNoteIdProvider);
  if (access == null || id == null || VirtualTodayTab.dateOf(id) != null) {
    return VaultScoped(vault, null);
  }
  return VaultScoped(vault, await access.notes.getNote(id));
});

/// Every note's (id, title) through `VaultAccess.notes.allTitles`, with the
/// vault it was loaded for. [noteTitlesProvider] is its facade.
final noteTitlesAsyncProvider = FutureProvider<VaultScoped<List<NoteTitle>>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null) return VaultScoped(vault, const []);
  return VaultScoped(vault, await access.notes.allTitles(limit: 1000));
});

/// Every link kind through `VaultAccess.notes.distinctLinkKinds`, with the
/// vault it was loaded for. [linkKindsProvider] is its facade.
final linkKindsAsyncProvider = FutureProvider<VaultScoped<List<String>>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null) return VaultScoped(vault, const []);
  return VaultScoped(vault, await access.notes.distinctLinkKinds());
});

/// Hydrated form of the selected note: the synchronous facade of
/// [selectedNoteAsyncProvider] (D14a).
final selectedNoteProvider = Provider<Note?>(
  (ref) => vaultFacadeValue(ref, ref.watch(selectedNoteAsyncProvider), null),
);

/// All notes' (id, title) pairs — used by the wikilink autocomplete and the
/// kind chip's "More…" picker. Facade of [noteTitlesAsyncProvider].
final noteTitlesProvider = Provider<List<NoteTitle>>(
  (ref) => vaultFacadeValue(
    ref,
    ref.watch(noteTitlesAsyncProvider),
    const <NoteTitle>[],
  ),
);

/// Distinct kinds present anywhere in the vault. Used by the chip's "More…"
/// picker to surface user-defined kinds the user has already coined.
/// Facade of [linkKindsAsyncProvider].
final linkKindsProvider = Provider<List<String>>(
  (ref) => vaultFacadeValue(
    ref,
    ref.watch(linkKindsAsyncProvider),
    const <String>[],
  ),
);

/// The current vault's data of the async vault read [provider], watched from
/// a widget, or [empty] while there is none or it was loaded for another
/// vault (D14a, through `currentVaultData`).
T watchVaultValue<T>(
  WidgetRef ref,
  ProviderListenable<AsyncValue<VaultScoped<T>>> provider,
  T empty,
) {
  final scoped = currentVaultData(
    ref.watch(provider),
    ref.watch(currentVaultProvider),
  );
  return scoped == null ? empty : scoped.value;
}

/// [watchVaultValue] without subscribing, for event handlers: the current
/// vault's data of [provider] right now, or [empty].
T readVaultValue<T>(
  WidgetRef ref,
  ProviderListenable<AsyncValue<VaultScoped<T>>> provider,
  T empty,
) {
  final scoped = currentVaultData(
    ref.read(provider),
    ref.read(currentVaultProvider),
  );
  return scoped == null ? empty : scoped.value;
}
