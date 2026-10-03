import '../memex_cli.dart';

/// The parsed `memex footer add` result (C2.3).
class FooterAddResult {
  const FooterAddResult({
    required this.vaultId,
    required this.dailyNoteId,
    required this.topicNoteId,
    required this.origin,
    required this.version,
  });

  final String vaultId;
  final String dailyNoteId;
  final String topicNoteId;

  /// `person` for this wrapper (C2.3).
  final String origin;

  /// The daily note's new `notes.version`.
  final int version;
}

/// `memex footer add` wrapper (C2.3, D21).
extension FooterCli on MemexCli {
  /// `memex footer add --vault V --daily-note-id D --topic-note-id T`: records a `person` chip for the topic in
  /// the daily note's Topics footer (idempotent).
  ///
  /// A CLI failure throws [MemexException] from
  /// [MemexException.fromCliFailure] (`role_rule`, `not_found`); stdout that
  /// is not the C2.3 shape throws a [MemexException] with a null code.
  Future<FooterAddResult> addFooterChip({
    required String vaultPath,
    required String dailyNoteId,
    required String topicNoteId,
  }) {
    throw UnimplementedError();
  }
}
