// WI #350 (Spec #347 req 7–16, 19, 20): the delete-vault confirm.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../state/backup_controller.dart';
import '../../state/vault_delete.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../dialog_button.dart';

/// Asks before moving the local vault at [path] to the Trash (Spec #347
/// req 7–16) and runs the delete flow (`vaultDeleterProvider`) on
/// "move to trash". When [path] is the open local vault it closes the vault
/// first (Spec #357 Req 27-31). Completes when the dialog closes.
Future<void> confirmDeleteVault(
  BuildContext context, {
  required String path,
}) async {
  // On the root navigator (the default), above `_Router`: the dialog
  // outlives the workspace that opened it when the open vault closes.
  await showDialog<void>(
    context: context,
    builder: (_) => DeleteVaultDialog(path: path),
  );
}

/// The delete-vault confirm: the remove-server shell (472 wide), eyebrow
/// "DELETE VAULT", the question, the body, then ghost "cancel"
/// (`delete-vault-cancel`) and danger "move to trash"
/// (`delete-vault-confirm`).
///
/// While the move runs both buttons are disabled and the dialog can't be
/// dismissed. It closes when the vault is deleted; a failure leaves it open
/// with the flow's message under the body, and "move to trash" tries again.
///
/// For the open local vault a line under the body says it closes first
/// (`delete-vault-open-line`), and "move to trash" runs
/// `VaultDeleter.deleteOpenVault` (close, settle, Trash, reopen on a
/// failure). While a backup of the vault runs, "move to trash" is disabled
/// with the backup line, until the backup ends.
class DeleteVaultDialog extends ConsumerStatefulWidget {
  const DeleteVaultDialog({super.key, required this.path});

  /// The full path of the vault folder.
  final String path;

  @override
  ConsumerState<DeleteVaultDialog> createState() => _DeleteVaultDialogState();
}

class _DeleteVaultDialogState extends ConsumerState<DeleteVaultDialog> {
  bool _busy = false;
  String? _error;

  /// Whether the delete running now started on the open vault. Decided at
  /// the press: the vault closes during it, and the dialog keeps the open
  /// vault's layout until the result (board S3, busy).
  bool _deletingOpen = false;

  Future<void> _delete() async {
    // The button is disabled while a backup of the vault runs; a press
    // that still arrives moves nothing.
    if (_busy || _backingUp()) return;
    final open = _isOpen(ref.read(currentVaultProvider));
    setState(() {
      _busy = true;
      _deletingOpen = open;
    });
    final deleter = ref.read(vaultDeleterProvider);
    final VaultDeleteResult result;
    try {
      // The open vault's delete runs from this dialog's context: closing
      // the vault unmounts whatever opened the dialog.
      result = open
          ? await deleter.deleteOpenVault(context, widget.path)
          : await deleter.delete(widget.path);
    } catch (_) {
      // Don't leave the dialog stuck busy (and undismissable) on a throw.
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    if (!mounted) return;
    switch (result) {
      case VaultDeleted():
        Navigator.of(context).pop();
      case VaultDeleteFailed(:final message):
        setState(() {
          _busy = false;
          // A backup that started during the delete refused it. That line
          // comes from the backup state, so it goes when the backup ends;
          // kept here it would stay after the button re-enables.
          _error = message == vaultBackupRunningMessage(widget.path)
              ? null
              : message;
        });
      case VaultDeleteCancelled():
        setState(() => _busy = false);
    }
  }

  bool _backingUp() =>
      isVaultBackingUp(ref.read(backupInFlightProvider), widget.path);

  /// Whether [current] is this dialog's vault, in any spelling of its
  /// folder ([isOpenVaultFolder]).
  bool _isOpen(VaultRef? current) =>
      current is LocalVaultRef && isOpenVaultFolder(current.path, widget.path);

  @override
  Widget build(BuildContext context) {
    final name = p.basename(widget.path);
    final isOpen = _isOpen(ref.watch(currentVaultProvider));
    final openLine = _busy ? _deletingOpen : isOpen;
    // A backup of this vault running refuses the delete until it ends
    // (Spec #357 Req 33); the dialog re-enables by itself.
    final backingUp = ref.watch(
      backupInFlightProvider.select(
        (paths) => isVaultBackingUp(paths, widget.path),
      ),
    );
    final error = backingUp ? vaultBackupRunningMessage(widget.path) : _error;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 472,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: OmColors.surface2,
            border: Border.all(color: OmColors.line2),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: OmColors.dialogShadow,
                offset: Offset(0, 24),
                blurRadius: 64,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('DELETE VAULT', style: OmType.eyebrow()),
              const SizedBox(height: 16),
              Text(
                'move $name to the trash?',
                style: OmType.sans(
                  size: 15,
                  weight: FontWeight.w600,
                  color: OmColors.fg0,
                  height: 21 / 15,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${widget.path} goes to the Trash. you can put it back from '
                'there until you empty it. its backups are kept.',
                style: OmType.sans(
                  size: 13.5,
                  color: OmColors.fg1,
                  height: 20.93 / 13.5,
                ),
              ),
              if (openLine) ...[
                const SizedBox(height: 12),
                _OpenLine(name: name),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                _ErrorLine(message: error),
              ],
              const SizedBox(height: 20),
              _EndAligned(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DialogButton(
                      key: const Key('delete-vault-cancel'),
                      kind: OmButtonKind.ghost,
                      label: 'cancel',
                      autofocus: true,
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                    DialogButton(
                      key: const Key('delete-vault-confirm'),
                      kind: OmButtonKind.danger,
                      icon: _busy ? LucideIcons.loader2 : null,
                      label: _busy ? 'moving to trash…' : 'move to trash',
                      onPressed: _busy || backingUp ? null : _delete,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The open-vault line (`delete-vault-open-line`, board S3): an `fg2` info
/// icon, then "[name] is open, so open memex will close it first.".
class _OpenLine extends StatelessWidget {
  const _OpenLine({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('delete-vault-open-line'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Icon(LucideIcons.info, size: 14, color: OmColors.fg2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$name is open, so open memex will close it first.',
            style: OmType.sans(
              size: 13.5,
              color: OmColors.fg1,
              height: 20.93 / 13.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// The failure line: a `danger` alert icon, then [message] in its own
/// live-region node. It never takes focus.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Icon(
            LucideIcons.triangleAlert,
            size: 14,
            color: OmColors.danger,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              message,
              style: OmType.sans(
                size: 12.5,
                color: OmColors.danger,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Lays [child] (the button Wrap) out at its natural width, against the
/// right edge, when that fits the width offered; otherwise at the offered
/// width, so the Wrap runs onto a second line.
///
/// `OmButton` fills the width it is offered, and a Wrap offers each child
/// its own full width, so without this each button would take a line.
class _EndAligned extends SingleChildRenderObjectWidget {
  const _EndAligned({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderEndAligned();
}

class _RenderEndAligned extends RenderShiftedBox {
  _RenderEndAligned() : super(null);

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    final natural = child!.getMaxIntrinsicWidth(double.infinity);
    return natural <= constraints.maxWidth
        ? constraints.copyWith(minWidth: 0, maxWidth: double.infinity)
        : constraints.loosen();
  }

  Size _sizeFor(BoxConstraints constraints, Size childSize) =>
      constraints.constrain(
        Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : childSize.width,
          childSize.height,
        ),
      );

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    if (child == null) return constraints.smallest;
    final childSize = child!.getDryLayout(_childConstraints(constraints));
    return _sizeFor(constraints, childSize);
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _sizeFor(constraints, c.size);
    (c.parentData! as BoxParentData).offset = Offset(
      size.width - c.size.width,
      0,
    );
  }
}
