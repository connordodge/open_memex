// #425 (391-A1, ruling D22): the optional per-request `timeout` of
// `HostedClient.vaultRequest`. Without it a request keeps the 10 s default
// (records `unreachable`, throws VaultUnreachableException). With it, the
// request is aborted when that timeout fires and HostedRequestTimeout is
// thrown; `unreachable` is NOT recorded (a slow echoes run is no outage).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

class _Held425 extends http.BaseClient {
  _Held425({this.failOnAbort = false});

  /// Fails an aborted request the way `IOClient` does.
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

  void respond(int i, int status, Object json) => _pending[i].complete(
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(json))),
      status,
      request: requests[i],
      headers: {'content-type': 'application/json'},
    ),
  );
}

class _Env {
  _Env(this.container, this.clock, this.held, this.client);

  final ProviderContainer container;
  final FakeClock clock;
  final _Held425 held;
  final HostedClient client;

  HostedConnectionStatus? get status =>
      container.read(hostedConnectionStatusProvider(fakeServerId));

  /// Starts a vault request and collects its one outcome in [outcomes].
  List<Object?> start({Duration? timeout, bool passTimeout = true}) {
    final outcomes = <Object?>[];
    final Future<Object?> f = passTimeout
        ? client.vaultRequest(
            'GET',
            'seed',
            '/notes/n1/echoes',
            operation: 'echoes',
            timeout: timeout,
          )
        : client.vaultRequest(
            'GET',
            'seed',
            '/notes/n1/echoes',
            operation: 'echoes',
          );
    unawaited(
      f.then<void>(outcomes.add, onError: (Object e) => outcomes.add(e)),
    );
    return outcomes;
  }
}

_Env _env({http.Client? over, bool failOnAbort = false}) {
  final clock = FakeClock();
  final held = _Held425(failOnAbort: failOnAbort);
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final provider = Provider<HostedClient>(
    (ref) => HostedClient(
      ref,
      serverId: fakeServerId,
      serverName: fakeServerName,
      serverUrl: fakeServerUrl,
      accessToken: fakeServerToken,
      httpClient: over ?? held,
    ),
  );
  return _Env(container, clock, held, container.read(provider));
}

Future<void> _advance(_Env env, Duration by) async {
  env.clock.advance(by);
  await pumpEventQueue();
}

void main() {
  group('a caller timeout', () {
    test(
      'a request with a 60 s timeout is aborted at 60 s and throws HostedRequestTimeout',
      () async {
        final env = _env();
        final outcomes = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();

        await _advance(env, const Duration(seconds: 10));
        expect(outcomes, isEmpty, reason: 'the 10 s default does not apply');
        await _advance(env, const Duration(seconds: 49));
        expect(outcomes, isEmpty);
        expect(env.held.aborts, 0);

        await _advance(env, const Duration(seconds: 1));
        expect(outcomes, hasLength(1), reason: 'one outcome only');
        expect(outcomes, hasLength(1));
        expect(outcomes.single, isA<HostedRequestTimeout>());
        expect(outcomes.single, isNot(isA<VaultUnreachableException>()));
        expect(env.held.aborts, 1);
        expect(env.clock.pendingTimers, 0);
      },
    );

    test('a caller timeout does not record unreachable', () async {
      final env = _env();
      final outcomes = env.start(timeout: const Duration(seconds: 60));
      await pumpEventQueue();

      await _advance(env, const Duration(seconds: 60));

      expect(outcomes, hasLength(1));
      expect(outcomes.single, isA<HostedRequestTimeout>());
      expect(env.status, isNull, reason: 'no outcome was recorded');
    });

    test(
      'a caller timeout does not overwrite an earlier connected status',
      () async {
        final env = _env();
        final first = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();
        env.held.respond(0, 200, {'ok': true});
        await pumpEventQueue();
        expect(first.single, {'ok': true});
        expect(env.status, HostedConnectionStatus.connected);

        final second = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();
        await _advance(env, const Duration(seconds: 60));

        expect(second, hasLength(1));
        expect(second.single, isA<HostedRequestTimeout>());
        expect(env.status, HostedConnectionStatus.connected);
      },
    );

    test('a caller timeout shorter than 10 s fires at that timeout', () async {
      final env = _env();
      final outcomes = env.start(timeout: const Duration(seconds: 3));
      await pumpEventQueue();

      await _advance(env, const Duration(seconds: 2));
      expect(outcomes, isEmpty);
      await _advance(env, const Duration(seconds: 1));

      expect(outcomes, hasLength(1));
      expect(outcomes.single, isA<HostedRequestTimeout>());
      expect(env.held.aborts, 1);
    });

    test(
      'a response before the caller timeout is returned and cancels its timer',
      () async {
        final env = _env();
        final outcomes = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();

        await _advance(env, const Duration(seconds: 30));
        expect(outcomes, isEmpty, reason: 'the 10 s default does not apply');
        env.held.respond(0, 200, {'echoes': <Object?>[]});
        await pumpEventQueue();

        expect(outcomes, [
          {'echoes': <Object?>[]},
        ]);
        expect(env.clock.pendingTimers, 0);
        expect(env.status, HostedConnectionStatus.connected);
        expect(env.held.aborts, 0);
      },
    );

    test('a response after the caller timeout is ignored', () async {
      final env = _env();
      final outcomes = env.start(timeout: const Duration(seconds: 60));
      await pumpEventQueue();
      await _advance(env, const Duration(seconds: 60));
      expect(outcomes, hasLength(1));
      expect(outcomes.single, isA<HostedRequestTimeout>());

      // A late 401 would record tokenRejected if it were read.
      env.held.respond(0, 401, {
        'error': {'code': 'unauthorized', 'message': 'no'},
      });
      await pumpEventQueue();

      expect(outcomes, hasLength(1), reason: 'no second outcome');
      expect(env.status, isNull);
    });

    test(
      'a refused connection under a caller timeout is still unreachable',
      () async {
        final server = FakeVaultServer()..failure = FakeServerFailure.refused;
        final env = _env(over: server.client);

        final outcomes = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();

        expect(outcomes.single, isA<VaultUnreachableException>());
        expect(
          (outcomes.single! as VaultUnreachableException).mayHaveCommitted,
          isFalse,
        );
        expect(env.status, HostedConnectionStatus.unreachable);
        expect(env.clock.pendingTimers, 0);
      },
    );

    test(
      'a connection dropped under a caller timeout is unreachable with a possible commit',
      () async {
        final server = FakeVaultServer()..failure = FakeServerFailure.drop;
        final env = _env(over: server.client);

        final outcomes = env.start(timeout: const Duration(seconds: 60));
        await pumpEventQueue();

        expect(outcomes.single, isA<VaultUnreachableException>());
        expect(
          (outcomes.single! as VaultUnreachableException).mayHaveCommitted,
          isTrue,
        );
        expect(env.status, HostedConnectionStatus.unreachable);
      },
    );
  });

  group('the default', () {
    test(
      'a request without a timeout keeps 10 s and records unreachable',
      () async {
        final env = _env();
        final outcomes = env.start(passTimeout: false);
        await pumpEventQueue();

        await _advance(env, const Duration(seconds: 9));
        expect(outcomes, isEmpty);
        expect(env.held.aborts, 0);
        await _advance(env, const Duration(seconds: 1));

        expect(outcomes.single, isA<VaultUnreachableException>());
        expect(
          (outcomes.single! as VaultUnreachableException).mayHaveCommitted,
          isTrue,
        );
        expect(env.held.aborts, 1);
        expect(env.status, HostedConnectionStatus.unreachable);
      },
    );

    test('an explicit null timeout is the 10 s default', () async {
      final env = _env();
      final outcomes = env.start(timeout: null);
      await pumpEventQueue();

      await _advance(env, const Duration(seconds: 10));

      expect(outcomes.single, isA<VaultUnreachableException>());
      expect(env.status, HostedConnectionStatus.unreachable);
    });

    test('a server request keeps 10 s and records unreachable', () async {
      final env = _env();
      final outcomes = <Object?>[];
      unawaited(
        env.client
            .serverRequest('GET', '/vaults', operation: 'list')
            .then<void>(outcomes.add, onError: (Object e) => outcomes.add(e)),
      );
      await pumpEventQueue();

      await _advance(env, const Duration(seconds: 10));

      expect(outcomes.single, isA<VaultUnreachableException>());
      expect(env.status, HostedConnectionStatus.unreachable);
    });
  });
}
