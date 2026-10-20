import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import 'vault_state.dart';

/// How the sidebar's note list is ordered. Persisted choice between
/// "last edited" (default — `notes.updated_at` desc) and alphabetical
/// (case-insensitive title). Deliberately does **not** include
/// "last opened": opening a note shouldn't change its rank in the list.
enum NoteSortMode { lastEdited, alphabetical }

final sidebarSortProvider = StateProvider<NoteSortMode>(
  (_) => NoteSortMode.lastEdited,
);

/// Sorted list of notes in the current vault.
final notesListProvider = Provider<List<NoteListItem>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  final notes = db.listNotes(limit: 200);
  switch (ref.watch(sidebarSortProvider)) {
    case NoteSortMode.alphabetical:
      notes.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    case NoteSortMode.lastEdited:
      // Already ordered by `updated_at DESC` via the SQL query.
      break;
  }
  return notes;
});
