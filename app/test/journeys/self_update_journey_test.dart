// WI #39 (A5, Spec #31 Testing Strategy "Robot journey", req 13, 15, 16,
// 17, 23): the whole Self-update path from the vault picker, every seam
// faked (UpdaterFakes over the journey harness's FakeClock):
// Open Memex ▸ Check for Updates… → Checking → Update available →
// **install** → Downloading → Verifying → Ready to Update → **later** → the
// picker label reads `v<current> · update ready` → clicking it reopens
// Ready to Update → **relaunch** → the install helper and the process-exit
// seam are each called once. The fakes' holds keep each step on screen.
import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../robots/updater_robot.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

void main() {
  holdFontFetches();

  testWidgets(
    'the menu event walks Checking Update available install Downloading Verifying Ready later the picker label and relaunch',
    (tester) async {
      final clock = FakeClock(DateTime(2026, 10, 19, 9));
      final fakes = UpdaterFakes(clock: clock)
        // The launch check is not due, so only the menu checks.
        ..lastCheck.stamp = clock.now()
        ..fetcher.hold = Completer<void>()
        ..fetcher.items = [testAppcastItem(shortVersionString: '1.3.0')]
        ..downloader.hold = Completer<void>()
        ..verifier.hold = Completer<void>();
      final app = await pumpJourneyApp(
        tester,
        clock: clock,
        overrides: wi39UpdaterOverrides(fakes),
      );
      expect(find.byType(VaultPickerScreen), findsOneWidget);
      final robot = UpdaterRobot(tester, fakes);
      robot.expectNoModal();
      expect(robot.pickerLabelText, 'v1.2.3');

      // 1. The menu event opens Checking.
      await robot.checkForUpdatesFromMenu();
      robot.expectModal('Checking for updates');
      expect(fakes.fetcher.fetchCount, 1);

      // 2. Update available, then install.
      fakes.fetcher.hold!.complete();
      await robot.settle();
      robot.expectModal('Update available');
      expect(
        robot.inModal(find.text('Version 1.3.0 is available.')),
        findsOneWidget,
      );
      await robot.tapInstall();

      // 3. Downloading, Verifying, Ready to Update.
      robot.expectModal('Downloading update');
      expect(fakes.downloader.downloads, hasLength(1));
      fakes.downloader.hold!.complete();
      await robot.settle();
      robot.expectModal('Verifying update');
      expect(fakes.verifier.calls, hasLength(1));
      fakes.verifier.hold!.complete();
      await robot.settle();
      robot.expectModal('Update ready');
      expect(
        robot.inModal(
          find.text('Version 1.3.0 is downloaded. Relaunch to apply it.'),
        ),
        findsOneWidget,
      );

      // 4. later: the modal closes and the picker label says so.
      await robot.tapLater();
      robot.expectNoModal();
      expect(app.read(updateControllerProvider), isA<UpdateReady>());
      expect(robot.pickerLabelText, 'v1.2.3 · update ready');

      // 5. Clicking the label reopens Ready to Update.
      await robot.tapPickerLabel();
      robot.expectModal('Update ready');

      // 6. relaunch: no unsent text, so no dialog; helper and exit once.
      await robot.tapRelaunch();
      expect(find.byKey(const Key('leave-confirm')), findsNothing);
      expect(fakes.location.checkCount, 1);
      expect(fakes.helper.starts, hasLength(1));
      expect(fakes.helper.starts.single.pid, 4242);
      expect(fakes.exit.calls, [AppExitType.required]);
      expect(fakes.fetcher.fetchCount, 1, reason: 'one check in the journey');
    },
  );
}
