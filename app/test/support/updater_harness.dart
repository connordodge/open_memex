// WI #32 (A0, D19): pumps or builds a provider scope with every updater seam
// faked (Spec #31 TD6, D6), so no updater test needs a real HTTP client,
// file, process, SharedPreferences, clock or process exit.
//
// FROZEN after #32: sibling WIs (#33 #34 #36 #37 #38 #39) build on it in
// parallel. A filler never adds a ProviderScope requirement: every port and
// every low-level seam is overridden here. Extra overrides (for example
// `agentActivityAsyncProvider`) go in `overrides` and must not repeat one
// the harness already sets.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_version.dart';

import 'editor_scope.dart' show RecordingUrlOpener;
import 'fake_clock.dart';
import 'updater_fakes.dart';

/// Every updater double, with the values the harness injects. Change a
/// value before building the overrides (or pumping); the fakes themselves
/// can be reconfigured at any time.
class UpdaterFakes {
  UpdaterFakes({FakeClock? clock}) : clock = clock ?? FakeClock();

  final fetcher = FakeAppcastFetcher();
  final downloader = FakeUpdateDownloader();
  final verifier = FakeEdDsaVerifier();
  final location = FakeInstallLocationCheck();
  final helper = FakeInstallHelper();
  final marker = FakeFailureMarkerStore();
  final lastCheck = FakeLastCheckStore();
  final exit = RecordingProcessExit();
  final urlOpener = RecordingUrlOpener();
  final io = RecordingUpdaterIo();
  final FakeClock clock;

  /// `updatesEnabledProvider`: on, so the updater is live under test.
  bool updatesEnabled = true;

  /// `appVersionProvider`: the installed `x.y.z`.
  String appVersion = '1.2.3';

  /// `appBuildNumberProvider`: the installed build number.
  String buildNumber = '7';

  /// `runningMacosVersionProvider`: macOS 15.1.
  SystemVersion? runningMacos = const SystemVersion([15, 1]);

  /// `currentPidProvider`.
  int pid = 4242;

  /// `sparkleEdPublicKeyProvider`: a non-empty test value (the fake verifier
  /// never decodes it; real-verifier tests inject an ephemeral key, D9).
  String publicKey = 'dGVzdC1wdWJsaWMta2V5LXRoaXJ0eS10d28tYnl0ZXM=';

  /// The overrides for every updater seam, plus `updateControllerProvider`
  /// when [controller] is given (otherwise the real controller runs over
  /// the fakes).
  List<Override> overrides({FakeUpdateController? controller}) => [
    updatesEnabledProvider.overrideWithValue(updatesEnabled),
    appVersionProvider.overrideWithValue(appVersion),
    appBuildNumberProvider.overrideWithValue(buildNumber),
    runningMacosVersionProvider.overrideWithValue(runningMacos),
    currentPidProvider.overrideWithValue(pid),
    sparkleEdPublicKeyProvider.overrideWithValue(publicKey),
    clockProvider.overrideWithValue(clock),
    urlOpenerProvider.overrideWithValue(urlOpener),
    appProcessExitProvider.overrideWithValue(exit.call),
    appcastFetcherProvider.overrideWithValue(fetcher),
    updateDownloaderProvider.overrideWithValue(downloader),
    edDsaVerifierProvider.overrideWithValue(verifier),
    installLocationCheckProvider.overrideWithValue(location),
    installHelperProvider.overrideWithValue(helper),
    failureMarkerStoreProvider.overrideWithValue(marker),
    lastCheckStoreProvider.overrideWithValue(lastCheck),
    updateHttpClientFactoryProvider.overrideWithValue(io.clientFactory),
    updateDownloadDirProvider.overrideWithValue(io.downloadDir),
    resolvedExecutableProvider.overrideWithValue(io.resolvedExecutable),
    folderWritableProvider.overrideWithValue(io.folderWritable),
    installHelperRunnerProvider.overrideWithValue(io.runHelper),
    failureMarkerFileProvider.overrideWithValue(io.failureMarkerFile),
    if (controller != null)
      updateControllerProvider.overrideWith(() => controller),
  ];
}

/// A [ProviderContainer] with every updater seam faked by [fakes] (fresh
/// ones by default), the fake [controller] when given, then [overrides].
/// Disposed at the end of the test.
ProviderContainer updaterContainer({
  UpdaterFakes? fakes,
  FakeUpdateController? controller,
  List<Override> overrides = const [],
}) {
  final f = fakes ?? UpdaterFakes();
  final container = ProviderContainer(
    overrides: [
      ...f.overrides(controller: controller),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// What [pumpUpdaterHarness] pumped.
class UpdaterHarness {
  UpdaterHarness({
    required this.fakes,
    required this.container,
    required this.context,
    this.controller,
  });

  final UpdaterFakes fakes;
  final ProviderContainer container;

  /// A context under the app's Navigator, for `openUpdateModal`.
  final BuildContext context;

  /// The fake controller, when one was given.
  final FakeUpdateController? controller;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pumps [child] (an empty box by default) in a `MaterialApp` under a
/// `ProviderScope` with every updater seam faked by [fakes] (fresh ones by
/// default), the fake [controller] when given, then [overrides].
Future<UpdaterHarness> pumpUpdaterHarness(
  WidgetTester tester, {
  Widget child = const SizedBox.shrink(),
  UpdaterFakes? fakes,
  FakeUpdateController? controller,
  List<Override> overrides = const [],
}) async {
  final f = fakes ?? UpdaterFakes();
  final contextKey = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...f.overrides(controller: controller),
        ...overrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: KeyedSubtree(key: contextKey, child: child),
        ),
      ),
    ),
  );
  final context = contextKey.currentContext!;
  return UpdaterHarness(
    fakes: f,
    container: ProviderScope.containerOf(context),
    context: context,
    controller: controller,
  );
}
