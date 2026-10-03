import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/folder_cli.dart';
import '../cli/settings_cli.dart';
import '../memex_cli.dart';
import 'vault_state.dart';

/// The CLI message of the last failed Smart Folder mutation (Req 54), shown
/// as a dismissible inline error in the Topics pane. Null when there is none.
final smartFolderErrorProvider = StateProvider<String?>((_) => null);

/// The Smart Folder the person last selected in the Topics tree:
/// `+ New Smart Folder` creates inside it. Null means root.
final selectedTopicFolderProvider = StateProvider<String?>((_) => null);

/// Asks the person whether to raise `smart_folder_max_depth` to
/// [requiredDepth] (the depth dialog, Req 37). Resolves true on Confirm.
typedef ConfirmDepthRaise = Future<bool> Function(int requiredDepth);

/// Runs one Smart Folder write through the CLI (Req 54, TD11).
///
/// [write] gets the CLI and the vault path and makes the `memex folder …`
/// call. On success the vault reads refresh (`vaultRevisionProvider`) and
/// any earlier inline error clears. On a failure nothing else changes and
/// [smartFolderErrorProvider] holds the CLI message.
///
/// When [confirmDepth] is given and the call fails with `depth_exceeded`,
/// it is asked about the error's `required_depth` instead. On Confirm the
/// setting is raised to that value (`memex settings set`) and [write] runs
/// again with the same arguments; on Cancel nothing changes. A failure of
/// either of those calls is shown inline the same way.
///
/// Resolves true when the write landed. Takes a [ProviderContainer] rather
/// than a `WidgetRef` because menus and dialogs are gone by the time the
/// call returns.
Future<bool> runSmartFolderWrite(
  ProviderContainer container,
  Future<void> Function(MemexCli cli, String vaultPath) write, {
  ConfirmDepthRaise? confirmDepth,
}) async {
  final errors = container.read(smartFolderErrorProvider.notifier);
  final cli = container.read(memexCliProvider);
  final vaultPath = container.read(currentVaultProvider);
  if (cli == null || vaultPath == null) {
    errors.state = 'The memex CLI is not available.';
    return false;
  }
  try {
    try {
      await write(cli, vaultPath);
    } on MemexException catch (e) {
      final required = e.code == 'depth_exceeded'
          ? e.fields['required_depth']
          : null;
      if (confirmDepth == null || required is! int) rethrow;
      if (!await confirmDepth(required)) return false;
      await cli.setSetting(vaultPath, smartFolderMaxDepthKey, required);
      await write(cli, vaultPath);
    }
  } on Exception catch (e) {
    // MemexException carries the CLI message; anything else (the binary
    // is missing, …) shows as is.
    errors.state = e is MemexException ? e.message : '$e';
    return false;
  }
  errors.state = null;
  container.read(vaultRevisionProvider.notifier).state++;
  return true;
}

/// `+ New Smart Folder`: `memex folder new` named [name], inside [parentId]
/// or at root when null.
Future<bool> createSmartFolder(
  ProviderContainer container, {
  required String name,
  String? parentId,
  ConfirmDepthRaise? confirmDepth,
}) => runSmartFolderWrite(
  container,
  (cli, vault) =>
      cli.createFolder(vaultPath: vault, name: name, parentId: parentId),
  confirmDepth: confirmDepth,
);

/// Folder menu Rename: `memex folder update --name` (the server pins it).
Future<bool> renameSmartFolder(
  ProviderContainer container, {
  required String id,
  required String name,
}) => runSmartFolderWrite(
  container,
  (cli, vault) => cli.updateFolder(vaultPath: vault, id: id, name: name),
);

/// Folder menu Move: `memex folder update` with `--parent-id`, or
/// `--to-root` when [parentId] is null (the server pins it).
Future<bool> moveSmartFolder(
  ProviderContainer container, {
  required String id,
  required String? parentId,
  ConfirmDepthRaise? confirmDepth,
}) => runSmartFolderWrite(
  container,
  (cli, vault) => cli.updateFolder(
    vaultPath: vault,
    id: id,
    parentId: parentId,
    toRoot: parentId == null,
  ),
  confirmDepth: confirmDepth,
);

/// Folder menu pinned toggle: `memex folder update --pinned`.
Future<bool> setSmartFolderPinned(
  ProviderContainer container, {
  required String id,
  required bool pinned,
}) => runSmartFolderWrite(
  container,
  (cli, vault) => cli.updateFolder(vaultPath: vault, id: id, pinned: pinned),
);

/// Folder menu Delete: `memex folder rm`.
Future<bool> deleteSmartFolder(
  ProviderContainer container, {
  required String id,
}) => runSmartFolderWrite(
  container,
  (cli, vault) => cli.deleteFolder(vaultPath: vault, id: id),
);

/// A drop onto a folder row (no [pinned]: the server pins it and gives a
/// role-less note `role: topic`, Q3), or the membership pinned toggle:
/// `memex folder add`.
Future<bool> addToSmartFolder(
  ProviderContainer container, {
  required String folderId,
  required String noteId,
  bool? pinned,
}) => runSmartFolderWrite(
  container,
  (cli, vault) => cli.addToFolder(
    vaultPath: vault,
    folderId: folderId,
    noteId: noteId,
    pinned: pinned,
  ),
);
