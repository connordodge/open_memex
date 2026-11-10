import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../memex_cli.dart';
import 'backup_models.dart';
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
  /// [recentVaults] and [lastVault] seed local-only typed recents when
  /// [recentRefs] / [lastVaultRef] aren't given (today's local-path form).
  AppSettings({
    required this.memexBinaryPath,
    List<String>? recentVaults,
    String? lastVault,
    List<VaultRef>? recentRefs,
    VaultRef? lastVaultRef,
    List<SavedServer>? savedServers,
    Map<String, VaultBackupSettings>? vaultBackups,
  }) : recentRefs = List.unmodifiable(
         recentRefs ??
             [
               for (final p in recentVaults ?? const <String>[])
                 LocalVaultRef(p),
             ],
       ),
       lastVaultRef =
           lastVaultRef ??
           (lastVault == null ? null : LocalVaultRef(lastVault)),
       savedServers = List.unmodifiable(savedServers ?? const <SavedServer>[]),
       vaultBackups = Map.unmodifiable(
         vaultBackups ?? const <String, VaultBackupSettings>{},
       );

  final String? memexBinaryPath;

  /// Typed recents (D18), local and hosted combined, most recent first, at
  /// most 8. A hosted entry is identified by saved-server id + vault name.
  final List<VaultRef> recentRefs;

  /// The typed last vault, or null.
  final VaultRef? lastVaultRef;

  /// Saved vault servers, in the order they were first saved.
  final List<SavedServer> savedServers;

  /// Per-vault backup settings (D22), keyed by the local vault path as
  /// opened. Unmodifiable. Absent key = the defaults.
  final Map<String, VaultBackupSettings> vaultBackups;

  /// The local paths in [recentRefs], in order. Hosted entries are left out.
  late final List<String> recentVaults = List.unmodifiable([
    for (final r in recentRefs)
      if (r is LocalVaultRef) r.path,
  ]);

  /// The last vault's folder while it is local; null while it is hosted.
  String? get lastVault => lastVaultRef.localPath;

  /// [recentVaults] / [lastVault] replace the typed values with local refs
  /// when the typed ones aren't given.
  AppSettings copyWith({
    String? memexBinaryPath,
    List<String>? recentVaults,
    String? lastVault,
    bool clearLastVault = false,
    List<VaultRef>? recentRefs,
    VaultRef? lastVaultRef,
    List<SavedServer>? savedServers,
    Map<String, VaultBackupSettings>? vaultBackups,
  }) => AppSettings(
    memexBinaryPath: memexBinaryPath ?? this.memexBinaryPath,
    recentRefs:
        recentRefs ??
        (recentVaults == null
            ? this.recentRefs
            : [for (final p in recentVaults) LocalVaultRef(p)]),
    lastVaultRef: clearLastVault
        ? null
        : (lastVaultRef ??
              (lastVault == null
                  ? this.lastVaultRef
                  : LocalVaultRef(lastVault))),
    savedServers: savedServers ?? this.savedServers,
    vaultBackups: vaultBackups ?? this.vaultBackups,
  );
}

/// The form two vault server URLs are compared in: scheme and host
/// lowercased, a default port (80 for `http`, 443 for `https`) dropped and a
/// trailing `/` stripped. The path keeps its case.
String normalizeServerUrl(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return _stripTrailingSlash(trimmed);
  }
  final scheme = uri.scheme.toLowerCase();
  final defaultPort = switch (scheme) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return '$scheme://${uri.host.toLowerCase()}$port'
      '${_stripTrailingSlash(uri.path)}$query';
}

String _stripTrailingSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController._(this._prefs, this._tokens, AppSettings initial)
    : super(initial);

  final SharedPreferences _prefs;
  final TokenStore _tokens;

  static const _kBinary = 'memex.binary_path';

  // Today's keys: read once by the migration, never deleted, and kept as a
  // local-only mirror so older builds keep their local recents.
  static const _kRecents = 'memex.recent_vaults';
  static const _kLast = 'memex.last_vault';

  // The typed keys (D18). [_kRecentRefs] existing means the migration ran.
  static const _kRecentRefs = 'memex.recent_refs';
  static const _kLastRef = 'memex.last_vault_ref';
  static const _kServers = 'memex.vault_servers';

  // Per-vault backup settings (D22): a JSON object, vault path -> toJson.
  static const _kVaultBackups = 'memex.vault_backups';

  static const _maxRecents = 8;

  /// Loads settings. [tokenStore] keeps the saved servers' access tokens
  /// (default: the macOS Keychain).
  static Future<SettingsController> load({
    TokenStore? tokenStore,
    String? executablePath,
    bool Function(String path)? exists,
    String? home,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // A picked path that no longer exists is skipped, never removed from
    // prefs, so it works again if the file comes back.
    final binary = MemexCli.autodiscover(
      executablePath: executablePath,
      exists: exists,
      home: home,
      picked: prefs.getString(_kBinary),
    );

    final List<VaultRef> refs;
    final VaultRef? last;
    if (prefs.containsKey(_kRecentRefs)) {
      refs = [
        for (final e in prefs.getStringList(_kRecentRefs) ?? const <String>[])
          ?_decodeRef(e),
      ];
      final lastText = prefs.getString(_kLastRef);
      last = lastText == null ? null : _decodeRef(lastText);
    } else {
      // One-time migration from today's keys, which stay in place.
      refs = [
        for (final p in prefs.getStringList(_kRecents) ?? const <String>[])
          LocalVaultRef(p),
      ].take(_maxRecents).toList();
      final oldLast = prefs.getString(_kLast);
      last = oldLast == null ? null : LocalVaultRef(oldLast);
      await prefs.setStringList(_kRecentRefs, refs.map(_encodeRef).toList());
      if (last != null) await prefs.setString(_kLastRef, _encodeRef(last));
    }

    final servers = [
      for (final e in prefs.getStringList(_kServers) ?? const <String>[])
        ?_decodeServer(e),
    ];

    return SettingsController._(
      prefs,
      tokenStore ?? const KeychainTokenStore(),
      AppSettings(
        memexBinaryPath: binary,
        recentRefs: refs,
        lastVaultRef: last,
        savedServers: servers,
        vaultBackups: _decodeVaultBackups(prefs.get(_kVaultBackups)),
      ),
    );
  }

  /// Saves [settings] for the local vault at [path] (the path as opened) and
  /// changes no other vault's entry or preference.
  Future<void> setVaultBackup(String path, VaultBackupSettings settings) async {
    final updated = {...state.vaultBackups, path: settings};
    await _prefs.setString(
      _kVaultBackups,
      jsonEncode({for (final e in updated.entries) e.key: e.value.toJson()}),
    );
    state = state.copyWith(vaultBackups: updated);
  }

  /// Removes the backup settings saved for the local vault at [path] and
  /// changes no other vault's entry; a no-op when there is none.
  Future<void> removeVaultBackup(String path) async {
    if (!state.vaultBackups.containsKey(path)) return;
    final updated = {...state.vaultBackups}..remove(path);
    await _prefs.setString(
      _kVaultBackups,
      jsonEncode({for (final e in updated.entries) e.key: e.value.toJson()}),
    );
    state = state.copyWith(vaultBackups: updated);
  }

  Future<void> setMemexBinary(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kBinary);
    } else {
      await _prefs.setString(_kBinary, path);
    }
    state = state.copyWith(memexBinaryPath: path);
  }

  Future<void> rememberVault(String path) => rememberRef(LocalVaultRef(path));

  Future<void> forgetVault(String path) => forgetRef(LocalVaultRef(path));

  Future<void> clearLastVault() async {
    await _prefs.remove(_kLastRef);
    await _prefs.remove(_kLast);
    state = state.copyWith(clearLastVault: true);
  }

  /// Puts [ref] first in the typed recents (no duplicate, capped at 8) and
  /// makes it the last vault.
  Future<void> rememberRef(VaultRef ref) async {
    final refs = [
      ref,
      ...state.recentRefs.where((r) => r != ref),
    ].take(_maxRecents).toList();
    await _writeRecents(refs);
    await _prefs.setString(_kLastRef, _encodeRef(ref));
    // The old key mirrors only local last vaults.
    if (ref is LocalVaultRef) await _prefs.setString(_kLast, ref.path);
    state = state.copyWith(recentRefs: refs, lastVaultRef: ref);
  }

  /// Drops [ref] from the typed recents, and clears the last vault if it was
  /// [ref].
  Future<void> forgetRef(VaultRef ref) async {
    final refs = state.recentRefs.where((r) => r != ref).toList();
    await _writeRecents(refs);
    // An older build must not reopen a local vault forgotten here.
    if (ref is LocalVaultRef && _prefs.getString(_kLast) == ref.path) {
      await _prefs.remove(_kLast);
    }
    if (state.lastVaultRef == ref) {
      await _prefs.remove(_kLastRef);
      state = state.copyWith(recentRefs: refs, clearLastVault: true);
    } else {
      state = state.copyWith(recentRefs: refs);
    }
  }

  /// Saves a vault server: name and URL in settings, [token] in the token
  /// store under the server's id. A URL that's already saved (after
  /// normalising) updates that server's name and token and keeps its id.
  Future<SavedServer> saveServer({
    required String name,
    required String url,
    required String token,
  }) async {
    final key = normalizeServerUrl(url);
    for (final s in state.savedServers) {
      if (normalizeServerUrl(s.url) == key) {
        return updateServer(s.id, name: name, token: token);
      }
    }
    final server = SavedServer(id: _mintServerId(), name: name, url: url);
    await _tokens.write(server.id, token);
    await _writeServers([...state.savedServers, server]);
    return server;
  }

  /// Edits the saved server [id]; the id never changes.
  Future<SavedServer> updateServer(
    String id, {
    String? name,
    String? url,
    String? token,
  }) async {
    final old = state.savedServers.firstWhere(
      (s) => s.id == id,
      orElse: () => throw StateError('no saved vault server $id'),
    );
    final server = SavedServer(
      id: id,
      name: name ?? old.name,
      url: url ?? old.url,
    );
    if (token != null) await _tokens.write(id, token);
    await _writeServers([
      for (final s in state.savedServers) s.id == id ? server : s,
    ]);
    return server;
  }

  /// Removes the saved server [id]: drops it, its hosted recents and the last
  /// vault if it was one of them, then deletes its access token. Settings are
  /// written first, so a failed token delete (which still throws) never
  /// leaves the removed server saved.
  Future<void> removeServer(String id) async {
    bool onServer(VaultRef? r) => r is HostedVaultRef && r.serverId == id;

    await _writeServers(state.savedServers.where((s) => s.id != id).toList());
    final refs = state.recentRefs.where((r) => !onServer(r)).toList();
    await _writeRecents(refs);
    final clearLast = onServer(state.lastVaultRef);
    if (clearLast) await _prefs.remove(_kLastRef);
    state = state.copyWith(recentRefs: refs, clearLastVault: clearLast);
    await _tokens.delete(id);
  }

  /// Writes the typed recents and mirrors their local paths, in order, to
  /// today's recents key.
  Future<void> _writeRecents(List<VaultRef> refs) async {
    await _prefs.setStringList(_kRecentRefs, refs.map(_encodeRef).toList());
    await _prefs.setStringList(_kRecents, [
      for (final r in refs)
        if (r is LocalVaultRef) r.path,
    ]);
  }

  Future<void> _writeServers(List<SavedServer> servers) async {
    await _prefs.setStringList(_kServers, [
      for (final s in servers)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ]);
    state = state.copyWith(savedServers: servers);
  }

  /// An opaque, random server id, never derived from the URL or the access
  /// token.
  static String _mintServerId() {
    final rng = Random.secure();
    final hex = [
      for (var i = 0; i < 16; i++)
        rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    return 'srv-$hex';
  }

  static String _encodeRef(VaultRef ref) => jsonEncode(switch (ref) {
    LocalVaultRef(:final path) => {'kind': 'local', 'path': path},
    HostedVaultRef(:final serverId, :final vaultName) => {
      'kind': 'hosted',
      'server': serverId,
      'vault': vaultName,
    },
  });

  static VaultRef? _decodeRef(String text) => switch (_tryDecode(text)) {
    {'kind': 'local', 'path': final String path} => LocalVaultRef(path),
    {
      'kind': 'hosted',
      'server': final String serverId,
      'vault': final String vaultName,
    } =>
      HostedVaultRef(serverId, vaultName),
    _ => null,
  };

  static SavedServer? _decodeServer(String text) => switch (_tryDecode(text)) {
    {
      'id': final String id,
      'name': final String name,
      'url': final String url,
    } =>
      SavedServer(id: id, name: name, url: url),
    _ => null,
  };

  /// The stored `memex.vault_backups` value. An absent, wrong-typed or
  /// malformed value is an empty map; a malformed entry drops only its vault.
  /// A stored `keep` outside 1-365 is clamped into range (the model only
  /// asserts it in debug builds).
  static Map<String, VaultBackupSettings> _decodeVaultBackups(Object? stored) {
    if (stored is! String) return const {};
    final decoded = _tryDecode(stored);
    if (decoded is! Map) return const {};
    final result = <String, VaultBackupSettings>{};
    for (final e in decoded.entries) {
      final key = e.key;
      final value = e.value;
      if (key is! String || value is! Map) continue;
      final json = <String, Object?>{
        for (final f in value.entries)
          if (f.key is String) f.key as String: f.value,
      };
      final keep = json['keep'];
      if (keep is int) {
        json['keep'] = max(backupKeepMin, min(backupKeepMax, keep));
      }
      try {
        result[key] = VaultBackupSettings.fromJson(json);
      } on FormatException {
        // Only this vault's entry is dropped.
      }
    }
    return result;
  }

  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsController, AppSettings>(
  (_) => throw UnimplementedError('overridden in main()'),
);
