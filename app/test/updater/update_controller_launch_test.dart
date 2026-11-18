// WI #37 (A3; Spec #31 req 11, 12, 26; D7, D8): the update controller's
// launch sequence and the 24-hour throttle. Time comes only from the
// harness's FakeClock; no test waits on wall-clock time.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/fake_clock.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';
import 'update_controller_doubles.dart';

const _day = Duration(hours: 24);
const _ms = Duration(milliseconds: 1);

void main() {
  test(
    'with updates disabled launch returns false and calls no port',
    () async {
      // Everything that would make an enabled launch act: a recorded failure,
      // a due check and an offered update.
      UpdaterFakes primed(UpdaterFakes f) {
        f.marker.reason = "the new app couldn't be copied";
        f.fetcher.items = [newerItem()];
        return f;
      }

      final off = ControllerRig(
        fakes: primed(UpdaterFakes()..updatesEnabled = false),
      );

      expect(await off.controller.launch(), isFalse);

      expect(off.fakes.downloader.deleteLeftoversCount, 0);
      expect(off.fakes.marker.takeCount, 0);
      expect(
        off.fakes.marker.reason,
        isNotNull,
        reason: 'marker left in place',
      );
      expect(off.fakes.lastCheck.readCount, 0);
      expect(off.fakes.lastCheck.writes, isEmpty);
      expect(off.fakes.fetcher.fetchCount, 0);
      expect(off.fakes.downloader.downloads, isEmpty);
      expect(off.states, isEmpty);
      expect(off.state, isA<UpdateIdle>());

      // Control: the same setup with updates on does act, so the counters
      // above would have seen a call.
      final on = ControllerRig(fakes: primed(UpdaterFakes()));
      expect(await on.controller.launch(), isTrue);
      expect(on.fakes.downloader.deleteLeftoversCount, 1);
      expect(on.fakes.marker.takeCount, 1);
    },
  );

  test(
    'launch deletes the leftover download directory then reads and clears the failure marker',
    () async {
      final fakes = LoggingUpdaterFakes();
      final rig = ControllerRig(fakes: fakes);

      await rig.controller.launch();

      final launchSteps = fakes.log
          .where(
            (e) => const {'deleteLeftovers', 'takeMarker', 'fetch'}.contains(e),
          )
          .toList();
      expect(launchSteps, ['deleteLeftovers', 'takeMarker', 'fetch']);
      expect(fakes.downloader.deleteLeftoversCount, 1);
      expect(fakes.marker.takeCount, 1);
    },
  );

  test(
    'launch deletes the leftover directory even when no check is due',
    () async {
      final fakes = LoggingUpdaterFakes();
      fakes.lastCheck.stamp = fakes.clock.now().subtract(
        const Duration(hours: 1),
      );
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isFalse);

      expect(fakes.log.take(2), ['deleteLeftovers', 'takeMarker']);
      expect(fakes.fetcher.fetchCount, 0);
    },
  );

  test(
    'a recorded failure reason makes launch show Error with that reason and skip the check',
    () async {
      const reason = "the new app's signature didn't verify";
      final fakes = UpdaterFakes();
      fakes.marker.reason = reason;
      fakes.fetcher.items = [newerItem()]; // a due check would offer this
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isTrue);

      expect(
        rig.state,
        isA<UpdateError>()
            .having((e) => e.cause, 'cause', UpdateErrorCause.failureRecorded)
            .having((e) => e.reason, 'reason', reason)
            .having((e) => e.item, 'item', isNull),
      );
      expect(fakes.fetcher.fetchCount, 0, reason: 'that launch runs no check');
      expect(fakes.lastCheck.writes, isEmpty);
      expect(fakes.marker.takeCount, 1);
      expect(fakes.marker.reason, isNull, reason: 'the marker is cleared');
    },
  );

  test('each fixed marker reason reaches the Error state unchanged', () async {
    for (final reason in const [
      "the disk image couldn't be opened",
      "the new app couldn't be copied",
      "the new app's signature didn't verify",
      "the new app couldn't be moved into place",
      "the app didn't quit in time",
    ]) {
      final fakes = UpdaterFakes();
      fakes.marker.reason = reason;
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isTrue, reason: reason);
      expect(
        rig.state,
        isA<UpdateError>().having((e) => e.reason, 'reason', reason),
        reason: reason,
      );
    }
  });

  test(
    'a recorded failure is shown once, the next launch checks as usual',
    () async {
      final fakes = UpdaterFakes();
      fakes.marker.reason = "the app didn't quit in time";
      final first = ControllerRig(fakes: fakes);
      expect(await first.controller.launch(), isTrue);

      // The next app run, same stores.
      final second = ControllerRig(fakes: fakes);
      expect(await second.controller.launch(), isFalse);
      expect(second.state, isNot(isA<UpdateError>()));
      expect(fakes.fetcher.fetchCount, 1, reason: 'the due check runs again');
    },
  );

  // AC: due when never stamped, or stamped exactly 24 hours ago or earlier.
  for (final (name, age) in [
    ('launch checks when the last check was never stamped', null),
    ('launch checks when the stamp is exactly 24 hours old', _day),
    ('launch checks when the stamp is more than 24 hours old', _day * 3),
  ]) {
    test(name, () async {
      final fakes = UpdaterFakes();
      fakes.lastCheck.stamp = age == null
          ? null
          : fakes.clock.now().subtract(age);
      final rig = ControllerRig(fakes: fakes);

      await rig.controller.launch();

      expect(fakes.fetcher.fetchCount, 1);
      expect(fakes.lastCheck.readCount, greaterThanOrEqualTo(1));
    });
  }

  test(
    'the throttle measures elapsed time across a time zone or DST change',
    () async {
      // The clock reads UTC; the stamp is the same instant 24 hours earlier
      // expressed in local time (as SharedPreferences hands it back).
      final now = DateTime.utc(2026, 11, 1, 12);
      final fakes = UpdaterFakes(clock: FakeClock(now));
      fakes.lastCheck.stamp = now.subtract(_day).toLocal();
      final rig = ControllerRig(fakes: fakes);

      await rig.controller.launch();

      expect(fakes.fetcher.fetchCount, 1);
    },
  );

  // AC: no check under 24 hours, or with a stamp in the future.
  for (final (name, offset) in [
    (
      'launch runs no check when the stamp is 1 ms short of 24 hours',
      -(_day - _ms),
    ),
    ('launch runs no check when the stamp was just written', Duration.zero),
    ('launch runs no check when the stamp lies 1 ms in the future', _ms),
    ('launch runs no check after a backward clock jump of 30 days', _day * 30),
  ]) {
    test(name, () async {
      final fakes = UpdaterFakes();
      final stamp = fakes.clock.now().add(offset);
      fakes.lastCheck.stamp = stamp;
      fakes.fetcher.items = [newerItem()];
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isFalse);

      expect(fakes.fetcher.fetchCount, 0);
      expect(fakes.lastCheck.writes, isEmpty);
      expect(fakes.lastCheck.stamp, stamp);
      // The launch itself ran: it cleaned up and read the stamp.
      expect(fakes.downloader.deleteLeftoversCount, 1);
      expect(fakes.marker.takeCount, 1);
      expect(fakes.lastCheck.readCount, greaterThanOrEqualTo(1));
    });
  }

  test('a launch check that finds an update returns true', () async {
    final fakes = UpdaterFakes();
    final item = newerItem();
    fakes.fetcher.items = [item];
    final rig = ControllerRig(fakes: fakes);

    expect(await rig.controller.launch(), isTrue);

    expect(
      rig.state,
      isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
    );
    expect(fakes.downloader.downloads, isEmpty, reason: 'nothing installs');
  });

  // AC: no update, offline or a failed check returns false (no modal).
  for (final (name, items, failure) in [
    (
      'a launch check that finds no update returns false',
      [testAppcastItem(shortVersionString: '1.2.3', version: '7')],
      null,
    ),
    ('a launch check of an empty channel returns false', <AppcastItem>[], null),
    (
      'a launch check that is offline returns false',
      [newerItem()],
      const UpdateFailure(UpdateErrorCause.offline),
    ),
    (
      'a launch check whose feed is unreadable returns false',
      [newerItem()],
      const UpdateFailure(UpdateErrorCause.feedUnreadable),
    ),
    (
      'a launch check with no Appcast published returns false',
      [newerItem()],
      const UpdateFailure(UpdateErrorCause.noAppcast),
    ),
  ]) {
    test(name, () async {
      final fakes = UpdaterFakes();
      fakes.fetcher
        ..items = List.of(items)
        ..failure = failure;
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isFalse);

      expect(fakes.fetcher.fetchCount, 1, reason: 'the due check ran');
      expect(rig.state, isNot(isA<UpdateAvailable>()));
    });
  }

  test('a launch check skips an item whose minimum macOS is newer', () async {
    final fakes = UpdaterFakes()..runningMacos = null;
    // Control first: an unknown running macOS meets every minimum.
    fakes.fetcher.items = [
      testAppcastItem(minimumSystemVersion: '99.0', version: '9'),
    ];
    final unknown = ControllerRig(fakes: fakes);
    expect(await unknown.controller.launch(), isTrue);

    final tooOld = UpdaterFakes(); // macOS 15.1
    tooOld.fetcher.items = [
      testAppcastItem(minimumSystemVersion: '15.2', version: '9'),
    ];
    final rig = ControllerRig(fakes: tooOld);
    expect(await rig.controller.launch(), isFalse);
    expect(tooOld.fetcher.fetchCount, 1);
    expect(rig.state, isA<UpdateUpToDate>());
  });

  // AC: a fetched and parsed check stamps the clock's time; a failed one
  // leaves the stamp.
  for (final (name, items) in [
    (
      'a launch check that finds an update stamps the last check',
      [newerItem()],
    ),
    (
      'a launch check that finds no update stamps the last check',
      [testAppcastItem(shortVersionString: '1.2.0', version: '5')],
    ),
  ]) {
    test(name, () async {
      final fakes = UpdaterFakes();
      final old = fakes.clock.now().subtract(_day * 2);
      fakes.lastCheck.stamp = old;
      fakes.fetcher.items = items;
      final rig = ControllerRig(fakes: fakes);

      await rig.controller.launch();

      expect(fakes.lastCheck.writes, [fakes.clock.now()]);
      expect(fakes.lastCheck.stamp, fakes.clock.now());
    });
  }

  for (final (name, cause) in const [
    (
      'an offline launch check leaves the stamp unchanged',
      UpdateErrorCause.offline,
    ),
    (
      'an unreadable feed launch check leaves the stamp unchanged',
      UpdateErrorCause.feedUnreadable,
    ),
    (
      'a launch check with no Appcast leaves the stamp unchanged',
      UpdateErrorCause.noAppcast,
    ),
  ]) {
    test(name, () async {
      final fakes = UpdaterFakes();
      final old = fakes.clock.now().subtract(_day * 2);
      fakes.lastCheck.stamp = old;
      fakes.fetcher.failure = UpdateFailure(cause);
      final rig = ControllerRig(fakes: fakes);

      expect(await rig.controller.launch(), isFalse);

      expect(fakes.fetcher.fetchCount, 1);
      expect(fakes.lastCheck.writes, isEmpty);
      expect(fakes.lastCheck.stamp, old);
      // So the next launch checks again.
      final next = ControllerRig(fakes: fakes);
      fakes.fetcher.failure = null;
      await next.controller.launch();
      expect(fakes.fetcher.fetchCount, 2);
    });
  }
}
