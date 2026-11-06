// WI #70 (W0a): structural comparison of vault rows and CLI results. The
// production row classes have no `==`, so tests compare these shapes.
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/cli/footer_cli.dart';
import 'package:open_memex_app/src/cli/note_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/cli/feedback_cli.dart';
import 'package:open_memex_app/src/cli/guide_cli.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';

/// [v] as plain lists, maps and primitives, field by field, so two results
/// compare with `equals`. Throws for a type it doesn't know, so a new return
/// type can't silently compare as equal.
Object? vaultAccessShape(Object? v) => switch (v) {
  null || String() || num() || bool() => v,
  List() => [for (final e in v) vaultAccessShape(e)],
  Map() => {for (final e in v.entries) '${e.key}': vaultAccessShape(e.value)},
  ReviewState() => v.name,
  NoteListItem() => {
    'NoteListItem': [v.id, v.title, v.snippet, v.version, v.updatedAt],
  },
  Note() => {
    'Note': [
      v.id,
      v.title,
      v.contentMd,
      v.frontmatter,
      v.version,
      v.createdAt,
      v.updatedAt,
      v.tags,
      v.footerTags,
    ],
  },
  NoteTitle() => {
    'NoteTitle': [v.id, v.title, v.updatedAt],
  },
  LinkRow() => {
    'LinkRow': [
      v.id,
      v.fromNoteId,
      v.toNoteId,
      v.linkText,
      v.kind,
      v.label,
      v.position,
      v.source,
    ],
  },
  CanvasRow() => {
    'CanvasRow': [
      v.canvasId,
      v.title,
      v.createdAt,
      v.updatedAt,
      v.version,
      v.nodeCount,
    ],
  },
  CanvasNodeRow() => {
    'CanvasNodeRow': [v.noteId, v.noteTitle, v.x, v.y, v.zOrder, v.placedAt],
  },
  CanvasEdgeRow() => {
    'CanvasEdgeRow': [
      v.linkId,
      v.fromNoteId,
      v.toNoteId,
      v.linkText,
      v.kind,
      v.label,
      v.position,
      v.source,
    ],
  },
  CanvasDetailRow() => {
    'CanvasDetailRow': [
      v.canvasId,
      v.title,
      v.createdAt,
      v.updatedAt,
      v.version,
      vaultAccessShape(v.nodes),
      vaultAccessShape(v.edges),
    ],
  },
  DailyNoteRow() => {
    'DailyNoteRow': [v.date, v.noteId, v.preview, v.reviewState.name],
  },
  ReviewInfo() => {
    'ReviewInfo': [v.state.name, v.reviewedAt],
  },
  BlockRow() => {
    'BlockRow': [
      v.blockId,
      v.ord,
      v.text,
      v.source,
      v.createdVersion,
      v.createdAt,
      v.startByte,
      v.endByte,
    ],
  },
  FooterChipRow() => {
    'FooterChipRow': [v.topicNoteId, v.topicTitle, v.origin],
  },
  SmartFolderData() => {
    'SmartFolderData': [
      vaultAccessShape(v.folders),
      vaultAccessShape(v.members),
    ],
  },
  SmartFolderRow() => {
    'SmartFolderRow': [v.id, v.name, v.parentId, v.pinned],
  },
  SmartFolderMemberRow() => {
    'SmartFolderMemberRow': [v.folderId, v.noteId, v.title, v.pinned],
  },
  UnsortedNoteRow() => {
    'UnsortedNoteRow': [v.noteId, v.title, v.role],
  },
  GraphNoteRow() => {
    'GraphNoteRow': [v.id, v.title, v.role],
  },
  GraphLinkRow() => {
    'GraphLinkRow': [v.from, v.to, v.kind, v.label],
  },
  AgentChangeRow() => {
    'AgentChangeRow': [v.id, v.noteId, v.day, v.createdAt, v.bullets],
  },
  NoteUpdateResult() => {
    'NoteUpdateResult': [v.noteId, v.version, v.updatedAt],
  },
  NoteDeleteResult() => {
    'NoteDeleteResult': [v.vaultId, v.noteId, v.deleted],
  },
  AddLinkResult() => {
    'AddLinkResult': [
      v.linkId,
      v.fromNoteId,
      v.toNoteId,
      v.kind,
      v.source,
      v.wasExisting,
      v.noteVersion,
    ],
  },
  UpdateLinkResult() => {
    'UpdateLinkResult': [
      v.linkId,
      v.fromNoteId,
      v.toNoteId,
      v.kind,
      v.label,
      v.source,
      v.position,
    ],
  },
  FooterAddResult() => {
    'FooterAddResult': [
      v.vaultId,
      v.dailyNoteId,
      v.topicNoteId,
      v.origin,
      v.version,
    ],
  },
  ExcerptRemoveResult() => {
    'ExcerptRemoveResult': [v.vaultId, v.topicNoteId, v.version],
  },
  SmartFolderResult() => {
    'SmartFolderResult': [
      v.vaultId,
      v.id,
      v.name,
      v.parentId,
      v.pinned,
      v.depth,
      v.createdAt,
      v.updatedAt,
    ],
  },
  FolderDeleteResult() => {
    'FolderDeleteResult': [v.vaultId, v.id, v.deleted],
  },
  FolderMembershipResult() => {
    'FolderMembershipResult': [
      v.vaultId,
      v.smartFolderId,
      v.noteId,
      v.pinned,
      v.roleSet,
    ],
  },
  CanvasInfo() => {
    'CanvasInfo': [v.canvasId, v.title, v.version, v.createdAt, v.updatedAt],
  },
  CanvasNodeInfo() => {
    'CanvasNodeInfo': [
      v.canvasId,
      v.noteId,
      v.noteTitle,
      v.x,
      v.y,
      v.zOrder,
      v.placedAt,
    ],
  },
  MemexException() => {
    'MemexException': [
      v.message,
      v.kind.name,
      v.code,
      vaultAccessShape(v.fields),
    ],
  },
  TagRow() => {
    'TagRow': [v.tag, v.noteCount, v.system],
  },
  TagNoteRow() => {
    'TagNoteRow': [v.noteId, v.title, v.role, v.firstLine, v.updatedAt],
  },
  TagAddResult() => {
    'TagAddResult': [v.noteId, v.tag, v.origin, v.changed, v.version],
  },
  TagRmResult() => {
    'TagRmResult': [v.noteId, v.tag, v.removed, v.correctionId, v.version],
  },
  FolderMemberRemoveResult() => {
    'FolderMemberRemoveResult': [
      v.vaultId,
      v.smartFolderId,
      v.noteId,
      v.removed,
    ],
  },
  ExcerptEditResult() => {
    'ExcerptEditResult': [v.vaultId, v.topicNoteId, v.version],
  },
  ExcerptMoveResult() => {
    'ExcerptMoveResult': [
      v.vaultId,
      v.fromTopicNoteId,
      v.fromVersion,
      v.toTopicNoteId,
      v.toVersion,
    ],
  },
  FilingBlock() => {
    'FilingBlock': [v.id, v.text],
  },
  FilingTopic() => {
    'FilingTopic': [v.topicNoteId, v.title, vaultAccessShape(v.blocks)],
  },
  Filing() => {
    'Filing': [
      v.vaultId,
      v.date,
      v.noteId,
      v.reviewed,
      vaultAccessShape(v.topics),
      vaultAccessShape(v.notFiled),
    ],
  },
  FeedbackRemoveResult() => {
    'FeedbackRemoveResult': [v.vaultId, v.id],
  },
  VaultGuide() => {
    'VaultGuide': [v.vaultId, v.noteId, v.version, v.contentMd],
  },
  GuideRestoreResult() => {
    'GuideRestoreResult': [v.vaultId, v.noteId, v.version],
  },
  GuideRevisionRow() => {
    'GuideRevisionRow': [v.id, v.agentChangeId, v.createdAt],
  },
  FeedbackRow() => {
    'FeedbackRow': [
      v.id,
      v.kind.name,
      v.source.name,
      v.noteId,
      v.day,
      v.agentChangeId,
      v.text,
      vaultAccessShape(v.correction),
      v.status.name,
      v.reply,
      v.createdAt,
      v.updatedAt,
      v.handledAt,
    ],
  },
  ExcerptMovedCorrection() => {
    'ExcerptMovedCorrection': [
      v.date,
      v.blockId,
      v.preview,
      v.fromTopicNoteId,
      v.fromTitle,
      v.toTopicNoteId,
      v.toTitle,
    ],
  },
  ExcerptRemovedCorrection() => {
    'ExcerptRemovedCorrection': [
      v.date,
      v.blockIds,
      v.preview,
      v.topicNoteId,
      v.title,
    ],
  },
  ExcerptAddedCorrection() => {
    'ExcerptAddedCorrection': [
      v.date,
      v.blockId,
      v.preview,
      v.topicNoteId,
      v.title,
    ],
  },
  MembershipRemovedCorrection() => {
    'MembershipRemovedCorrection': [
      v.noteId,
      v.noteTitle,
      v.smartFolderId,
      v.folderName,
    ],
  },
  FolderRenamedCorrection() => {
    'FolderRenamedCorrection': [v.smartFolderId, v.oldName, v.newName],
  },
  FolderMovedCorrection() => {
    'FolderMovedCorrection': [
      v.smartFolderId,
      v.name,
      v.oldParentId,
      v.newParentId,
    ],
  },
  FolderDeletedCorrection() => {
    'FolderDeletedCorrection': [v.smartFolderId, v.name],
  },
  TagRemovedCorrection() => {
    'TagRemovedCorrection': [v.tag, v.noteId, v.noteTitle],
  },
  _ => throw ArgumentError('vaultAccessShape: unknown type ${v.runtimeType}'),
};
