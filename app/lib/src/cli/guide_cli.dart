import '../db/feedback_reads.dart';
import '../memex_cli.dart';

/// The parsed `memex guide get` result: the Vault Guide note.
class VaultGuide {
  const VaultGuide({
    required this.vaultId,
    required this.noteId,
    required this.version,
    required this.contentMd,
  });
  final String vaultId;
  final String noteId;
  final int version;
  final String contentMd;
}

/// The parsed `memex guide restore` result.
class GuideRestoreResult {
  const GuideRestoreResult({
    required this.vaultId,
    required this.noteId,
    required this.version,
  });
  final String vaultId;
  final String noteId;

  /// The guide note's new `notes.version`.
  final int version;
}

/// `memex guide get|revisions|restore` wrappers (#256).
extension GuideCli on MemexCli {
  /// `memex guide get --vault V`: creates the guide on first call.
  Future<VaultGuide> getGuide({required String vaultPath}) => Future.value(
    const VaultGuide(vaultId: '', noteId: '', version: 0, contentMd: ''),
  );

  /// `memex guide revisions --vault V`.
  Future<List<GuideRevisionRow>> guideRevisions({required String vaultPath}) =>
      Future.value(const []);

  /// `memex guide restore --vault V --revision-id R`.
  Future<GuideRestoreResult> restoreGuide({
    required String vaultPath,
    required String revisionId,
  }) => Future.value(
    const GuideRestoreResult(vaultId: '', noteId: '', version: 0),
  );
}
