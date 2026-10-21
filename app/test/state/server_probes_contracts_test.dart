// WI #97 (H3): picker probe contracts the implementer's handoff listed as
// unpinned, plus the lead's dispose ruling (after the probes are disposed,
// nothing #97 owns writes; HostedClient's own response hook may still write
// the connection status).
//
// Each request is held in a queue and answered by the test, so two probes of
// one server can be in flight together and return in either order.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/server_probes.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';
import '../support/poll_fakes.dart';
import '../support/token_store_fakes.dart';
import '../support/vault_picker_harness.dart';

/// One request the hosted http client sent, waiting for the test's answer.
class _Wi97cCall {
  _Wi97cCall(this.request);

  final http.Request request;
  final Completer<http.Response> _reply = Completer();

  /// Answers `GET /api/v1/info` as a memex server running [version].
  void connected(String version) => _reply.complete(
    http.Response(
      jsonEncode({'api_version': kApiVersion, 'server_version': version}),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );

  /// Fails the request as a refused connection.
  void refused() => _reply.completeError(
    fakeTransportException(FakeServerFailure.refused, request.url)!,
  );
}

/// A token store whose reads wait for [releaseReads] once [holdReads] ran.
class _Wi97cHeldTokenStore extends FakeTokenStore {
  _Wi97cHeldTokenStore(super.initial);

  Completer<void>? _gate;

  void holdReads() => _gate ??= Completer<void>();

  void releaseReads() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<String?> read(String serverId) async {
    final gate = _gate;
    if (gate != null) await gate.future;
    return super.read(serverId);
  }
}

class _Wi97cEnv {
  _Wi97cEnv(this.container, this.calls, this.tokens);

  final ProviderContainer container;
  final List<_Wi97cCall> calls;
  final _Wi97cHeldTokenStore tokens;

  FakeAppFocus get focus =>
      container.read(appFocusProvider.notifier) as FakeAppFocus;

  HostedConnectionStatus? status(String id) =>
      container.read(hostedConnectionStatusProvider(id));

  ServerProbe? result(String id) =>
      container.read(serverProbeResultProvider(id));

  /// The `GET /api/v1/info` calls sent to [server], in order.
  List<_Wi97cCall> infoTo(SavedServer server) => [
    for (final c in calls)
      if (c.request.method == 'GET' &&
          c.request.url.toString() == '${server.url}/api/v1/info')
        c,
  ];

  ProviderSubscription<void> open() =>
      container.listen<void>(serverProbesProvider, (_, _) {});

  Future<void> refocus() async {
    focus.set(false);
    await pumpEventQueue();
    focus.set(true);
    await pumpEventQueue();
  }
}

Future<_Wi97cEnv> _env({
  List<SavedServer> saved = const [wi97Nas],
  Map<String, String>? tokens,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.vault_servers': [
      for (final s in saved)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  });
  final store = _Wi97cHeldTokenStore(
    tokens ?? {for (final s in saved) s.id: wi97TokenFor(s.id)},
  );
  final settings = await SettingsController.load(tokenStore: store);
  final calls = <_Wi97cCall>[];
  final router = MockClient((request) {
    final call = _Wi97cCall(request);
    calls.add(call);
    return call._reply.future;
  });
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(store),
      hostedHttpClientProvider.overrideWithValue(router),
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
      appFocusProvider.overrideWith(() => FakeAppFocus()),
    ],
  );
  addTearDown(container.dispose);
  return _Wi97cEnv(container, calls, store);
}

void main() {
  group('refocus while a probe is in flight', () {
    test(
      'a refocus while the first probe is in flight sends a second probe',
      () async {
        final env = await _env();
        env.open();
        await pumpEventQueue();
        expect(env.infoTo(wi97Nas), hasLength(1));

        await env.refocus();

        expect(env.infoTo(wi97Nas), hasLength(2));
        expect(env.status(wi97Nas.id), isNull);
        expect(env.result(wi97Nas.id), isNull);
      },
    );

    test(
      'two probes in flight where the refocus probe returns first leave the first probe result',
      () async {
        final env = await _env();
        env.open();
        await pumpEventQueue();
        await env.refocus();
        final [first, second] = env.infoTo(wi97Nas);

        second.refused();
        await pumpEventQueue();
        expect(env.status(wi97Nas.id), HostedConnectionStatus.unreachable);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.unreachable);

        first.connected('0.1.0');
        await pumpEventQueue();
        expect(env.status(wi97Nas.id), HostedConnectionStatus.connected);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.connected);
        expect(env.result(wi97Nas.id)!.serverVersion, '0.1.0');
      },
    );

    test(
      'two probes in flight where the first probe returns first leave the refocus probe result',
      () async {
        final env = await _env();
        env.open();
        await pumpEventQueue();
        await env.refocus();
        final [first, second] = env.infoTo(wi97Nas);

        first.connected('0.1.0');
        await pumpEventQueue();
        expect(env.status(wi97Nas.id), HostedConnectionStatus.connected);

        second.refused();
        await pumpEventQueue();
        expect(env.status(wi97Nas.id), HostedConnectionStatus.unreachable);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.unreachable);
      },
    );
  });

  group('servers saved while the probes are open', () {
    test(
      'a server saved while the probes are open is not probed until the next refocus',
      () async {
        final env = await _env();
        env.open();
        await pumpEventQueue();
        env.infoTo(wi97Nas).single.connected('0.1.0');
        await pumpEventQueue();

        final mini = await env.container
            .read(settingsProvider.notifier)
            .saveServer(
              name: wi97Mini.name,
              url: wi97Mini.url,
              token: wi97TokenFor('mini'),
            );
        await pumpEventQueue();
        expect(env.infoTo(wi97Mini), isEmpty);
        expect(env.status(mini.id), isNull);
        expect(env.result(mini.id), isNull);
        expect(env.infoTo(wi97Nas), hasLength(1));

        await env.refocus();
        expect(env.infoTo(wi97Mini), hasLength(1));
        expect(
          env.infoTo(wi97Mini).single.request.headers['authorization'],
          'Bearer ${wi97TokenFor('mini')}',
        );
        expect(env.infoTo(wi97Nas), hasLength(2));
      },
    );

    test(
      'a server saved while the probes are open is probed when the probes reopen',
      () async {
        final env = await _env();
        final sub = env.open();
        await pumpEventQueue();

        await env.container
            .read(settingsProvider.notifier)
            .saveServer(
              name: wi97Mini.name,
              url: wi97Mini.url,
              token: wi97TokenFor('mini'),
            );
        await pumpEventQueue();
        expect(env.infoTo(wi97Mini), isEmpty);

        sub.close();
        await pumpEventQueue();
        env.open();
        await pumpEventQueue();
        expect(env.infoTo(wi97Mini), hasLength(1));
      },
    );
  });

  group('no saved token', () {
    test(
      'a server with no saved token sends no request and records token rejected',
      () async {
        final env = await _env(
          saved: const [wi97Nas, wi97Mini],
          tokens: {wi97Mini.id: wi97TokenFor(wi97Mini.id)},
        );
        env.open();
        await pumpEventQueue();

        expect(env.infoTo(wi97Nas), isEmpty);
        expect(env.status(wi97Nas.id), HostedConnectionStatus.tokenRejected);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.unauthorized);
        expect(env.result(wi97Nas.id)!.serverVersion, isNull);
        expect(env.tokens.calls, contains('read ${wi97Nas.id}'));
        // The server with a token is probed as usual.
        expect(env.infoTo(wi97Mini), hasLength(1));
        expect(env.calls, hasLength(1));
      },
    );

    test('a refocus with no saved token still sends no request', () async {
      final env = await _env(tokens: const {});
      env.open();
      await pumpEventQueue();
      await env.refocus();

      expect(env.calls, isEmpty);
      expect(env.status(wi97Nas.id), HostedConnectionStatus.tokenRejected);
      expect(
        env.tokens.calls.where((c) => c == 'read ${wi97Nas.id}'),
        hasLength(2),
      );
    });
  });

  group('after the probes are disposed', () {
    test(
      'a probe that returns after the probes close writes no probe result',
      () async {
        final env = await _env();
        final sub = env.open();
        await pumpEventQueue();
        final call = env.infoTo(wi97Nas).single;

        sub.close();
        await pumpEventQueue();
        call.connected('0.1.0');
        await pumpEventQueue();

        expect(env.result(wi97Nas.id), isNull);
      },
    );

    test(
      'probes that close during the token read send no request and write nothing',
      () async {
        final env = await _env();
        env.tokens.holdReads();
        final sub = env.open();
        await pumpEventQueue();
        expect(env.calls, isEmpty);

        sub.close();
        await pumpEventQueue();
        env.tokens.releaseReads();
        await pumpEventQueue();

        expect(env.calls, isEmpty);
        expect(env.status(wi97Nas.id), isNull);
        expect(env.result(wi97Nas.id), isNull);
      },
    );

    test(
      'probes that close during the token read of a server with no token write no status',
      () async {
        final env = await _env(tokens: const {});
        env.tokens.holdReads();
        final sub = env.open();
        await pumpEventQueue();

        sub.close();
        await pumpEventQueue();
        env.tokens.releaseReads();
        await pumpEventQueue();

        expect(env.calls, isEmpty);
        expect(env.status(wi97Nas.id), isNull);
        expect(env.result(wi97Nas.id), isNull);
      },
    );
  });
}
