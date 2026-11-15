import '../cli/note_cli.dart';
import '../cli/note_edits_cli.dart';
import '../db.dart';
import '../memex_cli.dart';

/// Notes and links of the open vault (D13, D11 V1). Every method is async and
/// mirrors today's `VaultDb` read or `MemexCli` write, minus the vault path.
///
/// Reads return today's empty values (empty list, empty map, null row) when
/// the vault has no database handle. Writes throw exactly the exceptions
/// today's `MemexCli` wrapper throws ([MemexException] with its C1 `code` and
/// `fields`); a write on a vault whose `VaultAccess.canWrite` is false throws
/// a [StateError] and runs nothing.
///
/// Frozen at merge (D13). Test doubles `extends LocalNotesAccess` (D21).
abstract interface class NotesAccess {
  // ---------- reads ----------

  /// `VaultDb.listNotes`: newest `updated_at` first.
  Future<List<NoteListItem>> listNotes({int limit = 200});

  /// `VaultDb.getNote`: the note with its tags, or null.
  Future<Note?> getNote(String id);

  /// `VaultDb.allTitles`: every (id, title), newest first.
  Future<List<NoteTitle>> allTitles({int limit = 1000});

  /// `VaultDb.linksOutFor`: outgoing links by position.
  Future<List<LinkRow>> linksOutFor(String noteId);

  /// `VaultDb.linksInFor`: incoming links, optionally only those of [kind].
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind});

  /// `VaultDb.titlesForIds`: id → title for the ids that exist.
  Future<Map<String, String>> titlesForIds(List<String> ids);

  /// `VaultDb.distinctLinkKinds`: every link kind, sorted.
  Future<List<String>> distinctLinkKinds();

  /// The note's agent-edit revisions, newest first (D14, D16). Local:
  /// `VaultDb.noteRevisions` (empty below V8). Hosted:
  /// `GET …/notes/{note_id}/revisions`.
  Future<List<NoteRevision>> noteRevisions(String noteId);

  // ---------- writes ----------

  /// `memex add` (`MemexCli.addNote`): the new note's id.
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  });

  /// `memex update` (`MemexCli.updateNote`). A stale [expectedVersion]
  /// throws [MemexException] with kind [MemexErrorKind.versionConflict].
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  });

  /// `memex rm` (`NoteCli.deleteNote`).
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  });

  /// `memex add-link` (`MemexCli.addLink`).
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  });

  /// Sets ([on]) or clears the note's Agent read-only flag (D14, D16): local
  /// `memex read-only set|clear --note-id`, hosted
  /// `PUT …/notes/{note_id}/agent-read-only {agent_read_only}`. One call.
  Future<AgentReadOnlyResult> setAgentReadOnly(String noteId, bool on);

  /// Restores agent-edit revision [revisionId] of note [noteId] (D14, D16):
  /// local `memex revisions restore --revision-id`, hosted
  /// `POST …/notes/{note_id}/revisions/{revision_id}/restore`. One call.
  Future<NoteRevisionRestoreResult> restoreNoteRevision({
    required String noteId,
    required String revisionId,
  });

  /// `memex update-link` (`MemexCli.updateLink`).
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  });
}
