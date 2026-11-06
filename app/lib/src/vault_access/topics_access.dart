import '../cli/folder_cli.dart';
import '../db/topics_reads.dart';

/// Smart Folders, unsorted notes, vault settings and the review prompt of the
/// open vault (D13, D11 V3, D11a). Same rules as `NotesAccess`: async mirrors
/// of today's `TopicsReads` / CLI wrappers, today's empty values without a
/// database, today's exceptions from writes, [StateError] from a write when
/// `VaultAccess.canWrite` is false.
///
/// Frozen at merge (D13). Test doubles `extends LocalTopicsAccess` (D21).
abstract interface class TopicsAccess {
  // ---------- reads ----------

  /// `TopicsReads.smartFolders`: every folder and membership.
  Future<SmartFolderData> smartFolders();

  /// `TopicsReads.unsortedNotes`.
  Future<List<UnsortedNoteRow>> unsortedNotes();

  // ---------- writes (and CLI-served reads) ----------

  /// `memex folder new` (`FolderCli.createFolder`). Too deep throws
  /// `depth_exceeded` with `max_depth` / `required_depth`.
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  });

  /// `memex folder update` (`FolderCli.updateFolder`). [toRoot] wins over
  /// [parentId].
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  });

  /// `memex folder rm` (`FolderCli.deleteFolder`).
  Future<FolderDeleteResult> deleteFolder({required String id});

  /// `memex folder add` (`FolderCli.addToFolder`). [pinned] null omits the
  /// flag.
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  });

  /// `memex folder remove` (`FolderCli.removeFromFolder`); hosted:
  /// `DELETE /smart-folders/{folder_id}/members/{note_id}`.
  Future<FolderMemberRemoveResult> removeFromFolder({
    required String folderId,
    required String noteId,
  });

  /// `memex settings get` (`SettingsCli.getSetting`).
  Future<int> getSetting(String key);

  /// `memex settings set` (`SettingsCli.setSetting`): the stored value.
  Future<int> setSetting(String key, int value);

  /// `memex prompt review` (`PromptCli.reviewPrompt`): the raw text.
  Future<String> reviewPrompt();
}
