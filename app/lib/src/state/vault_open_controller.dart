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

/// [LeaveVaultGuard] said stay: the current vault, the last vault and the
/// selected note are unchanged and nothing was opened. Not a failure; there
/// is nothing to show.
final class VaultOpenCancelled extends VaultOpenOutcome {
  const VaultOpenCancelled();
}

/// Launch found no open vault and no last vault (`memex.last_vault` unset):
/// nothing opened and the picker shows.
final class NoVaultToReopen extends VaultOpenOutcome {
  const NoVaultToReopen();
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

/// Owns every change of the open vault: launch reopen, open, create, switch
/// and leave.
class VaultOpenController {
  VaultOpenController(this._ref);

  final Ref _ref;

  /// Reopens the last vault (`memex.last_vault`) at launch. The app root
  /// calls it once, after the first frame.
  ///
  /// The reopen itself is still `currentVaultProvider`'s synchronous default,
  /// so the first frame already shows the last vault's workspace and launch
  /// behaves as before: with a vault open this changes nothing and completes
  /// [VaultOpened] with that vault. With no vault open and a last vault set
  /// it makes that folder the current vault as a [LocalVaultRef], with no
  /// folder check and no settings write, as the default does. With neither
  /// it completes [NoVaultToReopen].
  Future<VaultOpenOutcome> launchReopen() async {
    final current = _ref.read(currentVaultProvider);
    if (current != null) return VaultOpened(current);
    final last = _ref.read(settingsProvider).lastVault;
    if (last == null) return const NoVaultToReopen();
    final vault = LocalVaultRef(last);
    _ref.read(currentVaultProvider.notifier).state = vault;
    return VaultOpened(vault);
  }

  /// Opens [vault] after checking it: a local folder must hold
  /// `manifest.json` and `memex.db`. On success the vault is remembered
  /// (recents and last vault) and becomes the current vault; on failure
  /// nothing changes.
  Future<VaultOpenOutcome> openVault(VaultRef vault) =>
      _openVault(vault, checkFolder: true);

  /// The one open path behind [openVault] and [switchToVault].
  /// [checkFolder] is false only for a vault pill, which has never checked
  /// the folder; #92 replaces the check with `memex vault check` for every
  /// local open, pills included.
  Future<VaultOpenOutcome> _openVault(
    VaultRef vault, {
    required bool checkFolder,
  }) async {
    switch (vault) {
      case HostedVaultRef():
        // No hosted ref can be created yet (#96 opens them).
        return const VaultOpenFailure('Hosted vaults cannot be opened yet.');
      case LocalVaultRef(:final path):
        if (checkFolder && !VaultDb.isVault(path)) {
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

  /// Switches to [vault] from a sidebar vault pill. Asks
  /// [leaveVaultGuardProvider] once first: when it says stay, completes
  /// [VaultOpenCancelled] and changes nothing. Otherwise opens [vault] through
  /// the [openVault] path without the folder check (pills have never checked
  /// it; #92 adds `memex vault check` there), clears the selected note on
  /// [VaultOpened], and completes with the open's outcome.
  Future<VaultOpenOutcome> switchToVault(
    BuildContext context,
    LocalVaultRef vault,
  ) async {
    if (!await _ref.read(leaveVaultGuardProvider)(context)) {
      return const VaultOpenCancelled();
    }
    final outcome = await _openVault(vault, checkFolder: false);
    if (outcome is VaultOpened) {
      _ref.read(selectedNoteIdProvider.notifier).state = null;
    }
    return outcome;
  }

  Future<VaultOpenOutcome> _open(LocalVaultRef vault) async {
    await _ref.read(settingsProvider.notifier).rememberVault(vault.path);
    // Remembering a new last vault already rebuilt `currentVaultProvider` to
    // an equal ref. Writing another equal but not identical one would notify
    // every dependent a second time (StateProvider compares by identity).
    final current = _ref.read(currentVaultProvider.notifier);
    if (current.state != vault) current.state = vault;
    return VaultOpened(vault);
  }
}
