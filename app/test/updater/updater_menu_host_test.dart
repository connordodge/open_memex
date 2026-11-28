// WI #39 (A5, Spec #31 req 10, 13, 17, 18; D5, D20): Open Memex ▸ Check for
// Updates… arrives as native → Dart `checkForUpdatesFromMenu` on
// `open_memex/updater` (played here with a real platform message) and the
// UpdaterMenuHost opens the update modal:
// - updates disabled: at `Updates are off`, no check;
// - Ready: at Ready, no check (req 17);
// - Downloading or Verifying: at that state, no check (D20);
// - otherwise: at Checking, running a manual check (req 13);
// - a second event while the modal is open shows one modal (req 18).
// The host is pumped alone over a bare MaterialApp, then wired by the app
// root (from the vault picker and from an open vault).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/updater/updater_menu_host.dart';

import '../robots/updater_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

/// The real controller, built in [initial] instead of Idle, so a test can
/// start it in any state and still run its real check.
class _Wi39SeededController extends UpdateController {
  _Wi39SeededController(this.initial);

  final UpdateState initial;

  @override
  UpdateState build() => initial;
}

/// The checks a [FakeUpdateController] was asked for.
List<String> _checks(FakeUpdateController c) =>
    c.calls.where((call) => call.startsWith('check')).toList();

/// Pumps a bare MaterialApp over every updater seam faked by [fakes], with
/// an [UpdaterMenuHost] attached over its navigator (detached at the end).
/// [controller] replaces the real controller when given.
Future<UpdaterRobot> _pumpHost(
  WidgetTester tester, {
  UpdaterFakes? fakes,
  UpdateController Function()? controller,
}) async {
  final f = fakes ?? UpdaterFakes();
  final container = updaterContainer(
    fakes: f,
    overrides: [
      if (controller != null) updateControllerProvider.overrideWith(controller),
    ],
  );
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  final host = UpdaterMenuHost(navigatorKey: navigatorKey, read: container.read)
    ..attach();
  addTearDown(host.detach);
  return UpdaterRobot(tester, f);
}

/// Updater fakes over [clock] whose last check was stamped at [clock]'s
/// now, so the app root's launch check is not due and fetches nothing.
UpdaterFakes _notDueFakes(FakeClock clock) =>
    UpdaterFakes(clock: clock)..lastCheck.stamp = clock.now();

void main() {
  holdFontFetches();

  group('host', () {
    final item = testAppcastItem(shortVersionString: '1.3.0');
    for (final (name, initial) in [
      (
        'the menu event from Idle opens the modal at Checking and runs a manual check',
        const UpdateIdle() as UpdateState,
      ),
      (
        'the menu event from Up to date opens the modal at Checking and runs a manual check',
        const UpdateUpToDate(),
      ),
      (
        'the menu event from Update available opens the modal at Checking and runs a manual check',
        UpdateAvailable(item),
      ),
      (
        'the menu event after a check error opens the modal at Checking and runs a manual check',
        const UpdateError(UpdateErrorCause.offline),
      ),
      (
        'the menu event after a background download failure opens the modal at Checking and runs a manual check',
        UpdateError(UpdateErrorCause.downloadFailed, item: item),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
        final robot = await _pumpHost(
          tester,
          fakes: fakes,
          controller: () => _Wi39SeededController(initial),
        );

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Checking for updates');
        expect(
          fakes.fetcher.fetchCount,
          1,
          reason: 'a manual check runs (never throttled)',
        );
        expect(fakes.lastCheck.readCount, 0, reason: 'manual: no throttle');
      });
    }

    testWidgets(
      'the menu event runs the check even when the last check was minutes ago',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 11, 17, 9));
        final fakes = UpdaterFakes(clock: clock)
          ..fetcher.hold = Completer<void>()
          ..lastCheck.stamp = DateTime(2026, 11, 17, 8, 55);
        final robot = await _pumpHost(tester, fakes: fakes);

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Checking for updates');
        expect(fakes.fetcher.fetchCount, 1);
      },
    );

    testWidgets(
      'the menu event while Ready opens the modal at Ready and runs no check',
      (tester) async {
        final fake = FakeUpdateController(
          UpdateReady(
            testAppcastItem(shortVersionString: '1.3.0'),
            dmgPath: '/updater-test/open-memex-update/Open-Memex-update.dmg',
          ),
        );
        final robot = await _pumpHost(tester, controller: () => fake);

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Update ready');
        expect(_checks(fake), isEmpty, reason: 'Ready runs no check');
        expect(fake.current, isA<UpdateReady>());
      },
    );

    testWidgets(
      'the menu event while Downloading opens the modal at Downloading and runs no check',
      (tester) async {
        final fake = FakeUpdateController(
          UpdateDownloading(
            testAppcastItem(shortVersionString: '1.3.0'),
            progress: 0.5,
          ),
        );
        final robot = await _pumpHost(tester, controller: () => fake);

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Downloading update');
        expect(_checks(fake), isEmpty, reason: 'D20: no parallel check');
        expect(fake.current, isA<UpdateDownloading>());
      },
    );

    testWidgets(
      'the menu event while Verifying opens the modal at Verifying and runs no check',
      (tester) async {
        final fake = FakeUpdateController(
          UpdateVerifying(testAppcastItem(shortVersionString: '1.3.0')),
        );
        final robot = await _pumpHost(tester, controller: () => fake);

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Verifying update');
        expect(_checks(fake), isEmpty, reason: 'D20: no parallel check');
        expect(fake.current, isA<UpdateVerifying>());
      },
    );

    testWidgets(
      'with the real controller Downloading the menu event shows Downloading and fetches nothing',
      (tester) async {
        final fakes = UpdaterFakes()
          ..fetcher.items = [testAppcastItem(shortVersionString: '1.3.0')]
          ..downloader.hold = Completer<void>();
        final robot = await _pumpHost(tester, fakes: fakes);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold)),
        );
        final controller = container.read(updateControllerProvider.notifier);
        await controller.check(manual: true);
        unawaited(controller.install());
        await tester.pump();
        expect(
          container.read(updateControllerProvider),
          isA<UpdateDownloading>(),
        );

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Downloading update');
        expect(fakes.fetcher.fetchCount, 1, reason: 'only the first check');
        expect(fakes.downloader.downloads, hasLength(1));
        expect(
          container.read(updateControllerProvider),
          isA<UpdateDownloading>(),
        );
      },
    );

    testWidgets(
      'with updates disabled the menu event opens the modal at Updates are off',
      (tester) async {
        final fakes = UpdaterFakes()..updatesEnabled = false;
        final robot = await _pumpHost(tester, fakes: fakes);

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Updates are off');
        expect(
          robot.inModal(find.text('Updates are off in development builds.')),
          findsOneWidget,
        );
        expect(fakes.fetcher.fetchCount, 0, reason: 'disabled: no check');
        expect(fakes.lastCheck.readCount, 0);
        expect(fakes.lastCheck.writes, isEmpty);
      },
    );

    testWidgets('a second menu event while the modal is open shows one modal', (
      tester,
    ) async {
      final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
      final robot = await _pumpHost(tester, fakes: fakes);

      await robot.checkForUpdatesFromMenu();
      robot.expectModal('Checking for updates');
      await robot.checkForUpdatesFromMenu();

      robot.expectModal('Checking for updates');
    });

    testWidgets('two menu events in the same frame show one modal', (
      tester,
    ) async {
      final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
      final robot = await _pumpHost(tester, fakes: fakes);

      wi39SendCheckForUpdatesFromMenu(tester);
      wi39SendCheckForUpdatesFromMenu(tester);
      await robot.settle();

      robot.expectModal('Checking for updates');
    });

    testWidgets('a second menu event while Ready keeps one modal at Ready', (
      tester,
    ) async {
      final fake = FakeUpdateController(
        UpdateReady(
          testAppcastItem(shortVersionString: '1.3.0'),
          dmgPath: '/updater-test/open-memex-update/Open-Memex-update.dmg',
        ),
      );
      final robot = await _pumpHost(tester, controller: () => fake);

      await robot.checkForUpdatesFromMenu();
      await robot.checkForUpdatesFromMenu();

      robot.expectModal('Update ready');
      expect(_checks(fake), isEmpty);
    });

    testWidgets('after detach a menu event opens no modal and runs no check', (
      tester,
    ) async {
      final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
      final container = updaterContainer(fakes: fakes);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      UpdaterMenuHost(navigatorKey: navigatorKey, read: container.read)
        ..attach()
        ..detach();
      final robot = UpdaterRobot(tester, fakes);

      await robot.checkForUpdatesFromMenu();

      robot.expectNoModal();
      expect(fakes.fetcher.fetchCount, 0);
    });

    testWidgets(
      'an unknown method on the updater channel is not implemented and runs no check',
      (tester) async {
        final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
        final robot = await _pumpHost(tester, fakes: fakes);
        ByteData? reply = ByteData(0);
        var replied = false;

        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'open_memex/updater',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('somethingElse'),
          ),
          (data) {
            replied = true;
            reply = data;
          },
        );
        await robot.settle();

        expect(replied, isTrue);
        expect(reply, isNull, reason: 'MissingPluginException: not handled');
        robot.expectNoModal();
        expect(fakes.fetcher.fetchCount, 0);
      },
    );

    testWidgets(
      'a menu event with no navigator mounted is ignored and runs no check',
      (tester) async {
        final fakes = UpdaterFakes()..fetcher.hold = Completer<void>();
        final container = updaterContainer(fakes: fakes);
        await tester.pumpWidget(const SizedBox.shrink());
        final host = UpdaterMenuHost(
          navigatorKey: GlobalKey<NavigatorState>(),
          read: container.read,
        )..attach();
        addTearDown(host.detach);

        wi39SendCheckForUpdatesFromMenu(tester);
        await tester.pump();

        expect(fakes.fetcher.fetchCount, 0, reason: 'no navigator: no-op');
        expect(find.byType(Dialog), findsNothing);
      },
    );
  });

  group('app root', () {
    testWidgets(
      'the menu event from the vault picker opens the modal at Checking and runs a manual check',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 19, 9));
        final fakes = _notDueFakes(clock)..fetcher.hold = Completer<void>();
        await pumpJourneyApp(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        final robot = UpdaterRobot(tester, fakes);
        robot.expectNoModal();
        expect(fakes.fetcher.fetchCount, 0, reason: 'launch check not due');

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Checking for updates');
        expect(fakes.fetcher.fetchCount, 1);
      },
    );

    testWidgets(
      'the menu event from an open vault opens the modal at Checking and runs a manual check',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 3, 9));
        final fakes = _notDueFakes(clock)..fetcher.hold = Completer<void>();
        await pumpWorkspace(
          tester,
          clock: clock,
          overrides: wi39UpdaterOverrides(fakes),
        );
        expect(find.byType(Workspace), findsOneWidget);
        final robot = UpdaterRobot(tester, fakes);
        robot.expectNoModal();
        expect(fakes.fetcher.fetchCount, 0, reason: 'launch check not due');

        await robot.checkForUpdatesFromMenu();

        robot.expectModal('Checking for updates');
        expect(fakes.fetcher.fetchCount, 1);
      },
    );
  });
}
