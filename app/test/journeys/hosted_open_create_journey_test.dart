// WI #105 (F1) AC4: open and create a vault on a server, starting with no
// saved server (Req 42, 44, 45; boards A6/A7). "open vault on a server…"
// and "create vault on a server…" first go through the connect dialog, then
// continue into #99's dialog on the new server; picking or creating a vault
// opens it in the workspace and puts it first in RECENT. The real app runs
// over the journey harness; the vault server is a fake that is not saved
// until the connect succeeds.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/picker_robot.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/font_fetch_hold.dart';

const _token = 'fresh-token-105';

/// The picker with no saved server and the vault server [server] (serving
/// [vaultName]'s fixtures) reachable at nas's URL but not saved.
Future<(PickerRobot, HostedServerFixture)> _noSavedServer(
  WidgetTester tester, {
  String vaultName = 'seed',
}) async {
  final app = await pumpJourneyApp(tester);
  final server = HostedServerFixture(token: _token, vaultName: vaultName);
  app.router.servers.add(server.server);
  return (PickerRobot(app), server);
}

/// Connects to nas from the connect dialog an action opened.
Future<SavedServer> _connectNas(PickerRobot r) async {
  r.expectConnectDialog();
  await r.connectWith(name: 'nas', url: fakeServerUrl, token: _token);
  expect(r.connectDialog, findsNothing);
  return r.app.settings.savedServers.single;
}

void _expectOpened(PickerRobot r, HostedVaultRef ref) {
  expect(r.app.read(currentVaultProvider), ref);
  expect(find.byType(Workspace), findsOneWidget);
  expect(r.openDialog, findsNothing);
  expect(r.createDialog, findsNothing);
  expect(r.app.settings.recentRefs.first, ref);
}

void main() {
  holdFontFetches();

  group('open on a server (AC4)', () {
    testWidgets(
      'open vault on a server with no saved server connects then shows loading then the list and opens the picked vault into RECENT',
      (tester) async {
        final (r, server) = await _noSavedServer(tester);
        // Hold the server once the connect saved it: the list request the
        // open dialog sends next stays in flight.
        var held = false;
        r.app.container.listen<AppSettings>(settingsProvider, (_, next) {
          if (held || next.savedServers.isEmpty) return;
          held = true;
          server.server.hold();
        });

        await r.tap(r.openOnServer);
        final saved = await _connectNas(r);

        expect(r.openDialog, findsOneWidget);
        expect(r.shows(r.openDialog, 'loading vaults on nas…'), isTrue);
        expect(r.openVaultRow('seed'), findsNothing);

        server.server.release();
        await r.app.settle();
        expect(r.openVaultRow('seed'), findsOneWidget);

        await r.tap(r.openVaultRow('seed'));
        await r.tap(r.openButton);

        _expectOpened(r, HostedVaultRef(saved.id, 'seed'));
      },
    );

    testWidgets(
      'an empty server shows no vaults on the server yet and its create button creates and opens the vault',
      (tester) async {
        final (r, server) = await _noSavedServer(tester, vaultName: 'work');
        server.server.route('GET', '/api/v1/vaults', json: {'vaults': []});

        await r.tap(r.openOnServer);
        final saved = await _connectNas(r);

        expect(r.shows(r.openDialog, 'no vaults on nas yet'), isTrue);
        await r.tap(r.openEmptyCreate);
        expect(r.createDialog, findsOneWidget);
        server.server.route(
          'POST',
          '/api/v1/vaults',
          status: 201,
          json: {'name': 'work', 'vault_id': '01M5DK9Z8CWPQGFA893JX9VRZF'},
        );
        await r.enter(r.createName, 'work');
        await r.tap(r.createSubmit);

        _expectOpened(r, HostedVaultRef(saved.id, 'work'));
      },
    );
  });

  group('create on a server (AC4)', () {
    testWidgets(
      'create vault on a server with no saved server connects then shows both name errors and opens the vault with a valid name',
      (tester) async {
        final (r, server) = await _noSavedServer(tester, vaultName: 'work');

        await r.tap(r.createOnServer);
        final saved = await _connectNas(r);
        expect(r.createDialog, findsOneWidget);

        server.server.route(
          'POST',
          '/api/v1/vaults',
          status: 400,
          json: {
            'error': {
              'code': 'invalid_vault_name',
              'message':
                  'vault names use letters, digits, - and _ (1-64 characters)',
            },
          },
        );
        await r.enter(r.createName, '../x');
        await r.tap(r.createSubmit);
        expect(
          r.shows(
            r.createDialog,
            'use letters, digits, - and _ (1–64 characters)',
          ),
          isTrue,
        );

        server.server.route(
          'POST',
          '/api/v1/vaults',
          status: 409,
          json: {
            'error': {
              'code': 'vault_exists',
              'message': 'a vault named SEED already exists',
            },
          },
        );
        await r.enter(r.createName, 'SEED');
        await r.tap(r.createSubmit);
        expect(
          r.shows(r.createDialog, 'a vault named SEED already exists on nas'),
          isTrue,
        );
        expect(r.app.read(currentVaultProvider), isNull);

        server.server.route(
          'POST',
          '/api/v1/vaults',
          status: 201,
          json: {'name': 'work', 'vault_id': '01M5DK9Z8CWPQGFA893JX9VRZF'},
        );
        await r.enter(r.createName, 'work');
        await r.tap(r.createSubmit);

        _expectOpened(r, HostedVaultRef(saved.id, 'work'));
        expect(
          server.server.requests.where(
            (q) => q.method == 'POST' && q.url.path == '/api/v1/vaults',
          ),
          hasLength(3),
        );
      },
    );
  });
}
