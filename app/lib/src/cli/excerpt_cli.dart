import '../memex_cli.dart';

/// The parsed `memex excerpt rm` result (C2.4).
class ExcerptRemoveResult {
  const ExcerptRemoveResult({
    required this.vaultId,
    required this.topicNoteId,
    required this.version,
  });
  final String vaultId;
  final String topicNoteId;

  /// The topic note's new `notes.version` after the token was removed.
  final int version;
}

/// `memex excerpt rm` wrapper (C2.4, D21).
extension ExcerptCli on MemexCli {
  /// `memex excerpt rm --vault V --topic-note-id T --date YYYY-MM-DD
  /// --block-ids FROM[,TO]` with [vaultPath], [topicNoteId], [date],
  /// [fromBlockId] and [toBlockId]: removes the transclusion
  /// `![[date#^from(..^to)?]]` from the topic note.
  ///
  /// Stdout is `{"vault_id":…,"topic_note_id":…,"version":N}`. A CLI failure
  /// throws [MemexException] with the C1 `code` (`role_rule`, `not_found`,
  /// `invalid_date`); stdout that is not that shape throws a
  /// [MemexException] with a null code.
  Future<ExcerptRemoveResult> removeExcerpt({
    required String vaultPath,
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) async {
    throw UnimplementedError('removeExcerpt (WI #27)');
  }
}
