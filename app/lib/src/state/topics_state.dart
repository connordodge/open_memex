import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/topics_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'topics_tree.dart';
import 'vault_state.dart';

/// The Topics tree read through `VaultAccess.topics`, stamped with the vault it
/// was loaded for (D14a). WI #87 skeleton: the implementation replaces it.
final smartFolderTreeAsyncProvider = FutureProvider<VaultScoped<TopicsTree>>(
  (ref) => throw UnimplementedError(),
);

/// The Topics tree, re-read on every `vaultRevisionProvider` bump. Empty on a
/// vault below V5 or with no database.
final smartFolderTreeProvider = Provider<TopicsTree>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null || !ref.watch(vaultV5ReadyProvider)) {
    return buildTopicsTree(const SmartFolderData(folders: [], members: []), []);
  }
  return buildTopicsTree(db.smartFolders(), db.unsortedNotes());
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
