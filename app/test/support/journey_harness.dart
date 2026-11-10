// WI #105 (F1): the end-to-end journey harness. It pumps the real
// `OpenMemexApp` (router: picker or workspace) with every product seam at
// its default, so the picker actions, the dialogs, the banners' seams and
// the unsent-text seams are the ones the app binds. Only the outside world
// is faked:
// - vault servers: FakeVaultServers behind one FakeVaultServerRouter, for
//   the hosted access, the connect/edit dialogs and the open/create dialogs;
// - the Keychain: a FakeTokenStore shared by settings and tokenStoreProvider;
// - SharedPreferences: the mock, seeded with hostedPrefs;
// - time: a FakeClock (2 s / 30 s polls, 10 s timeouts);
// - the `memex` binary: FakeMemexCli (or none), picked by the configured
//   binary path when [pumpJourneyApp] gets `clis`;
// - app focus, app exit and the native window title.
// No rollout flag exists: hosted vaults are on.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/app_support_dir.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/revision_poller.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/widgets/hosted/connect_server_dialog.dart';
import 'package:open_memex_app/src/widgets/hosted/server_select.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_exit_fakes.dart';
import 'app_harness.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'fake_vault_server.dart';
import 'hosted_harness.dart';
import 'poll_fakes.dart';
import 'token_store_fakes.dart';

/// A second vault server for journeys that need two (A2's studio-mini).
HostedServerFixture journeyStudio({bool storeToken = true}) =>
    HostedServerFixture(
      id: 'srv-studio',
      name: 'studio',
      url: 'http://studio.local:9000',
      token: 'studio-token-105',
      storeToken: storeToken,
      vaultName: 'work',
    );

/// Everything a journey needs after [pumpJourneyApp].
class JourneyApp {
  JourneyApp._({
    required this.tester,
    required this.container,
    required this.servers,
    required this.router,
    required this.tokens,
    required this.clock,
    required this.appSupport,
    required this.windowTitle,
    required this.exitHost,
  });

  final WidgetTester tester;
  final ProviderContainer container;

  /// The saved servers' fixtures, in saved order.
  final List<HostedServerFixture> servers;

  /// Routes every app request (hosted access, probes, dialogs) to the fake
  /// whose origin it is sent to. [addUnsavedServer] adds to it.
  final FakeVaultServerRouter router;
  final FakeTokenStore tokens;
  final FakeClock clock;
  final Directory appSupport;
  final RecordingWindowTitle windowTitle;
  final FakeAppExitHost exitHost;

  HostedServerFixture get first => servers.first;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  AppSettings get settings => read(settingsProvider);

  VaultOpenController get controller => read(vaultOpenControllerProvider);

  FakeAppFocus get focus => read(appFocusProvider.notifier) as FakeAppFocus;

  HostedConnectionStatus? status(String serverId) =>
      read(hostedConnectionStatusProvider(serverId));

  /// A vault server that is not saved yet (a connect journey's target),
  /// reachable at [url] and accepting [token].
  FakeVaultServer addUnsavedServer({
    String url = fakeServerUrl,
    String token = fakeServerToken,
    bool seeded = true,
  }) {
    final server = FakeVaultServer(token: token, url: url);
    if (seeded) {
      for (final d in hostedFixtureDomains) {
        server.serveDomain(d);
      }
    }
    router.servers.add(server);
    return server;
  }

  /// Lets real-async work (prefs, UI-state files, fake server answers)
  /// land, then draws.
  Future<void> settle() => settleHosted(tester);

  /// Moves the FakeClock forward by [by] in steps of at most 1 s, settling
  /// after each step, so each poll tick's read completes before the next.
  Future<void> advance(Duration by) async {
    const maxStep = Duration(seconds: 1);
    var left = by;
    while (left > Duration.zero) {
      final step = left < maxStep ? left : maxStep;
      clock.advance(step);
      left -= step;
      await tester.pump();
      await settle();
    }
  }

  /// One 2 s revision poll tick while the window is focused.
  Future<void> pollTick() => advance(const Duration(seconds: 2));
}

/// Pumps the whole app as `main()` builds it, over the journey seams:
/// - [servers] are saved (name and URL in prefs, token in the FakeTokenStore
///   unless the fixture says otherwise); [recents] and [lastVault] are the
///   typed recents and last vault (launch reopens it);
/// - [cli] behind `memexCliProvider` ([binary] false: none, the binary is
///   not found), or with [clis] the fake for the configured binary path;
/// - [db] behind `vaultDbProvider` when given (else the real one opens the
///   local vault folder's SQLite); [revisionReader] behind
///   `revisionReaderProvider` when given (a local vault's revision seam);
/// - a [FakeClock] (default 2026-10-19 09:00) and a +02:00 UTC offset.
/// Nothing else is overridden: no picker-actions, dialog, banner, flag or
/// unsent-text override. [overrides] are appended.
Future<JourneyApp> pumpJourneyApp(
  WidgetTester tester, {
  List<HostedServerFixture> servers = const [],
  List<VaultRef> recents = const [],
  VaultRef? lastVault,
  FakeMemexCli? cli,
  Map<String, FakeMemexCli>? clis,
  bool binary = true,
  FakeVaultDb? db,
  RevisionReader? revisionReader,
  FakeClock? clock,
  Size surfaceSize = const Size(1600, 1000),
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues(
    hostedPrefs(
      servers: [for (final s in servers) s.saved],
      recents: recents,
      lastVault: lastVault,
    ),
  );
  final tokens = FakeTokenStore({
    for (final s in servers) s.id: ?s.storedToken,
  });
  final settings = (await tester.runAsync(
    () => loadSettingsKeepingPickedBinary(tokenStore: tokens),
  ))!;
  final router = FakeVaultServerRouter([for (final s in servers) s.server]);
  final fakeClock = clock ?? FakeClock(DateTime(2026, 10, 19, 9));
  final appSupport = Directory.systemTemp.createTempSync('om105_support_');
  final title = RecordingWindowTitle();
  final exitHost = FakeAppExitHost();
  final defaultCli = binary
      ? (cli ??
            (FakeMemexCli()
              ..on('vault check', (_) => FakeMemexCli.ok())
              ..on(
                'settings get',
                (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
              )))
      : null;
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(tokens),
      hostedHttpClientProvider.overrideWithValue(router),
      connectServerHttpClientProvider.overrideWithValue(router),
      serverDialogHttpClientProvider.overrideWithValue(router),
      appSupportDirProvider.overrideWithValue(appSupport.path),
      if (clis != null)
        memexCliProvider.overrideWith(
          (ref) => clis[ref.watch(settingsProvider).memexBinaryPath],
        )
      else
        memexCliProvider.overrideWithValue(defaultCli),
      if (db != null) vaultDbProvider.overrideWithValue(db),
      if (revisionReader != null)
        revisionReaderProvider.overrideWithValue(revisionReader),
      clockProvider.overrideWithValue(fakeClock),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
      windowTitleProvider.overrideWithValue(title),
      appExitHostProvider.overrideWithValue(exitHost),
      appFocusProvider.overrideWith(() => FakeAppFocus()),
      // The app root's own seam wiring, as main() spreads it.
      ...appRootOverrides,
      ...overrides,
    ],
  );
  addTearDown(() => _deleteQuietly(appSupport));
  addTearDown(container.dispose);
  if (db != null) addTearDown(db.close);

  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OpenMemexApp(),
    ),
  );
  final app = JourneyApp._(
    tester: tester,
    container: container,
    servers: servers,
    router: router,
    tokens: tokens,
    clock: fakeClock,
    appSupport: appSupport,
    windowTitle: title,
    exitHost: exitHost,
  );
  await app.settle();
  return app;
}

/// Every file under [dir], relative to it (for UI-state checks).
List<String> journeyFilesUnder(Directory dir) => [
  for (final e in dir.listSync(recursive: true))
    if (e is File) p.relative(e.path, from: dir.path),
]..sort();

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

/// Holds an unawaited future so a journey can fire an action (close, quit)
/// whose answer lands later.
void journeyFire(Future<Object?> f) => unawaited(f);
