// WI #321 (A0, D19, D22): per-vault backup settings. The providers'
// signatures are frozen; their bodies are the stubs A2 (#323) replaces (A2
// reads and writes `AppSettings.vaultBackups`).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_models.dart';

/// The stored settings of the local vault at [path] (the path as opened), or
/// the defaults (`VaultBackupSettings()`) when none are stored.
final vaultBackupSettingsProvider =
    Provider.family<VaultBackupSettings, String>(
      (ref, path) => const VaultBackupSettings(),
    );

/// Saves [settings] for the local vault at `vaultPath` (shared preferences,
/// then state). Read it with `ref.read(saveVaultBackupSettingsProvider)` from
/// a widget or a provider alike.
final saveVaultBackupSettingsProvider =
    Provider<
      Future<void> Function(String vaultPath, VaultBackupSettings settings)
    >((ref) => (vaultPath, settings) async {});
