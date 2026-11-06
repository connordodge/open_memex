import 'dart:convert';

import '../memex_cli.dart';

/// A Smart Folder as `memex folder new|update` prints it (C2.6, C2.7).
class SmartFolderResult {
  SmartFolderResult({
    required this.vaultId,
    required this.id,
    required this.name,
    required this.parentId,
    required this.pinned,
    required this.depth,
    required this.createdAt,
    required this.updatedAt,
  });
  final String vaultId;
  final String id;
  final String name;

  /// Null for a root folder.
  final String? parentId;
  final bool pinned;

  /// 1 for a root folder.
  final int depth;

  /// Unix ms.
  final int createdAt;

  /// Unix ms.
  final int updatedAt;
}

/// The parsed `memex folder rm` result (C2.8).
class FolderDeleteResult {
  FolderDeleteResult({
    required this.vaultId,
    required this.id,
    required this.deleted,
  });
  final String vaultId;
  final String id;
  final bool deleted;
}

/// The parsed `memex folder add` result (C2.9).
class FolderMembershipResult {
  FolderMembershipResult({
    required this.vaultId,
    required this.smartFolderId,
    required this.noteId,
    required this.pinned,
    required this.roleSet,
  });
  final String vaultId;
  final String smartFolderId;
  final String noteId;
  final bool pinned;

  /// True when a role-less note became `role: topic` (Q3).
  final bool roleSet;
}

/// The parsed `memex folder remove` result (C2.10).
class FolderMemberRemoveResult {
  FolderMemberRemoveResult({
    required this.vaultId,
    required this.smartFolderId,
    required this.noteId,
    required this.removed,
  });
  final String vaultId;
  final String smartFolderId;
  final String noteId;
  final bool removed;
}

/// `memex folder new|update|rm|add|remove` wrappers (C2.6–C2.10, D21).
///
/// Every call passes `--vault`. A CLI failure throws [MemexException] built
/// by [MemexException.fromCliFailure] (C1 `code` and `fields`, e.g.
/// `depth_exceeded` with `max_depth` / `required_depth`); stdout that is not
/// the contract shape throws a [MemexException] with a null code.
extension FolderCli on MemexCli {
  /// `memex folder new --vault V --name NAME [--parent-id P]` (C2.6).
  Future<SmartFolderResult> createFolder({
    required String vaultPath,
    required String name,
    String? parentId,
  }) => _folderCall('new', [
    '--vault',
    vaultPath,
    '--name',
    name,
    if (parentId != null) ...['--parent-id', parentId],
  ], parseFolderResult);

  /// `memex folder update --vault V --id F [--name NAME]
  /// [--parent-id P | --to-root] [--pinned true|false]` (C2.7). [toRoot]
  /// wins over [parentId].
  Future<SmartFolderResult> updateFolder({
    required String vaultPath,
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) => _folderCall('update', [
    '--vault',
    vaultPath,
    '--id',
    id,
    if (name != null) ...['--name', name],
    if (toRoot)
      '--to-root'
    else if (parentId != null) ...[
      '--parent-id',
      parentId,
    ],
    if (pinned != null) ...['--pinned', '$pinned'],
  ], parseFolderResult);

  /// `memex folder rm --vault V --id F` (C2.8).
  Future<FolderDeleteResult> deleteFolder({
    required String vaultPath,
    required String id,
  }) => _folderCall('rm', [
    '--vault',
    vaultPath,
    '--id',
    id,
  ], parseFolderDeleteResult);

  /// `memex folder add --vault V --id F --note-id N [--pinned true|false]`
  /// (C2.9). [pinned] null omits the flag (the CLI default is pinned).
  Future<FolderMembershipResult> addToFolder({
    required String vaultPath,
    required String folderId,
    required String noteId,
    bool? pinned,
  }) => _folderCall('add', [
    '--vault',
    vaultPath,
    '--id',
    folderId,
    '--note-id',
    noteId,
    if (pinned != null) ...['--pinned', '$pinned'],
  ], parseFolderMembershipResult);

  /// `memex folder remove --vault V --id F --note-id N` (C2.10).
  Future<FolderMemberRemoveResult> removeFromFolder({
    required String vaultPath,
    required String folderId,
    required String noteId,
  }) => _folderCall('remove', [
    '--vault',
    vaultPath,
    '--id',
    folderId,
    '--note-id',
    noteId,
  ], parseFolderMemberRemoveResult);

  /// Runs `memex folder <sub> <args>` and [parse]s the JSON object on stdout.
  /// A non-zero exit throws [MemexException.fromCliFailure]; stdout that is
  /// not an object, or that [parse] rejects (null), throws a null-code
  /// [MemexException].
  Future<T> _folderCall<T>(
    String sub,
    List<String> args,
    T? Function(Map<String, Object?> json) parse,
  ) async {
    final r = await run(['folder', sub, ...args]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('folder $sub', r);
    }
    Object? json;
    try {
      json = jsonDecode(r.stdout.trim());
    } on FormatException {
      json = null;
    }
    final result = json is Map<String, Object?> ? parse(json) : null;
    if (result == null) {
      throw MemexException('folder $sub: could not parse output: ${r.stdout}');
    }
    return result;
  }
}

/// The C2.6 / C2.7 folder object, or null for any other shape. Shared by
/// the CLI wrapper and the hosted `POST|PATCH /smart-folders` calls.
SmartFolderResult? parseFolderResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'id': final String id,
    'name': final String name,
    'parent_id': final String? parentId,
    'pinned': final bool pinned,
    'depth': final int depth,
    'created_at': final int createdAt,
    'updated_at': final int updatedAt,
  }) {
    return SmartFolderResult(
      vaultId: vaultId,
      id: id,
      name: name,
      parentId: parentId,
      pinned: pinned,
      depth: depth,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
  return null;
}

/// The C2.8 `folder rm` object, or null for any other shape. Shared by the
/// CLI wrapper and the hosted `DELETE /smart-folders/{id}` call.
FolderDeleteResult? parseFolderDeleteResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'id': final String id,
    'deleted': final bool deleted,
  }) {
    return FolderDeleteResult(vaultId: vaultId, id: id, deleted: deleted);
  }
  return null;
}

/// The C2.9 `folder add` object, or null for any other shape. Shared by the
/// CLI wrapper and the hosted `POST /smart-folders/{id}/members` call.
FolderMembershipResult? parseFolderMembershipResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'smart_folder_id': final String smartFolderId,
    'note_id': final String noteId,
    'pinned': final bool pinned,
    'role_set': final bool roleSet,
  }) {
    return FolderMembershipResult(
      vaultId: vaultId,
      smartFolderId: smartFolderId,
      noteId: noteId,
      pinned: pinned,
      roleSet: roleSet,
    );
  }
  return null;
}

/// The C2.10 `folder remove` object, or null for any other shape. Shared by
/// the CLI wrapper and the hosted `DELETE /smart-folders/{id}/members/{note}`
/// call.
FolderMemberRemoveResult? parseFolderMemberRemoveResult(
  Map<String, Object?> json,
) {
  if (json case {
    'vault_id': final String vaultId,
    'smart_folder_id': final String smartFolderId,
    'note_id': final String noteId,
    'removed': final bool removed,
  }) {
    return FolderMemberRemoveResult(
      vaultId: vaultId,
      smartFolderId: smartFolderId,
      noteId: noteId,
      removed: removed,
    );
  }
  return null;
}
