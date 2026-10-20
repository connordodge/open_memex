import '../../cli/folder_cli.dart';
import '../../db/topics_reads.dart';
import '../topics_access.dart';
import 'hosted_client.dart';

/// [TopicsAccess] for a hosted vault (D11 V3, D11a, D13): every read and
/// write is one `/vaults/<vaultName>/api/v1` route through [client] (D17).
class HostedTopicsAccess implements TopicsAccess {
  HostedTopicsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  // ---------- reads ----------

  @override
  Future<SmartFolderData> smartFolders() => throw UnimplementedError('#83');

  @override
  Future<List<UnsortedNoteRow>> unsortedNotes() =>
      throw UnimplementedError('#83');

  // ---------- writes (and CLI-served reads) ----------

  @override
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  }) => throw UnimplementedError('#83');

  @override
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) => throw UnimplementedError('#83');

  @override
  Future<FolderDeleteResult> deleteFolder({required String id}) =>
      throw UnimplementedError('#83');

  @override
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  }) => throw UnimplementedError('#83');

  @override
  Future<int> getSetting(String key) => throw UnimplementedError('#83');

  @override
  Future<int> setSetting(String key, int value) =>
      throw UnimplementedError('#83');

  @override
  Future<String> reviewPrompt() => throw UnimplementedError('#83');
}
