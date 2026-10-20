// WI #91 (D18, Req 57): typed recents. Today's `memex.recent_vaults` /
// `memex.last_vault` are read once into new keys, never deleted, and local
// entries are mirrored back to them on every write, so older builds keep
// their local recents. The local-path API keeps today's results.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/token_store_fakes.dart';

const _kOldRecents = 'memex.recent_vaults';
const _kOldLast = 'memex.last_vault';

const _a = '/Users/test/vaults/alpha';
const _b = '/Users/test/vaults/bravo';
const _c = '/Users/test/vaults/charlie';

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

/// Settings loaded from [seed] (today's key format) with a fake token store.
Future<(SettingsController, FakeTokenStore)> _load(
  Map<String, Object> seed,
) async {
  SharedPreferences.setMockInitialValues(seed);
  final store = FakeTokenStore();
  final settings = await SettingsController.load(tokenStore: store);
  return (settings, store);
}

void main() {
  group('migration (AC1, AC2)', () {
    test(
      'load migrates the old recents and last vault into typed local recents and keeps the old keys',
      () async {
        final (settings, _) = await _load({
          _kOldRecents: <String>[_a, _b],
          _kOldLast: _b,
        });

        expect(settings.state.recentRefs, const [
          LocalVaultRef(_a),
          LocalVaultRef(_b),
        ]);
        expect(settings.state.lastVaultRef, const LocalVaultRef(_b));

        final prefs = await _prefs();
        expect(prefs.getStringList(_kOldRecents), [_a, _b]);
        expect(prefs.getString(_kOldLast), _b);
      },
    );

    test('the migrated typed recents survive a relaunch', () async {
      final (_, store) = await _load({
        _kOldRecents: <String>[_a, _b],
        _kOldLast: _b,
      });

      final again = await relaunchSettings(tokenStore: store);

      expect(again.state.recentRefs, const [
        LocalVaultRef(_a),
        LocalVaultRef(_b),
      ]);
      expect(again.state.lastVaultRef, const LocalVaultRef(_b));
    });

    test(
      'the migration runs once so an older build editing the old keys later changes nothing',
      () async {
        final (_, store) = await _load({
          _kOldRecents: <String>[_a, _b],
          _kOldLast: _b,
        });

        // An older build runs and rewrites the old keys.
        final prefs = await _prefs();
        await prefs.setStringList(_kOldRecents, <String>[_c]);
        await prefs.setString(_kOldLast, _c);

        final again = await relaunchSettings(tokenStore: store);

        expect(again.state.recentRefs, const [
          LocalVaultRef(_a),
          LocalVaultRef(_b),
        ]);
        expect(again.state.lastVaultRef, const LocalVaultRef(_b));
      },
    );

    test(
      'the migration runs once even after a typed write and an older build edit',
      () async {
        final (settings, store) = await _load({
          _kOldRecents: <String>[_a, _b],
          _kOldLast: _b,
        });
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-migration-0001',
        );
        final hosted = HostedVaultRef(server.id, 'notes');
        await settings.rememberRef(hosted);

        final prefs = await _prefs();
        await prefs.setStringList(_kOldRecents, <String>[_c]);

        final again = await relaunchSettings(tokenStore: store);

        expect(again.state.recentRefs, [
          hosted,
          const LocalVaultRef(_a),
          const LocalVaultRef(_b),
        ]);
        expect(again.state.lastVaultRef, hosted);
      },
    );

    test(
      'a fresh install loads empty typed recents and no last vault',
      () async {
        final (settings, _) = await _load({});

        expect(settings.state.recentRefs, isEmpty);
        expect(settings.state.lastVaultRef, isNull);
        expect(settings.state.recentVaults, isEmpty);
        expect(settings.state.lastVault, isNull);
      },
    );

    test(
      'an old last vault alone migrates to a typed local last vault',
      () async {
        final (settings, _) = await _load({_kOldLast: _b});

        expect(settings.state.lastVaultRef, const LocalVaultRef(_b));
        expect(settings.state.lastVault, _b);
      },
    );
  });

  group('recents (AC3)', () {
    test(
      'recents keep at most 8 entries across local and hosted most recent first',
      () async {
        final (settings, store) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-cap-0001',
        );
        // Ten entries, alternating local and hosted, built at run time.
        final refs = <VaultRef>[
          for (var i = 0; i < 10; i++)
            i.isEven
                ? LocalVaultRef('/Users/test/vaults/v$i')
                : HostedVaultRef(server.id, 'vault-$i'),
        ];
        for (final r in refs) {
          await settings.rememberRef(r);
        }

        final expected = refs.reversed.take(8).toList();
        expect(settings.state.recentRefs, expected);
        expect(settings.state.lastVaultRef, refs.last);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.recentRefs, expected);
      },
    );

    test(
      'remembering an existing entry moves it to the front without a duplicate',
      () async {
        final (settings, _) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-front-0001',
        );
        await settings.rememberRef(const LocalVaultRef(_a));
        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        await settings.rememberRef(const LocalVaultRef(_b));

        await settings.rememberRef(const LocalVaultRef(_a));
        expect(settings.state.recentRefs, [
          const LocalVaultRef(_a),
          const LocalVaultRef(_b),
          HostedVaultRef(server.id, 'notes'),
        ]);

        // A new, equal hosted ref moves the existing entry.
        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        expect(settings.state.recentRefs, [
          HostedVaultRef(server.id, 'notes'),
          const LocalVaultRef(_a),
          const LocalVaultRef(_b),
        ]);
        expect(settings.state.lastVaultRef, HostedVaultRef(server.id, 'notes'));
      },
    );

    test(
      'a hosted recent is keyed by server id and vault name so one name on two servers gives two entries',
      () async {
        final (settings, store) = await _load({});
        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-key-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: 'tok-key-0002',
        );
        expect(s1.id, isNot(s2.id));

        // A copied vault shares its original's vault_id; recents never merge
        // entries by it, only by (server id, vault name).
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes'));
        await settings.rememberRef(HostedVaultRef(s2.id, 'notes'));
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes-copy'));

        final expected = [
          HostedVaultRef(s1.id, 'notes-copy'),
          HostedVaultRef(s2.id, 'notes'),
          HostedVaultRef(s1.id, 'notes'),
        ];
        expect(settings.state.recentRefs, expected);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.recentRefs, expected);
      },
    );

    test(
      'forgetRef drops one typed entry and clears the last vault if it was that entry',
      () async {
        final (settings, store) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-forget-0001',
        );
        final hosted = HostedVaultRef(server.id, 'notes');
        await settings.rememberRef(const LocalVaultRef(_a));
        await settings.rememberRef(hosted);

        await settings.forgetRef(hosted);

        expect(settings.state.recentRefs, const [LocalVaultRef(_a)]);
        expect(settings.state.lastVaultRef, isNull);
        // The server itself and its token stay.
        expect(settings.state.savedServers.map((s) => s.id), [server.id]);
        expect(store.tokens[server.id], 'tok-forget-0001');

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.recentRefs, const [LocalVaultRef(_a)]);
        expect(again.state.lastVaultRef, isNull);
      },
    );
  });

  group('mirroring (AC4)', () {
    test(
      'every recents write mirrors the local paths in order to the old recents key',
      () async {
        final (settings, _) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-mirror-0001',
        );
        final prefs = await _prefs();

        await settings.rememberRef(const LocalVaultRef(_a));
        expect(prefs.getStringList(_kOldRecents), [_a]);

        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        expect(prefs.getStringList(_kOldRecents), [_a]);

        await settings.rememberRef(const LocalVaultRef(_b));
        await settings.rememberRef(HostedVaultRef(server.id, 'journal'));
        expect(prefs.getStringList(_kOldRecents), [_b, _a]);

        await settings.rememberRef(const LocalVaultRef(_a));
        expect(prefs.getStringList(_kOldRecents), [_a, _b]);

        await settings.forgetRef(const LocalVaultRef(_a));
        expect(prefs.getStringList(_kOldRecents), [_b]);

        await settings.forgetRef(HostedVaultRef(server.id, 'notes'));
        expect(prefs.getStringList(_kOldRecents), [_b]);
      },
    );

    test(
      'the old last vault key holds the local path and is left unchanged when the last vault becomes hosted',
      () async {
        final (settings, _) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-last-0001',
        );
        final prefs = await _prefs();

        await settings.rememberRef(const LocalVaultRef(_a));
        expect(prefs.getString(_kOldLast), _a);
        expect(settings.state.lastVault, _a);

        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        expect(prefs.getString(_kOldLast), _a);
        expect(settings.state.lastVaultRef, HostedVaultRef(server.id, 'notes'));
        // The local-path API sees no local last vault while it is hosted.
        expect(settings.state.lastVault, isNull);

        await settings.rememberRef(const LocalVaultRef(_b));
        expect(prefs.getString(_kOldLast), _b);
        expect(settings.state.lastVault, _b);
      },
    );

    test(
      'no hosted entry server id or URL ever appears in the old keys',
      () async {
        final (settings, _) = await _load({
          _kOldRecents: <String>[_a],
          _kOldLast: _a,
        });
        final prefs = await _prefs();
        final s1 = await settings.saveServer(
          name: 'nas-xq',
          url: 'http://nas-xq.local:7878',
          token: 'tok-oldkeys-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini-zq',
          url: 'https://mini-zq.example.net',
          token: 'tok-oldkeys-0002',
        );

        Future<void> expectOldKeysClean(String step) async {
          final old = [
            ...?prefs.getStringList(_kOldRecents),
            ?prefs.getString(_kOldLast),
          ].join('\n');
          for (final needle in [
            s1.id,
            s2.id,
            'nas-xq',
            'mini-zq',
            'hosted-vault-zeta',
            'hosted-vault-eta',
            'http',
          ]) {
            expect(old, isNot(contains(needle)), reason: '$step: $needle');
          }
        }

        await settings.rememberRef(HostedVaultRef(s1.id, 'hosted-vault-zeta'));
        await expectOldKeysClean('remember hosted s1');
        await settings.rememberRef(const LocalVaultRef(_b));
        await settings.rememberRef(HostedVaultRef(s2.id, 'hosted-vault-eta'));
        await expectOldKeysClean('remember hosted s2');
        await settings.updateServer(s2.id, url: 'https://mini-zq.example.org');
        await expectOldKeysClean('edit s2');
        await settings.forgetRef(const LocalVaultRef(_b));
        await expectOldKeysClean('forget local');
        await settings.removeServer(s1.id);
        await expectOldKeysClean('remove s1');
        expect(prefs.getStringList(_kOldRecents), [_a]);
      },
    );
  });

  group('local-path API (AC12)', () {
    test(
      'rememberVault and forgetVault give todays local path results and typed local recents',
      () async {
        final (settings, _) = await _load({});
        final prefs = await _prefs();

        await settings.rememberVault(_a);
        await settings.rememberVault(_b);
        await settings.rememberVault(_a);
        expect(settings.state.recentVaults, [_a, _b]);
        expect(settings.state.lastVault, _a);
        expect(settings.state.recentRefs, const [
          LocalVaultRef(_a),
          LocalVaultRef(_b),
        ]);
        expect(settings.state.lastVaultRef, const LocalVaultRef(_a));
        expect(prefs.getStringList(_kOldRecents), [_a, _b]);
        expect(prefs.getString(_kOldLast), _a);

        // Forgetting a vault that isn't recent changes nothing.
        await settings.forgetVault(_c);
        expect(settings.state.recentVaults, [_a, _b]);
        expect(settings.state.lastVault, _a);

        // Forgetting the last vault clears it, as today.
        await settings.forgetVault(_a);
        expect(settings.state.recentVaults, [_b]);
        expect(settings.state.lastVault, isNull);
        expect(settings.state.recentRefs, const [LocalVaultRef(_b)]);
        expect(settings.state.lastVaultRef, isNull);
        expect(prefs.getStringList(_kOldRecents), [_b]);
        expect(prefs.getString(_kOldLast), isNull);
      },
    );

    test(
      'rememberVault keeps at most 8 local recents most recent first',
      () async {
        final (settings, _) = await _load({});
        final paths = [for (var i = 0; i < 9; i++) '/Users/test/vaults/p$i'];
        for (final p in paths) {
          await settings.rememberVault(p);
        }

        final expected = paths.reversed.take(8).toList();
        expect(settings.state.recentVaults, expected);
        expect(settings.state.recentRefs, [
          for (final p in expected) LocalVaultRef(p),
        ]);
        expect((await _prefs()).getStringList(_kOldRecents), expected);
      },
    );

    test(
      'recentVaults lists only the local paths of mixed typed recents in order',
      () async {
        final (settings, _) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-local-0001',
        );
        await settings.rememberVault(_a);
        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        await settings.rememberVault(_b);

        expect(settings.state.recentVaults, [_b, _a]);
        expect(settings.state.lastVault, _b);
      },
    );

    test(
      'clearLastVault clears the last vault keeps the recents and survives a relaunch',
      () async {
        final (settings, store) = await _load({
          _kOldRecents: <String>[_a, _b],
          _kOldLast: _a,
        });

        await settings.clearLastVault();

        expect(settings.state.lastVault, isNull);
        expect(settings.state.lastVaultRef, isNull);
        expect(settings.state.recentVaults, [_a, _b]);
        expect((await _prefs()).getString(_kOldLast), isNull);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.lastVaultRef, isNull);
        expect(again.state.lastVault, isNull);
        expect(again.state.recentRefs, const [
          LocalVaultRef(_a),
          LocalVaultRef(_b),
        ]);
      },
    );

    test('setMemexBinary still stores and clears the binary path', () async {
      final (settings, store) = await _load({});

      await settings.setMemexBinary('/opt/test/memex');
      expect(settings.state.memexBinaryPath, '/opt/test/memex');
      expect(
        (await _prefs()).getString('memex.binary_path'),
        '/opt/test/memex',
      );
      final again = await relaunchSettings(tokenStore: store);
      expect(again.state.memexBinaryPath, '/opt/test/memex');
      expect(again.state.recentRefs, isEmpty);

      await again.setMemexBinary(null);
      expect((await _prefs()).getString('memex.binary_path'), isNull);
    });
  });
}
