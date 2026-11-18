// WI #37 (A3; Spec #31 req 9, 11), fix round 3: a check that joins another
// check while that check is writing its stamp (the fetch is done and the state
// already holds the result) must end at that result, never stuck in Checking.
// The write is held with a completer, never a wall-clock wait.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';
import 'update_controller_doubles.dart';

/// A last-check store that can hold a read (it answers the stamp as it was
/// when the read began, once [readGate] completes) and a write (the stamp is
/// recorded at once, but the write completes only when [writeGate] does).
class _HeldLastCheck extends FakeLastCheckStore {
  Completer<void>? readGate;
  Completer<void>? writeGate;

  @override
  Future<DateTime?> read() async {
    final stamp = await super.read();
    final gate = readGate;
    if (gate != null) await gate.future;
    return stamp;
  }

  @override
  Future<void> write(DateTime time) async {
    await super.write(time);
    final gate = writeGate;
    if (gate != null) await gate.future;
  }
}

/// [UpdaterFakes] whose last-check store holds reads and writes.
class _HeldStampFakes extends UpdaterFakes {
  final _stamp = _HeldLastCheck();

  @override
  _HeldLastCheck get lastCheck => _stamp;
}

/// A rig whose first check, run with [offer] (an update, or none), has
/// fetched and parsed and is now held in its stamp write. The returned
/// `first` future is that check.
Future<({ControllerRig rig, _HeldLastCheck stamp, Future<void> first})>
_holdInStampWrite({required bool offer}) async {
  final fakes = _HeldStampFakes();
  final rig = ControllerRig(fakes: fakes);
  fakes.fetcher.items = offer ? [newerItem()] : [];
  fakes.lastCheck.writeGate = Completer<void>();

  final first = rig.controller.check(manual: true);
  await pumpEventQueue();
  expect(
    fakes.lastCheck.writes,
    hasLength(1),
    reason: 'setup: the first check is in its stamp write',
  );
  expect(
    rig.state,
    offer ? isA<UpdateAvailable>() : isA<UpdateUpToDate>(),
    reason: 'setup: the first check already holds its result',
  );
  return (rig: rig, stamp: fakes.lastCheck, first: first);
}

void main() {
  test(
    'a manual check joining the stamp write ends at Available and fetches once',
    () async {
      final held = await _holdInStampWrite(offer: true);
      final rig = held.rig;

      final joiner = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(
        rig.state,
        isA<UpdateChecking>(),
        reason: 'the joiner shows Checking while it waits',
      );

      held.stamp.writeGate!.complete();
      await joiner;
      await held.first;

      expect(
        rig.state,
        isA<UpdateAvailable>(),
        reason: 'the joiner adopts the check result',
      );
      expect(rig.fakes.fetcher.fetchCount, 1);
      expect(held.stamp.writes, [rig.clock.now()]);
    },
  );

  test(
    'a manual check joining the stamp write ends at Up to date and fetches once',
    () async {
      final held = await _holdInStampWrite(offer: false);
      final rig = held.rig;

      final joiner = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(rig.state, isA<UpdateChecking>());

      held.stamp.writeGate!.complete();
      await joiner;
      await held.first;

      expect(rig.state, isA<UpdateUpToDate>());
      expect(rig.fakes.fetcher.fetchCount, 1);
    },
  );

  test(
    'later then a manual check during the stamp write offers the update again',
    () async {
      final held = await _holdInStampWrite(offer: true);
      final rig = held.rig;
      final offered = (rig.state as UpdateAvailable).item;

      rig.controller.later();
      expect(rig.state, isA<UpdateIdle>());
      final joiner = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(rig.state, isA<UpdateChecking>());

      held.stamp.writeGate!.complete();
      await joiner;
      await held.first;

      expect(
        rig.state,
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(offered)),
      );
      expect(rig.fakes.fetcher.fetchCount, 1);
    },
  );

  test(
    'a launch check joining the stamp write answers true on Available',
    () async {
      final fakes = _HeldStampFakes();
      final rig = ControllerRig(fakes: fakes);
      fakes.fetcher.items = [newerItem()];
      fakes.lastCheck
        ..readGate = Completer<void>()
        ..writeGate = Completer<void>();

      // The launch stops at its due-check read, which straddles the menu
      // check below.
      final launch = rig.controller.launch();
      await pumpEventQueue();
      expect(fakes.lastCheck.readCount, 1, reason: 'setup: launch is reading');

      final menu = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(fakes.lastCheck.writes, hasLength(1), reason: 'setup: writing');
      expect(rig.state, isA<UpdateAvailable>());

      // The read ends (never stamped, so due) while the menu check writes.
      fakes.lastCheck.readGate!.complete();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateChecking>(), reason: 'launch has joined');

      fakes.lastCheck.writeGate!.complete();
      expect(await launch, isTrue);
      await menu;

      expect(rig.state, isA<UpdateAvailable>());
      expect(fakes.fetcher.fetchCount, 1);
      expect(fakes.lastCheck.writes, hasLength(1));
    },
  );

  test(
    'a launch check joining the stamp write answers false on Up to date',
    () async {
      final fakes = _HeldStampFakes();
      final rig = ControllerRig(fakes: fakes);
      fakes.fetcher.items = [];
      fakes.lastCheck
        ..readGate = Completer<void>()
        ..writeGate = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      final menu = rig.controller.check(manual: true);
      await pumpEventQueue();
      fakes.lastCheck.readGate!.complete();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateChecking>());

      fakes.lastCheck.writeGate!.complete();
      expect(await launch, isFalse);
      await menu;

      expect(rig.state, isA<UpdateUpToDate>());
    },
  );

  test('a check after a held stamp write finished fetches again', () async {
    final held = await _holdInStampWrite(offer: true);
    final rig = held.rig;

    held.stamp.writeGate!.complete();
    await held.first;
    await rig.controller.check(manual: true);

    expect(rig.fakes.fetcher.fetchCount, 2);
    expect(rig.state, isA<UpdateAvailable>());
  });
}
