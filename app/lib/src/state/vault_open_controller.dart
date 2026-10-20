import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/vault_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import '../widgets/memex_too_old_dialog.dart';
import '../widgets/network_drive_refusal_dialog.dart';
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

  /// Reopens the last vault (`memex.last_vault`) at launch. The vault picker
  /// calls it once, when it first shows with a last vault set and no vault
  /// open (`currentVaultProvider` starts null, so launch shows the picker).
  ///
  /// With a vault open this changes nothing and completes [VaultOpened] with
  /// that vault. With no vault open and no last vault it completes
  /// [NoVaultToReopen]. Otherwise it opens the last vault as a
  /// [LocalVaultRef] through `memex vault check`, as a vault pill does (no
  /// folder shape check), and completes with that open's outcome. Launch
  /// writes no settings: the last vault and the recents order stay as they
  /// were.
  Future<VaultOpenOutcome> launchReopen() async {
    final current = _ref.read(currentVaultProvider);
    if (current != null) return VaultOpened(current);
    final last = _ref.read(settingsProvider).lastVault;
    if (last == null) return const NoVaultToReopen();
    return _openVault(LocalVaultRef(last), checkFolder: false, remember: false);
  }

  /// Opens [vault] after checking it: a local folder must hold
  /// `manifest.json` and `memex.db`, then `memex vault check` must pass. On
  /// success the vault is remembered (recents and last vault) and becomes
  /// the current vault; on any other outcome nothing changes.
  Future<VaultOpenOutcome> openVault(VaultRef vault) =>
      _openVault(vault, checkFolder: true, remember: true);

  /// The one open path behind [openVault], [switchToVault] and
  /// [launchReopen]. Every local open runs `memex vault check` before the
  /// vault becomes current, so before any SQLite handle opens.
  /// [checkFolder] is false for a vault pill and for launch, which have
  /// never checked the folder's shape. [remember] is false only for launch,
  /// which reopens the last vault without a settings write.
  Future<VaultOpenOutcome> _openVault(
    VaultRef vault, {
    required bool checkFolder,
    required bool remember,
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
        // Read on every open: no CLI handle is kept, so a newly located
        // binary is used by the next attempt.
        final cli = _ref.read(memexCliProvider);
        if (cli == null) {
          return const VaultBinaryNotFound(
            'Could not open vault: no memex binary is configured.',
          );
        }
        final refused = await _checkLocal(cli, path);
        if (refused != null) return refused;
        return _open(vault, remember: remember);
    }
  }

  /// Runs `memex vault check` on [path]: null when the folder is safe,
  /// otherwise the outcome that refuses it (D19).
  Future<VaultOpenFailure?> _checkLocal(MemexCli cli, String path) async {
    final r = await cli.checkVault(path);
    return switch (r.status) {
      VaultCheckStatus.safe => null,
      VaultCheckStatus.networkFilesystem => VaultOnNetworkDrive(
        path,
        networkDriveRefusalMessage,
      ),
      VaultCheckStatus.memexTooOld => VaultMemexTooOld(
        path,
        memexTooOldMessage,
      ),
      VaultCheckStatus.binaryNotFound => VaultBinaryNotFound(
        'memex binary not found: ${cli.binaryPath}',
      ),
      VaultCheckStatus.failed => VaultOpenFailure(
        'Could not open $path: ${r.error!.message}',
      ),
    };
  }

  /// Shows the refusal dialog for a refused local open: the network-drive
  /// refusal for [VaultOnNetworkDrive], the too-old-memex refusal for
  /// [VaultMemexTooOld] (whose "locate memex binary…" stores the picked
  /// binary). [eyebrow] heads the dialog. Completes true when [outcome] was
  /// a refusal, false (showing nothing) for any other outcome.
  Future<bool> showRefusal(
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
        final choice = await showMemexTooOldDialog(
          context,
          path: path,
          eyebrow: eyebrow,
        );
        if (choice == MemexTooOldChoice.locateBinary) {
          await locateMemexBinary(_ref.read(settingsProvider.notifier));
        }
        return true;
      default:
        return false;
    }
  }

  /// Creates a local vault at [fullPath] with `memex init`, then opens it as
  /// [openVault] does. A non-empty existing folder fails before anything
  /// runs. `memex vault check` runs on [fullPath] before `init`, and a
  /// refused folder never runs `init`. An `init` failure leaves the current
  /// vault as it was.
  Future<VaultOpenOutcome> createLocalVault(String fullPath) async {
    final dir = Directory(fullPath);
    if (dir.existsSync() && dir.listSync().isNotEmpty) {
      return VaultOpenFailure('$fullPath already exists and is not empty.');
    }
    final cli = _ref.read(memexCliProvider);
    if (cli == null) {
      return const VaultBinaryNotFound(
        'Could not create vault: no memex binary is configured.',
      );
    }
    final refused = await _checkLocal(cli, fullPath);
    if (refused != null) return refused;
    try {
      await cli.initVault(fullPath);
      return await _open(LocalVaultRef(fullPath), remember: true);
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
  /// the [openVault] path with `memex vault check` but without the folder
  /// shape check (pills have never checked it), and clears the selected note
  /// on [VaultOpened]. A refused folder shows its refusal dialog
  /// ([showRefusal]) over the workspace. Completes with the open's outcome,
  /// after any refusal dialog closed.
  Future<VaultOpenOutcome> switchToVault(
    BuildContext context,
    LocalVaultRef vault,
  ) async {
    if (!await _ref.read(leaveVaultGuardProvider)(context)) {
      return const VaultOpenCancelled();
    }
    final outcome = await _openVault(vault, checkFolder: false, remember: true);
    if (outcome is VaultOpened) {
      _ref.read(selectedNoteIdProvider.notifier).state = null;
    } else if (context.mounted) {
      await showRefusal(context, outcome, eyebrow: 'OPEN LOCAL VAULT');
    }
    return outcome;
  }

  Future<VaultOpenOutcome> _open(
    LocalVaultRef vault, {
    required bool remember,
  }) async {
    if (remember) {
      await _ref.read(settingsProvider.notifier).rememberVault(vault.path);
    }
    // Reopening the vault that is already current writes nothing: an equal
    // but not identical ref would notify every dependent again
    // (StateProvider compares by identity).
    final current = _ref.read(currentVaultProvider.notifier);
    if (current.state != vault) current.state = vault;
    return VaultOpened(vault);
  }
}

/// #92: `memex vault check` refused the folder at [path]: it is on a network
/// drive (exit 1, C1 `network_filesystem`). Nothing opened.
class VaultOnNetworkDrive extends VaultOpenFailure {
  const VaultOnNetworkDrive(this.path, super.message);

  final String path;
}

/// #92: the installed `memex` is too old to run `vault check` (exit 2), so
/// the folder at [path] was not opened.
class VaultMemexTooOld extends VaultOpenFailure {
  const VaultMemexTooOld(this.path, super.message);

  final String path;
}

/// #92: no `memex` binary is configured, or it could not be started. No
/// local vault opened.
class VaultBinaryNotFound extends VaultOpenFailure {
  const VaultBinaryNotFound(super.message);
}
