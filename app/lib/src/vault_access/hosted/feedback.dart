import '../../cli/excerpt_cli.dart';
import '../../cli/feedback_cli.dart';
import '../../cli/guide_cli.dart';
import '../../db/feedback_reads.dart';
import '../feedback_access.dart';
import 'hosted_client.dart';

/// [FeedbackAccess] for a hosted vault: every method is one
/// `/vaults/<vaultName>/api/v1` route of the #256 Contract through [client]
/// (D17). Writes leave `vaultRevisionProvider` to their call sites.
class HostedFeedbackAccess implements FeedbackAccess {
  HostedFeedbackAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  @override
  Future<Filing> filing(String date) async => const Filing(
    vaultId: '',
    date: '',
    noteId: '',
    reviewed: false,
    topics: [],
    notFiled: [],
  );

  @override
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptEditResult(vaultId: '', topicNoteId: '', version: 0);

  @override
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptMoveResult(
    vaultId: '',
    fromTopicNoteId: '',
    fromVersion: 0,
    toTopicNoteId: '',
    toVersion: 0,
  );

  @override
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptEditResult(vaultId: '', topicNoteId: '', version: 0);

  @override
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) async => _neutralRow;

  @override
  Future<FeedbackRow> editComment({
    required String id,
    required String text,
  }) async => _neutralRow;

  @override
  Future<FeedbackRemoveResult> deleteComment({required String id}) async =>
      const FeedbackRemoveResult(vaultId: '', id: '');

  @override
  Future<List<FeedbackRow>> feedbackForNote(String noteId) async => const [];

  @override
  Future<List<FeedbackRow>> feedbackWithoutNote() async => const [];

  @override
  Future<VaultGuide> guide() async =>
      const VaultGuide(vaultId: '', noteId: '', version: 0, contentMd: '');

  @override
  Future<List<GuideRevisionRow>> guideRevisions() async => const [];

  @override
  Future<GuideRestoreResult> restoreGuide(String revisionId) async =>
      const GuideRestoreResult(vaultId: '', noteId: '', version: 0);
}

const _neutralRow = FeedbackRow(
  id: '',
  kind: FeedbackKind.comment,
  source: FeedbackSource.person,
  status: FeedbackStatus.open,
  createdAt: 0,
  updatedAt: 0,
);
