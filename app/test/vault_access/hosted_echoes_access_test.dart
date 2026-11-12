// #425 (391-A1): HostedEchoesAccess reads `GET /vaults/{name}/api/v1/notes/
// {note_id}/echoes?limit=8` through HostedClient and maps the outcome (Spec
// #391 req 20, 21; rulings D21, D21a). Fixture rows come from the V4 notes
// domain and #401's compat domain; a case with no row adds its own route.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

/// Seed notes the V4 fixture rows answer for.
const _okNote = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _missingNote = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _offNote = '01M5DQAYZ3WP7H0NXZZV9M2315';

String _echoesPath(String noteId) =>
    '/vaults/seed/api/v1/notes/$noteId/echoes?limit=8';

const _noRoute = 'not found: no route for this path';

class _Env {
  _Env(this.container, this.clock, this.server);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;

  HostedEchoesAccess get access =>
      HostedEchoesAccess(client: server.connect(container), vaultName: 'seed');

  HostedConnectionStatus? get status =>
      container.read(hostedConnectionStatusProvider(fakeServerId));
}

_Env _env(List<String> domains) {
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
  return _Env(container, clock, server);
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// An `http.Client` that holds every response until the test answers it and
/// counts abort triggers that fire.
class _Held425 extends http.BaseClient {
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

HostedClient _clientOver(_Env env, http.Client httpClient) {
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
  group('answers', () {
    test(
      'hosted 200 fixture maps to EchoesReady with every echo field',
      () async {
        final env = _env(['notes']);

        final result = await env.access.echoes(_okNote);

        final expected = EchoesReady(
          [
            Echo(
              noteId: '01M5DQAYZ5RH88SRZGPY15XXVM'.toString(),
              noteTitle: 'Broken Frontmatter',
              passage:
                  'Its frontmatter is not JSON, so every reader treats it as role-less.',
              startByte: int.parse('0'),
              noteUpdatedAt: int.parse('1760000540000'),
            ),
            Echo(
              noteId: '01M5DQAYZ592W2515HPSDF5Q16'.toString(),
              noteTitle: '2026-10-15',
              noteRole: 'daily',
              day: '2026-10-15',
              passage: 'Read about loot tables.',
              startByte: int.parse('0'),
              noteUpdatedAt: int.parse('1760000480000'),
            ),
          ],
          emptyNote: false,
          pending: 0,
        );
        expect(result, expected);
      },
    );

    test('hosted sends one GET to the echoes route with limit 8', () async {
      final env = _env(['notes']);

      await env.access.echoes(_okNote);

      expect(env.server.requests, hasLength(1));
      final r = env.server.requests.single;
      expect(r.method, 'GET');
      expect(r.url.path, '/vaults/seed/api/v1/notes/$_okNote/echoes');
      expect(r.url.queryParameters, {'limit': '8'});
    });

    test(
      'hosted allowDownload is ignored and sends the same request',
      () async {
        final env = _env(['notes']);

        final result = await env.access.echoes(_okNote, allowDownload: true);

        expect(result, isA<EchoesReady>());
        expect(env.server.requests, hasLength(1));
        expect(env.server.requests.single.url.queryParameters, {'limit': '8'});
        expect(env.server.requests.single.url.path, contains('/echoes'));
      },
    );

    test(
      'hosted reason empty_note maps to emptyNote true and pending is read',
      () async {
        final env = _env([]);
        env.server.route(
          'GET',
          _echoesPath('n-empty'),
          json: {'echoes': <Object?>[], 'pending': 5, 'reason': 'empty_note'},
        );

        final result = await env.access.echoes('n-empty');

        expect(result, isA<EchoesReady>());
        result as EchoesReady;
        expect(result.emptyNote, isTrue);
        expect(result.echoes, isEmpty);
        expect(result.pending, 5);
      },
    );

    test(
      'hosted null reason and any other reason map to emptyNote false',
      () async {
        for (final reason in <String?>[null, 'something_else']) {
          final env = _env([]);
          env.server.route(
            'GET',
            _echoesPath('n-r'),
            json: {'echoes': <Object?>[], 'pending': 2, 'reason': reason},
          );

          final result = await env.access.echoes('n-r') as EchoesReady;

          expect(result.emptyNote, isFalse, reason: '$reason');
          expect(result.pending, 2, reason: '$reason');
        }
      },
    );

    test(
      'hosted 200 body that is not a valid echoes answer throws MemexException',
      () async {
        final bodies = <Object?>[
          <String, Object?>{'pending': 0, 'reason': null},
          <String, Object?>{'echoes': 'nope', 'pending': 0, 'reason': null},
          <String, Object?>{
            'echoes': [
              {'note_id': 'n1'},
            ],
            'pending': 0,
            'reason': null,
          },
          <String, Object?>{'echoes': <Object?>[], 'pending': '0'},
        ];
        for (final body in bodies) {
          final env = _env([]);
          env.server.route('GET', _echoesPath('n-bad'), json: body);

          final e = await _outcome(env.access.echoes('n-bad'));

          expect(e, isA<MemexException>(), reason: '$body');
          expect((e! as MemexException).code, isNull, reason: '$body');
        }
      },
    );
  });

  group('unavailable', () {
    test('hosted 409 embeddings_off maps to EmbeddingsOff', () async {
      final env = _env(['notes']);

      final result = await env.access.echoes(_offNote);

      expect(result, const EchoesUnavailable(EmbeddingsOff()));
    });

    test(
      'hosted 503 embedder_unavailable maps to EmbedderUnavailable with the C1 message',
      () async {
        final env = _env([]);
        env.server.route(
          'GET',
          _echoesPath('n-503'),
          status: 503,
          json: {
            'error': {
              'code': 'embedder_unavailable',
              'message': 'the embedder could not run: out of memory',
            },
          },
        );

        final result = await env.access.echoes('n-503');

        expect(
          result,
          const EchoesUnavailable(
            EmbedderUnavailable('the embedder could not run: out of memory'),
          ),
        );
      },
    );

    test(
      'hosted compat 404 not_found with the exact no-route message maps to Outdated',
      () async {
        final env = _env(['compat']);

        final result = await env.access.echoes(_offNote);

        expect(result, const EchoesUnavailable(Outdated()));
      },
    );
  });

  group('errors', () {
    test('hosted note 404 not_found fixture throws MemexException', () async {
      final env = _env(['notes']);

      final e = await _outcome(env.access.echoes(_missingNote));

      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'not_found');
      expect(e.message, 'echoes failed: not found: note <id:1>');
    });

    test(
      'hosted not_found with a near-miss message throws not Outdated',
      () async {
        const nearMisses = [
          'no route for this path',
          'not found: no route for this path.',
          'Not found: no route for this path',
          'not found: no route for this path ',
          'not found: note n-nm',
          '',
        ];
        for (final message in nearMisses) {
          final env = _env([]);
          env.server.route(
            'GET',
            _echoesPath('n-nm'),
            status: 404,
            json: {
              'error': {'code': 'not_found', 'message': message},
            },
          );

          final e = await _outcome(env.access.echoes('n-nm'));

          expect(e, isA<MemexException>(), reason: '"$message"');
          expect(
            (e! as MemexException).code,
            'not_found',
            reason: '"$message"',
          );
        }
      },
    );

    test(
      'hosted exact no-route message under another code throws not Outdated',
      () async {
        final env = _env([]);
        env.server.route(
          'GET',
          _echoesPath('n-oc'),
          status: 404,
          json: {
            'error': {'code': 'vault_not_found', 'message': _noRoute},
          },
        );

        final e = await _outcome(env.access.echoes('n-oc'));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'vault_not_found');
      },
    );

    test('hosted unmapped errors rethrow with their code', () async {
      const cases = <(int, String)>[
        (500, 'internal'),
        (400, 'invalid_argument'),
        (409, 'version_conflict'),
        (503, 'unavailable'),
      ];
      for (final (status, code) in cases) {
        final env = _env([]);
        env.server.route(
          'GET',
          _echoesPath('n-un'),
          status: status,
          json: {
            'error': {'code': code, 'message': 'm-$code'},
          },
        );

        final result = await _outcome(env.access.echoes('n-un'));

        expect(result, isA<MemexException>(), reason: '$status $code');
        expect((result! as MemexException).code, code);
      }
    });

    test(
      'hosted 401 throws MemexException unauthorized and records token rejected',
      () async {
        final env = _env(['notes']);
        // Connect first: connect() reads the server's current token.
        final access = env.access;
        env.server.token = 'a-different-token';

        final e = await _outcome(access.echoes(_okNote));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'unauthorized');
        expect(env.status, HostedConnectionStatus.tokenRejected);
      },
    );

    test(
      'hosted refused connection propagates VaultUnreachableException unchanged',
      () async {
        final env = _env(['notes']);
        env.server.failure = FakeServerFailure.refused;

        final e = await _outcome(env.access.echoes(_okNote));

        expect(e, isA<VaultUnreachableException>());
        expect((e! as VaultUnreachableException).mayHaveCommitted, isFalse);
        expect(env.status, HostedConnectionStatus.unreachable);
      },
    );

    test(
      'hosted vault_not_found through the composite reports the vault gone',
      () async {
        final env = _env(['notes']);
        env.server.removeVault('seed');
        var gone = 0;
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
          onVaultGone: () => gone++,
        );

        final e = await _outcome(access.echoes.echoes(_okNote));

        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'vault_not_found');
        expect(gone, 1);
      },
    );
  });

  group('timeout', () {
    test(
      'hosted echoes waits 60 s then maps the timeout to EmbedderUnavailable timed out',
      () async {
        final env = _env([]);
        final held = _Held425();
        final access = HostedEchoesAccess(
          client: _clientOver(env, held),
          vaultName: 'seed',
        );
        final outcomes = <Object?>[];
        unawaited(_outcome(access.echoes(_okNote)).then(outcomes.add));
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
        expect(outcomes, [
          const EchoesUnavailable(EmbedderUnavailable('timed out')),
        ]);
        expect(held.aborts, 1, reason: 'the request is aborted');
        expect(
          env.status,
          isNot(HostedConnectionStatus.unreachable),
          reason: 'a slow echoes run is not an outage',
        );
        expect(env.clock.pendingTimers, 0);
      },
    );

    test('hosted echoes through the composite also waits 60 s', () async {
      final env = _env([]);
      final held = _Held425();
      final access = HostedVaultAccess(
        client: _clientOver(env, held),
        vaultName: 'seed',
      );
      final outcomes = <Object?>[];
      unawaited(_outcome(access.echoes.echoes(_okNote)).then(outcomes.add));
      await pumpEventQueue();

      env.clock.advance(const Duration(seconds: 59));
      await pumpEventQueue();
      expect(outcomes, isEmpty);

      env.clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(outcomes, [
        const EchoesUnavailable(EmbedderUnavailable('timed out')),
      ]);
      expect(env.status, isNot(HostedConnectionStatus.unreachable));
    });

    test(
      'hosted echoes answered before 60 s returns the result and cancels the timer',
      () async {
        final env = _env([]);
        final held = _Held425();
        final access = HostedEchoesAccess(
          client: _clientOver(env, held),
          vaultName: 'seed',
        );
        final outcomes = <Object?>[];
        unawaited(_outcome(access.echoes(_okNote)).then(outcomes.add));
        await pumpEventQueue();

        env.clock.advance(const Duration(seconds: 30));
        await pumpEventQueue();
        expect(held.requests, hasLength(1));
        expect(outcomes, isEmpty, reason: 'the 10 s default does not apply');
        held.respond(0, 200, {
          'echoes': <Object?>[],
          'pending': 1,
          'reason': null,
        });
        await pumpEventQueue();

        expect(outcomes, [const EchoesReady([], emptyNote: false, pending: 1)]);
        expect(env.clock.pendingTimers, 0);
        expect(env.status, HostedConnectionStatus.connected);
        expect(held.aborts, 0);
      },
    );

    test('hosted another hosted request keeps the 10 s timeout', () async {
      final env = _env([]);
      final held = _Held425();
      final client = _clientOver(env, held);
      final outcomes = <Object?>[];
      unawaited(
        _outcome(
          client.vaultRequest('GET', 'seed', '/notes/n1', operation: 'read'),
        ).then(outcomes.add),
      );
      await pumpEventQueue();

      env.clock.advance(const Duration(seconds: 10));
      await pumpEventQueue();

      expect(outcomes.single, isA<VaultUnreachableException>());
      expect(env.status, HostedConnectionStatus.unreachable);
    });
  });
}
