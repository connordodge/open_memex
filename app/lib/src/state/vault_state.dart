import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import 'settings.dart';

/// The currently open vault path. `null` means no vault is open.
final currentVaultProvider = StateProvider<String?>((ref) {
  return ref.watch(settingsProvider).lastVault;
});

/// SQLite read handle for the current vault.
final vaultDbProvider = Provider<VaultDb?>((ref) {
  final path = ref.watch(currentVaultProvider);
  if (path == null) return null;
  if (!VaultDb.isVault(path)) return null;
  final db = VaultDb.open(path);
  ref.onDispose(db.close);
  return db;
});

/// Memex CLI handle bound to the configured binary path.
final memexCliProvider = Provider<MemexCli?>((ref) {
  final binary = ref.watch(settingsProvider).memexBinaryPath;
  if (binary == null || binary.isEmpty) return null;
  return MemexCli(binaryPath: binary);
});

/// A monotonic counter that increments whenever the vault should be re-read
/// from disk. Bump it after every write.
final vaultRevisionProvider = StateProvider<int>((_) => 0);

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

/// The currently selected note id (or null).
final selectedNoteIdProvider = StateProvider<String?>((_) => null);

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

/// Outgoing links for a note. Provider.family keyed on note id.
final linksOutProvider = Provider.family<List<LinkRow>, String>((ref, noteId) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.linksOutFor(noteId);
});

/// A backlink — incoming link enriched with the source note's title so the
/// UI can render "Source.title" without a second query per row.
class BacklinkEntry {
  BacklinkEntry({
    required this.linkId,
    required this.fromNoteId,
    required this.fromTitle,
    required this.kind,
    required this.label,
    required this.source,
  });
  final String linkId;
  final String fromNoteId;
  final String fromTitle;
  final String kind;
  final String? label;
  final String source;
}

/// Incoming links for a note, grouped by kind. Source titles are pre-joined
/// so the UI can render in one pass.
final backlinksProvider =
    Provider.family<Map<String, List<BacklinkEntry>>, String>((ref, noteId) {
      ref.watch(vaultRevisionProvider);
      final db = ref.watch(vaultDbProvider);
      if (db == null) return const {};
      final rows = db.linksInFor(noteId);
      if (rows.isEmpty) return const {};
      final fromIds = rows.map((r) => r.fromNoteId).toSet().toList();
      final titles = db.titlesForIds(fromIds);
      final out = <String, List<BacklinkEntry>>{};
      for (final r in rows) {
        final entry = BacklinkEntry(
          linkId: r.id,
          fromNoteId: r.fromNoteId,
          fromTitle: titles[r.fromNoteId] ?? r.fromNoteId,
          kind: r.kind,
          label: r.label,
          source: r.source,
        );
        (out[r.kind] ??= <BacklinkEntry>[]).add(entry);
      }
      // Sort source titles alphabetically inside each kind for stable rendering.
      for (final list in out.values) {
        list.sort((a, b) => a.fromTitle.compareTo(b.fromTitle));
      }
      return out;
    });

/// Order kinds: built-ins first in canonical order, user-defined alphabetic.
List<String> orderedLinkKinds(Iterable<String> kinds) {
  const builtIn = ['references', 'extends', 'contradicts', 'example-of'];
  final present = kinds.toSet();
  final out = <String>[];
  for (final b in builtIn) {
    if (present.contains(b)) out.add(b);
  }
  final userDefined = present.where((k) => !builtIn.contains(k)).toList()
    ..sort();
  out.addAll(userDefined);
  return out;
}

/// Friendly label for a kind in the UI ("Contradicted by", "Extended by",
/// etc. for backlinks; defaults to the kind verbatim for user-defined).
String backlinkLabelForKind(String kind) {
  switch (kind) {
    case 'references':
      return 'References';
    case 'extends':
      return 'Extended by';
    case 'contradicts':
      return 'Contradicted by';
    case 'example-of':
      return 'Examples';
    default:
      return kind;
  }
}

enum SaveStatus { idle, dirty, saving, clean, error, conflict }

class EditorStateValue {
  const EditorStateValue({
    required this.title,
    required this.contentMd,
    required this.status,
    this.errorMessage,
    this.lastSavedVersion,
  });
  final String title;
  final String contentMd;
  final SaveStatus status;
  final String? errorMessage;
  final int? lastSavedVersion;

  EditorStateValue copyWith({
    String? title,
    String? contentMd,
    SaveStatus? status,
    String? errorMessage,
    bool clearError = false,
    int? lastSavedVersion,
  }) => EditorStateValue(
    title: title ?? this.title,
    contentMd: contentMd ?? this.contentMd,
    status: status ?? this.status,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    lastSavedVersion: lastSavedVersion ?? this.lastSavedVersion,
  );
}
