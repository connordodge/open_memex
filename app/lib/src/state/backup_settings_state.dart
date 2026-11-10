// WI #321 (A0, D19, D22): per-vault backup settings. The providers'
// signatures are frozen. WI #323 (A2) fills the bodies over
// `AppSettings.vaultBackups`.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_models.dart';
import 'settings.dart';

/// The stored settings of the local vault at [path] (the path as opened), or
/// the defaults (`VaultBackupSettings()`) when none are stored.
final vaultBackupSettingsProvider =
    Provider.family<VaultBackupSettings, String>(
      (ref, path) =>
          ref.watch(settingsProvider.select((s) => s.vaultBackups[path])) ??
          const VaultBackupSettings(),
    );

/// Saves [settings] for the local vault at `vaultPath` (shared preferences,
/// then state). Read it with `ref.read(saveVaultBackupSettingsProvider)` from
/// a widget or a provider alike. It only stores: turning backups off or
/// changing the destination runs no CLI call and deletes no file.
final saveVaultBackupSettingsProvider =
    Provider<
      Future<void> Function(String vaultPath, VaultBackupSettings settings)
    >(
      (ref) =>
          (vaultPath, settings) => ref
              .read(settingsProvider.notifier)
              .setVaultBackup(vaultPath, settings),
    );
