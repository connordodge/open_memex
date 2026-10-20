import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  Future<String?> read(String serverId) => throw UnimplementedError();

  @override
  Future<void> write(String serverId, String token) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String serverId) => throw UnimplementedError();
}

/// The app's token store. Tests override it with `FakeTokenStore`
/// (`test/support/token_store_fakes.dart`).
final tokenStoreProvider = Provider<TokenStore>(
  (_) => throw UnimplementedError(),
);
