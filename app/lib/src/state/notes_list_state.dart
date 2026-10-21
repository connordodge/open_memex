import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// How the sidebar's note list is ordered. Persisted choice between
/// "last edited" (default — `notes.updated_at` desc) and alphabetical
/// (case-insensitive title). Deliberately does **not** include
/// "last opened": opening a note shouldn't change its rank in the list.
enum NoteSortMode { lastEdited, alphabetical }

final sidebarSortProvider = StateProvider<NoteSortMode>(
  (_) => NoteSortMode.lastEdited,
);

/// The open vault's notes for the sidebar (D14a), read through
/// `vaultAccessProvider` (`notes.listNotes(limit: 200)`) and ordered by
/// [sidebarSortProvider], stamped with the vault they were loaded for.
/// Re-reads on every `vaultRevisionProvider` bump and on a vault switch.
final notesListAsyncProvider = FutureProvider<VaultScoped<List<NoteListItem>>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  final sort = ref.watch(sidebarSortProvider);
  if (access == null) return VaultScoped(vault, const []);
  final notes = [...await access.notes.listNotes(limit: 200)];
  switch (sort) {
    case NoteSortMode.alphabetical:
      notes.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    case NoteSortMode.lastEdited:
      // Already ordered by `updated_at DESC` by `notes.listNotes`.
      break;
  }
  return VaultScoped(vault, notes);
});

/// Synchronous facade over [notesListAsyncProvider] (D14a): the current
/// vault's loaded list; today's empty list before the first load, with no
/// vault open, or while a switched-to vault's read is pending.
final notesListProvider = Provider<List<NoteListItem>>(
  (ref) => vaultFacadeValue(ref, ref.watch(notesListAsyncProvider), const []),
);
