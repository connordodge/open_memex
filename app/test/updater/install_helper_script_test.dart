// WI #34 (Spec #31 req 25, 26, TD5, D13): runs the real install helper
// script under /bin/sh, exactly as `start` hands it to the helper-runner
// seam, against fake tools and a fake installed app in a temp dir whose
// names contain spaces. Only the wait limit and the PATH argument are
// swapped for the rig's (a tiny limit; fakes first).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';

import '../support/updater_fakes.dart';
import 'support/install_helper_rig.dart';

const _timeout = Timeout(Duration(seconds: 30));

/// Starts the helper through the production `installHelperProvider` (with a
/// recording runner), then runs the recorded command with the rig's wait
/// limit and PATH.
Future<ProcessResult> _runHelper(
  InstallHelperRig rig, {
  required int pid,
  String waitLimit = '10',
}) async {
  final io = RecordingUpdaterIo();
  final container = ProviderContainer(
    overrides: [
      installHelperRunnerProvider.overrideWithValue(io.runHelper),
      failureMarkerFileProvider.overrideWithValue(rig.markerPath),
      currentPidProvider.overrideWithValue(pid),
    ],
  );
  addTearDown(container.dispose);

  await container
      .read(installHelperProvider)
      .start(pid: pid, dmgPath: rig.dmgPath, bundlePath: rig.bundlePath);

  expect(
    io.helperRuns,
    hasLength(1),
    reason: 'start hands the helper to the runner seam once',
  );
  final run = io.helperRuns.single;
  final args = List.of(run.arguments);
  expect(args, hasLength(9), reason: '$args');
  args[7] = waitLimit;
  args[8] = rig.toolPath;
  return Process.run(
    run.executable,
    args,
    environment: {'PATH': rig.inheritedPath, 'TMPDIR': rig.tmpDir},
  );
}

/// The pid of a process that has already exited.
Future<int> _exitedPid() async => (await Process.run('/usr/bin/true', [])).pid;

void _expectExit(ProcessResult r, int code) => expect(
  r.exitCode,
  code,
  reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}',
);

/// The old app is still (or again) at the installed path, and the helper
/// relaunched it: `open` on the installed path, which held the old app.
void _expectOldAppRelaunched(InstallHelperRig rig) {
  expect(rig.versionAt(), 'old');
  final opens = rig.callsTo('open');
  expect(opens, hasLength(1), reason: '${rig.calls()}');
  expect(opens.single.last, rig.bundlePath);
  expect(rig.note('opened-version'), 'old');
  expect(rig.trapped(), isEmpty);
}

/// After a mounted failure the DMG is detached before the relaunch.
void _expectDetachedBeforeOpen(InstallHelperRig rig) {
  final detach = rig.indexOf('hdiutil', 'detach');
  expect(detach, isNot(-1), reason: '${rig.calls()}');
  expect(detach, lessThan(rig.indexOf('open')), reason: '${rig.calls()}');
}

void main() {
  late InstallHelperRig rig;

  tearDown(() => rig.dispose());

  test(
    'a successful install leaves the new app at the installed path with a space in its name and removes the old app',
    () async {
      rig = await InstallHelperRig.create();

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 0);
      expect(rig.versionAt(), 'new');
      expect(
        File('${rig.bundlePath}/Contents/MacOS/Open Memex').readAsStringSync(),
        'new binary',
      );
      expect(Directory(rig.oldPath).existsSync(), isFalse);
      expect(Directory(rig.newPath).existsSync(), isFalse);
      expect(rig.marker(), isNull);
      expect(rig.trapped(), isEmpty);

      // Mounted read-only, without browsing, at a mount point of its own.
      final attach = rig
          .callsTo('hdiutil')
          .firstWhere((c) => c.args.first == 'attach');
      expect(attach.args, containsAll(['-nobrowse', '-readonly', rig.dmgPath]));
      final mount = attach.after('-mountpoint');
      expect(mount, isNotNull, reason: '$attach');
      expect(mount, isNot(startsWith('/Volumes/')));

      // Copied from the mount root, only to the .new bundle.
      final ditto = rig.callsTo('ditto');
      expect(ditto, hasLength(1));
      expect(ditto.single.args, contains('$mount/Open Memex.app'));
      expect(ditto.single.last, rig.newPath);

      // Verified strictly, on the copy.
      final codesign = rig.callsTo('codesign');
      expect(codesign, hasLength(1));
      expect(
        codesign.single.args,
        containsAll(['--verify', '--deep', '--strict']),
      );
      expect(codesign.single.last, rig.newPath);
      expect(rig.indexOf('ditto'), lessThan(rig.indexOf('codesign')));
    },
    timeout: _timeout,
  );

  test(
    'a successful install strips quarantine then detaches the disk image then opens the new app',
    () async {
      rig = await InstallHelperRig.create();

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 0);
      final xattr = rig.callsTo('xattr');
      expect(xattr, hasLength(1));
      expect(xattr.single.args, contains('com.apple.quarantine'));
      expect(xattr.single.last, rig.bundlePath);

      final attach = rig
          .callsTo('hdiutil')
          .firstWhere((c) => c.args.first == 'attach');
      final detach = rig
          .callsTo('hdiutil')
          .where((c) => c.args.first == 'detach');
      expect(detach, isNotEmpty);
      expect(detach.first.args, contains(attach.after('-mountpoint')));

      final open = rig.callsTo('open');
      expect(open, hasLength(1));
      expect(open.single.last, rig.bundlePath);
      expect(rig.note('opened-version'), 'new');

      final iXattr = rig.indexOf('xattr');
      final iDetach = rig.indexOf('hdiutil', 'detach');
      final iOpen = rig.indexOf('open');
      expect(iXattr, lessThan(iDetach), reason: '${rig.calls()}');
      expect(iDetach, lessThan(iOpen), reason: '${rig.calls()}');
      expect(rig.indexOf('codesign'), lessThan(iXattr));
    },
    timeout: _timeout,
  );

  test(
    'the helper waits while the app is running and installs once it exits',
    () async {
      final app = await Process.start('/bin/cat', []);
      addTearDown(app.kill);
      rig = await InstallHelperRig.create(killOnFirstSleep: app.pid);

      final r = await _runHelper(rig, pid: app.pid);

      _expectExit(r, 0);
      // It slept at least once, before mounting anything.
      final iSleep = rig.indexOf('sleep');
      expect(iSleep, isNot(-1), reason: '${rig.calls()}');
      expect(iSleep, lessThan(rig.indexOf('hdiutil', 'attach')));
      expect(rig.versionAt(), 'new');
      expect(rig.marker(), isNull);
    },
    timeout: _timeout,
  );

  test(
    'a pid still alive after the wait limit records that the app did not quit in time and touches no bundle',
    () async {
      final app = await Process.start('/bin/sleep', ['60']);
      addTearDown(app.kill);
      rig = await InstallHelperRig.create(staleNew: true);

      final r = await _runHelper(rig, pid: app.pid, waitLimit: '1');

      _expectExit(r, 1);
      expect(rig.marker(), "the app didn't quit in time");
      expect(rig.versionAt(), 'old');
      expect(File('${rig.newPath}/stale.txt').existsSync(), isTrue);
      expect(Directory(rig.oldPath).existsSync(), isFalse);
      for (final tool in ['hdiutil', 'ditto', 'codesign', 'xattr', 'open']) {
        expect(rig.callsTo(tool), isEmpty, reason: tool);
      }
      expect(rig.trapped(), isEmpty);
    },
    timeout: _timeout,
  );

  test(
    'a failed mount records that the disk image could not be opened and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(mountFails: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the disk image couldn't be opened");
      _expectOldAppRelaunched(rig);
      expect(rig.callsTo('ditto'), isEmpty);
      expect(rig.callsTo('codesign'), isEmpty);
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a failed copy records that the new app could not be copied and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(copyFails: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the new app couldn't be copied");
      _expectOldAppRelaunched(rig);
      _expectDetachedBeforeOpen(rig);
      expect(rig.callsTo('codesign'), isEmpty);
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'no app at the mount root records that the new app could not be copied and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(appAtMountRoot: false);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the new app couldn't be copied");
      _expectOldAppRelaunched(rig);
      _expectDetachedBeforeOpen(rig);
      expect(rig.callsTo('codesign'), isEmpty);
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a failed signature check records that the signature did not verify and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(verifyFails: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the new app's signature didn't verify");
      _expectOldAppRelaunched(rig);
      _expectDetachedBeforeOpen(rig);
      expect(rig.callsTo('codesign'), hasLength(1));
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a failed rename into place restores the old app records the reason and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(lockCopy: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the new app couldn't be moved into place");
      _expectOldAppRelaunched(rig);
      _expectDetachedBeforeOpen(rig);
      // Restored by renaming back: no .old left over.
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a failed rename of the installed app records the moved into place reason and relaunches the old app',
    () async {
      rig = await InstallHelperRig.create(lockInstalled: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 1);
      expect(rig.marker(), "the new app couldn't be moved into place");
      _expectOldAppRelaunched(rig);
      _expectDetachedBeforeOpen(rig);
      expect(Directory(rig.oldPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a stale new app from an earlier attempt is removed before the copy',
    () async {
      rig = await InstallHelperRig.create(staleNew: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 0);
      expect(rig.note('ditto-dest-existed'), 'no');
      expect(rig.versionAt(), 'new');
      expect(File('${rig.bundlePath}/stale.txt').existsSync(), isFalse);
      expect(Directory(rig.newPath).existsSync(), isFalse);
    },
    timeout: _timeout,
  );

  test(
    'a failed delete of the old app after the swap still counts as success',
    () async {
      rig = await InstallHelperRig.create(lockFileInOld: true);

      final r = await _runHelper(rig, pid: await _exitedPid());

      _expectExit(r, 0);
      expect(rig.marker(), isNull);
      expect(rig.versionAt(), 'new');
      // The old app could not be fully deleted: it is still the old one.
      expect(File('${rig.oldPath}/Contents/locked.txt').existsSync(), isTrue);
      final open = rig.callsTo('open');
      expect(open, hasLength(1));
      expect(open.single.last, rig.bundlePath);
      expect(rig.note('opened-version'), 'new');
      expect(rig.trapped(), isEmpty);
    },
    timeout: _timeout,
  );
}
