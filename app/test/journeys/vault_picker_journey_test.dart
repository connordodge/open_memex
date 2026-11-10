// WI #363 (Spec #357 Req 1, 2, 26, Testing Strategy 3, 5; flows F1, F2, F3):
// the vault picker reached from the sidebar, end to end over the real app
// (`pumpJourneyApp`: default seams; only Trash, Finder, the vault servers,
// prefs and the `memex` binary are faked). Two robot journeys:
// 1. MANAGE -> the modal over the open vault -> delete the open vault from
//    its row -> the full-screen picker without it.
// 2. a pill right-click -> manage… -> another vault's row -> that vault is
//    open and the modal closed.
// Robots: VaultSidebarRobot (sidebar, pill menu, delete dialog) and
// PickerRobot (picker and modal). Temp vault folders only.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';

import '../robots/picker_robot.dart';
import '../robots/vault_sidebar_robot.dart';
import '../support/fake_file_revealer.dart';
import '../support/fake_vault_db.dart';
import '../support/api_fixtures.dart';
import '../support/fake_vault_server.dart';
import '../support/fake_vault_trash.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/wi361_rows.dart';

/// The journeys' world: the local `memex` open (the last vault), with the
/// local `work-notes` and the hosted `seed` on nas in the recents.
class _World {
  _World(this.app, this.trash, this.memex, this.workNotes);

  final JourneyApp app;
  final FakeVaultTrash trash;
  final String memex;
  final String workNotes;

  late final sidebar = VaultSidebarRobot(app);
  late final picker = PickerRobot(app);

  AppSettings get settings => app.settings;
}

Future<_World> _launch(WidgetTester tester) async {
  final memex = wi361VaultNamed('memex');
  final workNotes = wi361VaultNamed('work-notes');
  final trash = FakeVaultTrash();
  final app = await pumpJourneyApp(
    tester,
    servers: [HostedServerFixture()],
    db: FakeVaultDb.v5(),
    recents: [LocalVaultRef(memex), LocalVaultRef(workNotes), seedHostedRef],
    lastVault: LocalVaultRef(memex),
    overrides: [
      vaultTrashProvider.overrideWithValue(trash),
      fileRevealerProvider.overrideWithValue(FakeFileRevealer()),
    ],
  );
  // Flush each vault's queued UI state before its temp folder goes.
  addTearDown(() => UiStateStore(vaultPath: memex).flush());
  addTearDown(() => UiStateStore(vaultPath: workNotes).flush());
  await app.settle();
  expect(
    app.read(currentVaultProvider),
    LocalVaultRef(memex),
    reason: 'launch opened memex',
  );
  return _World(app, trash, memex, workNotes);
}

/// The index of the modal's RECENT row showing [name].
int _modalRowOf(PickerRobot r, String name) {
  for (var i = 0; i < 8; i++) {
    if (r.modalRecentRow(i).evaluate().isEmpty) break;
    if (r.within(r.modalRecentRow(i), find.text(name)).evaluate().isNotEmpty) {
      return i;
    }
  }
  fail('no RECENT row in the modal shows $name');
}

void main() {
  holdFontFetches();

  testWidgets(
    'journey MANAGE then delete the open vault from its modal row ends on the full screen picker without it',
    (tester) async {
      final w = await _launch(tester);
      final s = w.sidebar;
      final r = w.picker;

      // F1.1 -> F1.2: MANAGE opens the modal over the open vault.
      await s.pressManage();
      r.expectModalOpen(openName: 'memex');
      expect(w.app.read(currentVaultProvider), LocalVaultRef(w.memex));

      // The open vault's row: delete -> the dialog says it is open.
      await r.deleteRecentInModal(0);
      expect(s.deleteOpenLine, findsOneWidget);
      await s.confirmDelete();

      // F2.5: the full-screen picker, without memex.
      expect(w.trash.calls, [w.memex]);
      expect(w.app.read(currentVaultProvider), isNull);
      r.expectModalClosed();
      expect(s.manage, findsNothing, reason: 'the sidebar is gone');
      expect(r.openLocal, findsOneWidget, reason: 'the full-screen picker');
      expect(r.recentRow(0), findsOneWidget);
      expect(r.within(r.recentRow(0), find.text('work-notes')), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(
          r.within(r.recentRow(i), find.text('memex')),
          findsNothing,
          reason: 'memex is not listed',
        );
      }
      expect(w.settings.recentRefs, isNot(contains(LocalVaultRef(w.memex))));
      expect(w.settings.lastVaultRef, isNull);
    },
  );

  testWidgets(
    'journey pill right click then manage then another row opens that vault and closes the modal',
    (tester) async {
      final w = await _launch(tester);
      final s = w.sidebar;
      final r = w.picker;

      // F2.1 -> F2.2: the hosted seed pill's menu (not open): remove from
      // recents, then manage….
      await s.openMenu(s.hostedPill(fakeServerId, seedVaultName));
      expect(s.menuShown, ['vault-menu-remove', 'vault-menu-manage']);

      // F3.1: manage… opens the modal over memex.
      await s.chooseManage();
      expect(s.menuShown, isEmpty, reason: 'the menu closed');
      r.expectModalOpen(openName: 'memex');
      expect(w.app.read(currentVaultProvider), LocalVaultRef(w.memex));

      // Another vault's row: work-notes opens and the modal closes.
      await r.openRecentInModal(_modalRowOf(r, 'work-notes'));
      for (var i = 0; i < 3; i++) {
        await w.app.settle();
      }

      expect(w.app.read(currentVaultProvider), LocalVaultRef(w.workNotes));
      expect(w.settings.lastVaultRef, LocalVaultRef(w.workNotes));
      r.expectModalClosed();
      expect(s.manage, findsOneWidget, reason: 'the workspace shows');
      expect(w.trash.calls, isEmpty);
    },
  );
}
