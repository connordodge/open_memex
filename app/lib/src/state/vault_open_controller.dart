import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import 'settings.dart';
import 'vault_state.dart';

/// What opening or creating a vault gave (D12). Data only; #92 and #96 add
/// their own variants.
sealed class VaultOpenOutcome {
  const VaultOpenOutcome();
}

/// The vault is open: `currentVaultProvider` holds [vault].
final class VaultOpened extends VaultOpenOutcome {
  const VaultOpened(this.vault);

  final VaultRef vault;
}

/// Opening or creating failed and nothing changed. [message] is the copy the
/// person sees.
class VaultOpenFailure extends VaultOpenOutcome {
  const VaultOpenFailure(this.message);

  final String message;
}

/// Asked before the current vault is left (switch vault, a vault pill).
/// Completes true to go ahead, false to stay.
typedef LeaveVaultGuard = Future<bool> Function(BuildContext context);

/// The guard asked before the current vault is left. The default always
/// allows; #103 supplies the confirm.
final leaveVaultGuardProvider = Provider<LeaveVaultGuard>((_) => _allowLeaving);

Future<bool> _allowLeaving(BuildContext _) async => true;

/// Opens, creates and leaves vaults for the picker and the sidebar (D12).
final vaultOpenControllerProvider = Provider<VaultOpenController>(
  VaultOpenController.new,
);

/// Owns every change of the open vault. Launch reopen stays with
/// `currentVaultProvider`'s default, which reads `memex.last_vault`.
class VaultOpenController {
  VaultOpenController(this._ref);

  final Ref _ref;

  /// Opens [vault] after checking it: a local folder must hold
  /// `manifest.json` and `memex.db`. On success the vault is remembered
  /// (recents and last vault) and becomes the current vault; on failure
  /// nothing changes.
  Future<VaultOpenOutcome> openVault(VaultRef vault) async {
    switch (vault) {
      case HostedVaultRef():
        // No hosted ref can be created yet (#96 opens them).
        return const VaultOpenFailure('Hosted vaults cannot be opened yet.');
      case LocalVaultRef(:final path):
        if (!VaultDb.isVault(path)) {
          return VaultOpenFailure(
            '$path does not look like a vault (no manifest.json + memex.db).',
          );
        }
        return _open(vault);
    }
  }

  /// Creates a local vault at [fullPath] with `memex init`, then opens it as
  /// [openVault] does. A non-empty existing folder fails before `init` runs;
  /// an `init` failure leaves the current vault as it was.
  Future<VaultOpenOutcome> createLocalVault(String fullPath) async {
    final dir = Directory(fullPath);
    if (dir.existsSync() && dir.listSync().isNotEmpty) {
      return VaultOpenFailure('$fullPath already exists and is not empty.');
    }
    final cli = _ref.read(memexCliProvider);
    if (cli == null) {
      return const VaultOpenFailure(
        'Could not create vault: no memex binary is configured.',
      );
    }
    try {
      await cli.initVault(fullPath);
      return await _open(LocalVaultRef(fullPath));
    } catch (e) {
      return VaultOpenFailure('Could not create vault: $e');
    }
  }

  /// Leaves the current vault for the picker (the vaults header "+ new"):
  /// clears the last vault, the current vault and the selected note. Asks
  /// [leaveVaultGuardProvider] first; completes false when it says stay.
  Future<bool> leaveVault(BuildContext context) async {
    if (!await _ref.read(leaveVaultGuardProvider)(context)) return false;
    await _ref.read(settingsProvider.notifier).clearLastVault();
    _ref.read(currentVaultProvider.notifier).state = null;
    _ref.read(selectedNoteIdProvider.notifier).state = null;
    return true;
  }

  /// Switches to [vault] from a sidebar vault pill: remembers and opens it
  /// without the folder check, and clears the selected note. Asks
  /// [leaveVaultGuardProvider] first; completes false when it says stay.
  Future<bool> switchToVault(BuildContext context, LocalVaultRef vault) async {
    if (!await _ref.read(leaveVaultGuardProvider)(context)) return false;
    await _open(vault);
    _ref.read(selectedNoteIdProvider.notifier).state = null;
    return true;
  }

  Future<VaultOpenOutcome> _open(LocalVaultRef vault) async {
    await _ref.read(settingsProvider.notifier).rememberVault(vault.path);
    _ref.read(currentVaultProvider.notifier).state = vault;
    return VaultOpened(vault);
  }
}
