// WI #94 (R4) D9: the hosted vault revision, Dart half.
//
// `HostedRevision(client, vaultName).revision()` reads
// `GET /vaults/<vaultName>/api/v1/revision` through #77's `HostedClient`
// (its `Authorization` and `X-Memex-UTC-Offset` headers, its 10 s timeout,
// its one C1 parser) and returns the server's `revision` string unchanged.
// It is `VaultAccess.revision()` for a hosted vault; #96 composes it.
//
// API under test:
//   HostedRevision(HostedClient client, String vaultName)
//     .vaultName
//     .revision() -> Future<String>
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/revision.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

const _wi94Token = 'tok-wi94-revision-5c1e';

class _Wi94Env {
  _Wi94Env(this.container, this.clock, this.server);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;
  Duration offset = const Duration(hours: -3, minutes: -30);

  HostedClient client({String? accessToken}) =>
      server.connect(container, accessToken: accessToken);

  HostedRevision revision([String vaultName = seedVaultName]) =>
      HostedRevision(client(), vaultName);

  HostedConnectionStatus? status() =>
      container.read(hostedConnectionStatusProvider(fakeServerId));
}

/// A fake server that serves the `revision` and `errors` rows, with a
/// [FakeClock] and a settable UTC offset.
_Wi94Env _env() {
  final clock = FakeClock();
  final server = FakeVaultServer(token: _wi94Token)
    ..serveDomain('revision')
    ..serveDomain('errors');
  late final _Wi94Env env;
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => env.offset),
    ],
  );
  addTearDown(container.dispose);
  env = _Wi94Env(container, clock, server);
  return env;
}

/// The `revision/` row for `GET /vaults/seed/api/v1/revision` 200.
FixtureRow _seedRevisionRow() =>
    loadFixtureRows('$apiV1FixturesDir/revision').singleWhere(
      (r) =>
          r.method == 'GET' &&
          r.path == '/vaults/$seedVaultName/api/v1/revision' &&
          r.status == 200,
    );

String _fixtureRevision() =>
    (_seedRevisionRow().readResponseJson()!
            as Map<String, Object?>)['revision']!
        as String;

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  group('the hosted revision read', () {
    test(
      'revision sends GET to the vault revision route and returns the fixture string',
      () async {
        final env = _env();
        final expected = _fixtureRevision();
        expect(expected, isNotEmpty);

        final revision = await env.revision().revision();

        expect(revision, expected);
        final request = env.server.requests.single;
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          '$fakeServerUrl/vaults/$seedVaultName/api/v1/revision',
        );
        expect(request.headers['authorization'], 'Bearer $_wi94Token');
        expect(request.headers['x-memex-utc-offset'], '-03:30');
        expect(request.bodyBytes, isEmpty, reason: 'a GET carries no body');
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );

    test('revision reads the route of its own vault name', () async {
      final env = _env();
      env.server.route(
        'GET',
        '/vaults/Work_2/api/v1/revision',
        json: {'revision': '01JZZZZZZZZZZZZZZZZZZZZZZZ-7-3'},
      );
      final hosted = env.revision('Work_2');
      expect(hosted.vaultName, 'Work_2');

      expect(await hosted.revision(), '01JZZZZZZZZZZZZZZZZZZZZZZZ-7-3');
      expect(
        env.server.requests.single.url.path,
        '/vaults/Work_2/api/v1/revision',
      );
    });

    test(
      'revision returns each server answer as it is with no caching',
      () async {
        final env = _env();
        final hosted = env.revision();
        final values = <String>[];
        for (final value in ['a-1-1', 'a-2-1', 'a-2-1', 'b-0-0']) {
          env.server.route(
            'GET',
            '/vaults/seed/api/v1/revision',
            json: {'revision': value},
          );
          values.add(await hosted.revision());
        }
        expect(values, ['a-1-1', 'a-2-1', 'a-2-1', 'b-0-0']);
        expect(env.server.requests, hasLength(4), reason: 'one GET per call');
      },
    );

    test(
      'an extra unknown field in the revision response is ignored',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '/vaults/seed/api/v1/revision',
          json: {
            'revision': '01JAAAAAAAAAAAAAAAAAAAAAAA-0-2',
            'computed_at': 1760000000000,
            'future': {'nested': true},
          },
        );
        expect(
          await env.revision().revision(),
          '01JAAAAAAAAAAAAAAAAAAAAAAA-0-2',
        );
      },
    );

    test('each read takes the UTC offset of its own moment', () async {
      final env = _env();
      final hosted = env.revision();
      await hosted.revision();
      env.offset = const Duration(hours: 1);
      await hosted.revision();
      expect(
        [for (final r in env.server.requests) r.headers['x-memex-utc-offset']],
        ['-03:30', '+01:00'],
      );
    });
  });

  group('revision errors come from HostedClient unchanged', () {
    test('a 401 surfaces as code unauthorized and token rejected', () async {
      final env = _env();
      final hosted = env.revision();
      env.server.token = 'rotated-on-the-server';
      final e = await _outcome(hosted.revision());
      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'unauthorized');
      expect(
        e.message,
        'revision failed: missing or wrong access token; '
        'send Authorization: Bearer <token>',
      );
      expect(env.status(), HostedConnectionStatus.tokenRejected);
    });

    test(
      'vault_not_found surfaces as vault gone with the server message',
      () async {
        final env = _env();
        env.server.removeVault(seedVaultName);
        final e = await _outcome(env.revision().revision());
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'vault_not_found');
        expect(e.message, 'revision failed: no vault named seed');
        expect(env.status(), HostedConnectionStatus.connected);
      },
    );

    test(
      'the revision fixture row for an unknown vault surfaces vault_not_found',
      () async {
        final env = _env();
        final e = await _outcome(env.revision('nope').revision());
        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'vault_not_found');
        expect(
          env.server.requests.single.url.path,
          '/vaults/nope/api/v1/revision',
        );
      },
    );

    test('an unknown C1 code passes through with its fields', () async {
      final env = _env();
      env.server.route(
        'GET',
        '/vaults/seed/api/v1/revision',
        status: 503,
        json: {
          'error': {
            'code': 'some_future_code',
            'message': 'try later',
            'retry_after_ms': 250,
          },
        },
      );
      final e = await _outcome(env.revision().revision());
      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'some_future_code');
      expect(e.message, 'revision failed: try later');
      expect(e.fields, {'retry_after_ms': 250});
      expect(e.kind, MemexErrorKind.other);
    });

    for (final (name, failure) in [
      (
        'a refused connection surfaces as VaultUnreachableException',
        FakeServerFailure.refused,
      ),
      (
        'a failed host lookup surfaces as VaultUnreachableException',
        FakeServerFailure.hostLookup,
      ),
    ]) {
      test(name, () async {
        final env = _env();
        env.server.failure = failure;
        final e = await _outcome(env.revision().revision());
        expect(e, isA<VaultUnreachableException>());
        e as VaultUnreachableException;
        expect(e.serverName, fakeServerName);
        expect(e.mayHaveCommitted, isFalse);
        expect(env.status(), HostedConnectionStatus.unreachable);
      });
    }

    test(
      'a 200 revision body that is not a JSON object is the HostedClient error',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '/vaults/seed/api/v1/revision',
          json: ['01JAAAAAAAAAAAAAAAAAAAAAAA-0-2'],
        );
        final e = await _outcome(env.revision().revision());
        expect(e, isA<MemexException>());
        expect(
          (e! as MemexException).message,
          'revision failed: the server response is not a JSON object',
        );
        expect(env.server.requests, hasLength(1), reason: 'no retry');
      },
    );

    // A 200 object without a string `revision` is not a C1 error, so
    // HostedClient returns it and the cast in HostedRevision throws a
    // TypeError. Neither the WI nor D17 asks HostedRevision to map it (it
    // adds no parsing of its own), and the poller (#79) treats any other
    // error as unreachable. Pinned as-is: a change to a MemexException is a
    // deliberate TEST-CHANGE.
    for (final (name, json) in [
      (
        'a 200 revision body without a revision field throws and returns nothing',
        <String, Object?>{'revisions': 'a-1-1'},
      ),
      (
        'a 200 revision body with a null revision throws and returns nothing',
        <String, Object?>{'revision': null},
      ),
      (
        'a 200 revision body with a number revision throws and returns nothing',
        <String, Object?>{'revision': 7},
      ),
    ]) {
      test(name, () async {
        final env = _env();
        env.server.route('GET', '/vaults/seed/api/v1/revision', json: json);
        final e = await _outcome(env.revision().revision());
        expect(e, isA<TypeError>());
        expect(env.server.requests, hasLength(1), reason: 'no retry');
        expect(
          env.status(),
          HostedConnectionStatus.connected,
          reason: 'the server answered',
        );
      });
    }

    test('a revision read with no answer is unreachable at 10 s', () async {
      final env = _env();
      env.server.failure = FakeServerFailure.timeout;
      Object? outcome;
      var done = false;
      unawaited(
        _outcome(env.revision().revision()).then((v) {
          outcome = v;
          done = true;
        }),
      );
      await pumpEventQueue();
      expect(env.server.requests, hasLength(1), reason: 'the GET was sent');

      env.clock.advance(const Duration(seconds: 9));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'no outcome at 9 s');

      env.clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(done, isTrue, reason: 'an outcome at 10 s');
      expect(outcome, isA<VaultUnreachableException>());
      expect(
        (outcome! as VaultUnreachableException).serverName,
        fakeServerName,
      );
      expect(env.status(), HostedConnectionStatus.unreachable);
    });
  });
}
