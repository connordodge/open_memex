import 'dart:convert';

import '../memex_cli.dart';

/// The parsed `memex rm` result (C2.2).
class NoteDeleteResult {
  NoteDeleteResult({
    required this.vaultId,
    required this.noteId,
    required this.deleted,
  });
  final String vaultId;
  final String noteId;
  final bool deleted;
}

/// `memex rm` wrapper (C2.2).
extension NoteCli on MemexCli {
  /// `memex rm --vault <vaultPath> --note-id <noteId> --expected-version <n>`.
  ///
  /// Stdout is `{"vault_id":…,"note_id":…,"deleted":true}`. A CLI failure
  /// throws [MemexException] with the C1 `code` (`version_conflict`,
  /// `not_found`); stdout that is not that shape throws a [MemexException]
  /// with a null code.
  Future<NoteDeleteResult> deleteNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
  }) async {
    final r = await run([
      'rm',
      '--vault',
      vaultPath,
      '--note-id',
      noteId,
      '--expected-version',
      '$expectedVersion',
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('rm', r);
    }
    Object? json;
    try {
      json = jsonDecode(r.stdout.trim());
    } on FormatException {
      json = null;
    }
    final map = json is Map<String, Object?> ? json : null;
    final vaultId = map?['vault_id'];
    final id = map?['note_id'];
    final deleted = map?['deleted'];
    if (vaultId is! String || id is! String || deleted is! bool) {
      throw MemexException('rm: could not parse output: ${r.stdout}');
    }
    return NoteDeleteResult(vaultId: vaultId, noteId: id, deleted: deleted);
  }
}
