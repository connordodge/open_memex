import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's file method channel (macOS `MainFlutterWindow.swift`).
///
/// - Dart → native `trashItem` (argument: the absolute path `String`): moves
///   the item to the system Trash. Replies null on success, or a
///   `trash_failed` error whose details are `{domain, code}` of the thrown
///   `NSError`; a non-`String` argument gets `bad_arguments`.
const vaultFilesChannel = MethodChannel('open_memex/files');

/// What moving a folder to the Trash came to.
sealed class TrashResult {
  const TrashResult();
}

/// The folder is in the Trash.
final class Trashed extends TrashResult {
  const Trashed();
}

/// The drive has no Trash.
final class TrashNoTrash extends TrashResult {
  const TrashNoTrash();
}

/// The app isn't allowed to move the folder.
final class TrashPermission extends TrashResult {
  const TrashPermission();
}

/// The folder isn't there.
final class TrashNotFound extends TrashResult {
  const TrashNotFound();
}

/// Anything else; [message] is the system's text.
final class TrashFailed extends TrashResult {
  const TrashFailed(this.message);

  final String message;
}

/// The Trash seam: moves a folder to the system Trash.
abstract interface class VaultTrash {
  Future<TrashResult> trash(String path);
}

/// Sends `trashItem` on [vaultFilesChannel] and maps the reply.
class PlatformVaultTrash implements VaultTrash {
  const PlatformVaultTrash();

  @override
  Future<TrashResult> trash(String path) async => const TrashFailed('');
}

/// The Trash seam.
final vaultTrashProvider = Provider<VaultTrash>(
  (_) => const PlatformVaultTrash(),
);
