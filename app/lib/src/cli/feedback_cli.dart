import '../db/feedback_reads.dart';
import '../memex_cli.dart';

/// One block of a day's [Filing].
class FilingBlock {
  const FilingBlock({required this.id, required this.text});
  final String id;
  final String text;
}

/// A topic and the blocks of the day filed under it.
class FilingTopic {
  const FilingTopic({
    required this.topicNoteId,
    required this.title,
    required this.blocks,
  });
  final String topicNoteId;
  final String title;
  final List<FilingBlock> blocks;
}

/// The Contract's `Filing` object (#256): where a daily note's blocks are
/// filed.
class Filing {
  const Filing({
    required this.vaultId,
    required this.date,
    required this.noteId,
    required this.reviewed,
    required this.topics,
    required this.notFiled,
  });
  final String vaultId;
  final String date;
  final String noteId;
  final bool reviewed;
  final List<FilingTopic> topics;
  final List<FilingBlock> notFiled;
}

/// The parsed `memex feedback rm` result.
class FeedbackRemoveResult {
  const FeedbackRemoveResult({required this.vaultId, required this.id});
  final String vaultId;
  final String id;
}

/// `memex filing` and `memex feedback add|edit|rm|ls` wrappers (#256).
extension FeedbackCli on MemexCli {
  /// `memex filing --vault V --date D`.
  Future<Filing> filing({required String vaultPath, required String date}) =>
      Future.value(
        const Filing(
          vaultId: '',
          date: '',
          noteId: '',
          reviewed: false,
          topics: [],
          notFiled: [],
        ),
      );

  /// `memex feedback add --vault V --note-id N --date D --change-id C
  /// --text TEXT`.
  Future<FeedbackRow> addFeedback({
    required String vaultPath,
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) => Future.value(_neutralFeedback);

  /// `memex feedback edit --vault V --id F --text TEXT`.
  Future<FeedbackRow> editFeedback({
    required String vaultPath,
    required String id,
    required String text,
  }) => Future.value(_neutralFeedback);

  /// `memex feedback rm --vault V --id F`.
  Future<FeedbackRemoveResult> removeFeedback({
    required String vaultPath,
    required String id,
  }) => Future.value(const FeedbackRemoveResult(vaultId: '', id: ''));

  /// `memex feedback ls --vault V --note-id N`, or `--no-note` when
  /// [noteId] is null. All statuses, newest first.
  Future<List<FeedbackRow>> listFeedback({
    required String vaultPath,
    String? noteId,
  }) => Future.value(const []);
}

const _neutralFeedback = FeedbackRow(
  id: '',
  kind: FeedbackKind.comment,
  source: FeedbackSource.person,
  status: FeedbackStatus.open,
  createdAt: 0,
  updatedAt: 0,
);
