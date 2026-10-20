// WI #77 (H0) D17: `HostedClient.probeServer()`, the app's only
// `api_version` check (req 14, req 21, req 43, L9). It never throws, and it
// writes the server's status like any request, except that notMemex and
// apiMismatch write `incompatible`.
//
// API under test:
//   const kApiVersion = 1;
//   enum ServerProbeKind { connected, unreachable, unauthorized, notMemex,
//       apiMismatch }
//   class ServerProbe { ServerProbeKind kind; String? serverVersion; }
//   Future<ServerProbe> HostedClient.probeServer()
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

class _Wi77Probe {
  _Wi77Probe(this.container, this.clock, this.server);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;

  HostedClient client() => server.connect(container);

  HostedConnectionStatus? get status =>
      container.read(hostedConnectionStatusProvider(fakeServerId));
}

_Wi77Probe _probeEnv({String domain = 'server'}) {
  final clock = FakeClock();
  final server = FakeVaultServer()..serveDomain(domain);
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
    ],
  );
  addTearDown(container.dispose);
  return _Wi77Probe(container, clock, server);
}

void main() {
  test('kApiVersion is 1', () {
    expect(kApiVersion, 1);
  });

  test('a valid info body with api_version 1 probes connected', () async {
    final env = _probeEnv();
    final probe = await env.client().probeServer();
    expect(probe.kind, ServerProbeKind.connected);
    expect(probe.serverVersion, '0.1.0');
    expect(env.status, HostedConnectionStatus.connected);
    final request = env.server.requests.single;
    expect(request.method, 'GET');
    expect(request.url.toString(), '$fakeServerUrl/api/v1/info');
    expect(request.headers['authorization'], 'Bearer $fakeServerToken');
    expect(request.headers['x-memex-utc-offset'], '+02:00');
  });

  test('an info body with an unknown field still probes connected', () async {
    final env = _probeEnv(domain: 'compat');
    final probe = await env.client().probeServer();
    expect(probe.kind, ServerProbeKind.connected);
    expect(probe.serverVersion, '0.0.0');
    expect(env.status, HostedConnectionStatus.connected);
  });

  test('a 401 probes unauthorized and sets token rejected', () async {
    final env = _probeEnv();
    // The client keeps the old token; the server rotates it afterwards.
    final client = env.client();
    env.server.token = 'rotated-on-the-server';
    final probe = await client.probeServer();
    expect(probe.kind, ServerProbeKind.unauthorized);
    expect(probe.serverVersion, isNull);
    expect(env.status, HostedConnectionStatus.tokenRejected);
  });

  for (final (name, failure) in [
    ('a refused probe returns unreachable', FakeServerFailure.refused),
    (
      'a probe whose host lookup fails returns unreachable',
      FakeServerFailure.hostLookup,
    ),
    (
      'a probe over an unreachable network returns unreachable',
      FakeServerFailure.networkUnreachable,
    ),
    ('a dropped probe returns unreachable', FakeServerFailure.drop),
  ]) {
    test(name, () async {
      final env = _probeEnv();
      env.server.failure = failure;
      final probe = await env.client().probeServer();
      expect(probe.kind, ServerProbeKind.unreachable);
      expect(env.status, HostedConnectionStatus.unreachable);
    });
  }

  test('a probe with no answer within 10 s returns unreachable', () async {
    final env = _probeEnv();
    env.server.failure = FakeServerFailure.timeout;
    ServerProbe? probe;
    unawaited(env.client().probeServer().then((p) => probe = p));
    await pumpEventQueue();
    env.clock.advance(const Duration(seconds: 9));
    await pumpEventQueue();
    expect(probe, isNull, reason: 'still checking at 9 s');
    expect(env.status, isNull);
    env.clock.advance(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(probe?.kind, ServerProbeKind.unreachable);
    expect(env.status, HostedConnectionStatus.unreachable);
  });

  test('an HTML server probes notMemex and sets incompatible', () async {
    final env = _probeEnv();
    env.server.servesHtml = true;
    final probe = await env.client().probeServer();
    expect(probe.kind, ServerProbeKind.notMemex);
    expect(probe.serverVersion, isNull);
    expect(env.status, HostedConnectionStatus.incompatible);
  });

  for (final (name, status, body) in [
    ('a non-JSON info body probes notMemex', 200, 'hello'),
    ('a JSON array info body probes notMemex', 200, '[1]'),
    ('an empty info body probes notMemex', 200, ''),
    (
      'an info body without api_version probes notMemex',
      200,
      '{"server_version":"0.1.0"}',
    ),
    (
      'an info body with a string api_version probes notMemex',
      200,
      '{"server_version":"0.1.0","api_version":"1"}',
    ),
    (
      'an info body with a fractional api_version probes notMemex',
      200,
      '{"server_version":"0.1.0","api_version":1.5}',
    ),
    (
      'an info body without server_version probes notMemex',
      200,
      '{"api_version":1}',
    ),
    (
      'an info body with a numeric server_version probes notMemex',
      200,
      '{"server_version":1,"api_version":1}',
    ),
    (
      'a 404 info probes notMemex',
      404,
      '{"error":{"code":"not_found","message":"not found: no route for this path"}}',
    ),
    (
      'a 500 info probes notMemex',
      500,
      '{"error":{"code":"internal","message":"boom"}}',
    ),
  ]) {
    test(name, () async {
      final env = _probeEnv();
      env.server.route('GET', '/api/v1/info', status: status, body: body);
      final probe = await env.client().probeServer();
      expect(probe.kind, ServerProbeKind.notMemex, reason: body);
      expect(probe.serverVersion, isNull);
      expect(
        env.status,
        HostedConnectionStatus.incompatible,
        reason: 'notMemex is never connected',
      );
    });
  }

  test(
    'api_version 2 probes apiMismatch carrying the server version',
    () async {
      final env = _probeEnv();
      env.server.route(
        'GET',
        '/api/v1/info',
        json: {'server_version': '0.4.2', 'api_version': 2, 'extra': true},
      );
      final probe = await env.client().probeServer();
      expect(probe.kind, ServerProbeKind.apiMismatch);
      expect(probe.serverVersion, '0.4.2');
      expect(
        env.status,
        HostedConnectionStatus.incompatible,
        reason: 'apiMismatch is never connected',
      );
    },
  );

  test('api_version 0 probes apiMismatch', () async {
    final env = _probeEnv();
    env.server.route(
      'GET',
      '/api/v1/info',
      json: {'server_version': '0.0.1', 'api_version': 0},
    );
    final probe = await env.client().probeServer();
    expect(probe.kind, ServerProbeKind.apiMismatch);
    expect(probe.serverVersion, '0.0.1');
  });

  test(
    'a connected probe after an incompatible one sets connected again',
    () async {
      final env = _probeEnv();
      final client = env.client();
      env.server.servesHtml = true;
      await client.probeServer();
      expect(env.status, HostedConnectionStatus.incompatible);
      env.server.servesHtml = false;
      final probe = await client.probeServer();
      expect(probe.kind, ServerProbeKind.connected);
      expect(env.status, HostedConnectionStatus.connected);
    },
  );
}
