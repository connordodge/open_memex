// #74 (56-A1): LocalSearchAccess runs `memex search` through the CLI and maps
// the outcome (Spec #59 req 34, 39). Everything goes through FakeMemexCli; no
// real `memex` ever runs. Each mapping is pinned on both arms: the exit code,
// JSON vs non-JSON stderr, and a C1 code that echoes would map but search
// does not.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/vaults/My Vault';

/// A req 34 hit object for a topic note, every key present.
Map<String, Object?> _topicRow() => {
  'note_id': '01JSEARCHTOPIC0000000000001',
  'note_title': 'Pricing',
  'note_role': 'topic',
  'day': null,
  'chunk_id': '01JSEARCHCHUNK0000000000001',
  'snippet': 'The pricing plan for next year.',
  'start_byte': 42,
  'via': null,
  'note_updated_at': 1731900000000,
};

/// A req 34 hit object for a daily note transcluded into another day, with
/// no byte offset.
Map<String, Object?> _dailyRow() => {
  'note_id': '01JSEARCHDAILY0000000000002',
  'note_title': '2026-11-17',
  'note_role': 'daily',
  'day': '2026-11-17',
  'chunk_id': '01JSEARCHCHUNK0000000000002',
  'snippet': 'Talked about pricing at lunch.',
  'start_byte': null,
  'via': '2026-11-18',
  'note_updated_at': 1731800000000,
};

/// One compact CLI answer line.
String _answer({
  String query = 'pricing',
  Object? semantic = 'on',
  List<Object?>? hits,
  Object? truncated = false,
}) =>
    '${jsonEncode({'query': query, 'semantic': semantic, 'hits': hits ?? <Object?>[], 'truncated': truncated})}\n';

/// Access over a fake whose `search` handler is [handler].
(LocalSearchAccess, FakeMemexCli) _access(FakeCliHandler handler) {
  final cli = FakeMemexCli()..on('search', handler);
  return (LocalSearchAccess(vaultPath: _vault, cli: cli), cli);
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  group('arguments and timeouts', () {
    test(
      'local search runs memex search with the vault and query and no limit and a 60 s timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_answer()));

        await access.search('pricing');

        expect(cli.callsFor('search'), hasLength(1));
        final call = cli.callsFor('search').single;
        expect(call.args, ['search', '--vault', _vault, '--query', 'pricing']);
        expect(call.hasFlag('limit'), isFalse);
        expect(call.hasFlag('allow-download'), isFalse);
        expect(call.timeout, const Duration(seconds: 60));
      },
    );

    test(
      'local search allowDownload adds --allow-download and a 10 minute timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_answer()));

        await access.search('pricing', allowDownload: true);

        expect(cli.callsFor('search'), hasLength(1));
        final call = cli.callsFor('search').single;
        expect(call.args, [
          'search',
          '--vault',
          _vault,
          '--query',
          'pricing',
          '--allow-download',
        ]);
        expect(call.hasFlag('limit'), isFalse);
        expect(call.timeout, const Duration(minutes: 10));
      },
    );

    test(
      'local search allowDownload false after true goes back to the 60 s timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_answer()));

        await access.search('pricing', allowDownload: true);
        await access.search('pricing');

        final calls = cli.callsFor('search');
        expect(calls, hasLength(2));
        expect(calls[0].timeout, const Duration(minutes: 10));
        expect(calls[1].timeout, const Duration(seconds: 60));
        expect(calls[1].hasFlag('allow-download'), isFalse);
      },
    );

    test(
      'local search passes a query that starts with a hyphen as the --query value',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_answer()));

        await access.search('-1');

        expect(cli.callsFor('search'), hasLength(1));
        final call = cli.callsFor('search').single;
        expect(call.args, ['search', '--vault', _vault, '--query', '-1']);
        expect(call.flag('query'), '-1');
      },
    );

    test(
      'local search passes a query with spaces and dashes as one argument',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_answer()));

        await access.search('--limit 3 pricing plan');

        expect(cli.callsFor('search'), hasLength(1));
        final call = cli.callsFor('search').single;
        expect(call.args, [
          'search',
          '--vault',
          _vault,
          '--query',
          '--limit 3 pricing plan',
        ]);
      },
    );

    test('local search passes the extension the vault of the access', () async {
      final cli = FakeMemexCli()
        ..on('search', (_) => FakeMemexCli.ok(_answer()));
      final access = LocalSearchAccess(
        vaultPath: '/vaults/Other Vault'.toString(),
        cli: cli,
      );

      await access.search('pricing');

      expect(cli.calls, hasLength(1));
      expect(cli.calls.single.flag('vault'), '/vaults/Other Vault');
    });
  });

  group('exit 0', () {
    test(
      'local exit 0 with R34 JSON returns SearchReady with the parsed hits semantic and truncated',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.ok(
            _answer(
              semantic: 'model_not_downloaded',
              hits: [_topicRow(), _dailyRow()],
              truncated: true,
            ),
          ),
        );

        final result = await access.search('pricing');

        // Built from run-time values so the constructors and == really run.
        final expected = SearchReady(
          [
            SearchHit(
              noteId: '01JSEARCHTOPIC0000000000001'.toString(),
              noteTitle: 'Pricing',
              noteRole: 'topic',
              chunkId: '01JSEARCHCHUNK0000000000001',
              snippet: 'The pricing plan for next year.',
              startByte: int.parse('42'),
              noteUpdatedAt: int.parse('1731900000000'),
            ),
            SearchHit(
              noteId: '01JSEARCHDAILY0000000000002'.toString(),
              noteTitle: '2026-11-17',
              noteRole: 'daily',
              day: '2026-11-17',
              chunkId: '01JSEARCHCHUNK0000000000002',
              snippet: 'Talked about pricing at lunch.',
              via: '2026-11-18',
              noteUpdatedAt: int.parse('1731800000000'),
            ),
          ],
          semantic: Semantic.modelNotDownloaded,
          truncated: bool.parse('true'),
        );
        expect(result, expected);
        result as SearchReady;
        expect(result.hits, hasLength(2));
        expect(result.hits[0].startByte, 42);
        expect(result.hits[1].startByte, isNull);
        expect(result.hits[1].via, '2026-11-18');
        expect(result.semantic, Semantic.modelNotDownloaded);
        expect(result.truncated, isTrue);
      },
    );

    test(
      'semantic strings map to their Semantic values and any other string to unknown',
      () async {
        const cases = <(String, Semantic)>[
          ('on', Semantic.on),
          ('model_not_downloaded', Semantic.modelNotDownloaded),
          ('embeddings_off', Semantic.embeddingsOff),
          ('unavailable', Semantic.unavailable),
          ('off', Semantic.unknown),
          ('ON', Semantic.unknown),
          ('modelNotDownloaded', Semantic.unknown),
          ('', Semantic.unknown),
          ('keyword_only', Semantic.unknown),
        ];
        for (final (wire, expected) in cases) {
          final (access, _) = _access(
            (_) =>
                FakeMemexCli.ok(_answer(semantic: wire, hits: [_topicRow()])),
          );

          final result = await access.search('pricing');

          expect(result, isA<SearchReady>(), reason: wire);
          expect((result as SearchReady).semantic, expected, reason: wire);
          expect(result.hits, hasLength(1), reason: wire);
        }
      },
    );

    test(
      'local exit 0 with no hits and truncated false is an empty SearchReady',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.ok(_answer(semantic: 'embeddings_off')),
        );

        final result = await access.search('pricing');

        expect(
          result,
          const SearchReady(
            [],
            semantic: Semantic.embeddingsOff,
            truncated: false,
          ),
        );
      },
    );

    test('local exit 0 answer without a query key still parses', () async {
      final (access, _) = _access(
        (_) => FakeMemexCli.ok(
          '${jsonEncode({
            'semantic': 'unavailable',
            'hits': [_topicRow()],
            'truncated': false,
          })}\n',
        ),
      );

      final result = await access.search('pricing');

      expect(result, isA<SearchReady>());
      result as SearchReady;
      expect(result.semantic, Semantic.unavailable);
      expect(result.hits.single.noteId, '01JSEARCHTOPIC0000000000001');
    });

    test('local exit 0 with non-JSON stdout throws MemexException', () async {
      final (access, _) = _access(
        (_) => FakeMemexCli.ok('note text search output\n'),
      );

      final e = await _outcome(access.search('pricing'));

      expect(e, isA<MemexException>());
      expect(e, isNot(isA<FormatException>()));
    });

    final malformed = <(String, String)>[
      ('local exit 0 with a JSON list throws MemexException', '[]\n'),
      (
        'local exit 0 without semantic throws MemexException',
        '${jsonEncode({'query': 'pricing', 'hits': <Object?>[], 'truncated': false})}\n',
      ),
      (
        'local exit 0 with a numeric semantic throws MemexException',
        _answer(semantic: 1),
      ),
      (
        'local exit 0 without hits throws MemexException',
        '${jsonEncode({'query': 'pricing', 'semantic': 'on', 'truncated': false})}\n',
      ),
      (
        'local exit 0 with hits that are not a list throws MemexException',
        '${jsonEncode({'query': 'pricing', 'semantic': 'on', 'hits': <String, Object?>{}, 'truncated': false})}\n',
      ),
      (
        'local exit 0 without truncated throws MemexException',
        '${jsonEncode({'query': 'pricing', 'semantic': 'on', 'hits': <Object?>[]})}\n',
      ),
      (
        'local exit 0 with a string truncated throws MemexException',
        _answer(truncated: 'false'),
      ),
      (
        'local exit 0 with a hit that is not an object throws MemexException',
        _answer(hits: ['a hit']),
      ),
      (
        'local exit 0 with a hit missing note_id throws MemexException',
        _answer(hits: [_topicRow()..remove('note_id')]),
      ),
      (
        'local exit 0 with a hit whose start_byte is a string throws MemexException',
        _answer(hits: [_topicRow()..['start_byte'] = '42']),
      ),
    ];
    for (final (name, stdout) in malformed) {
      test(name, () async {
        final (access, _) = _access((_) => FakeMemexCli.ok(stdout));

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
        expect(e, isNot(isA<FormatException>()));
      });
    }
  });

  group('failures', () {
    test(
      'local exit 2 with non-JSON stderr returns SearchUnavailable MemexOutdated',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.failure(
            "error: unrecognized subcommand 'search'\n\nUsage: memex <COMMAND>\n",
            exitCode: 2,
          ),
        );

        final result = await access.search('pricing');

        expect(result, const SearchUnavailable(MemexOutdated()));
        // Value equality, not just the canonical const instance.
        expect(result, SearchUnavailable(MemexOutdated()));
        expect(result, isA<SearchUnavailable>());
        expect((result as SearchUnavailable).reason, isA<MemexOutdated>());
      },
    );

    test(
      'local exit 2 with C1 JSON stderr throws MemexException with its code',
      () async {
        final (access, _) = _access(
          (_) => MemexResult(
            exitCode: 2,
            stdout: '',
            stderr:
                '${jsonEncode({
                  'error': {'code': 'invalid_argument', 'message': 'bad limit'},
                })}\n',
          ),
        );

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'invalid_argument');
      },
    );

    test(
      'local exit 1 with C1 JSON stderr throws MemexException carrying the C1 code',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.error('vault_open_failed', 'no such vault'),
        );

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
        final failure = e! as MemexException;
        expect(failure.code, 'vault_open_failed');
        expect(failure.message, contains('no such vault'));
      },
    );

    test(
      'local exit 1 with C1 model_not_downloaded is thrown not mapped to a result',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.error('model_not_downloaded', 'no model'),
        );

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'model_not_downloaded');
      },
    );

    test(
      'local exit 1 with C1 embedder_unavailable is thrown not mapped to a result',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.error('embedder_unavailable', 'no embedder'),
        );

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'embedder_unavailable');
      },
    );

    test('local exit 1 with non-JSON stderr throws MemexException', () async {
      final (access, _) = _access(
        (_) => FakeMemexCli.failure('thread main panicked\n'),
      );

      final e = await _outcome(access.search('pricing'));

      expect(e, isA<MemexException>());
      expect((e! as MemexException).code, isNull);
    });

    test(
      'local exit 3 with non-JSON stderr throws MemexException not outdated',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.failure('killed\n', exitCode: 3),
        );

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexException>());
      },
    );

    test(
      'local MemexCliTimeout is thrown to the caller not mapped to a result',
      () async {
        final (access, _) = _access(FakeMemexCli.timedOut);

        final e = await _outcome(access.search('pricing'));

        expect(e, isA<MemexCliTimeout>());
        expect((e! as MemexCliTimeout).timeout, const Duration(seconds: 60));
      },
    );

    test(
      'local MemexCliTimeout with allowDownload is thrown after 10 minutes',
      () async {
        final (access, _) = _access(FakeMemexCli.timedOut);

        final e = await _outcome(access.search('pricing', allowDownload: true));

        expect(e, isA<MemexCliTimeout>());
        expect((e! as MemexCliTimeout).timeout, const Duration(minutes: 10));
      },
    );
  });
}
