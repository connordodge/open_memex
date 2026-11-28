// WI #32 (D1, D2, D6, D17, D19): pins the frozen seam surface the sibling
// WIs build on: every D6 provider name, each stub file's `defaultX(Ref)`,
// the controller and modal signatures, the shared harness and the fakes.
import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/updater/appcast_fetcher.dart';
import 'package:open_memex_app/src/updater/eddsa_verifier.dart';
import 'package:open_memex_app/src/updater/failure_marker.dart';
import 'package:open_memex_app/src/updater/install_helper.dart';
import 'package:open_memex_app/src/updater/install_location.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_downloader.dart';
import 'package:open_memex_app/src/updater/update_modal.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/updater/update_version.dart';
import 'package:open_memex_app/src/widgets/hosted/leave_confirm_dialog.dart'
    show ProviderReader;

import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

// Each filler's entry point keeps this exact shape (D1).
const AppcastFetcher Function(Ref) _fetcher = defaultAppcastFetcher;
const UpdateHttpClientFactory Function(Ref) _client =
    defaultUpdateHttpClientFactory;
const UpdateDownloader Function(Ref) _downloader = defaultUpdateDownloader;
const String Function(Ref) _downloadDir = defaultUpdateDownloadDir;
const EdDsaVerifier Function(Ref) _verifier = defaultEdDsaVerifier;
const InstallLocationCheck Function(Ref) _location =
    defaultInstallLocationCheck;
const String Function(Ref) _executable = defaultResolvedExecutable;
const FolderWritable Function(Ref) _writable = defaultFolderWritable;
const InstallHelper Function(Ref) _helper = defaultInstallHelper;
const InstallHelperRunner Function(Ref) _runner = defaultInstallHelperRunner;
const FailureMarkerStore Function(Ref) _marker = defaultFailureMarkerStore;
const String Function(Ref) _markerFile = defaultFailureMarkerFile;

// The modal's frozen entry point (D17).
const Future<void> Function(BuildContext, ProviderReader) _openModal =
    openUpdateModal;

void main() {
  test('every stub file keeps its defaultX entry point', () {
    expect(<Object>[
      _fetcher,
      _client,
      _downloader,
      _downloadDir,
      _verifier,
      _location,
      _executable,
      _writable,
      _helper,
      _runner,
      _marker,
      _markerFile,
      _openModal,
    ], hasLength(13));
  });

  test('the update controller keeps its frozen signatures', () {
    final container = updaterContainer();
    final UpdateController controller = container.read(
      updateControllerProvider.notifier,
    );

    final Future<bool> Function() launch = controller.launch;
    final Future<void> Function({required bool manual}) check =
        controller.check;
    final Future<void> Function() install = controller.install;
    final Future<void> Function() tryAgain = controller.tryAgain;
    final void Function() later = controller.later;
    final Future<RelaunchOutcome> Function({
      required Future<bool> Function() confirmQuit,
    })
    relaunch = controller.relaunch;

    expect([launch, check, install, tryAgain, later, relaunch], hasLength(6));
    expect(container.read(updateControllerProvider), isA<UpdateIdle>());
    expect(RelaunchOutcome.values, hasLength(4));
  });

  test('the updater harness overrides every updater seam with its fakes', () {
    final fakes = UpdaterFakes();
    final container = updaterContainer(fakes: fakes);

    expect(container.read(updatesEnabledProvider), isTrue);
    expect(container.read(appVersionProvider), '1.2.3');
    expect(container.read(appBuildNumberProvider), '7');
    expect(container.read(runningMacosVersionProvider)?.parts, [15, 1]);
    expect(container.read(currentPidProvider), 4242);
    expect(container.read(sparkleEdPublicKeyProvider), isNotEmpty);
    expect(container.read(clockProvider), same(fakes.clock));
    expect(container.read(urlOpenerProvider), same(fakes.urlOpener));
    expect(container.read(appcastFetcherProvider), same(fakes.fetcher));
    expect(container.read(updateDownloaderProvider), same(fakes.downloader));
    expect(container.read(edDsaVerifierProvider), same(fakes.verifier));
    expect(container.read(installLocationCheckProvider), same(fakes.location));
    expect(container.read(installHelperProvider), same(fakes.helper));
    expect(container.read(failureMarkerStoreProvider), same(fakes.marker));
    expect(container.read(lastCheckStoreProvider), same(fakes.lastCheck));
    expect(container.read(updateDownloadDirProvider), fakes.io.downloadDir);
    expect(
      container.read(resolvedExecutableProvider),
      fakes.io.resolvedExecutable,
    );
    expect(
      container.read(failureMarkerFileProvider),
      fakes.io.failureMarkerFile,
    );
    for (final path in [
      fakes.io.downloadDir,
      fakes.io.resolvedExecutable,
      fakes.io.failureMarkerFile,
    ]) {
      expect(path, isNot(contains('/Users/')));
      expect(path, isNot(startsWith('/tmp')));
    }
    // The process-exit seam, the HTTP client, the probe and the runner are
    // the recorders (checked by calling them below).
    expect(container.read(appProcessExitProvider), isNotNull);
    expect(container.read(updateHttpClientFactoryProvider), isNotNull);
    expect(container.read(folderWritableProvider), isNotNull);
    expect(container.read(installHelperRunnerProvider), isNotNull);
  });

  test('the harness values can be changed before the overrides are built', () {
    final fakes = UpdaterFakes()
      ..updatesEnabled = false
      ..appVersion = '2.0.1'
      ..buildNumber = '31'
      ..runningMacos = null
      ..pid = 77
      ..publicKey = '';
    final container = updaterContainer(fakes: fakes);

    expect(container.read(updatesEnabledProvider), isFalse);
    expect(container.read(appVersionProvider), '2.0.1');
    expect(container.read(appBuildNumberProvider), '31');
    expect(container.read(runningMacosVersionProvider), isNull);
    expect(container.read(currentPidProvider), 77);
    expect(container.read(sparkleEdPublicKeyProvider), '');
  });

  test('the low level seam doubles record and touch nothing real', () async {
    final fakes = UpdaterFakes();
    final container = updaterContainer(fakes: fakes);

    final exit = container.read(appProcessExitProvider);
    expect(await exit(AppExitType.required), AppExitResponse.exit);
    expect(fakes.exit.calls, [AppExitType.required]);

    final client = container.read(updateHttpClientFactoryProvider)();
    final response = await client.get(Uri.parse('https://example.invalid/a'));
    expect(response.statusCode, 404);
    expect(fakes.io.httpRequests.single.url.path, '/a');

    fakes.io.writable = false;
    expect(
      await container.read(folderWritableProvider)('/Applications'),
      false,
    );
    expect(fakes.io.writableProbes, ['/Applications']);

    await container.read(installHelperRunnerProvider)('/bin/sh', ['a', 'b']);
    expect(fakes.io.helperRuns.single.executable, '/bin/sh');
    expect(fakes.io.helperRuns.single.arguments, ['a', 'b']);
  });

  test('the port fakes answer, hold and fail like the real ports', () async {
    final item = testAppcastItem(shortVersionString: '1.2.4', version: '8');

    final fetcher = FakeAppcastFetcher(items: [item]);
    expect(await fetcher.fetch(), [item]);
    fetcher.failure = const UpdateFailure(UpdateErrorCause.noAppcast);
    await expectLater(fetcher.fetch(), throwsA(isA<UpdateFailure>()));
    expect(fetcher.fetchCount, 2);

    final downloader = FakeUpdateDownloader()..progress = [0.25, null];
    final seen = <double?>[];
    expect(await downloader.download(item, onProgress: seen.add), isNotEmpty);
    expect(seen, [0.25, null]);
    expect(downloader.downloads, [item]);
    downloader.failure = const UpdateFailure(UpdateErrorCause.downloadFailed);
    await expectLater(downloader.download(item), throwsA(isA<UpdateFailure>()));
    await downloader.deleteLeftovers();
    expect(downloader.deleteLeftoversCount, 1);

    final verifier = FakeEdDsaVerifier();
    await verifier.verify(dmgPath: '/updater-test/a.dmg', edSignature: 'c2ln');
    expect(verifier.calls.single.dmgPath, '/updater-test/a.dmg');
    expect(verifier.calls.single.edSignature, 'c2ln');

    final location = FakeInstallLocationCheck();
    expect(await location.check(), '/Applications/Open Memex.app');
    location.failure = const UpdateFailure(
      UpdateErrorCause.folderNotWritable,
      folder: '/Applications',
    );
    await expectLater(
      location.check(),
      throwsA(
        isA<UpdateFailure>().having((f) => f.folder, 'folder', '/Applications'),
      ),
    );

    final helper = FakeInstallHelper();
    await helper.start(
      pid: 4242,
      dmgPath: '/updater-test/a.dmg',
      bundlePath: 'B',
    );
    expect(helper.starts.single.pid, 4242);

    final marker = FakeFailureMarkerStore(
      reason: 'the new app couldn’t be copied',
    );
    expect(await marker.take(), 'the new app couldn’t be copied');
    expect(await marker.take(), isNull, reason: 'take clears the marker');
    expect(marker.takeCount, 2);

    final lastCheck = FakeLastCheckStore();
    expect(await lastCheck.read(), isNull);
    final at = DateTime(2026, 11, 17, 9);
    await lastCheck.write(at);
    expect(await lastCheck.read(), at);
    expect(lastCheck.writes, [at]);
  });

  test(
    'a held fake call stays in flight until its completer completes',
    () async {
      final fetcher = FakeAppcastFetcher()..hold = Completer<void>();
      var done = false;
      final pending = fetcher.fetch().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);

      expect(
        fetcher.fetchCount,
        1,
        reason: 'the call is recorded at its start',
      );
      expect(done, isFalse);

      fetcher.hold!.complete();
      await pending;
      expect(done, isTrue);
    },
  );

  testWidgets(
    'the harness pumps a context under a Navigator with the fake controller',
    (tester) async {
      final item = testAppcastItem();
      final controller = FakeUpdateController(UpdateAvailable(item))
        ..launchResult = true;
      final harness = await pumpUpdaterHarness(tester, controller: controller);

      expect(Navigator.maybeOf(harness.context), isNotNull);
      expect(harness.controller, same(controller));
      expect(
        harness.read(updateControllerProvider),
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
      );

      final notifier = harness.read(updateControllerProvider.notifier);
      expect(await notifier.launch(), isTrue);
      await notifier.check(manual: true);
      await notifier.install();
      await notifier.tryAgain();
      notifier.later();
      expect(
        await notifier.relaunch(confirmQuit: () async => false),
        RelaunchOutcome.cancelled,
      );
      expect(
        await notifier.relaunch(confirmQuit: () async => true),
        RelaunchOutcome.exiting,
      );
      expect(controller.calls, [
        'launch',
        'check(manual: true)',
        'install',
        'tryAgain',
        'later',
        'relaunch',
        'relaunch',
      ]);
      expect(controller.confirmQuitAnswers, [false, true]);
      expect(
        harness.read(updateControllerProvider),
        isA<UpdateAvailable>(),
        reason: 'the fake changes no state on its own',
      );

      controller.emit(UpdateReady(item, dmgPath: '/updater-test/a.dmg'));
      expect(harness.read(updateControllerProvider), isA<UpdateReady>());
      expect(controller.current, isA<UpdateReady>());
    },
  );

  test('fixtures use invented versions only', () {
    for (final name in [
      'appcast_valid.xml',
      'appcast_cdata_split.xml',
      'appcast_unknown_fields.xml',
      'appcast_missing_fields.xml',
      'appcast_all_invalid.xml',
      'appcast_no_channel.xml',
      'appcast_bad_xml.xml',
      'appcast_empty_channel.xml',
    ]) {
      final text = updaterFixture(name);
      expect(text, isNot(contains('0.7.1')), reason: name);
      expect(text, isNot(contains('/Users/')), reason: name);
    }
  });

  test('a SystemVersion and an AppcastItem build from run time values', () {
    final parts = [for (final p in '15.1'.split('.')) int.parse(p)];
    expect(SystemVersion(parts).parts, [15, 1]);
    final http.Client Function() factory = RecordingUpdaterIo().clientFactory;
    expect(factory(), isA<http.Client>());
  });
}
