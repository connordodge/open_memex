import '../db.dart';

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
  String get persistedId => throw UnimplementedError();

  /// Parses [persistedId]; null for an unknown kind or a malformed value.
  static GraphScope? parse(String persistedId) => throw UnimplementedError();
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
GraphData buildGraph(VaultDb db, GraphScope scope) =>
    throw UnimplementedError();
