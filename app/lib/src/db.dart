import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Read-only access to the vault's SQLite file from Dart. All writes go
/// through the `memex` CLI to keep indexing/embedding logic in one place.
class VaultDb {
  VaultDb._(this.db);

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
