// WI #37 (A3; Spec #31 req 9, 11, D20): a check started while another check
// is in flight joins it, so one Appcast fetch answers both. The fetch is held
// with a completer, never a wall-clock wait.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import 'update_controller_doubles.dart';

void main() {
  test(
    'a manual check during the launch check joins it with one fetch',
    () async {
      final rig = ControllerRig();
      final item = newerItem();
      rig.fakes.fetcher
        ..items = [item]
        ..hold = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      expect(rig.fakes.fetcher.fetchCount, 1);
      expect(rig.state, isA<UpdateChecking>());

      final manual = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(
        rig.fakes.fetcher.fetchCount,
        1,
        reason: 'joined, not a second fetch',
      );

      rig.fakes.fetcher.hold!.complete();
      await manual;
      expect(await launch, isTrue);

      expect(rig.fakes.fetcher.fetchCount, 1);
      expect(rig.fakes.lastCheck.stamp, rig.clock.now());
      expect(
        rig.state,
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
      );
      expect(rig.states.whereType<UpdateChecking>(), hasLength(1));
    },
  );

  test('two manual checks in the same frame make one fetch', () async {
    final rig = ControllerRig();
    rig.fakes.fetcher.hold = Completer<void>();

    final first = rig.controller.check(manual: true);
    final second = rig.controller.check(manual: true);
    await pumpEventQueue();
    expect(rig.fakes.fetcher.fetchCount, 1);

    rig.fakes.fetcher.hold!.complete();
    await Future.wait([first, second]);

    expect(rig.fakes.fetcher.fetchCount, 1);
    expect(rig.state, isA<UpdateUpToDate>());
  });

  test('a check after a finished check fetches again', () async {
    final rig = ControllerRig();

    await rig.controller.check(manual: true);
    await rig.controller.check(manual: true);

    expect(rig.fakes.fetcher.fetchCount, 2);
  });
}
