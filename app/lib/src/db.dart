import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Read-only access to the vault's SQLite file from Dart. All writes go
/// through the `memex` CLI to keep indexing/embedding logic in one place.
class VaultDb {
  VaultDb._(this.db);

  /// Wrap an already-open [Database] (an in-memory test database, or a
  /// handle opened elsewhere). The caller keeps ownership semantics: [close]
  /// still disposes it.
  VaultDb.fromDatabase(this.db);

  /// Tables added by schema V5 (daily notes, review, Smart Folders, vault
  /// settings). V5 reads return empty while any of them is missing.
  static const v5TableNames = <String>[
    'blocks',
    'day_reviews',
    'day_review_blocks',
    'footer_chips',
    'agent_changes',
    'smart_folders',
    'smart_folder_members',
    'vault_settings',
  ];

  final Database db;

  static VaultDb open(String vaultPath) {
    final dbPath = p.join(vaultPath, 'memex.db');
    if (!File(dbPath).existsSync()) {
      throw VaultDbException('No vault database at $dbPath');
    }
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    return VaultDb._(db);
  }

  void close() {
    db.dispose();
  }

  String vaultId(String vaultPath) {
    final manifestPath = p.join(vaultPath, 'manifest.json');
    final raw = File(manifestPath).readAsStringSync();
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m['vault_id'] as String;
  }

  List<NoteListItem> listNotes({int limit = 200}) {
    final rows = db.select(
      'SELECT id, title, content_md, version, updated_at FROM notes ORDER BY updated_at DESC LIMIT ?',
      [limit],
    );
    return rows
        .map(
          (r) => NoteListItem(
            id: r['id'] as String,
            title: r['title'] as String,
            snippet: _snippet(r['content_md'] as String),
            version: (r['version'] as num).toInt(),
            updatedAt: (r['updated_at'] as num).toInt(),
          ),
        )
        .toList();
  }

  Note? getNote(String id) {
    final rows = db.select(
      'SELECT id, title, content_md, frontmatter, version, created_at, updated_at FROM notes WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final tags = db
        .select('SELECT tag FROM tags WHERE note_id = ? ORDER BY tag', [id])
        .map((row) => row['tag'] as String)
        .toList();
    return Note(
      id: r['id'] as String,
      title: r['title'] as String,
      contentMd: r['content_md'] as String,
      frontmatter: r['frontmatter'] as String,
      version: (r['version'] as num).toInt(),
      createdAt: (r['created_at'] as num).toInt(),
      updatedAt: (r['updated_at'] as num).toInt(),
      tags: tags,
    );
  }

  /// All notes' (id, title) pairs. Used for the wikilink autocomplete and
  /// the kind-chip "More…" picker.
  List<NoteTitle> allTitles({int limit = 1000}) {
    final rows = db.select(
      'SELECT id, title, updated_at FROM notes ORDER BY updated_at DESC LIMIT ?',
      [limit],
    );
    return rows
        .map(
          (r) => NoteTitle(
            id: r['id'] as String,
            title: r['title'] as String,
            updatedAt: (r['updated_at'] as num).toInt(),
          ),
        )
        .toList();
  }

  /// Outgoing links for a note, ordered by position.
  List<LinkRow> linksOutFor(String noteId) {
    final rows = db.select(
      'SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source '
      'FROM links WHERE from_note_id = ? ORDER BY position',
      [noteId],
    );
    return rows.map(_rowToLink).toList();
  }

  /// Incoming links for a note, optionally filtered by kind. Joined with
  /// notes so the source title is available.
  List<LinkRow> linksInFor(String noteId, {String? kind}) {
    final whereKind = kind != null ? ' AND link_kind = ?' : '';
    final args = <Object?>[noteId];
    if (kind != null) args.add(kind);
    final rows = db.select(
      'SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source '
      'FROM links WHERE to_note_id = ?$whereKind '
      'ORDER BY link_kind, from_note_id, position',
      args,
    );
    return rows.map(_rowToLink).toList();
  }

  /// Map of note_id → title for a list of ids. Used to enrich link rows
  /// with the source/target's display title.
  Map<String, String> titlesForIds(List<String> ids) {
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = db.select(
      'SELECT id, title FROM notes WHERE id IN ($placeholders)',
      ids,
    );
    return {for (final r in rows) r['id'] as String: r['title'] as String};
  }

  /// All distinct kinds present in the vault's links table. Used by the
  /// kind chip's "More…" picker.
  List<String> distinctLinkKinds() {
    final rows = db.select(
      'SELECT DISTINCT link_kind FROM links ORDER BY link_kind',
    );
    return rows.map((r) => r['link_kind'] as String).toList();
  }

  /// True when every table in [names] exists in this database. Never caches
  /// a negative answer: the CLI may migrate the vault (V4 → V5) while the
  /// app holds this handle, and a re-probe must see the new tables.
  bool hasTables(List<String> names) {
    final placeholders = List.filled(names.length, '?').join(',');
    final row = db.select(
      "SELECT COUNT(DISTINCT name) AS n FROM sqlite_master "
      "WHERE type = 'table' AND name IN ($placeholders)",
      names,
    );
    return (row.first['n'] as int) == names.toSet().length;
  }

  /// The vault's schema version, `MAX(schema_version.version)`; 0 when the
  /// table is missing or empty. Read fresh on every call (the CLI may migrate
  /// the vault while this handle is open).
  int schemaVersion() {
    if (!hasTables(const ['schema_version'])) return 0;
    final row = db.select('SELECT MAX(version) AS v FROM schema_version');
    return (row.first['v'] as num?)?.toInt() ?? 0;
  }

  /// The local vault revision (D9, Req 22): `<handle instance id>-<data_version>`,
  /// where data_version is this handle's `PRAGMA data_version`. It changes
  /// after another connection (the CLI) commits a write, stays the same while
  /// nothing is written, and differs between two handles (the value resets
  /// when the handle is reopened, so the instance id keeps it unique).
  String dataVersion() {
    // RED SKELETON (#70 test author): placeholder; the implementer writes it.
    return '';
  }

  // ---------- canvas reads ----------

  /// True if the canvas layer (V4 migration) has been applied to this vault.
  /// Cached after the first probe so the per-frame read in `listCanvases` is
  /// fast.
  bool? _canvasTablesPresent;

  bool _hasCanvasTables() {
    if (_canvasTablesPresent != null) return _canvasTablesPresent!;
    final row = db.select(
      "SELECT COUNT(*) AS n FROM sqlite_master "
      "WHERE type='table' AND name='canvases'",
    );
    _canvasTablesPresent = (row.first['n'] as int) > 0;
    return _canvasTablesPresent!;
  }

  /// List every canvas with a node-count, ordered by `updated_at DESC`.
  /// Returns an empty list when the vault predates V4 (`canvases` table
  /// absent) so the UI doesn't crash on pre-migration handles.
  List<CanvasRow> listCanvases() {
    if (!_hasCanvasTables()) return const [];
    final rows = db.select(
      'SELECT c.id, c.title, c.created_at, c.updated_at, c.version, '
      '       (SELECT COUNT(*) FROM canvas_nodes n WHERE n.canvas_id = c.id) AS node_count '
      'FROM canvases c ORDER BY c.updated_at DESC, c.id ASC',
    );
    return rows
        .map(
          (r) => CanvasRow(
            canvasId: r['id'] as String,
            title: r['title'] as String,
            createdAt: (r['created_at'] as num).toInt(),
            updatedAt: (r['updated_at'] as num).toInt(),
            version: (r['version'] as num).toInt(),
            nodeCount: (r['node_count'] as num).toInt(),
          ),
        )
        .toList();
  }

  /// Read a canvas's metadata, placed nodes, and edges in one call. Edges are
  /// the existing wikilinks whose source AND target are both placed on this
  /// canvas — off-canvas wikilinks are excluded. Returns null for vaults that
  /// predate V4.
  CanvasDetailRow? getCanvasDetail(String canvasId) {
    if (!_hasCanvasTables()) return null;
    final canvasRows = db.select(
      'SELECT id, title, created_at, updated_at, version FROM canvases WHERE id = ?',
      [canvasId],
    );
    if (canvasRows.isEmpty) return null;
    final c = canvasRows.first;

    final nodeRows = db.select(
      'SELECT cn.note_id, n.title, cn.x, cn.y, cn.z_order, cn.placed_at '
      'FROM canvas_nodes cn JOIN notes n ON n.id = cn.note_id '
      'WHERE cn.canvas_id = ? '
      'ORDER BY cn.z_order ASC, cn.placed_at ASC',
      [canvasId],
    );
    final nodes = nodeRows
        .map(
          (r) => CanvasNodeRow(
            noteId: r['note_id'] as String,
            noteTitle: r['title'] as String,
            x: (r['x'] as num).toDouble(),
            y: (r['y'] as num).toDouble(),
            zOrder: (r['z_order'] as num).toInt(),
            placedAt: (r['placed_at'] as num).toInt(),
          ),
        )
        .toList();

    List<CanvasEdgeRow> edges = const [];
    if (nodes.isNotEmpty) {
      final ids = nodes.map((n) => n.noteId).toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      // Bind ids twice (once for from, once for to).
      final binds = <Object?>[...ids, ...ids];
      final edgeRows = db.select(
        'SELECT id, from_note_id, to_note_id, link_text, link_kind, label, position, source '
        'FROM links '
        'WHERE to_note_id IS NOT NULL '
        '  AND from_note_id IN ($placeholders) '
        '  AND to_note_id   IN ($placeholders) '
        'ORDER BY from_note_id, position',
        binds,
      );
      edges = edgeRows
          .map(
            (r) => CanvasEdgeRow(
              linkId: r['id'] as String,
              fromNoteId: r['from_note_id'] as String,
              toNoteId: r['to_note_id'] as String,
              linkText: r['link_text'] as String,
              kind: r['link_kind'] as String,
              label: r['label'] as String?,
              position: (r['position'] as num).toInt(),
              source: r['source'] as String,
            ),
          )
          .toList();
    }

    return CanvasDetailRow(
      canvasId: c['id'] as String,
      title: c['title'] as String,
      createdAt: (c['created_at'] as num).toInt(),
      updatedAt: (c['updated_at'] as num).toInt(),
      version: (c['version'] as num).toInt(),
      nodes: nodes,
      edges: edges,
    );
  }

  static LinkRow _rowToLink(Row r) {
    return LinkRow(
      id: r['id'] as String,
      fromNoteId: r['from_note_id'] as String,
      toNoteId: r['to_note_id'] as String?,
      linkText: r['link_text'] as String,
      kind: r['link_kind'] as String,
      label: r['label'] as String?,
      position: (r['position'] as num).toInt(),
      source: r['source'] as String,
    );
  }

  static bool isVault(String path) {
    return File(p.join(path, 'manifest.json')).existsSync() &&
        File(p.join(path, 'memex.db')).existsSync();
  }

  static String _snippet(String content) {
    final stripped = content.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
    final firstLine = stripped
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.length <= 120) return firstLine.trim();
    return '${firstLine.substring(0, 117).trim()}…';
  }
}

class NoteListItem {
  NoteListItem({
    required this.id,
    required this.title,
    required this.snippet,
    required this.version,
    required this.updatedAt,
  });
  final String id;
  final String title;
  final String snippet;
  final int version;
  final int updatedAt;
}

class Note {
  Note({
    required this.id,
    required this.title,
    required this.contentMd,
    required this.frontmatter,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.tags,
  });
  final String id;
  final String title;
  final String contentMd;
  final String frontmatter;
  final int version;
  final int createdAt;
  final int updatedAt;
  final List<String> tags;

  /// The note's role from the frontmatter JSON (`$.role`): `daily`, `topic`,
  /// or null when absent or when the frontmatter is not valid JSON.
  String? get role {
    final Object? decoded;
    try {
      decoded = jsonDecode(frontmatter);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final role = decoded['role'];
    return role is String ? role : null;
  }
}

class NoteTitle {
  NoteTitle({required this.id, required this.title, required this.updatedAt});
  final String id;
  final String title;
  final int updatedAt;
}

class LinkRow {
  LinkRow({
    required this.id,
    required this.fromNoteId,
    required this.toNoteId,
    required this.linkText,
    required this.kind,
    required this.label,
    required this.position,
    required this.source,
  });
  final String id;
  final String fromNoteId;
  final String? toNoteId;
  final String linkText;
  final String kind;
  final String? label;
  final int position;
  final String source;

  bool get isGhost => toNoteId == null;
}

class VaultDbException implements Exception {
  VaultDbException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CanvasRow {
  CanvasRow({
    required this.canvasId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    required this.nodeCount,
  });
  final String canvasId;
  final String title;
  final int createdAt;
  final int updatedAt;
  final int version;
  final int nodeCount;
}

class CanvasNodeRow {
  CanvasNodeRow({
    required this.noteId,
    required this.noteTitle,
    required this.x,
    required this.y,
    required this.zOrder,
    required this.placedAt,
  });
  final String noteId;
  final String noteTitle;
  final double x;
  final double y;
  final int zOrder;
  final int placedAt;
}

class CanvasEdgeRow {
  CanvasEdgeRow({
    required this.linkId,
    required this.fromNoteId,
    required this.toNoteId,
    required this.linkText,
    required this.kind,
    required this.label,
    required this.position,
    required this.source,
  });
  final String linkId;
  final String fromNoteId;
  final String toNoteId;
  final String linkText;
  final String kind;
  final String? label;
  final int position;
  final String source;
}

class CanvasDetailRow {
  CanvasDetailRow({
    required this.canvasId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    required this.nodes,
    required this.edges,
  });
  final String canvasId;
  final String title;
  final int createdAt;
  final int updatedAt;
  final int version;
  final List<CanvasNodeRow> nodes;
  final List<CanvasEdgeRow> edges;
}
