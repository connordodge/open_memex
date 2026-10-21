// WI #105 (F1) verify: contracts of the seam bindings that the AC tests in
// seam_bindings_test.dart and entry_points_test.dart leave unpinned (the
// implementer's handoff lists them):
// - `hostedVaultGoneProvider` is set by the open path on C1
//   `vault_not_found` and cleared by a successful open of that vault;
// - `hostedClientForServerProvider` gives no client for a saved server with
//   no open hosted vault on it;
// - `VaultOpenController.serverTokenChanged` hands the token now in the
//   token store to the open session (`HostedClient.useAccessToken`) and
//   sends one probe, so a poller a 401 stopped resumes and polls with the
//   new Bearer; it does nothing for another server or with no token;
// - the network-drive refusal reached from a local vault pill in the
//   sidebar opens the set-up sheet and the connect dialog, as the picker's
//   refusal does.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../robots/hosted_workspace_robot.dart';
import '../robots/picker_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';

const _work = HostedVaultRef(fakeServerId, 'work');
const _newToken = 'rotated-token-105';

/// `METHOD path Bearer` of each request in [requests].
List<String> _sent(Iterable<http.Request> requests) => [
  for (final r in requests)
    '${r.method} ${r.url.path} ${r.headers['authorization']}',
];

void main() {
  holdFontFetches();

  group('hostedVaultGoneProvider and the open path', () {
    test(
      'an open that gets vault_not_found sets the vault gone flag for that vault only',
      () async {
        final h = await hostedContainer();
        h.first.server.removeVault('seed');

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(outcome, isA<HostedVaultGone>());
        expect(h.read(hostedVaultGoneProvider(seedHostedRef)), isTrue);
        expect(h.read(hostedVaultGoneProvider(_work)), isFalse);
      },
    );

    test(
      'a successful open clears the vault gone flag of the vault it opened',
      () async {
        final h = await hostedContainer();
        h.read(hostedVaultGoneProvider(seedHostedRef).notifier).state = true;
        h.read(hostedVaultGoneProvider(_work).notifier).state = true;

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(outcome, isA<VaultOpened>());
        expect(h.read(hostedVaultGoneProvider(seedHostedRef)), isFalse);
        expect(
          h.read(hostedVaultGoneProvider(_work)),
          isTrue,
          reason: 'another vault keeps its flag',
        );
      },
    );

    test(
      'a failed open leaves the vault gone flag of that vault set',
      () async {
        final h = await hostedContainer();
        h.read(hostedVaultGoneProvider(seedHostedRef).notifier).state = true;
        h.first.server.failure = FakeServerFailure.refused;

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(outcome, isA<HostedServerUnreachable>());
        expect(h.read(hostedVaultGoneProvider(seedHostedRef)), isTrue);
      },
    );
  });

  group('hostedClientForServerProvider without an open vault', () {
    test(
      'hostedClientForServerProvider gives no client for a saved server with no open vault',
      () async {
        final studio = journeyStudio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );

        expect(h.read(hostedClientForServerProvider(fakeServerId)), isNull);
        expect(h.read(hostedClientForServerProvider(studio.id)), isNull);

        await h.controller.openVault(seedHostedRef);

        expect(h.read(hostedClientForServerProvider(fakeServerId)), isNotNull);
        expect(
          h.read(hostedClientForServerProvider(studio.id)),
          isNull,
          reason: 'the open vault is on nas, not studio',
        );
      },
    );
  });

  group('serverTokenChanged hands the new token to the open session', () {
    test(
      'serverTokenChanged makes the open session send with the new token and probes once',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final server = h.first.server;
        server.token = _newToken;
        await h.tokens.write(fakeServerId, _newToken);
        final before = server.requests.length;

        await h.controller.serverTokenChanged(fakeServerId);

        expect(_sent(server.requests.skip(before)), [
          'GET /api/v1/info Bearer $_newToken',
        ]);
        expect(
          h.read(hostedConnectionStatusProvider(fakeServerId)),
          HostedConnectionStatus.connected,
        );

        final client = h.read(hostedClientForServerProvider(fakeServerId))!;
        final next = server.requests.length;
        await client.probeServer();
        expect(_sent(server.requests.skip(next)), [
          'GET /api/v1/info Bearer $_newToken',
        ]);
      },
    );

    test(
      'serverTokenChanged for a server with no open vault sends nothing',
      () async {
        final studio = journeyStudio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);
        final nasBefore = h.first.server.requests.length;
        final studioBefore = studio.server.requests.length;
        await h.tokens.write(studio.id, _newToken);

        await h.controller.serverTokenChanged(studio.id);

        expect(h.first.server.requests, hasLength(nasBefore));
        expect(studio.server.requests, hasLength(studioBefore));
      },
    );

    test(
      'serverTokenChanged with no token in the store keeps the session token and sends nothing',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        await h.tokens.delete(fakeServerId);
        final server = h.first.server;
        final before = server.requests.length;

        await h.controller.serverTokenChanged(fakeServerId);

        expect(server.requests, hasLength(before));
        final client = h.read(hostedClientForServerProvider(fakeServerId))!;
        await client.probeServer();
        expect(_sent(server.requests.skip(before)), [
          'GET /api/v1/info Bearer $fakeServerToken',
        ]);
      },
    );

    testWidgets(
      'after a 401 stopped the poller saving the new token in the edit server dialog resumes polls with the new Bearer',
      (tester) async {
        final app = await pumpJourneyApp(
          tester,
          servers: [HostedServerFixture()],
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        final w = HostedWorkspaceRobot(app);
        final r = PickerRobot(app);
        expect(w.currentVault, seedHostedRef);
        final server = app.first.server;

        server.token = _newToken;
        await app.pollTick();
        expect(w.unauthorizedBanner, findsOneWidget);
        expect(app.status(fakeServerId), HostedConnectionStatus.tokenRejected);
        // The poller is stopped: ticks send nothing.
        final stopped = server.requests.length;
        await app.pollTick();
        expect(server.requests, hasLength(stopped));

        await w.tap(w.bannerUpdateToken);
        r.expectEditServerDialog('nas', fakeServerUrl);
        await r.enter(r.connectToken, _newToken);
        await r.tap(r.connectSubmit);
        await app.settle();

        expect(r.connectDialog, findsNothing);
        expect(app.tokens.tokens[fakeServerId], _newToken);
        expect(app.status(fakeServerId), HostedConnectionStatus.connected);
        expect(w.unauthorizedBanner, findsNothing);

        final resumed = server.requests.length;
        await app.pollTick();
        await app.pollTick();
        final polls = _sent(
          server.requests.skip(resumed),
        ).where((s) => s.contains('/vaults/seed/'));
        expect(polls, isNotEmpty, reason: 'the poller resumed');
        expect(
          polls,
          everyElement(endsWith('Bearer $_newToken')),
          reason: 'every resumed poll carries the new token',
        );
        expect(app.status(fakeServerId), HostedConnectionStatus.connected);
      },
    );
  });

  group('refusal choices from a sidebar pill', () {
    /// The workspace on the seed vault of nas, with a local vault on a
    /// network drive in the recents; its pill was tapped and the refusal
    /// shows.
    Future<(PickerRobot, HostedWorkspaceRobot)> refusalFromPill(
      WidgetTester tester,
    ) async {
      final local = createVaultFolder('om105_pill_nas_');
      final cli = FakeMemexCli()
        ..on(
          'vault check',
          (call) => call.args.contains(local.path)
              ? FakeMemexCli.error(
                  'network_filesystem',
                  'the vault folder is on a network filesystem',
                )
              : FakeMemexCli.ok(),
        );
      final app = await pumpJourneyApp(
        tester,
        servers: [HostedServerFixture()],
        recents: [seedHostedRef, LocalVaultRef(local.path)],
        lastVault: seedHostedRef,
        cli: cli,
      );
      final w = HostedWorkspaceRobot(app);
      final r = PickerRobot(app);
      expect(w.currentVault, seedHostedRef);

      await w.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text(p.basename(local.path)),
        ),
      );
      expect(r.networkRefusal, findsOneWidget);
      expect(
        r.within(r.networkRefusal, find.text('OPEN LOCAL VAULT')),
        findsOneWidget,
      );
      return (r, w);
    }

    testWidgets(
      'the refusal from a local vault pill connect to a vault server opens the connect dialog',
      (tester) async {
        final (r, w) = await refusalFromPill(tester);

        await r.tap(r.networkRefusalConnect);

        expect(r.networkRefusal, findsNothing);
        r.expectConnectDialog();
        expect(w.currentVault, seedHostedRef);
      },
    );

    testWidgets(
      'the refusal from a local vault pill set up a vault server opens the set up sheet',
      (tester) async {
        final (r, w) = await refusalFromPill(tester);

        await r.tap(r.networkRefusalSetUp);

        expect(r.networkRefusal, findsNothing);
        expect(r.setUpSheet, findsOneWidget);
        expect(find.text('SET UP A VAULT SERVER'), findsOneWidget);
        expect(w.currentVault, seedHostedRef);
      },
    );
  });
}
