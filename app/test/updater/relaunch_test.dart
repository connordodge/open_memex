// WI #39 (A5, Spec #31 req 11, 12, 23; TD7; D3, D7, D8): the app root's
// Self-update wiring.
// - Launch (D8): after the first frame the app root runs the controller's
//   `launch()` once and opens the update modal only when it answers true;
//   with updates disabled nothing is touched (D7).
// - Relaunch through the quit guard (D3 call counts a–e): the update modal
//   is opened at Ready with Open Memex ▸ Check for Updates… (the
//   `open_memex/updater` menu event) and **relaunch** is tapped; the
//   app-exit seam is a FakeAppExitHost, the process exit and the install
//   helper are the updater fakes, and unsent hosted text comes from the
//   unsent-text seam (as test/journeys/leave_confirm_test.dart does).
// - `_onQuit` returns exit with no confirm once the exit is confirmed.
import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../robots/updater_robot.dart';
import '../support/app_exit_fakes.dart';
import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

const _confirm = Key('leave-confirm');
const _cancel = Key('leave-confirm-cancel');
const _proceed = Key('leave-confirm-proceed');

final _unsent = UnsentHostedText(
  serverName: 'nas',
  vaultName: 'memex',
  notes: [
    UnsentHostedNote(title: 'hosted vault plan', since: DateTime(2026, 10, 3)),
  ],
);

/// A [FakeUpdateController] that also records whether the app's Navigator
/// was already built when `launch()` ran (it is not, inside the root's
/// `initState`).
class _Wi39LaunchRecorder extends FakeUpdateController {
  _Wi39LaunchRecorder(super.initial);

  final List<bool> navigatorBuiltAtLaunch = [];

  @override
  Future<bool> launch() {
    navigatorBuiltAtLaunch.add(find.byType(Navigator).evaluate().isNotEmpty);
    return super.launch();
  }
}

/// What [_pumpReady] pumped.
class _Ready {
  _Ready(this.h, this.exitHost, this.fakes, this.robot);

  final WorkspaceHarness h;
  final FakeAppExitHost exitHost;
  final UpdaterFakes fakes;
  final UpdaterRobot robot;

  UpdateState get state => h.read(updateControllerProvider);
}

/// The workspace with the app root's overrides, a [FakeAppExitHost], every
/// updater seam faked (launch check not due), [unsent] reported as unsent
/// when given, and the real controller driven to Ready (update 1.3.0
/// downloaded and verified). The modal is not open.
Future<_Ready> _pumpReady(
  WidgetTester tester, {
  UnsentHostedText? unsent,
  void Function(UpdaterFakes fakes)? configure,
}) async {
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final fakes = UpdaterFakes(clock: clock)
    ..lastCheck.stamp = clock.now()
    ..fetcher.items = [testAppcastItem(shortVersionString: '1.3.0')];
  configure?.call(fakes);
  final exitHost = FakeAppExitHost();
  final h = await pumpWorkspace(
    tester,
    clock: clock,
    overrides: [
      ...appRootOverrides,
      appExitHostProvider.overrideWithValue(exitHost),
      if (unsent != null) ...unsentTextOverrides(unsent),
      ...wi39UpdaterOverrides(fakes),
    ],
  );
  final controller = h.read(updateControllerProvider.notifier);
  await controller.check(manual: true);
  await controller.install();
  await pumpFrames(tester);
  expect(h.read(updateControllerProvider), isA<UpdateReady>());
  return _Ready(h, exitHost, fakes, UpdaterRobot(tester, fakes));
}

/// Opens the modal at Ready from the menu and taps **relaunch**.
Future<void> _relaunchFromMenu(_Ready r) async {
  await r.robot.checkForUpdatesFromMenu();
  r.robot.expectModal('Update ready');
  await r.robot.tapRelaunch();
}

void main() {
  holdFontFetches();

  group('launch', () {
    testWidgets(
      'after the first frame the app root runs launch once and opens the modal when it returns true',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock);
        final fake = _Wi39LaunchRecorder(
          UpdateAvailable(testAppcastItem(shortVersionString: '1.3.0')),
        )..launchResult = true;
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes, controller: () => fake),
        );
        final robot = UpdaterRobot(tester, fakes);
        await robot.settle();

        expect(fake.calls, ['launch']);
        expect(fake.navigatorBuiltAtLaunch, [
          true,
        ], reason: 'launch runs after the first frame, not in initState');
        robot.expectModal('Update available');

        await pumpFrames(tester, frames: 20);
        expect(fake.calls, ['launch'], reason: 'once for the app run');
        robot.expectModal('Update available');
      },
    );

    testWidgets(
      'when launch returns false the app root runs it once and opens no modal',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock);
        final fake = _Wi39LaunchRecorder(const UpdateIdle())
          ..launchResult = false;
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes, controller: () => fake),
        );
        final robot = UpdaterRobot(tester, fakes);
        await pumpFrames(tester, frames: 20);

        expect(fake.calls, ['launch']);
        robot.expectNoModal();
      },
    );

    testWidgets(
      'a due launch check that finds an update opens the modal at Update available',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock)
          ..fetcher.items = [testAppcastItem(shortVersionString: '1.3.0')];
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        final robot = UpdaterRobot(tester, fakes);
        await robot.settle();

        expect(fakes.downloader.deleteLeftoversCount, 1);
        expect(fakes.marker.takeCount, 1);
        expect(fakes.fetcher.fetchCount, 1);
        robot.expectModal('Update available');
      },
    );

    testWidgets(
      'a due launch check that finds no update stays silent but stamps the check',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock);
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        final robot = UpdaterRobot(tester, fakes);
        await robot.settle();

        expect(fakes.fetcher.fetchCount, 1, reason: 'the launch check ran');
        expect(fakes.lastCheck.writes, [clock.now()]);
        robot.expectNoModal();
      },
    );

    testWidgets(
      'a recorded install failure at launch opens the modal at Update failed',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock)
          ..marker.reason = "the new app couldn't be copied";
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        final robot = UpdaterRobot(tester, fakes);
        await robot.settle();

        robot.expectModal('Update failed');
        expect(fakes.fetcher.fetchCount, 0, reason: 'D8: marker skips check');
      },
    );

    testWidgets(
      'with updates disabled pumping the app touches no updater port and shows no modal',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = UpdaterFakes(clock: clock)..updatesEnabled = false;
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        final robot = UpdaterRobot(tester, fakes);
        await pumpFrames(tester, frames: 20);

        robot.expectNoModal();
        expect(fakes.downloader.deleteLeftoversCount, 0);
        expect(fakes.downloader.downloads, isEmpty);
        expect(fakes.marker.takeCount, 0);
        expect(fakes.lastCheck.readCount, 0);
        expect(fakes.lastCheck.writes, isEmpty);
        expect(fakes.fetcher.fetchCount, 0);
        expect(fakes.verifier.calls, isEmpty);
        expect(fakes.location.checkCount, 0);
        expect(fakes.exit.calls, isEmpty);
        expect(fakes.io.httpRequests, isEmpty);
        expect(fakes.io.writableProbes, isEmpty);
        expect(fakes.io.helperRuns, isEmpty);
      },
    );
  });

  group('relaunch', () {
    testWidgets(
      'relaunch with unsent hosted text confirmed shows the leave confirm once starts the helper once and exits once with required',
      (tester) async {
        final r = await _pumpReady(tester, unsent: _unsent);

        await _relaunchFromMenu(r);
        expect(find.byKey(_confirm), findsOneWidget, reason: 'the quit guard');
        expect(r.fakes.io.helperRuns, isEmpty, reason: 'helper after confirm');
        expect(r.fakes.exit.calls, isEmpty);

        await tester.tap(find.byKey(_proceed));
        await r.robot.settle();

        expect(find.byKey(_confirm), findsNothing, reason: 'shown once only');
        expect(r.fakes.io.helperRuns, hasLength(1));
        final run = r.fakes.io.helperRuns.single;
        expect(run.executable, '/bin/sh');
        expect(run.arguments[3], '4242', reason: 'the app pid');
        expect(run.arguments[4], r.fakes.downloader.dmgPath);
        expect(run.arguments[5], '/Applications/Open Memex.app');
        expect(r.fakes.exit.calls, [AppExitType.required]);
        expect(r.h.read(appExitConfirmationProvider).confirmed, isTrue);
      },
    );

    testWidgets(
      'relaunch with unsent hosted text cancelled starts no helper calls no exit and stays Ready',
      (tester) async {
        final r = await _pumpReady(tester, unsent: _unsent);

        await _relaunchFromMenu(r);
        expect(find.byKey(_confirm), findsOneWidget);
        await tester.tap(find.byKey(_cancel));
        await r.robot.settle();

        expect(find.byKey(_confirm), findsNothing);
        expect(r.fakes.io.helperRuns, isEmpty);
        expect(r.fakes.exit.calls, isEmpty);
        expect(r.state, isA<UpdateReady>());
        expect(r.h.read(appExitConfirmationProvider).confirmed, isFalse);
      },
    );

    testWidgets(
      'relaunch whose install location check fails shows Update failed with no leave confirm no helper and no exit',
      (tester) async {
        final r = await _pumpReady(
          tester,
          unsent: _unsent,
          configure: (f) => f.location.failure = const UpdateFailure(
            UpdateErrorCause.folderNotWritable,
            folder: '/Applications',
          ),
        );

        await _relaunchFromMenu(r);

        expect(r.fakes.location.checkCount, 1);
        r.robot.expectModal('Update failed');
        expect(find.byKey(_confirm), findsNothing);
        expect(r.fakes.io.helperRuns, isEmpty);
        expect(r.fakes.exit.calls, isEmpty);
      },
    );

    testWidgets(
      'relaunch with no unsent hosted text shows no dialog and calls the exit seam once',
      (tester) async {
        final r = await _pumpReady(tester);

        await _relaunchFromMenu(r);

        expect(find.byKey(_confirm), findsNothing);
        expect(r.fakes.io.helperRuns, hasLength(1));
        expect(r.fakes.exit.calls, [AppExitType.required]);
      },
    );

    testWidgets(
      'after the relaunch confirmed the exit a quit request returns exit with no confirm',
      (tester) async {
        final r = await _pumpReady(tester, unsent: _unsent);
        await _relaunchFromMenu(r);
        await tester.tap(find.byKey(_proceed));
        await r.robot.settle();
        expect(r.fakes.exit.calls, [AppExitType.required]);

        unawaited(r.exitHost.requestQuit());
        await r.robot.settle();

        expect(find.byKey(_confirm), findsNothing, reason: 'no second confirm');
        expect(r.exitHost.quitAnswers, [AppExitResponse.exit]);
      },
    );
  });

  group('quit guard', () {
    testWidgets(
      'a quit request after the exit is confirmed returns exit with no confirm',
      (tester) async {
        final exitHost = FakeAppExitHost();
        final h = await pumpWorkspace(
          tester,
          overrides: [
            ...appRootOverrides,
            appExitHostProvider.overrideWithValue(exitHost),
            ...unsentTextOverrides(_unsent),
          ],
        );
        h.read(appExitConfirmationProvider).confirm();

        unawaited(exitHost.requestQuit());
        await pumpFrames(tester);

        expect(find.byKey(_confirm), findsNothing);
        expect(exitHost.quitAnswers, [AppExitResponse.exit]);
      },
    );

    testWidgets(
      'a quit request with unsent text and no confirmed exit still shows the leave confirm',
      (tester) async {
        final exitHost = FakeAppExitHost();
        await pumpWorkspace(
          tester,
          overrides: [
            ...appRootOverrides,
            appExitHostProvider.overrideWithValue(exitHost),
            ...unsentTextOverrides(_unsent),
          ],
        );

        unawaited(exitHost.requestQuit());
        await pumpFrames(tester);
        expect(find.byKey(_confirm), findsOneWidget);
        await tester.tap(find.byKey(_cancel));
        await pumpFrames(tester);

        expect(exitHost.quitAnswers, [AppExitResponse.cancel]);
      },
    );
  });
}
