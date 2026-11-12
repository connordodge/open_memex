// WI #432 (Spec #392 req 14, 15b, 16; D21, D22): LocalWordsAccess and the
// `words` getter on both VaultAccess composites. Reads come from the vault's
// `learned_words` table (V7; a vault without it reads as no learned words),
// writes go through `memex words add|rm --vault <path> --word <w>`
// (FakeMemexCli; never a real `memex`).
//
//   memex words add|rm stdout: {vault_id, word, changed}
//   errors: one C1 line on stderr, e.g. code word_invalid
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/words_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/words.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';
import '../support/fake_words_access.dart';

const _vault = '/tmp/om-432-vault';
const _vaultId = '01M5DK9Z8CWPQGFA893JX9VRZF';

String _out(String word, {required bool changed}) =>
    '{"vault_id":"$_vaultId","word":"$word","changed":$changed}\n';

void _seedWord(FakeVaultDb db, String word, int createdAt) => db.db.execute(
  'INSERT INTO learned_words (word_key, word, created_at) VALUES (?, ?, ?)',
  [word.toLowerCase(), word, createdAt],
);

FakeVaultDb _v7() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  return db;
}

List<(String, int)> _rows(List<LearnedWord> words) => [
  for (final w in words) (w.word, w.createdAt),
];

void main() {
  group('LocalWordsAccess list', () {
    test(
      'LocalWordsAccess list returns the learned_words rows of a V7 vault',
      () async {
        final db = _v7();
        _seedWord(db, 'memex', 1000);
        _seedWord(db, 'Émile', 2000);
        final words = LocalWordsAccess(vaultPath: _vault, db: db);

        expect(_rows(await words.list()), [('memex', 1000), ('Émile', 2000)]);
      },
    );

    test('LocalWordsAccess list is sorted by word_key', () async {
      final db = _v7();
      _seedWord(db, 'Zeta', 3000);
      _seedWord(db, 'Émile', 2000);
      _seedWord(db, 'apple', 1000);
      _seedWord(db, 'Memex', 4000);
      final words = LocalWordsAccess(vaultPath: _vault, db: db);

      // word_key order: apple < memex < zeta < émile (é sorts after z).
      expect(
        [for (final w in await words.list()) w.word],
        ['apple', 'Memex', 'Zeta', 'Émile'],
      );
    });

    test(
      'LocalWordsAccess list is empty on a V6 vault without learned_words',
      () async {
        final db = FakeVaultDb.v6Only();
        addTearDown(db.close);
        expect(db.hasTables(const ['learned_words']), isFalse);
        final words = LocalWordsAccess(vaultPath: _vault, db: db);

        expect(await words.list(), isEmpty);
        expect(db.learnedWords(), isEmpty);
        expect(await LocalWordsAccess(vaultPath: _vault).list(), isEmpty);

        // The CLI migrates the vault while the app holds this handle: the
        // missing table is probed again on the next read, never cached.
        db.db.execute(
          'CREATE TABLE learned_words (word_key TEXT PRIMARY KEY, '
          'word TEXT NOT NULL, created_at INTEGER NOT NULL)',
        );
        _seedWord(db, 'teh', 7);
        expect(_rows(await words.list()), [('teh', 7)]);
      },
    );

    test('WordsReads learnedWords reads the rows of a V7 vault', () {
      final db = _v7();
      _seedWord(db, 'teh', 42);

      expect(_rows(db.learnedWords()), [('teh', 42)]);
    });
  });

  group('LocalWordsAccess writes', () {
    test(
      'learn runs memex words add with the vault and word once and returns its result',
      () async {
        final cli = FakeMemexCli()
          ..on('words add', (_) => FakeMemexCli.ok(_out('teh', changed: true)));
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        final result = await words.learn('teh');

        expect(cli.calls.map((c) => c.args), [
          ['words', 'add', '--vault', _vault, '--word', 'teh'],
        ]);
        expect(result.word, 'teh');
        expect(result.changed, isTrue);
      },
    );

    test('learn of a word already there returns changed false', () async {
      final cli = FakeMemexCli()
        ..on('words add', (_) => FakeMemexCli.ok(_out('teh', changed: false)));
      final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

      final result = await words.learn('teh');

      expect(cli.callsFor('words add'), hasLength(1));
      expect(result.word, 'teh');
      expect(result.changed, isFalse);
    });

    test(
      'unlearn runs memex words rm with the vault and word once and returns its result',
      () async {
        final cli = FakeMemexCli()
          ..on('words rm', (_) => FakeMemexCli.ok(_out('teh', changed: true)));
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        final result = await words.unlearn('teh');

        expect(cli.calls.map((c) => c.args), [
          ['words', 'rm', '--vault', _vault, '--word', 'teh'],
        ]);
        expect(result.word, 'teh');
        expect(result.changed, isTrue);
      },
    );

    test('unlearn of a word that is not there returns changed false', () async {
      final cli = FakeMemexCli()
        ..on('words rm', (_) => FakeMemexCli.ok(_out('teh', changed: false)));
      final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

      final result = await words.unlearn('teh');

      expect(cli.callsFor('words rm'), hasLength(1));
      expect(result.changed, isFalse);
    });

    test(
      'a word_invalid CLI failure surfaces as MemexException with code word_invalid',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'words add',
            (_) => FakeMemexCli.error(
              'word_invalid',
              'word invalid: a learned word must be 1 to 64 characters with no whitespace, got "a b"',
            ),
          );
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          words.learn('a b'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'word_invalid')
                .having(
                  (e) => e.message,
                  'message',
                  contains('a learned word must be 1 to 64 characters'),
                ),
          ),
        );
        expect(cli.callsFor('words add'), hasLength(1));
      },
    );

    test(
      'an unlearn CLI failure surfaces as MemexException with its code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'words rm',
            (_) => FakeMemexCli.error('vault_locked', 'vault is locked'),
          );
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          words.unlearn('teh'),
          throwsA(
            isA<MemexException>().having((e) => e.code, 'code', 'vault_locked'),
          ),
        );
      },
    );

    test(
      'a memex without words (clap exit 2) makes learn throw MemexException',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'words add',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'words'\n\n"
              'Usage: memex <COMMAND>\n',
              exitCode: 2,
            ),
          );
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        await expectLater(words.learn('teh'), throwsA(isA<MemexException>()));
      },
    );

    test(
      'learn stdout without word and changed throws a null-code MemexException',
      () async {
        final cli = FakeMemexCli()
          ..on('words add', (_) => FakeMemexCli.ok('{"vault_id":"x"}\n'));
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          words.learn('teh'),
          throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull)),
        );
      },
    );

    test(
      'unlearn stdout that is not JSON throws a null-code MemexException',
      () async {
        final cli = FakeMemexCli()
          ..on('words rm', (_) => FakeMemexCli.ok('removed teh\n'));
        final words = LocalWordsAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          words.unlearn('teh'),
          throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull)),
        );
      },
    );

    test(
      'with canWrite false learn throws StateError and runs no CLI call',
      () async {
        final access = LocalVaultAccess(vaultPath: _vault, db: _v7());
        expect(access.canWrite, isFalse);

        await expectLater(access.words.learn('teh'), throwsStateError);
        await expectLater(access.words.unlearn('teh'), throwsStateError);
      },
    );
  });

  group('contracts (verify)', () {
    test(
      'LocalWordsAccess without a cli throws StateError on learn and unlearn',
      () async {
        final words = LocalWordsAccess(vaultPath: _vault, db: _v7());

        await expectLater(words.learn('teh'), throwsStateError);
        await expectLater(words.unlearn('teh'), throwsStateError);
      },
    );

    test(
      'parseWordWriteResult reads a string word and a bool changed and nothing else',
      () {
        final ok = parseWordWriteResult({
          'vault_id': 'v',
          'word': 'Émile',
          'changed': false,
        });
        expect(ok, isNotNull);
        expect(ok!.word, 'Émile');
        expect(ok.changed, isFalse);
        expect(
          parseWordWriteResult({'word': 'x', 'changed': true})!.changed,
          isTrue,
        );

        for (final bad in <Object?>[
          null,
          'memex',
          <Object?>[],
          <String, Object?>{},
          {'word': 'x'},
          {'changed': true},
          {'word': 1, 'changed': true},
          {'word': 'x', 'changed': 'true'},
          {'word': 'x', 'changed': 1},
        ]) {
          expect(parseWordWriteResult(bad), isNull, reason: '$bad');
        }
      },
    );

    test('LearnedWord and WordWriteResult keep run-time values', () {
      final word = 'te${'h'}';
      final at = DateTime.utc(2026, 11, 11).millisecondsSinceEpoch;
      final learned = LearnedWord(word: word, createdAt: at);
      final result = WordWriteResult(word: word, changed: at.isEven);

      expect((learned.word, learned.createdAt), ('teh', at));
      expect((result.word, result.changed), ('teh', at.isEven));
    });
  });

  group('VaultAccess words', () {
    test(
      'LocalVaultAccess words defaults to a LocalWordsAccess on its db and cli',
      () async {
        final db = _v7();
        _seedWord(db, 'memex', 1000);
        final cli = FakeMemexCli()
          ..on('words add', (_) => FakeMemexCli.ok(_out('teh', changed: true)));
        final access = LocalVaultAccess(vaultPath: _vault, db: db, cli: cli);

        final VaultAccess asInterface = access;
        expect(asInterface.words, isA<LocalWordsAccess>());
        expect(access.words.vaultPath, _vault);
        expect(access.words.db, same(db));
        expect(access.words.cli, same(cli));
        expect(_rows(await asInterface.words.list()), [('memex', 1000)]);
        await asInterface.words.learn('teh');
        expect(cli.callsFor('words add'), hasLength(1));
        expect(cli.callsFor('words add').single.flag('vault'), _vault);

        // A replacement double (D21) takes the domain's place.
        final fake = FakeWordsAccess(vaultPath: _vault)..script(['zeta']);
        final replaced = LocalVaultAccess(vaultPath: _vault, words: fake);
        final VaultAccess replacedInterface = replaced;
        expect(replacedInterface.words, same(fake));
        expect(replaced.tags, isA<LocalTagsAccess>());
        expect(
          [for (final w in await replacedInterface.words.list()) w.word],
          ['zeta'],
        );
      },
    );

    test(
      'HostedVaultAccess words is a HostedWordsAccess that sends GET words for its vault',
      () async {
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final server = FakeVaultServer()
          ..route(
            'GET',
            '/vaults/seed/api/v1/words',
            json: {
              'vault_id': _vaultId,
              'words': [
                {'word': 'memex', 'created_at': 1000},
              ],
            },
          );
        final access = HostedVaultAccess(
          client: server.connect(container),
          vaultName: 'seed',
        );

        final VaultAccess asInterface = access;
        expect(asInterface.words, isA<HostedWordsAccess>());
        expect(access.words.vaultName, 'seed');
        expect(_rows(await asInterface.words.list()), [('memex', 1000)]);
        expect(server.requests.single.method, 'GET');
        expect(server.requests.single.url.path, '/vaults/seed/api/v1/words');
      },
    );
  });
}
