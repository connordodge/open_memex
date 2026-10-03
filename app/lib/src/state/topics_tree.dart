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
  bool get isEmpty =>
      folders.isEmpty && !unsorted.notes.any((n) => n.role == 'topic');
}

/// Builds the Topics tree from the Smart Folder reads (pure, no I/O).
///
/// Independent of the input order. Every level sorts case-insensitively by
/// name / title, ties broken by id so the order is stable. A folder whose
/// parent is not in [data] is treated as a root. Daily notes never appear.
TopicsTree buildTopicsTree(
  SmartFolderData data,
  List<UnsortedNoteRow> unsorted,
) {
  final ids = {for (final f in data.folders) f.id};
  final childrenOf = <String?, List<SmartFolderRow>>{};
  for (final f in data.folders) {
    final parent = ids.contains(f.parentId) ? f.parentId : null;
    (childrenOf[parent] ??= []).add(f);
  }
  final membersOf = <String, List<SmartFolderMemberRow>>{};
  for (final m in data.members) {
    (membersOf[m.folderId] ??= []).add(m);
  }

  List<FolderNode> build(String? parent, int depth) {
    final rows = [...?childrenOf[parent]]
      ..sort((a, b) => _byLabel(a.name, a.id, b.name, b.id));
    return [
      for (final f in rows)
        FolderNode(
          id: f.id,
          name: f.name,
          pinned: f.pinned,
          depth: depth,
          children: build(f.id, depth + 1),
          topics:
              ([...?membersOf[f.id]]..sort(
                    (a, b) => _byLabel(a.title, a.noteId, b.title, b.noteId),
                  ))
                  .map(
                    (m) => TopicNode(
                      noteId: m.noteId,
                      title: m.title,
                      pinned: m.pinned,
                    ),
                  )
                  .toList(),
        ),
    ];
  }

  final loose = [
    for (final n in unsorted)
      if (n.role != 'daily') n,
  ]..sort((a, b) => _byLabel(a.title, a.noteId, b.title, b.noteId));

  return TopicsTree(
    folders: build(null, 0),
    unsorted: UnsortedNode(notes: loose),
  );
}

int _byLabel(String a, String aId, String b, String bId) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : aId.compareTo(bId);
}
