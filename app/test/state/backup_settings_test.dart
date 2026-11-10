// WI #323 (A2, D22): per-vault backup settings. `AppSettings.vaultBackups`
// round-trips through `memex.vault_backups`, every existing setter and
// `copyWith` carry it forward, `setVaultBackup` touches one vault only, and
// `vaultBackupSettingsProvider` / `saveVaultBackupSettingsProvider` read and
// write it. Turning backups off or changing the destination runs no CLI and
// deletes nothing.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/backup_harness.dart';
import '../support/token_store_fakes.dart';

const _prefKey = 'memex.vault_backups';

// Paths with a space, `~` and `@` are the normal case.
const _vaultA = '/Users/test/My Vaults/alpha @home~1';
const _vaultB = '/Volumes/NAS share/bravo';
const _vaultC = '/Users/test/charlie';

/// Built from run-time values, so the constructor really runs.
VaultBackupSettings _settingsA() => VaultBackupSettings(
  enabled: true,
  destination: '/Volumes/NAS share/Open Memex Backups',
  keep: 45,
  automatic: false,
);

VaultBackupSettings _settingsB() => VaultBackupSettings(
  enabled: false,
  destination:
      '/Users/test/Library/Mobile Documents/com~apple~CloudDocs/'
      'Open Memex Backups',
  keep: 7,
);

VaultBackupSettings _settingsC() => VaultBackupSettings(
  enabled: true,
  destination: '/Volumes/Big Disk/Open Memex Backups',
  keep: 365,
);

Map<String, VaultBackupSettings> _seed() => {
  _vaultA: _settingsA(),
  _vaultB: _settingsB(),
};

String _seedJson() =>
    jsonEncode({for (final e in _seed().entries) e.key: e.value.toJson()});

Future<SettingsController> _load({Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    ...prefs,
  });
  return SettingsController.load(tokenStore: FakeTokenStore());
}

Future<Object?> _stored() async {
  final text = (await SharedPreferences.getInstance()).getString(_prefKey);
  return text == null ? null : jsonDecode(text);
}

/// A controller seeded with [_seed], for the guard tests.
Future<SettingsController> _seeded() => _load(prefs: {_prefKey: _seedJson()});

/// The seeded entries are still in state and in the preference.
Future<void> _expectSeedIntact(SettingsController c) async {
  expect(c.state.vaultBackups, _seed());
  expect(await _stored(), jsonDecode(_seedJson()));
}

void main() {
  group('AppSettings.vaultBackups', () {
    test('vaultBackups is an unmodifiable copy of the map it is given', () {
      final empty = AppSettings(memexBinaryPath: null);
      expect(empty.vaultBackups, isEmpty);
      expect(
        () => empty.vaultBackups[_vaultA] = _settingsA(),
        throwsUnsupportedError,
      );

      final source = {_vaultA: _settingsA()};
      final s = AppSettings(memexBinaryPath: null, vaultBackups: source);
      expect(s.vaultBackups, {_vaultA: _settingsA()});
      source[_vaultB] = _settingsB();
      expect(s.vaultBackups, {_vaultA: _settingsA()});
      expect(() => s.vaultBackups.remove(_vaultA), throwsUnsupportedError);
    });

    test('copyWith keeps vaultBackups when the field is not given', () {
      final s = AppSettings(
        memexBinaryPath: '/old/memex',
        recentVaults: const ['/a'],
        lastVault: '/a',
        savedServers: const [
          SavedServer(id: 'srv-1', name: 'Nas', url: 'http://nas'),
        ],
        vaultBackups: _seed(),
      );
      expect(s.copyWith().vaultBackups, _seed());
      expect(s.copyWith(memexBinaryPath: '/new/memex').vaultBackups, _seed());
      expect(s.copyWith(recentVaults: const ['/b']).vaultBackups, _seed());
      expect(s.copyWith(lastVault: '/b').vaultBackups, _seed());
      expect(s.copyWith(clearLastVault: true).vaultBackups, _seed());
      expect(
        s.copyWith(recentRefs: [LocalVaultRef('/c')]).vaultBackups,
        _seed(),
      );
      expect(
        s.copyWith(lastVaultRef: HostedVaultRef('srv-1', 'v')).vaultBackups,
        _seed(),
      );
      expect(s.copyWith(savedServers: const []).vaultBackups, _seed());
    });

    test('copyWith replaces vaultBackups when given, even an empty map', () {
      final s = AppSettings(memexBinaryPath: null, vaultBackups: _seed());
      expect(s.copyWith(vaultBackups: {_vaultC: _settingsC()}).vaultBackups, {
        _vaultC: _settingsC(),
      });
      expect(s.copyWith(vaultBackups: const {}).vaultBackups, isEmpty);
    });
  });

  group('memex.vault_backups preference', () {
    test('vaultBackups round-trips through memex.vault_backups', () async {
      final c = await _load();
      expect(c.state.vaultBackups, isEmpty);
      await c.setVaultBackup(_vaultA, _settingsA());
      await c.setVaultBackup(_vaultB, _settingsB());

      // The stored shape: a JSON object, vault path -> toJson.
      expect(await _stored(), {
        _vaultA: _settingsA().toJson(),
        _vaultB: _settingsB().toJson(),
      });

      // A fresh load (same stored prefs) reads the same values back.
      final reloaded = await SettingsController.load(
        tokenStore: FakeTokenStore(),
      );
      expect(reloaded.state.vaultBackups, _seed());
    });

    test('an absent memex.vault_backups key loads as an empty map', () async {
      final c = await _load();
      expect(c.state.vaultBackups, isEmpty);
      expect(c.state.memexBinaryPath, 'fake-memex');
      // The empty map is not sticky: the first save is stored and reloads.
      await c.setVaultBackup(_vaultA, _settingsA());
      final reloaded = await SettingsController.load(
        tokenStore: FakeTokenStore(),
      );
      expect(reloaded.state.vaultBackups, {_vaultA: _settingsA()});
    });

    test(
      'malformed JSON in memex.vault_backups loads as an empty map',
      () async {
        // Control: a well-formed value loads.
        final good = await _load(prefs: {_prefKey: _seedJson()});
        expect(good.state.vaultBackups, _seed());
        for (final bad in ['{not json', '', '[1, 2]', '"text"', 'null', '42']) {
          final c = await _load(prefs: {_prefKey: bad});
          expect(c.state.vaultBackups, isEmpty, reason: 'stored: $bad');
          // The rest of the settings still load.
          expect(c.state.memexBinaryPath, 'fake-memex', reason: 'stored: $bad');
        }
      },
    );

    test(
      'a memex.vault_backups preference of the wrong type loads as an empty map',
      () async {
        // Control: a well-formed value loads.
        final good = await _load(prefs: {_prefKey: _seedJson()});
        expect(good.state.vaultBackups, _seed());
        final c = await _load(prefs: {_prefKey: 7});
        expect(c.state.vaultBackups, isEmpty);
        expect(c.state.memexBinaryPath, 'fake-memex');
      },
    );

    test(
      'settings can be saved after a malformed memex.vault_backups load',
      () async {
        final c = await _load(prefs: {_prefKey: '{not json'});
        await c.setVaultBackup(_vaultA, _settingsA());
        expect(c.state.vaultBackups, {_vaultA: _settingsA()});
        expect(await _stored(), {_vaultA: _settingsA().toJson()});
      },
    );

    test(
      'a malformed entry drops only that vault and the others still load',
      () async {
        final text = jsonEncode({
          _vaultA: _settingsA().toJson(),
          '/not/a/map': 'text',
          '/wrong/enabled': {'enabled': 'yes'},
          '/wrong/destination': {'destination': 5},
          '/wrong/keep': {'keep': '30'},
          '/wrong/automatic': {'automatic': 1},
          _vaultB: _settingsB().toJson(),
        });
        final c = await _load(prefs: {_prefKey: text});
        expect(c.state.vaultBackups, _seed());
      },
    );

    test('an entry with missing keys takes the defaults', () async {
      final c = await _load(
        prefs: {
          _prefKey: jsonEncode({
            _vaultA: {'enabled': true},
            _vaultB: <String, Object?>{},
          }),
        },
      );
      expect(c.state.vaultBackups, {
        _vaultA: VaultBackupSettings(enabled: true),
        _vaultB: VaultBackupSettings(),
      });
    });

    test(
      'a stored keep outside 1 to 365 is clamped into range on read',
      () async {
        final text = jsonEncode({
          '/keep/zero': {'keep': 0},
          '/keep/negative': {'keep': -5},
          '/keep/low': {'keep': 1},
          '/keep/high': {'keep': 365},
          '/keep/over': {'keep': 366},
          '/keep/huge': {'keep': 999},
          '/keep/ok': {'keep': 45},
          _vaultA: _settingsA().toJson(),
        });
        final c = await _load(prefs: {_prefKey: text});
        final keeps = {
          for (final e in c.state.vaultBackups.entries) e.key: e.value.keep,
        };
        expect(keeps, {
          '/keep/zero': 1,
          '/keep/negative': 1,
          '/keep/low': 1,
          '/keep/high': 365,
          '/keep/over': 365,
          '/keep/huge': 365,
          '/keep/ok': 45,
          _vaultA: 45,
        });
        // The other fields of a clamped entry load as stored.
        expect(c.state.vaultBackups[_vaultA], _settingsA());
      },
    );
  });

  group('SettingsController.setVaultBackup', () {
    test('setVaultBackup saves for that vault path only', () async {
      final c = await _seeded();
      await c.setVaultBackup(_vaultA, _settingsC());
      expect(c.state.vaultBackups, {
        _vaultA: _settingsC(),
        _vaultB: _settingsB(),
      });
      expect(await _stored(), {
        _vaultA: _settingsC().toJson(),
        _vaultB: _settingsB().toJson(),
      });
    });

    test('setVaultBackup adds a new vault and keeps the others', () async {
      final c = await _seeded();
      await c.setVaultBackup(_vaultC, _settingsC());
      expect(c.state.vaultBackups, {..._seed(), _vaultC: _settingsC()});
      expect(await _stored(), {
        for (final e in {..._seed(), _vaultC: _settingsC()}.entries)
          e.key: e.value.toJson(),
      });
    });

    test(
      'setVaultBackup changes nothing outside memex.vault_backups',
      () async {
        final c = await _seeded();
        await c.rememberVault('/some/vault');
        final prefs = await SharedPreferences.getInstance();
        final recentsBefore = prefs.getStringList('memex.recent_refs');
        final lastBefore = prefs.getString('memex.last_vault_ref');
        await c.setVaultBackup(_vaultA, _settingsC());
        expect(c.state.vaultBackups[_vaultA], _settingsC());
        expect(c.state.recentVaults, ['/some/vault']);
        expect(c.state.lastVault, '/some/vault');
        expect(c.state.memexBinaryPath, 'fake-memex');
        expect(prefs.getStringList('memex.recent_refs'), recentsBefore);
        expect(prefs.getString('memex.last_vault_ref'), lastBefore);
      },
    );
  });

  group('existing setters keep vaultBackups intact', () {
    test('setMemexBinary keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.setMemexBinary('/opt/memex');
      expect(c.state.memexBinaryPath, '/opt/memex');
      await _expectSeedIntact(c);
      await c.setMemexBinary(null);
      await _expectSeedIntact(c);
    });

    test('rememberVault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberVault('/new/vault');
      expect(c.state.recentVaults, ['/new/vault']);
      await _expectSeedIntact(c);
    });

    test('rememberRef of a hosted vault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberRef(HostedVaultRef('srv-1', 'team'));
      expect(c.state.lastVaultRef, HostedVaultRef('srv-1', 'team'));
      await _expectSeedIntact(c);
    });

    test('forgetVault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberVault('/new/vault');
      await c.forgetVault('/new/vault');
      expect(c.state.recentVaults, isEmpty);
      await _expectSeedIntact(c);
    });

    test('forgetRef of the last vault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberRef(LocalVaultRef('/new/vault'));
      await c.forgetRef(LocalVaultRef('/new/vault'));
      expect(c.state.lastVaultRef, isNull);
      await _expectSeedIntact(c);
    });

    test('forgetRef of another vault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberRef(LocalVaultRef('/keep/me'));
      await c.rememberRef(LocalVaultRef('/new/vault'));
      await c.forgetRef(LocalVaultRef('/keep/me'));
      expect(c.state.lastVaultRef, LocalVaultRef('/new/vault'));
      await _expectSeedIntact(c);
    });

    test('clearLastVault keeps vaultBackups intact', () async {
      final c = await _seeded();
      await c.rememberVault('/new/vault');
      await c.clearLastVault();
      expect(c.state.lastVaultRef, isNull);
      await _expectSeedIntact(c);
    });

    test('saveServer keeps vaultBackups intact', () async {
      final c = await _seeded();
      final server = await c.saveServer(
        name: 'Nas',
        url: 'http://nas.local:8080',
        token: 'tok',
      );
      expect(c.state.savedServers.single, same(server));
      await _expectSeedIntact(c);
      // Saving the same URL again goes through the update path.
      await c.saveServer(
        name: 'Nas 2',
        url: 'http://nas.local:8080',
        token: 't',
      );
      await _expectSeedIntact(c);
    });

    test('updateServer keeps vaultBackups intact', () async {
      final c = await _seeded();
      final server = await c.saveServer(
        name: 'Nas',
        url: 'http://nas.local:8080',
        token: 'tok',
      );
      await c.updateServer(server.id, name: 'Renamed', url: 'http://nas2');
      expect(c.state.savedServers.single.name, 'Renamed');
      await _expectSeedIntact(c);
    });

    test('removeServer keeps vaultBackups intact', () async {
      final c = await _seeded();
      final server = await c.saveServer(
        name: 'Nas',
        url: 'http://nas.local:8080',
        token: 'tok',
      );
      await c.rememberRef(HostedVaultRef(server.id, 'team'));
      await c.removeServer(server.id);
      expect(c.state.savedServers, isEmpty);
      expect(c.state.lastVaultRef, isNull);
      await _expectSeedIntact(c);
    });
  });

  group('vaultBackupSettingsProvider', () {
    test(
      'vaultBackupSettingsProvider returns the defaults for a vault with no entry',
      () async {
        final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
        final s = h.read(vaultBackupSettingsProvider(_vaultC));
        expect(s.enabled, isFalse);
        expect(s.destination, isNull);
        expect(s.keep, 30);
        expect(s.automatic, isTrue);
        expect(s, VaultBackupSettings());
        // A vault with an entry reads it, so the defaults are not a stub.
        expect(h.read(vaultBackupSettingsProvider(_vaultA)), _settingsA());
      },
    );

    test(
      'vaultBackupSettingsProvider returns the stored settings of that vault',
      () async {
        final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
        expect(h.read(vaultBackupSettingsProvider(_vaultA)), _settingsA());
        expect(h.read(vaultBackupSettingsProvider(_vaultB)), _settingsB());
      },
    );

    test(
      'vaultBackupSettingsProvider returns the saved value after a save',
      () async {
        final h = await createBackupContainer();
        final seen = <VaultBackupSettings>[];
        h.container.listen(
          vaultBackupSettingsProvider(_vaultA),
          (_, next) => seen.add(next),
        );
        expect(
          h.read(vaultBackupSettingsProvider(_vaultA)),
          VaultBackupSettings(),
        );

        await h.read(saveVaultBackupSettingsProvider)(_vaultA, _settingsA());

        expect(h.read(vaultBackupSettingsProvider(_vaultA)), _settingsA());
        expect(seen, [_settingsA()]);
        // Another vault still reads the defaults.
        expect(
          h.read(vaultBackupSettingsProvider(_vaultB)),
          VaultBackupSettings(),
        );
        // The save reached the preference and the settings state.
        expect(await _stored(), {_vaultA: _settingsA().toJson()});
        expect(h.read(settingsProvider).vaultBackups, {_vaultA: _settingsA()});
      },
    );

    test(
      'vaultBackupSettingsProvider of a vault is not rebuilt by a save for another vault',
      () async {
        final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
        final seenA = <VaultBackupSettings>[];
        final seenC = <VaultBackupSettings>[];
        h.container.listen(
          vaultBackupSettingsProvider(_vaultA),
          (_, next) => seenA.add(next),
        );
        h.container.listen(
          vaultBackupSettingsProvider(_vaultC),
          (_, next) => seenC.add(next),
        );
        // An unrelated setting changes: no vault is notified.
        await h.read(settingsProvider.notifier).setMemexBinary('other-memex');
        await pumpEventQueue();
        expect(seenA, isEmpty);
        expect(seenC, isEmpty);

        await h.read(saveVaultBackupSettingsProvider)(_vaultC, _settingsC());
        await pumpEventQueue();

        expect(seenC, [_settingsC()]);
        expect(seenA, isEmpty);
      },
    );

    test('saving one vault leaves another vault settings unchanged', () async {
      final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
      await h.read(saveVaultBackupSettingsProvider)(_vaultC, _settingsC());
      expect(h.read(vaultBackupSettingsProvider(_vaultA)), _settingsA());
      expect(h.read(vaultBackupSettingsProvider(_vaultB)), _settingsB());
      expect(h.read(vaultBackupSettingsProvider(_vaultC)), _settingsC());
    });

    test(
      'the save function works from a provider as well as a widget',
      () async {
        final viaProvider = Provider<Future<void>>(
          (ref) =>
              ref.read(saveVaultBackupSettingsProvider)(_vaultA, _settingsA()),
        );
        final h = await createBackupContainer();
        await h.read(viaProvider);
        expect(h.read(vaultBackupSettingsProvider(_vaultA)), _settingsA());
      },
    );
  });

  group('turning off and changing the destination', () {
    const oldDestination = '/Volumes/NAS share/Open Memex Backups';
    const newDestination = '/Volumes/Big Disk/Open Memex Backups';

    test(
      'turning backups off saves settings and runs no CLI call or delete',
      () async {
        final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
        final backupFile = '$oldDestination/Alpha-20261109T090000Z.memex.zip';
        h.probe.addFile(backupFile);
        final callsBefore = List.of(h.probe.calls);

        final on = h.read(vaultBackupSettingsProvider(_vaultA));
        expect(on.enabled, isTrue);
        await h.read(saveVaultBackupSettingsProvider)(
          _vaultA,
          on.copyWith(enabled: false),
        );

        final off = h.read(vaultBackupSettingsProvider(_vaultA));
        expect(off.enabled, isFalse);
        // The destination, keep and automatic stay stored.
        expect(off.destination, oldDestination);
        expect(off.keep, 45);
        expect(off.automatic, isFalse);
        expect(await _stored(), containsPair(_vaultA, off.toJson()));

        expect(h.cli.calls, isEmpty);
        expect(h.runner.calls, isEmpty);
        expect(h.probe.calls, callsBefore);
        expect(await h.probe.listNames(oldDestination), [
          'Alpha-20261109T090000Z.memex.zip',
        ]);
      },
    );

    test(
      'changing the destination saves settings and runs no CLI call or delete',
      () async {
        final h = await createBackupContainer(prefs: {_prefKey: _seedJson()});
        h.probe.addFile('$oldDestination/Alpha-20261109T090000Z.memex.zip');
        h.probe.addDirectory(newDestination);
        final callsBefore = List.of(h.probe.calls);

        final before = h.read(vaultBackupSettingsProvider(_vaultA));
        await h.read(saveVaultBackupSettingsProvider)(
          _vaultA,
          before.copyWith(destination: newDestination),
        );

        final after = h.read(vaultBackupSettingsProvider(_vaultA));
        expect(after.destination, newDestination);
        expect(after.enabled, before.enabled);
        expect(after.keep, before.keep);
        expect(after.automatic, before.automatic);

        expect(h.cli.calls, isEmpty);
        expect(h.runner.calls, isEmpty);
        expect(h.probe.calls, callsBefore);
        // The old destination keeps its backups.
        expect(await h.probe.listNames(oldDestination), [
          'Alpha-20261109T090000Z.memex.zip',
        ]);
      },
    );
  });
}
