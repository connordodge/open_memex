import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps each vault server's access token, keyed by the saved server's id
/// (D18). Access tokens live only here: never in SharedPreferences, logs or
/// UI state.
abstract interface class TokenStore {
  /// The access token saved for [serverId], or null when there is none.
  Future<String?> read(String serverId);

  /// Saves [token] as the access token for [serverId], replacing any earlier
  /// one.
  Future<void> write(String serverId, String token);

  /// Deletes the access token for [serverId]. Deleting a missing token is a
  /// no-op.
  Future<void> delete(String serverId);
}

/// The macOS Keychain token store: `flutter_secure_storage` with
/// `MacOsOptions(usesDataProtectionKeychain: false)`, the legacy file
/// keychain (the ad-hoc-signed, unsandboxed app can't hold
/// `keychain-access-groups`). The item key is derived only from the server id.
class KeychainTokenStore implements TokenStore {
  const KeychainTokenStore();

  /// The legacy file keychain, passed on every call.
  static const _options = MacOsOptions(usesDataProtectionKeychain: false);

  static const _storage = FlutterSecureStorage(mOptions: _options);

  /// The Keychain item key for [serverId]: derived only from the id, so it
  /// never contains the access token.
  static String _key(String serverId) => 'memex.vault_server_token.$serverId';

  @override
  Future<String?> read(String serverId) =>
      _storage.read(key: _key(serverId), mOptions: _options);

  @override
  Future<void> write(String serverId, String token) =>
      _storage.write(key: _key(serverId), value: token, mOptions: _options);

  @override
  Future<void> delete(String serverId) =>
      _storage.delete(key: _key(serverId), mOptions: _options);
}

/// The app's token store. Tests override it with `FakeTokenStore`
/// (`test/support/token_store_fakes.dart`).
final tokenStoreProvider = Provider<TokenStore>(
  (_) => const KeychainTokenStore(),
);
