import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../memex_cli.dart';
import 'token_store.dart';
import 'vault_ref.dart';

/// A saved vault server (D18): an opaque [id] minted once when the server is
/// first saved, a [name] and a [url]. Editing the name or URL keeps the id, so
/// hosted recents and the Keychain item stay attached. The access token is
/// never part of this model: it lives only in the [TokenStore], under [id].
class SavedServer {
  const SavedServer({required this.id, required this.name, required this.url});

  final String id;
  final String name;
  final String url;
}

class AppSettings {
  AppSettings({
    required this.memexBinaryPath,
    required this.recentVaults,
    required this.lastVault,
  });

  final String? memexBinaryPath;
  final List<String> recentVaults;
  final String? lastVault;

  /// Typed recents (D18), local and hosted combined, most recent first, at
  /// most 8. A hosted entry is identified by saved-server id + vault name.
  List<VaultRef> get recentRefs => throw UnimplementedError();

  /// The typed last vault, or null.
  VaultRef? get lastVaultRef => throw UnimplementedError();

  /// Saved vault servers, in the order they were first saved.
  List<SavedServer> get savedServers => throw UnimplementedError();

  AppSettings copyWith({
    String? memexBinaryPath,
    List<String>? recentVaults,
    String? lastVault,
    bool clearLastVault = false,
  }) => AppSettings(
    memexBinaryPath: memexBinaryPath ?? this.memexBinaryPath,
    recentVaults: recentVaults ?? this.recentVaults,
    lastVault: clearLastVault ? null : (lastVault ?? this.lastVault),
  );
}

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController._(this._prefs, AppSettings initial) : super(initial);

  final SharedPreferences _prefs;

  static const _kBinary = 'memex.binary_path';
  static const _kRecents = 'memex.recent_vaults';
  static const _kLast = 'memex.last_vault';

  /// Loads settings. [tokenStore] keeps the saved servers' access tokens
  /// (default: the macOS Keychain).
  static Future<SettingsController> load({TokenStore? tokenStore}) async {
    final prefs = await SharedPreferences.getInstance();
    final binary = prefs.getString(_kBinary) ?? MemexCli.autodiscover();
    final recents = prefs.getStringList(_kRecents) ?? const <String>[];
    final last = prefs.getString(_kLast);
    return SettingsController._(
      prefs,
      AppSettings(
        memexBinaryPath: binary,
        recentVaults: recents,
        lastVault: last,
      ),
    );
  }

  Future<void> setMemexBinary(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kBinary);
    } else {
      await _prefs.setString(_kBinary, path);
    }
    state = state.copyWith(memexBinaryPath: path);
  }

  Future<void> rememberVault(String path) async {
    final list = [path, ...state.recentVaults.where((p) => p != path)];
    final trimmed = list.take(8).toList();
    await _prefs.setStringList(_kRecents, trimmed);
    await _prefs.setString(_kLast, path);
    state = state.copyWith(recentVaults: trimmed, lastVault: path);
  }

  Future<void> forgetVault(String path) async {
    final list = state.recentVaults.where((p) => p != path).toList();
    await _prefs.setStringList(_kRecents, list);
    if (state.lastVault == path) {
      await _prefs.remove(_kLast);
      state = state.copyWith(recentVaults: list, clearLastVault: true);
    } else {
      state = state.copyWith(recentVaults: list);
    }
  }

  Future<void> clearLastVault() async {
    await _prefs.remove(_kLast);
    state = state.copyWith(clearLastVault: true);
  }

  /// Puts [ref] first in the typed recents (no duplicate, capped at 8) and
  /// makes it the last vault.
  Future<void> rememberRef(VaultRef ref) => throw UnimplementedError();

  /// Drops [ref] from the typed recents, and clears the last vault if it was
  /// [ref].
  Future<void> forgetRef(VaultRef ref) => throw UnimplementedError();

  /// Saves a vault server: name and URL in settings, [token] in the token
  /// store under the server's id. A URL that's already saved (after
  /// normalising) updates that server's name and token and keeps its id.
  Future<SavedServer> saveServer({
    required String name,
    required String url,
    required String token,
  }) => throw UnimplementedError();

  /// Edits the saved server [id]; the id never changes.
  Future<SavedServer> updateServer(
    String id, {
    String? name,
    String? url,
    String? token,
  }) => throw UnimplementedError();

  /// Removes the saved server [id]: deletes its access token, drops its hosted
  /// recents, and clears the last vault if it was one of them.
  Future<void> removeServer(String id) => throw UnimplementedError();
}

final settingsProvider = StateNotifierProvider<SettingsController, AppSettings>(
  (_) => throw UnimplementedError('overridden in main()'),
);
