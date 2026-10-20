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

  group('recents contracts (handoff, lead pinned)', () {
    test(
      'forgetVault of a local path removes the old last vault key when it holds that path even while the last vault is hosted',
      () async {
        final (settings, store) = await _load({});
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-oldlast-0001',
        );
        final hosted = HostedVaultRef(server.id, 'notes');
        final prefs = await _prefs();
        await settings.rememberVault(_a);
        await settings.rememberVault(_b);
        await settings.rememberRef(hosted);
        expect(prefs.getString(_kOldLast), _b);

        // A local path the old key does not hold leaves it alone.
        await settings.forgetVault(_a);
        expect(prefs.getString(_kOldLast), _b);

        await settings.forgetVault(_b);
        expect(prefs.getString(_kOldLast), isNull);
        // The typed last vault is hosted and stays.
        expect(settings.state.lastVaultRef, hosted);
        expect(settings.state.recentRefs, [hosted]);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.lastVaultRef, hosted);
      },
    );

    test(
      'forgetRef of a local path removes the old last vault key when it holds that path',
      () async {
        final (settings, _) = await _load({
          _kOldRecents: <String>[_a, _b],
          _kOldLast: _a,
        });
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-oldlast-1001',
        );
        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        final prefs = await _prefs();
        expect(prefs.getString(_kOldLast), _a);

        await settings.forgetRef(const LocalVaultRef(_a));

        expect(prefs.getString(_kOldLast), isNull);
        expect(prefs.getStringList(_kOldRecents), [_b]);
        expect(settings.state.lastVaultRef, HostedVaultRef(server.id, 'notes'));
      },
    );

    test(
      'clearLastVault removes the old last vault key also while the last vault is hosted',
      () async {
        final (settings, store) = await _load({
          _kOldRecents: <String>[_a],
          _kOldLast: _a,
        });
        final server = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-clear-0001',
        );
        await settings.rememberRef(HostedVaultRef(server.id, 'notes'));
        final prefs = await _prefs();
        expect(prefs.getString(_kOldLast), _a);

        await settings.clearLastVault();

        expect(prefs.getString(_kOldLast), isNull);
        expect(settings.state.lastVaultRef, isNull);
        expect(settings.state.recentRefs, [
          HostedVaultRef(server.id, 'notes'),
          const LocalVaultRef(_a),
        ]);
        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.lastVaultRef, isNull);
      },
    );

    test(
      'clearing a hosted last vault leaves the old last vault key unchanged',
      () async {
        final (settings, store) = await _load({});
        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-hostedlast-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: 'tok-hostedlast-0002',
        );
        final prefs = await _prefs();
        await settings.rememberVault(_a);

        // forgetRef of the hosted last vault.
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes'));
        await settings.forgetRef(HostedVaultRef(s1.id, 'notes'));
        expect(settings.state.lastVaultRef, isNull);
        expect(prefs.getString(_kOldLast), _a);

        // removeServer of the server holding the hosted last vault.
        await settings.rememberRef(HostedVaultRef(s2.id, 'notes'));
        await settings.removeServer(s2.id);
        expect(settings.state.lastVaultRef, isNull);
        expect(prefs.getString(_kOldLast), _a);

        // The typed keys win on the next load: no last vault.
        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.lastVaultRef, isNull);
        expect(again.state.recentRefs, const [LocalVaultRef(_a)]);
      },
    );

    test(
      'undecodable typed recents and last vault entries are skipped on load',
      () async {
        // (stored last vault text, why it is undecodable)
        const badLasts = <(String, String)>[
          ('{oops', 'bad JSON'),
          ('{"kind":"hosted","server":"srv-x"}', 'no vault name'),
          ('{"kind":"local","path":7}', 'path not a string'),
          ('{"kind":"cloud","path":"/x"}', 'unknown kind'),
          ('["local","/x"]', 'not an object'),
        ];
        for (final (lastText, why) in badLasts) {
          final (settings, _) = await _load({
            'memex.recent_refs': <String>[
              'nope',
              '{"kind":"local"}',
              '{"kind":"local","path":5}',
              '{"kind":"hosted","server":"srv-x"}',
              '{"kind":"hosted","server":"srv-x","vault":"notes"}',
              '{"kind":"cloud","path":"/x"}',
              '[]',
              '{"kind":"local","path":"$_a"}',
              '{"kind":"hosted","server":3,"vault":"notes"}',
            ],
            'memex.last_vault_ref': lastText,
            _kOldRecents: <String>[_c],
            _kOldLast: _c,
          });

          expect(settings.state.recentRefs, const [
            HostedVaultRef('srv-x', 'notes'),
            LocalVaultRef(_a),
          ], reason: why);
          expect(settings.state.lastVaultRef, isNull, reason: why);
        }
      },
    );

    test(
      'the migration keeps at most 8 old recents in order and leaves the old key whole',
      () async {
        final paths = [for (var i = 0; i < 10; i++) '/Users/test/vaults/m$i'];
        final (settings, store) = await _load({
          _kOldRecents: paths,
          _kOldLast: paths.first,
        });

        final expected = [for (final p in paths.take(8)) LocalVaultRef(p)];
        expect(settings.state.recentRefs, expected);
        expect(settings.state.recentVaults, paths.take(8).toList());
        expect(settings.state.lastVaultRef, LocalVaultRef(paths.first));
        expect((await _prefs()).getStringList(_kOldRecents), paths);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.recentRefs, expected);
      },
    );

    test(
      'hosted recents for a server id that is not saved are kept on load',
      () async {
        final (settings, _) = await _load({
          'memex.recent_refs': <String>[
            '{"kind":"hosted","server":"srv-gone","vault":"notes"}',
            '{"kind":"local","path":"$_a"}',
          ],
          'memex.last_vault_ref':
              '{"kind":"hosted","server":"srv-gone","vault":"notes"}',
        });

        expect(settings.state.savedServers, isEmpty);
        expect(settings.state.recentRefs, const [
          HostedVaultRef('srv-gone', 'notes'),
          LocalVaultRef(_a),
        ]);
        expect(
          settings.state.lastVaultRef,
          const HostedVaultRef('srv-gone', 'notes'),
        );
        expect(settings.state.lastVault, isNull);
        expect(settings.state.recentVaults, [_a]);
      },
    );

    test(
      'AppSettings seeds typed local refs from the local path form and copyWith keeps or replaces them',
      () {
        final paths = [
          for (var i = 0; i < 3; i++) '/Users/test/vaults/s${i * 7}',
        ];
        final local = AppSettings(
          memexBinaryPath: '/opt/test/memex',
          recentVaults: paths,
          lastVault: paths[1],
        );
        expect(local.recentRefs, [for (final p in paths) LocalVaultRef(p)]);
        expect(local.lastVaultRef, LocalVaultRef(paths[1]));
        expect(local.recentVaults, paths);
        expect(local.lastVault, paths[1]);
        expect(local.savedServers, isEmpty);
        expect(
          () => local.recentRefs.add(const LocalVaultRef(_a)),
          throwsUnsupportedError,
        );
        expect(() => local.recentVaults.add(_a), throwsUnsupportedError);

        final empty = AppSettings(memexBinaryPath: null);
        expect(empty.recentRefs, isEmpty);
        expect(empty.lastVaultRef, isNull);

        // The typed form wins over the local path form.
        final server = SavedServer(
          id: 'srv-${paths.length}',
          name: 'nas',
          url: 'http://nas.local',
        );
        final hosted = HostedVaultRef(server.id, 'notes');
        final typed = AppSettings(
          memexBinaryPath: null,
          recentVaults: paths,
          lastVault: paths[0],
          recentRefs: [hosted, LocalVaultRef(paths[2])],
          lastVaultRef: hosted,
          savedServers: [server],
        );
        expect(typed.recentRefs, [hosted, LocalVaultRef(paths[2])]);
        expect(typed.lastVaultRef, hosted);
        expect(typed.recentVaults, [paths[2]]);
        expect(typed.lastVault, isNull);
        expect(typed.savedServers, [server]);

        final kept = typed.copyWith();
        expect(kept.recentRefs, typed.recentRefs);
        expect(kept.lastVaultRef, hosted);
        expect(kept.savedServers, [server]);

        final replaced = typed.copyWith(
          memexBinaryPath: '/opt/test/memex2',
          recentVaults: [paths[0]],
          lastVault: paths[0],
        );
        expect(replaced.memexBinaryPath, '/opt/test/memex2');
        expect(replaced.recentRefs, [LocalVaultRef(paths[0])]);
        expect(replaced.lastVaultRef, LocalVaultRef(paths[0]));
        expect(replaced.savedServers, [server]);

        final cleared = typed.copyWith(
          lastVault: paths[0],
          clearLastVault: true,
        );
        expect(cleared.lastVaultRef, isNull);
        expect(
          typed.copyWith(recentRefs: const [], recentVaults: paths).recentRefs,
          isEmpty,
        );
        expect(
          typed
              .copyWith(lastVaultRef: LocalVaultRef(paths[2]), lastVault: _a)
              .lastVaultRef,
          LocalVaultRef(paths[2]),
        );
      },
    );
  });
}
