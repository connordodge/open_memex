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

/// `memex rm` wrapper (C2.2). Skeleton: #31 implements it.
extension NoteCli on MemexCli {
  /// `memex rm --vault <vaultPath> --note-id <noteId> --expected-version <n>`.
  Future<NoteDeleteResult> deleteNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
  }) {
    throw UnimplementedError();
  }
}
