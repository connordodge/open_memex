// #75 (56-A1b): HostedSearchAccess reads `GET /vaults/{name}/api/v1/search
// ?q=<text>&limit=8` through HostedClient and maps the outcome (Spec #59
// req 37-39; rulings D18). Answers come from #73's wire fixtures
// (`api_v1/search/index.json`, `compat/search_not_found.json`) through the
// fixture loader; a case with no row adds its own route.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/search.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _searchPath = '/vaults/seed/api/v1/search';

const _noRoute = 'not found: no route for this path';

/// The request path and query the access sends for [query].
String _requestFor(String query) => Uri(
  path: _searchPath,
  queryParameters: {'q': query, 'limit': '8'},
).toString();

class _Env75 {
  _Env75(this.container, this.clock, this.server);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;

  HostedSearchAccess get access =>
      HostedSearchAccess(client: server.connect(container), vaultName: 'seed');

  HostedConnectionStatus? get status =>
      container.read(hostedConnectionStatusProvider(fakeServerId));
}

_Env75 _env(List<String> domains) {
  final clock = FakeClock();
  final server = FakeVaultServer();
  for (final d in domains) {
    server.serveDomain(d);
  }
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env75(container, clock, server);
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// The rows of #73's `api_v1/search/index.json`.
List<FixtureRow> _searchRows() =>
    loadFixtureRows(p.join(apiV1FixturesDir, 'search'));

/// The row of `api_v1/search/index.json` that answers with [response].
FixtureRow _searchRow(String response) =>
    _searchRows().singleWhere((r) => r.response == response);

/// The `q` of [row]'s path; empty when the row has none.
String _rowQuery(FixtureRow row) =>
    Uri.parse(row.path).queryParameters['q'] ?? '';

/// [row] answering the request the access sends for the row's own query
/// (the access always asks for 8; a row may name another limit).
FixtureRow _servedAt(FixtureRow row) => FixtureRow(
  domainDir: row.domainDir,
  method: row.method,
  path: _requestFor(_rowQuery(row)),
  request: row.request,
  response: row.response,
  status: row.status,
  headers: row.headers,
  dartOnly: row.dartOnly,
);

const _wireSemantic = <String, Semantic>{
  'on': Semantic.on,
  'model_not_downloaded': Semantic.modelNotDownloaded,
  'embeddings_off': Semantic.embeddingsOff,
  'unavailable': Semantic.unavailable,
};

/// The [SearchReady] a req 34 answer [json] means, mapped field by field
/// here (not through the production parser).
SearchReady _expectedReady(Map<String, Object?> json) => SearchReady(
  [
    for (final h
        in (json['hits']! as List<Object?>).cast<Map<String, Object?>>())
      SearchHit(
        noteId: h['note_id']! as String,
        noteTitle: h['note_title']! as String,
        noteRole: h['note_role'] as String?,
        day: h['day'] as String?,
        chunkId: h['chunk_id']! as String,
        snippet: h['snippet']! as String,
        startByte: h['start_byte'] as int?,
        via: h['via'] as String?,
        noteUpdatedAt: h['note_updated_at']! as int,
      ),
  ],
  semantic: _wireSemantic[json['semantic']! as String]!,
  truncated: json['truncated']! as bool,
);

/// An `http.Client` that holds every response until the test answers it and
/// counts abort triggers that fire.
class _Held75 extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final List<Completer<http.StreamedResponse>> _pending = [];
  int aborts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    final pending = Completer<http.StreamedResponse>();
    _pending.add(pending);
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          aborts++;
          if (!pending.isCompleted) {
            pending.completeError(http.RequestAbortedException(request.url));
          }
        }),
      );
    }
    return pending.future;
  }

  void respond(int i, int status, Object json) => _pending[i].complete(
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(json))),
      status,
      request: requests[i],
      headers: {'content-type': 'application/json'},
    ),
  );
}

HostedClient _clientOver(_Env75 env, http.Client httpClient) {
  final provider = Provider<HostedClient>(
    (ref) => HostedClient(
      ref,
      serverId: fakeServerId,
      serverName: fakeServerName,
      serverUrl: fakeServerUrl,
      accessToken: fakeServerToken,
      httpClient: httpClient,
    ),
  );
  return env.container.read(provider);
}

void main() {
  group('request', () {
    test(
      'hosted search pricing sends one GET to the search route with q pricing and limit 8',
      () async {
        final env = _env([]);

        await _outcome(env.access.search('pricing'));

        expect(env.server.requests, hasLength(1));
        final r = env.server.requests.single;
        expect(r.method, 'GET');
        expect(r.url.path, '/vaults/seed/api/v1/search');
        expect(r.url.queryParameters, {'q': 'pricing', 'limit': '8'});
        expect(r.bodyBytes, isEmpty);
      },
    );

    test(
      'hosted search request matches the fixture row path verbatim',
      () async {
        final env = _env(['search']);

        final result = await env.access.search('prices');

        // Rows 0-2 share this path and are served in order: row 0 first.
        final first = _searchRows().first;
        expect(Uri.parse(first.path).queryParameters, {
          'q': 'prices',
          'limit': '8',
        });
        expect(
          result,
          _expectedReady(first.readResponseJson()! as Map<String, Object?>),
        );
      },
    );

    test('hosted search sends the query text unchanged in q', () async {
      const queries = [
        'shop prices',
        'a&b=c?d#e',
        'die🎲 run',
        '  padded  ',
        '',
      ];
      for (final q in queries) {
        final env = _env([]);

        await _outcome(env.access.search(q));

        expect(env.server.requests, hasLength(1), reason: '"$q"');
        expect(env.server.requests.single.url.queryParameters, {
          'q': q,
          'limit': '8',
        }, reason: '"$q"');
      }
    });

    test(
      'hosted search allowDownload true sends the same request as false',
      () async {
        final env = _env([]);
        env.server.serveRows([_servedAt(_searchRow('search_on.json'))]);

        final withoutDownload = await env.access.search('prices');
        final withDownload = await env.access.search(
          'prices',
          allowDownload: true,
        );

        expect(env.server.requests, hasLength(2));
        final [off, on] = env.server.requests;
        expect(on.method, off.method);
        expect(on.url, off.url);
        expect(on.url.queryParameters.keys.toSet(), {'q', 'limit'});
        expect(on.bodyBytes, off.bodyBytes);
        expect(withDownload, withoutDownload);
        expect(withDownload, isA<SearchReady>());
      },
    );
  });

  group('answers', () {
    test(
      'hosted each search fixture row 200 response parses into SearchReady with its hits and semantic',
      () async {
        final rows = _searchRows().where((r) => r.status == 200).toList();
        expect(rows.length, greaterThanOrEqualTo(5));
        final semantics = <Semantic>{};
        for (final row in rows) {
          final env = _env([]);
          env.server.serveRows([_servedAt(row)]);
          final json = row.readResponseJson()! as Map<String, Object?>;

          final result = await _outcome(env.access.search(_rowQuery(row)));

          final expected = _expectedReady(json);
          expect(result, expected, reason: '$row');
          result as SearchReady;
          expect(result.hits, hasLength(expected.hits.length), reason: '$row');
          expect(result.semantic, expected.semantic, reason: '$row');
          expect(result.truncated, json['truncated'], reason: '$row');
          semantics.add(result.semantic);
        }
        expect(semantics, {
          Semantic.on,
          Semantic.embeddingsOff,
          Semantic.unavailable,
        });
      },
    );

    test('hosted embeddings_off fixture maps every hit field', () async {
      final env = _env([]);
      env.server.serveRows([
        _servedAt(_searchRow('search_embeddings_off.json')),
      ]);

      final result = await env.access.search('prices');

      expect(result, isA<SearchReady>());
      result as SearchReady;
      expect(result.semantic, Semantic.embeddingsOff);
      expect(result.truncated, isFalse);
      expect(result.hits, hasLength(3));
      expect(
        result.hits[0],
        SearchHit(
          noteId: '01M5DQAYZ5T5B865CDF2RWAC37'.toString(),
          noteTitle: '2026-10-17',
          noteRole: 'daily',
          day: '2026-10-17',
          chunkId: '01M5DQAYZKVWVP01WR8GCXZ6KZ',
          snippet: 'Tuned the shop prices.\n\nThen undid half of it.',
          startByte: int.parse('0'),
          noteUpdatedAt: int.parse('1792535788530'),
        ),
      );
      expect(
        result.hits[2],
        SearchHit(
          noteId: '01M5DQAYZ47QW55S90ZF0A56AH'.toString(),
          noteTitle: 'Economy Design',
          noteRole: 'topic',
          chunkId: '01M5DQAYZFW5NANWNHESXCHD7R',
          snippet: 'Sketched a crafting tree.',
          startByte: int.parse('0'),
          via: '2026-10-19',
          noteUpdatedAt: int.parse('1792535788527'),
        ),
      );
    });

    test(
      'hosted truncated and empty fixtures keep truncated and an empty hit list',
      () async {
        final truncatedEnv = _env([]);
        truncatedEnv.server.serveRows([
          _servedAt(_searchRow('search_truncated.json')),
        ]);
        final truncated = await truncatedEnv.access.search('prices');
        expect(truncated, isA<SearchReady>());
        expect((truncated as SearchReady).truncated, isTrue);
        expect(truncated.hits, hasLength(1));

        final emptyEnv = _env([]);
        emptyEnv.server.serveRows([_servedAt(_searchRow('search_empty.json'))]);
        final empty = await emptyEnv.access.search('');
        expect(
          empty,
          const SearchReady(
            [],
            semantic: Semantic.embeddingsOff,
            truncated: false,
          ),
        );
      },
    );

    test(
      'hosted 200 body that is not a valid search answer throws MemexException',
      () async {
        final bodies = <Object?>[
          <String, Object?>{'hits': <Object?>[], 'truncated': false},
          <String, Object?>{'semantic': 'on', 'truncated': false},
          <String, Object?>{
            'semantic': 'on',
            'hits': 'nope',
            'truncated': false,
          },
          <String, Object?>{'semantic': 'on', 'hits': <Object?>[]},
          <String, Object?>{
            'semantic': 'on',
            'hits': [
              {'note_id': 'n1'},
            ],
            'truncated': false,
          },
        ];
        for (final body in bodies) {
          final env = _env([]);
          env.server.route('GET', _requestFor('bad'), json: body);

          final e = await _outcome(env.access.search('bad'));

          expect(e, isA<MemexException>(), reason: '$body');
          expect((e! as MemexException).code, isNull, reason: '$body');
        }
      },
    );
  });

  group('unavailable', () {
    test(
      'hosted compat search_not_found response maps to SearchUnavailable ServerOutdated',
      () async {
        final env = _env(['compat']);

        final result = await env.access.search('prices');

        expect(result, const SearchUnavailable(ServerOutdated()));
        expect(env.server.requests.single.url.path, _searchPath);
      },
    );

    test(
      'hosted compat no-route answer for any query maps to ServerOutdated',
      () async {
        final compat = loadFixtureRows(
          p.join(apiV1FixturesDir, 'compat'),
        ).singleWhere((r) => r.response == 'search_not_found.json');
        expect(compat.status, 404);
        for (final q in ['pricing', 'loot tables']) {
          final env = _env([]);
          env.server.serveRows([
            FixtureRow(
              domainDir: compat.domainDir,
              method: compat.method,
              path: _requestFor(q),
              request: compat.request,
              response: compat.response,
              status: compat.status,
              headers: compat.headers,
              dartOnly: compat.dartOnly,
            ),
          ]);

          final result = await env.access.search(q);

          expect(result, const SearchUnavailable(ServerOutdated()), reason: q);
        }
      },
    );
  });

  group('errors', () {
    test(
      'hosted 404 not_found with another message throws not ServerOutdated',
      () async {
        const messages = [
          'no route for this path',
          'not found: no route for this path.',
          'Not found: no route for this path',
          'not found: no route for this path ',
          'not found: note n-nm',
          '',
        ];
        for (final message in messages) {
          final env = _env([]);
          env.server.route(
            'GET',
            _requestFor('prices'),
            status: 404,
            json: {
              'error': {'code': 'not_found', 'message': message},
            },
          );

          final e = await _outcome(env.access.search('prices'));

          expect(e, isA<MemexException>(), reason: '"$message"');
          expect(
            (e! as MemexException).code,
            'not_found',
            reason: '"$message"',
          );
          expect(
            (e as MemexException).message,
            'search failed: $message',
            reason: '"$message"',
          );
        }
      },
    );

    test(
      'hosted exact no-route message under another code throws not ServerOutdated',
      () async {
        final env = _env([]);
        env.server.route(
          'GET',
          _requestFor('prices'),
          status: 404,
          json: {
            'error': {'code': 'vault_not_found', 'message': _noRoute},
          },
        );

        final e = await _outcome(env.access.search('prices'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'vault_not_found');
      },
    );

    test(
      'hosted search_limit_invalid 400 throws MemexException invalid_argument',
      () async {
        final env = _env([]);
        final row = _searchRow('search_limit_invalid.json');
        expect(row.status, 400);
        env.server.serveRows([_servedAt(row)]);

        final e = await _outcome(env.access.search('prices'));

        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'invalid_argument');
        expect(e.message, 'search failed: invalid limit: 0 (1 to 20)');
      },
    );

    test('hosted unmapped search errors rethrow with their code', () async {
      const cases = <(int, String)>[
        (500, 'internal'),
        (400, 'invalid_argument'),
        (409, 'embeddings_off'),
        (503, 'embedder_unavailable'),
        (503, 'unavailable'),
      ];
      for (final (status, code) in cases) {
        final env = _env([]);
        env.server.route(
          'GET',
          _requestFor('prices'),
          status: status,
          json: {
            'error': {'code': code, 'message': 'm-$code'},
          },
        );

        final result = await _outcome(env.access.search('prices'));

        expect(result, isA<MemexException>(), reason: '$status $code');
        expect((result! as MemexException).code, code, reason: '$status $code');
      }
    });

    test('hosted non-C1 HTTP error is thrown', () async {
      final env = _env([]);
      env.server.route(
        'GET',
        _requestFor('prices'),
        status: 502,
        body: '<html>bad gateway</html>',
        contentType: 'text/html',
      );

      final e = await _outcome(env.access.search('prices'));

      expect(e, isA<MemexException>());
      expect((e! as MemexException).message, 'search failed: HTTP 502');
    });

    test(
      'hosted search 401 throws MemexException unauthorized and records token rejected',
      () async {
        final env = _env(['search']);
        // Connect first: connect() reads the server's current token.
        final access = env.access;
        env.server.token = 'a-different-token';

        final e = await _outcome(access.search('prices'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'unauthorized');
        expect(env.status, HostedConnectionStatus.tokenRejected);
      },
    );

    test(
      'hosted search refused connection propagates VaultUnreachableException',
      () async {
        final env = _env(['search']);
        env.server.failure = FakeServerFailure.refused;

        final e = await _outcome(env.access.search('prices'));

        expect(e, isA<VaultUnreachableException>());
        expect((e! as VaultUnreachableException).mayHaveCommitted, isFalse);
        expect(env.status, HostedConnectionStatus.unreachable);
      },
    );
  });

  group('timeout', () {
    test(
      'hosted search waits 60 s then throws HostedRequestTimeout to the caller',
      () async {
        final env = _env([]);
        final held = _Held75();
        final access = HostedSearchAccess(
          client: _clientOver(env, held),
          vaultName: 'seed',
        );
        final outcomes = <Object?>[];
        unawaited(_outcome(access.search('prices')).then(outcomes.add));
        await pumpEventQueue();
        expect(held.requests, hasLength(1));

        env.clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();
        expect(outcomes, isEmpty, reason: 'the default 10 s must not apply');
        expect(held.aborts, 0);

        env.clock.advance(const Duration(seconds: 49));
        await pumpEventQueue();
        expect(outcomes, isEmpty, reason: 'still before 60 s');
        expect(held.aborts, 0);

        env.clock.advance(const Duration(seconds: 1));
        await pumpEventQueue();
        expect(outcomes, hasLength(1));
        expect(outcomes.single, isA<HostedRequestTimeout>());
        expect(held.aborts, 1, reason: 'the request is aborted');
        expect(
          env.status,
          isNot(HostedConnectionStatus.unreachable),
          reason: 'a slow search is not an outage',
        );
        expect(env.clock.pendingTimers, 0);
      },
    );

    test(
      'hosted search answered before 60 s returns the result and cancels the timer',
      () async {
        final env = _env([]);
        final held = _Held75();
        final access = HostedSearchAccess(
          client: _clientOver(env, held),
          vaultName: 'seed',
        );
        final outcomes = <Object?>[];
        unawaited(_outcome(access.search('prices')).then(outcomes.add));
        await pumpEventQueue();

        env.clock.advance(const Duration(seconds: 30));
        await pumpEventQueue();
        expect(held.requests, hasLength(1));
        expect(outcomes, isEmpty, reason: 'the 10 s default does not apply');
        held.respond(0, 200, {
          'query': 'prices',
          'semantic': 'on',
          'hits': <Object?>[],
          'truncated': false,
        });
        await pumpEventQueue();

        expect(outcomes, [
          const SearchReady([], semantic: Semantic.on, truncated: false),
        ]);
        expect(env.clock.pendingTimers, 0);
        expect(env.status, HostedConnectionStatus.connected);
        expect(held.aborts, 0);
      },
    );
  });

  group('composite', () {
    test('HostedVaultAccess search returns a HostedSearchAccess', () {
      final env = _env([]);
      final access = HostedVaultAccess(
        client: env.server.connect(env.container),
        vaultName: 'seed',
      );

      expect(access.search, isA<HostedSearchAccess>());
      expect((access.search as HostedSearchAccess).vaultName, 'seed');
    });

    test('hosted placeholder search is gone from HostedVaultAccess', () {
      final source = File(
        'lib/src/vault_access/hosted/hosted_vault_access.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('_ServerOutdatedSearch')));
    });

    test(
      'hosted search through the composite sends the request and parses the answer',
      () async {
        final env = _env([]);
        final row = _searchRow('search_on.json');
        env.server.serveRows([_servedAt(row)]);
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
        );

        final result = await access.search.search('prices');

        expect(env.server.requests, hasLength(1));
        expect(
          result,
          _expectedReady(row.readResponseJson()! as Map<String, Object?>),
        );
      },
    );

    test(
      'hosted compat search through the composite maps to ServerOutdated',
      () async {
        final env = _env(['compat']);
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
        );

        final result = await access.search.search('prices');

        expect(env.server.requests, hasLength(1));
        expect(result, const SearchUnavailable(ServerOutdated()));
      },
    );

    test(
      'hosted search vault_not_found through the composite reports the vault gone',
      () async {
        final env = _env(['search']);
        env.server.removeVault('seed');
        var gone = 0;
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
          onVaultGone: () => gone++,
        );

        final e = await _outcome(access.search.search('prices'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'vault_not_found');
        expect(gone, 1);
      },
    );

    test(
      'hosted search on a disposed composite throws StateError and sends nothing',
      () async {
        final env = _env(['search']);
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
        );
        access.dispose();

        final e = await _outcome(access.search.search('prices'));

        expect(e, isA<StateError>());
        expect(env.server.requests, isEmpty);
      },
    );

    test('hosted search through the composite also waits 60 s', () async {
      final env = _env([]);
      final held = _Held75();
      final access = HostedVaultAccess(
        client: _clientOver(env, held),
        vaultName: 'seed',
      );
      final outcomes = <Object?>[];
      unawaited(_outcome(access.search.search('prices')).then(outcomes.add));
      await pumpEventQueue();
      expect(held.requests, hasLength(1));

      env.clock.advance(const Duration(seconds: 59));
      await pumpEventQueue();
      expect(outcomes, isEmpty);

      env.clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(outcomes.single, isA<HostedRequestTimeout>());
      expect(env.status, isNot(HostedConnectionStatus.unreachable));
    });
  });
}
