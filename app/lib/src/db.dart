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

class VaultDbException implements Exception {
  VaultDbException(this.message);
  final String message;
  @override
  String toString() => message;
}
