// WI #37 (A3; Spec #31 req 11, 17, 26; D8, D20), fix round 1: the launch
// sequence and a menu check or install running at the same time (the menu is
// live from the first frame), and the folder and reason an Error keeps. Every
// in-flight call is held with a completer, never a wall-clock wait.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';
import 'update_controller_doubles.dart';

const _recorded = 'the new app could not be copied';

/// A marker store whose take waits for [gate] when it is set.
class _GatedMarker extends FakeFailureMarkerStore {
  Completer<void>? gate;

  @override
  Future<String?> take() async {
    final g = gate;
    if (g != null) await g.future;
    return super.take();
  }
}

/// A last-check store whose read answers the stamp as it was when the read
/// began, but only once [gate] completes (when it is set).
class _GatedLastCheck extends FakeLastCheckStore {
  Completer<void>? gate;

  @override
  Future<DateTime?> read() async {
    final stamp = await super.read();
    final g = gate;
    if (g != null) await g.future;
    return stamp;
  }
}

/// A downloader whose leftover delete waits for [gate] (then throws
/// [deleteFailure] when set) and which notes whether the delete had finished
/// when a download began.
class _GatedDownloader extends FakeUpdateDownloader {
  Completer<void>? gate;
  UpdateFailure? deleteFailure;
  bool deleteDone = false;

  /// [deleteDone] at the moment each download started.
  final List<bool> deleteDoneAtDownload = [];

  @override
  Future<void> deleteLeftovers() async {
    deleteLeftoversCount++;
    final g = gate;
    if (g != null) await g.future;
    deleteDone = true;
    final f = deleteFailure;
    if (f != null) throw f;
  }

  @override
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  }) {
    deleteDoneAtDownload.add(deleteDone);
    return super.download(item, onProgress: onProgress);
  }
}

/// [UpdaterFakes] with a gate on the marker take, the stamp read and the
/// leftover delete.
class _GatedFakes extends UpdaterFakes {
  final _marker = _GatedMarker();
  final _stamp = _GatedLastCheck();
  final _downloader = _GatedDownloader();

  @override
  _GatedMarker get marker => _marker;
  @override
  _GatedLastCheck get lastCheck => _stamp;
  @override
  _GatedDownloader get downloader => _downloader;
}

void main() {
  test(
    'launch runs once and a second call answers false and calls no port',
    () async {
      final rig = ControllerRig();
      rig.fakes.fetcher.items = [newerItem()];

      expect(await rig.controller.launch(), isTrue);
      final fakes = rig.fakes;
      expect(fakes.downloader.deleteLeftoversCount, 1);
      expect(fakes.marker.takeCount, 1);
      expect(fakes.lastCheck.readCount, 1);
      expect(fakes.fetcher.fetchCount, 1);

      expect(await rig.controller.launch(), isFalse);

      expect(fakes.downloader.deleteLeftoversCount, 1);
      expect(fakes.marker.takeCount, 1);
      expect(fakes.lastCheck.readCount, 1);
      expect(fakes.fetcher.fetchCount, 1);
      expect(rig.state, isA<UpdateAvailable>());
    },
  );

  test('a second launch while Ready keeps the staged download', () async {
    final rig = ControllerRig();
    rig.fakes.fetcher.items = [newerItem()];
    await rig.controller.launch();
    await rig.controller.install();
    expect(rig.state, isA<UpdateReady>());

    expect(await rig.controller.launch(), isFalse);

    expect(rig.fakes.downloader.deleteLeftoversCount, 1);
    expect(rig.state, isA<UpdateReady>());
  });

  test(
    'a recorded failure holds Error when a manual check was fetching meanwhile',
    () async {
      final fakes = _GatedFakes()..marker.gate = Completer<void>();
      final rig = ControllerRig(fakes: fakes);
      fakes.marker.reason = _recorded;
      fakes.fetcher
        ..items = [newerItem()]
        ..hold = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      expect(fakes.marker.takeCount, 0, reason: 'launch waits at the marker');
      final manual = rig.controller.check(manual: true);
      await pumpEventQueue();
      expect(rig.state, isA<UpdateChecking>());

      fakes.marker.gate!.complete();
      expect(await launch, isTrue);
      expect(
        rig.state,
        isA<UpdateError>()
            .having((e) => e.cause, 'cause', UpdateErrorCause.failureRecorded)
            .having((e) => e.reason, 'reason', _recorded),
      );

      fakes.fetcher.hold!.complete();
      await manual;

      expect(
        rig.state,
        isA<UpdateError>().having((e) => e.reason, 'reason', _recorded),
        reason: 'the late check result does not overwrite the failure',
      );
      expect(fakes.lastCheck.writes, isEmpty, reason: 'a dropped check');
      expect(fakes.fetcher.fetchCount, 1);
    },
  );

  test(
    'a recorded failure holds Error when a manual check failed meanwhile',
    () async {
      final fakes = _GatedFakes()..marker.gate = Completer<void>();
      final rig = ControllerRig(fakes: fakes);
      fakes.marker.reason = _recorded;
      fakes.fetcher
        ..failure = const UpdateFailure(UpdateErrorCause.offline)
        ..hold = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      final manual = rig.controller.check(manual: true);
      await pumpEventQueue();
      fakes.marker.gate!.complete();
      expect(await launch, isTrue);

      fakes.fetcher.hold!.complete();
      await manual;

      expect(
        rig.state,
        isA<UpdateError>()
            .having((e) => e.cause, 'cause', UpdateErrorCause.failureRecorded)
            .having((e) => e.reason, 'reason', _recorded),
        reason: 'the late offline result does not overwrite the failure',
      );
      expect(fakes.lastCheck.writes, isEmpty);
    },
  );

  test(
    'a recorded failure arriving while a download runs is dropped and launch answers false',
    () async {
      final fakes = _GatedFakes()..marker.gate = Completer<void>();
      final rig = ControllerRig(fakes: fakes);
      fakes.marker.reason = _recorded;
      fakes.downloader.hold = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      await driveToAvailable(rig);
      final install = rig.controller.install();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateDownloading>());

      fakes.marker.gate!.complete();
      expect(await launch, isFalse);
      expect(rig.state, isA<UpdateDownloading>());
      expect(fakes.marker.takeCount, 1, reason: 'the marker is still read');

      fakes.downloader.hold!.complete();
      await install;
      expect(rig.state, isA<UpdateReady>());
      expect(
        rig.states.whereType<UpdateError>(),
        isEmpty,
        reason: 'no Error was ever shown',
      );
    },
  );

  test(
    'a recorded failure arriving once an update is Ready is dropped and launch answers false',
    () async {
      final fakes = _GatedFakes()..marker.gate = Completer<void>();
      final rig = ControllerRig(fakes: fakes);
      fakes.marker.reason = _recorded;

      final launch = rig.controller.launch();
      await pumpEventQueue();
      await driveToReady(rig);

      fakes.marker.gate!.complete();
      expect(await launch, isFalse);

      expect(rig.state, isA<UpdateReady>());
      expect(rig.states.whereType<UpdateError>(), isEmpty);
    },
  );

  test(
    'a launch check whose stamp read ends after an install began fetches nothing more',
    () async {
      final fakes = _GatedFakes()..lastCheck.gate = Completer<void>();
      final rig = ControllerRig(fakes: fakes);
      fakes.downloader.hold = Completer<void>();

      final launch = rig.controller.launch();
      await pumpEventQueue();
      expect(fakes.lastCheck.readCount, 1, reason: 'launch waits at the stamp');
      await driveToAvailable(rig);
      expect(fakes.fetcher.fetchCount, 1);
      final install = rig.controller.install();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateDownloading>());

      fakes.lastCheck.gate!.complete(); // the stamp is null: a check is due
      expect(await launch, isFalse, reason: 'no update is offered to open');

      expect(fakes.fetcher.fetchCount, 1, reason: 'no second fetch');
      expect(rig.state, isA<UpdateDownloading>());
      expect(rig.states.whereType<UpdateChecking>(), hasLength(1));

      fakes.downloader.hold!.complete();
      await install;
      expect(rig.state, isA<UpdateReady>());
    },
  );

  group('the leftover delete', () {
    test('is skipped when the launch begins with an update Ready', () async {
      final rig = ControllerRig();
      await driveToReady(rig);

      expect(await rig.controller.launch(), isFalse);

      expect(rig.fakes.downloader.deleteLeftoversCount, 0);
      expect(rig.state, isA<UpdateReady>());
      expect(rig.fakes.fetcher.fetchCount, 1, reason: 'no new check either');
    });

    test('is skipped when the launch begins while Downloading', () async {
      final rig = ControllerRig();
      await driveToAvailable(rig);
      rig.fakes.downloader.hold = Completer<void>();
      final install = rig.controller.install();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateDownloading>());

      expect(await rig.controller.launch(), isFalse);

      expect(rig.fakes.downloader.deleteLeftoversCount, 0);
      expect(rig.state, isA<UpdateDownloading>());
      expect(rig.fakes.fetcher.fetchCount, 1);

      rig.fakes.downloader.hold!.complete();
      await install;
      expect(rig.state, isA<UpdateReady>());
    });

    test('is skipped when the launch begins while Verifying', () async {
      final rig = ControllerRig();
      await driveToAvailable(rig);
      rig.fakes.verifier.hold = Completer<void>();
      final install = rig.controller.install();
      await pumpEventQueue();
      expect(rig.state, isA<UpdateVerifying>());

      expect(await rig.controller.launch(), isFalse);

      expect(rig.fakes.downloader.deleteLeftoversCount, 0);
      expect(rig.state, isA<UpdateVerifying>());
      expect(rig.fakes.fetcher.fetchCount, 1);

      rig.fakes.verifier.hold!.complete();
      await install;
      expect(rig.state, isA<UpdateReady>());
    });

    test(
      'finishes before a download started meanwhile begins writing',
      () async {
        final fakes = _GatedFakes()..downloader.gate = Completer<void>();
        final rig = ControllerRig(fakes: fakes);
        final launch = rig.controller.launch();
        await pumpEventQueue();
        expect(fakes.downloader.deleteLeftoversCount, 1);
        await driveToAvailable(rig);

        final install = rig.controller.install();
        await pumpEventQueue();
        expect(rig.state, isA<UpdateDownloading>());
        expect(
          fakes.downloader.downloads,
          isEmpty,
          reason: 'the download waits for the delete',
        );

        fakes.downloader.gate!.complete();
        await install;
        await launch;

        expect(fakes.downloader.deleteDoneAtDownload, [true]);
        expect(rig.state, isA<UpdateReady>());
      },
    );

    test(
      'failing does not fail a download started meanwhile but launch still throws it',
      () async {
        final fakes = _GatedFakes()
          ..downloader.gate = Completer<void>()
          ..downloader.deleteFailure = const UpdateFailure(
            UpdateErrorCause.folderNotWritable,
            folder: '/updater-test',
          );
        final rig = ControllerRig(fakes: fakes);
        final launch = rig.controller.launch();
        final thrown = expectLater(
          launch,
          throwsA(
            isA<UpdateFailure>().having(
              (f) => f.cause,
              'cause',
              UpdateErrorCause.folderNotWritable,
            ),
          ),
        );
        await pumpEventQueue();
        await driveToAvailable(rig);
        final install = rig.controller.install();
        await pumpEventQueue();

        fakes.downloader.gate!.complete();
        await install;
        await thrown;

        expect(rig.state, isA<UpdateReady>());
        expect(fakes.downloader.downloads, hasLength(1));
      },
    );

    test('does not delay a download once the launch has finished', () async {
      final fakes = _GatedFakes();
      final rig = ControllerRig(fakes: fakes);
      await rig.controller.launch();
      await driveToAvailable(rig);

      await rig.controller.install();

      expect(fakes.downloader.deleteDoneAtDownload, [true]);
      expect(fakes.downloader.deleteLeftoversCount, 1);
      expect(rig.state, isA<UpdateReady>());
    });
  });

  group('an Error keeps its folder and reason', () {
    const failure = UpdateFailure(
      UpdateErrorCause.folderNotWritable,
      folder: '/updater-test',
      reason: 'a reason from the port',
    );

    Matcher carries({AppcastItem? item}) {
      var m = isA<UpdateError>()
          .having((e) => e.cause, 'cause', failure.cause)
          .having((e) => e.folder, 'folder', failure.folder)
          .having((e) => e.reason, 'reason', failure.reason);
      if (item != null) m = m.having((e) => e.item, 'item', same(item));
      return m;
    }

    test('when a check fails', () async {
      final rig = ControllerRig();
      rig.fakes.fetcher.failure = failure;

      await rig.controller.check(manual: true);

      expect(rig.state, carries());
      expect((rig.state as UpdateError).item, isNull);
    });

    test('when a download fails', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      rig.fakes.downloader.failure = failure;

      await rig.controller.install();

      expect(rig.state, carries(item: item));
    });

    test('when a verify fails', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      rig.fakes.verifier.failure = failure;

      await rig.controller.install();

      expect(rig.state, carries(item: item));
    });
  });
}
