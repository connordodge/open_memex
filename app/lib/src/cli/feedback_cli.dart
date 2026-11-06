import 'dart:convert';

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

/// The [Filing] of a Contract `Filing` object, or null when [json] is not
/// that shape. Shared by the CLI and the hosted route.
Filing? parseFiling(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'date': final String date,
    'note_id': final String noteId,
    'reviewed': final bool reviewed,
    'topics': final List<Object?> topics,
    'not_filed': final List<Object?> notFiled,
  }) {
    final parsedTopics = <FilingTopic>[];
    for (final t in topics) {
      if (t case {
        'topic_note_id': final String topicNoteId,
        'title': final String title,
        'blocks': final List<Object?> blocks,
      }) {
        final parsed = _filingBlocks(blocks);
        if (parsed == null) return null;
        parsedTopics.add(
          FilingTopic(topicNoteId: topicNoteId, title: title, blocks: parsed),
        );
      } else {
        return null;
      }
    }
    final parsedNotFiled = _filingBlocks(notFiled);
    if (parsedNotFiled == null) return null;
    return Filing(
      vaultId: vaultId,
      date: date,
      noteId: noteId,
      reviewed: reviewed,
      topics: parsedTopics,
      notFiled: parsedNotFiled,
    );
  }
  return null;
}

List<FilingBlock>? _filingBlocks(List<Object?> blocks) {
  final parsed = <FilingBlock>[];
  for (final b in blocks) {
    if (b case {'id': final String id, 'text': final String text}) {
      parsed.add(FilingBlock(id: id, text: text));
    } else {
      return null;
    }
  }
  return parsed;
}

/// The [FeedbackRemoveResult] of `{vault_id, id}`, or null.
FeedbackRemoveResult? parseFeedbackRemoveResult(Map<String, Object?> json) {
  if (json case {'vault_id': final String vaultId, 'id': final String id}) {
    return FeedbackRemoveResult(vaultId: vaultId, id: id);
  }
  return null;
}

/// The rows of `{vault_id, feedback: [Feedback]}` in order, or null when
/// the shape is wrong or any row is not a Contract `Feedback`.
List<FeedbackRow>? parseFeedbackList(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String _,
    'feedback': final List<Object?> rows,
  }) {
    final parsed = <FeedbackRow>[];
    for (final r in rows) {
      final row = parseFeedbackRow(r);
      if (row == null) return null;
      parsed.add(row);
    }
    return parsed;
  }
  return null;
}

/// `memex filing` and `memex feedback add|edit|rm|ls` wrappers (#256).
///
/// A CLI failure throws [MemexException] with the C1 `code`; stdout that is
/// not the Contract shape throws a [MemexException] with a null code.
extension FeedbackCli on MemexCli {
  /// `memex filing --vault V --date D`.
  Future<Filing> filing({required String vaultPath, required String date}) =>
      _call(this, 'filing', [
        'filing',
        '--vault',
        vaultPath,
        '--date',
        date,
      ], parseFiling);

  /// `memex feedback add --vault V --note-id N --date D --change-id C
  /// --text TEXT`.
  Future<FeedbackRow> addFeedback({
    required String vaultPath,
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) => _call(this, 'feedback add', [
    'feedback',
    'add',
    '--vault',
    vaultPath,
    '--note-id',
    noteId,
    '--date',
    date,
    '--change-id',
    changeId,
    '--text',
    text,
  ], parseFeedbackRow);

  /// `memex feedback edit --vault V --id F --text TEXT`.
  Future<FeedbackRow> editFeedback({
    required String vaultPath,
    required String id,
    required String text,
  }) => _call(this, 'feedback edit', [
    'feedback',
    'edit',
    '--vault',
    vaultPath,
    '--id',
    id,
    '--text',
    text,
  ], parseFeedbackRow);

  /// `memex feedback rm --vault V --id F`.
  Future<FeedbackRemoveResult> removeFeedback({
    required String vaultPath,
    required String id,
  }) => _call(this, 'feedback rm', [
    'feedback',
    'rm',
    '--vault',
    vaultPath,
    '--id',
    id,
  ], parseFeedbackRemoveResult);

  /// `memex feedback ls --vault V --note-id N`, or `--no-note` when
  /// [noteId] is null. All statuses, newest first.
  Future<List<FeedbackRow>> listFeedback({
    required String vaultPath,
    String? noteId,
  }) => _call(this, 'feedback ls', [
    'feedback',
    'ls',
    '--vault',
    vaultPath,
    if (noteId == null) '--no-note' else ...['--note-id', noteId],
  ], parseFeedbackList);
}

/// Runs [args], throws the C1 error of a failure, and returns what [parse]
/// makes of the JSON object on stdout; [parse] returning null (or stdout that
/// is not a JSON object) throws a null-code [MemexException].
Future<T> _call<T extends Object>(
  MemexCli cli,
  String operation,
  List<String> args,
  T? Function(Map<String, Object?> json) parse,
) async {
  final r = await cli.run(args);
  if (r.exitCode != 0) throw MemexException.fromCliFailure(operation, r);
  Object? json;
  try {
    json = jsonDecode(r.stdout.trim());
  } on FormatException {
    json = null;
  }
  final result = json is Map<String, Object?> ? parse(json) : null;
  if (result == null) {
    throw MemexException('$operation: could not parse output: ${r.stdout}');
  }
  return result;
}
