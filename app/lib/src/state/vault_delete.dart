import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import 'editor_controller.dart';
import 'settings.dart';
import 'ui_state_store.dart';
import 'vault_open_controller.dart';
import 'vault_open_hosted.dart';
import 'vault_ref.dart';
import 'vault_trash.dart';

/// How a vault delete came out.
sealed class VaultDeleteResult {
  const VaultDeleteResult();
}

/// The folder is in the Trash and the app has forgotten the vault.
final class VaultDeleted extends VaultDeleteResult {
  const VaultDeleted();
}

/// Nothing was deleted; [message] says why.
final class VaultDeleteFailed extends VaultDeleteResult {
  const VaultDeleteFailed(this.message);

  final String message;
}

/// The leave guard said stay: nothing was flushed, closed or trashed, and
/// the vault is still open.
final class VaultDeleteCancelled extends VaultDeleteResult {
  const VaultDeleteCancelled();
}

/// The message for a failed [result] on the vault at [path]; null for
/// [Trashed].
String? vaultDeleteMessage(TrashResult result, String path) {
  final name = p.basename(path);
  return switch (result) {
    Trashed() => null,
    TrashNoTrash() =>
      "this drive has no trash, so $name can't be moved there. nothing was deleted.",
    TrashPermission() =>
      "open memex isn't allowed to move $path. nothing was deleted.",
    TrashNotFound() =>
      '$path is no longer a vault folder. nothing was deleted.',
    TrashFailed(:final message) =>
      "couldn't move $name to the trash: $message. nothing was deleted.",
  };
}

/// Moves a local vault's folder to the Trash and forgets it.
class VaultDeleter {
  VaultDeleter(this._ref);

  final Ref _ref;

  /// Re-checks that [path] is still a vault, moves it to the Trash and, only
  /// when that succeeds, forgets it, its recorded row outcome and its backup
  /// settings. This deletes nothing itself and leaves every backup alone.
  Future<VaultDeleteResult> delete(String path) async {
    if (!VaultDb.isVault(path)) {
      return VaultDeleteFailed(
        vaultDeleteMessage(const TrashNotFound(), path)!,
      );
    }
    final result = await _ref.read(vaultTrashProvider).trash(path);
    final message = vaultDeleteMessage(result, path);
    if (message != null) return VaultDeleteFailed(message);
    final ref = LocalVaultRef(path);
    final settings = _ref.read(settingsProvider.notifier);
    await settings.forgetRef(ref);
    _ref.read(recentRowOutcomeProvider(ref).notifier).state = null;
    await settings.removeVaultBackup(path);
    return const VaultDeleted();
  }

  /// Deletes the open local vault at [path] (Spec #357 Req 28-30), in this
  /// order: asks [leaveVaultGuardProvider] once with [context] (stay
  /// completes [VaultDeleteCancelled] and changes nothing); flushes the
  /// editor's pending save; closes the vault
  /// ([VaultOpenController.closeForDelete]); waits for the editor's saves
  /// of the vault and its UI state writes, so nothing writes into the
  /// folder after it moves; then runs [delete]. On a [VaultDeleteFailed]
  /// the vault reopens ([VaultOpenController.reopenAfterFailedDelete]) and
  /// the failure is the result, whether or not the reopen worked.
  ///
  /// [context] must stay mounted while the guard runs: pass the delete
  /// dialog's own, since closing the vault unmounts whatever opened it.
  Future<VaultDeleteResult> deleteOpenVault(
    BuildContext context,
    String path,
  ) async {
    if (!await _ref.read(leaveVaultGuardProvider)(context)) {
      return const VaultDeleteCancelled();
    }
    final vault = LocalVaultRef(path);
    final editor = _ref.read(editorControllerProvider.notifier);
    final opener = _ref.read(vaultOpenControllerProvider);
    editor.flushPendingSave();
    await opener.closeForDelete();
    final VaultDeleteResult result;
    try {
      await editor.savesSettled(vault);
      await UiStateStore(vaultPath: path).flush();
      result = await delete(path);
    } catch (_) {
      // Never leave the vault closed on a throw: reopen it, then report.
      await opener.reopenAfterFailedDelete(vault);
      rethrow;
    }
    if (result is VaultDeleteFailed) {
      await opener.reopenAfterFailedDelete(vault);
    }
    return result;
  }
}

final vaultDeleterProvider = Provider<VaultDeleter>((ref) => VaultDeleter(ref));
