// WI #432 (Spec #392 req 13, 13b, 15, 18; D4, D5b, D24): the learned-words
// state behind E1's seam (`learnedWordKeysProvider`,
// `learnedWordsActionsProvider`).
//
// - Keys: `VaultAccess.words.list()` on vault open and on every
//   `vaultRevisionProvider` change, each word lowercased (Dart
//   `toLowerCase()`).
// - learn: the vault write first; on success `SpellingService.learn` (also
//   for `changed:false`), the key added at once (D5b), true. Any failure:
//   false, no native call, no key.
// - unlearn: the vault write first; on success `SpellingService.unlearn`, the
//   key removed, true. A failure: false, no native call, the key kept.
// - Exactly one `vaultRevisionProvider` bump per attempted write; none when
//   `canWrite` is false (no write ran).
//
// Seams: FakeMemexCli (`memex words add|rm`, never a real binary),
// FakeVaultDb (V7 `learned_words`), FakeWordsAccess (held reads and writes),
// FakeVaultServer (hosted), FakeSpellingService (records native calls).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/learned_words_state.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/words_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_spelling_service.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';
import '../support/fake_words_access.dart';

const _vaultA = LocalVaultRef('/tmp/om-432-state-a');
const _vaultB = LocalVaultRef('/tmp/om-432-state-b');
const _hosted = HostedVaultRef(fakeServerId, 'seed');
const _base = '/vaults/seed/api/v1';
const _vaultId = '01M5DK9Z8CWPQGFA893JX9VRZF';

String _out(String word, {required bool changed}) =>
    '{"vault_id":"$_vaultId","word":"$word","changed":$changed}\n';

class _Wi432Env {
  _Wi432Env(this.container, this.spelling);

  final ProviderContainer container;
  final FakeSpellingService spelling;
  int bumps = 0;

  Set<String> get keys => container.read(learnedWordKeysProvider);

  LearnedWordsActions get actions =>
      container.read(learnedWordsActionsProvider);

  int get revision => container.read(vaultRevisionProvider);

  /// Keeps the key set alive, counts bumps and lets the first read land.
  Future<void> start() async {
    container.listen(learnedWordKeysProvider, (_, _) {}, fireImmediately: true);
    container.listen<int>(vaultRevisionProvider, (_, _) => bumps++);
    await pumpEventQueue();
  }
}

/// A local vault per [VaultRef] in [words]; [db] and [cli] for every vault.
_Wi432Env _local({
  Map<VaultRef, FakeWordsAccess> words = const {},
  FakeVaultDb? db,
  MemexCli? cli,
  VaultRef? open = _vaultA,
}) {
  final spelling = FakeSpellingService();
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => open),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      spellingServiceProvider.overrideWithValue(spelling),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final path = vault.localPath;
        if (path == null) return null;
        return LocalVaultAccess(
          vaultPath: path,
          db: db,
          cli: cli,
          words: words[vault],
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  return _Wi432Env(container, spelling);
}

/// A hosted vault `seed` on [server].
_Wi432Env _hostedEnv(FakeVaultServer server, {FakeClock? clock}) {
  final spelling = FakeSpellingService();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock ?? FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
      currentVaultProvider.overrideWith((_) => _hosted),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      spellingServiceProvider.overrideWithValue(spelling),
      vaultAccessProvider.overrideWith(
        (ref) => HostedVaultAccess(
          client: HostedClient(
            ref,
            serverId: fakeServerId,
            serverName: fakeServerName,
            serverUrl: fakeServerUrl,
            accessToken: fakeServerToken,
            httpClient: server.client,
          ),
          vaultName: 'seed',
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return _Wi432Env(container, spelling);
}

FakeVaultDb _v7({List<String> words = const []}) {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  for (final w in words) {
    _insert(db, w);
  }
  return db;
}

void _insert(FakeVaultDb db, String word) => db.db.execute(
  'INSERT INTO learned_words (word_key, word, created_at) VALUES (?, ?, 1) '
  'ON CONFLICT(word_key) DO NOTHING',
  [word.toLowerCase(), word],
);

/// A CLI whose `words add` / `words rm` write [db] as the real CLI does.
FakeMemexCli _cliOn(FakeVaultDb db, {bool addChanged = true}) => FakeMemexCli()
  ..on('words add', (c) {
    final word = c.flag('word')!;
    _insert(db, word);
    return FakeMemexCli.ok(_out(word, changed: addChanged));
  })
  ..on('words rm', (c) {
    final word = c.flag('word')!;
    db.db.execute('DELETE FROM learned_words WHERE word_key = ?', [
      word.toLowerCase(),
    ]);
    return FakeMemexCli.ok(_out(word, changed: true));
  });

FakeWordsAccess _real(VaultRef vault, FakeVaultDb db, MemexCli? cli) =>
    FakeWordsAccess(vaultPath: vault.localPath!, db: db, cli: cli);

FakeWordsAccess _scripted(List<String> words, {VaultRef vault = _vaultA}) =>
    FakeWordsAccess(vaultPath: vault.localPath!)..script(words);

List<String> _spelled(FakeSpellingService s, String method) => [
  for (final c in s.callsFor(method)) c.args['word']! as String,
];

void main() {
  group('learn', () {
    test(
      'a successful learn makes one words add, one SpellingService learn and one bump, and adds the key before any re-read completes',
      () async {
        final db = _v7();
        final cli = _cliOn(db);
        final words = _real(_vaultA, db, cli);
        final env = _local(words: {_vaultA: words}, db: db, cli: cli);
        await env.start();
        expect(env.keys, isEmpty);
        final readsBefore = words.listCalls;
        words.holdLists = true;

        final ok = await env.actions.learn('memex');

        expect(ok, isTrue);
        expect(cli.callsFor('words add'), hasLength(1));
        expect(cli.callsFor('words add').single.flag('word'), 'memex');
        expect(_spelled(env.spelling, 'learn'), ['memex']);
        expect(env.bumps, 1);
        expect(env.revision, 1);
        expect(env.keys, {'memex'}, reason: 'no re-read has completed yet');

        words.releaseLists();
        await pumpEventQueue();
        expect(words.listCalls, greaterThan(readsBefore));
        expect(env.keys, {'memex'}, reason: 'the re-read confirms it');
        expect(cli.callsFor('words add'), hasLength(1));
        expect(env.spelling.count('learn'), 1);
      },
    );

    test(
      'learn writes to the vault before calling SpellingService learn',
      () async {
        final words = _scripted([]);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        words.holdLearns = true;

        final pending = env.actions.learn('memex');
        await pumpEventQueue();

        expect(words.learnCalls, ['memex']);
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, isEmpty);

        words.releaseLearns();
        expect(await pending, isTrue);
        expect(_spelled(env.spelling, 'learn'), ['memex']);
        expect(env.keys, contains('memex'));
      },
    );

    test(
      'a repeat learn with changed false makes one words add, one SpellingService learn and one bump and leaves the key set unchanged',
      () async {
        final db = _v7(words: ['memex']);
        final cli = _cliOn(db, addChanged: false);
        final env = _local(
          words: {_vaultA: _real(_vaultA, db, cli)},
          db: db,
          cli: cli,
        );
        await env.start();
        expect(env.keys, {'memex'});

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(ok, isTrue);
        expect(cli.callsFor('words add'), hasLength(1));
        expect(_spelled(env.spelling, 'learn'), ['memex']);
        expect(env.bumps, 1);
        expect(env.keys, {'memex'});
      },
    );

    test(
      'a learn with changed false of a word learned on another Mac still teaches this Mac and adds the key at once',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'words add',
            (_) => FakeMemexCli.ok(_out('serendipity', changed: false)),
          );
        // Not scripted: learn goes through the CLI stub (changed:false) and
        // the app's last read (no db: empty) does not hold the word.
        final words = FakeWordsAccess(vaultPath: _vaultA.path, cli: cli);
        final env = _local(words: {_vaultA: words}, cli: cli);
        await env.start();
        expect(env.keys, isEmpty);
        words.holdLists = true;

        final ok = await env.actions.learn('serendipity');

        expect(ok, isTrue);
        expect(cli.callsFor('words add'), hasLength(1));
        expect(_spelled(env.spelling, 'learn'), ['serendipity']);
        expect(env.keys, {'serendipity'});
      },
    );

    test('learning Émile adds émile to the key set at once', () async {
      final words = _scripted([]);
      final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
      await env.start();
      words.holdLists = true;

      expect(await env.actions.learn('Émile'), isTrue);

      expect(env.keys, {'émile'});
      expect(_spelled(env.spelling, 'learn'), ['Émile']);
    });

    test(
      'learn with no CLI returns false, makes no SpellingService learn call, adds no key and bumps nothing',
      () async {
        final words = _scripted(['teh']);
        final env = _local(words: {_vaultA: words}, cli: null);
        await env.start();
        final access = env.container.read(vaultAccessProvider)!;
        expect(access.canWrite, isFalse);
        expect(env.keys, {'teh'}, reason: 'reads still work without a CLI');

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(ok, isFalse);
        expect(words.learnCalls, isEmpty, reason: 'no write runs');
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, {'teh'});
        expect(env.bumps, 0);
        expect(env.revision, 0);
      },
    );

    test(
      'learn with a CLI failure returns false, makes no SpellingService learn call and adds no key',
      () async {
        final db = _v7();
        final cli = FakeMemexCli()
          ..on('words add', (_) => FakeMemexCli.error('internal', 'disk full'));
        final env = _local(
          words: {_vaultA: _real(_vaultA, db, cli)},
          db: db,
          cli: cli,
        );
        await env.start();

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(cli.callsFor('words add'), hasLength(1));
        expect(ok, isFalse);
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, isEmpty);
      },
    );

    test(
      'learn with a memex without words (clap exit 2) returns false, makes no SpellingService learn call and adds no key',
      () async {
        final db = _v7();
        final cli = FakeMemexCli()
          ..on(
            'words add',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'words'\n",
              exitCode: 2,
            ),
          );
        final env = _local(
          words: {_vaultA: _real(_vaultA, db, cli)},
          db: db,
          cli: cli,
        );
        await env.start();

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(cli.callsFor('words add'), hasLength(1));
        expect(ok, isFalse);
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, isEmpty);
      },
    );

    test(
      'learn during a hosted outage returns false, makes no SpellingService learn call and adds no key',
      () async {
        final server = FakeVaultServer()
          ..route('GET', '$_base/words', json: {'vault_id': 'v', 'words': []});
        final env = _hostedEnv(server);
        await env.start();
        server.failure = FakeServerFailure.refused;

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(
          server.requests.where((r) => r.method == 'POST'),
          hasLength(1),
          reason: 'the write was attempted',
        );
        expect(ok, isFalse);
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, isEmpty);
      },
    );

    test(
      'learn on an older hosted server returns false, makes no SpellingService learn call and adds no key',
      () async {
        final server = FakeVaultServer()..serveDomain('compat');
        final env = _hostedEnv(server);
        await env.start();

        final ok = await env.actions.learn('memex');
        await pumpEventQueue();

        expect(
          server.requests.where((r) => r.method == 'POST'),
          hasLength(1),
          reason: 'the write was attempted',
        );
        expect(ok, isFalse);
        expect(env.spelling.count('learn'), 0);
        expect(env.keys, isEmpty);
      },
    );

    test(
      'a successful hosted learn posts once, teaches this Mac once and adds the key',
      () async {
        final server = FakeVaultServer()..serveDomain('words');
        final env = _hostedEnv(server);
        await env.start();

        expect(await env.actions.learn('memex'), isTrue);

        expect(server.requests.where((r) => r.method == 'POST'), hasLength(1));
        expect(_spelled(env.spelling, 'learn'), ['memex']);
        expect(env.keys, contains('memex'));
        expect(env.bumps, 1);
      },
    );

    test(
      'a failed learn write still bumps vaultRevisionProvider exactly once',
      () async {
        final words = _scripted([])
          ..learnError = MemexException('words add failed: disk full');
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();

        expect(await env.actions.learn('memex'), isFalse);
        await pumpEventQueue();

        expect(words.learnCalls, ['memex']);
        expect(env.bumps, 1);
        expect(env.revision, 1);
      },
    );

    test(
      'closing the vault empties the key set and learn then returns false and calls nothing',
      () async {
        final words = _scripted(['teh']);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        expect(env.keys, {'teh'});

        env.container.read(currentVaultProvider.notifier).state = null;
        await pumpEventQueue();

        expect(env.keys, isEmpty);
        expect(await env.actions.learn('memex'), isFalse);
        expect(words.learnCalls, isEmpty);
        expect(env.spelling.count('learn'), 0);
        expect(env.bumps, 0);
      },
    );
  });

  group('keys', () {
    test(
      'the key set is read on vault open and again after a vaultRevisionProvider bump',
      () async {
        final words = _scripted(['memex']);
        final env = _local(words: {_vaultA: words});
        await env.start();

        expect(env.keys, {'memex'});
        final reads = words.listCalls;
        expect(reads, greaterThanOrEqualTo(1));

        words.script(['memex', 'teh']);
        env.container.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();

        expect(words.listCalls, greaterThan(reads));
        expect(env.keys, {'memex', 'teh'});
      },
    );

    test('learned Émile puts émile in the key set', () async {
      final env = _local(
        words: {
          _vaultA: _scripted(['Émile', 'MEMEX']),
        },
      );
      await env.start();

      expect(env.keys, {'émile', 'memex'});
    });

    test(
      'the key set reads the learned_words rows of a local V7 vault',
      () async {
        final db = _v7(words: ['Serendipity', 'teh']);
        final env = _local(db: db);
        await env.start();

        expect(env.keys, {'serendipity', 'teh'});
      },
    );

    test(
      'opening another vault reads its words and never shows the old vault keys',
      () async {
        final a = _scripted(['alpha']);
        final b = _scripted(['beta'], vault: _vaultB)..holdLists = true;
        final env = _local(words: {_vaultA: a, _vaultB: b});
        await env.start();
        expect(env.keys, {'alpha'});

        env.container.read(currentVaultProvider.notifier).state = _vaultB;
        await pumpEventQueue();

        expect(b.listCalls, greaterThanOrEqualTo(1));
        expect(env.keys, isNot(contains('alpha')));

        b.releaseLists();
        await pumpEventQueue();
        expect(env.keys, {'beta'});
      },
    );

    test('a hosted key set reads GET words and lowercases each word', () async {
      final server = FakeVaultServer()
        ..route(
          'GET',
          '$_base/words',
          json: {
            'vault_id': _vaultId,
            'words': [
              {'word': 'memex', 'created_at': 1},
              {'word': 'Émile', 'created_at': 2},
            ],
          },
        );
      final env = _hostedEnv(server);
      await env.start();

      expect(env.keys, {'memex', 'émile'});
      expect(server.requests.where((r) => r.method == 'GET'), isNotEmpty);
    });
  });

  group('unlearn', () {
    test(
      'a successful unlearn makes one words rm, one SpellingService unlearn and one bump, and removes the key',
      () async {
        final db = _v7(words: ['memex', 'teh']);
        final cli = _cliOn(db);
        final words = _real(_vaultA, db, cli);
        final env = _local(words: {_vaultA: words}, db: db, cli: cli);
        await env.start();
        expect(env.keys, {'memex', 'teh'});
        words.holdLists = true;

        final ok = await env.actions.unlearn('memex');

        expect(ok, isTrue);
        expect(cli.callsFor('words rm'), hasLength(1));
        expect(cli.callsFor('words rm').single.flag('word'), 'memex');
        expect(_spelled(env.spelling, 'unlearn'), ['memex']);
        expect(env.bumps, 1);
        expect(env.keys, {'teh'}, reason: 'removed without waiting for a read');

        words.releaseLists();
        await pumpEventQueue();
        expect(env.keys, {'teh'});
      },
    );

    test(
      'unlearn writes to the vault before calling SpellingService unlearn',
      () async {
        final words = _scripted(['memex']);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        words.holdUnlearns = true;

        final pending = env.actions.unlearn('memex');
        await pumpEventQueue();

        expect(words.unlearnCalls, ['memex']);
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'memex'});

        words.releaseUnlearns();
        expect(await pending, isTrue);
        expect(_spelled(env.spelling, 'unlearn'), ['memex']);
      },
    );

    test('unlearning MEMEX removes the memex key', () async {
      final words = _scripted(['memex', 'teh']);
      final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
      await env.start();
      words.holdLists = true;

      expect(await env.actions.unlearn('MEMEX'), isTrue);

      expect(env.keys, {'teh'});
    });

    test(
      'a failed unlearn returns false, makes no SpellingService unlearn call and keeps the key',
      () async {
        final db = _v7(words: ['memex']);
        final cli = FakeMemexCli()
          ..on('words rm', (_) => FakeMemexCli.error('internal', 'disk full'));
        final env = _local(
          words: {_vaultA: _real(_vaultA, db, cli)},
          db: db,
          cli: cli,
        );
        await env.start();
        expect(env.keys, {'memex'});

        final ok = await env.actions.unlearn('memex');
        await pumpEventQueue();

        expect(cli.callsFor('words rm'), hasLength(1));
        expect(ok, isFalse);
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'memex'});
      },
    );

    test(
      'unlearn with no CLI returns false, makes no SpellingService unlearn call, keeps the key and bumps nothing',
      () async {
        final words = _scripted(['memex']);
        final env = _local(words: {_vaultA: words}, cli: null);
        await env.start();

        expect(await env.actions.unlearn('memex'), isFalse);
        await pumpEventQueue();

        expect(words.unlearnCalls, isEmpty);
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'memex'});
        expect(env.bumps, 0);
      },
    );

    test(
      'a failed unlearn write still bumps vaultRevisionProvider exactly once',
      () async {
        final words = _scripted(['memex'])
          ..unlearnError = MemexException('words rm failed: disk full');
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();

        expect(await env.actions.unlearn('memex'), isFalse);
        await pumpEventQueue();

        expect(words.unlearnCalls, ['memex']);
        expect(env.bumps, 1);
        expect(env.revision, 1);
      },
    );
  });

  group('contracts (verify)', () {
    LearnedWordsState state(_Wi432Env env) => env.actions as LearnedWordsState;

    test(
      'lastError and lastErrorMessage name why the last write failed and clear on a success',
      () async {
        final words = _scripted([])
          ..learnError = MemexException('words add failed: disk full');
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        expect(state(env).lastError, isNull);
        expect(state(env).lastErrorMessage, isNull);

        expect(await env.actions.learn('memex'), isFalse);
        expect(state(env).lastError, isA<MemexException>());
        expect(state(env).lastErrorMessage, 'words add failed: disk full');

        words.learnError = null;
        expect(await env.actions.learn('memex'), isTrue);
        expect(state(env).lastError, isNull);
        expect(state(env).lastErrorMessage, isNull);

        words.unlearnError = Exception('boom');
        expect(await env.actions.unlearn('memex'), isFalse);
        expect(state(env).lastErrorMessage, 'Exception: boom');
      },
    );

    test(
      'lastErrorMessage for a VaultUnreachableException is the L17 copy, not its debug string',
      () async {
        final words = _scripted(['teh']);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();

        words.unlearnError = const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        );
        expect(await env.actions.unlearn('teh'), isFalse);
        expect(state(env).lastError, isA<VaultUnreachableException>());
        expect(state(env).lastErrorMessage, "couldn't reach nas. try again.");

        words.unlearnError = const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: true,
        );
        expect(await env.actions.unlearn('teh'), isFalse);
        expect(
          state(env).lastErrorMessage,
          "couldn't confirm with nas — check before trying again",
        );
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'teh'});
      },
    );

    test(
      'a hosted unlearn with the server refusing reads couldn\'t reach nas and keeps the key',
      () async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '$_base/words',
            json: {
              'vault_id': 'v',
              'words': [
                {'word': 'teh', 'created_at': 1},
              ],
            },
          );
        final env = _hostedEnv(server);
        await env.start();
        expect(env.keys, {'teh'});
        server.failure = FakeServerFailure.refused;

        expect(await env.actions.unlearn('teh'), isFalse);
        await pumpEventQueue();

        expect(
          (env.actions as LearnedWordsState).lastErrorMessage,
          "couldn't reach nas. try again.",
        );
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'teh'});
      },
    );

    test(
      'a hosted unlearn that times out after the send reads couldn\'t confirm with nas',
      () async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '$_base/words',
            json: {
              'vault_id': 'v',
              'words': [
                {'word': 'teh', 'created_at': 1},
              ],
            },
          );
        final clock = FakeClock();
        final env = _hostedEnv(server, clock: clock);
        await env.start();
        server.failure = FakeServerFailure.timeout;

        final pending = env.actions.unlearn('teh');
        await pumpEventQueue();
        clock.advance(const Duration(seconds: 10));
        expect(await pending, isFalse);

        expect(
          (env.actions as LearnedWordsState).lastErrorMessage,
          "couldn't confirm with nas — check before trying again",
        );
        expect(env.spelling.count('unlearn'), 0);
        expect(env.keys, {'teh'});
      },
    );

    test(
      'with no CLI the last error is a StateError saying the memex CLI is not available',
      () async {
        final env = _local(words: {_vaultA: _scripted([])}, cli: null);
        await env.start();

        expect(await env.actions.learn('memex'), isFalse);

        expect(state(env).lastError, isA<StateError>());
        expect(state(env).lastErrorMessage, 'The memex CLI is not available.');
      },
    );

    test(
      'with no vault open the last error is a StateError saying no vault is open',
      () async {
        final env = _local(open: null, cli: FakeMemexCli());
        await env.start();

        expect(await env.actions.unlearn('memex'), isFalse);

        expect(state(env).lastError, isA<StateError>());
        expect(state(env).lastErrorMessage, 'No vault is open.');
        expect(env.bumps, 0);
        expect(env.spelling.count('unlearn'), 0);
      },
    );

    test(
      'a vault switch while a learn is writing records no key into the new vault',
      () async {
        final a = _scripted([])..holdLearns = true;
        final b = _scripted(['beta'], vault: _vaultB);
        final env = _local(
          words: {_vaultA: a, _vaultB: b},
          cli: FakeMemexCli(),
        );
        await env.start();

        final pending = env.actions.learn('memex');
        await pumpEventQueue();
        expect(a.learnCalls, ['memex']);

        env.container.read(currentVaultProvider.notifier).state = _vaultB;
        await pumpEventQueue();
        expect(env.keys, {'beta'});
        b.holdLists = true; // B's re-read after A's write bump stays pending.
        a.releaseLearns();
        expect(await pending, isTrue);
        await pumpEventQueue();

        expect(env.keys, {'beta'}, reason: "vault A's word never shows in B");
        b.releaseLists();
        await pumpEventQueue();
        expect(env.keys, {'beta'});
      },
    );

    test(
      'a read that started before a learn and lands after it does not drop the key',
      () async {
        final words = _StaleListWords(vaultPath: _vaultA.path)..script([]);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        expect(env.keys, isEmpty);

        // A second read is pending on a snapshot taken before the write.
        words.holdLists = true;
        env.container.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();
        final readsHeld = words.listCalls;

        expect(await env.actions.learn('memex'), isTrue);
        expect(env.keys, {'memex'});
        words.releaseLists();
        await pumpEventQueue();

        expect(words.listCalls, greaterThanOrEqualTo(readsHeld));
        expect(env.keys, {'memex'});
      },
    );

    test(
      'learnedWordsProvider lists the words as written sorted by word_key and a learned word shows after the re-read',
      () async {
        final words = _scripted(['Zeta', 'Émile', 'apple', 'Memex']);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        env.container.listen(learnedWordsProvider, (_, _) {});
        List<String> listed() => [
          for (final w in env.container.read(learnedWordsProvider)) w.word,
        ];

        expect(listed(), ['apple', 'Memex', 'Zeta', 'Émile']);

        words.holdLists = true;
        expect(await env.actions.learn('Banana'), isTrue);
        expect(listed(), [
          'apple',
          'Memex',
          'Zeta',
          'Émile',
        ], reason: 'a learn is not overlaid on the list before the re-read');
        expect(env.keys, contains('banana'));

        words.releaseLists();
        await pumpEventQueue();
        expect(listed(), ['apple', 'Banana', 'Memex', 'Zeta', 'Émile']);
      },
    );

    test(
      'learnedWordsProvider drops an unlearned word at once, before the re-read',
      () async {
        final words = _scripted(['memex', 'teh']);
        final env = _local(words: {_vaultA: words}, cli: FakeMemexCli());
        await env.start();
        env.container.listen(learnedWordsProvider, (_, _) {});
        List<String> listed() => [
          for (final w in env.container.read(learnedWordsProvider)) w.word,
        ];
        words.holdLists = true;

        expect(await env.actions.unlearn('TEH'), isTrue);

        expect(listed(), ['memex']);
        expect(env.keys, {'memex'});
        words.releaseLists();
        await pumpEventQueue();
        expect(listed(), ['memex']);
      },
    );

    test('learnedWordKey lowercases with Unicode rules', () {
      expect(learnedWordKey('Émile'), 'émile');
      expect(learnedWordKey('MEMEX'), 'memex');
      expect(learnedWordKey('teh'), 'teh');
    });

    test('learnedWordsProvider is empty with no vault open', () async {
      final env = _local(open: null);
      await env.start();

      expect(env.container.read(learnedWordsProvider), isEmpty);
      expect(env.keys, isEmpty);
    });
  });
}

/// A FakeWordsAccess whose `list` snapshots the words before it waits, so a
/// held read lands with what the vault held when it started.
class _StaleListWords extends FakeWordsAccess {
  _StaleListWords({required super.vaultPath});

  @override
  Future<List<LearnedWord>> list() async {
    final snapshot = List<LearnedWord>.of(words ?? const []);
    await super.list();
    return List.unmodifiable(snapshot);
  }
}
