import '../cli/excerpt_cli.dart';
import '../cli/feedback_cli.dart';
import '../cli/guide_cli.dart';
import '../db/feedback_reads.dart';

/// Block filing, Feedback and the Vault Guide of the open vault (Spec #233,
/// R42, R43, TD6), built on the frozen Contract of #256. Same rules as
/// `TopicsAccess`: today's empty values without a database (or below V6),
/// today's exceptions from writes, [StateError] from a write when
/// `VaultAccess.canWrite` is false.
///
/// Locally, Feedback and guide revisions are read from `VaultDb`; `filing`
/// and `guide` go through the CLI (`guide` may create the note). Every write
/// is one CLI call, or one hosted route.
///
/// Frozen at merge (D13). Test doubles `extends LocalFeedbackAccess` (D21).
abstract interface class FeedbackAccess {
  // ---------- filing ----------

  /// `memex filing` / `GET /daily-notes/{date}/filing`: where the blocks of
  /// the daily note [date] (`YYYY-MM-DD`) are filed.
  Future<Filing> filing(String date);

  /// `memex excerpt add`: files [blockId] of the daily note [date] under
  /// [topicNoteId]. [note] is the Correction's text, left out when null.
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  });

  /// `memex excerpt move`: moves [blockId] of [date] from one topic to
  /// another. [note] as in [fileBlock].
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  });

  /// `memex excerpt remove-block`: removes [blockId] of [date] from
  /// [topicNoteId]. [note] as in [fileBlock].
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  });

  // ---------- comments ----------

  /// `memex feedback add`: a comment on the agent change [changeId] of
  /// [noteId] on [date].
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  });

  /// `memex feedback edit`.
  Future<FeedbackRow> editComment({required String id, required String text});

  /// `memex feedback rm`.
  Future<FeedbackRemoveResult> deleteComment({required String id});

  // ---------- reads ----------

  /// [noteId]'s comments and Corrections of every status, plus its open tag
  /// Corrections (id `tag-<n>`), newest first.
  Future<List<FeedbackRow>> feedbackForNote(String noteId);

  /// Feedback with no note, plus open tag Corrections whose note was deleted
  /// (with their stored title), newest first.
  Future<List<FeedbackRow>> feedbackWithoutNote();

  // ---------- Vault Guide ----------

  /// `memex guide get`: the guide note, created on first call.
  Future<VaultGuide> guide();

  /// `memex guide revisions`: newest first.
  Future<List<GuideRevisionRow>> guideRevisions();

  /// `memex guide restore`: restores [revisionId], keeping the replaced text
  /// as a new revision.
  Future<GuideRestoreResult> restoreGuide(String revisionId);
}
