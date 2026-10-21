import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/topics_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'topics_tree.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// A tree with no folders and no unsorted notes: the value below V5, with no
/// vault access, and before the first read of the open vault completes.
TopicsTree emptyTopicsTree() =>
    buildTopicsTree(const SmartFolderData(folders: [], members: []), []);

/// The Topics tree read through `VaultAccess.topics`, re-read on every
/// `vaultRevisionProvider` bump and stamped with the vault it was loaded for
/// (D14a). Empty on a vault below V5 or with no vault access.
final smartFolderTreeAsyncProvider = FutureProvider<VaultScoped<TopicsTree>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null || !ref.watch(vaultV5ReadyProvider)) {
    return VaultScoped(vault, emptyTopicsTree());
  }
  final folders = await access.topics.smartFolders();
  final unsorted = await access.topics.unsortedNotes();
  return VaultScoped(vault, buildTopicsTree(folders, unsorted));
});

/// The ids of the Smart Folders the person has expanded in the Topics tree.
/// In memory only: every folder starts collapsed and nothing is persisted.
final expandedTopicFoldersProvider =
    NotifierProvider<ExpandedTopicFolders, Set<String>>(
      ExpandedTopicFolders.new,
    );

class ExpandedTopicFolders extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Expands [folderId] when collapsed, collapses it when expanded.
  void toggle(String folderId) {
    state = state.contains(folderId)
        ? ({...state}..remove(folderId))
        : {...state, folderId};
  }
}
