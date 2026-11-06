import '../../cli/excerpt_cli.dart';
import '../../cli/feedback_cli.dart';
import '../../cli/guide_cli.dart';
import '../../db.dart';
import '../../db/feedback_reads.dart';
import '../../memex_cli.dart';
import '../feedback_access.dart';
import 'write_guard.dart';

/// [FeedbackAccess] for a local vault: Feedback and guide revisions from
/// [db], everything else through [cli] with `--vault` [vaultPath]. Either may
/// be null (see `FeedbackAccess`).
class LocalFeedbackAccess implements FeedbackAccess {
  LocalFeedbackAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  MemexCli get _cli => requireLocalCli(cli);

  // ---------- filing and block writes (CLI) ----------

  @override
  Future<Filing> filing(String date) async =>
      _cli.filing(vaultPath: vaultPath, date: date);

  @override
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => _cli.addExcerpt(
    vaultPath: vaultPath,
    topicNoteId: topicNoteId,
    date: date,
    blockId: blockId,
    note: note,
  );

  @override
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => _cli.moveExcerptBlock(
    vaultPath: vaultPath,
    date: date,
    blockId: blockId,
    fromTopicNoteId: fromTopicNoteId,
    toTopicNoteId: toTopicNoteId,
    note: note,
  );

  @override
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => _cli.removeExcerptBlock(
    vaultPath: vaultPath,
    topicNoteId: topicNoteId,
    date: date,
    blockId: blockId,
    note: note,
  );

  // ---------- comments (CLI) ----------

  @override
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) async => _cli.addFeedback(
    vaultPath: vaultPath,
    noteId: noteId,
    date: date,
    changeId: changeId,
    text: text,
  );

  @override
  Future<FeedbackRow> editComment({
    required String id,
    required String text,
  }) async => _cli.editFeedback(vaultPath: vaultPath, id: id, text: text);

  @override
  Future<FeedbackRemoveResult> deleteComment({required String id}) async =>
      _cli.removeFeedback(vaultPath: vaultPath, id: id);

  // ---------- reads (database) ----------

  @override
  Future<List<FeedbackRow>> feedbackForNote(String noteId) async =>
      db?.feedbackForNote(noteId) ?? const [];

  @override
  Future<List<FeedbackRow>> feedbackWithoutNote() async =>
      db?.feedbackWithoutNote() ?? const [];

  // ---------- Vault Guide ----------

  @override
  Future<VaultGuide> guide() async => _cli.getGuide(vaultPath: vaultPath);

  @override
  Future<List<GuideRevisionRow>> guideRevisions() async =>
      db?.guideRevisions() ?? const [];

  @override
  Future<GuideRestoreResult> restoreGuide(String revisionId) async =>
      _cli.restoreGuide(vaultPath: vaultPath, revisionId: revisionId);
}
