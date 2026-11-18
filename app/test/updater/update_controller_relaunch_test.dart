// WI #37 (A3; Spec #31 req 23, 24; D2, D3 call-count ACs a, b, c, e at the
// controller level): relaunch runs the location check, then confirmQuit,
// then the install helper, then confirms the exit, then exits.
import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_harness.dart';
import 'update_controller_doubles.dart';

void main() {
  test(
    'relaunch with confirmQuit true starts the helper with the pid then confirms then exits',
    () async {
      final fakes = LoggingUpdaterFakes();
      final confirmation = LoggingExitConfirmation(fakes.log);
      final rig = ControllerRig(
        fakes: fakes,
        overrides: [
          appExitConfirmationProvider.overrideWithValue(confirmation),
        ],
      );
      final ready = await driveToReady(rig);
      fakes.log.clear();
      var asked = 0;

      final outcome = await rig.controller.relaunch(
        confirmQuit: () async {
          asked++;
          fakes.log.add('confirmQuit');
          return true;
        },
      );

      expect(outcome, RelaunchOutcome.exiting);
      expect(fakes.log, [
        'location',
        'confirmQuit',
        'helper',
        'confirm',
        'exit required',
      ]);
      expect(asked, 1);
      expect(fakes.helper.starts, [
        (
          pid: 4242,
          dmgPath: ready.dmgPath,
          bundlePath: fakes.location.bundlePath,
        ),
      ]);
      expect(confirmation.confirmed, isTrue);
      expect(fakes.exit.calls, [AppExitType.required]);
    },
  );

  test('relaunch passes the current pid from its seam to the helper', () async {
    final rig = ControllerRig(fakes: UpdaterFakes()..pid = 31337);
    await driveToReady(rig);

    await rig.controller.relaunch(confirmQuit: () async => true);

    expect(rig.fakes.helper.starts.single.pid, 31337);
  });

  for (final (name, failure) in const [
    (
      'relaunch with a disk image location enters Error and calls nothing else',
      UpdateFailure(UpdateErrorCause.diskImage),
    ),
    (
      'relaunch with a folder not writable location enters Error and calls nothing else',
      UpdateFailure(
        UpdateErrorCause.folderNotWritable,
        folder: '/Applications',
      ),
    ),
  ]) {
    test(name, () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);
      rig.fakes.location.failure = failure;
      var asked = 0;

      final outcome = await rig.controller.relaunch(
        confirmQuit: () async {
          asked++;
          return true;
        },
      );

      expect(outcome, RelaunchOutcome.failed);
      expect(
        rig.state,
        isA<UpdateError>()
            .having((e) => e.cause, 'cause', failure.cause)
            .having((e) => e.folder, 'folder', failure.folder)
            .having((e) => e.item, 'item', same(ready.item)),
      );
      expect(rig.fakes.location.checkCount, 1);
      expect(asked, 0, reason: 'confirmQuit is never called');
      expect(rig.fakes.helper.starts, isEmpty);
      expect(rig.fakes.exit.calls, isEmpty);
      expect(
        rig.container.read(appExitConfirmationProvider).confirmed,
        isFalse,
      );
    });
  }

  test(
    'relaunch whose confirmQuit returns false keeps Ready and calls no helper or exit',
    () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);
      var asked = 0;

      final outcome = await rig.controller.relaunch(
        confirmQuit: () async {
          asked++;
          return false;
        },
      );

      expect(outcome, RelaunchOutcome.cancelled);
      expect(asked, 1);
      expect(
        rig.state,
        isA<UpdateReady>()
            .having((s) => s.item, 'item', same(ready.item))
            .having((s) => s.dmgPath, 'dmgPath', ready.dmgPath),
      );
      expect(rig.fakes.helper.starts, isEmpty);
      expect(rig.fakes.exit.calls, isEmpty);
      expect(
        rig.container.read(appExitConfirmationProvider).confirmed,
        isFalse,
      );

      // Still Ready, so a second relaunch can go ahead.
      expect(
        await rig.controller.relaunch(confirmQuit: () async => true),
        RelaunchOutcome.exiting,
      );
      expect(rig.fakes.helper.starts, hasLength(1));
    },
  );

  test(
    'relaunch whose helper fails enters Error and never confirms or exits',
    () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);
      rig.fakes.helper.failure = const UpdateFailure(
        UpdateErrorCause.folderNotWritable,
        folder: '/Applications',
      );

      final outcome = await rig.controller.relaunch(
        confirmQuit: () async => true,
      );

      expect(outcome, RelaunchOutcome.failed);
      expect(
        rig.state,
        isA<UpdateError>()
            .having((e) => e.cause, 'cause', UpdateErrorCause.folderNotWritable)
            .having((e) => e.item, 'item', same(ready.item)),
      );
      expect(rig.fakes.helper.starts, hasLength(1));
      expect(
        rig.container.read(appExitConfirmationProvider).confirmed,
        isFalse,
      );
      expect(rig.fakes.exit.calls, isEmpty);
    },
  );

  test('relaunch outside Ready is ignored and calls nothing', () async {
    final rig = ControllerRig();
    await driveToAvailable(rig);
    var asked = 0;

    final outcome = await rig.controller.relaunch(
      confirmQuit: () async {
        asked++;
        return true;
      },
    );

    expect(outcome, RelaunchOutcome.ignored);
    expect(rig.state, isA<UpdateAvailable>());
    expect(rig.fakes.location.checkCount, 0);
    expect(asked, 0);
    expect(rig.fakes.helper.starts, isEmpty);
    expect(rig.fakes.exit.calls, isEmpty);
  });

  test('two relaunch calls in the same frame start one helper', () async {
    final rig = ControllerRig();
    await driveToReady(rig);
    final hold = Completer<void>();
    rig.fakes.location.hold = hold; // the state is still Ready meanwhile
    var asked = 0;
    Future<bool> confirmQuit() async {
      asked++;
      return true;
    }

    final first = rig.controller.relaunch(confirmQuit: confirmQuit);
    final second = rig.controller.relaunch(confirmQuit: confirmQuit);
    await pumpEventQueue();
    hold.complete();
    final outcomes = await Future.wait([first, second]);

    expect(outcomes, [RelaunchOutcome.exiting, RelaunchOutcome.ignored]);
    expect(rig.fakes.location.checkCount, 1);
    expect(asked, 1);
    expect(rig.fakes.helper.starts, hasLength(1));
    expect(rig.fakes.exit.calls, [AppExitType.required]);
  });

  test('a relaunch held at confirmQuit blocks a second relaunch', () async {
    final rig = ControllerRig();
    await driveToReady(rig);
    final answer = Completer<bool>();
    var asked = 0;

    final first = rig.controller.relaunch(
      confirmQuit: () {
        asked++;
        return answer.future;
      },
    );
    await pumpEventQueue();
    expect(asked, 1);
    final second = await rig.controller.relaunch(
      confirmQuit: () async {
        asked++;
        return true;
      },
    );
    expect(second, RelaunchOutcome.ignored);

    answer.complete(true);
    expect(await first, RelaunchOutcome.exiting);
    expect(asked, 1, reason: 'the leave confirm shows at most once');
    expect(rig.fakes.helper.starts, hasLength(1));
  });
}
