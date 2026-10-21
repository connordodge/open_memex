import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
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
