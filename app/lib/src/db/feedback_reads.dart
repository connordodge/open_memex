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

/// Feedback and Vault Guide revision reads (V6). Return an empty list on a
/// vault that lacks the V6 tables, never throw. Reads are synchronous.
extension FeedbackReads on VaultDb {
  /// [noteId]'s Feedback of every status plus its open tag Corrections,
  /// newest first.
  List<FeedbackRow> feedbackForNote(String noteId) => const [];

  /// Feedback with no note, plus open tag Corrections whose note was deleted,
  /// newest first.
  List<FeedbackRow> feedbackWithoutNote() => const [];

  /// The Vault Guide's revisions, newest first.
  List<GuideRevisionRow> guideRevisions() => const [];
}
