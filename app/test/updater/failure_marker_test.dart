// WI #34 (Spec #31 req 26, D8): the failure marker store reads and clears
// `<appSupportDir>/self_update_failure`; only the five fixed reasons count.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_support_dir.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';

/// The five fixed reasons, verbatim from Spec #31 req 26.
const _reasons = [
  "the disk image couldn't be opened",
  "the new app couldn't be copied",
  "the new app's signature didn't verify",
  "the new app couldn't be moved into place",
  "the app didn't quit in time",
];

void main() {
  late Directory root;
  late String markerPath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('open memex marker ');
    markerPath = '${root.path}/Application Support/self_update_failure';
    await Directory('${root.path}/Application Support').create();
  });

  tearDown(() async {
    // Undo the immutable flag a test set before deleting.
    await Process.run('/usr/bin/chflags', ['-R', 'nouchg', root.path]);
    await root.delete(recursive: true);
  });

  FailureMarkerStore store() {
    final container = ProviderContainer(
      overrides: [failureMarkerFileProvider.overrideWithValue(markerPath)],
    );
    addTearDown(container.dispose);
    return container.read(failureMarkerStoreProvider);
  }

  test(
    'reading the marker returns each of the five fixed reasons and clears the file',
    () async {
      for (final reason in _reasons) {
        // The helper writes the reason and a newline.
        File(markerPath).writeAsStringSync('$reason\n');

        expect(await store().take(), reason);
        expect(File(markerPath).existsSync(), isFalse, reason: reason);
      }

      // Without the trailing newline too.
      File(markerPath).writeAsStringSync(_reasons.first);
      expect(await store().take(), _reasons.first);
      expect(File(markerPath).existsSync(), isFalse);
    },
  );

  test('a marker is read once and the next read is no failure', () async {
    File(markerPath).writeAsStringSync('${_reasons[3]}\n');
    final s = store();

    expect(await s.take(), _reasons[3]);
    expect(await s.take(), isNull);
  });

  test('unknown marker text is cleared and reads as no failure', () async {
    for (final text in [
      'something went wrong\n',
      "The app didn't quit in time\n",
      "the app didn't quit in time (pid 4242)\n",
      '',
      '\n',
    ]) {
      File(markerPath).writeAsStringSync(text);

      expect(await store().take(), isNull, reason: text);
      expect(File(markerPath).existsSync(), isFalse, reason: text);
    }
  });

  test(
    'a missing marker reads as no failure and creates no file, and a later marker is still read',
    () async {
      expect(await store().take(), isNull);
      expect(File(markerPath).existsSync(), isFalse);

      File(markerPath).writeAsStringSync('${_reasons[0]}\n');
      expect(await store().take(), _reasons[0]);
    },
  );

  test('building the marker store does not read or clear the marker', () async {
    File(markerPath).writeAsStringSync('${_reasons[1]}\n');

    store();

    expect(File(markerPath).readAsStringSync(), '${_reasons[1]}\n');
    expect(await store().take(), _reasons[1]);
  });

  test(
    'the production marker path is self_update_failure in the app support folder',
    () {
      final support = ['', 'vaults', 'Support Dir'].join('/');
      final container = ProviderContainer(
        overrides: [appSupportDirProvider.overrideWithValue(support)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(failureMarkerFileProvider),
        '/vaults/Support Dir/self_update_failure',
      );
      // Computing the path touches no file system.
      expect(Directory(support).existsSync(), isFalse);
    },
  );

  test(
    'a marker that is not valid text is cleared and reads as no failure',
    () async {
      File(markerPath).writeAsBytesSync([0xff, 0xfe, 0x00, 0xc3, 0x28]);

      expect(await store().take(), isNull);
      expect(File(markerPath).existsSync(), isFalse);

      // A fixed reason with a bad byte after it is not that reason.
      File(markerPath).writeAsBytesSync([...utf8.encode(_reasons[0]), 0xff]);
      expect(await store().take(), isNull);
      expect(File(markerPath).existsSync(), isFalse);
    },
  );

  test('a marker that cannot be deleted still reads as its reason', () async {
    File(markerPath).writeAsStringSync('${_reasons[1]}\n');
    final lock = await Process.run('/usr/bin/chflags', ['uchg', markerPath]);
    expect(lock.exitCode, 0, reason: '${lock.stderr}');
    addTearDown(() => Process.run('/usr/bin/chflags', ['nouchg', markerPath]));

    expect(await store().take(), _reasons[1]);
    expect(File(markerPath).existsSync(), isTrue);
  });

  test(
    'an unknown marker that cannot be deleted still reads as no failure',
    () async {
      File(markerPath).writeAsStringSync('something else\n');
      final lock = await Process.run('/usr/bin/chflags', ['uchg', markerPath]);
      expect(lock.exitCode, 0, reason: '${lock.stderr}');
      addTearDown(
        () => Process.run('/usr/bin/chflags', ['nouchg', markerPath]),
      );

      expect(await store().take(), isNull);
    },
  );
}
