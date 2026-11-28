// WI #39 (A5, Spec #31 Testing Strategy "Robot journey"): the robot for
// Self-update journeys, and the updater overrides an app-root harness that
// already fakes the clock can take.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/updater_harness.dart';

/// Every updater seam faked by [fakes], as `UpdaterFakes.overrides` builds
/// them, but without `clockProvider`: the app-root harnesses
/// (`pumpJourneyApp`, `pumpWorkspace`) already override the clock, so build
/// [fakes] over that same FakeClock. [controller] replaces the real
/// controller when given.
///
/// The real `defaultInstallHelper` runs over the recording runner seam
/// (`installHelperRunnerProvider` -> `fakes.io.runHelper`), so a relaunch is
/// seen in `fakes.io.helperRuns`; the InstallHelper port fake
/// (`fakes.helper`) is deliberately not wired.
List<Override> wi39UpdaterOverrides(
  UpdaterFakes fakes, {
  UpdateController Function()? controller,
}) => [
  updatesEnabledProvider.overrideWithValue(fakes.updatesEnabled),
  appVersionProvider.overrideWithValue(fakes.appVersion),
  appBuildNumberProvider.overrideWithValue(fakes.buildNumber),
  runningMacosVersionProvider.overrideWithValue(fakes.runningMacos),
  currentPidProvider.overrideWithValue(fakes.pid),
  sparkleEdPublicKeyProvider.overrideWithValue(fakes.publicKey),
  urlOpenerProvider.overrideWithValue(fakes.urlOpener),
  appProcessExitProvider.overrideWithValue(fakes.exit.call),
  appcastFetcherProvider.overrideWithValue(fakes.fetcher),
  updateDownloaderProvider.overrideWithValue(fakes.downloader),
  edDsaVerifierProvider.overrideWithValue(fakes.verifier),
  installLocationCheckProvider.overrideWithValue(fakes.location),
  failureMarkerStoreProvider.overrideWithValue(fakes.marker),
  lastCheckStoreProvider.overrideWithValue(fakes.lastCheck),
  updateHttpClientFactoryProvider.overrideWithValue(fakes.io.clientFactory),
  updateDownloadDirProvider.overrideWithValue(fakes.io.downloadDir),
  resolvedExecutableProvider.overrideWithValue(fakes.io.resolvedExecutable),
  folderWritableProvider.overrideWithValue(fakes.io.folderWritable),
  installHelperRunnerProvider.overrideWithValue(fakes.io.runHelper),
  failureMarkerFileProvider.overrideWithValue(fakes.io.failureMarkerFile),
  if (controller != null) updateControllerProvider.overrideWith(controller),
];

/// Plays the native menu: sends `checkForUpdatesFromMenu` (no arguments)
/// on `open_memex/updater`, as `MainFlutterWindow.checkForUpdates(_:)`
/// does. It does not wait for Dart's reply.
void wi39SendCheckForUpdatesFromMenu(WidgetTester tester) {
  const codec = StandardMethodCodec();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'open_memex/updater',
    codec.encodeMethodCall(const MethodCall('checkForUpdatesFromMenu')),
    (_) {},
  );
}

/// Robot for the Self-update journey. Finds widgets by the Spec's stable
/// Keys only: `update-modal`, `update-modal-title`, `update-modal-body`,
/// `update-modal-install`, `update-modal-later`, `update-modal-relaunch`
/// and `picker-version-label`. Open Memex ▸ Check for Updates… is played
/// with [wi39SendCheckForUpdatesFromMenu].
class UpdaterRobot {
  UpdaterRobot(this.tester, this.fakes);

  final WidgetTester tester;

  /// The updater seams' fakes the app runs over.
  final UpdaterFakes fakes;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get modal => key('update-modal');
  Finder get title => key('update-modal-title');
  Finder get install => key('update-modal-install');
  Finder get later => key('update-modal-later');
  Finder get relaunch => key('update-modal-relaunch');
  Finder get pickerLabel => key('picker-version-label');

  /// [matching] inside the update modal.
  Finder inModal(Finder matching) =>
      find.descendant(of: modal, matching: matching);

  // ------------------------------------------------------------------ reads

  /// The text of the picker version label.
  String get pickerLabelText {
    expect(pickerLabel, findsOneWidget, reason: 'picker-version-label shows');
    final text = tester.widget(pickerLabel);
    if (text is Text) return text.data ?? text.textSpan!.toPlainText();
    return tester
        .widget<Text>(
          find.descendant(of: pickerLabel, matching: find.byType(Text)).first,
        )
        .data!;
  }

  // ----------------------------------------------------------------- checks

  /// Expects exactly one update modal, showing the title [title].
  void expectModal(String title) {
    expect(modal, findsOneWidget, reason: 'one update modal shows');
    final titleFinder = inModal(this.title);
    expect(
      titleFinder,
      findsOneWidget,
      reason: 'the update modal has one update-modal-title',
    );
    final widget = tester.widget(titleFinder);
    final shown = widget is Text
        ? (widget.data ?? widget.textSpan?.toPlainText())
        : null;
    expect(shown, title, reason: 'the update modal title reads "$title"');
  }

  /// Expects no update modal.
  void expectNoModal() =>
      expect(modal, findsNothing, reason: 'no update modal shows');

  // ---------------------------------------------------------------- actions

  /// Lets the fakes answer and the dialog route animate.
  Future<void> settle() => pumpFrames(tester, frames: 8);

  /// Open Memex ▸ Check for Updates….
  Future<void> checkForUpdatesFromMenu() async {
    wi39SendCheckForUpdatesFromMenu(tester);
    await settle();
  }

  Future<void> _tap(Finder f) async {
    expect(f, findsOneWidget, reason: '$f shows');
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle();
  }

  Future<void> tapInstall() => _tap(install);
  Future<void> tapLater() => _tap(later);
  Future<void> tapRelaunch() => _tap(relaunch);
  Future<void> tapPickerLabel() => _tap(pickerLabel);
}
