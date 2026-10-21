// WI #77 (H0): the seam test of `test/support/fake_vault_server.dart`, the
// fake vault server #81–#85, #94 and #96–#102 test against. It serves the
// rows of any `api_v1/<domain>/index.json` and simulates refused, host
// lookup, unreachable network, timed-out, dropped, 401, `vault_not_found`,
// non-memex and held responses.
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
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

/// Every `api_v1/<domain>` folder that has an `index.json`.
List<String> _wi77Domains() => [
  for (final dir in Directory(apiV1FixturesDir).listSync())
    if (dir is Directory && File(p.join(dir.path, 'index.json')).existsSync())
      p.basename(dir.path),
]..sort();

Future<http.Response> _send(
  FakeVaultServer server,
  String method,
  String path, {
  Map<String, String> headers = const {},
  List<int>? body,
  String? token,
}) async {
  final request = http.Request(method, Uri.parse('$fakeServerUrl$path'))
    ..headers['authorization'] = 'Bearer ${token ?? server.token}'
    ..headers.addAll(headers);
  if (body != null) request.bodyBytes = body;
  return http.Response.fromStream(await server.client.send(request));
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

Object? _json(http.Response r) => jsonDecode(r.body);

void main() {
  group('raw fake', () {
    test(
      'the fake vault server replays every row of every api_v1 domain',
      () async {
        final domains = _wi77Domains();
        expect(domains, containsAll(['compat', 'errors', 'server']));
        for (final domain in domains) {
          final server = FakeVaultServer()..serveDomain(domain);
          for (final row in loadFixtureRows(p.join(apiV1FixturesDir, domain))) {
            final headers = {
              for (final e in row.headers.entries)
                if (e.key.toLowerCase() != 'content-length') e.key: e.value,
            };
            final response = await _send(
              server,
              row.method,
              row.path,
              headers: headers,
              body: row.readRequestBytes(),
            );
            expect(response.statusCode, row.status, reason: '$domain $row');
            expect(_json(response), row.readResponseJson(), reason: '$row');
          }
        }
      },
    );

    test('the fake vault server records every request it receives', () async {
      final server = FakeVaultServer()..serveDomain('server');
      await _send(server, 'GET', '/api/v1/info');
      server.failure = FakeServerFailure.refused;
      await _outcome(_send(server, 'GET', '/api/v1/vaults'));
      expect(
        [for (final r in server.requests) r.url.path],
        ['/api/v1/info', '/api/v1/vaults'],
      );
    });

    test(
      'the fake vault server answers a wrong or missing token with 401',
      () async {
        final server = FakeVaultServer()..serveDomain('server');
        final wrong = await _send(server, 'GET', '/api/v1/info', token: 'nope');
        expect(wrong.statusCode, 401);
        expect(
          _json(wrong),
          loadFixtureRows(
            '$apiV1FixturesDir/errors',
          ).firstWhere((r) => r.status == 401).readResponseJson(),
        );
        final missing = http.Request(
          'GET',
          Uri.parse('$fakeServerUrl/api/v1/info'),
        );
        final r = await http.Response.fromStream(
          await server.client.send(missing),
        );
        expect(r.statusCode, 401);
      },
    );

    test(
      'the fake vault server answers a removed or unknown vault with vault_not_found',
      () async {
        final server = FakeVaultServer()..serveDomain('server');
        expect(
          (await _send(server, 'GET', '/vaults/seed/api/v1/info')).statusCode,
          200,
        );
        server.removeVault('seed');
        final gone = await _send(server, 'GET', '/vaults/seed/api/v1/info');
        expect(gone.statusCode, 404);
        expect((_json(gone)! as Map)['error'], {
          'code': 'vault_not_found',
          'message': 'no vault named seed',
        });
        final unknown = await _send(server, 'GET', '/vaults/other/api/v1/info');
        expect(unknown.statusCode, 404);
        expect(
          ((_json(unknown)! as Map)['error'] as Map)['code'],
          'vault_not_found',
        );
        final noRoute = await _send(server, 'GET', '/api/v1/nope');
        expect(noRoute.statusCode, 404);
        expect(((_json(noRoute)! as Map)['error'] as Map)['code'], 'not_found');
      },
    );

    test(
      'the fake vault server can pretend to be a non-memex server',
      () async {
        final server = FakeVaultServer()..serveDomain('server');
        server.servesHtml = true;
        final r = await _send(server, 'GET', '/api/v1/info', token: 'any');
        expect(r.statusCode, 200);
        expect(r.headers['content-type'], 'text/html');
        expect(r.body, fakeHtmlBody);
      },
    );

    test(
      'the fake vault server simulates transport failures like IOClient',
      () async {
        final server = FakeVaultServer()..serveDomain('server');
        for (final (failure, errno) in [
          (FakeServerFailure.refused, 61),
          (FakeServerFailure.hostLookup, 8),
          (FakeServerFailure.networkUnreachable, 51),
        ]) {
          server.failure = failure;
          final e = await _outcome(_send(server, 'GET', '/api/v1/info'));
          expect(e, isA<http.ClientException>(), reason: '$failure');
          expect(e, isA<SocketException>(), reason: '$failure');
          expect((e! as SocketException).osError?.errorCode, errno);
        }
        server.failure = FakeServerFailure.drop;
        final dropped = await _outcome(_send(server, 'GET', '/api/v1/info'));
        expect(dropped, isA<http.ClientException>());
        expect(dropped, isNot(isA<SocketException>()));

        server.failure = FakeServerFailure.timeout;
        var done = false;
        unawaited(
          _outcome(
            _send(server, 'GET', '/api/v1/info'),
          ).whenComplete(() => done = true),
        );
        await pumpEventQueue();
        expect(done, isFalse, reason: 'a timed-out request never answers');
      },
    );

    test('the fake vault server holds responses until released', () async {
      final server = FakeVaultServer()..serveDomain('server');
      server.hold();
      http.Response? response;
      unawaited(_send(server, 'GET', '/api/v1/info').then((r) => response = r));
      await pumpEventQueue();
      expect(response, isNull);
      expect(server.requests, hasLength(1));
      server.release();
      await pumpEventQueue();
      expect(response?.statusCode, 200);
    });

    test(
      'the fake vault server picks rows by their headers and serves custom routes first',
      () async {
        final dir = '$apiV1FixturesDir/server';
        final server = FakeVaultServer()
          ..serveRows([
            FixtureRow(
              domainDir: dir,
              method: 'GET',
              path: '/vaults/seed/api/v1/today',
              request: null,
              response: 'info.json',
              status: 200,
              headers: {'X-Memex-UTC-Offset': '-00:30'},
              dartOnly: true,
            ),
            FixtureRow(
              domainDir: dir,
              method: 'GET',
              path: '/vaults/seed/api/v1/today',
              request: null,
              response: 'vault_info.json',
              status: 200,
              headers: {'X-Memex-UTC-Offset': '+14:00'},
              dartOnly: true,
            ),
          ]);
        final west = await _send(
          server,
          'GET',
          '/vaults/seed/api/v1/today',
          headers: {'X-Memex-UTC-Offset': '-00:30'},
        );
        expect((_json(west)! as Map)['api_version'], 1);
        final east = await _send(
          server,
          'GET',
          '/vaults/seed/api/v1/today',
          headers: {'X-Memex-UTC-Offset': '+14:00'},
        );
        expect((_json(east)! as Map)['name'], 'seed');

        server.route('GET', '/vaults/seed/api/v1/today', status: 418, json: {});
        final custom = await _send(server, 'GET', '/vaults/seed/api/v1/today');
        expect(custom.statusCode, 418);
      },
    );
  });

  group('through HostedClient', () {
    test(
      'HostedClient over the fake vault server reads rows and maps every simulated failure',
      () async {
        final clock = FakeClock();
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final server = FakeVaultServer()..serveDomain('server');
        final client = server.connect(container);
        HostedConnectionStatus? status() =>
            container.read(hostedConnectionStatusProvider(fakeServerId));

        expect((await client.probeServer()).kind, ServerProbeKind.connected);
        final info = await client.vaultRequest(
          'GET',
          'seed',
          '/info',
          operation: 'info',
        );
        expect(info['name'], 'seed');
        expect(status(), HostedConnectionStatus.connected);

        for (final (failure, committed) in [
          (FakeServerFailure.refused, false),
          (FakeServerFailure.hostLookup, false),
          (FakeServerFailure.networkUnreachable, false),
          (FakeServerFailure.drop, true),
        ]) {
          server.failure = failure;
          final e = await _outcome(
            client.serverRequest('GET', '/vaults', operation: 'l'),
          );
          expect(e, isA<VaultUnreachableException>(), reason: '$failure');
          expect((e! as VaultUnreachableException).mayHaveCommitted, committed);
          expect(status(), HostedConnectionStatus.unreachable);
        }

        server.failure = FakeServerFailure.timeout;
        final pending = _outcome(
          client.serverRequest('GET', '/vaults', operation: 'l'),
        );
        await pumpEventQueue();
        clock.advance(const Duration(seconds: 10));
        final timedOut = await pending;
        expect(
          (timedOut! as VaultUnreachableException).mayHaveCommitted,
          isTrue,
        );
        server.failure = null;

        server.token = 'rotated';
        final rejected = await _outcome(
          client.serverRequest('GET', '/vaults', operation: 'l'),
        );
        expect((rejected! as MemexException).code, 'unauthorized');
        expect(status(), HostedConnectionStatus.tokenRejected);
        server.token = fakeServerToken;

        server.removeVault('seed');
        final gone = await _outcome(
          client.vaultRequest('GET', 'seed', '/info', operation: 'info'),
        );
        expect((gone! as MemexException).code, 'vault_not_found');
        expect(status(), HostedConnectionStatus.connected);

        server.servesHtml = true;
        expect((await client.probeServer()).kind, ServerProbeKind.notMemex);
        expect(status(), HostedConnectionStatus.incompatible);
      },
    );
  });
}
