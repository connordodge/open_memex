// WI #33 (Spec #31 req 16a, D8): the cleanup of the leftover update download
// directory, through the production downloader with the directory injected
// (never the real `<systemTemp>/open-memex-update`).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:path/path.dart' as p;

/// A fresh temp root for this test, deleted at its end.
String _wi33CleanRoot() {
  final dir = Directory.systemTemp.createTempSync('wi33_cleanup_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

/// The production downloader over [dir]; its HTTP client is never used.
UpdateDownloader _wi33CleanDownloader(String dir, List<int> clientsMade) {
  final container = ProviderContainer(
    overrides: [
      updateHttpClientFactoryProvider.overrideWithValue(() {
        clientsMade.add(1);
        return MockClient((_) async => http.Response('', 500));
      }),
      updateDownloadDirProvider.overrideWithValue(dir),
    ],
  );
  addTearDown(container.dispose);
  return container.read(updateDownloaderProvider);
}

/// Fills [dir] with a leftover DMG, a nested folder and a dotfile.
void _wi33Leftovers(String dir) {
  Directory(p.join(dir, 'nested', 'deeper')).createSync(recursive: true);
  File(p.join(dir, 'Open-Memex-1.3.0-arm64.dmg')).writeAsBytesSync([1, 2, 3]);
  File(p.join(dir, 'nested', 'deeper', 'part')).writeAsStringSync('x');
  File(p.join(dir, '.hidden')).writeAsStringSync('y');
}

void main() {
  test(
    'the cleanup deletes the update download directory and its contents',
    () async {
      final root = _wi33CleanRoot();
      final dir = p.join(root, 'open-memex-update');
      _wi33Leftovers(dir);
      // Siblings in the same temp folder are not the updater's.
      final sibling = File(p.join(root, 'open-memex-update-other'))
        ..writeAsStringSync('keep');
      final clients = <int>[];

      await _wi33CleanDownloader(dir, clients).deleteLeftovers();

      expect(Directory(dir).existsSync(), isFalse);
      expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);
      expect(sibling.readAsStringSync(), 'keep');
      expect(Directory(root).existsSync(), isTrue);
      expect(clients, isEmpty, reason: 'the cleanup sends no request');
    },
  );

  test(
    'a missing update download directory is not an error for the cleanup',
    () async {
      final root = _wi33CleanRoot();
      final dir = p.join(root, 'open-memex-update');
      final clients = <int>[];
      final downloader = _wi33CleanDownloader(dir, clients);

      // Missing: completes, creates nothing.
      await downloader.deleteLeftovers();
      expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);

      // Its parent missing too.
      await _wi33CleanDownloader(
        p.join(root, 'gone', 'open-memex-update'),
        clients,
      ).deleteLeftovers();
      expect(Directory(p.join(root, 'gone')).existsSync(), isFalse);

      // The same cleanup still deletes a directory that appears later.
      _wi33Leftovers(dir);
      await downloader.deleteLeftovers();
      expect(Directory(dir).existsSync(), isFalse);
      expect(clients, isEmpty);
    },
  );
}
