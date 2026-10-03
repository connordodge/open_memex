import '../db.dart';
import '../db/daily_reads.dart';
import '../db/graph_reads.dart';
import '../db/topics_reads.dart';

/// Where a Graph view was opened from (Req 64). Persisted in `ui_state.json`
/// as `<kind>:<id>` (D26): `folder:<smartFolderId>`, `topic:<noteId>`,
/// `day:<noteId>`, `vault:all`.
enum GraphScopeKind { folder, topic, day, vault }

/// The scope of one Graph view.
class GraphScope {
  /// A Smart Folder: its members and the members of its descendant folders.
  const GraphScope.folder(String smartFolderId)
    : kind = GraphScopeKind.folder,
      id = smartFolderId;

  /// A topic note: the topic, its 1-hop neighbours and the daily notes it
  /// transcludes.
  const GraphScope.topic(String noteId)
    : kind = GraphScopeKind.topic,
      id = noteId;

  /// A daily note: the day, its footer topics and the topics that
  /// transclude it.
  const GraphScope.day(String noteId) : kind = GraphScopeKind.day, id = noteId;

  /// Every note and every link (off the default path).
  const GraphScope.vault() : kind = GraphScopeKind.vault, id = 'all';

  final GraphScopeKind kind;

  /// The Smart Folder id, the note id, or `all` for the vault scope.
  final String id;

  /// `<kind>:<id>`, e.g. `topic:<noteId>` or `vault:all` (D26).
  String get persistedId => '${kind.name}:$id';

  /// Parses [persistedId]; null for an unknown kind or a malformed value.
  static GraphScope? parse(String persistedId) {
    final match = _persistedPattern.firstMatch(persistedId);
    return switch ((match?.group(1), match?.group(2))) {
      ('folder', final String id) => GraphScope.folder(id),
      ('topic', final String id) => GraphScope.topic(id),
      ('day', final String id) => GraphScope.day(id),
      ('vault', 'all') => const GraphScope.vault(),
      _ => null,
    };
  }

  /// `<kind>:<id>` with a non-empty id; the id may itself contain colons.
  static final _persistedPattern = RegExp(r'^([a-z]+):(.+)$');

  @override
  bool operator ==(Object other) =>
      other is GraphScope && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'GraphScope($persistedId)';
}

/// Node kind by note role: `daily` for `role: daily`, `topic` for
/// `role: topic`, `note` otherwise.
enum GraphNodeKind { daily, topic, note }

class GraphNode {
  const GraphNode({
    required this.id,
    required this.kind,
    required this.label,
    required this.pinned,
  });

  /// The note id.
  final String id;
  final GraphNodeKind kind;

  /// The date for a daily note, otherwise the note title.
  final String label;

  /// True when any of the note's Smart Folder memberships is pinned.
  final bool pinned;
}

/// One link (`links` row with a target) between two nodes in scope.
class GraphEdge {
  const GraphEdge({
    required this.from,
    required this.to,
    required this.kind,
    required this.label,
  });

  final String from;
  final String to;

  /// `links.link_kind`, e.g. `references`, `extends`, `from-day`, `about`.
  final String kind;
  final String? label;
}

/// A Smart Folder drawn as a soft background hull behind its member nodes.
class GraphHull {
  const GraphHull({
    required this.folderId,
    required this.name,
    required this.pinned,
    required this.memberIds,
  });

  final String folderId;
  final String name;

  /// `smart_folders.pinned`.
  final bool pinned;

  /// The folder's direct members that are nodes in scope.
  final List<String> memberIds;
}

class GraphData {
  const GraphData({
    required this.nodes,
    required this.edges,
    required this.hulls,
  });

  static const empty = GraphData(nodes: [], edges: [], hulls: []);

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final List<GraphHull> hulls;
}

/// The nodes, edges and hulls of [scope] in [db] (Req 64). Pure: reads only,
/// no positions. V5-only data (Smart Folders, footer chips) is empty on a
/// vault below V5; never throws for a missing scope target.
GraphData buildGraph(VaultDb db, GraphScope scope) {
  final notes = db.graphNotes();
  final links = db.graphLinks();
  final folders = db.smartFolders();
  final id = scope.id;

  final Set<String> wanted = switch (scope.kind) {
    GraphScopeKind.folder => _folderMembers(folders, id),
    GraphScopeKind.topic => {
      id,
      for (final l in links)
        if (l.from == id) l.to,
      for (final l in links)
        if (l.to == id) l.from,
    },
    GraphScopeKind.day => {
      id,
      for (final chip in db.footerChips(id)) chip.topicNoteId,
      for (final l in links)
        if (l.to == id && l.kind == _fromDay) l.from,
    },
    GraphScopeKind.vault => {for (final n in notes) n.id},
  };

  final pinned = {
    for (final m in folders.members)
      if (m.pinned) m.noteId,
  };
  final nodes = [
    for (final n in notes)
      if (wanted.contains(n.id))
        GraphNode(
          id: n.id,
          kind: _kindOf(n.role),
          label: n.title,
          pinned: pinned.contains(n.id),
        ),
  ];
  final inScope = {for (final n in nodes) n.id};
  final edges = [
    for (final l in links)
      if (inScope.contains(l.from) && inScope.contains(l.to))
        GraphEdge(from: l.from, to: l.to, kind: l.kind, label: l.label),
  ];
  final hulls = <GraphHull>[];
  final byName = [...folders.folders]..sort((a, b) => a.name.compareTo(b.name));
  for (final f in byName) {
    final memberIds = [
      for (final m in folders.members)
        if (m.folderId == f.id && inScope.contains(m.noteId)) m.noteId,
    ];
    if (memberIds.isEmpty) continue;
    hulls.add(
      GraphHull(
        folderId: f.id,
        name: f.name,
        pinned: f.pinned,
        memberIds: memberIds,
      ),
    );
  }
  return GraphData(nodes: nodes, edges: edges, hulls: hulls);
}

/// The built-in link kind a topic's transclusion of a day writes.
const _fromDay = 'from-day';

GraphNodeKind _kindOf(String? role) => switch (role) {
  'daily' => GraphNodeKind.daily,
  'topic' => GraphNodeKind.topic,
  _ => GraphNodeKind.note,
};

/// The members of folder [rootId] and of every folder below it. Empty for
/// an unknown folder; a parent cycle cannot loop.
Set<String> _folderMembers(SmartFolderData data, String rootId) {
  final subtree = <String>{};
  final pending = [rootId];
  while (pending.isNotEmpty) {
    final next = pending.removeLast();
    if (!subtree.add(next)) continue;
    for (final f in data.folders) {
      if (f.parentId == next) pending.add(f.id);
    }
  }
  return {
    for (final m in data.members)
      if (subtree.contains(m.folderId)) m.noteId,
  };
}
