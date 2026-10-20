// WI #77 (H0) D17: the hosted client core. One C1 parser
// (`MemexException.fromC1`), the request helpers' headers and URLs, the
// 10 s timeout through `clockProvider`, error mapping to `MemexException` /
// `VaultUnreachableException`, and the per-server status written by the
// client's response hook to `hostedConnectionStatusProvider`.
//
// API under test:
//   MemexException.fromC1(String operation, Map<String, Object?> error)
//   HostedClient(Ref, {serverId, serverName, serverUrl, accessToken,
//       httpClient})
//     .serverRequest(method, path, {required operation, query, body})
//     .vaultRequest(method, vaultName, path, {required operation, query,
//       body})
//   hostedConnectionStatusProvider(serverId) -> HostedConnectionStatus?
//   utcOffsetProvider -> Duration Function()
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

/// A sentinel access token: it must never show up anywhere but the header.
const _wi77Token = 'tok-SENTINEL-77-9f3a2c';

/// A version_conflict C1 object as the CLI and the server emit it.
const _wi77VersionConflict = {
  'code': 'version_conflict',
  'message': 'version conflict: expected 3, current 4',
  'expected': 3,
  'current': 4,
};

/// A code this app doesn't know yet, with rule fields.
const _wi77UnknownCode = {
  'code': 'some_future_code',
  'message': 'a rule this app has never heard of',
  'limit': 9,
  'detail': {'a': 1},
};

class _Wi77Env {
  _Wi77Env(this.container, this.clock, this.server);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;
  Duration offset = const Duration(hours: 2);

  HostedClient client({
    String serverId = fakeServerId,
    String serverName = fakeServerName,
    String? serverUrl,
  }) => server.connect(
    container,
    serverId: serverId,
    serverName: serverName,
    serverUrl: serverUrl,
  );

  HostedConnectionStatus? status([String serverId = fakeServerId]) =>
      container.read(hostedConnectionStatusProvider(serverId));
}

/// A container over a fake server that serves the `server` and `errors`
/// rows, with a [FakeClock] and a settable UTC offset.
_Wi77Env _env({String url = fakeServerUrl, FakeVaultServer? server}) {
  final clock = FakeClock();
  final fake =
      server ??
      (FakeVaultServer(token: _wi77Token, url: url)
        ..serveDomain('server')
        ..serveDomain('errors'));
  late final _Wi77Env env;
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => env.offset),
    ],
  );
  addTearDown(container.dispose);
  env = _Wi77Env(container, clock, fake);
  return env;
}

Map<String, Object?> _c1Of(FixtureRow row) =>
    (row.readResponseJson()! as Map<String, Object?>)['error']!
        as Map<String, Object?>;

List<FixtureRow> _errorRows() => loadFixtureRows('$apiV1FixturesDir/errors');

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  group('MemexException.fromC1', () {
    test(
      'fromC1 maps every errors fixture to its code, message and fields',
      () {
        final rows = _errorRows();
        expect(rows, isNotEmpty);
        for (final row in rows) {
          final c1 = _c1Of(row);
          final e = MemexException.fromC1('vault create', c1);
          expect(e.code, c1['code'], reason: '$row');
          expect(e.message, 'vault create failed: ${c1['message']}');
          expect(e.toString(), e.message);
          expect(e.fields, isEmpty, reason: '$row has only code and message');
          expect(e.kind, MemexErrorKind.other, reason: '$row');
        }
      },
    );

    test(
      'fromC1 keeps rule fields and sets versionConflict only for version_conflict',
      () {
        final conflict = MemexException.fromC1('update', {
          ..._wi77VersionConflict,
        });
        expect(conflict.code, 'version_conflict');
        expect(conflict.kind, MemexErrorKind.versionConflict);
        expect(
          conflict.message,
          'update failed: version conflict: expected 3, current 4',
        );
        expect(conflict.fields, {'expected': 3, 'current': 4});
        expect(conflict.fields.containsKey('code'), isFalse);
        expect(conflict.fields.containsKey('message'), isFalse);

        final unknown = MemexException.fromC1('add', {..._wi77UnknownCode});
        expect(unknown.code, 'some_future_code');
        expect(unknown.kind, MemexErrorKind.other);
        expect(
          unknown.message,
          'add failed: a rule this app has never heard of',
        );
        expect(unknown.fields, {
          'limit': 9,
          'detail': {'a': 1},
        });
      },
    );

    test('fromC1 falls back to the code when the message is not a string', () {
      final e = MemexException.fromC1('rm', {
        'code': 'not_found',
        'message': 7,
      });
      expect(e.code, 'not_found');
      expect(e.message, 'rm failed: not_found');
      expect(e.fields, isEmpty);
      final noMessage = MemexException.fromC1('rm', {'code': 'internal'});
      expect(noMessage.message, 'rm failed: internal');
    });

    test(
      'fromCliFailure gives the same exception as fromC1 for every C1 line',
      () {
        final objects = [
          for (final row in _errorRows()) _c1Of(row),
          _wi77VersionConflict,
          _wi77UnknownCode,
        ];
        for (final c1 in objects) {
          final viaCli = MemexException.fromCliFailure(
            'get',
            MemexResult(
              exitCode: 1,
              stdout: '',
              stderr: 'log line\n${jsonEncode({'error': c1})}\n',
            ),
          );
          final viaC1 = MemexException.fromC1('get', {...c1});
          expect(viaC1.code, viaCli.code);
          expect(viaC1.message, viaCli.message);
          expect(viaC1.kind, viaCli.kind);
          expect(viaC1.fields, viaCli.fields);
        }
      },
    );
  });

  group('headers and URLs', () {
    test(
      'every request carries the bearer token and the UTC offset header',
      () async {
        final env = _env();
        final client = env.client();
        await client.serverRequest('GET', '/vaults', operation: 'vault list');
        await client.vaultRequest('GET', 'seed', '/info', operation: 'info');
        await client.probeServer();

        final requests = env.server.requests;
        expect(requests, hasLength(3));
        for (final r in requests) {
          expect(
            r.headers['authorization'],
            'Bearer $_wi77Token',
            reason: '$r',
          );
          expect(r.headers['x-memex-utc-offset'], '+02:00', reason: '$r');
          expect(r.url.toString(), isNot(contains(_wi77Token)));
        }
      },
    );

    for (final (name, url) in [
      (
        'request URLs join a saved URL that has no trailing slash',
        'http://nas.local:7878',
      ),
      (
        'request URLs join a saved URL that ends in a slash',
        'http://nas.local:7878/',
      ),
    ]) {
      test(name, () async {
        final env = _env(url: url);
        final client = env.client(serverUrl: url);
        await client.serverRequest('GET', '/vaults', operation: 'vault list');
        await client.vaultRequest('GET', 'seed', '/info', operation: 'info');
        await client.probeServer();
        expect(
          [for (final r in env.server.requests) r.url.toString()],
          [
            'http://nas.local:7878/api/v1/vaults',
            'http://nas.local:7878/vaults/seed/api/v1/info',
            'http://nas.local:7878/api/v1/info',
          ],
        );
      });
    }

    test('a query goes into the URL and a body is sent as JSON', () async {
      final env = _env();
      env.server.route(
        'GET',
        '/vaults/seed/api/v1/notes?limit=200',
        json: {'notes': <Object?>[]},
      );
      final client = env.client();

      final listed = await client.vaultRequest(
        'GET',
        'seed',
        '/notes',
        operation: 'list',
        query: {'limit': '200'},
      );
      expect(listed, {'notes': <Object?>[]});
      expect(
        env.server.requests.single.url.toString(),
        'http://nas.local:7878/vaults/seed/api/v1/notes?limit=200',
      );

      final created = await client.serverRequest(
        'POST',
        '/vaults',
        operation: 'vault create',
        body: {'name': 'fixture-new'},
      );
      expect(created, {'name': 'fixture-new', 'vault_id': '<id:1>'});
      final post = env.server.requests.last;
      expect(post.method, 'POST');
      expect(jsonDecode(post.body), {'name': 'fixture-new'});
      expect(post.headers['content-type'], startsWith('application/json'));
    });

    test(
      'the offset header is read per request so a DST switch changes it',
      () async {
        final env = _env();
        final client = env.client();
        env.offset = const Duration(hours: 1);
        await client.serverRequest('GET', '/vaults', operation: 'vault list');
        env.offset = const Duration(hours: 2);
        await client.serverRequest('GET', '/vaults', operation: 'vault list');
        env.offset = const Duration(minutes: -30);
        await client.probeServer();
        expect(
          [
            for (final r in env.server.requests)
              r.headers['x-memex-utc-offset'],
          ],
          ['+01:00', '+02:00', '-00:30'],
        );
      },
    );
  });

  group('responses', () {
    test(
      'a 2xx JSON object is returned and unknown fields are ignored',
      () async {
        final env = _env(
          server: FakeVaultServer(token: _wi77Token)..serveDomain('compat'),
        );
        final info = await env.client().serverRequest(
          'GET',
          '/info',
          operation: 'info',
        );
        expect(info['api_version'], 1);
        expect(info['server_version'], '0.0.0');
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );

    test(
      'every fixture row is returned decoded through the request helpers',
      () async {
        final env = _env(
          server: FakeVaultServer(token: _wi77Token)..serveDomain('server'),
        );
        final client = env.client();
        for (final row in loadFixtureRows('$apiV1FixturesDir/server')) {
          final segments = Uri.parse(row.path).pathSegments;
          final requestBody = row.readRequestBytes();
          final body = requestBody == null
              ? null
              : jsonDecode(utf8.decode(requestBody));
          final Map<String, Object?> got;
          if (segments.first == 'vaults') {
            got = await client.vaultRequest(
              row.method,
              segments[1],
              '/${segments.skip(4).join('/')}',
              operation: 'row',
              body: body,
            );
          } else {
            got = await client.serverRequest(
              row.method,
              '/${segments.skip(2).join('/')}',
              operation: 'row',
              body: body,
            );
          }
          expect(got, row.readResponseJson(), reason: '$row');
        }
      },
    );

    test(
      'a non-2xx C1 body throws MemexException with its code and fields',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '/vaults/seed/api/v1/notes/n1',
          status: 409,
          json: {'error': _wi77VersionConflict},
        );
        final client = env.client();

        final exists = await _outcome(
          client.serverRequest(
            'POST',
            '/vaults',
            operation: 'vault create',
            body: {'name': 'SEED'},
          ),
        );
        expect(exists, isA<MemexException>());
        exists as MemexException;
        expect(exists.code, 'vault_exists');
        expect(
          exists.message,
          'vault create failed: a vault named SEED already exists',
        );
        expect(exists.fields, isEmpty);

        final conflict = await _outcome(
          client.vaultRequest(
            'POST',
            'seed',
            '/notes/n1',
            operation: 'update',
            body: {'content_md': 'x', 'expected_version': 3},
          ),
        );
        expect(conflict, isA<MemexException>());
        conflict as MemexException;
        expect(conflict.code, 'version_conflict');
        expect(conflict.kind, MemexErrorKind.versionConflict);
        expect(conflict.fields, {'expected': 3, 'current': 4});
        expect(
          conflict.message,
          'update failed: version conflict: expected 3, current 4',
        );
      },
    );

    test(
      'an unknown C1 code throws a plain MemexException with that code',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '/api/v1/vaults',
          status: 422,
          json: {'error': _wi77UnknownCode},
        );
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'some_future_code');
        expect(e.kind, MemexErrorKind.other);
        expect(e.fields, {
          'limit': 9,
          'detail': {'a': 1},
        });
      },
    );

    for (final (name, status, body, contentType) in [
      (
        'a non-2xx HTML body throws a null-code MemexException naming the status',
        502,
        '<html><body>bad gateway</body></html>',
        'text/html',
      ),
      (
        'a non-2xx JSON body without a C1 error throws a null-code MemexException naming the status',
        500,
        '{"detail":"boom"}',
        'application/json',
      ),
      (
        'a non-2xx empty body throws a null-code MemexException naming the status',
        503,
        '',
        'text/plain',
      ),
      (
        'a non-2xx body whose error has no string code throws a null-code MemexException naming the status',
        400,
        '{"error":{"code":12,"message":"x"}}',
        'application/json',
      ),
    ]) {
      test(name, () async {
        final env = _env();
        env.server.route(
          'GET',
          '/api/v1/vaults',
          status: status,
          body: body,
          contentType: contentType,
        );
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, isNull);
        expect(e.kind, MemexErrorKind.other);
        expect(e.message, startsWith('vault list failed: '));
        expect(e.message, contains('$status'));
        expect(env.status(), HostedConnectionStatus.connected);
      });
    }

    for (final (name, body) in [
      ('a 2xx HTML body throws a null-code MemexException', '<html></html>'),
      ('a 2xx JSON array throws a null-code MemexException', '[1, 2]'),
      ('a 2xx JSON string throws a null-code MemexException', '"ok"'),
      ('a 2xx empty body throws a null-code MemexException', ''),
    ]) {
      test(name, () async {
        final env = _env();
        env.server.route('GET', '/api/v1/vaults', body: body);
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, isNull);
        expect(e.message, startsWith('vault list failed: '));
        expect(env.status(), HostedConnectionStatus.connected);
      });
    }
  });

  group('401 and vault_not_found', () {
    test(
      'a 401 throws code unauthorized and sets the status to token rejected',
      () async {
        final env = _env();
        // The client keeps the old token; the server rotates it afterwards.
        final client = env.client();
        env.server.token = 'rotated-on-the-server';
        final e = await _outcome(
          client.serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'unauthorized');
        expect(
          e.message,
          'vault list failed: missing or wrong access token; '
          'send Authorization: Bearer <token>',
        );
        expect(env.status(), HostedConnectionStatus.tokenRejected);
      },
    );

    test('a 401 without a C1 body still throws code unauthorized', () async {
      final env = _env();
      env.server.route(
        'GET',
        '/vaults/seed/api/v1/info',
        status: 401,
        body: 'Unauthorized',
        contentType: 'text/plain',
      );
      final e = await _outcome(
        env.client().vaultRequest('GET', 'seed', '/info', operation: 'info'),
      );
      expect(e, isA<MemexException>());
      expect((e! as MemexException).code, 'unauthorized');
      expect(env.status(), HostedConnectionStatus.tokenRejected);
    });

    test(
      'vault_not_found throws with that code and the server stays connected',
      () async {
        final env = _env();
        env.server.removeVault('seed');
        final e = await _outcome(
          env.client().vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'vault_not_found');
        expect(e.message, 'info failed: no vault named seed');
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );
  });

  group('unreachable', () {
    for (final (name, failure) in [
      (
        'a refused connection throws unreachable without a commit',
        FakeServerFailure.refused,
      ),
      (
        'a failed host lookup throws unreachable without a commit',
        FakeServerFailure.hostLookup,
      ),
      (
        'an unreachable network throws unreachable without a commit',
        FakeServerFailure.networkUnreachable,
      ),
    ]) {
      test(name, () async {
        final env = _env();
        env.server.failure = failure;
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(e, isA<VaultUnreachableException>());
        e as VaultUnreachableException;
        expect(e.mayHaveCommitted, isFalse);
        expect(e.serverName, fakeServerName);
        expect(env.status(), HostedConnectionStatus.unreachable);
      });
    }

    test('a host with no route throws unreachable without a commit', () async {
      final env = _env();
      final client = _wi77ClientOver(
        env,
        MockClient((request) async {
          throw FakeClientSocketException(
            const SocketException(
              'No route to host',
              osError: OSError('No route to host', 65),
            ),
            request.url,
          );
        }),
      );
      final e = await _outcome(
        client.serverRequest('GET', '/vaults', operation: 'vault list'),
      );
      expect(e, isA<VaultUnreachableException>());
      expect((e! as VaultUnreachableException).mayHaveCommitted, isFalse);
      expect(env.status(), HostedConnectionStatus.unreachable);
    });

    test(
      'a request with no outcome at 9 s times out at 10 s with a possible commit',
      () async {
        final env = _env();
        env.server.failure = FakeServerFailure.timeout;
        Object? outcome;
        var done = false;
        unawaited(
          _outcome(
            env.client().vaultRequest(
              'POST',
              'seed',
              '/notes',
              operation: 'add',
              body: {'content_md': 'x'},
            ),
          ).then((v) {
            outcome = v;
            done = true;
          }),
        );
        await pumpEventQueue();
        expect(
          env.server.requests,
          hasLength(1),
          reason: 'the request was sent',
        );

        env.clock.advance(const Duration(seconds: 9));
        await pumpEventQueue();
        expect(done, isFalse, reason: 'no outcome at 9 s');
        expect(env.status(), isNull, reason: 'no status before an outcome');

        env.clock.advance(const Duration(seconds: 1));
        await pumpEventQueue();
        expect(done, isTrue, reason: 'an outcome at 10 s');
        expect(outcome, isA<VaultUnreachableException>());
        final timedOut = outcome! as VaultUnreachableException;
        expect(timedOut.mayHaveCommitted, isTrue);
        expect(timedOut.serverName, fakeServerName);
        expect(env.status(), HostedConnectionStatus.unreachable);
      },
    );

    test(
      'a connection dropped after sending throws unreachable with a possible commit',
      () async {
        final env = _env();
        env.server.failure = FakeServerFailure.drop;
        final e = await _outcome(
          env.client().vaultRequest(
            'POST',
            'seed',
            '/notes',
            operation: 'add',
            body: {'content_md': 'x'},
          ),
        );
        expect(e, isA<VaultUnreachableException>());
        expect((e! as VaultUnreachableException).mayHaveCommitted, isTrue);
        expect(env.status(), HostedConnectionStatus.unreachable);
      },
    );

    test(
      'a connection reset after sending throws unreachable with a possible commit',
      () async {
        final env = _env();
        final client = _wi77ClientOver(
          env,
          MockClient((request) async {
            throw FakeClientSocketException(
              const SocketException(
                'Connection reset by peer',
                osError: OSError('Connection reset by peer', 54),
              ),
              request.url,
            );
          }),
        );
        final e = await _outcome(
          client.vaultRequest('POST', 'seed', '/notes', operation: 'add'),
        );
        expect(e, isA<VaultUnreachableException>());
        expect((e! as VaultUnreachableException).mayHaveCommitted, isTrue);
        expect(env.status(), HostedConnectionStatus.unreachable);
      },
    );

    test(
      'a connection dropped while the body arrives throws unreachable with a possible commit',
      () async {
        final env = _env();
        final client = _wi77ClientOver(
          env,
          MockClient.streaming((request, _) async {
            final body = StreamController<List<int>>();
            body.add(utf8.encode('{"name":'));
            body.addError(
              http.ClientException(
                'Connection closed while receiving data',
                request.url,
              ),
            );
            unawaited(body.close());
            return http.StreamedResponse(body.stream, 200, request: request);
          }),
        );
        final e = await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect(e, isA<VaultUnreachableException>());
        expect((e! as VaultUnreachableException).mayHaveCommitted, isTrue);
        expect(env.status(), HostedConnectionStatus.unreachable);
      },
    );

    test(
      'a response before 10 s cancels the timeout so the status stays connected',
      () async {
        final env = _env();
        final client = env.client();
        await client.serverRequest('GET', '/vaults', operation: 'vault list');
        expect(env.status(), HostedConnectionStatus.connected);
        expect(env.clock.pendingTimers, 0, reason: 'the timeout was cancelled');
        env.clock.advance(const Duration(seconds: 30));
        await pumpEventQueue();
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );

    test(
      'a held response that arrives at 9 s is returned and not timed out',
      () async {
        final env = _env();
        env.server.hold();
        Object? outcome;
        unawaited(
          _outcome(
            env.client().serverRequest('GET', '/vaults', operation: 'l'),
          ).then((v) => outcome = v),
        );
        await pumpEventQueue();
        env.clock.advance(const Duration(seconds: 9));
        env.server.release();
        await pumpEventQueue();
        expect(outcome, isA<Map<String, Object?>>());
        env.clock.advance(const Duration(seconds: 5));
        await pumpEventQueue();
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );
  });

  group('status', () {
    test('the status of a server is null before any request', () {
      final env = _env();
      expect(env.status(), isNull);
      expect(env.status('another-server'), isNull);
    });

    test(
      'after unreachable or token rejected the next non-401 response sets connected',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '/vaults/seed/api/v1/notes/n1',
          status: 409,
          json: {'error': _wi77VersionConflict},
        );
        final client = env.client();

        env.server.failure = FakeServerFailure.refused;
        await _outcome(client.serverRequest('GET', '/vaults', operation: 'l'));
        expect(env.status(), HostedConnectionStatus.unreachable);

        env.server.failure = null;
        await client.serverRequest('GET', '/vaults', operation: 'l');
        expect(env.status(), HostedConnectionStatus.connected, reason: '2xx');

        env.server.token = 'rotated';
        await _outcome(client.serverRequest('GET', '/vaults', operation: 'l'));
        expect(env.status(), HostedConnectionStatus.tokenRejected);

        env.server.token = _wi77Token;
        final conflict = await _outcome(
          client.vaultRequest('POST', 'seed', '/notes/n1', operation: 'update'),
        );
        expect((conflict! as MemexException).code, 'version_conflict');
        expect(
          env.status(),
          HostedConnectionStatus.connected,
          reason: 'a C1 error is a response',
        );

        env.server.failure = FakeServerFailure.timeout;
        final pending = _outcome(
          client.serverRequest('GET', '/vaults', operation: 'l'),
        );
        await pumpEventQueue();
        env.clock.advance(const Duration(seconds: 10));
        await pending;
        expect(env.status(), HostedConnectionStatus.unreachable);

        env.server.failure = null;
        env.server.removeVault('seed');
        await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'i'),
        );
        expect(
          env.status(),
          HostedConnectionStatus.connected,
          reason: 'vault_not_found is a response',
        );
      },
    );

    test(
      'two clients for different saved servers keep separate statuses',
      () async {
        final env = _env();
        final nas = env.client(serverId: 'srv-nas', serverName: 'nas');
        final mini = _wi77ClientOver(
          env,
          MockClient((request) async {
            throw fakeTransportException(
              FakeServerFailure.refused,
              request.url,
            )!;
          }),
          serverId: 'srv-mini',
          serverName: 'mini',
        );

        await nas.serverRequest('GET', '/vaults', operation: 'l');
        final e = await _outcome(
          mini.serverRequest('GET', '/vaults', operation: 'l'),
        );
        expect((e! as VaultUnreachableException).serverName, 'mini');
        expect(env.status('srv-nas'), HostedConnectionStatus.connected);
        expect(env.status('srv-mini'), HostedConnectionStatus.unreachable);

        env.server.token = 'rotated';
        await _outcome(nas.serverRequest('GET', '/vaults', operation: 'l'));
        expect(env.status('srv-nas'), HostedConnectionStatus.tokenRejected);
        expect(env.status('srv-mini'), HostedConnectionStatus.unreachable);
      },
    );
  });

  group('the access token', () {
    test(
      'the access token never appears in an exception, a status, a URL or a log',
      () async {
        final env = _env();
        final client = env.client();
        final failures = <Object>[];
        final statuses = <HostedConnectionStatus?>[];
        final logs = <String>[];

        Future<void> attempt(Future<Object?> Function() run) async {
          final outcome = await _outcome(run());
          if (outcome is Exception || outcome is Error) failures.add(outcome!);
          statuses.add(env.status());
        }

        Future<void> everyCall() async {
          await attempt(
            () => client.serverRequest('GET', '/vaults', operation: 'l'),
          );
          await attempt(
            () => client.vaultRequest(
              'POST',
              'seed',
              '/notes',
              operation: 'add',
              body: {'content_md': 'x'},
            ),
          );
          await attempt(client.probeServer);
        }

        final previousDebugPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) => logs.add('$message');
        addTearDown(() => debugPrint = previousDebugPrint);

        await runZoned(
          () async {
            for (final failure in [
              FakeServerFailure.refused,
              FakeServerFailure.hostLookup,
              FakeServerFailure.networkUnreachable,
              FakeServerFailure.drop,
            ]) {
              env.server.failure = failure;
              await everyCall();
            }

            env.server.failure = FakeServerFailure.timeout;
            final pending = everyCall();
            for (var i = 0; i < 3; i++) {
              await pumpEventQueue();
              env.clock.advance(const Duration(seconds: 10));
            }
            await pending;
            env.server.failure = null;

            env.server.token = 'rotated';
            await everyCall();
            env.server.token = _wi77Token;

            // A misbehaving proxy that echoes the request headers back.
            env.server.route(
              'GET',
              '/api/v1/vaults',
              status: 502,
              body: '<pre>Authorization: Bearer $_wi77Token</pre>',
              contentType: 'text/html',
            );
            await attempt(
              () => client.serverRequest('GET', '/vaults', operation: 'l'),
            );

            env.server.removeVault('seed');
            await everyCall();

            env.server.servesHtml = true;
            await everyCall();
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );

        expect(failures, isNotEmpty);
        for (final f in failures) {
          expect(f.toString(), isNot(contains(_wi77Token)), reason: '$f');
          if (f is MemexException) {
            expect(f.message, isNot(contains(_wi77Token)));
            expect(jsonEncode(f.fields), isNot(contains(_wi77Token)));
          }
        }
        for (final s in statuses) {
          expect('$s', isNot(contains(_wi77Token)));
        }
        for (final r in env.server.requests) {
          expect(r.url.toString(), isNot(contains(_wi77Token)));
        }
        for (final line in logs) {
          expect(line, isNot(contains(_wi77Token)));
        }
      },
    );
  });

  group('pinned contracts', () {
    for (final (name, url, base) in [
      (
        'request URLs keep the path prefix of a saved URL',
        'http://nas.local:7878/memex',
        'http://nas.local:7878/memex',
      ),
      (
        'request URLs keep the path prefix of a saved URL that ends in a slash',
        'http://nas.local:7878/memex/',
        'http://nas.local:7878/memex',
      ),
      (
        'request URLs drop every trailing slash of a saved URL',
        'http://nas.local:7878/memex///',
        'http://nas.local:7878/memex',
      ),
      (
        'request URLs drop every trailing slash of a saved URL without a prefix',
        'http://nas.local:7878//',
        'http://nas.local:7878',
      ),
    ]) {
      test(name, () async {
        final env = _env(
          server: FakeVaultServer(token: _wi77Token, url: base)
            ..serveDomain('server')
            ..serveDomain('errors'),
        );
        final client = env.client(serverUrl: url);
        final vaults = await client.serverRequest(
          'GET',
          '/vaults',
          operation: 'vault list',
        );
        expect(vaults['vaults'], isA<List<Object?>>());
        await client.vaultRequest('GET', 'seed', '/info', operation: 'info');
        await client.probeServer();
        expect(
          [for (final r in env.server.requests) r.url.toString()],
          [
            '$base/api/v1/vaults',
            '$base/vaults/seed/api/v1/info',
            '$base/api/v1/info',
          ],
        );
        expect(env.status(), HostedConnectionStatus.connected);
      });
    }

    test('an empty query map adds no question mark to the URL', () async {
      final env = _env();
      final client = env.client();
      await client.serverRequest(
        'GET',
        '/vaults',
        operation: 'vault list',
        query: {},
      );
      await client.vaultRequest(
        'GET',
        'seed',
        '/info',
        operation: 'info',
        query: {},
      );
      expect(
        [for (final r in env.server.requests) r.url.toString()],
        [
          'http://nas.local:7878/api/v1/vaults',
          'http://nas.local:7878/vaults/seed/api/v1/info',
        ],
      );
      for (final r in env.server.requests) {
        expect(r.url.hasQuery, isFalse, reason: '${r.url}');
      }
    });

    test('query values are percent-encoded in the URL', () async {
      final env = _env();
      await _outcome(
        env.client().vaultRequest(
          'GET',
          'seed',
          '/search',
          operation: 'search',
          query: {'q': 'a b&c=d', 'limit': '5'},
        ),
      );
      final url = env.server.requests.single.url;
      expect(url.path, '/vaults/seed/api/v1/search');
      expect(url.queryParameters, {'q': 'a b&c=d', 'limit': '5'});
      expect(url.query, isNot(contains(' ')));
    });

    test('the vault name is percent-encoded as one path segment', () async {
      final env = _env();
      const name = 'my vault/x?y#z';
      await _outcome(
        env.client().vaultRequest('GET', name, '/info', operation: 'info'),
      );
      final url = env.server.requests.single.url;
      expect(
        url.toString(),
        'http://nas.local:7878/vaults/my%20vault%2Fx%3Fy%23z/api/v1/info',
      );
      expect(url.pathSegments, ['vaults', name, 'api', 'v1', 'info']);
      expect(url.hasQuery, isFalse);
      expect(url.hasFragment, isFalse);
    });

    test('a 2xx body is decoded as UTF-8 whatever its content type', () async {
      final env = _env();
      for (final headers in [
        <String, String>{},
        {'content-type': 'text/plain'},
        {'content-type': 'application/json'},
      ]) {
        final client = _wi77ClientOver(
          env,
          MockClient(
            (request) async => http.Response.bytes(
              utf8.encode('{"title":"café ☕ naïve"}'),
              200,
              request: request,
              headers: headers,
            ),
          ),
        );
        final got = await client.vaultRequest(
          'GET',
          'seed',
          '/info',
          operation: 'info',
        );
        expect(got, {'title': 'café ☕ naïve'}, reason: '$headers');
      }
    });

    test(
      'a 2xx body that is not UTF-8 throws a null-code MemexException',
      () async {
        final env = _env();
        // Valid JSON in Latin-1 but not in UTF-8 (0xE9 is a lone byte).
        final latin1Json = latin1.encode('{"title":"café"}');
        final client = _wi77ClientOver(
          env,
          MockClient(
            (request) async =>
                http.Response.bytes(latin1Json, 200, request: request),
          ),
        );
        final e = await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, isNull);
        expect(e.message, startsWith('info failed: '));
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );

    test(
      'a non-2xx C1 body that is not UTF-8 throws a null-code MemexException naming the status',
      () async {
        final env = _env();
        final latin1C1 = latin1.encode(
          '{"error":{"code":"invalid_argument","message":"café"}}',
        );
        final client = _wi77ClientOver(
          env,
          MockClient(
            (request) async =>
                http.Response.bytes(latin1C1, 400, request: request),
          ),
        );
        final e = await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, isNull);
        expect(e.message, 'info failed: HTTP 400');
      },
    );

    test(
      'a 401 with a C1 body of another code still throws code unauthorized',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '/api/v1/vaults',
          status: 401,
          json: {
            'error': {
              'code': 'token_expired',
              'message': 'the access token expired',
              'expired_at': '2026-10-01',
            },
          },
        );
        env.server.route(
          'GET',
          '/vaults/seed/api/v1/info',
          status: 401,
          json: {
            'error': {'code': 'not_found'},
          },
        );
        final client = env.client();

        final expired = await _outcome(
          client.serverRequest('GET', '/vaults', operation: 'vault list'),
        );
        expect(expired, isA<MemexException>());
        expired as MemexException;
        expect(expired.code, 'unauthorized');
        expect(expired.kind, MemexErrorKind.other);
        expect(expired.message, 'vault list failed: the access token expired');
        expect(expired.fields, {'expired_at': '2026-10-01'});
        expect(env.status(), HostedConnectionStatus.tokenRejected);

        final noMessage = await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect(noMessage, isA<MemexException>());
        noMessage as MemexException;
        expect(noMessage.code, 'unauthorized');
        expect(noMessage.message, 'info failed: unauthorized');
        expect(noMessage.fields, isEmpty);
      },
    );

    test(
      'a 401 with a version_conflict body is not a version conflict',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '/api/v1/vaults',
          status: 401,
          json: {'error': _wi77VersionConflict},
        );
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'l'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'unauthorized');
        expect(e.kind, MemexErrorKind.other);
        expect(env.status(), HostedConnectionStatus.tokenRejected);
      },
    );

    test('a timeout aborts the request it gave up on', () async {
      final env = _env();
      final held = _Wi77HeldClient(failOnAbort: true);
      final client = _wi77ClientOver(env, held);
      final outcomes = <Object?>[];
      unawaited(
        _outcome(
          client.vaultRequest('POST', 'seed', '/notes', operation: 'add'),
        ).then(outcomes.add),
      );
      await pumpEventQueue();
      expect(held.requests, hasLength(1));
      expect(held.requests.single, isA<http.Abortable>());

      env.clock.advance(const Duration(seconds: 9));
      await pumpEventQueue();
      expect(held.aborts, 0, reason: 'no abort before 10 s');

      env.clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(held.aborts, 1, reason: 'aborted at 10 s');
      expect(outcomes, hasLength(1), reason: 'one outcome only');
      expect(outcomes.single, isA<VaultUnreachableException>());
      expect(
        (outcomes.single! as VaultUnreachableException).mayHaveCommitted,
        isTrue,
      );
      expect(env.status(), HostedConnectionStatus.unreachable);
    });

    test('a response that arrives after the timeout is ignored', () async {
      final env = _env();
      final held = _Wi77HeldClient();
      final client = _wi77ClientOver(env, held);
      final outcomes = <Object?>[];
      unawaited(
        _outcome(
          client.serverRequest('GET', '/vaults', operation: 'l'),
        ).then(outcomes.add),
      );
      await pumpEventQueue();
      env.clock.advance(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(outcomes.single, isA<VaultUnreachableException>());
      expect(env.status(), HostedConnectionStatus.unreachable);

      // A late 401 would set token rejected if it were read.
      held.respond(0, 401, '{"error":{"code":"unauthorized"}}');
      await pumpEventQueue();
      expect(outcomes, hasLength(1), reason: 'no second outcome');
      expect(env.status(), HostedConnectionStatus.unreachable);

      final second = _outcome(
        client.serverRequest('GET', '/vaults', operation: 'l'),
      );
      await pumpEventQueue();
      held.respond(1, 200, '{"vaults":[]}');
      expect(await second, {'vaults': <Object?>[]});
      expect(env.status(), HostedConnectionStatus.connected);
      expect(env.clock.pendingTimers, 0);
    });

    test('a failure that arrives after the timeout is ignored', () async {
      final env = _env();
      final held = _Wi77HeldClient();
      final client = _wi77ClientOver(env, held);
      final outcomes = <Object?>[];
      unawaited(
        _outcome(
          client.serverRequest('GET', '/vaults', operation: 'l'),
        ).then(outcomes.add),
      );
      await pumpEventQueue();
      env.clock.advance(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(outcomes.single, isA<VaultUnreachableException>());

      // The next request succeeds before the first one's late failure.
      final second = _outcome(
        client.serverRequest('GET', '/vaults', operation: 'l'),
      );
      await pumpEventQueue();
      held.respond(1, 200, '{"vaults":[]}');
      await second;
      expect(env.status(), HostedConnectionStatus.connected);

      held.fail(
        0,
        http.ClientException('Connection reset by peer', held.requests[0].url),
      );
      await pumpEventQueue();
      expect(outcomes, hasLength(1), reason: 'no second outcome');
      expect(
        env.status(),
        HostedConnectionStatus.connected,
        reason: 'a late failure never overwrites a newer status',
      );
    });

    test('a transport failure before 10 s cancels the timeout', () async {
      final env = _env();
      env.server.failure = FakeServerFailure.refused;
      await _outcome(
        env.client().serverRequest('GET', '/vaults', operation: 'l'),
      );
      expect(env.status(), HostedConnectionStatus.unreachable);
      expect(env.clock.pendingTimers, 0, reason: 'the timeout was cancelled');
    });

    test('a failed body read cancels the timeout', () async {
      final env = _env();
      final client = _wi77ClientOver(
        env,
        MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream<List<int>>.error(
              http.ClientException('Connection closed', request.url),
            ),
            200,
            request: request,
          ),
        ),
      );
      await _outcome(
        client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
      );
      expect(env.status(), HostedConnectionStatus.unreachable);
      expect(env.clock.pendingTimers, 0);
    });

    test('with no overrides the status of a saved server is null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(hostedConnectionStatusProvider('srv-a')), isNull);
      expect(container.read(hostedConnectionStatusProvider('srv-b')), isNull);
    });
  });
}

/// An `http.Client` that holds every response until the test answers it,
/// and records when a request's abort trigger fires. With [failOnAbort] it
/// fails an aborted request the way `IOClient` does.
class _Wi77HeldClient extends http.BaseClient {
  _Wi77HeldClient({this.failOnAbort = false});

  final bool failOnAbort;
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
          if (failOnAbort && !pending.isCompleted) {
            pending.completeError(http.RequestAbortedException(request.url));
          }
        }),
      );
    }
    return pending.future;
  }

  /// Answers request [i] with [status] and [body].
  void respond(int i, int status, String body) => _pending[i].complete(
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: requests[i],
      headers: {'content-type': 'application/json'},
    ),
  );

  /// Fails request [i] with [error].
  void fail(int i, Object error) => _pending[i].completeError(error);
}

/// Builds a [HostedClient] in [env]'s container over another `http.Client`
/// (failures the fake server doesn't model).
HostedClient _wi77ClientOver(
  _Wi77Env env,
  http.Client httpClient, {
  String serverId = fakeServerId,
  String serverName = fakeServerName,
}) {
  final provider = Provider<HostedClient>(
    (ref) => HostedClient(
      ref,
      serverId: serverId,
      serverName: serverName,
      serverUrl: fakeServerUrl,
      accessToken: _wi77Token,
      httpClient: httpClient,
    ),
  );
  return env.container.read(provider);
}
