import '../../cli/folder_cli.dart';
import '../../db.dart';
import '../../db/topics_reads.dart';
import '../../memex_cli.dart';
import '../topics_access.dart';

/// [TopicsAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `TopicsAccess`).
class LocalTopicsAccess implements TopicsAccess {
  LocalTopicsAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  // RED SKELETON (#70 test author): bodies are placeholders; the implementer
  // replaces every one with the delegation to [db] / [cli].

  static SmartFolderResult _placeholderFolder() => SmartFolderResult(
    vaultId: '',
    id: '',
    name: '',
    parentId: null,
    pinned: false,
    depth: 0,
    createdAt: 0,
    updatedAt: 0,
  );

  @override
  Future<SmartFolderData> smartFolders() async =>
      const SmartFolderData(folders: [], members: []);

  @override
  Future<List<UnsortedNoteRow>> unsortedNotes() async => const [];

  @override
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  }) async => _placeholderFolder();

  @override
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) async => _placeholderFolder();

  @override
  Future<FolderDeleteResult> deleteFolder({required String id}) async =>
      FolderDeleteResult(vaultId: '', id: '', deleted: false);

  @override
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  }) async => FolderMembershipResult(
    vaultId: '',
    smartFolderId: '',
    noteId: '',
    pinned: false,
    roleSet: false,
  );

  @override
  Future<int> getSetting(String key) async => 0;

  @override
  Future<int> setSetting(String key, int value) async => 0;

  @override
  Future<String> reviewPrompt() async => '';
}
