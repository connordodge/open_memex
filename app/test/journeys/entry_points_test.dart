// WI #105 (F1) AC1 and AC2: hosted vaults are on with default providers
// (no flag, no override, no --dart-define), and every entry point the UI
// WIs left as a seam opens its target: the connect dialog (#98), the
// edit-server dialog for that server (#98, A5 state 6) or the set-up sheet
// (#100). The real OpenMemexApp runs over the journey harness; the picker
// actions, the update-token seams and the refusal choices are the app's own
// bindings.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';

import '../robots/hosted_workspace_robot.dart';
import '../robots/picker_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/file_picker_fakes.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

const _hostedSubtitle =
    'a vault is a folder of your notes. open one on this mac, or one hosted '
    'by a vault server.';

/// A fake CLI whose `vault check` refuses the folder as on a network drive.
FakeMemexCli _networkDriveCli() => FakeMemexCli()
  ..on(
    'vault check',
    (_) => FakeMemexCli.error(
      'network_filesystem',
      'the vault folder is on a network filesystem',
    ),
  );

/// The picker with one saved server (nas) and nothing open.
Future<PickerRobot> _pickerWithNas(WidgetTester tester) async =>
    PickerRobot(await pumpJourneyApp(tester, servers: [HostedServerFixture()]));

/// The picker with no saved server.
Future<PickerRobot> _pickerWithNoServers(WidgetTester tester) async =>
    PickerRobot(await pumpJourneyApp(tester));

/// The picker after a local open that `memex vault check` refused as on a
/// network drive: the refusal (A9 state 1) shows.
Future<PickerRobot> _networkDriveRefusal(WidgetTester tester) async {
  final vault = createVaultFolder('om105_nas_');
  installFakeFilePicker().directories.add(vault.path);
  final r = PickerRobot(await pumpJourneyApp(tester, cli: _networkDriveCli()));
  await r.tap(r.openLocal);
  expect(r.networkRefusal, findsOneWidget);
  return r;
}

/// The workspace on the seed vault of nas, opened at launch.
Future<(PickerRobot, HostedWorkspaceRobot)> _hostedWorkspace(
  WidgetTester tester, {
  List<HostedServerFixture>? servers,
  List<VaultRef> extraRecents = const [],
}) async {
  final nas = HostedServerFixture();
  final app = await pumpJourneyApp(
    tester,
    servers: servers ?? [nas],
    recents: [seedHostedRef, ...extraRecents],
    lastVault: seedHostedRef,
  );
  await app.settle();
  final w = HostedWorkspaceRobot(app);
  expect(w.currentVault, seedHostedRef, reason: 'launch opened the vault');
  return (PickerRobot(app), w);
}

void main() {
  wi97HoldFontFetches();

  group('hosted vaults are on by default (AC1)', () {
    testWidgets(
      'with default providers the picker shows the SERVERS section and the VAULT SERVER row and probes each saved server',
      (tester) async {
        final r = await _pickerWithNas(tester);

        expect(find.text('SERVERS'), findsOneWidget);
        expect(r.serversConnect, findsOneWidget);
        expect(r.serverRow(fakeServerId), findsOneWidget);
        expect(find.text('VAULT SERVER'), findsOneWidget);
        expect(r.openOnServer, findsOneWidget);
        expect(r.createOnServer, findsOneWidget);
        expect(find.text('THIS MAC'), findsOneWidget);
        expect(find.text(_hostedSubtitle), findsOneWidget);
        expect(
          r.app.first.server.requests.where(
            (q) => q.method == 'GET' && q.url.path == '/api/v1/info',
          ),
          hasLength(1),
          reason: 'the picker probes each saved server once when it opens',
        );
      },
    );

    testWidgets(
      'with default providers hosted recents are listed with local ones',
      (tester) async {
        final local = createVaultFolder('om105_recent_');
        final app = await pumpJourneyApp(
          tester,
          servers: [HostedServerFixture()],
          recents: [seedHostedRef, LocalVaultRef(local.path)],
        );
        final r = PickerRobot(app);

        expect(r.inside('recent-row-0', find.text('seed')), findsOneWidget);
        expect(r.recentRow(1), findsOneWidget);
      },
    );

    testWidgets(
      'with no saved server the no servers box offers connect and set up',
      (tester) async {
        final r = await _pickerWithNoServers(tester);

        expect(
          find.text(
            'no vault servers yet. connect to one to open its vaults on this mac.',
          ),
          findsOneWidget,
        );
        expect(r.noServersConnect, findsOneWidget);
        expect(r.noServersSetUp, findsOneWidget);
      },
    );
  });

  group('entry points open the connect dialog (AC2)', () {
    for (final (name, open) in <(String, Future<PickerRobot> Function(WidgetTester))>[
      (
        'plus CONNECT opens the connect dialog',
        (tester) async {
          final r = await _pickerWithNas(tester);
          await r.tap(r.serversConnect);
          return r;
        },
      ),
      (
        'the no servers connect to a vault server opens the connect dialog',
        (tester) async {
          final r = await _pickerWithNoServers(tester);
          await r.tap(r.noServersConnect);
          return r;
        },
      ),
      (
        'the open dialog connect to a vault server opens the connect dialog',
        (tester) async {
          final r = await _pickerWithNas(tester);
          await r.tap(r.openOnServer);
          expect(r.openDialog, findsOneWidget);
          await r.pickConnectInServerMenu();
          return r;
        },
      ),
      (
        'the create dialog connect to a vault server opens the connect dialog',
        (tester) async {
          final r = await _pickerWithNas(tester);
          await r.tap(r.createOnServer);
          expect(r.createDialog, findsOneWidget);
          await r.pickConnectInServerMenu();
          return r;
        },
      ),
      (
        'the set up sheet connect to a vault server opens the connect dialog',
        (tester) async {
          final r = await _pickerWithNoServers(tester);
          await r.tap(r.noServersSetUp);
          expect(r.setUpSheet, findsOneWidget);
          await r.tap(r.setUpConnect);
          expect(r.setUpSheet, findsNothing);
          return r;
        },
      ),
      (
        'the refusal connect to a vault server opens the connect dialog',
        (tester) async {
          final r = await _networkDriveRefusal(tester);
          await r.tap(r.networkRefusalConnect);
          expect(r.networkRefusal, findsNothing);
          return r;
        },
      ),
    ]) {
      testWidgets(name, (tester) async {
        final r = await open(tester);
        r.expectConnectDialog();
      });
    }
  });

  group('entry points open the edit server dialog for that server (AC2)', () {
    testWidgets(
      'the server row pencil opens the edit server dialog for that server',
      (tester) async {
        final studio = journeyStudio();
        final r = PickerRobot(
          await pumpJourneyApp(
            tester,
            servers: [HostedServerFixture(), studio],
          ),
        );

        await r.tap(r.serverEdit(studio.id));

        r.expectEditServerDialog('studio', 'http://studio.local:9000');
      },
    );

    testWidgets(
      'a recent row update token opens the edit server dialog for its server',
      (tester) async {
        final nas = HostedServerFixture(storeToken: false);
        final r = PickerRobot(
          await pumpJourneyApp(
            tester,
            servers: [nas],
            recents: [seedHostedRef],
          ),
        );
        expect(r.recentUpdateToken(0), findsOneWidget);

        await r.tap(r.recentUpdateToken(0));

        r.expectEditServerDialog('nas', fakeServerUrl);
      },
    );

    testWidgets(
      'the banner update token opens the edit server dialog for the open vault server',
      (tester) async {
        final (r, w) = await _hostedWorkspace(tester);
        r.app.first.server.token = 'rotated-on-the-server';
        await r.app.pollTick();
        expect(w.unauthorizedBanner, findsOneWidget);

        await w.tap(w.bannerUpdateToken);

        r.expectEditServerDialog('nas', fakeServerUrl);
      },
    );

    testWidgets(
      'a vault pill update token opens the edit server dialog for that pill server',
      (tester) async {
        final studio = journeyStudio(storeToken: false);
        final (r, w) = await _hostedWorkspace(
          tester,
          servers: [HostedServerFixture(), studio],
          extraRecents: [studio.ref('work')],
        );

        await w.tap(w.pill(studio.id, 'work'));
        expect(w.pillSnackbar, findsOneWidget);
        await w.tap(
          find.descendant(
            of: w.pillSnackbar,
            matching: find.text('update token'),
          ),
        );

        r.expectEditServerDialog('studio', 'http://studio.local:9000');
      },
    );

    testWidgets(
      'the open dialog update token opens the edit server dialog for the selected server',
      (tester) async {
        final r = PickerRobot(
          await pumpJourneyApp(
            tester,
            servers: [HostedServerFixture(storeToken: false)],
          ),
        );
        await r.tap(r.openOnServer);
        expect(r.serverDialogUpdateToken, findsOneWidget);

        await r.tap(r.serverDialogUpdateToken);

        r.expectEditServerDialog('nas', fakeServerUrl);
      },
    );
  });

  group('entry points open the set up sheet (AC2)', () {
    for (final (name, open)
        in <(String, Future<PickerRobot> Function(WidgetTester))>[
          (
            'the connect dialog how do I set one up opens the set up sheet',
            (tester) async {
              final r = await _pickerWithNas(tester);
              await r.tap(r.serversConnect);
              await r.tap(r.connectSetUpLink);
              return r;
            },
          ),
          (
            'the no servers how do I set one up opens the set up sheet',
            (tester) async {
              final r = await _pickerWithNoServers(tester);
              await r.tap(r.noServersSetUp);
              return r;
            },
          ),
          (
            'the refusal set up a vault server opens the set up sheet',
            (tester) async {
              final r = await _networkDriveRefusal(tester);
              await r.tap(r.networkRefusalSetUp);
              expect(r.networkRefusal, findsNothing);
              return r;
            },
          ),
        ]) {
      testWidgets(name, (tester) async {
        final r = await open(tester);
        expect(r.setUpSheet, findsOneWidget);
        expect(find.text('SET UP A VAULT SERVER'), findsOneWidget);
      });
    }
  });
}
