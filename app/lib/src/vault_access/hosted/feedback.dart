import '../../cli/excerpt_cli.dart';
import '../../cli/feedback_cli.dart';
import '../../cli/guide_cli.dart';
import '../../db/feedback_reads.dart';
import '../../memex_cli.dart';
import '../feedback_access.dart';
import 'hosted_client.dart';

/// [FeedbackAccess] for a hosted vault: every method is one
/// `/vaults/<vaultName>/api/v1` route of the #256 Contract through [client]
/// (D17). Errors are labelled with the CLI command name (`filing`,
/// `excerpt add`, `feedback ls`, `guide get`, ...), so a C1 error keeps its
/// code and fields; a response that is not the Contract shape throws a
/// [MemexException] with a null code. Writes leave `vaultRevisionProvider`
/// to their call sites.
class HostedFeedbackAccess implements FeedbackAccess {
  HostedFeedbackAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  /// One route, its response parsed by [parse]; a null parse is a null-code
  /// [MemexException].
  Future<T> _call<T extends Object>(
    String method,
    String path,
    T? Function(Map<String, Object?> json) parse, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) async {
    final json = await client.vaultRequest(
      method,
      vaultName,
      path,
      operation: operation,
      query: query,
      body: body,
    );
    final parsed = parse(json);
    if (parsed == null) {
      throw MemexException('$operation: could not parse output: $json');
    }
    return parsed;
  }

  static String _note(String id) => '/notes/${Uri.encodeComponent(id)}';

  static String _feedback(String id) => '/feedback/${Uri.encodeComponent(id)}';

  // ---------- filing and block writes ----------

  /// `GET /daily-notes/{date}/filing`.
  @override
  Future<Filing> filing(String date) => _call(
    'GET',
    '/daily-notes/${Uri.encodeComponent(date)}/filing',
    parseFiling,
    operation: 'filing',
  );

  /// `POST /notes/{topic_note_id}/excerpts {date, block_id[, note]}`.
  @override
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _call(
    'POST',
    '${_note(topicNoteId)}/excerpts',
    parseExcerptEditResult,
    operation: 'excerpt add',
    body: {'date': date, 'block_id': blockId, 'note': ?note},
  );

  /// `POST /notes/{from_topic_note_id}/excerpts/move {date, block_id,
  /// to_topic_note_id[, note]}`.
  @override
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _call(
    'POST',
    '${_note(fromTopicNoteId)}/excerpts/move',
    parseExcerptMoveResult,
    operation: 'excerpt move',
    body: {
      'date': date,
      'block_id': blockId,
      'to_topic_note_id': toTopicNoteId,
      'note': ?note,
    },
  );

  /// `DELETE /notes/{topic_note_id}/excerpts/blocks/{block_id}?date=[&note=]`
  /// (no body).
  @override
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _call(
    'DELETE',
    '${_note(topicNoteId)}/excerpts/blocks/${Uri.encodeComponent(blockId)}',
    parseExcerptEditResult,
    operation: 'excerpt remove-block',
    query: {'date': date, 'note': ?note},
  );

  // ---------- comments ----------

  /// `POST /feedback {note_id, date, change_id, text}`.
  @override
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) => _call(
    'POST',
    '/feedback',
    parseFeedbackRow,
    operation: 'feedback add',
    body: {
      'note_id': noteId,
      'date': date,
      'change_id': changeId,
      'text': text,
    },
  );

  /// `PATCH /feedback/{feedback_id} {text}`.
  @override
  Future<FeedbackRow> editComment({required String id, required String text}) =>
      _call(
        'PATCH',
        _feedback(id),
        parseFeedbackRow,
        operation: 'feedback edit',
        body: {'text': text},
      );

  /// `DELETE /feedback/{feedback_id}` (no body).
  @override
  Future<FeedbackRemoveResult> deleteComment({required String id}) => _call(
    'DELETE',
    _feedback(id),
    parseFeedbackRemoveResult,
    operation: 'feedback rm',
  );

  // ---------- reads ----------

  /// `GET /feedback?note_id=`.
  @override
  Future<List<FeedbackRow>> feedbackForNote(String noteId) => _call(
    'GET',
    '/feedback',
    parseFeedbackList,
    operation: 'feedback ls',
    query: {'note_id': noteId},
  );

  /// `GET /feedback` with no parameter: the no-note list.
  @override
  Future<List<FeedbackRow>> feedbackWithoutNote() =>
      _call('GET', '/feedback', parseFeedbackList, operation: 'feedback ls');

  // ---------- Vault Guide ----------

  /// `GET /guide`.
  @override
  Future<VaultGuide> guide() =>
      _call('GET', '/guide', parseVaultGuide, operation: 'guide get');

  /// `GET /guide/revisions`, in server order.
  @override
  Future<List<GuideRevisionRow>> guideRevisions() => _call(
    'GET',
    '/guide/revisions',
    parseGuideRevisions,
    operation: 'guide revisions',
  );

  /// `POST /guide/revisions/{revision_id}/restore`.
  @override
  Future<GuideRestoreResult> restoreGuide(String revisionId) => _call(
    'POST',
    '/guide/revisions/${Uri.encodeComponent(revisionId)}/restore',
    parseGuideRestoreResult,
    operation: 'guide restore',
  );
}
