import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import 'vault_picker_body.dart';

/// Shows the vault picker as a centred modal over the open vault (Spec #357
/// Req 5, 6, 6a, design A1/A2): the picker body in a dialog keyed
/// `vault-picker-modal`, with the header's `esc` hint and the × close button
/// (`vault-picker-modal-close`). Esc, × and a scrim click close it with
/// nothing changed, and it closes whenever `currentVaultProvider` changes
/// while it shows. Completes when it has closed.
Future<void> showVaultPickerModal(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: OmColors.dialogShadow,
  barrierDismissible: true,
  // Design flows F1/F3: no transition.
  animationStyle: AnimationStyle.noAnimation,
  builder: (_) => const _VaultPickerModal(),
);

/// The dialog card (pack 362): `min(640, window width - 48)` wide, height
/// hugging its content (scrolling when the window is shorter), `surface1`
/// with a 1 px `line3` border, radius 10, and 32/40 padding inside the
/// border, over the `dialogShadow` scrim.
class _VaultPickerModal extends ConsumerStatefulWidget {
  const _VaultPickerModal();

  @override
  ConsumerState<_VaultPickerModal> createState() => _VaultPickerModalState();
}

class _VaultPickerModalState extends ConsumerState<_VaultPickerModal> {
  /// × or a click on the open vault's row: closes the modal (the top route
  /// then).
  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// The current vault changed (Req 6a): removes this modal's own route,
  /// leaving any route above it (the open vault's delete dialog) in place.
  void _closeForVaultChange() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeForVaultChange();
      });
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    Navigator.of(context).removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<VaultRef?>(currentVaultProvider, (previous, next) {
      if (previous != next) _closeForVaultChange();
    });
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const Key('vault-picker-modal'),
          width: math.max(0, math.min(640, size.width - 48)),
          constraints: BoxConstraints(maxHeight: math.max(0, size.height - 48)),
          decoration: BoxDecoration(
            color: OmColors.surface1,
            border: Border.all(color: OmColors.line3),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: OmColors.dialogShadow,
                offset: Offset(0, 24),
                blurRadius: 64,
              ),
            ],
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
            child: VaultPickerBody(onClose: _close),
          ),
        ),
      ),
    );
  }
}
