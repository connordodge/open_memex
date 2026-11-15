import 'dart:convert';

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

/// The D14 decoders, shared by [AgentEditsCli] (the CLI's stdout) and
/// `HostedNotesAccess` (the vault server's body), so both read one shape.
///
/// Each takes the decoded JSON and the operation label (`read-only set`,
/// `read-only clear`, `revisions list`, `revisions restore`). JSON that is
/// not the D14 shape throws a [MemexException] with a null code and the
/// message `'<operation>: could not parse output: <json>'`. Fields a later
/// server adds are ignored.
abstract final class AgentEditsWire {
  static Never _bad(String operation, Object? json) => throw MemexException(
    '$operation: could not parse output: '
    '${json is String ? json : jsonEncode(json)}',
  );

  /// `{vault_id, note_id, agent_read_only}`.
  static AgentReadOnlyResult readOnly(String operation, Object? json) {
    final map = json is Map<String, Object?> ? json : null;
    final vaultId = map?['vault_id'];
    final noteId = map?['note_id'];
    final flag = map?['agent_read_only'];
    if (vaultId is! String || noteId is! String || flag is! bool) {
      _bad(operation, json);
    }
    return AgentReadOnlyResult(
      vaultId: vaultId,
      noteId: noteId,
      agentReadOnly: flag,
    );
  }

  /// `{vault_id, revisions: [{id, agent_change_id|null, created_at}]}`, in
  /// the order listed (newest first). An absent `agent_change_id` reads as
  /// null.
  static List<NoteRevision> revisions(String operation, Object? json) {
    final map = json is Map<String, Object?> ? json : null;
    final list = map?['revisions'];
    if (map?['vault_id'] is! String || list is! List) _bad(operation, json);
    final out = <NoteRevision>[];
    for (final row in list) {
      final fields = row is Map<String, Object?> ? row : null;
      final id = fields?['id'];
      final changeId = fields?['agent_change_id'];
      final createdAt = fields?['created_at'];
      if (id is! String || changeId is! String? || createdAt is! int) {
        _bad(operation, json);
      }
      out.add(
        NoteRevision(id: id, agentChangeId: changeId, createdAt: createdAt),
      );
    }
    return out;
  }

  /// `{vault_id, note_id, version, content_md}`.
  static NoteRevisionRestoreResult restore(String operation, Object? json) {
    final map = json is Map<String, Object?> ? json : null;
    final vaultId = map?['vault_id'];
    final noteId = map?['note_id'];
    final version = map?['version'];
    final content = map?['content_md'];
    if (vaultId is! String ||
        noteId is! String ||
        version is! int ||
        content is! String) {
      _bad(operation, json);
    }
    return NoteRevisionRestoreResult(
      vaultId: vaultId,
      noteId: noteId,
      version: version,
      contentMd: content,
    );
  }
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
  }) async {
    final command = ['read-only', if (on) 'set' else 'clear'];
    return AgentEditsWire.readOnly(
      command.join(' '),
      await _agentEditsRun(command, [
        '--vault',
        vaultPath,
        '--note-id',
        noteId,
      ]),
    );
  }

  /// `memex revisions list --vault V --note-id N`: newest first.
  Future<List<NoteRevision>> noteRevisions({
    required String vaultPath,
    required String noteId,
  }) async => AgentEditsWire.revisions(
    'revisions list',
    await _agentEditsRun(
      const ['revisions', 'list'],
      ['--vault', vaultPath, '--note-id', noteId],
    ),
  );

  /// `memex revisions restore --vault V --revision-id R`.
  Future<NoteRevisionRestoreResult> restoreNoteRevision({
    required String vaultPath,
    required String revisionId,
  }) async => AgentEditsWire.restore(
    'revisions restore',
    await _agentEditsRun(
      const ['revisions', 'restore'],
      ['--vault', vaultPath, '--revision-id', revisionId],
    ),
  );

  /// Runs `memex <command> <flags>` once and returns the decoded stdout, or
  /// the raw stdout when it is not JSON (the decoder then rejects it). A
  /// failed run throws [MemexException.fromCliFailure] labelled with
  /// [command].
  Future<Object?> _agentEditsRun(
    List<String> command,
    List<String> flags,
  ) async {
    final r = await run([...command, ...flags]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure(command.join(' '), r);
    }
    final out = r.stdout.trim();
    try {
      return jsonDecode(out);
    } on FormatException {
      return out;
    }
  }
}
