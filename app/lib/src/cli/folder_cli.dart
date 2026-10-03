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
  }) {
    throw UnimplementedError();
  }

  /// `memex folder update --vault V --id F [--name NAME]
  /// [--parent-id P | --to-root] [--pinned true|false]` (C2.7).
  Future<SmartFolderResult> updateFolder({
    required String vaultPath,
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) {
    throw UnimplementedError();
  }

  /// `memex folder rm --vault V --id F` (C2.8).
  Future<FolderDeleteResult> deleteFolder({
    required String vaultPath,
    required String id,
  }) {
    throw UnimplementedError();
  }

  /// `memex folder add --vault V --id F --note-id N [--pinned true|false]`
  /// (C2.9). [pinned] null omits the flag (the CLI default is pinned).
  Future<FolderMembershipResult> addToFolder({
    required String vaultPath,
    required String folderId,
    required String noteId,
    bool? pinned,
  }) {
    throw UnimplementedError();
  }

  /// `memex folder remove --vault V --id F --note-id N` (C2.10).
  Future<FolderMemberRemoveResult> removeFromFolder({
    required String vaultPath,
    required String folderId,
    required String noteId,
  }) {
    throw UnimplementedError();
  }
}
