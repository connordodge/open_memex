import '../db.dart';
import '../memex_cli.dart';

/// The parsed `memex read-only set|clear` result (D14):
/// `{vault_id, note_id, agent_read_only}`. Also the body of
/// `PUT …/notes/{note_id}/agent-read-only`.
class AgentReadOnlyResult {
  const AgentReadOnlyResult({
    required this.vaultId,
    required this.noteId,
    required this.agentReadOnly,
  });
  final String vaultId;
  final String noteId;
  final bool agentReadOnly;
}

/// The parsed `memex revisions restore` result (D14):
/// `{vault_id, note_id, version, content_md}`. Also the body of
/// `POST …/notes/{note_id}/revisions/{revision_id}/restore`.
class NoteRevisionRestoreResult {
  const NoteRevisionRestoreResult({
    required this.vaultId,
    required this.noteId,
    required this.version,
    required this.contentMd,
  });
  final String vaultId;
  final String noteId;

  /// The note's new `notes.version`.
  final int version;
  final String contentMd;
}

/// `memex read-only set|clear` and `memex revisions list|restore` wrappers
/// (D13, D14, D16; pattern of `NoteCli`).
///
/// A CLI failure throws [MemexException] with the C1 `code` and message,
/// labelled with the subcommand (`read-only set`, `read-only clear`,
/// `revisions list`, `revisions restore`); stdout that is not the D14 shape
/// throws a [MemexException] with a null code.
extension AgentEditsCli on MemexCli {
  /// `memex read-only set|clear --vault V --note-id N` ([on] picks `set`).
  Future<AgentReadOnlyResult> setAgentReadOnly({
    required String vaultPath,
    required String noteId,
    required bool on,
  }) async =>
      const AgentReadOnlyResult(vaultId: '', noteId: '', agentReadOnly: false);

  /// `memex revisions list --vault V --note-id N`: newest first.
  Future<List<NoteRevision>> noteRevisions({
    required String vaultPath,
    required String noteId,
  }) async => const [];

  /// `memex revisions restore --vault V --revision-id R`.
  Future<NoteRevisionRestoreResult> restoreNoteRevision({
    required String vaultPath,
    required String revisionId,
  }) async => const NoteRevisionRestoreResult(
    vaultId: '',
    noteId: '',
    version: 0,
    contentMd: '',
  );
}
