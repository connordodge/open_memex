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
        env.server.token = 'rotated-on-the-server';
        final e = await _outcome(
          env.client().serverRequest('GET', '/vaults', operation: 'vault list'),
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
