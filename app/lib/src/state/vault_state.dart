import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/settings_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import 'settings.dart';
import 'vault_ref.dart';

export 'canvas_state.dart' show canvasDetailProvider, canvasesProvider;
export 'links_state.dart';
export 'note_state.dart';
export 'notes_list_state.dart';
export 'vault_ref.dart';

/// The open vault. `null` means no vault is open. It starts null: at launch
/// the last vault (`memex.last_vault`) reopens only through `memex vault
/// check` (`VaultOpenController.launchReopen`, #92), never directly.
final currentVaultProvider = StateProvider<VaultRef?>((_) => null);

/// SQLite read handle for the current vault. Null with no vault open and for
/// a hosted vault (it never opens SQLite).
final vaultDbProvider = Provider<VaultDb?>((ref) {
  final path = ref.watch(currentVaultProvider).localPath;
  if (path == null) return null;
  if (!VaultDb.isVault(path)) return null;
  final db = VaultDb.open(path);
  ref.onDispose(db.close);
  return db;
});

/// Memex CLI handle bound to the configured binary path.
final memexCliProvider = Provider<MemexCli?>((ref) {
  final binary = ref.watch(settingsProvider).memexBinaryPath;
  if (binary == null || binary.isEmpty) return null;
  return MemexCli(binaryPath: binary);
});

/// A monotonic counter that increments whenever the vault should be re-read
/// from disk. Bump it after every write.
final vaultRevisionProvider = StateProvider<int>((_) => 0);

/// What opening the current vault found (see [vaultOpenProvider]).
class VaultOpenState {
  const VaultOpenState({
    required this.schemaOutdated,
    this.smartFolderMaxDepth,
  });

  /// True when the vault is still below schema V5 after the open call (the
  /// configured `memex` is missing or too old to migrate it). The workspace
  /// shows the `vault-schema-outdated` banner.
  final bool schemaOutdated;

  /// The vault's `smart_folder_max_depth` setting from the open call, or null
  /// when the call failed or no `memex` binary is configured.
  final int? smartFolderMaxDepth;
}

/// The minimum vault schema this app reads in full.
const requiredVaultSchemaVersion = 5;

/// Opens the current vault: runs `memex settings get --key
/// smart_folder_max_depth` once per opened vault, which migrates an older
/// vault to V5 through the CLI (the app's own handle is read-only). On
/// success it bumps [vaultRevisionProvider] so every read re-runs against the
/// migrated schema. Afterwards it re-reads the schema version: below V5 means
/// the vault is outdated for this app.
///
/// Watches only the vault path, the database and the CLI, so later revision
/// bumps never re-run the call. Never throws: a missing or failing binary
/// yields a state, not an error.
final vaultOpenProvider = FutureProvider<VaultOpenState>((ref) async {
  final vault = ref.watch(currentVaultProvider);
  // Req 53: the server owns a hosted vault's schema: no `settings get`, no
  // schema check.
  if (vault is HostedVaultRef) {
    return const VaultOpenState(schemaOutdated: false);
  }
  final path = vault.localPath;
  final db = ref.watch(vaultDbProvider);
  final cli = ref.watch(memexCliProvider);
  if (path == null || db == null) {
    return const VaultOpenState(schemaOutdated: false);
  }
  int? maxDepth;
  if (cli != null) {
    try {
      maxDepth = await cli.getSetting(path, smartFolderMaxDepthKey);
    } on Exception {
      // MemexException (older memex, locked vault, …) or ProcessException
      // (binary missing): fall through to the schema check.
    }
  }
  if (maxDepth != null) {
    ref.read(vaultRevisionProvider.notifier).state++;
  }
  return VaultOpenState(
    schemaOutdated: db.schemaVersion() < requiredVaultSchemaVersion,
    smartFolderMaxDepth: maxDepth,
  );
});

/// True when the open vault has every V5 table. V5 reads (daily notes,
/// review, Smart Folders) return empty while it is false instead of throwing.
/// Re-probed on every vault revision and when the open call completes, so a
/// pre-migration `false` is never cached. Always true for a hosted vault:
/// the server owns its migrations (D12a).
final vaultV5ReadyProvider = Provider<bool>((ref) {
  if (ref.watch(currentVaultProvider) is HostedVaultRef) return true;
  ref.watch(vaultRevisionProvider);
  ref.watch(vaultOpenProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return false;
  return db.hasTables(VaultDb.v5TableNames);
});

/// The currently selected note id (or null).
final selectedNoteIdProvider = StateProvider<String?>((_) => null);

/// Whether the right (Connections) panel is visible. Lives here so the
/// Workspace shell and the canvas zoom-in path can both reach it.
final rightPanelOpenProvider = StateProvider<bool>((_) => true);

enum SaveStatus { idle, dirty, saving, clean, error, conflict }

class EditorStateValue {
  const EditorStateValue({
    required this.title,
    required this.contentMd,
    required this.status,
    this.errorMessage,
    this.lastSavedVersion,
  });
  final String title;
  final String contentMd;
  final SaveStatus status;
  final String? errorMessage;
  final int? lastSavedVersion;

  EditorStateValue copyWith({
    String? title,
    String? contentMd,
    SaveStatus? status,
    String? errorMessage,
    bool clearError = false,
    int? lastSavedVersion,
  }) => EditorStateValue(
    title: title ?? this.title,
    contentMd: contentMd ?? this.contentMd,
    status: status ?? this.status,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    lastSavedVersion: lastSavedVersion ?? this.lastSavedVersion,
  );
}
