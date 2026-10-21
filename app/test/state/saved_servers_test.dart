// WI #91 (D18): saved vault servers. Id, name and URL live in
// SharedPreferences; the access token lives only in the token store, under
// the server id. Server ids are opaque, minted once, and survive edits.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/token_store_fakes.dart';

const _a = '/Users/test/vaults/alpha';
const _b = '/Users/test/vaults/bravo';

/// A [FakeTokenStore] whose writes or deletes can fail, as a locked or
/// denied Keychain would.
class _FailingTokenStore extends FakeTokenStore {
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<void> write(String serverId, String token) async {
    if (failWrites) throw StateError('keychain write denied');
    return super.write(serverId, token);
  }

  @override
  Future<void> delete(String serverId) async {
    if (failDeletes) throw StateError('keychain delete denied');
    return super.delete(serverId);
  }
}

Future<(SettingsController, FakeTokenStore)> _fresh([
  Map<String, Object> seed = const {},
]) async {
  SharedPreferences.setMockInitialValues(seed);
  final store = FakeTokenStore();
  final settings = await SettingsController.load(tokenStore: store);
  return (settings, store);
}

void main() {
  group('saving (AC5)', () {
    test(
      'saving a server stores id name and URL in prefs and the token under its id and survives a reload',
      () async {
        final (settings, store) = await _fresh();

        final saved = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-save-0001',
        );

        expect(saved.id, isNotEmpty);
        expect(saved.name, 'nas');
        expect(saved.url, 'http://nas.local:7878');
        final listed = settings.state.savedServers.single;
        expect(
          (listed.id, listed.name, listed.url),
          (saved.id, 'nas', 'http://nas.local:7878'),
        );
        expect(store.tokens, {saved.id: 'tok-save-0001'});
        expect(
          await prefsEntriesContaining('http://nas.local:7878'),
          isNotEmpty,
          reason: 'the URL is stored in SharedPreferences',
        );

        final again = await relaunchSettings(tokenStore: store);
        final reloaded = again.state.savedServers.single;
        expect(
          (reloaded.id, reloaded.name, reloaded.url),
          (saved.id, 'nas', 'http://nas.local:7878'),
        );
      },
    );

    test('saving two servers mints two distinct ids in save order', () async {
      final (settings, store) = await _fresh();
      final names = [for (var i = 0; i < 3; i++) 'server-$i'];
      final saved = <SavedServer>[];
      for (final (i, name) in names.indexed) {
        saved.add(
          await settings.saveServer(
            name: name,
            url: 'http://host$i.local:7878',
            token: 'tok-distinct-000$i',
          ),
        );
      }

      expect(saved.map((s) => s.id).toSet(), hasLength(3));
      expect(settings.state.savedServers.map((s) => s.name), names);
      for (final (i, s) in saved.indexed) {
        expect(store.tokens[s.id], 'tok-distinct-000$i');
      }

      final again = await relaunchSettings(tokenStore: store);
      expect(again.state.savedServers.map((s) => s.id), saved.map((s) => s.id));
    });

    test(
      'saving a URL that is already saved updates its name and token and keeps its id',
      () async {
        final (settings, store) = await _fresh();
        final first = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-dupe-0001',
        );

        final second = await settings.saveServer(
          name: 'home nas',
          url: 'http://nas.local:7878',
          token: 'tok-dupe-0002',
        );

        expect(second.id, first.id);
        expect(second.name, 'home nas');
        final listed = settings.state.savedServers.single;
        expect(listed.id, first.id);
        expect(listed.name, 'home nas');
        expect(store.tokens, {first.id: 'tok-dupe-0002'});

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.savedServers.single.id, first.id);
        expect(again.state.savedServers.single.name, 'home nas');
      },
    );

    test(
      'saved server URLs match after lowercasing scheme and host stripping a trailing slash and dropping a default port',
      () async {
        // (first URL, second URL, same server?)
        const table = <(String, String, bool)>[
          ('HTTP://NAS.local:80/', 'http://nas.local', true),
          ('http://nas.local', 'HTTP://NAS.local:80/', true),
          ('https://nas.local:443', 'https://NAS.LOCAL/', true),
          ('http://nas.local:7878/', 'http://nas.local:7878', true),
          ('http://Nas.Local:7878', 'http://nas.local:7878/', true),
          ('http://nas.local/memex/', 'http://nas.local/memex', true),
          ('http://nas.local:443', 'http://nas.local', false),
          ('https://nas.local:80', 'https://nas.local', false),
          ('http://nas.local', 'https://nas.local', false),
          ('http://nas.local:7878', 'http://nas.local:7879', false),
          ('http://nas.local', 'http://nas2.local', false),
          ('http://nas.local/memex', 'http://nas.local/Memex', false),
        ];
        for (final (first, second, same) in table) {
          final (settings, store) = await _fresh();
          final s1 = await settings.saveServer(
            name: 'one',
            url: first,
            token: 'tok-url-0001',
          );
          final s2 = await settings.saveServer(
            name: 'two',
            url: second,
            token: 'tok-url-0002',
          );
          final row = '$first vs $second';
          if (same) {
            expect(s2.id, s1.id, reason: row);
            expect(settings.state.savedServers, hasLength(1), reason: row);
            expect(settings.state.savedServers.single.name, 'two', reason: row);
            expect(store.tokens, {s1.id: 'tok-url-0002'}, reason: row);
          } else {
            expect(s2.id, isNot(s1.id), reason: row);
            expect(settings.state.savedServers, hasLength(2), reason: row);
            expect(store.tokens, {
              s1.id: 'tok-url-0001',
              s2.id: 'tok-url-0002',
            }, reason: row);
          }
        }
      },
    );
  });

  group('editing (AC6)', () {
    test(
      'editing a saved server name URL or token keeps its id and its hosted recents',
      () async {
        final (settings, store) = await _fresh();
        final s = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-edit-0001',
        );
        final hosted = HostedVaultRef(s.id, 'notes');
        await settings.rememberRef(const LocalVaultRef(_a));
        await settings.rememberRef(hosted);

        final renamed = await settings.updateServer(s.id, name: 'home nas');
        expect(renamed.id, s.id);
        expect(renamed.name, 'home nas');
        expect(renamed.url, 'http://nas.local:7878');
        expect(store.tokens, {s.id: 'tok-edit-0001'});

        final moved = await settings.updateServer(
          s.id,
          url: 'http://nas.tailnet.ts.net:7878',
        );
        expect(moved.id, s.id);
        expect(moved.name, 'home nas');
        expect(moved.url, 'http://nas.tailnet.ts.net:7878');

        final rekeyed = await settings.updateServer(
          s.id,
          token: 'tok-edit-0002',
        );
        expect(rekeyed.id, s.id);
        expect(store.tokens, {s.id: 'tok-edit-0002'});

        final listed = settings.state.savedServers.single;
        expect(
          (listed.id, listed.name, listed.url),
          (s.id, 'home nas', 'http://nas.tailnet.ts.net:7878'),
        );
        expect(settings.state.recentRefs, [hosted, const LocalVaultRef(_a)]);
        expect(settings.state.lastVaultRef, hosted);

        final again = await relaunchSettings(tokenStore: store);
        final reloaded = again.state.savedServers.single;
        expect(
          (reloaded.id, reloaded.name, reloaded.url),
          (s.id, 'home nas', 'http://nas.tailnet.ts.net:7878'),
        );
        expect(again.state.recentRefs, [hosted, const LocalVaultRef(_a)]);
        expect(again.state.lastVaultRef, hosted);
      },
    );

    test(
      'editing name URL and token in one call keeps the id and saves the new token',
      () async {
        final (settings, store) = await _fresh();
        final s = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-edit-1001',
        );

        final edited = await settings.updateServer(
          s.id,
          name: 'mini',
          url: 'https://mini.example.net',
          token: 'tok-edit-1002',
        );

        expect(
          (edited.id, edited.name, edited.url),
          (s.id, 'mini', 'https://mini.example.net'),
        );
        expect(store.tokens, {s.id: 'tok-edit-1002'});
        expect(settings.state.savedServers, hasLength(1));
      },
    );
  });

  group('removing (AC7)', () {
    test(
      'removing a saved server deletes its token and its hosted recents and clears the last vault if it was one',
      () async {
        final (settings, store) = await _fresh();
        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-remove-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: 'tok-remove-0002',
        );
        await settings.rememberRef(const LocalVaultRef(_a));
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes'));
        await settings.rememberRef(HostedVaultRef(s2.id, 'notes'));
        await settings.rememberRef(const LocalVaultRef(_b));
        await settings.rememberRef(HostedVaultRef(s1.id, 'journal'));

        await settings.removeServer(s1.id);

        expect(store.tokens, {s2.id: 'tok-remove-0002'});
        expect(settings.state.savedServers.map((s) => s.id), [s2.id]);
        final expected = [
          const LocalVaultRef(_b),
          HostedVaultRef(s2.id, 'notes'),
          const LocalVaultRef(_a),
        ];
        expect(settings.state.recentRefs, expected);
        expect(settings.state.lastVaultRef, isNull);
        expect(settings.state.recentVaults, [_b, _a]);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.savedServers.map((s) => s.id), [s2.id]);
        expect(again.state.recentRefs, expected);
        expect(again.state.lastVaultRef, isNull);
      },
    );

    test(
      'removing a saved server keeps a last vault that belongs elsewhere',
      () async {
        final (settings, store) = await _fresh();
        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-keep-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: 'tok-keep-0002',
        );
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes'));
        await settings.rememberRef(HostedVaultRef(s2.id, 'notes'));

        await settings.removeServer(s1.id);
        expect(settings.state.lastVaultRef, HostedVaultRef(s2.id, 'notes'));
        expect(settings.state.recentRefs, [HostedVaultRef(s2.id, 'notes')]);

        await settings.rememberRef(const LocalVaultRef(_a));
        await settings.removeServer(s2.id);
        expect(settings.state.lastVaultRef, const LocalVaultRef(_a));
        expect(settings.state.lastVault, _a);
        expect(settings.state.recentRefs, const [LocalVaultRef(_a)]);
        expect(settings.state.savedServers, isEmpty);
        expect(store.tokens, isEmpty);

        final again = await relaunchSettings(tokenStore: store);
        expect(again.state.lastVaultRef, const LocalVaultRef(_a));
        expect(again.state.savedServers, isEmpty);
      },
    );
  });

  group('no token outside the Keychain (AC8)', () {
    test(
      'no access token is stored in prefs after saving editing and removing servers',
      () async {
        final (settings, store) = await _fresh({
          'memex.recent_vaults': <String>[_a],
          'memex.last_vault': _a,
        });
        const tokens = [
          'tok-scan-alpha-7f3a9c',
          'tok-scan-bravo-2b8e41',
          'tok-scan-charlie-90d6aa',
          'tok-scan-delta-5c1f07',
        ];

        Future<void> expectNoToken(String step) async {
          for (final t in tokens) {
            expect(
              await prefsEntriesContaining(t),
              isEmpty,
              reason: '$step: token $t found in SharedPreferences',
            );
          }
        }

        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: tokens[0],
        );
        await expectNoToken('save s1');
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: tokens[1],
        );
        await settings.rememberRef(HostedVaultRef(s1.id, 'notes'));
        await settings.rememberRef(HostedVaultRef(s2.id, 'notes'));
        await expectNoToken('save s2 and remember');
        await settings.updateServer(s1.id, name: 'nas2', token: tokens[2]);
        await expectNoToken('edit s1');
        // Re-saving s2 by URL updates its token.
        await settings.saveServer(
          name: 'mini',
          url: 'HTTP://MINI.local:7878/',
          token: tokens[3],
        );
        await expectNoToken('re-save s2');
        await settings.removeServer(s1.id);
        await expectNoToken('remove s1');

        // The tokens went to the token store instead.
        expect(store.tokens, {s2.id: tokens[3]});

        await relaunchSettings(tokenStore: store);
        await expectNoToken('relaunch');
      },
    );

    test('the saved server and recents models carry no token field', () {
      // A String-typed field whose name mentions a token.
      final tokenField = RegExp(r'final\s+String\??\s+\w*[Tt]oken\w*\s*[;=]');
      for (final path in [
        'lib/src/state/settings.dart',
        'lib/src/state/vault_ref.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          tokenField.allMatches(source).map((m) => m.group(0)),
          isEmpty,
          reason: '$path declares a token field',
        );
      }

      // A run-time SavedServer is fully described by id, name and URL.
      final id = 'srv-${DateTime(2026, 10, 20).millisecondsSinceEpoch}';
      final s = SavedServer(id: id, name: 'nas', url: 'http://nas.local');
      expect((s.id, s.name, s.url), (id, 'nas', 'http://nas.local'));
    });
  });

  group('saved server contracts (handoff, lead pinned)', () {
    test(
      're-saving a saved URL keeps the first URL string and updates only name and token',
      () async {
        final (settings, store) = await _fresh();
        final first = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-first-url-0001',
        );

        final again = await settings.saveServer(
          name: 'home nas',
          url: 'HTTP://NAS.local:7878/',
          token: 'tok-first-url-0002',
        );

        expect(
          (again.id, again.name, again.url),
          (first.id, 'home nas', 'http://nas.local:7878'),
        );
        final listed = settings.state.savedServers.single;
        expect(listed.url, 'http://nas.local:7878');
        expect(store.tokens, {first.id: 'tok-first-url-0002'});

        final relaunched = await relaunchSettings(tokenStore: store);
        expect(
          relaunched.state.savedServers.single.url,
          'http://nas.local:7878',
        );
      },
    );

    test(
      'updateServer with an unknown id throws StateError and changes nothing',
      () async {
        final (settings, store) = await _fresh();
        final s = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-unknown-0001',
        );
        store.calls.clear();
        final before = await prefsEntries();

        await expectLater(
          settings.updateServer(
            'srv-missing',
            name: 'ghost',
            url: 'http://ghost.local',
            token: 'tok-unknown-0002',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('srv-missing'),
            ),
          ),
        );

        expect(store.calls, isEmpty);
        expect(store.tokens, {s.id: 'tok-unknown-0001'});
        expect(await prefsEntries(), before);
        final listed = settings.state.savedServers.single;
        expect(
          (listed.id, listed.name, listed.url),
          (s.id, 'nas', 'http://nas.local:7878'),
        );
      },
    );

    test(
      'the token is written before prefs so a failed token write saves no server',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _FailingTokenStore()..failWrites = true;
        final settings = await SettingsController.load(tokenStore: store);

        await expectLater(
          settings.saveServer(
            name: 'nas',
            url: 'http://nas.local:7878',
            token: 'tok-order-0001',
          ),
          throwsStateError,
        );

        expect(settings.state.savedServers, isEmpty);
        expect(await prefsEntriesContaining('nas.local'), isEmpty);
        final relaunched = await relaunchSettings(tokenStore: store);
        expect(relaunched.state.savedServers, isEmpty);
      },
    );

    test(
      'a failed token write on update or re-save leaves the saved server unchanged',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _FailingTokenStore();
        final settings = await SettingsController.load(tokenStore: store);
        final s = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-order-1001',
        );
        store.failWrites = true;

        await expectLater(
          settings.updateServer(
            s.id,
            name: 'renamed',
            url: 'http://moved.local:7878',
            token: 'tok-order-1002',
          ),
          throwsStateError,
        );
        await expectLater(
          settings.saveServer(
            name: 'renamed',
            url: 'HTTP://nas.local:7878/',
            token: 'tok-order-1003',
          ),
          throwsStateError,
        );

        final listed = settings.state.savedServers.single;
        expect(
          (listed.id, listed.name, listed.url),
          (s.id, 'nas', 'http://nas.local:7878'),
        );
        expect(store.tokens, {s.id: 'tok-order-1001'});
        expect(await prefsEntriesContaining('renamed'), isEmpty);
        expect(await prefsEntriesContaining('moved.local'), isEmpty);
        final relaunched = await relaunchSettings(tokenStore: store);
        expect(relaunched.state.savedServers.single.name, 'nas');
      },
    );

    test(
      'the token is deleted before prefs so a failed token delete keeps the server and its recents',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _FailingTokenStore();
        final settings = await SettingsController.load(tokenStore: store);
        final s = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-order-2001',
        );
        final hosted = HostedVaultRef(s.id, 'notes');
        await settings.rememberRef(hosted);
        store.failDeletes = true;

        await expectLater(settings.removeServer(s.id), throwsStateError);

        expect(settings.state.savedServers.map((x) => x.id), [s.id]);
        expect(settings.state.recentRefs, [hosted]);
        expect(settings.state.lastVaultRef, hosted);
        expect(store.tokens, {s.id: 'tok-order-2001'});
        final relaunched = await relaunchSettings(tokenStore: store);
        expect(relaunched.state.savedServers.map((x) => x.id), [s.id]);
        expect(relaunched.state.recentRefs, [hosted]);
        expect(relaunched.state.lastVaultRef, hosted);
      },
    );

    test('undecodable saved server entries are skipped on load', () async {
      const good = '{"id":"srv-good","name":"mini","url":"http://mini.local"}';
      final (settings, _) = await _fresh({
        'memex.recent_refs': <String>[],
        'memex.vault_servers': <String>[
          'not json',
          '{"id":"srv-a","name":"nas"',
          '{"id":"srv-b","name":"nas"}',
          '{"id":"srv-c","name":"nas","url":7}',
          '["srv-d","nas","http://d.local"]',
          '"srv-e"',
          good,
          '{"id":5,"name":"nas","url":"http://f.local"}',
        ],
      });

      final listed = settings.state.savedServers.single;
      expect(
        (listed.id, listed.name, listed.url),
        ('srv-good', 'mini', 'http://mini.local'),
      );
    });

    test(
      'editing a URL to match another saved server is allowed and keeps both servers',
      () async {
        // Open risk for #98: updateServer does not dedupe by URL.
        final (settings, store) = await _fresh();
        final s1 = await settings.saveServer(
          name: 'nas',
          url: 'http://nas.local:7878',
          token: 'tok-clash-0001',
        );
        final s2 = await settings.saveServer(
          name: 'mini',
          url: 'http://mini.local:7878',
          token: 'tok-clash-0002',
        );

        final edited = await settings.updateServer(
          s2.id,
          url: 'HTTP://NAS.local:7878/',
        );

        expect(edited.id, s2.id);
        expect(
          [for (final s in settings.state.savedServers) (s.id, s.url)],
          [(s1.id, 'http://nas.local:7878'), (s2.id, 'HTTP://NAS.local:7878/')],
        );
        expect(store.tokens, {
          s1.id: 'tok-clash-0001',
          s2.id: 'tok-clash-0002',
        });
        final relaunched = await relaunchSettings(tokenStore: store);
        expect(relaunched.state.savedServers.map((s) => s.id), [s1.id, s2.id]);
      },
    );

    test(
      'normalizeServerUrl keeps path case and query trims whitespace and leaves a URL without a host alone',
      () {
        // (input, normalised form)
        const table = <(String, String)>[
          ('HTTP://NAS.local:80/', 'http://nas.local'),
          ('https://NAS.local:443/', 'https://nas.local'),
          ('https://nas.local:8443/', 'https://nas.local:8443'),
          ('http://nas.local:443', 'http://nas.local:443'),
          ('  http://nas.local/  ', 'http://nas.local'),
          ('http://nas.local/Memex/', 'http://nas.local/Memex'),
          ('http://nas.local/memex?v=A', 'http://nas.local/memex?v=A'),
          ('FTP://Files.local:80/', 'ftp://files.local:80'),
          ('NAS.local/', 'NAS.local'),
          ('nas.local', 'nas.local'),
          ('', ''),
        ];
        for (final (input, expected) in table) {
          expect(normalizeServerUrl(input), expected, reason: '"$input"');
        }
      },
    );
  });
}
