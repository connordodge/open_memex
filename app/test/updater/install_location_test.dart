// WI #34 (Spec #31 req 24, TD6, D6): the install-location check and the
// production executable and writability seams behind it.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';

const _exe = 'Contents/MacOS/Open Memex';

/// A container whose only overrides are the location check's two seams, so
/// the production `installLocationCheckProvider` runs over them.
({InstallLocationCheck check, RecordingUpdaterIo io}) _checkFor(
  String executable, {
  bool writable = true,
}) {
  final io = RecordingUpdaterIo()
    ..resolvedExecutable = executable
    ..writable = writable;
  final container = ProviderContainer(
    overrides: [
      resolvedExecutableProvider.overrideWithValue(io.resolvedExecutable),
      folderWritableProvider.overrideWithValue(io.folderWritable),
    ],
  );
  addTearDown(container.dispose);
  return (check: container.read(installLocationCheckProvider), io: io);
}

Matcher _failsWith(UpdateErrorCause cause, {String? folder}) => throwsA(
  isA<UpdateFailure>()
      .having((f) => f.cause, 'cause', cause)
      .having((f) => f.folder, 'folder', folder),
);

void main() {
  test(
    'the location check resolves the executable to its enclosing bundle and passes when the folder is writable',
    () async {
      // Built from run-time values, not a const literal.
      final dir = ['', 'vaults', 'My Apps'].join('/');
      final r = _checkFor('$dir/Open Memex.app/$_exe');

      expect(await r.check.check(), '$dir/Open Memex.app');
      expect(r.io.writableProbes, [dir]);
    },
  );

  test(
    'the location check returns the innermost enclosing bundle, whatever it is named',
    () async {
      final renamed = _checkFor('/vaults/My Apps/Open Memex 2.app/$_exe');
      expect(await renamed.check.check(), '/vaults/My Apps/Open Memex 2.app');
      expect(renamed.io.writableProbes, ['/vaults/My Apps']);

      final nested = _checkFor('/vaults/Tools.app/Inner/Open Memex.app/$_exe');
      expect(
        await nested.check.check(),
        '/vaults/Tools.app/Inner/Open Memex.app',
      );
      expect(nested.io.writableProbes, ['/vaults/Tools.app/Inner']);
    },
  );

  test(
    'a bundle under the Volumes folder fails with the disk image cause',
    () async {
      final r = _checkFor('/Volumes/Open Memex/Open Memex.app/$_exe');

      await expectLater(
        r.check.check(),
        _failsWith(UpdateErrorCause.diskImage),
      );
      expect(r.io.writableProbes, isEmpty);

      // Disk image wins even when the folder would be writable or not.
      final unwritable = _checkFor(
        '/Volumes/Open Memex/Open Memex.app/$_exe',
        writable: false,
      );
      await expectLater(
        unwritable.check.check(),
        _failsWith(UpdateErrorCause.diskImage),
      );
    },
  );

  test(
    'only a path that starts with the Volumes folder counts as a disk image',
    () async {
      final r = _checkFor('/vaults/Volumes/Apps/Open Memex.app/$_exe');

      expect(await r.check.check(), '/vaults/Volumes/Apps/Open Memex.app');
      expect(r.io.writableProbes, ['/vaults/Volumes/Apps']);
    },
  );

  test(
    'a bundle path containing AppTranslocation fails with the disk image cause',
    () async {
      final r = _checkFor(
        '/private/var/folders/zz/T/AppTranslocation/0A1B2C3D-4E5F/d/'
        'Open Memex.app/$_exe',
      );

      await expectLater(
        r.check.check(),
        _failsWith(UpdateErrorCause.diskImage),
      );
      expect(r.io.writableProbes, isEmpty);
    },
  );

  test(
    'a bundle whose parent folder is not writable fails with the folder not writable cause and that folder',
    () async {
      final r = _checkFor(
        '/vaults/Locked Apps/Open Memex.app/$_exe',
        writable: false,
      );

      await expectLater(
        r.check.check(),
        _failsWith(
          UpdateErrorCause.folderNotWritable,
          folder: '/vaults/Locked Apps',
        ),
      );
      expect(r.io.writableProbes, ['/vaults/Locked Apps']);
    },
  );

  test(
    'an executable outside any app bundle fails with the folder not writable cause and its folder',
    () async {
      final r = _checkFor('/vaults/My Tools/open-memex');

      await expectLater(
        r.check.check(),
        _failsWith(
          UpdateErrorCause.folderNotWritable,
          folder: '/vaults/My Tools',
        ),
      );
      expect(r.io.writableProbes, isEmpty);

      // A top-level executable has the root as its folder.
      final top = _checkFor('/open-memex');
      await expectLater(
        top.check.check(),
        _failsWith(UpdateErrorCause.folderNotWritable, folder: '/'),
      );
    },
  );

  test(
    'a bundle directly under the root is probed in the root folder',
    () async {
      final r = _checkFor('/Open Memex.app/$_exe');

      expect(await r.check.check(), '/Open Memex.app');
      expect(r.io.writableProbes, ['/']);
    },
  );

  test(
    'a relative executable path whose first segment is the bundle still resolves to it',
    () async {
      final r = _checkFor('Open Memex.app/$_exe');

      expect(await r.check.check(), 'Open Memex.app');
      expect(r.io.writableProbes, ['/']);
    },
  );

  test(
    'the production resolvedExecutableProvider is Platform.resolvedExecutable',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(Platform.resolvedExecutable, isNotEmpty);
      expect(
        container.read(resolvedExecutableProvider),
        Platform.resolvedExecutable,
      );
    },
  );

  group('on real folders', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('open memex probe ');
    });

    tearDown(() async {
      // Undo the immutable flag before deleting.
      await Process.run('/usr/bin/chflags', ['-R', 'nouchg', root.path]);
      await root.delete(recursive: true);
    });

    test(
      'the production writability probe creates and deletes a file and reports false when the create fails',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final writable = container.read(folderWritableProvider);

        // Writable: true, and the probe file is gone afterwards.
        final open = await Directory('${root.path}/My Apps').create();
        expect(await writable(open.path), isTrue);
        expect(open.listSync(), isEmpty);

        // The owner may write by mode bits, but the folder is immutable:
        // only a real create notices.
        final locked = await Directory('${root.path}/Locked Apps').create();
        final lock = await Process.run('/usr/bin/chflags', [
          'uchg',
          locked.path,
        ]);
        expect(lock.exitCode, 0, reason: '${lock.stderr}');
        expect(await writable(locked.path), isFalse);
        expect(locked.listSync(), isEmpty);

        // Read-only by mode bits.
        final readOnly = await Directory('${root.path}/Read Only').create();
        await Process.run('/bin/chmod', ['0555', readOnly.path]);
        addTearDown(() => Process.run('/bin/chmod', ['0755', readOnly.path]));
        expect(await writable(readOnly.path), isFalse);
        expect(readOnly.listSync(), isEmpty);

        // A missing folder.
        expect(await writable('${root.path}/Missing'), isFalse);
        expect(Directory('${root.path}/Missing').existsSync(), isFalse);

        // Still true for a writable folder afterwards.
        expect(await writable(open.path), isTrue);
        expect(open.listSync(), isEmpty);
      },
    );

    test(
      'the production writability probe never touches an existing entry at the old probe name and leaves nothing behind',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final writable = container.read(folderWritableProvider);
        final oldName = '.open-memex-write-probe-$pid';

        // A file left at the name an earlier version probed with.
        final plain = await Directory('${root.path}/My Apps').create();
        final leftover = File('${plain.path}/$oldName')
          ..writeAsStringSync('left behind');
        expect(await writable(plain.path), isTrue);
        expect(leftover.readAsStringSync(), 'left behind');
        expect(plain.listSync(), hasLength(1));

        // A symlink planted at that name, pointing at a file the probe must
        // never truncate: another account could plant it in a shared folder.
        final shared = await Directory('${root.path}/Shared Apps').create();
        final victim = File('${root.path}/victim note.md')
          ..writeAsStringSync('precious notes');
        final planted = Link('${shared.path}/$oldName')
          ..createSync(victim.path);
        expect(await writable(shared.path), isTrue);
        expect(victim.readAsStringSync(), 'precious notes');
        expect(planted.targetSync(), victim.path);
        expect(shared.listSync(), hasLength(1));
      },
    );
  });
}
