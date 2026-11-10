import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import 'settings.dart';
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
}

final vaultDeleterProvider = Provider<VaultDeleter>((ref) => VaultDeleter(ref));
