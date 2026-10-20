import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// Hydrated form of the selected note.
final selectedNoteProvider = Provider<Note?>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  final id = ref.watch(selectedNoteIdProvider);
  if (db == null || id == null) return null;
  return db.getNote(id);
});

/// All notes' (id, title) pairs — used by the wikilink autocomplete and the
/// kind chip's "More…" picker.
final noteTitlesProvider = Provider<List<NoteTitle>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.allTitles(limit: 1000);
});

/// Distinct kinds present anywhere in the vault. Used by the chip's "More…"
/// picker to surface user-defined kinds the user has already coined.
final linkKindsProvider = Provider<List<String>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.distinctLinkKinds();
});

// ---------------------------------------------------------------------------
// Async versions (D14a, #78). Skeleton: the tests pin these names and types.
// ---------------------------------------------------------------------------

/// The selected note read through `VaultAccess.notes.getNote`, with the vault
/// it was loaded for. [selectedNoteProvider] is its synchronous facade.
final selectedNoteAsyncProvider = FutureProvider<VaultScoped<Note?>>((ref) {
  throw UnimplementedError();
});

/// Every note's (id, title) through `VaultAccess.notes.allTitles`, with the
/// vault it was loaded for. [noteTitlesProvider] is its facade.
final noteTitlesAsyncProvider = FutureProvider<VaultScoped<List<NoteTitle>>>((
  ref,
) {
  throw UnimplementedError();
});

/// Every link kind through `VaultAccess.notes.distinctLinkKinds`, with the
/// vault it was loaded for. [linkKindsProvider] is its facade.
final linkKindsAsyncProvider = FutureProvider<VaultScoped<List<String>>>((ref) {
  throw UnimplementedError();
});
