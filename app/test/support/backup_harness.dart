// WI #321 (A0, D19): the one pump helper every backup WI uses (A1-A6). A0
// only: nobody else edits it. It wires a ProviderScope (or a bare container)
// with a FakeClock (no real timer is ever created: time moves only with
// `clock.advance`), a FakeMemexCli, mock SharedPreferences, a FakeTokenStore
// and every backup fake. No real `memex`, network, Keychain or `~/Library`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_fakes.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'token_store_fakes.dart';

/// Everything a backup test drives and inspects.
class BackupHarness {
  BackupHarness({
    required this.container,
    required this.clock,
    required this.cli,
    required this.runner,
    required this.reader,
    required this.hostedApi,
    required this.probe,
    required this.controller,
  });

  final ProviderContainer container;

  /// Manual time. Nothing fires until `clock.advance`.
  final FakeClock clock;

  /// Behind `memexCliProvider`. Registers no handlers: the runner fake sits
  /// above it, so a test of the real `CliBackupRunner` registers its own.
  final FakeMemexCli cli;

  final FakeBackupRunner runner;
  final FakeBackupStateReader reader;
  final FakeHostedBackupApi hostedApi;
  final FakeCloudFolderProbe probe;

  /// The fake behind `backupControllerProvider`; null when the harness was
  /// built with `realController: true` (the live controller runs over the
  /// other fakes).
  final FakeBackupController? controller;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Builds the harness: a container with an override for every backup seam. [prefs] seeds mock
/// SharedPreferences (the `memex.binary_path` of the fake binary is always
/// present). [realController] leaves `backupControllerProvider` to the live
/// controller (A3's tests); otherwise a [FakeBackupController] answers (an
/// injected [controller] always wins). [noHostedApi] makes
/// `hostedBackupApiProvider` answer null, as it does when no hosted vault is
/// open: [BackupHarness.hostedApi] is then a fake nothing is wired to, so its
/// `calls` stay empty. [overrides] are appended after every harness override
/// (a test's own win): the way to override providers the harness does not
/// know (the sidebar's, a vault's), so no filler needs to bypass it.
Future<BackupHarness> _build({
  FakeClock? clock,
  FakeBackupRunner? runner,
  FakeBackupStateReader? reader,
  FakeHostedBackupApi? hostedApi,
  FakeCloudFolderProbe? probe,
  FakeMemexCli? cli,
  FakeBackupController? controller,
  bool realController = false,
  bool noHostedApi = false,
  List<Override> overrides = const [],
  VaultRef? vault,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    ...prefs,
  });
  final settings = await SettingsController.load(tokenStore: FakeTokenStore());
  final fakeClock = clock ?? FakeClock();
  final fakeCli = cli ?? FakeMemexCli();
  final fakeRunner = runner ?? FakeBackupRunner();
  final fakeReader = reader ?? FakeBackupStateReader();
  final fakeApi = hostedApi ?? FakeHostedBackupApi();
  final fakeProbe = probe ?? FakeCloudFolderProbe();
  // An injected controller always wins over `realController`.
  final fakeController = realController && controller == null
      ? null
      : (controller ?? FakeBackupController());
  final allOverrides = <Override>[
    settingsProvider.overrideWith((_) => settings),
    clockProvider.overrideWithValue(fakeClock),
    memexCliProvider.overrideWithValue(fakeCli),
    backupRunnerProvider.overrideWithValue(fakeRunner),
    backupStateReaderProvider.overrideWithValue(fakeReader),
    hostedBackupApiProvider.overrideWithValue(noHostedApi ? null : fakeApi),
    cloudFolderProbeProvider.overrideWithValue(fakeProbe),
    if (fakeController != null)
      backupControllerProvider.overrideWith((_) => fakeController),
    if (vault != null) currentVaultProvider.overrideWith((_) => vault),
    // Last, so a test's own override wins over the harness's.
    ...overrides,
  ];
  return BackupHarness(
    container: ProviderContainer(overrides: allOverrides),
    clock: fakeClock,
    cli: fakeCli,
    runner: fakeRunner,
    reader: fakeReader,
    hostedApi: fakeApi,
    probe: fakeProbe,
    controller: fakeController,
  );
}

/// A bare [ProviderContainer] with every backup seam in place, for
/// non-widget tests (the live controller's schedule, the settings, the
/// destination discovery). Disposed at test end.
///
/// [vault] is the open vault (`currentVaultProvider`), if the test needs one.
/// Pass a [clock] to start time somewhere else than the FakeClock default.
Future<BackupHarness> createBackupContainer({
  FakeClock? clock,
  FakeBackupRunner? runner,
  FakeBackupStateReader? reader,
  FakeHostedBackupApi? hostedApi,
  FakeCloudFolderProbe? probe,
  FakeMemexCli? cli,
  FakeBackupController? controller,
  bool realController = true,
  bool noHostedApi = false,
  List<Override> overrides = const [],
  VaultRef? vault,
  Map<String, Object> prefs = const {},
}) async {
  final harness = await _build(
    clock: clock,
    runner: runner,
    reader: reader,
    hostedApi: hostedApi,
    probe: probe,
    cli: cli,
    controller: controller,
    realController: realController,
    noHostedApi: noHostedApi,
    overrides: overrides,
    vault: vault,
    prefs: prefs,
  );
  addTearDown(harness.container.dispose);
  return harness;
}

/// Pumps [child] (inside a MaterialApp, so dialogs and sheets work) under a
/// ProviderScope with every backup seam in place. Returns the harness. Use
/// `tester.pump(duration)` to step frames: never `pumpAndSettle` on a screen
/// with a repeating animation.
///
/// By default `backupControllerProvider` is a [FakeBackupController]
/// (`harness.controller`); pass `realController: true` to run the live one.
Future<BackupHarness> pumpBackupWidget(
  WidgetTester tester,
  Widget child, {
  FakeClock? clock,
  FakeBackupRunner? runner,
  FakeBackupStateReader? reader,
  FakeHostedBackupApi? hostedApi,
  FakeCloudFolderProbe? probe,
  FakeMemexCli? cli,
  FakeBackupController? controller,
  bool realController = false,
  bool noHostedApi = false,
  List<Override> overrides = const [],
  VaultRef? vault,
  Map<String, Object> prefs = const {},
  Size surfaceSize = const Size(1200, 900),
}) async {
  final harness = await _build(
    clock: clock,
    runner: runner,
    reader: reader,
    hostedApi: hostedApi,
    probe: probe,
    cli: cli,
    controller: controller,
    realController: realController,
    noHostedApi: noHostedApi,
    overrides: overrides,
    vault: vault,
    prefs: prefs,
  );
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(harness.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
  return harness;
}
