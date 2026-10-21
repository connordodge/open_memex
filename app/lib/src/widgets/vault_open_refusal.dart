import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';
import '../state/vault_open_controller.dart';
import 'memex_too_old_dialog.dart';
import 'network_drive_refusal_dialog.dart';

/// Shows the refusal dialog for a refused local open: the network-drive
/// refusal for [VaultOnNetworkDrive], the too-old-memex refusal for
/// [VaultMemexTooOld] (whose "locate memex binary…" stores the picked
/// binary). [eyebrow] heads the dialog. Completes true when [outcome] was a
/// refusal, once its dialog closed; false, showing nothing, for any other
/// outcome. [context] must be under the app's `ProviderScope`.
Future<bool> showVaultOpenRefusal(
  BuildContext context,
  VaultOpenOutcome outcome, {
  required String eyebrow,
}) async {
  switch (outcome) {
    case VaultOnNetworkDrive(:final path):
      await showNetworkDriveRefusalDialog(
        context,
        path: path,
        eyebrow: eyebrow,
      );
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
