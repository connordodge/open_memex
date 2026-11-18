// WI #33 (Spec #31 req 15, 19, 20, D1, D6): the production update
// downloader. HTTP is a MockClient.streaming behind
// updateHttpClientFactoryProvider; the update download directory is a fresh
// temp dir per test. No test touches the network or the real download dir.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_downloader.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:path/path.dart' as p;

import '../support/updater_fakes.dart' show testAppcastItem;

/// A client that records whether it was closed.
class _Wi33DlClosingClient extends http.BaseClient {
  _Wi33DlClosingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// Answers each download with [respond]'s streamed response; records every
/// request and every client.
class _Wi33DlHttp {
  _Wi33DlHttp(this.respond);

  http.StreamedResponse Function(http.BaseRequest request) respond;
  final List<http.BaseRequest> requests = [];
  final List<_Wi33DlClosingClient> clients = [];

  http.Client call() {
    final client = _Wi33DlClosingClient(
      MockClient.streaming((request, _) async {
        requests.add(request);
        return respond(request);
      }),
    );
    clients.add(client);
    return client;
  }
}

/// A 200 response streaming [chunks], with [contentLength] when given.
http.StreamedResponse Function(http.BaseRequest) _wi33Chunks(
  List<List<int>> chunks, {
  int? contentLength,
  int status = 200,
}) =>
    (_) => http.StreamedResponse(
      Stream.fromIterable(chunks),
      status,
      contentLength: contentLength,
    );

/// A fresh temp root for this test, deleted at its end. The update download
/// directory under test is `<root>/open-memex-update`, not created yet.
String _wi33Root() {
  final dir = Directory.systemTemp.createTempSync('wi33_download_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

/// The production downloader (`defaultUpdateDownloader` through
/// `updateDownloaderProvider`) over [net], downloading into [dir].
UpdateDownloader _wi33Downloader(_Wi33DlHttp net, String dir) {
  final container = ProviderContainer(
    overrides: [
      updateHttpClientFactoryProvider.overrideWithValue(net.call),
      updateDownloadDirProvider.overrideWithValue(dir),
    ],
  );
  addTearDown(container.dispose);
  return container.read(updateDownloaderProvider);
}

/// Whether [dir] holds no file (or does not exist).
bool _wi33NoFiles(String dir) =>
    !Directory(dir).existsSync() ||
    Directory(dir).listSync(recursive: true).whereType<File>().isEmpty;

int _wi33Mode(String path) => FileStat.statSync(path).mode & 0x1ff;

const _wi33Mode0700 = 0x1c0; // octal 700: rwx for the owner only

Matcher _wi33FailsWith(UpdateErrorCause cause) =>
    throwsA(isA<UpdateFailure>().having((f) => f.cause, 'cause', cause));

/// Ten bytes in three chunks: 3, 5 and 2 bytes.
List<List<int>> _wi33TenBytes() => [
  [1, 2, 3],
  [4, 5, 6, 7, 8],
  [9, 10],
];

AppcastItem _wi33Item({int? length}) => testAppcastItem(length: length);

void main() {
  test(
    'a download writes the enclosure bytes to a file in the update download directory',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));
      final item = _wi33Item(length: 10);

      final downloader = _wi33Downloader(net, dir);
      expect(downloader, isA<HttpUpdateDownloader>());
      expect((downloader as HttpUpdateDownloader).directory, dir);

      final path = await downloader.download(item);

      expect(net.requests, hasLength(1));
      expect(net.requests.single.method, 'GET');
      expect(net.requests.single.url.toString(), item.url);
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(
        File(path).parent.resolveSymbolicLinksSync(),
        Directory(dir).resolveSymbolicLinksSync(),
      );
    },
  );

  test(
    'a download without a progress callback still writes the file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes()));

      final path = await _wi33Downloader(
        net,
        dir,
      ).download(_wi33Item(length: null));

      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), hasLength(10));
    },
  );

  test('download progress is bytes received over the Content-Length', () async {
    final dir = p.join(_wi33Root(), 'open-memex-update');
    // The Content-Length wins over the item length.
    final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));
    final progress = <double?>[];

    await _wi33Downloader(
      net,
      dir,
    ).download(_wi33Item(length: 999), onProgress: progress.add);

    expect(progress, isNotEmpty);
    expect(progress, everyElement(isNotNull));
    expect(progress, containsAllInOrder(<double>[0.3, 0.8, 1.0]));
    expect(progress.last, 1.0);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i]!, greaterThanOrEqualTo(progress[i - 1]!));
    }
    expect(progress, everyElement(inInclusiveRange(0.0, 1.0)));
  });

  test(
    'download progress falls back to the item length when the response has no Content-Length',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes()));
      final progress = <double?>[];

      await _wi33Downloader(
        net,
        dir,
      ).download(_wi33Item(length: 10), onProgress: progress.add);

      expect(progress, everyElement(isNotNull));
      expect(progress, containsAllInOrder(<double>[0.3, 0.8, 1.0]));
      expect(progress.last, 1.0);
    },
  );

  test(
    'a response with no Content-Length and an item with no length reports indeterminate progress',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes()));
      final progress = <double?>[];

      final path = await _wi33Downloader(
        net,
        dir,
      ).download(_wi33Item(length: null), onProgress: progress.add);

      expect(progress, isNotEmpty, reason: 'indeterminate is reported');
      expect(progress, everyElement(isNull));
      expect(File(path).readAsBytesSync(), hasLength(10));
    },
  );

  test(
    'an item length of zero with no Content-Length reports indeterminate progress',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes()));
      final progress = <double?>[];

      await _wi33Downloader(
        net,
        dir,
      ).download(_wi33Item(length: 0), onProgress: progress.add);

      expect(progress, isNotEmpty);
      expect(progress, everyElement(isNull));
    },
  );

  test(
    'progress never passes 1 when the item length is less than the bytes received',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes()));
      final progress = <double?>[];

      await _wi33Downloader(
        net,
        dir,
      ).download(_wi33Item(length: 4), onProgress: progress.add);

      expect(progress, everyElement(isNotNull));
      expect(progress, everyElement(inInclusiveRange(0.0, 1.0)));
      expect(progress, contains(0.75));
      expect(progress.last, 1.0);
    },
  );

  test(
    'the production update download directory is open-memex-update under the system temp directory',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(updateDownloadDirProvider),
        p.join(Directory.systemTemp.path, 'open-memex-update'),
      );
    },
  );

  test(
    'the update download directory is under the system temp directory and under the per-user temp directory when the system temp directory is /tmp',
    () {
      var calls = 0;
      String? userDir(String? value) {
        calls++;
        return value;
      }

      String dirFor(String systemTemp, String? user) =>
          updateDownloadDirFor(systemTemp, userTempDir: () => userDir(user));

      // TMPDIR set: the system temp directory, and getconf is never asked.
      expect(
        dirFor('/vaults/My Vault/T', '/var/folders/zz/T/'),
        '/vaults/My Vault/T/open-memex-update',
      );
      expect(
        dirFor('/tmp/other', '/var/folders/zz/T/'),
        '/tmp/other/open-memex-update',
      );
      expect(
        dirFor('/private/var/folders/aa/T', '/var/folders/zz/T/'),
        '/private/var/folders/aa/T/open-memex-update',
      );
      expect(calls, 0);

      // TMPDIR unset: /tmp falls back to the per-user temp directory.
      for (final shared in ['/tmp', '/tmp/', '/private/tmp', '/private/tmp/']) {
        expect(
          dirFor(shared, '/var/folders/zz/T/'),
          '/var/folders/zz/T/open-memex-update',
          reason: shared,
        );
        expect(
          dirFor(shared, '/var/folders/zz/T'),
          '/var/folders/zz/T/open-memex-update',
          reason: shared,
        );
      }
      expect(calls, 8);

      // No usable per-user directory: the path stays under /tmp, which the
      // downloader refuses.
      expect(dirFor('/tmp', null), '/tmp/open-memex-update');
      expect(dirFor('/tmp', ''), '/tmp/open-memex-update');
      expect(dirFor('/tmp', '/tmp'), '/tmp/open-memex-update');
      expect(dirFor('/tmp', '/tmp/'), '/tmp/open-memex-update');
      expect(dirFor('/tmp', '/private/tmp/'), '/tmp/open-memex-update');
      expect(dirFor('/private/tmp', null), '/private/tmp/open-memex-update');
    },
  );

  test(
    'a download over an existing DMG in the update download directory leaves exactly the new bytes',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      Directory(dir).createSync(recursive: true);
      // A stale file longer than the new download, under the same name.
      File(
        p.join(dir, updateDmgFileName),
      ).writeAsBytesSync(List<int>.filled(25, 0xee));
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      final path = await _wi33Downloader(net, dir).download(_wi33Item());

      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(Directory(dir).listSync(), hasLength(1));
    },
  );

  test(
    'two downloads in a row into the same directory leave the second download bytes only',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      var round = 0;
      final net = _Wi33DlHttp(
        (_) => http.StreamedResponse(
          Stream.value(List<int>.filled(7, ++round)),
          200,
          contentLength: 7,
        ),
      );
      final downloader = _wi33Downloader(net, dir);

      await downloader.download(_wi33Item());
      final path = await downloader.download(_wi33Item());

      expect(File(path).readAsBytesSync(), List<int>.filled(7, 2));
    },
  );

  test(
    'a download directory that cannot be set to mode 0700 fails with the download-failed cause and writes nothing',
    () async {
      // /private/tmp exists and is owned by root, so a user cannot chmod it;
      // the guards below keep this test from ever changing a real mode.
      const dir = '/private/tmp';
      if (!Platform.isMacOS || !Directory(dir).existsSync()) {
        markTestSkipped('needs the macOS /private/tmp owned by root');
        return;
      }
      if (Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() ==
          '0') {
        markTestSkipped('root can chmod /private/tmp; the test must not');
        return;
      }
      final leftover = File(p.join(dir, updateDmgFileName));
      if (leftover.existsSync()) {
        markTestSkipped('${leftover.path} exists already');
        return;
      }
      addTearDown(() {
        if (leftover.existsSync()) leftover.deleteSync();
      });
      final modeBefore = _wi33Mode(dir);
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item()),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );

      expect(leftover.existsSync(), isFalse);
      expect(net.requests, isEmpty);
      expect(_wi33Mode(dir), modeBefore);
    },
  );

  test(
    'a download directory that is a symbolic link fails with the download-failed cause and writes nothing through the link',
    () async {
      final root = _wi33Root();
      final target = Directory(p.join(root, 'elsewhere'))..createSync();
      final dir = p.join(root, 'open-memex-update');
      Link(dir).createSync(target.path);
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item()),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );

      expect(target.listSync(), isEmpty);
      expect(net.requests, isEmpty);
      // The link is left as it was, and the target keeps its mode.
      expect(FileSystemEntity.isLinkSync(dir), isTrue);
      expect(_wi33Mode(target.path), isNot(_wi33Mode0700));
    },
  );

  test(
    'a download directory directly under the shared /tmp fails with the download-failed cause and creates nothing',
    () async {
      final unique = p.basename(_wi33Root());
      for (final parent in ['/tmp', '/tmp/', '/private/tmp']) {
        final dir = p.join(parent, 'open-memex-update-$unique');
        addTearDown(() {
          if (Directory(dir).existsSync()) {
            Directory(dir).deleteSync(recursive: true);
          }
        });
        final net = _Wi33DlHttp(
          _wi33Chunks(_wi33TenBytes(), contentLength: 10),
        );

        await expectLater(
          _wi33Downloader(net, dir).download(_wi33Item()),
          _wi33FailsWith(UpdateErrorCause.downloadFailed),
          reason: parent,
        );

        expect(Directory(dir).existsSync(), isFalse, reason: parent);
        expect(net.requests, isEmpty, reason: parent);
      }
    },
  );

  test(
    'a download creates the update download directory with mode 0700',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      expect(Directory(dir).existsSync(), isFalse);
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      await _wi33Downloader(net, dir).download(_wi33Item());

      expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.directory);
      expect(_wi33Mode(dir), _wi33Mode0700);
    },
  );

  test(
    'a download resets an existing update download directory to mode 0700',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      Directory(dir).createSync();
      final chmod = Process.runSync('chmod', ['755', dir]);
      expect(chmod.exitCode, 0);
      expect(_wi33Mode(dir), 0x1ed); // octal 755
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      final path = await _wi33Downloader(net, dir).download(_wi33Item());

      expect(_wi33Mode(dir), _wi33Mode0700);
      expect(File(path).readAsBytesSync(), hasLength(10));
    },
  );

  test(
    'a non-2xx download response fails with the download-failed cause and leaves no partial file',
    () async {
      for (final status in [199, 300, 302, 403, 404, 500, 503]) {
        final dir = p.join(_wi33Root(), 'open-memex-update');
        final net = _Wi33DlHttp(
          _wi33Chunks([
            [1, 2, 3],
            [4, 5],
          ], status: status),
        );

        await expectLater(
          _wi33Downloader(net, dir).download(_wi33Item(length: 5)),
          _wi33FailsWith(UpdateErrorCause.downloadFailed),
          reason: 'HTTP $status',
        );
        expect(_wi33NoFiles(dir), isTrue, reason: 'HTTP $status');
      }
    },
  );

  test(
    'a connection lost mid-stream fails with the download-failed cause and leaves no partial file',
    () async {
      final errors = <Object>[
        http.ClientException('Connection closed while receiving data'),
        const SocketException('Connection reset by peer'),
        const HttpException('Connection closed while receiving data'),
        TimeoutException('No data', const Duration(seconds: 30)),
      ];
      for (final error in errors) {
        final dir = p.join(_wi33Root(), 'open-memex-update');
        Stream<List<int>> body() async* {
          yield [1, 2, 3];
          yield [4, 5, 6, 7];
          throw error;
        }

        final net = _Wi33DlHttp(
          (_) => http.StreamedResponse(body(), 200, contentLength: 10),
        );
        final progress = <double?>[];

        await expectLater(
          _wi33Downloader(
            net,
            dir,
          ).download(_wi33Item(length: 10), onProgress: progress.add),
          _wi33FailsWith(UpdateErrorCause.downloadFailed),
          reason: '$error',
        );
        expect(_wi33NoFiles(dir), isTrue, reason: '$error');
      }
    },
  );

  test(
    'a body shorter than its Content-Length fails with the download-failed cause and leaves no partial file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(
        _wi33Chunks([
          [1, 2, 3],
          [4],
        ], contentLength: 10),
      );

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item(length: 10)),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(_wi33NoFiles(dir), isTrue);
    },
  );

  test(
    'a connection failure before any response fails with the download-failed cause',
    () async {
      final errors = <Object>[
        const SocketException(
          'Failed host lookup: github.com',
          osError: OSError('nodename nor servname provided, or not known', 8),
        ),
        http.ClientException('Connection refused'),
        TimeoutException('No answer', const Duration(seconds: 30)),
      ];
      for (final error in errors) {
        final dir = p.join(_wi33Root(), 'open-memex-update');
        final net = _Wi33DlHttp((_) => throw error);

        await expectLater(
          _wi33Downloader(net, dir).download(_wi33Item()),
          _wi33FailsWith(UpdateErrorCause.downloadFailed),
          reason: '$error',
        );
        expect(_wi33NoFiles(dir), isTrue, reason: '$error');
      }
    },
  );

  test(
    'a download directory that cannot be created fails with the download-failed cause',
    () async {
      final root = _wi33Root();
      // A plain file where the parent folder should be.
      File(p.join(root, 'not-a-folder')).writeAsStringSync('x');
      final dir = p.join(root, 'not-a-folder', 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item()),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
    },
  );

  test(
    'each download makes a client from the factory and closes it after a success and after a failure',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));
      final downloader = _wi33Downloader(net, dir);

      await downloader.download(_wi33Item());
      net.respond = _wi33Chunks(const [], status: 500);
      await expectLater(
        downloader.download(_wi33Item()),
        throwsA(isA<UpdateFailure>()),
      );

      expect(net.clients, hasLength(2));
      expect(net.clients.map((c) => c.closed), [true, true]);
    },
  );

  test('every 2xx download response is accepted and written', () async {
    for (final status in [200, 201, 206, 299]) {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), status: status));

      final path = await _wi33Downloader(net, dir).download(_wi33Item());

      expect(
        File(path).readAsBytesSync(),
        hasLength(10),
        reason: 'HTTP $status',
      );
    }
  });

  test(
    'a download creates a missing parent of the update download directory',
    () async {
      final dir = p.join(_wi33Root(), 'missing', 'parent', 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 10));

      final path = await _wi33Downloader(net, dir).download(_wi33Item());

      expect(File(path).readAsBytesSync(), hasLength(10));
      expect(_wi33Mode(dir), _wi33Mode0700);
    },
  );

  test(
    'a body longer than its Content-Length fails with the download-failed cause and leaves no partial file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp(_wi33Chunks(_wi33TenBytes(), contentLength: 8));

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item(length: 8)),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(_wi33NoFiles(dir), isTrue);
    },
  );

  test(
    'the production downloader waits 60 seconds without a byte before it gives up',
    () {
      final net = _Wi33DlHttp(_wi33Chunks(const []));
      final downloader = _wi33Downloader(net, 'unused');

      expect(
        (downloader as HttpUpdateDownloader).idleTimeout,
        const Duration(seconds: 60),
      );
    },
  );

  test(
    'a response that never starts fails with the download-failed cause after the idle timeout and leaves no partial file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final clients = <_Wi33DlClosingClient>[];
      final downloader = HttpUpdateDownloader(
        clientFactory: () {
          final client = _Wi33DlClosingClient(
            MockClient.streaming(
              (_, _) => Completer<http.StreamedResponse>().future,
            ),
          );
          clients.add(client);
          return client;
        },
        directory: dir,
        idleTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        downloader.download(_wi33Item()),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(_wi33NoFiles(dir), isTrue);
      expect(clients.single.closed, isTrue);
    },
  );

  test(
    'a download that stalls after some bytes fails with the download-failed cause after the idle timeout and leaves no partial file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final net = _Wi33DlHttp(
        (_) => http.StreamedResponse(body.stream, 200, contentLength: 10),
      );
      final downloader = HttpUpdateDownloader(
        clientFactory: net.call,
        directory: dir,
        idleTimeout: const Duration(milliseconds: 100),
      );
      final progress = <double?>[];

      final result = downloader.download(_wi33Item(), onProgress: progress.add);
      // The body never ends: the first chunk arrives, then nothing.
      body.add([1, 2, 3]);

      await expectLater(
        result,
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(progress, [0.3]);
      expect(_wi33NoFiles(dir), isTrue);
      expect(net.clients.single.closed, isTrue);
    },
  );

  test(
    'the idle timeout restarts on every chunk and does not limit the whole download',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      const idle = Duration(milliseconds: 500);
      const gap = Duration(milliseconds: 25);
      const chunks = 30; // 750 ms from the first listen to the close
      final fromListen = Stopwatch();
      late final StreamController<List<int>> body;
      // The chunk schedule starts when the download starts listening to the
      // body, not when it was called: the time before that (the directory
      // setup) never counts against the idle timeout under test.
      body = StreamController<List<int>>(
        onListen: () async {
          fromListen.start();
          for (var i = 0; i < chunks; i++) {
            await Future<void>.delayed(gap);
            if (body.isClosed) return;
            body.add([i]);
          }
          await body.close();
        },
      );
      addTearDown(() {
        if (!body.isClosed) body.close();
      });
      final net = _Wi33DlHttp(
        (_) => http.StreamedResponse(body.stream, 200, contentLength: chunks),
      );
      final downloader = HttpUpdateDownloader(
        clientFactory: net.call,
        directory: dir,
        idleTimeout: idle,
      );

      final path = await downloader.download(_wi33Item());

      // The whole body took longer than the idle timeout, yet no gap did.
      expect(fromListen.elapsed, greaterThan(idle));
      expect(File(path).readAsBytesSync(), [
        for (var i = 0; i < chunks; i++) i,
      ]);
    },
  );

  test(
    'an enclosure URL the HTTP client refuses fails with the download-failed cause and leaves no partial file',
    () async {
      final urls = <String>[
        'ftp://example.com/Open-Memex.dmg',
        'Open-Memex.dmg',
        'http://[::bad/Open-Memex.dmg',
      ];
      for (final url in urls) {
        final dir = p.join(_wi33Root(), 'open-memex-update');
        final container = ProviderContainer(
          overrides: [updateDownloadDirProvider.overrideWithValue(dir)],
        );
        addTearDown(container.dispose);

        // The production client (no network: it refuses before connecting).
        await expectLater(
          container
              .read(updateDownloaderProvider)
              .download(testAppcastItem(url: url)),
          _wi33FailsWith(UpdateErrorCause.downloadFailed),
          reason: url,
        );
        expect(_wi33NoFiles(dir), isTrue, reason: url);
      }
    },
  );

  test(
    'an ArgumentError from the client fails with the download-failed cause and leaves no partial file',
    () async {
      final dir = p.join(_wi33Root(), 'open-memex-update');
      final net = _Wi33DlHttp((_) => throw ArgumentError('Unsupported scheme'));

      await expectLater(
        _wi33Downloader(net, dir).download(_wi33Item()),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(_wi33NoFiles(dir), isTrue);
      expect(net.clients.single.closed, isTrue);
    },
  );
}
