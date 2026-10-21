import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/settings_cli.dart';
import '../memex_cli.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_access.dart';
import 'topics_state.dart';
import 'topics_tree.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The CLI message of the last failed Smart Folder mutation (Req 54), shown
/// as a dismissible inline error in the Topics pane. Null when there is none.
final smartFolderErrorProvider = StateProvider<String?>((_) => null);

/// The Smart Folder the person last selected in the Topics tree:
/// `+ New Smart Folder` creates inside it. Null means root.
final selectedTopicFolderProvider = StateProvider<String?>((_) => null);

/// [selectedTopicFolderProvider] while that folder is still in the tree;
/// null (root) once it was deleted, here or by an agent.
final selectedFolderInTreeProvider = Provider<String?>((ref) {
  final id = ref.watch(selectedTopicFolderProvider);
  bool holds(FolderNode f) => f.id == id || f.children.any(holds);
  return ref.watch(smartFolderTreeProvider).folders.any(holds) ? id : null;
});

/// Asks the person whether to raise `smart_folder_max_depth` to
/// [requiredDepth] (the depth dialog, Req 37). Resolves true on Confirm.
typedef ConfirmDepthRaise = Future<bool> Function(int requiredDepth);

/// Runs one Smart Folder write through `VaultAccess.topics` (Req 54, TD11).
///
/// [write] gets the topics domain and makes the Smart Folder call. The whole
/// sequence runs inside `guardVaultWrite` on [context]: a
/// `VaultUnreachableException` shows its snackbar instead of the inline
/// error and changes nothing. With no vault access or no CLI the inline
/// error is "The memex CLI is not available.". On success the vault reads refresh (`vaultRevisionProvider`) and
/// any earlier inline error clears. On a failure nothing else changes and
/// [smartFolderErrorProvider] holds the CLI message.
///
/// When [confirmDepth] is given and the call fails with `depth_exceeded`,
/// it is asked about the error's `required_depth` instead. On Confirm the
/// setting is raised to that value (`memex settings set`) and [write] runs
/// again with the same arguments; on Cancel nothing changes. A failure of
/// either of those calls is shown inline the same way.
///
/// Takes a [ProviderContainer] rather than a `WidgetRef` because menus and
/// dialogs are gone by the time the call returns.
Future<void> runSmartFolderWrite(
  ProviderContainer container,
  BuildContext context,
  Future<void> Function(TopicsAccess topics) write, {
  ConfirmDepthRaise? confirmDepth,
}) async {
  final errors = container.read(smartFolderErrorProvider.notifier);
  final access = container.read(vaultAccessProvider);
  if (access == null || !access.canWrite) {
    errors.state = 'The memex CLI is not available.';
    return;
  }
  final topics = access.topics;
  final ok = await guardVaultWrite<bool>(context, () async {
    try {
      try {
        await write(topics);
      } on MemexException catch (e) {
        final required = e.code == 'depth_exceeded'
            ? e.fields['required_depth']
            : null;
        if (confirmDepth == null || required is! int) rethrow;
        if (!await confirmDepth(required)) return false;
        await topics.setSetting(smartFolderMaxDepthKey, required);
        await write(topics);
      }
    } on VaultUnreachableException {
      rethrow;
    } on Exception catch (e) {
      errors.state = e is MemexException ? e.message : '$e';
      return false;
    }
    return true;
  });
  if (ok != true) return;
  errors.state = null;
  container.read(vaultRevisionProvider.notifier).state++;
}

/// `+ New Smart Folder`: `memex folder new` named [name], inside [parentId]
/// or at root when null.
Future<void> createSmartFolder(
  ProviderContainer container,
  BuildContext context, {
  required String name,
  String? parentId,
  ConfirmDepthRaise? confirmDepth,
}) => runSmartFolderWrite(
  container,
  context,
  (t) => t.createFolder(name: name, parentId: parentId),
  confirmDepth: confirmDepth,
);

/// Folder menu Rename: `memex folder update --name` (the server pins it).
Future<void> renameSmartFolder(
  ProviderContainer container,
  BuildContext context, {
  required String id,
  required String name,
}) => runSmartFolderWrite(
  container,
  context,
  (t) => t.updateFolder(id: id, name: name),
);

/// Folder menu Move: `memex folder update` with `--parent-id`, or
/// `--to-root` when [parentId] is null (the server pins it).
Future<void> moveSmartFolder(
  ProviderContainer container,
  BuildContext context, {
  required String id,
  required String? parentId,
  ConfirmDepthRaise? confirmDepth,
}) => runSmartFolderWrite(
  container,
  context,
  (t) => t.updateFolder(id: id, parentId: parentId, toRoot: parentId == null),
  confirmDepth: confirmDepth,
);

/// Folder menu pinned toggle: `memex folder update --pinned`.
Future<void> setSmartFolderPinned(
  ProviderContainer container,
  BuildContext context, {
  required String id,
  required bool pinned,
}) => runSmartFolderWrite(
  container,
  context,
  (t) => t.updateFolder(id: id, pinned: pinned),
);

/// Folder menu Delete: `memex folder rm`.
Future<void> deleteSmartFolder(
  ProviderContainer container,
  BuildContext context, {
  required String id,
}) => runSmartFolderWrite(container, context, (t) => t.deleteFolder(id: id));

/// A drop onto a folder row (no [pinned]: the server pins it and gives a
/// role-less note `role: topic`, Q3), or the membership pinned toggle:
/// `memex folder add`.
Future<void> addToSmartFolder(
  ProviderContainer container,
  BuildContext context, {
  required String folderId,
  required String noteId,
  bool? pinned,
}) => runSmartFolderWrite(
  container,
  context,
  (t) => t.addToFolder(folderId: folderId, noteId: noteId, pinned: pinned),
);
