import 'package:flutter_riverpod/flutter_riverpod.dart';

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
String? vaultDeleteMessage(TrashResult result, String path) => '';

/// Moves a local vault's folder to the Trash and forgets it.
class VaultDeleter {
  VaultDeleter(this._ref);

  // ignore: unused_field
  final Ref _ref;

  Future<VaultDeleteResult> delete(String path) async =>
      const VaultDeleteFailed('');
}

final vaultDeleterProvider = Provider<VaultDeleter>((ref) => VaultDeleter(ref));
