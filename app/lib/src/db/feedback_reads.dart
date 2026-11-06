import 'dart:convert';

import '../db.dart';

/// Whether a [FeedbackRow] is a person's comment or a Correction.
enum FeedbackKind { comment, correction }

/// Who wrote a [FeedbackRow].
enum FeedbackSource { person, chat }

/// Whether the agent has handled a [FeedbackRow].
enum FeedbackStatus { open, handled }

/// What a Correction recorded, decoded from the Contract's `correction`
/// object (#256), one subclass per `kind`. F9 renders each kind.
sealed class FeedbackCorrection {
  const FeedbackCorrection();
}

/// `excerpt_moved`: a block moved from one topic to another.
class ExcerptMovedCorrection extends FeedbackCorrection {
  const ExcerptMovedCorrection({
    required this.date,
    required this.blockId,
    required this.preview,
    required this.fromTopicNoteId,
    required this.fromTitle,
    required this.toTopicNoteId,
    required this.toTitle,
  });
  final String date;
  final String blockId;
  final String preview;
  final String fromTopicNoteId;
  final String fromTitle;
  final String toTopicNoteId;
  final String toTitle;
}

/// `excerpt_removed`: one or more blocks removed from a topic.
class ExcerptRemovedCorrection extends FeedbackCorrection {
  const ExcerptRemovedCorrection({
    required this.date,
    required this.blockIds,
    required this.preview,
    required this.topicNoteId,
    required this.title,
  });
  final String date;
  final List<String> blockIds;
  final String preview;
  final String topicNoteId;
  final String title;
}

/// `excerpt_added`: a block filed under a topic.
class ExcerptAddedCorrection extends FeedbackCorrection {
  const ExcerptAddedCorrection({
    required this.date,
    required this.blockId,
    required this.preview,
    required this.topicNoteId,
    required this.title,
  });
  final String date;
  final String blockId;
  final String preview;
  final String topicNoteId;
  final String title;
}

/// `membership_removed`: a note removed from a Smart Folder.
class MembershipRemovedCorrection extends FeedbackCorrection {
  const MembershipRemovedCorrection({
    required this.noteId,
    required this.noteTitle,
    required this.smartFolderId,
    required this.folderName,
  });
  final String noteId;
  final String noteTitle;
  final String smartFolderId;
  final String folderName;
}

/// `folder_renamed`.
class FolderRenamedCorrection extends FeedbackCorrection {
  const FolderRenamedCorrection({
    required this.smartFolderId,
    required this.oldName,
    required this.newName,
  });
  final String smartFolderId;
  final String oldName;
  final String newName;
}

/// `folder_moved`: a null parent is the root.
class FolderMovedCorrection extends FeedbackCorrection {
  const FolderMovedCorrection({
    required this.smartFolderId,
    required this.name,
    required this.oldParentId,
    required this.newParentId,
  });
  final String smartFolderId;
  final String name;
  final String? oldParentId;
  final String? newParentId;
}

/// `folder_deleted`.
class FolderDeletedCorrection extends FeedbackCorrection {
  const FolderDeletedCorrection({
    required this.smartFolderId,
    required this.name,
  });
  final String smartFolderId;
  final String name;
}

/// `tag_removed`: [noteId] is null once the note was deleted (D7a);
/// [noteTitle] is the title stored when the Correction was written.
class TagRemovedCorrection extends FeedbackCorrection {
  const TagRemovedCorrection({
    required this.tag,
    required this.noteId,
    required this.noteTitle,
  });
  final String tag;
  final String? noteId;
  final String noteTitle;
}

/// One Feedback item: the Contract's `Feedback` object (#256). [id] is a
/// ULID, or `tag-<n>` for an unhandled tag Correction. Times are unix ms.
class FeedbackRow {
  const FeedbackRow({
    required this.id,
    required this.kind,
    required this.source,
    this.noteId,
    this.day,
    this.agentChangeId,
    this.text,
    this.correction,
    required this.status,
    this.reply,
    required this.createdAt,
    required this.updatedAt,
    this.handledAt,
  });

  final String id;
  final FeedbackKind kind;
  final FeedbackSource source;
  final String? noteId;
  final String? day;
  final String? agentChangeId;
  final String? text;
  final FeedbackCorrection? correction;
  final FeedbackStatus status;
  final String? reply;
  final int createdAt;
  final int updatedAt;
  final int? handledAt;
}

/// One `vault_guide_revisions` row as `memex guide revisions` lists it.
class GuideRevisionRow {
  const GuideRevisionRow({
    required this.id,
    required this.agentChangeId,
    required this.createdAt,
  });
  final String id;
  final String? agentChangeId;
  final int createdAt;
}

/// Decodes a Contract `correction` object (#256) into its typed value, or
/// null when [raw] is not an object, names an unknown `kind` or lacks a
/// field of its kind. Never throws: a Correction the app cannot render is
/// shown as a bare row.
FeedbackCorrection? decodeFeedbackCorrection(Object? raw) {
  if (raw is! Map) return null;
  return switch (raw) {
    {
      'kind': 'excerpt_moved',
      'date': final String date,
      'block_id': final String blockId,
      'preview': final String preview,
      'from_topic_note_id': final String fromTopicNoteId,
      'from_title': final String fromTitle,
      'to_topic_note_id': final String toTopicNoteId,
      'to_title': final String toTitle,
    } =>
      ExcerptMovedCorrection(
        date: date,
        blockId: blockId,
        preview: preview,
        fromTopicNoteId: fromTopicNoteId,
        fromTitle: fromTitle,
        toTopicNoteId: toTopicNoteId,
        toTitle: toTitle,
      ),
    {
      'kind': 'excerpt_removed',
      'date': final String date,
      'block_ids': final List<Object?> blockIds,
      'preview': final String preview,
      'topic_note_id': final String topicNoteId,
      'title': final String title,
    } =>
      ExcerptRemovedCorrection(
        date: date,
        blockIds: [for (final b in blockIds) '$b'],
        preview: preview,
        topicNoteId: topicNoteId,
        title: title,
      ),
    {
      'kind': 'excerpt_added',
      'date': final String date,
      'block_id': final String blockId,
      'preview': final String preview,
      'topic_note_id': final String topicNoteId,
      'title': final String title,
    } =>
      ExcerptAddedCorrection(
        date: date,
        blockId: blockId,
        preview: preview,
        topicNoteId: topicNoteId,
        title: title,
      ),
    {
      'kind': 'membership_removed',
      'note_id': final String noteId,
      'note_title': final String noteTitle,
      'smart_folder_id': final String smartFolderId,
      'folder_name': final String folderName,
    } =>
      MembershipRemovedCorrection(
        noteId: noteId,
        noteTitle: noteTitle,
        smartFolderId: smartFolderId,
        folderName: folderName,
      ),
    {
      'kind': 'folder_renamed',
      'smart_folder_id': final String smartFolderId,
      'old_name': final String oldName,
      'new_name': final String newName,
    } =>
      FolderRenamedCorrection(
        smartFolderId: smartFolderId,
        oldName: oldName,
        newName: newName,
      ),
    {
      'kind': 'folder_moved',
      'smart_folder_id': final String smartFolderId,
      'name': final String name,
      'old_parent_id': final String? oldParentId,
      'new_parent_id': final String? newParentId,
    } =>
      FolderMovedCorrection(
        smartFolderId: smartFolderId,
        name: name,
        oldParentId: oldParentId,
        newParentId: newParentId,
      ),
    {
      'kind': 'folder_deleted',
      'smart_folder_id': final String smartFolderId,
      'name': final String name,
    } =>
      FolderDeletedCorrection(smartFolderId: smartFolderId, name: name),
    {
      'kind': 'tag_removed',
      'tag': final String tag,
      'note_id': final String? noteId,
      'note_title': final String noteTitle,
    } =>
      TagRemovedCorrection(tag: tag, noteId: noteId, noteTitle: noteTitle),
    _ => null,
  };
}

/// Parses a Contract `Feedback` object (#256), or returns null when [raw]
/// is not an object, a required field is missing or mistyped, or `kind`,
/// `source` or `status` is not a known value. An undecodable `correction`
/// is not an error: it gives a null [FeedbackRow.correction].
FeedbackRow? parseFeedbackRow(Object? raw) {
  if (raw is! Map) return null;
  if (raw case {
    'id': final String id,
    'kind': final String kind,
    'source': final String source,
    'status': final String status,
    'created_at': final int createdAt,
    'updated_at': final int updatedAt,
  }) {
    final feedbackKind = FeedbackKind.values.asNameMap()[kind];
    final feedbackSource = FeedbackSource.values.asNameMap()[source];
    final feedbackStatus = FeedbackStatus.values.asNameMap()[status];
    final optionalsOk =
        const [
          'note_id',
          'day',
          'agent_change_id',
          'text',
          'reply',
        ].every((k) => raw[k] == null || raw[k] is String) &&
        (raw['handled_at'] == null || raw['handled_at'] is int);
    if (feedbackKind == null ||
        feedbackSource == null ||
        feedbackStatus == null ||
        !optionalsOk) {
      return null;
    }
    return FeedbackRow(
      id: id,
      kind: feedbackKind,
      source: feedbackSource,
      noteId: raw['note_id'] as String?,
      day: raw['day'] as String?,
      agentChangeId: raw['agent_change_id'] as String?,
      text: raw['text'] as String?,
      correction: decodeFeedbackCorrection(raw['correction']),
      status: feedbackStatus,
      reply: raw['reply'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      handledAt: raw['handled_at'] as int?,
    );
  }
  return null;
}

/// Feedback and Vault Guide revision reads (V6). Return an empty list on a
/// vault that lacks the V6 tables, never throw. Reads are synchronous.
extension FeedbackReads on VaultDb {
  /// [noteId]'s Feedback of every status plus its open tag Corrections,
  /// newest first.
  List<FeedbackRow> feedbackForNote(String noteId) {
    if (!hasTables(VaultDb.v6TableNames)) return const [];
    final feedback = db.select(
      'SELECT $_feedbackColumns FROM feedback WHERE note_id = ? '
      'ORDER BY created_at DESC, rowid DESC',
      [noteId],
    );
    final tags = db.select(
      '$_openTagCorrections AND t.note_id = ? '
      'ORDER BY t.created_at DESC, t.id DESC',
      [noteId],
    );
    return _mergeNewestFirst(
      [for (final r in feedback) _feedbackRow(r)],
      [for (final r in tags) _tagRow(r)],
    );
  }

  /// Feedback with no note, plus open tag Corrections whose note was deleted,
  /// newest first.
  List<FeedbackRow> feedbackWithoutNote() {
    if (!hasTables(VaultDb.v6TableNames)) return const [];
    final feedback = db.select(
      'SELECT $_feedbackColumns FROM feedback WHERE note_id IS NULL '
      'ORDER BY created_at DESC, rowid DESC',
    );
    final tags = db.select(
      '$_openTagCorrections AND t.note_id IS NULL '
      'ORDER BY t.created_at DESC, t.id DESC',
    );
    return _mergeNewestFirst(
      [for (final r in feedback) _feedbackRow(r)],
      [for (final r in tags) _tagRow(r)],
    );
  }

  /// The Vault Guide's revisions, newest first.
  List<GuideRevisionRow> guideRevisions() {
    if (!hasTables(VaultDb.v6TableNames)) return const [];
    final rows = db.select(
      'SELECT id, agent_change_id, created_at FROM vault_guide_revisions '
      'ORDER BY created_at DESC, rowid DESC',
    );
    return [
      for (final r in rows)
        GuideRevisionRow(
          id: r['id'] as String,
          agentChangeId: r['agent_change_id'] as String?,
          createdAt: (r['created_at'] as num).toInt(),
        ),
    ];
  }
}

const _feedbackColumns =
    'id, kind, source, note_id, day, agent_change_id, text, '
    'correction_json, status, reply, created_at, updated_at, handled_at';

/// Uncleared tag Corrections no handled `feedback` row links to (D4); the
/// caller appends a note filter and the ORDER BY.
const _openTagCorrections =
    'SELECT t.id, t.note_id, t.note_title, t.tag, t.created_at '
    'FROM tag_corrections t WHERE t.cleared_at IS NULL '
    'AND NOT EXISTS (SELECT 1 FROM feedback f '
    "WHERE f.tag_correction_id = t.id AND f.status = 'handled')";

FeedbackRow _feedbackRow(Map<String, Object?> r) => FeedbackRow(
  id: r['id'] as String,
  kind: FeedbackKind.values.byName(r['kind'] as String),
  source: FeedbackSource.values.byName(r['source'] as String),
  noteId: r['note_id'] as String?,
  day: r['day'] as String?,
  agentChangeId: r['agent_change_id'] as String?,
  text: r['text'] as String?,
  correction: _storedCorrection(r['correction_json']),
  status: FeedbackStatus.values.byName(r['status'] as String),
  reply: r['reply'] as String?,
  createdAt: (r['created_at'] as num).toInt(),
  updatedAt: (r['updated_at'] as num).toInt(),
  handledAt: (r['handled_at'] as num?)?.toInt(),
);

/// An open tag Correction as the `tag-<n>` Feedback item the Contract names.
FeedbackRow _tagRow(Map<String, Object?> r) {
  final createdAt = (r['created_at'] as num).toInt();
  return FeedbackRow(
    id: 'tag-${r['id']}',
    kind: FeedbackKind.correction,
    source: FeedbackSource.person,
    noteId: r['note_id'] as String?,
    correction: TagRemovedCorrection(
      tag: r['tag'] as String,
      noteId: r['note_id'] as String?,
      noteTitle: r['note_title'] as String,
    ),
    status: FeedbackStatus.open,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

FeedbackCorrection? _storedCorrection(Object? raw) {
  if (raw is! String) return null;
  try {
    return decodeFeedbackCorrection(jsonDecode(raw));
  } on FormatException {
    return null;
  }
}

/// [feedback] and [tags], each already newest first, merged by `createdAt`
/// newest first; on a tie the Feedback row comes first.
List<FeedbackRow> _mergeNewestFirst(
  List<FeedbackRow> feedback,
  List<FeedbackRow> tags,
) {
  final merged = <FeedbackRow>[];
  var f = 0;
  var t = 0;
  while (f < feedback.length && t < tags.length) {
    merged.add(
      tags[t].createdAt > feedback[f].createdAt ? tags[t++] : feedback[f++],
    );
  }
  merged
    ..addAll(feedback.skip(f))
    ..addAll(tags.skip(t));
  return merged;
}
