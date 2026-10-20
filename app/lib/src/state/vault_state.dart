import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/settings_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import 'settings.dart';

export 'vault_ref.dart';

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

/// What opening the current vault found (see [vaultOpenProvider]).
class VaultOpenState {
  const VaultOpenState({
    required this.schemaOutdated,
    this.smartFolderMaxDepth,
  });

  /// True when the vault is still below schema V5 after the open call (the
  /// configured `memex` is missing or too old to migrate it). The workspace
  /// shows the `vault-schema-outdated` banner.
  final bool schemaOutdated;

  /// The vault's `smart_folder_max_depth` setting from the open call, or null
  /// when the call failed or no `memex` binary is configured.
  final int? smartFolderMaxDepth;
}

/// The minimum vault schema this app reads in full.
const requiredVaultSchemaVersion = 5;

/// Opens the current vault: runs `memex settings get --key
/// smart_folder_max_depth` once per opened vault, which migrates an older
/// vault to V5 through the CLI (the app's own handle is read-only). On
/// success it bumps [vaultRevisionProvider] so every read re-runs against the
/// migrated schema. Afterwards it re-reads the schema version: below V5 means
/// the vault is outdated for this app.
///
/// Watches only the vault path, the database and the CLI, so later revision
/// bumps never re-run the call. Never throws: a missing or failing binary
/// yields a state, not an error.
final vaultOpenProvider = FutureProvider<VaultOpenState>((ref) async {
  final path = ref.watch(currentVaultProvider);
  final db = ref.watch(vaultDbProvider);
  final cli = ref.watch(memexCliProvider);
  if (path == null || db == null) {
    return const VaultOpenState(schemaOutdated: false);
  }
  int? maxDepth;
  if (cli != null) {
    try {
      maxDepth = await cli.getSetting(path, smartFolderMaxDepthKey);
    } on Exception {
      // MemexException (older memex, locked vault, …) or ProcessException
      // (binary missing): fall through to the schema check.
    }
  }
  if (maxDepth != null) {
    ref.read(vaultRevisionProvider.notifier).state++;
  }
  return VaultOpenState(
    schemaOutdated: db.schemaVersion() < requiredVaultSchemaVersion,
    smartFolderMaxDepth: maxDepth,
  );
});

/// True when the open vault has every V5 table. V5 reads (daily notes,
/// review, Smart Folders) return empty while it is false instead of throwing.
/// Re-probed on every vault revision and when the open call completes, so a
/// pre-migration `false` is never cached.
final vaultV5ReadyProvider = Provider<bool>((ref) {
  ref.watch(vaultRevisionProvider);
  ref.watch(vaultOpenProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return false;
  return db.hasTables(VaultDb.v5TableNames);
});

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

/// Whether the right (Connections) panel is visible. Lives here so the
/// Workspace shell and the canvas zoom-in path can both reach it.
final rightPanelOpenProvider = StateProvider<bool>((_) => true);

/// All canvases in the current vault, ordered by `updated_at DESC`.
final canvasesProvider = Provider<List<CanvasRow>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.listCanvases();
});

/// Hydrated canvas (metadata + placed nodes + edges). Provider.family keyed
/// on canvas id.
final canvasDetailProvider = Provider.family<CanvasDetailRow?, String>((
  ref,
  canvasId,
) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return null;
  return db.getCanvasDetail(canvasId);
});

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
