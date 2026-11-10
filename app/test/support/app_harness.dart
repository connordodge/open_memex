import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'token_store_fakes.dart';

/// C2.11 stdout sample for `memex settings get --key smart_folder_max_depth`.
const settingsGetMaxDepthStdout =
    '{"vault_id":"01HV0000000000000000000000","key":"smart_folder_max_depth","value":2}';

/// Everything a journey needs after [pumpWorkspace].
class WorkspaceHarness {
  WorkspaceHarness({
    required this.container,
    required this.db,
    required this.cli,
    required this.clock,
    required this.vaultPath,
  });

  final ProviderContainer container;
  final FakeVaultDb db;

  /// The fake CLI. When the harness was pumped with `memexConfigured: false`
  /// it is not wired into `memexCliProvider` (which is null) and records
  /// nothing.
  final FakeMemexCli cli;
  final FakeClock clock;

  /// A temp dir standing in for the open vault (`currentVaultProvider`).
  final String vaultPath;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pump the whole app (router → Workspace) with test seams (D20, D14):
/// SharedPreferences mock settings, a temp-dir `currentVaultProvider`, a
/// [FakeVaultDb] for `vaultDbProvider`, a [FakeMemexCli] for
/// `memexCliProvider` (null when [memexConfigured] is false: no `memex`
/// binary configured) and a [FakeClock] for `clockProvider`.
///
/// Defaults: a fresh V5 [FakeVaultDb], a [FakeMemexCli] whose only handler
/// answers `settings get` with the C2.11 sample, and a [FakeClock] at
/// 2026-10-03 09:00 local. A caller-supplied [cli] gets no default handlers.
/// [overrides] are appended to the seams (e.g. `leaveVaultGuardProvider`);
/// they must not repeat a provider the harness already overrides.
Future<WorkspaceHarness> pumpWorkspace(
  WidgetTester tester, {
  FakeVaultDb? db,
  FakeMemexCli? cli,
  FakeClock? clock,
  bool memexConfigured = true,
  Size surfaceSize = const Size(1600, 1000),
  List<Override> overrides = const [],
}) async {
  final vaultDir = Directory.systemTemp.createTempSync('omv');
  final fakeDb = db ?? FakeVaultDb.v5();
  final fakeCli =
      cli ??
      (FakeMemexCli()..on(
        'settings get',
        (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
      ));
  final fakeClock = clock ?? FakeClock();

  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': <String>[vaultDir.path],
    'memex.last_vault': vaultDir.path,
  });
  final settings = await loadSettingsKeepingPickedBinary();

  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  // The test font draws every glyph 1em wide, far wider than Inter Tight, so
  // the fixed-width sidebar and right panel overflow at scale 1. Shrink text
  // so layout matches the real app's proportions; robots find widgets by Key.
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;

  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      currentVaultProvider.overrideWith((_) => LocalVaultRef(vaultDir.path)),
      vaultDbProvider.overrideWithValue(fakeDb),
      memexCliProvider.overrideWithValue(memexConfigured ? fakeCli : null),
      clockProvider.overrideWithValue(fakeClock),
      ...overrides,
    ],
  );

  // Teardowns run last-registered-first: dispose the tree's container, then
  // close the database, then remove the temp vault dir.
  addTearDown(() => _deleteQuietly(vaultDir));
  addTearDown(fakeDb.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OpenMemexApp(),
    ),
  );
  await pumpFrames(tester);

  return WorkspaceHarness(
    container: container,
    db: fakeDb,
    cli: fakeCli,
    clock: fakeClock,
    vaultPath: vaultDir.path,
  );
}

/// Pump a bounded number of frames so futures (fake CLI calls, provider
/// rebuilds) complete. Never use `pumpAndSettle` on the workspace: `OmDot`'s
/// pulse animation repeats forever, so it never settles.
Future<void> pumpFrames(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Best-effort removal of the temp vault. `TabsNotifier` persists tabs with
/// fire-and-forget writes into `<vault>/.memex/` that a test cannot await, so
/// a write may land while the dir is being deleted (errno 66, "Directory not
/// empty"). Retry, then give up silently: a leftover temp dir must not fail
/// the test.
void _deleteQuietly(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // A queued UiStateStore write raced the delete; try again.
    }
  }
}
