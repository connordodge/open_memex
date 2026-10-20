// WI #69 (D12): `currentVaultProvider` holds a `VaultRef?`, sealed
// `LocalVaultRef(path)` / `HostedVaultRef(serverId, vaultName)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_memex_cli.dart';
import '../support/vault_folders.dart';

/// Launch the app state as `main()` does: settings loaded from (mock)
/// SharedPreferences, no override of `currentVaultProvider`.
Future<ProviderContainer> _launch(
  Map<String, Object> prefs, {
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    ...prefs,
  });
  final settings = await SettingsController.load();
  final c = ProviderContainer(
    overrides: [settingsProvider.overrideWith((_) => settings), ...overrides],
  );
  addTearDown(c.dispose);
  return c;
}

ProviderContainer _withVault(VaultRef? vault, {FakeMemexCli? cli}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      memexCliProvider.overrideWithValue(cli),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('VaultRef value equality', () {
    test('two LocalVaultRefs with the same path are equal', () {
      // Built from run-time strings, not const instances.
      final path = ['', 'tmp', 'vault-a'].join('/');
      final a = LocalVaultRef(path);
      final b = LocalVaultRef('${'/tmp'}/vault-a');
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.path, '/tmp/vault-a');
      expect({a, b}, hasLength(1));
    });

    test('LocalVaultRefs with different paths are not equal', () {
      expect(LocalVaultRef('/tmp/a') == LocalVaultRef('/tmp/b'), isFalse);
    });

    test('two HostedVaultRefs with the same server and vault are equal', () {
      final server = ['srv', '1'].join('-');
      final a = HostedVaultRef(server, 'work');
      final b = HostedVaultRef('srv-1', ['wo', 'rk'].join());
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.serverId, 'srv-1');
      expect(a.vaultName, 'work');
      expect({a, b}, hasLength(1));
    });

    test('HostedVaultRefs differing in server or vault are not equal', () {
      final base = HostedVaultRef('srv-1', 'work');
      expect(base == HostedVaultRef('srv-2', 'work'), isFalse);
      expect(base == HostedVaultRef('srv-1', 'home'), isFalse);
    });

    test('a LocalVaultRef never equals a HostedVaultRef', () {
      final local = LocalVaultRef('work');
      final hosted = HostedVaultRef('work', 'work');
      expect(local == hosted, isFalse);
      expect(hosted == local, isFalse);
    });
  });

  group('currentVaultProvider at launch (AC1)', () {
    test('with a last vault P it is LocalVaultRef of P', () async {
      final dir = createVaultFolder();
      final c = await _launch({
        'memex.recent_vaults': <String>[dir.path],
        'memex.last_vault': dir.path,
      });
      expect(c.read(currentVaultProvider), LocalVaultRef(dir.path));
    });

    test('with no last vault it is null', () async {
      final dir = createVaultFolder();
      final c = await _launch({
        'memex.recent_vaults': <String>[dir.path],
      });
      expect(c.read(currentVaultProvider), isNull);
    });
  });

  group('vaultDbProvider (AC2)', () {
    test('a HostedVaultRef gives no database and opens nothing', () {
      // The vault name is a real vault folder on disk: a hosted ref must
      // still never open SQLite.
      final dir = createVaultFolder();
      final c = _withVault(HostedVaultRef('srv-1', dir.path));
      expect(c.read(vaultDbProvider), isNull);
      expect(c.read(vaultV5ReadyProvider), isFalse);
    });

    test(
      'a HostedVaultRef takes the no vault branch of vaultOpenProvider',
      () async {
        final dir = createVaultFolder();
        final cli = FakeMemexCli()
          ..on('settings get', (_) => FakeMemexCli.ok('{"value":2}'));
        final c = _withVault(HostedVaultRef('srv-1', dir.path), cli: cli);

        final state = await c.read(vaultOpenProvider.future);

        expect(state.schemaOutdated, isFalse);
        expect(state.smartFolderMaxDepth, isNull);
        expect(cli.calls, isEmpty);
      },
    );

    test('a LocalVaultRef of a vault folder opens its database', () {
      final dir = createVaultFolder();
      final c = _withVault(LocalVaultRef(dir.path));
      final db = c.read(vaultDbProvider);
      expect(db, isNotNull);
      expect(db!.schemaVersion(), 5);
      expect(c.read(vaultV5ReadyProvider), isTrue);
    });

    test('a LocalVaultRef of a folder that is not a vault gives null', () {
      final dir = createPlainFolder();
      final c = _withVault(LocalVaultRef(dir.path));
      expect(c.read(vaultDbProvider), isNull);
    });

    test('no vault gives null', () {
      final c = _withVault(null);
      expect(c.read(vaultDbProvider), isNull);
    });
  });
}
