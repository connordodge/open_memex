// WI #105 (F1) AC5: picker journeys on the real app (boards A2/A3, Req 40,
// 46). Removing a saved server asks first, then deletes its token from the
// fake token store, drops the server and its hosted RECENT rows and keeps
// every other row. With no `memex` binary the local actions are disabled
// and local rows don't open, while a hosted row still opens its vault.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../robots/picker_robot.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';
import '../support/font_fetch_hold.dart';

void main() {
  holdFontFetches();

  group('remove server (AC5)', () {
    testWidgets(
      'removing a server asks with the board copy then deletes its token and its hosted recents and keeps the other rows',
      (tester) async {
        final local = createVaultFolder('om105_keep_');
        final studio = journeyStudio();
        final work = studio.ref('work');
        final app = await pumpJourneyApp(
          tester,
          servers: [HostedServerFixture(), studio],
          recents: [seedHostedRef, LocalVaultRef(local.path), work],
        );
        final r = PickerRobot(app);
        expect(app.tokens.tokens.keys, containsAll([fakeServerId, studio.id]));

        await r.tap(r.serverRemove(fakeServerId));

        expect(find.text('REMOVE SERVER'), findsOneWidget);
        expect(find.text('remove nas?'), findsOneWidget);
        expect(
          find.text(
            'its vaults leave your recents. nothing on the server is touched.',
          ),
          findsOneWidget,
        );
        await r.tap(r.removeConfirm);

        expect(app.tokens.tokens.keys, [studio.id]);
        expect(app.settings.savedServers.map((s) => s.id), [studio.id]);
        expect(r.serverRow(fakeServerId), findsNothing);
        expect(r.serverRow(studio.id), findsOneWidget);
        expect(app.settings.recentRefs, [LocalVaultRef(local.path), work]);
        expect(find.text('seed'), findsNothing);
        expect(
          r.inside('recent-row-0', find.text(p.basename(local.path))),
          findsOneWidget,
        );
        expect(r.inside('recent-row-1', find.text('work')), findsOneWidget);
        expect(
          app.first.server.requests.where((q) => q.method != 'GET'),
          isEmpty,
          reason: 'nothing on the server is touched',
        );
      },
    );

    testWidgets('cancel in the remove confirm keeps the server and its token', (
      tester,
    ) async {
      final app = await pumpJourneyApp(
        tester,
        servers: [HostedServerFixture()],
        recents: [seedHostedRef],
      );
      final r = PickerRobot(app);

      await r.tap(r.serverRemove(fakeServerId));
      await r.tap(r.removeCancel);

      expect(app.tokens.tokens.keys, [fakeServerId]);
      expect(app.settings.recentRefs, [seedHostedRef]);
      expect(r.serverRow(fakeServerId), findsOneWidget);
    });
  });

  group('binary not found (AC5)', () {
    testWidgets(
      'with no memex binary the local actions are disabled and a local row needs the binary and does not open',
      (tester) async {
        final local = createVaultFolder('om105_nobin_');
        final app = await pumpJourneyApp(
          tester,
          binary: false,
          servers: [HostedServerFixture()],
          recents: [LocalVaultRef(local.path), seedHostedRef],
        );
        final r = PickerRobot(app);

        expect(find.text('memex binary not found'), findsOneWidget);
        expect(r.button('vault-picker-create').onPressed, isNull);
        expect(r.button('vault-picker-open').onPressed, isNull);
        expect(
          r.inside('recent-row-0', find.text('needs the memex binary')),
          findsOneWidget,
        );

        await r.tap(r.recentRow(0));

        expect(app.read(currentVaultProvider), isNull);
        expect(find.byType(Workspace), findsNothing);
      },
    );

    testWidgets(
      'with no memex binary a hosted recent row still opens its vault',
      (tester) async {
        final local = createVaultFolder('om105_nobin_');
        final app = await pumpJourneyApp(
          tester,
          binary: false,
          servers: [HostedServerFixture()],
          recents: [LocalVaultRef(local.path), seedHostedRef],
        );
        final r = PickerRobot(app);
        expect(
          r.inside('recent-row-1', find.text('needs the memex binary')),
          findsNothing,
        );

        await r.tap(r.recentRow(1));

        expect(app.read(currentVaultProvider), seedHostedRef);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });
}
