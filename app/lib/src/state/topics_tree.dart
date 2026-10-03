import '../db/topics_reads.dart';

/// One topic row under a Smart Folder. [pinned] is the membership's flag.
class TopicNode {
  const TopicNode({
    required this.noteId,
    required this.title,
    required this.pinned,
  });

  final String noteId;
  final String title;
  final bool pinned;
}

/// One Smart Folder in the Topics tree. [depth] is 0 for a root folder and
/// grows by one per parent; [children] are its subfolders and [topics] its
/// member notes, each sorted by name / title, case-insensitively.
class FolderNode {
  const FolderNode({
    required this.id,
    required this.name,
    required this.pinned,
    required this.depth,
    required this.children,
    required this.topics,
  });

  final String id;
  final String name;
  final bool pinned;
  final int depth;
  final List<FolderNode> children;
  final List<TopicNode> topics;
}

/// The implicit `Unsorted` group: every non-daily note in no Smart Folder,
/// sorted by title case-insensitively.
class UnsortedNode {
  const UnsortedNode({required this.notes});

  final List<UnsortedNoteRow> notes;
}

/// The Topics tree: root [folders] sorted by name, then [unsorted].
class TopicsTree {
  const TopicsTree({required this.folders, required this.unsorted});

  final List<FolderNode> folders;
  final UnsortedNode unsorted;

  /// True when the Topics empty state applies: no Smart Folders and no
  /// `role: topic` note.
  bool get isEmpty => throw UnimplementedError();
}

/// Builds the Topics tree from the Smart Folder reads (pure, no I/O).
TopicsTree buildTopicsTree(
  SmartFolderData data,
  List<UnsortedNoteRow> unsorted,
) => throw UnimplementedError();
