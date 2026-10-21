// WI #91 (D18): the in-memory token store and the prefs helpers that hosted
// vault tests share. Never touches the real Keychain.
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An in-memory [TokenStore]. [tokens] maps saved-server id to access token;
/// a read answers with the last token written for that id.
class FakeTokenStore implements TokenStore {
  FakeTokenStore([Map<String, String>? initial]) : tokens = {...?initial};

  final Map<String, String> tokens;

  /// Every call as `read <id>`, `write <id>` or `delete <id>` (never the
  /// token itself).
  final List<String> calls = [];

  @override
  Future<String?> read(String serverId) async {
    calls.add('read $serverId');
    return tokens[serverId];
  }

  @override
  Future<void> write(String serverId, String token) async {
    calls.add('write $serverId');
    tokens[serverId] = token;
  }

  @override
  Future<void> delete(String serverId) async {
    calls.add('delete $serverId');
    tokens.remove(serverId);
  }
}

/// Every SharedPreferences entry as `key=value` (list values joined with
/// `|`), for scans that prove no access token reached prefs.
Future<List<String>> prefsEntries() async {
  final prefs = await SharedPreferences.getInstance();
  final out = <String>[];
  for (final key in prefs.getKeys()) {
    final value = prefs.get(key);
    final text = value is List ? value.join('|') : '$value';
    out.add('$key=$text');
  }
  return out;
}

/// The prefs entries (key or value) that contain [needle].
Future<List<String>> prefsEntriesContaining(String needle) async =>
    (await prefsEntries()).where((e) => e.contains(needle)).toList();

/// Simulates quitting and relaunching the app: copies every persisted prefs
/// value into a fresh mock store, drops the cached instance, and loads
/// settings again, as `main()` does. Only what was written to prefs survives.
Future<SettingsController> relaunchSettings({TokenStore? tokenStore}) async {
  final prefs = await SharedPreferences.getInstance();
  final dump = <String, Object>{
    for (final key in prefs.getKeys()) key: prefs.get(key)!,
  };
  SharedPreferences.setMockInitialValues(dump);
  return SettingsController.load(tokenStore: tokenStore);
}
