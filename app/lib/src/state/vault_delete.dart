import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import 'backup_controller.dart';
import 'editor_controller.dart';
import 'settings.dart';
import 'ui_state_store.dart';
import 'vault_open_controller.dart';
import 'vault_open_hosted.dart';
import 'vault_paths.dart';
import 'vault_state.dart';
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

/// The refusal while a backup of the vault at [path] runs (Spec #357
/// Req 33).
String vaultBackupRunningMessage(String path) =>
    'a backup of ${p.basename(path)} is running. try again when it '
    'finishes. nothing was deleted.';

/// Whether [inFlight] (the paths of the running backups,
/// [backupInFlightProvider]) holds [path]'s folder in any spelling
/// ([isSameVaultFolder]).
bool isVaultBackingUp(Iterable<String> inFlight, String path) =>
    inFlight.any((running) => isSameVaultFolder(running, path));

/// Whether [path] is the open vault's folder [openPath] itself, so that
/// deleting [path] closes the vault and moves the open folder.
///
/// It is when the two strings are equal, or when they name the same folder
/// in any spelling ([isSameVaultFolder]) and [path]'s own last entry is the
/// open folder: a symlink to the open folder is not it (the Trash would
/// move the link and leave the folder), nor is a folder whose name differs
/// only in case on a case-sensitive volume. A path that can't be checked
/// on disk is not it.
bool isOpenVaultFolder(String openPath, String path) {
  if (openPath == path) return true;
  if (!isSameVaultFolder(openPath, path)) return false;
  try {
    final openFolder = Directory(openPath).resolveSymbolicLinksSync();
    return FileSystemEntity.identicalSync(
      openFolder,
      p.normalize(p.absolute(path)),
    );
  } on FileSystemException {
    return false;
  }
}

/// Moves a local vault's folder to the Trash and forgets it.
class VaultDeleter {
  VaultDeleter(this._ref);

  final Ref _ref;

  /// Re-checks that [path] is still a vault, moves it to the Trash and, only
  /// when that succeeds, forgets it, its recorded row outcome and its backup
  /// settings. This deletes nothing itself and leaves every backup alone.
  /// While a backup of [path] runs ([backupInFlightProvider]) it refuses
  /// with [vaultBackupRunningMessage] and moves nothing.
  Future<VaultDeleteResult> delete(String path) async {
    if (_backingUp(path)) {
      return VaultDeleteFailed(vaultBackupRunningMessage(path));
    }
    if (!VaultDb.isVault(path)) {
      return VaultDeleteFailed(
        vaultDeleteMessage(const TrashNotFound(), path)!,
      );
    }
    final result = await _ref.read(vaultTrashProvider).trash(path);
    final message = vaultDeleteMessage(result, path);
    if (message != null) return VaultDeleteFailed(message);
    await _forget(LocalVaultRef(path));
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
  ///
  /// [path] is the open vault when [isOpenVaultFolder] says so, in any
  /// spelling of the open folder; the close, the settle and the reopen use
  /// the open vault's own ref, and on success that ref is forgotten too.
  /// When [path] is not the open vault (a symlink to the open folder among
  /// them) this is [delete], and the vault stays open. While a backup of
  /// [path] runs it refuses before the guard and closes nothing; a backup
  /// that starts after that is refused by [delete], and the vault reopens.
  Future<VaultDeleteResult> deleteOpenVault(
    BuildContext context,
    String path,
  ) async {
    final current = _ref.read(currentVaultProvider);
    if (current is! LocalVaultRef || !isOpenVaultFolder(current.path, path)) {
      return delete(path);
    }
    final vault = current;
    if (_backingUp(path)) {
      return VaultDeleteFailed(vaultBackupRunningMessage(path));
    }
    if (!await _ref.read(leaveVaultGuardProvider)(context)) {
      return const VaultDeleteCancelled();
    }
    final editor = _ref.read(editorControllerProvider.notifier);
    final opener = _ref.read(vaultOpenControllerProvider);
    editor.flushPendingSave();
    await opener.closeForDelete();
    final VaultDeleteResult result;
    try {
      await editor.savesSettled(vault);
      await UiStateStore(vaultPath: vault.path).flush();
      result = await delete(path);
    } catch (_) {
      // Never leave the vault closed on a throw: reopen it, then report.
      await opener.reopenAfterFailedDelete(vault);
      rethrow;
    }
    if (result is VaultDeleteFailed) {
      await opener.reopenAfterFailedDelete(vault);
    } else if (vault.path != path) {
      // [delete] forgot [path]'s spelling. [isOpenVaultFolder] made [path]'s
      // own entry the open folder, so that folder is in the Trash now.
      await _forget(vault);
    }
    return result;
  }

  Future<void> _forget(LocalVaultRef ref) async {
    final settings = _ref.read(settingsProvider.notifier);
    await settings.forgetRef(ref);
    _ref.read(recentRowOutcomeProvider(ref).notifier).state = null;
    await settings.removeVaultBackup(ref.path);
  }

  /// Whether a backup of [path]'s folder, in any spelling, is running.
  bool _backingUp(String path) =>
      isVaultBackingUp(_ref.read(backupInFlightProvider), path);
}

final vaultDeleterProvider = Provider<VaultDeleter>((ref) => VaultDeleter(ref));
