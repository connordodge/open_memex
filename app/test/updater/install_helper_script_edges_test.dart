// WI #34 (Spec #31 req 25, 26, TD5, D13): the edges of the real install
// helper script under /bin/sh, beyond the acceptance journeys: argument
// checks, stale leftovers, cleanup of the copy and the mount point, and the
// forced detach. Same rig as install_helper_script_test.dart: fake tools
// first on a temp PATH, a fake bundle in a temp dir whose names contain
// spaces, nothing outside the temp dir touched.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/install_helper.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';

import '../support/updater_fakes.dart';
import 'support/install_helper_rig.dart';

const _timeout = Timeout(Duration(seconds: 30));

/// Starts the helper through the production `installHelperProvider` and runs
/// the recorded command with the rig's wait limit and PATH.
Future<ProcessResult> _runHelper(
  InstallHelperRig rig, {
  required int pid,
  String waitLimit = '10',
  String? tmpDir,
}) async {
  final io = RecordingUpdaterIo();
  final container = ProviderContainer(
    overrides: [
      installHelperRunnerProvider.overrideWithValue(io.runHelper),
      failureMarkerFileProvider.overrideWithValue(rig.markerPath),
    ],
  );
  addTearDown(container.dispose);
  await container
      .read(installHelperProvider)
      .start(pid: pid, dmgPath: rig.dmgPath, bundlePath: rig.bundlePath);
  final run = io.helperRuns.single;
  final args = List.of(run.arguments);
  args[7] = waitLimit;
  args[8] = rig.toolPath;
  return Process.run(
    run.executable,
    args,
    environment: {'PATH': rig.inheritedPath, 'TMPDIR': tmpDir ?? rig.tmpDir},
  );
}

/// Runs the constant script with exactly [args] as its positional arguments.
Future<ProcessResult> _runRaw(InstallHelperRig rig, List<String> args) =>
    Process.run(
      '/bin/sh',
      ['-c', installHelperScript, 'open-memex-install-helper', ...args],
      environment: {'PATH': rig.inheritedPath, 'TMPDIR': rig.tmpDir},
    );

/// The pid of a process that has already exited.
Future<int> _exitedPid() async => (await Process.run('/usr/bin/true', [])).pid;

void _expectExit(ProcessResult r, int code) => expect(
  r.exitCode,
  code,
  reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}',
);

/// Nothing ran and nothing changed: no tool call, no marker, the old app in
/// place, no mount point.
void _expectUntouched(InstallHelperRig rig) {
  expect(rig.calls(), isEmpty);
  expect(rig.marker(), isNull);
  expect(rig.versionAt(), 'old');
  expect(rig.tmpEntries(), isEmpty);
}

/// The old app is at the installed path and was relaunched there once.
void _expectOldAppRelaunched(InstallHelperRig rig) {
  expect(rig.versionAt(), 'old');
  final opens = rig.callsTo('open');
  expect(opens, hasLength(1), reason: '${rig.calls()}');
  expect(opens.single.last, rig.bundlePath);
  expect(rig.note('opened-version'), 'old');
  expect(rig.trapped(), isEmpty);
}

void main() {
  final rigs = <InstallHelperRig>[];

  Future<InstallHelperRig> makeRig({
    bool mountFails = false,
    bool appAtMountRoot = true,
    bool copyFails = false,
    bool verifyFails = false,
    bool lockCopy = false,
    bool lockInstalled = false,
    bool staleOld = false,
    bool lockStaleOld = false,
    bool lockStaleNew = false,
    bool detachNeedsForce = false,
  }) async {
    final rig = await InstallHelperRig.create(
      mountFails: mountFails,
      appAtMountRoot: appAtMountRoot,
      copyFails: copyFails,
      verifyFails: verifyFails,
      lockCopy: lockCopy,
      lockInstalled: lockInstalled,
      staleOld: staleOld,
      lockStaleOld: lockStaleOld,
      lockStaleNew: lockStaleNew,
      detachNeedsForce: detachNeedsForce,
    );
    rigs.add(rig);
    return rig;
  }

  tearDown(() async {
    for (final rig in rigs) {
      await rig.dispose();
    }
    rigs.clear();
  });

  group('arguments', () {
    test(
      'the helper exits 2 and touches nothing when it gets the wrong number of arguments',
      () async {
        final rig = await makeRig();
        final pid = '${await _exitedPid()}';
        final five = [pid, rig.dmgPath, rig.bundlePath, rig.markerPath, '10'];

        for (final args in [
          <String>[],
          five,
          [...five, rig.toolPath, 'extra'],
        ]) {
          _expectExit(await _runRaw(rig, args), 2);
          _expectUntouched(rig);
        }
      },
      timeout: _timeout,
    );

    test(
      'the helper exits 2 and touches nothing when the pid is not a number',
      () async {
        final rig = await makeRig();

        for (final pid in ['', 'abc', '12x', '-1', '1 2']) {
          final r = await _runRaw(rig, [
            pid,
            rig.dmgPath,
            rig.bundlePath,
            rig.markerPath,
            '10',
            rig.toolPath,
          ]);
          _expectExit(r, 2);
          _expectUntouched(rig);
        }
      },
      timeout: _timeout,
    );

    test(
      'a wait limit that is not a number counts as no wait at all',
      () async {
        final app = await Process.start('/bin/sleep', ['60']);
        addTearDown(app.kill);

        for (final limit in ['', 'abc', '5s']) {
          final rig = await makeRig();

          final r = await _runHelper(rig, pid: app.pid, waitLimit: limit);

          _expectExit(r, 1);
          expect(rig.marker(), "the app didn't quit in time", reason: limit);
          expect(rig.indexOf('sleep'), -1, reason: 'no wait for "$limit"');
          expect(rig.versionAt(), 'old');
          expect(rig.callsTo('open'), isEmpty);
        }
      },
      timeout: _timeout,
    );
  });

  group('stale leftovers', () {
    test(
      'a stale old app from an earlier attempt is removed before the swap',
      () async {
        final rig = await makeRig(staleOld: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 0);
        expect(rig.versionAt(), 'new');
        expect(Directory(rig.oldPath).existsSync(), isFalse);
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(rig.marker(), isNull);
        expect(rig.note('opened-version'), 'new');
      },
      timeout: _timeout,
    );

    test(
      'a stale old app that cannot be removed records the moved into place reason and relaunches the old app',
      () async {
        final rig = await makeRig(lockStaleOld: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app couldn't be moved into place");
        _expectOldAppRelaunched(rig);
        // The installed app was never moved into the stale folder.
        expect(
          Directory('${rig.oldPath}/Open Memex.app').existsSync(),
          isFalse,
        );
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(rig.tmpEntries(), isEmpty);
      },
      timeout: _timeout,
    );
  });

  group('guards before the copy', () {
    test(
      'a stale new app that cannot be removed records the copy reason without copying into it and relaunches the old app',
      () async {
        final rig = await makeRig(lockStaleNew: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app couldn't be copied");
        // Nothing was copied into (merged with) the stale folder, so nothing
        // was verified or moved.
        expect(rig.callsTo('ditto'), isEmpty, reason: '${rig.calls()}');
        expect(rig.callsTo('codesign'), isEmpty);
        expect(Directory(rig.oldPath).existsSync(), isFalse);
        expect(
          File('${rig.newPath}/stale.txt').readAsStringSync(),
          'from an earlier attempt',
        );
        expect(
          Directory('${rig.newPath}/Contents').existsSync(),
          isFalse,
          reason: 'no part of the new app was copied into the stale folder',
        );
        // It had mounted the image: detached before the old app is relaunched,
        // and the mount point is gone.
        expect(rig.indexOf('hdiutil', 'detach'), isNot(-1));
        expect(rig.indexOf('hdiutil', 'detach'), lessThan(rig.indexOf('open')));
        expect(rig.tmpEntries(), isEmpty);
        _expectOldAppRelaunched(rig);
      },
      timeout: _timeout,
    );

    test(
      'a mount point that cannot be created records the disk image reason without mounting and relaunches the old app',
      () async {
        final rig = await makeRig();

        final r = await _runHelper(
          rig,
          pid: await _exitedPid(),
          tmpDir: '${rig.tmpDir}/Missing Temp Folder',
        );

        _expectExit(r, 1);
        expect(rig.marker(), "the disk image couldn't be opened");
        // No mount point, so the image was never attached, copied or checked.
        expect(rig.callsTo('hdiutil'), isEmpty, reason: '${rig.calls()}');
        expect(rig.callsTo('ditto'), isEmpty);
        expect(rig.callsTo('codesign'), isEmpty);
        expect(rig.tmpEntries(), isEmpty);
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(Directory(rig.oldPath).existsSync(), isFalse);
        _expectOldAppRelaunched(rig);
      },
      timeout: _timeout,
    );
  });

  group('cleanup after a failure', () {
    test(
      'a failed copy removes the partial new app and the mount point',
      () async {
        final rig = await makeRig(copyFails: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app couldn't be copied");
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(rig.tmpEntries(), isEmpty);
        _expectOldAppRelaunched(rig);
      },
      timeout: _timeout,
    );

    test(
      'a failed signature check removes the unverified new app and the mount point',
      () async {
        final rig = await makeRig(verifyFails: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app's signature didn't verify");
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(rig.tmpEntries(), isEmpty);
        _expectOldAppRelaunched(rig);
      },
      timeout: _timeout,
    );

    test(
      'a failed rename of the installed app removes the new app and the mount point',
      () async {
        final rig = await makeRig(lockInstalled: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app couldn't be moved into place");
        expect(Directory(rig.newPath).existsSync(), isFalse);
        expect(rig.tmpEntries(), isEmpty);
        _expectOldAppRelaunched(rig);
      },
      timeout: _timeout,
    );

    test(
      'a failed mount and a missing app at the mount root remove the mount point',
      () async {
        final failedMount = await makeRig(mountFails: true);
        _expectExit(await _runHelper(failedMount, pid: await _exitedPid()), 1);
        expect(failedMount.marker(), "the disk image couldn't be opened");
        expect(failedMount.tmpEntries(), isEmpty);
        // Never mounted, so never detached.
        expect(failedMount.indexOf('hdiutil', 'detach'), -1);

        final noApp = await makeRig(appAtMountRoot: false);
        _expectExit(await _runHelper(noApp, pid: await _exitedPid()), 1);
        expect(noApp.marker(), "the new app couldn't be copied");
        expect(noApp.tmpEntries(), isEmpty);
        expect(noApp.indexOf('hdiutil', 'detach'), isNot(-1));
      },
      timeout: _timeout,
    );
  });

  group('the mount point and the detach', () {
    test(
      'a successful install mounts under the temp folder, detaches once without force and removes the mount point',
      () async {
        final rig = await makeRig();

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 0);
        final attach = rig
            .callsTo('hdiutil')
            .firstWhere((c) => c.args.first == 'attach');
        expect(attach.after('-mountpoint'), startsWith('${rig.tmpDir}/'));
        final detaches = [
          for (final c in rig.callsTo('hdiutil'))
            if (c.args.first == 'detach') c,
        ];
        expect(detaches, hasLength(1), reason: '${rig.calls()}');
        expect(detaches.single.args, isNot(contains('-force')));
        expect(rig.tmpEntries(), isEmpty);
      },
      timeout: _timeout,
    );

    test(
      'a detach that fails is retried with force before the new app is opened',
      () async {
        final rig = await makeRig(detachNeedsForce: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 0);
        final detaches = [
          for (final c in rig.callsTo('hdiutil'))
            if (c.args.first == 'detach') c,
        ];
        expect(detaches, hasLength(2), reason: '${rig.calls()}');
        expect(detaches.first.args, isNot(contains('-force')));
        expect(detaches.last.args, contains('-force'));
        final mount = rig
            .callsTo('hdiutil')
            .firstWhere((c) => c.args.first == 'attach')
            .after('-mountpoint');
        expect(mount, isNotNull);
        expect(detaches.first.args, contains(mount));
        expect(detaches.last.args, contains(mount));
        // The forced detach worked, so the mount point is gone.
        expect(rig.tmpEntries(), isEmpty);
        expect(rig.versionAt(), 'new');
        expect(rig.note('opened-version'), 'new');
      },
      timeout: _timeout,
    );

    test(
      'a detach that needs force after a failure is retried and the old app is relaunched',
      () async {
        final rig = await makeRig(detachNeedsForce: true, verifyFails: true);

        final r = await _runHelper(rig, pid: await _exitedPid());

        _expectExit(r, 1);
        expect(rig.marker(), "the new app's signature didn't verify");
        final detaches = [
          for (final c in rig.callsTo('hdiutil'))
            if (c.args.first == 'detach') c,
        ];
        expect(detaches, hasLength(2), reason: '${rig.calls()}');
        expect(detaches.last.args, contains('-force'));
        expect(rig.tmpEntries(), isEmpty);
        _expectOldAppRelaunched(rig);
        expect(rig.indexOf('hdiutil', 'detach'), lessThan(rig.indexOf('open')));
      },
      timeout: _timeout,
    );
  });
}
