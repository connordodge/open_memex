// WI #37 (A3; Spec #31 req 9, 11, 15, 16, 16a, 17, 20; D2, D20): the update
// controller's manual check, install, later and try again transitions over
// the shared fakes. The verifier fake is synchronous (no isolate, D6), and
// in-flight work is held with completers, never wall-clock waits.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';
import 'update_controller_doubles.dart';

void main() {
  group('manual check', () {
    test('a manual check goes Checking then Up to date', () async {
      final rig = ControllerRig();
      rig.fakes.fetcher.items = [
        testAppcastItem(shortVersionString: '1.2.3', version: '7'),
      ];

      await rig.controller.check(manual: true);

      expect(rig.states, [isA<UpdateChecking>(), isA<UpdateUpToDate>()]);
      expect(rig.fakes.fetcher.fetchCount, 1);
    });

    test('a manual check goes Checking then Available', () async {
      final rig = ControllerRig();
      final item = newerItem();
      rig.fakes.fetcher.items = [
        testAppcastItem(shortVersionString: '1.2.4', version: '8'),
        item,
      ];

      await rig.controller.check(manual: true);

      expect(rig.states, [
        isA<UpdateChecking>(),
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
      ]);
      expect(
        rig.fakes.downloader.downloads,
        isEmpty,
        reason: 'no auto install',
      );
    });

    for (final (name, cause) in const [
      (
        'a manual check that is offline goes Checking then Error offline',
        UpdateErrorCause.offline,
      ),
      (
        'a manual check of an unreadable feed goes Checking then Error feedUnreadable',
        UpdateErrorCause.feedUnreadable,
      ),
      (
        'a manual check with no Appcast goes Checking then Error noAppcast',
        UpdateErrorCause.noAppcast,
      ),
    ]) {
      test(name, () async {
        final rig = ControllerRig();
        rig.fakes.fetcher.failure = UpdateFailure(cause);

        await rig.controller.check(manual: true);

        expect(rig.states, [
          isA<UpdateChecking>(),
          isA<UpdateError>()
              .having((e) => e.cause, 'cause', cause)
              .having((e) => e.item, 'item', isNull),
        ]);
      });
    }

    test('a manual check is never throttled by a fresh stamp', () async {
      final fakes = UpdaterFakes();
      fakes.lastCheck.stamp = fakes.clock.now();
      final rig = ControllerRig(fakes: fakes);
      fakes.fetcher.items = [newerItem()];

      await rig.controller.check(manual: true);
      await rig.controller.check(manual: true);

      expect(fakes.fetcher.fetchCount, 2);
      expect(rig.state, isA<UpdateAvailable>());
    });

    test(
      'a manual check is never throttled by a stamp in the future',
      () async {
        final fakes = UpdaterFakes();
        fakes.lastCheck.stamp = fakes.clock.now().add(const Duration(days: 3));
        final rig = ControllerRig(fakes: fakes);

        await rig.controller.check(manual: true);

        expect(fakes.fetcher.fetchCount, 1);
        expect(rig.state, isA<UpdateUpToDate>());
      },
    );

    test('a manual check offers only a strictly newer item', () async {
      final rig = ControllerRig();
      rig.fakes.fetcher.items = [
        testAppcastItem(shortVersionString: '1.2.2', version: '99'),
        testAppcastItem(shortVersionString: '1.2.3', version: '7'),
      ];
      await rig.controller.check(manual: true);
      expect(rig.state, isA<UpdateUpToDate>(), reason: 'older and equal');

      // Equal x.y.z with a higher build than the installed 7 is newer.
      final rebuilt = testAppcastItem(
        shortVersionString: '1.2.3',
        version: '8',
      );
      rig.fakes.fetcher.items = [rebuilt];
      await rig.controller.check(manual: true);
      expect(
        rig.state,
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(rebuilt)),
      );
    });

    test('a manual check of an empty channel is Up to date', () async {
      final rig = ControllerRig();

      await rig.controller.check(manual: true);

      expect(rig.states, [isA<UpdateChecking>(), isA<UpdateUpToDate>()]);
    });

    test(
      'a manual check does not offer an item that needs a newer macOS',
      () async {
        final rig = ControllerRig(); // macOS 15.1
        rig.fakes.fetcher.items = [
          testAppcastItem(minimumSystemVersion: '15.2', version: '9'),
        ];

        await rig.controller.check(manual: true);

        expect(rig.states, [isA<UpdateChecking>(), isA<UpdateUpToDate>()]);
      },
    );

    for (final (name, items) in [
      (
        'a manual check that finds an update stamps the last check',
        [newerItem()],
      ),
      (
        'a manual check that finds no update stamps the last check',
        [testAppcastItem(shortVersionString: '1.0.0', version: '1')],
      ),
    ]) {
      test(name, () async {
        final fakes = UpdaterFakes();
        fakes.lastCheck.stamp = fakes.clock.now().subtract(
          const Duration(days: 9),
        );
        fakes.clock.advance(const Duration(minutes: 5));
        fakes.fetcher.items = items;
        final rig = ControllerRig(fakes: fakes);

        await rig.controller.check(manual: true);

        expect(fakes.lastCheck.writes, [fakes.clock.now()]);
      });
    }

    test('a failed manual check leaves the stamp unchanged', () async {
      final fakes = UpdaterFakes();
      final old = fakes.clock.now().subtract(const Duration(hours: 30));
      fakes.lastCheck.stamp = old;
      fakes.fetcher.failure = const UpdateFailure(UpdateErrorCause.offline);
      final rig = ControllerRig(fakes: fakes);

      await rig.controller.check(manual: true);

      expect(rig.state, isUpdateError(UpdateErrorCause.offline));
      expect(fakes.lastCheck.writes, isEmpty);
      expect(fakes.lastCheck.stamp, old);
    });

    test('a manual check while Ready keeps Ready', () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);
      final fetches = rig.fakes.fetcher.fetchCount;
      rig.states.clear();

      await rig.controller.check(manual: true);

      expect(rig.state, same(ready));
      expect(rig.states, isEmpty, reason: 'never passes through Checking');
      expect(rig.fakes.fetcher.fetchCount, fetches);
    });

    test(
      'a manual check while Downloading keeps Downloading and makes no fetch',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        final hold = Completer<void>();
        rig.fakes.downloader.hold = hold;
        final install = rig.controller.install();
        await pumpEventQueue();
        final downloading = rig.state;
        expect(downloading, isA<UpdateDownloading>());
        final fetches = rig.fakes.fetcher.fetchCount;

        await rig.controller.check(manual: true);

        expect(rig.state, same(downloading));
        expect(rig.fakes.fetcher.fetchCount, fetches);

        hold.complete();
        await install;
        expect(
          rig.state,
          isA<UpdateReady>().having((s) => s.item, 'item', same(item)),
        );
        expect(rig.fakes.downloader.downloads, hasLength(1));
      },
    );

    test(
      'a manual check while Verifying keeps Verifying and makes no fetch',
      () async {
        final rig = ControllerRig();
        await driveToAvailable(rig);
        final hold = Completer<void>();
        rig.fakes.verifier.hold = hold;
        final install = rig.controller.install();
        await pumpEventQueue();
        final verifying = rig.state;
        expect(verifying, isA<UpdateVerifying>());
        final fetches = rig.fakes.fetcher.fetchCount;

        await rig.controller.check(manual: true);

        expect(rig.state, same(verifying));
        expect(rig.fakes.fetcher.fetchCount, fetches);

        hold.complete();
        await install;
        expect(rig.state, isA<UpdateReady>());
      },
    );

    test(
      'a manual check after a background install failure runs a new check',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        rig.fakes.downloader.failure = const UpdateFailure(
          UpdateErrorCause.downloadFailed,
        );
        await rig.controller.install();
        expect(rig.state, isUpdateError(UpdateErrorCause.downloadFailed));
        final fetches = rig.fakes.fetcher.fetchCount;
        rig.states.clear();

        await rig.controller.check(manual: true);

        expect(rig.fakes.fetcher.fetchCount, fetches + 1);
        expect(rig.states, [
          isA<UpdateChecking>(),
          isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
        ]);
      },
    );
  });

  group('install', () {
    test(
      'install goes Available then Downloading with progress then Verifying then Ready',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        final hold = Completer<void>();
        rig.fakes.downloader
          ..hold = hold
          ..progress = [0.5, 1.0];
        rig.states.clear();

        final install = rig.controller.install();
        await pumpEventQueue();
        expect(
          rig.state,
          isA<UpdateDownloading>().having((s) => s.item, 'item', same(item)),
        );
        rig.fakes.downloader.onProgress!(0.25);
        expect(
          rig.state,
          isA<UpdateDownloading>()
              .having((s) => s.item, 'item', same(item))
              .having((s) => s.progress, 'progress', 0.25),
        );
        hold.complete();
        await install;

        final progress = rig.states
            .whereType<UpdateDownloading>()
            .map((s) => s.progress)
            .toList();
        expect(progress, containsAllInOrder([0.25, 0.5, 1.0]));
        expect(progress.last, 1.0);
        final kinds = rig.states.map((s) => s.runtimeType).toSet().toList();
        expect(kinds, [UpdateDownloading, UpdateVerifying, UpdateReady]);
        expect(
          rig.state,
          isA<UpdateReady>()
              .having((s) => s.item, 'item', same(item))
              .having(
                (s) => s.dmgPath,
                'dmgPath',
                rig.fakes.downloader.dmgPath,
              ),
        );
        expect(rig.fakes.downloader.downloads, [same(item)]);
        expect(rig.fakes.verifier.calls, [
          (
            dmgPath: rig.fakes.downloader.dmgPath,
            edSignature: item.edSignature,
          ),
        ]);
      },
    );

    test('an unknown download length shows indeterminate progress', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      final hold = Completer<void>();
      rig.fakes.downloader.hold = hold;

      final install = rig.controller.install();
      await pumpEventQueue();
      rig.fakes.downloader.onProgress!(0.4);
      rig.fakes.downloader.onProgress!(null);

      expect(
        rig.state,
        isA<UpdateDownloading>()
            .having((s) => s.item, 'item', same(item))
            .having((s) => s.progress, 'progress', isNull),
      );
      hold.complete();
      await install;
    });

    test('install verifies only after the download finishes', () async {
      final fakes = LoggingUpdaterFakes();
      final rig = ControllerRig(fakes: fakes);
      await driveToAvailable(rig);
      fakes.log.clear();

      await rig.controller.install();

      expect(fakes.log, ['download', 'verify']);
    });

    test(
      'a download failure goes to Error downloadFailed with the item',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        rig.fakes.downloader.failure = const UpdateFailure(
          UpdateErrorCause.downloadFailed,
        );

        await rig.controller.install();

        expect(
          rig.state,
          isUpdateError(UpdateErrorCause.downloadFailed, item: same(item)),
        );
        expect(rig.fakes.verifier.calls, isEmpty, reason: 'nothing to verify');
      },
    );

    for (final (name, cause) in const [
      (
        'a bad signature goes to Error badSignature with the item',
        UpdateErrorCause.badSignature,
      ),
      (
        'a missing signature goes to Error noSignature with the item',
        UpdateErrorCause.noSignature,
      ),
      (
        'no built in public key goes to Error noPublicKey with the item',
        UpdateErrorCause.noPublicKey,
      ),
    ]) {
      test(name, () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        rig.fakes.verifier.failure = UpdateFailure(cause);
        rig.states.clear();

        await rig.controller.install();

        expect(rig.states.last, isUpdateError(cause, item: same(item)));
        expect(rig.states.whereType<UpdateVerifying>(), hasLength(1));
        expect(rig.states.whereType<UpdateReady>(), isEmpty);
      });
    }

    test('install does nothing unless an update is Available', () async {
      final rig = ControllerRig();
      await rig.controller.install();
      expect(rig.fakes.downloader.downloads, isEmpty);
      expect(rig.states, isEmpty);

      // Control: from Available it does download.
      await driveToAvailable(rig);
      await rig.controller.install();
      expect(rig.fakes.downloader.downloads, hasLength(1));
    });

    test('two install calls in the same frame start one download', () async {
      final rig = ControllerRig();
      await driveToAvailable(rig);
      final hold = Completer<void>();
      rig.fakes.downloader.hold = hold;

      final first = rig.controller.install();
      final second = rig.controller.install();
      await pumpEventQueue();
      expect(rig.fakes.downloader.downloads, hasLength(1));

      hold.complete();
      await Future.wait([first, second]);
      expect(rig.fakes.downloader.downloads, hasLength(1));
      expect(rig.fakes.verifier.calls, hasLength(1));
      expect(rig.state, isA<UpdateReady>());
    });
  });

  group('later', () {
    test('later on Available goes to Idle', () async {
      final rig = ControllerRig();
      await driveToAvailable(rig);

      rig.controller.later();

      expect(rig.state, isA<UpdateIdle>());
      expect(rig.fakes.downloader.downloads, isEmpty);
    });

    test('after later the next manual check offers the update again', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      rig.controller.later();

      await rig.controller.check(manual: true);

      expect(
        rig.state,
        isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
      );
    });

    test(
      'after later the next due launch check offers the update again',
      () async {
        final fakes = UpdaterFakes();
        final item = newerItem();
        fakes.fetcher.items = [item];
        final first = ControllerRig(fakes: fakes);
        expect(await first.controller.launch(), isTrue);
        first.controller.later();
        expect(first.state, isA<UpdateIdle>());

        // A day later the next launch is due and offers it again.
        fakes.clock.advance(const Duration(hours: 24));
        final next = ControllerRig(fakes: fakes);
        expect(await next.controller.launch(), isTrue);
        expect(
          next.state,
          isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
        );
        expect(fakes.fetcher.fetchCount, 2);
      },
    );

    test(
      'later during Downloading lets the download finish at Ready without a modal',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        final hold = Completer<void>();
        rig.fakes.downloader.hold = hold;
        final install = rig.controller.install();
        await pumpEventQueue();
        final downloading = rig.state;
        expect(downloading, isA<UpdateDownloading>());

        rig.controller.later();
        expect(rig.state, same(downloading), reason: 'the work keeps running');

        hold.complete();
        await install;
        expect(
          rig.state,
          isA<UpdateReady>().having((s) => s.item, 'item', same(item)),
        );
        // Ready holds: nothing moves it on its own.
        await pumpEventQueue();
        expect(rig.state, isA<UpdateReady>());
      },
    );

    test(
      'later during Verifying lets the verify finish at Ready without a modal',
      () async {
        final rig = ControllerRig();
        await driveToAvailable(rig);
        final hold = Completer<void>();
        rig.fakes.verifier.hold = hold;
        final install = rig.controller.install();
        await pumpEventQueue();
        final verifying = rig.state;
        expect(verifying, isA<UpdateVerifying>());

        rig.controller.later();
        expect(rig.state, same(verifying));

        hold.complete();
        await install;
        expect(rig.state, isA<UpdateReady>());
      },
    );

    test('a failure after later holds Error with its cause', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      final hold = Completer<void>();
      rig.fakes.downloader
        ..hold = hold
        ..failure = const UpdateFailure(UpdateErrorCause.downloadFailed);
      final install = rig.controller.install();
      await pumpEventQueue();
      rig.controller.later();

      hold.complete();
      await install;
      await pumpEventQueue();

      expect(
        rig.state,
        isUpdateError(UpdateErrorCause.downloadFailed, item: same(item)),
      );
    });

    test('a verify failure after later holds Error with its cause', () async {
      final rig = ControllerRig();
      final item = await driveToAvailable(rig);
      final hold = Completer<void>();
      rig.fakes.verifier
        ..hold = hold
        ..failure = const UpdateFailure(UpdateErrorCause.badSignature);
      final install = rig.controller.install();
      await pumpEventQueue();
      rig.controller.later();

      hold.complete();
      await install;

      expect(
        rig.state,
        isUpdateError(UpdateErrorCause.badSignature, item: same(item)),
      );
    });

    test('later on Ready keeps the staged update Ready', () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);

      rig.controller.later();

      expect(rig.state, same(ready));
    });
  });

  group('try again', () {
    for (final (name, cause) in const [
      (
        'try again after an offline error runs a new check',
        UpdateErrorCause.offline,
      ),
      (
        'try again after a feed unreadable error runs a new check',
        UpdateErrorCause.feedUnreadable,
      ),
      (
        'try again after a no Appcast error runs a new check',
        UpdateErrorCause.noAppcast,
      ),
    ]) {
      test(name, () async {
        final fakes = UpdaterFakes();
        fakes.fetcher.failure = UpdateFailure(cause);
        final rig = ControllerRig(fakes: fakes);
        await rig.controller.check(manual: true);
        expect(rig.state, isUpdateError(cause));
        final item = newerItem();
        fakes.fetcher
          ..failure = null
          ..items = [item];
        rig.states.clear();

        await rig.controller.tryAgain();

        expect(fakes.fetcher.fetchCount, 2);
        expect(rig.states, [
          isA<UpdateChecking>(),
          isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
        ]);
      });
    }

    test('try again after a failure recorded error runs a new check', () async {
      final fakes = UpdaterFakes();
      fakes.marker.reason = "the app didn't quit in time";
      fakes.lastCheck.stamp = fakes.clock.now(); // try again never throttles
      final rig = ControllerRig(fakes: fakes);
      expect(await rig.controller.launch(), isTrue);
      expect(rig.state, isUpdateError(UpdateErrorCause.failureRecorded));
      expect(fakes.fetcher.fetchCount, 0);
      rig.states.clear();

      await rig.controller.tryAgain();

      expect(fakes.fetcher.fetchCount, 1);
      expect(rig.states, [isA<UpdateChecking>(), isA<UpdateUpToDate>()]);
    });

    for (final (name, cause, viaVerifier) in const [
      (
        'try again after a bad signature error downloads the same item again',
        UpdateErrorCause.badSignature,
        true,
      ),
      (
        'try again after a no signature error downloads the same item again',
        UpdateErrorCause.noSignature,
        true,
      ),
      (
        'try again after a download failed error downloads the same item again',
        UpdateErrorCause.downloadFailed,
        false,
      ),
    ]) {
      test(name, () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        final failure = UpdateFailure(cause);
        if (viaVerifier) {
          rig.fakes.verifier.failure = failure;
        } else {
          rig.fakes.downloader.failure = failure;
        }
        await rig.controller.install();
        expect(rig.state, isUpdateError(cause, item: same(item)));
        rig.fakes.verifier.failure = null;
        rig.fakes.downloader.failure = null;
        // The feed now offers something else: try again must not re-check.
        rig.fakes.fetcher.items = [newerItem(shortVersionString: '2.0.0')];
        final fetches = rig.fakes.fetcher.fetchCount;
        rig.states.clear();

        await rig.controller.tryAgain();

        expect(rig.fakes.downloader.downloads, [same(item), same(item)]);
        expect(rig.fakes.fetcher.fetchCount, fetches);
        expect(rig.states.first, isA<UpdateDownloading>());
        expect(
          rig.state,
          isA<UpdateReady>().having((s) => s.item, 'item', same(item)),
        );
      });
    }

    test('try again after a no public key error does nothing', () async {
      final rig = ControllerRig();
      await driveToAvailable(rig);
      rig.fakes.verifier.failure = const UpdateFailure(
        UpdateErrorCause.noPublicKey,
      );
      await rig.controller.install();
      final error = rig.state;
      expect(error, isUpdateError(UpdateErrorCause.noPublicKey));
      rig.fakes.verifier.failure = null;
      final fetches = rig.fakes.fetcher.fetchCount;
      rig.states.clear();

      await rig.controller.tryAgain();

      expect(rig.state, same(error));
      expect(rig.states, isEmpty);
      expect(rig.fakes.fetcher.fetchCount, fetches);
      expect(rig.fakes.downloader.downloads, hasLength(1));
    });

    for (final (name, failure) in const [
      (
        'try again after a folder not writable error does nothing',
        UpdateFailure(
          UpdateErrorCause.folderNotWritable,
          folder: '/Applications',
        ),
      ),
      (
        'try again after a disk image error does nothing',
        UpdateFailure(UpdateErrorCause.diskImage),
      ),
    ]) {
      test(name, () async {
        final rig = ControllerRig();
        await driveToReady(rig);
        rig.fakes.location.failure = failure;
        await rig.controller.relaunch(confirmQuit: () async => true);
        final error = rig.state;
        expect(error, isUpdateError(failure.cause));
        rig.fakes.location.failure = null;
        final fetches = rig.fakes.fetcher.fetchCount;
        final checks = rig.fakes.location.checkCount;
        rig.states.clear();

        await rig.controller.tryAgain();

        expect(rig.state, same(error));
        expect(rig.states, isEmpty);
        expect(rig.fakes.fetcher.fetchCount, fetches);
        expect(rig.fakes.downloader.downloads, hasLength(1));
        expect(rig.fakes.location.checkCount, checks);
        expect(rig.fakes.helper.starts, isEmpty);
      });
    }

    test(
      'two try again calls in the same frame after a download failure start one download',
      () async {
        final rig = ControllerRig();
        final item = await driveToAvailable(rig);
        rig.fakes.downloader.failure = const UpdateFailure(
          UpdateErrorCause.downloadFailed,
        );
        await rig.controller.install();
        expect(rig.state, isUpdateError(UpdateErrorCause.downloadFailed));
        rig.fakes.downloader.failure = null;
        final hold = Completer<void>();
        rig.fakes.downloader.hold = hold;

        final first = rig.controller.tryAgain();
        final second = rig.controller.tryAgain();
        await pumpEventQueue();
        expect(rig.fakes.downloader.downloads, [same(item), same(item)]);

        hold.complete();
        await Future.wait([first, second]);
        expect(rig.fakes.downloader.downloads, hasLength(2));
        expect(rig.fakes.verifier.calls, hasLength(1));
        expect(rig.state, isA<UpdateReady>());
      },
    );

    test(
      'two try again calls in the same frame after an offline error make one fetch',
      () async {
        final fakes = UpdaterFakes();
        fakes.fetcher.failure = const UpdateFailure(UpdateErrorCause.offline);
        final rig = ControllerRig(fakes: fakes);
        await rig.controller.check(manual: true);
        expect(rig.state, isUpdateError(UpdateErrorCause.offline));
        final item = newerItem();
        fakes.fetcher
          ..failure = null
          ..items = [item]
          ..hold = Completer<void>();
        final fetches = fakes.fetcher.fetchCount;

        final first = rig.controller.tryAgain();
        final second = rig.controller.tryAgain();
        await pumpEventQueue();
        expect(fakes.fetcher.fetchCount, fetches + 1);

        fakes.fetcher.hold!.complete();
        await Future.wait([first, second]);
        expect(fakes.fetcher.fetchCount, fetches + 1);
        expect(
          rig.state,
          isA<UpdateAvailable>().having((s) => s.item, 'item', same(item)),
        );
      },
    );

    test('try again outside an Error does nothing', () async {
      final rig = ControllerRig();
      final ready = await driveToReady(rig);
      final fetches = rig.fakes.fetcher.fetchCount;

      await rig.controller.tryAgain();

      expect(rig.state, same(ready));
      expect(rig.fakes.fetcher.fetchCount, fetches);
      expect(rig.fakes.downloader.downloads, hasLength(1));
    });
  });
}
