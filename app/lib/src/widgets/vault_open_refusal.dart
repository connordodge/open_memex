import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/picker_actions.dart';
import '../state/settings.dart';
import '../state/vault_open_controller.dart';
import 'memex_too_old_dialog.dart';
import 'network_drive_refusal_dialog.dart';

/// Shows the refusal dialog for a refused local open: the network-drive
/// refusal for [VaultOnNetworkDrive] (whose "set up a vault server…" opens
/// the picker actions' set-up sheet and "connect to a vault server…" their
/// connect dialog, once the refusal closed), the too-old-memex refusal for
/// [VaultMemexTooOld] (whose "locate memex binary…" stores the picked
/// binary). [eyebrow] heads the dialog. Completes true when [outcome] was a
/// refusal, once its dialog (and what its choice opened) closed; false,
/// showing nothing, for any other outcome. [context] must be under the app's
/// `ProviderScope`.
Future<bool> showVaultOpenRefusal(
  BuildContext context,
  VaultOpenOutcome outcome, {
  required String eyebrow,
}) async {
  switch (outcome) {
    case VaultOnNetworkDrive(:final path):
      final actions = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(pickerActionsProvider);
      final choice = await showNetworkDriveRefusalDialog(
        context,
        path: path,
        eyebrow: eyebrow,
      );
      if (!context.mounted) return true;
      switch (choice) {
        case NetworkDriveRefusalChoice.setUpServer:
          await actions.setUp(context);
        case NetworkDriveRefusalChoice.connectServer:
          await actions.connect(context);
        case NetworkDriveRefusalChoice.cancel || null:
          break;
      }
      return true;
    case VaultMemexTooOld(:final path):
      final settings = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(settingsProvider.notifier);
      final choice = await showMemexTooOldDialog(
        context,
        path: path,
        eyebrow: eyebrow,
      );
      if (choice == MemexTooOldChoice.locateBinary) {
        await locateMemexBinary(settings);
      }
      return true;
    default:
      return false;
  }
}
