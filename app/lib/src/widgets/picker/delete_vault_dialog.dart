import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Asks before moving the local vault at [path] to the Trash (Spec #347
/// req 7–16) and runs the delete flow (`vaultDeleterProvider`) on
/// "move to trash". Completes when the dialog closes.
Future<void> confirmDeleteVault(BuildContext context, {required String path}) =>
    Future.value();

/// The delete-vault confirm: the remove-server shell (472 wide), eyebrow
/// "DELETE VAULT", the question, the body, then ghost "cancel"
/// (`delete-vault-cancel`) and danger "move to trash"
/// (`delete-vault-confirm`).
class DeleteVaultDialog extends ConsumerStatefulWidget {
  const DeleteVaultDialog({super.key, required this.path});

  /// The full path of the vault folder.
  final String path;

  @override
  ConsumerState<DeleteVaultDialog> createState() => _DeleteVaultDialogState();
}

class _DeleteVaultDialogState extends ConsumerState<DeleteVaultDialog> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
