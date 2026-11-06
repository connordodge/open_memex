import '../../cli/folder_cli.dart';
import '../../cli/prompt_cli.dart';
import '../../cli/settings_cli.dart';
import '../../db.dart';
import '../../db/topics_reads.dart';
import '../../memex_cli.dart';
import '../topics_access.dart';
import 'write_guard.dart';

/// [TopicsAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `TopicsAccess`).
class LocalTopicsAccess implements TopicsAccess {
  LocalTopicsAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  MemexCli get _cli => requireLocalCli(cli);

  // ---------- reads ----------

  @override
  Future<SmartFolderData> smartFolders() async =>
      db?.smartFolders() ?? const SmartFolderData(folders: [], members: []);

  @override
  Future<List<UnsortedNoteRow>> unsortedNotes() async =>
      db?.unsortedNotes() ?? const [];

  // ---------- writes (and CLI-served reads) ----------

  @override
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  }) async =>
      _cli.createFolder(vaultPath: vaultPath, name: name, parentId: parentId);

  @override
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) async => _cli.updateFolder(
    vaultPath: vaultPath,
    id: id,
    name: name,
    parentId: parentId,
    toRoot: toRoot,
    pinned: pinned,
  );

  @override
  Future<FolderDeleteResult> deleteFolder({required String id}) async =>
      _cli.deleteFolder(vaultPath: vaultPath, id: id);

  @override
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  }) async => _cli.addToFolder(
    vaultPath: vaultPath,
    folderId: folderId,
    noteId: noteId,
    pinned: pinned,
  );

  @override
  Future<FolderMemberRemoveResult> removeFromFolder({
    required String folderId,
    required String noteId,
  }) async => FolderMemberRemoveResult(
    vaultId: '',
    smartFolderId: '',
    noteId: '',
    removed: false,
  );

  @override
  Future<int> getSetting(String key) async => _cli.getSetting(vaultPath, key);

  @override
  Future<int> setSetting(String key, int value) async =>
      _cli.setSetting(vaultPath, key, value);

  /// `memex prompt review` takes no `--vault` today (`PromptCli`).
  @override
  Future<String> reviewPrompt() async => _cli.reviewPrompt();
}
