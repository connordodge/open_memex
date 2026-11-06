import 'dart:convert';

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

/// The parsed `memex excerpt add` / `remove-block` result (#256).
class ExcerptEditResult {
  const ExcerptEditResult({
    required this.vaultId,
    required this.topicNoteId,
    required this.version,
  });
  final String vaultId;
  final String topicNoteId;

  /// The topic note's new `notes.version`.
  final int version;
}

/// The parsed `memex excerpt move` result (#256).
class ExcerptMoveResult {
  const ExcerptMoveResult({
    required this.vaultId,
    required this.fromTopicNoteId,
    required this.fromVersion,
    required this.toTopicNoteId,
    required this.toVersion,
  });
  final String vaultId;
  final String fromTopicNoteId;
  final int fromVersion;
  final String toTopicNoteId;
  final int toVersion;
}

/// `memex excerpt add|remove-block|move` wrappers (#256). Every `--note`
/// is optional and left out when null.
extension ExcerptFilingCli on MemexCli {
  /// `memex excerpt add --vault V --topic-note-id T --date D --block-id B
  /// [--note TEXT]`.
  Future<ExcerptEditResult> addExcerpt({
    required String vaultPath,
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _call(this, 'excerpt add', [
    'excerpt',
    'add',
    '--vault',
    vaultPath,
    '--topic-note-id',
    topicNoteId,
    '--date',
    date,
    '--block-id',
    blockId,
    if (note != null) ...['--note', note],
  ], parseExcerptEditResult);

  /// `memex excerpt remove-block --vault V --topic-note-id T --date D
  /// --block-id B [--note TEXT]`.
  Future<ExcerptEditResult> removeExcerptBlock({
    required String vaultPath,
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _call(this, 'excerpt remove-block', [
    'excerpt',
    'remove-block',
    '--vault',
    vaultPath,
    '--topic-note-id',
    topicNoteId,
    '--date',
    date,
    '--block-id',
    blockId,
    if (note != null) ...['--note', note],
  ], parseExcerptEditResult);

  /// `memex excerpt move --vault V --date D --block-id B --from-topic-note-id
  /// A --to-topic-note-id C [--note TEXT]`.
  Future<ExcerptMoveResult> moveExcerptBlock({
    required String vaultPath,
    required String date,
    required String blockId,
    required String fromTopicNoteId,
    required String toTopicNoteId,
    String? note,
  }) => _call(this, 'excerpt move', [
    'excerpt',
    'move',
    '--vault',
    vaultPath,
    '--date',
    date,
    '--block-id',
    blockId,
    '--from-topic-note-id',
    fromTopicNoteId,
    '--to-topic-note-id',
    toTopicNoteId,
    if (note != null) ...['--note', note],
  ], parseExcerptMoveResult);
}

/// The [ExcerptEditResult] of `{vault_id, topic_note_id, version}`, or null.
/// Shared by the CLI and the hosted route.
ExcerptEditResult? parseExcerptEditResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'topic_note_id': final String topicNoteId,
    'version': final int version,
  }) {
    return ExcerptEditResult(
      vaultId: vaultId,
      topicNoteId: topicNoteId,
      version: version,
    );
  }
  return null;
}

/// The [ExcerptMoveResult] of `memex excerpt move` stdout, or null.
ExcerptMoveResult? parseExcerptMoveResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'from_topic_note_id': final String fromTopicNoteId,
    'from_version': final int fromVersion,
    'to_topic_note_id': final String toTopicNoteId,
    'to_version': final int toVersion,
  }) {
    return ExcerptMoveResult(
      vaultId: vaultId,
      fromTopicNoteId: fromTopicNoteId,
      fromVersion: fromVersion,
      toTopicNoteId: toTopicNoteId,
      toVersion: toVersion,
    );
  }
  return null;
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
    final r = await run([
      'excerpt',
      'rm',
      '--vault',
      vaultPath,
      '--topic-note-id',
      topicNoteId,
      '--date',
      date,
      '--block-ids',
      toBlockId == null ? fromBlockId : '$fromBlockId,$toBlockId',
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('excerpt rm', r);
    }
    Object? json;
    try {
      json = jsonDecode(r.stdout.trim());
    } on FormatException {
      json = null;
    }
    final map = json is Map<String, Object?> ? json : null;
    final vaultId = map?['vault_id'];
    final noteId = map?['topic_note_id'];
    final version = map?['version'];
    if (vaultId is! String || noteId is! String || version is! int) {
      throw MemexException('excerpt rm: could not parse output: ${r.stdout}');
    }
    return ExcerptRemoveResult(
      vaultId: vaultId,
      topicNoteId: noteId,
      version: version,
    );
  }
}
