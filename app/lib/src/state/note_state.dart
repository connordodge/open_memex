import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'tabs_state.dart' show VirtualTodayTab;
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The selected note read through `VaultAccess.notes.getNote`, with the vault
/// it was loaded for (D14a). Null with no vault, no note selected, or a
/// virtual Today tab selected: its id is never a vault note id, so it is
/// never read.
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
/// vault it was loaded for. Used by the wikilink autocomplete and the kind
/// chip's "More…" picker.
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
/// vault it was loaded for. The chip's "More…" picker surfaces the kinds the
/// user has already coined.
final linkKindsAsyncProvider = FutureProvider<VaultScoped<List<String>>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null) return VaultScoped(vault, const []);
  return VaultScoped(vault, await access.notes.distinctLinkKinds());
});

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
