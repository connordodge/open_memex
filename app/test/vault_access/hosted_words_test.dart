// WI #432 (Spec #392 req 15b, 16; D20, D21, D21a, D21b): HostedWordsAccess
// against the W2 wire fixtures in `test/fixtures/api_v1/words/` and the
// older-server compat rows in `compat/words_not_found.json`.
//
//   GET    /vaults/{name}/api/v1/words         -> {vault_id, words:[{word, created_at}]}
//   POST   /vaults/{name}/api/v1/words {word}  -> {vault_id, word, changed}
//   DELETE /vaults/{name}/api/v1/words/{word}  -> {vault_id, word, changed}
//   {word} is percent-encoded (Uri.encodeComponent).
//
// Only a 404 whose code is `not_found` means an older server: `list()` reads
// as no learned words and `learn` throws. The message is never matched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/words.dart';
import 'package:open_memex_app/src/vault_access/words_access.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _base = '/vaults/seed/api/v1';
const _wordsDir = '$apiV1FixturesDir/words';

/// The value `"<timestamp>"` placeholders in the fixtures stand for.
const _stamp = 1792539488433;

class _Env {
  _Env(this.server, this.container);

  final FakeVaultServer server;
  final ProviderContainer container;

  HostedWordsAccess get words =>
      HostedWordsAccess(client: server.connect(container), vaultName: 'seed');
}

_Env _env() {
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env(FakeVaultServer(), container);
}

/// Every row of `<domain>/index.json` whose response is [response].
List<FixtureRow> _row(String domain, String response) => [
  for (final row in loadFixtureRows(p.join(apiV1FixturesDir, domain)))
    if (row.response == response) row,
];

/// `words/<file>` decoded, with `"<timestamp>"` replaced by [_stamp].
Object? _fixture(String file) {
  final raw = File(p.join(_wordsDir, file)).readAsStringSync();
  return jsonDecode(raw.replaceAll('"<timestamp>"', '$_stamp'));
}

/// The one request [server] received (fails the test on any other count).
http.Request _only(FakeVaultServer server) {
  expect(server.requests, hasLength(1), reason: 'one request was sent');
  return server.requests.first;
}

/// The decoded body of the last request [server] received.
Object? _requestBody(FakeVaultServer server) {
  expect(server.requests, isNotEmpty, reason: 'a request was sent');
  return jsonDecode(server.requests.last.body);
}

List<(String, int)> _rows(List<LearnedWord> words) => [
  for (final w in words) (w.word, w.createdAt),
];

Map<String, Object?> _notFound(String message) => {
  'error': {'code': 'not_found', 'message': message},
};

void main() {
  group('HostedWordsAccess against api_v1/words', () {
    test('hosted list of an empty vault is empty (words_ls)', () async {
      final env = _env()..server.serveRows(_row('words', 'words_ls.json'));

      expect(await env.words.list(), isEmpty);
      expect(_only(env.server).method, 'GET');
      expect(_only(env.server).url.path, '$_base/words');
    });

    test(
      'hosted list parses words and created_at in order (words_ls_after_adds)',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/words',
          json: _fixture('words_ls_after_adds.json'),
        );

        expect(_rows(await env.words.list()), [
          ('memex', _stamp),
          ('Émile', _stamp),
        ]);
      },
    );

    test('hosted learn posts the word and returns changed true', () async {
      final env = _env()..server.serveDomain('words');

      final result = await env.words.learn('memex');

      final request = _only(env.server);
      expect(request.method, 'POST');
      expect(request.url.path, '$_base/words');
      expect(_requestBody(env.server), {'word': 'memex'});
      expect(result.word, 'memex');
      expect(result.changed, isTrue);
    });

    test('a repeat hosted learn returns changed false', () async {
      final env = _env()..server.serveDomain('words');

      final first = await env.words.learn('memex');
      final repeat = await env.words.learn('memex');

      expect(first.changed, isTrue);
      expect(repeat.word, 'memex');
      expect(repeat.changed, isFalse);
      expect(env.server.requests.map((r) => r.method), ['POST', 'POST']);
    });

    test(
      'a non-ASCII hosted learn sends and returns the word as written',
      () async {
        final env = _env()..server.serveDomain('words');

        final result = await env.words.learn('Émile');

        expect(_requestBody(env.server), {'word': 'Émile'});
        expect(result.word, 'Émile');
        expect(result.changed, isTrue);
      },
    );

    test(
      'a too-long hosted learn throws MemexException word_invalid',
      () async {
        final env = _env()..server.serveDomain('words');
        final tooLong = 'a' * 65;

        await expectLater(
          env.words.learn(tooLong),
          throwsA(
            isA<MemexException>().having((e) => e.code, 'code', 'word_invalid'),
          ),
        );
        expect(_requestBody(env.server), {'word': tooLong});
      },
    );

    test(
      'hosted unlearn sends DELETE words/memex and returns changed true',
      () async {
        final env = _env()..server.serveDomain('words');

        final result = await env.words.unlearn('memex');

        final request = _only(env.server);
        expect(request.method, 'DELETE');
        expect(request.url.path, '$_base/words/memex');
        expect(result.word, 'memex');
        expect(result.changed, isTrue);
      },
    );

    test(
      'a hosted unlearn of a word that is not there returns changed false',
      () async {
        final env = _env()..server.serveDomain('words');

        await env.words.unlearn('memex');
        final gone = await env.words.unlearn('memex');

        expect(gone.word, 'memex');
        expect(gone.changed, isFalse);
      },
    );

    test(
      'hosted unlearn percent-encodes a non-ASCII word in the DELETE path',
      () async {
        final env = _env()..server.serveDomain('words');

        final result = await env.words.unlearn('émile');

        expect(_only(env.server).url.path, '$_base/words/%C3%A9mile');
        expect(result.word, 'émile');
        expect(result.changed, isTrue);
      },
    );

    test(
      'hosted unlearn percent-encodes a slash so the word stays one path segment',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/words/km%2Fh',
          json: {'vault_id': 'v', 'word': 'km/h', 'changed': true},
        );

        final result = await env.words.unlearn('km/h');

        expect(_only(env.server).url.path, '$_base/words/km%2Fh');
        expect(result.word, 'km/h');
        expect(result.changed, isTrue);
      },
    );

    test(
      'hosted unlearn of a dot-only word throws and sends no request',
      () async {
        for (final word in ['.', '..']) {
          final env = _env();
          env.server
            ..route(
              'DELETE',
              '$_base/words/',
              json: {'vault_id': 'v', 'word': word, 'changed': true},
            )
            ..route(
              'DELETE',
              '$_base/',
              json: {'vault_id': 'v', 'word': word, 'changed': true},
            );

          await expectLater(
            env.words.unlearn(word),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.message, 'message', contains('"$word"')),
            ),
            reason: word,
          );

          expect(env.server.requests, isEmpty, reason: 'no request for $word');
        }
      },
    );

    test(
      'hosted unlearn of words that merely contain dots still sends',
      () async {
        for (final word in ['...', 'a.b', '.a']) {
          final env = _env();
          env.server.route(
            'DELETE',
            '$_base/words/${Uri.encodeComponent(word)}',
            json: {'vault_id': 'v', 'word': word, 'changed': true},
          );

          final result = await env.words.unlearn(word);

          expect(result.changed, isTrue, reason: word);
          expect(_only(env.server).method, 'DELETE', reason: word);
        }
      },
    );

    test(
      'a hosted learn reply without word and changed throws a null-code MemexException',
      () async {
        final env = _env();
        env.server.route('POST', '$_base/words', json: {'vault_id': 'v'});

        await expectLater(
          env.words.learn('memex'),
          throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull)),
        );
      },
    );

    test(
      'a hosted list row without created_at throws a null-code MemexException',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/words',
          json: {
            'vault_id': 'v',
            'words': [
              {'word': 'memex'},
            ],
          },
        );

        await expectLater(
          env.words.list(),
          throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull)),
        );
      },
    );
  });

  group('malformed replies and refusals (verify)', () {
    Matcher nullCode() =>
        throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull));

    test(
      'a hosted list reply without a words array throws a null-code MemexException',
      () async {
        final env = _env();
        env.server.route('GET', '$_base/words', json: {'vault_id': 'v'});
        await expectLater(env.words.list(), nullCode());

        env.server.route(
          'GET',
          '$_base/words',
          json: {'vault_id': 'v', 'words': 'memex'},
        );
        await expectLater(env.words.list(), nullCode());
      },
    );

    test(
      'a hosted list with one bad row after good rows throws instead of returning the good ones',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/words',
          json: {
            'vault_id': 'v',
            'words': [
              {'word': 'memex', 'created_at': 1},
              {'word': 'teh', 'created_at': 'yesterday'},
              {'word': 'zeta', 'created_at': 3},
            ],
          },
        );

        await expectLater(env.words.list(), nullCode());
      },
    );

    test(
      'a hosted unlearn reply without word and changed throws a null-code MemexException',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/words/memex',
          json: {'vault_id': 'v', 'word': 'memex'},
        );

        await expectLater(env.words.unlearn('memex'), nullCode());
      },
    );

    test(
      'a 404 not_found on hosted learn and unlearn throws the not_found MemexException',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '$_base/words',
          status: 404,
          json: _notFound('no such route'),
        );
        env.server.route(
          'DELETE',
          '$_base/words/memex',
          status: 404,
          json: _notFound('no such route'),
        );

        for (final call in [
          () => env.words.learn('memex'),
          () => env.words.unlearn('memex'),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<MemexException>().having((e) => e.code, 'code', 'not_found'),
            ),
          );
        }
      },
    );

    test(
      'a 404 vault_not_found on hosted learn and unlearn throws it, not older-server handling',
      () async {
        final env = _env()..server.removeVault('seed');

        for (final call in [
          () => env.words.learn('memex'),
          () => env.words.unlearn('memex'),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<MemexException>().having(
                (e) => e.code,
                'code',
                'vault_not_found',
              ),
            ),
          );
        }
      },
    );
  });

  group('older hosted servers (compat/words_not_found.json)', () {
    test(
      'against words_not_found hosted list returns no learned words',
      () async {
        final env = _env()..server.serveDomain('compat');

        expect(await env.words.list(), isEmpty);
        expect(_only(env.server).method, 'GET');
        expect(_only(env.server).url.path, '$_base/words');
      },
    );

    test('against words_not_found hosted learn throws', () async {
      final env = _env()..server.serveDomain('compat');

      await expectLater(env.words.learn('memex'), throwsA(isA<Exception>()));
      expect(_only(env.server).method, 'POST');
    });

    test('against words_not_found hosted unlearn throws', () async {
      final env = _env()..server.serveDomain('compat');

      await expectLater(
        env.words.unlearn('serendipity'),
        throwsA(isA<Exception>()),
      );
      expect(_only(env.server).url.path, '$_base/words/serendipity');
    });

    test('a 404 not_found with any message reads as an older server', () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/words',
        status: 404,
        json: _notFound('something else entirely'),
      );

      expect(await env.words.list(), isEmpty);
      expect(env.server.requests, hasLength(1));
    });

    test(
      'a 404 vault_not_found is not an older server: hosted list throws it',
      () async {
        final env = _env()..server.removeVault('seed');

        await expectLater(
          env.words.list(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'vault_not_found',
            ),
          ),
        );
      },
    );

    test('a 500 on hosted list throws instead of reading as empty', () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/words',
        status: 500,
        json: {
          'error': {'code': 'internal', 'message': 'boom'},
        },
      );

      await expectLater(
        env.words.list(),
        throwsA(
          isA<MemexException>().having((e) => e.code, 'code', 'internal'),
        ),
      );
    });
  });
}
