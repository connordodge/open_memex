// WI #105 (F1) AC11: a hosted last vault that can't open at launch leaves
// the picker showing why on its RECENT row (Req 47, L7, L18; board A3),
// with hosted vaults on by default: unreachable with "retry" (which opens
// it once the server answers), 401 with "update token", an api_version
// mismatch that doesn't open, vault not found with removal, and a schema the
// server refuses (its error text) that doesn't open.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/picker_robot.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

/// Launches with seed on [nas] as the last vault; the launch reopen fails
/// and the picker shows.
Future<PickerRobot> _launch(
  WidgetTester tester,
  HostedServerFixture nas,
) async {
  final app = await pumpJourneyApp(
    tester,
    servers: [nas],
    recents: [seedHostedRef],
    lastVault: seedHostedRef,
  );
  await app.settle();
  expect(find.byType(VaultPickerScreen), findsOneWidget);
  expect(app.read(currentVaultProvider), isNull);
  return PickerRobot(app);
}

void _expectRowSays(PickerRobot r, String text) =>
    expect(r.inside('recent-row-0', find.text(text)), findsOneWidget);

Future<void> _expectRowDoesNotOpen(PickerRobot r) async {
  await r.tap(r.recentRow(0));
  expect(r.app.read(currentVaultProvider), isNull);
  expect(find.byType(Workspace), findsNothing);
}

void main() {
  wi97HoldFontFetches();

  group('launch outcomes on the RECENT row (AC11)', () {
    testWidgets(
      'an unreachable last vault shows cant reach nas with retry and retry opens it once nas answers',
      (tester) async {
        final nas = HostedServerFixture();
        nas.server.failure = FakeServerFailure.refused;
        final r = await _launch(tester, nas);

        _expectRowSays(r, "can't reach nas");
        expect(r.recentRetry(0), findsOneWidget);

        nas.server.failure = null;
        await r.tap(r.recentRetry(0));

        expect(r.app.read(currentVaultProvider), seedHostedRef);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    testWidgets(
      'a last vault whose token is rejected shows the danger row with update token',
      (tester) async {
        final nas = HostedServerFixture();
        nas.server.token = 'rotated-on-the-server';
        final r = await _launch(tester, nas);

        _expectRowSays(r, 'nas rejected the access token');
        expect(r.recentUpdateToken(0), findsOneWidget);
        await r.tap(r.recentUpdateToken(0));
        r.expectEditServerDialog('nas', fakeServerUrl);
      },
    );

    testWidgets(
      'a last vault on a server with another api version shows the L9 message and does not open',
      (tester) async {
        final nas = HostedServerFixture();
        nas.server.route(
          'GET',
          '/api/v1/info',
          json: {'api_version': 2, 'server_version': '0.9.0'},
        );
        final r = await _launch(tester, nas);

        _expectRowSays(
          r,
          "nas runs memex 0.9.0, which this app can't use. update the app or "
          'memex on the server so both are the same release.',
        );
        await _expectRowDoesNotOpen(r);
      },
    );

    testWidgets(
      'a last vault no longer on its server says so and offers removal from recents',
      (tester) async {
        final nas = HostedServerFixture();
        nas.server.removeVault('seed');
        final r = await _launch(tester, nas);

        _expectRowSays(r, 'seed is no longer on nas');
        await r.tap(r.recentRemoveFromRecents(0));
        expect(r.app.settings.recentRefs, isEmpty);
      },
    );

    testWidgets(
      'a last vault whose schema the server refuses shows the server error text and does not open',
      (tester) async {
        const refused = 'schema version unsupported: db=7, app=5';
        final nas = HostedServerFixture();
        nas.server.route(
          'GET',
          '/vaults/seed/api/v1/info',
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': refused},
          },
        );
        final r = await _launch(tester, nas);

        expect(
          r.inside('recent-row-0', find.textContaining(refused)),
          findsOneWidget,
        );
        await _expectRowDoesNotOpen(r);
      },
    );
  });
}
