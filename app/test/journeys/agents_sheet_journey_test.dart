// WI #408 (EP; Spec #394 req 2-6, 10; testing strategy "Journey test"): the
// Agents sheet opens from all three entry points in the running app. The
// real OpenMemexApp launches through the picker, which reopens a real temp
// local vault (FakeVaultDb, FakeMemexCli). Its `VaultAccess.agents` is a
// FakeAgentsAccess, and the app clock is the FakeClock it is relative to:
// - no agents: each of the footer `OPEN ↗` link, the status bar
//   `agents ⇧⌘A` button and an `openAgents` delivered through
//   FakeWindowMenuHost opens the sheet on Connect;
// - one faked presence record: each opens it on Live.
// Window ▸ Agents… is enabled once the vault is open (#408 enablement).
// The robot finds widgets by Key only.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../robots/agents_sheet_robot.dart';
import '../support/agents_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';
import '../support/window_menu_fakes.dart';

/// Launches the app on a fresh local vault whose agents domain answers
/// [activity] (no agents when null), and returns the robot.
Future<AgentsSheetRobot> _wi408Launch(
  WidgetTester tester, {
  AgentActivity? activity,
}) async {
  final vault = createVaultFolder('om408_journey_');
  final ref = LocalVaultRef(vault.path);
  final agents = FakeAgentsAccess(vaultPath: vault.path, script: [?activity]);
  final menu = FakeWindowMenuHost();
  final app = await pumpJourneyApp(
    tester,
    db: FakeVaultDb.v5(),
    // agentPresence() times are relative to the default FakeClock start.
    clock: FakeClock(),
    recents: [ref],
    lastVault: ref,
    overrides: [
      windowMenuHostProvider.overrideWithValue(menu),
      vaultAccessProvider.overrideWith((r) {
        final path = r.watch(currentVaultProvider).localPath;
        if (path == null) return null;
        return LocalVaultAccess(
          vaultPath: path,
          db: r.watch(vaultDbProvider),
          cli: r.watch(memexCliProvider),
          agents: agents,
        );
      }),
    ],
  );
  expect(app.read(currentVaultProvider), ref, reason: 'launch reopened it');
  return AgentsSheetRobot(app, menu);
}

/// Each entry point in turn, closing the sheet between them, expecting the
/// sheet to open on [tab] every time.
Future<void> _wi408OpenFromEveryEntryPoint(
  AgentsSheetRobot robot, {
  required String tab,
}) async {
  // The vault is open, so Window ▸ Agents… is enabled.
  expect(robot.menu.enabled, isTrue, reason: 'menu enabled with a vault');
  expect(robot.menu.isAttached, isTrue);

  await robot.openFromFooter();
  expect(robot.activeTab, tab, reason: 'from the footer');
  await robot.closeSheet();

  await robot.openFromStatusBar();
  expect(robot.activeTab, tab, reason: 'from the status bar');
  await robot.closeSheet();

  await robot.openFromWindowMenu();
  expect(robot.activeTab, tab, reason: 'from Window ▸ Agents…');
  await robot.closeSheet();

  expect(robot.menu.openAgentsDelivered, 1);
}

void main() {
  holdFontFetches();

  testWidgets(
    'with no agents connected the footer OPEN link the status bar button and Window Agents each open the sheet on Connect',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final robot = await _wi408Launch(tester);
      await _wi408OpenFromEveryEntryPoint(robot, tab: 'connect');
      semantics.dispose();
    },
  );

  testWidgets(
    'with one faked presence record the footer OPEN link the status bar button and Window Agents each open the sheet on Live',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final robot = await _wi408Launch(
        tester,
        activity: AgentActivity(
          agents: [
            agentPresence(
              clientName: 'claude-desktop',
              expiresAt: agentsT0 + 3600000,
            ),
          ],
          recent: [agentEntry(clientName: 'claude-desktop')],
          available: true,
        ),
      );
      await _wi408OpenFromEveryEntryPoint(robot, tab: 'live');
      semantics.dispose();
    },
  );
}
