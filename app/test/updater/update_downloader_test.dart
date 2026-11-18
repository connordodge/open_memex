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
}
