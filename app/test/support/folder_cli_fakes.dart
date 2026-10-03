// WI #25 (A8): FakeMemexCli handlers that behave like `memex folder …` and
// `memex settings get|set` (C2.6–C2.11, C1) against a FakeVaultDb. They stand
// in for the server: the app under test never computes depth, pinning or
// name rules itself. Nothing here goes through production code.
import 'dart:convert';

import 'package:open_memex_app/src/memex_cli.dart';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// The vault id every fake folder / settings response carries.
const fakeFolderVaultId = '01HV0000000000000000000000';

/// Fixed timestamp (unix ms) of fake folder writes.
const fakeFolderNowMs = 1759600000000;

/// A server simulation for `memex folder new|update|rm|add|remove` and
/// `memex settings get|set` over [vault]. [install] registers its handlers on
/// a [FakeMemexCli]; register a failing handler afterwards (`cli.on(…)`) to
/// script an error for one subcommand.
///
/// Rules (mirroring #13/#14): root depth is 1; `smart_folder_max_depth` is
/// read from `vault_settings`; `required_depth` = new parent depth + subtree
/// height; sibling names are unique case-insensitively; a person rename or
/// re-parent pins unless `--pinned false`; delete re-parents children to the
/// deleted folder's parent and drops its memberships; `folder add` upserts
/// (default pinned true) and gives a role-less note `role: topic` (Q3).
class FolderCliFake {
  FolderCliFake(this.vault);

  final FakeVaultDb vault;

  /// Ids of folders created through `folder new`, in order: `f-new-1`, ….
  final List<String> createdIds = [];

  /// The id the next `folder new` will use.
  String get nextId => 'f-new-${createdIds.length + 1}';

  void install(FakeMemexCli cli) {
    cli
      ..on('folder new', _new)
      ..on('folder update', _update)
      ..on('folder rm', _rm)
      ..on('folder add', _add)
      ..on('folder remove', _remove)
      ..on('settings get', _settingsGet)
      ..on('settings set', _settingsSet);
  }

  // ------------------------------------------------------------ db helpers

  int get maxDepth {
    final rows = vault.db.select(
      "SELECT value FROM vault_settings WHERE key = 'smart_folder_max_depth'",
    );
    return rows.isEmpty ? 2 : int.parse(rows.first['value'] as String);
  }

  Map<String, Object?>? _folder(String? id) {
    if (id == null) return null;
    final rows = vault.db.select('SELECT * FROM smart_folders WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  String? _parentOf(String id) => _folder(id)?['parent_id'] as String?;

  /// Root = 1.
  int depthOf(String id) {
    var d = 1;
    var p = _parentOf(id);
    while (p != null) {
      d++;
      p = _parentOf(p);
    }
    return d;
  }

  List<String> _childrenOf(String id) => [
    for (final r in vault.db.select(
      'SELECT id FROM smart_folders WHERE parent_id = ?',
      [id],
    ))
      r['id'] as String,
  ];

  /// A leaf has height 1.
  int heightOf(String id) {
    var h = 0;
    for (final c in _childrenOf(id)) {
      final ch = heightOf(c);
      if (ch > h) h = ch;
    }
    return h + 1;
  }

  bool _isSelfOrDescendant(String candidate, String of) {
    String? p = candidate;
    while (p != null) {
      if (p == of) return true;
      p = _parentOf(p);
    }
    return false;
  }

  bool _siblingNameTaken(String? parentId, String name, {String? exceptId}) {
    final rows = vault.db.select(
      parentId == null
          ? 'SELECT id, name FROM smart_folders WHERE parent_id IS NULL'
          : 'SELECT id, name FROM smart_folders WHERE parent_id = ?',
      parentId == null ? const [] : [parentId],
    );
    return rows.any(
      (r) =>
          r['id'] != exceptId &&
          (r['name'] as String).toLowerCase() == name.toLowerCase(),
    );
  }

  String _folderJson(String id) {
    final f = _folder(id)!;
    return jsonEncode({
      'vault_id': fakeFolderVaultId,
      'id': id,
      'name': f['name'],
      'parent_id': f['parent_id'],
      'pinned': (f['pinned'] as int) == 1,
      'depth': depthOf(id),
      'created_at': f['created_at'],
      'updated_at': f['updated_at'],
    });
  }

  static MemexResult _depthError(int required, int max) => FakeMemexCli.error(
    'depth_exceeded',
    'Smart Folder depth $required exceeds the vault maximum of $max',
    {'max_depth': max, 'required_depth': required},
  );

  // -------------------------------------------------------------- handlers

  MemexResult _new(FakeCliCall call) {
    final name = call.flag('name') ?? '';
    final parentId = call.flag('parent-id');
    if (parentId != null && _folder(parentId) == null) {
      return FakeMemexCli.error(
        'not_found',
        'Smart Folder not found: $parentId',
      );
    }
    if (_siblingNameTaken(parentId, name)) {
      return FakeMemexCli.error(
        'name_conflict',
        'A Smart Folder named $name already exists here',
      );
    }
    final required = (parentId == null ? 0 : depthOf(parentId)) + 1;
    if (required > maxDepth) return _depthError(required, maxDepth);
    final id = nextId;
    createdIds.add(id);
    vault.db.execute(
      'INSERT INTO smart_folders (id, name, parent_id, pinned, created_at, '
      'updated_at) VALUES (?, ?, ?, 1, ?, ?)',
      [id, name, parentId, fakeFolderNowMs, fakeFolderNowMs],
    );
    return FakeMemexCli.ok('${_folderJson(id)}\n');
  }

  MemexResult _update(FakeCliCall call) {
    final id = call.flag('id')!;
    final current = _folder(id);
    if (current == null) {
      return FakeMemexCli.error('not_found', 'Smart Folder not found: $id');
    }
    final name = call.flag('name');
    final toRoot = call.hasFlag('to-root');
    final parentFlag = call.flag('parent-id');
    final pinnedFlag = call.flag('pinned');
    final moving = toRoot || parentFlag != null;
    final newParent = toRoot
        ? null
        : (parentFlag ?? current['parent_id'] as String?);
    if (parentFlag != null) {
      if (_folder(parentFlag) == null) {
        return FakeMemexCli.error(
          'not_found',
          'Smart Folder not found: $parentFlag',
        );
      }
      if (_isSelfOrDescendant(parentFlag, id)) {
        return FakeMemexCli.error(
          'folder_cycle',
          'A Smart Folder cannot move inside itself',
        );
      }
    }
    final newName = name ?? current['name'] as String;
    if ((name != null || moving) &&
        _siblingNameTaken(newParent, newName, exceptId: id)) {
      return FakeMemexCli.error(
        'name_conflict',
        'A Smart Folder named $newName already exists here',
      );
    }
    if (moving) {
      final required =
          (newParent == null ? 0 : depthOf(newParent)) + heightOf(id);
      if (required > maxDepth) return _depthError(required, maxDepth);
    }
    final pinned = pinnedFlag != null
        ? pinnedFlag == 'true'
        : (name != null || moving) || (current['pinned'] as int) == 1;
    vault.db.execute(
      'UPDATE smart_folders SET name = ?, parent_id = ?, pinned = ?, '
      'updated_at = ? WHERE id = ?',
      [newName, newParent, pinned ? 1 : 0, fakeFolderNowMs, id],
    );
    return FakeMemexCli.ok('${_folderJson(id)}\n');
  }

  MemexResult _rm(FakeCliCall call) {
    final id = call.flag('id')!;
    final current = _folder(id);
    if (current == null) {
      return FakeMemexCli.error('not_found', 'Smart Folder not found: $id');
    }
    vault.db.execute(
      'UPDATE smart_folders SET parent_id = ? WHERE parent_id = ?',
      [current['parent_id'], id],
    );
    vault.db.execute(
      'DELETE FROM smart_folder_members WHERE smart_folder_id = ?',
      [id],
    );
    vault.db.execute('DELETE FROM smart_folders WHERE id = ?', [id]);
    return FakeMemexCli.ok(
      '${jsonEncode({'vault_id': fakeFolderVaultId, 'id': id, 'deleted': true})}\n',
    );
  }

  MemexResult _add(FakeCliCall call) {
    final folderId = call.flag('id')!;
    final noteId = call.flag('note-id')!;
    if (_folder(folderId) == null) {
      return FakeMemexCli.error(
        'not_found',
        'Smart Folder not found: $folderId',
      );
    }
    final notes = vault.db.select(
      'SELECT frontmatter FROM notes WHERE id = ?',
      [noteId],
    );
    if (notes.isEmpty) {
      return FakeMemexCli.error('not_found', 'note not found: $noteId');
    }
    final fm =
        jsonDecode(notes.first['frontmatter'] as String? ?? '{}')
            as Map<String, Object?>;
    if (fm['role'] == 'daily') {
      return FakeMemexCli.error(
        'role_rule',
        'A daily note cannot join a Smart Folder',
      );
    }
    final pinned = call.flag('pinned') != 'false';
    var roleSet = false;
    if (fm['role'] == null) {
      roleSet = true;
      vault.db.execute('UPDATE notes SET frontmatter = ? WHERE id = ?', [
        jsonEncode({...fm, 'role': 'topic'}),
        noteId,
      ]);
    }
    vault.db.execute(
      'INSERT INTO smart_folder_members (smart_folder_id, note_id, pinned) '
      'VALUES (?, ?, ?) ON CONFLICT(smart_folder_id, note_id) '
      'DO UPDATE SET pinned = excluded.pinned',
      [folderId, noteId, pinned ? 1 : 0],
    );
    return FakeMemexCli.ok(
      '${jsonEncode({'vault_id': fakeFolderVaultId, 'smart_folder_id': folderId, 'note_id': noteId, 'pinned': pinned, 'role_set': roleSet})}\n',
    );
  }

  MemexResult _remove(FakeCliCall call) {
    final folderId = call.flag('id')!;
    final noteId = call.flag('note-id')!;
    vault.db.execute(
      'DELETE FROM smart_folder_members WHERE smart_folder_id = ? '
      'AND note_id = ?',
      [folderId, noteId],
    );
    return FakeMemexCli.ok(
      '${jsonEncode({'vault_id': fakeFolderVaultId, 'smart_folder_id': folderId, 'note_id': noteId, 'removed': true})}\n',
    );
  }

  MemexResult _settingsJson(int value) => FakeMemexCli.ok(
    '${jsonEncode({'vault_id': fakeFolderVaultId, 'key': 'smart_folder_max_depth', 'value': value})}\n',
  );

  MemexResult _settingsGet(FakeCliCall call) {
    if (call.flag('key') != 'smart_folder_max_depth') {
      return FakeMemexCli.error(
        'setting_invalid',
        'unknown setting: ${call.flag('key')}',
      );
    }
    return _settingsJson(maxDepth);
  }

  MemexResult _settingsSet(FakeCliCall call) {
    if (call.flag('key') != 'smart_folder_max_depth') {
      return FakeMemexCli.error(
        'setting_invalid',
        'unknown setting: ${call.flag('key')}',
      );
    }
    final value = int.tryParse(call.flag('value') ?? '');
    if (value == null || value < 1 || value > 5) {
      return FakeMemexCli.error(
        'setting_invalid',
        'smart_folder_max_depth must be an integer from 1 to 5',
      );
    }
    vault.db.execute(
      "UPDATE vault_settings SET value = ? WHERE key = 'smart_folder_max_depth'",
      ['$value'],
    );
    return _settingsJson(value);
  }
}
