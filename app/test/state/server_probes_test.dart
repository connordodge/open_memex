// WI #97 (H3): picker probes. While `serverProbesProvider` is watched, each
// saved server gets one `GET /api/v1/info` when first watched and one more
// on each window refocus (app-focus seam, D15). Each result lands in
// `hostedConnectionStatusProvider` (through HostedClient's response hook)
// and `serverProbeResultProvider`.
//
// API under test (#97):
//   final serverProbeResultProvider = StateProvider.family<ServerProbe?, String>
//   final serverProbesProvider = Provider.autoDispose<void>   (watch it)
//   class PickerActions { connect / editServer / openOnServer /
//       createOnServer / setUp }   default: does nothing
// Used from #96 (not owned here): `hostedHttpClientProvider`
// (vault_access/hosted/hosted_vault_access.dart), `recentRowOutcomeProvider`
// and the hosted failures (state/vault_open_hosted.dart).
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/picker_actions.dart';
import 'package:open_memex_app/src/state/server_probes.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';
import '../support/poll_fakes.dart';
import '../support/token_store_fakes.dart';
import '../support/vault_picker_harness.dart';

class _Wi97ProbeEnv {
  _Wi97ProbeEnv(this.container, this.servers, this.tokens, this.routed);

  final ProviderContainer container;

  /// Every request the hosted http client sent, to any server.
  final List<http.BaseRequest> routed;
  final Map<String, FakeVaultServer> servers;
  final FakeTokenStore tokens;

  FakeAppFocus get focus =>
      container.read(appFocusProvider.notifier) as FakeAppFocus;

  HostedConnectionStatus? status(String id) =>
      container.read(hostedConnectionStatusProvider(id));

  ServerProbe? result(String id) =>
      container.read(serverProbeResultProvider(id));

  List<http.Request> info(String id) => [
    for (final r in servers[id]!.requests)
      if (r.method == 'GET' && r.url.path == '/api/v1/info') r,
  ];

  /// Starts watching the probes, as the picker does.
  ProviderSubscription<void> open() =>
      container.listen<void>(serverProbesProvider, (_, _) {});
}

Future<_Wi97ProbeEnv> _env({
  List<SavedServer> saved = const [wi97Nas, wi97Mini],
  Map<String, String>? tokenOverride,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.vault_servers': [
      for (final s in saved)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  });
  final tokens = FakeTokenStore(
    tokenOverride ?? {for (final s in saved) s.id: wi97TokenFor(s.id)},
  );
  final settings = await SettingsController.load(tokenStore: tokens);
  final servers = {
    for (final s in saved)
      s.id: FakeVaultServer(token: wi97TokenFor(s.id), url: s.url)
        ..serveDomain('server'),
  };
  final routed = <http.BaseRequest>[];
  final router = MockClient((request) async {
    routed.add(request);
    for (final s in servers.values) {
      if (s.url.host == request.url.host && s.url.port == request.url.port) {
        return http.Response.fromStream(await s.client.send(request));
      }
    }
    throw StateError('no fake vault server for ${request.url}');
  });
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(tokens),
      hostedHttpClientProvider.overrideWithValue(router),
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
      appFocusProvider.overrideWith(() => FakeAppFocus()),
    ],
  );
  addTearDown(container.dispose);
  return _Wi97ProbeEnv(container, servers, tokens, routed);
}

const _memexRef = HostedVaultRef(fakeServerId, 'memex');

/// Lets fake server responses and token reads finish.
Future<void> _drain() => pumpEventQueue();

/// A BuildContext for calling the default picker actions.
class _Wi97Ctx extends StatelessWidget {
  const _Wi97Ctx();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  group('probe on open', () {
    test(
      'watching the probes sends one info request to each saved server',
      () async {
        final env = await _env();
        env.open();
        await _drain();

        expect(env.info(wi97Nas.id), hasLength(1));
        expect(env.info(wi97Mini.id), hasLength(1));
        expect(
          env.info(wi97Nas.id).single.url.toString(),
          'http://nas.local:7878/api/v1/info',
        );
        expect(
          env.info(wi97Mini.id).single.url.toString(),
          'http://100.101.12.4:7878/api/v1/info',
        );
        // Nothing else is requested.
        expect(env.servers[wi97Nas.id]!.requests, hasLength(1));
        expect(env.servers[wi97Mini.id]!.requests, hasLength(1));
      },
    );

    test(
      'each probe carries the access token saved for its own server',
      () async {
        final env = await _env();
        env.open();
        await _drain();

        expect(
          env.info(wi97Nas.id).single.headers['authorization'],
          'Bearer ${wi97TokenFor(wi97Nas.id)}',
        );
        expect(
          env.info(wi97Mini.id).single.headers['authorization'],
          'Bearer ${wi97TokenFor(wi97Mini.id)}',
        );
        expect(
          env.tokens.calls,
          containsAll(['read srv-nas', 'read srv-mini']),
        );
      },
    );

    test(
      'a second watcher while the probes are open sends nothing more',
      () async {
        final env = await _env();
        env.open();
        await _drain();
        env.open();
        await _drain();

        expect(env.info(wi97Nas.id), hasLength(1));
        expect(env.info(wi97Mini.id), hasLength(1));
      },
    );

    test('with no saved server watching the probes sends nothing', () async {
      final env = await _env(saved: const []);
      final sub = env.open();
      await _drain();
      expect(env.routed, isEmpty);
      // The probes built without error.
      expect(sub.read, returnsNormally);
    });

    test(
      'closing and reopening the probes probes each saved server again',
      () async {
        final env = await _env();
        final sub = env.open();
        await _drain();
        sub.close();
        await _drain();
        env.open();
        await _drain();

        expect(env.info(wi97Nas.id), hasLength(2));
        expect(env.info(wi97Mini.id), hasLength(2));
      },
    );
  });

  group('probe results', () {
    test(
      'status stays null while the probe is held and is connected once it returns',
      () async {
        final env = await _env(saved: const [wi97Nas]);
        env.servers[wi97Nas.id]!.hold();
        env.open();
        await _drain();

        expect(env.info(wi97Nas.id), hasLength(1));
        expect(env.status(wi97Nas.id), isNull);
        expect(env.result(wi97Nas.id), isNull);

        env.servers[wi97Nas.id]!.release();
        await _drain();
        expect(env.status(wi97Nas.id), HostedConnectionStatus.connected);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.connected);
        expect(env.result(wi97Nas.id)!.serverVersion, '0.1.0');
      },
    );

    test(
      'a refused connection records unreachable for that server only',
      () async {
        final env = await _env();
        env.servers[wi97Mini.id]!.failure = FakeServerFailure.refused;
        env.open();
        await _drain();

        expect(env.status(wi97Mini.id), HostedConnectionStatus.unreachable);
        expect(env.result(wi97Mini.id)!.kind, ServerProbeKind.unreachable);
        expect(env.status(wi97Nas.id), HostedConnectionStatus.connected);
      },
    );

    test('a wrong access token records token rejected', () async {
      final env = await _env(
        saved: const [wi97Nas],
        tokenOverride: {wi97Nas.id: 'stale-token'},
      );
      env.open();
      await _drain();

      expect(env.status(wi97Nas.id), HostedConnectionStatus.tokenRejected);
      expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.unauthorized);
    });

    test(
      'a server that is not memex records incompatible and the notMemex result',
      () async {
        final env = await _env(saved: const [wi97Nas]);
        env.servers[wi97Nas.id]!.servesHtml = true;
        env.open();
        await _drain();

        expect(env.status(wi97Nas.id), HostedConnectionStatus.incompatible);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.notMemex);
      },
    );

    test(
      'an api mismatch records incompatible and keeps the server version',
      () async {
        final env = await _env(saved: const [wi97Nas]);
        env.servers[wi97Nas.id]!.route(
          'GET',
          '/api/v1/info',
          json: {'api_version': 2, 'server_version': '0.9.${3 * 1}'},
        );
        env.open();
        await _drain();

        expect(env.status(wi97Nas.id), HostedConnectionStatus.incompatible);
        expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.apiMismatch);
        expect(env.result(wi97Nas.id)!.serverVersion, '0.9.3');
      },
    );

    test(
      'a probe that returns after the probes close throws nothing',
      () async {
        final env = await _env(saved: const [wi97Nas]);
        env.servers[wi97Nas.id]!.hold();
        final sub = env.open();
        await _drain();
        sub.close();
        await _drain();
        env.servers[wi97Nas.id]!.release();
        await _drain();
        // An error from a write through a disposed ref would fail the test
        // zone; the request itself went out once.
        expect(env.info(wi97Nas.id), hasLength(1));
      },
    );

    test('before any probe the result and the status are null', () async {
      final env = await _env(saved: const [wi97Nas]);
      expect(env.result(wi97Nas.id), isNull);
      expect(env.status(wi97Nas.id), isNull);
    });
  });

  group('probe on refocus', () {
    test('a window refocus probes each saved server once more', () async {
      final env = await _env();
      env.open();
      await _drain();
      env.focus.set(false);
      await _drain();
      env.focus.set(true);
      await _drain();

      expect(env.info(wi97Nas.id), hasLength(2));
      expect(env.info(wi97Mini.id), hasLength(2));
    });

    test('losing focus sends no probe', () async {
      final env = await _env();
      env.open();
      await _drain();
      env.focus.set(false);
      await _drain();

      expect(env.info(wi97Nas.id), hasLength(1));
      expect(env.info(wi97Mini.id), hasLength(1));
    });

    test('two refocuses probe each saved server twice more', () async {
      final env = await _env();
      env.open();
      await _drain();
      for (var i = 0; i < 2; i++) {
        env.focus.set(false);
        await _drain();
        env.focus.set(true);
        await _drain();
      }

      expect(env.info(wi97Nas.id), hasLength(3));
      expect(env.info(wi97Mini.id), hasLength(3));
    });

    test('a refocus result replaces the earlier one', () async {
      final env = await _env(saved: const [wi97Nas]);
      env.open();
      await _drain();
      expect(env.status(wi97Nas.id), HostedConnectionStatus.connected);

      env.servers[wi97Nas.id]!.failure = FakeServerFailure.hostLookup;
      env.focus.set(false);
      await _drain();
      env.focus.set(true);
      await _drain();

      expect(env.status(wi97Nas.id), HostedConnectionStatus.unreachable);
      expect(env.result(wi97Nas.id)!.kind, ServerProbeKind.unreachable);
    });

    test('a refocus after the probes close sends nothing', () async {
      final env = await _env();
      final sub = env.open();
      await _drain();
      sub.close();
      await _drain();
      // Keep the focus seam alive on its own.
      env.container.listen<bool>(appFocusProvider, (_, _) {});
      env.focus.set(false);
      await _drain();
      env.focus.set(true);
      await _drain();

      expect(env.info(wi97Nas.id), hasLength(1));
      expect(env.info(wi97Mini.id), hasLength(1));
    });
  });

  group('seam defaults', () {
    test('the default hosted http client is a real client', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(hostedHttpClientProvider), isA<http.Client>());
    });

    test('the default probe result and recorded outcome are null', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(serverProbeResultProvider('srv-x')), isNull);
      expect(
        c.read(recentRowOutcomeProvider(const HostedVaultRef('srv-x', 'v'))),
        isNull,
      );
      expect(
        c.read(recentRowOutcomeProvider(const LocalVaultRef('/v'))),
        isNull,
      );
    });

    test('a recorded outcome is kept per entry', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final name = ['me', 'mex'].join();
      final hosted = HostedVaultRef(fakeServerId, name);
      c.read(recentRowOutcomeProvider(hosted).notifier).state = RecentRowFailed(
        HostedVaultGone(hosted, fakeServerName, '$name is no longer on nas'),
      );

      final read = c.read(
        recentRowOutcomeProvider(HostedVaultRef(fakeServerId, name)),
      );
      expect(read, isA<RecentRowFailed>());
      final failure = (read! as RecentRowFailed).failure;
      expect(failure, isA<HostedVaultGone>());
      expect(failure.message, 'memex is no longer on nas');
      expect(
        c.read(recentRowOutcomeProvider(HostedVaultRef('srv-mini', name))),
        isNull,
      );
    });

    testWidgets('the default picker actions do nothing', (tester) async {
      await tester.pumpWidget(const _Wi97Ctx());
      final context = tester.element(find.byType(_Wi97Ctx));
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final actions = c.read(pickerActionsProvider);

      expect(await actions.connect(context), isNull);
      await actions.editServer(context, 'srv-nas');
      await actions.openOnServer(context);
      await actions.createOnServer(context);
      await actions.setUp(context);
    });

    test('hosted outcomes carry their message and the server version', () {
      final version = ['0', '9', '3'].join('.');
      final vault = HostedVaultRef(fakeServerId, ['me', 'mex'].join());
      final server = fakeServerName;
      final outcomes = <HostedVaultOpenFailure>[
        HostedServerUnreachable(
          vault,
          server,
          'could not reach nas ($version)',
        ),
        HostedTokenRejected(vault, server, 'rejected $version'),
        HostedNotMemexServer(vault, server, 'not memex $version'),
        HostedApiMismatch(
          vault,
          server,
          'mismatch $version',
          serverVersion: version,
        ),
        HostedVaultGone(vault, server, 'gone $version'),
        HostedSchemaRefused(vault, server, 'schema $version'),
      ];
      expect(outcomes.map((o) => o.message), [
        'could not reach nas (0.9.3)',
        'rejected 0.9.3',
        'not memex 0.9.3',
        'mismatch 0.9.3',
        'gone 0.9.3',
        'schema 0.9.3',
      ]);
      expect((outcomes[3] as HostedApiMismatch).serverVersion, '0.9.3');
      expect(outcomes.map((o) => o.vault), everyElement(_memexRef));
      expect(outcomes.map((o) => o.serverName), everyElement('nas'));
      expect(outcomes, everyElement(isA<VaultOpenOutcome>()));
    });
  });
}
