// WI #140 (Spec #123 W3; R15, R33, R41, R42; rulings D10, D13, D19): the
// hosted vault's attachments domain, `HostedAttachmentsAccess`, over a real
// `HostedClient` and the fake vault server (no network).
//
// - `add`/`addBytes` upload through `POST /vaults/<v>/api/v1/attachments
//   ?name=<name>` with the raw body; the token only in the header. Uploads
//   wait 60 s + 1 s per MB (1 MB = 1,048,576 bytes, as R15's 100 MB), never
//   the 10 s JSON timeout. A 413 surfaces the server's R15 text.
// - `read` is a GET, `info` a HEAD cached per path; read bytes go in an LRU
//   bounded at 256 MB (an injected small bound in tests).
// - D13: after the app's own add, info and read of the new path send nothing.
// - `open` downloads to a per-server, per-vault cache folder (an injected temp
//   root) and opens the copy; executables (R33 table, or the copy's
//   executable bit) are revealed instead. Hosted `reveal` is unsupported
//   except for executables.
// - R42: offline, an old server (the exact no-route 404; a HEAD 404 has no
//   body, like the real server's), the once-per-session check before an
//   upload over 8 MiB, and the missing 404 (`not found: attachment …`).
//
// Time runs on a FakeClock through `clockProvider`; no real wait.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/attachments.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:path/path.dart' as p;

import '../../support/attachments_fakes.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_file_revealer.dart';
import '../../support/fake_vault_server.dart';

const _offline = "the vault server can't be reached";
const _serverTooOld =
    "This vault's server is too old for attachments; update memex on the server.";
const _mb = 1024 * 1024;

class _Wi140UrlOpener implements UrlOpener {
  final List<String> opened = [];

  @override
  Future<void> open(String url) async => opened.add(url);
}

/// The vault-relative path of a stored attachment named [name].
String _path(String name) => 'objects/aa/$fakeAttachmentHash/$name';

class _Env {
  _Env(this.container, this.clock, this.server, this.client, this.cacheRoot);

  final ProviderContainer container;
  final FakeClock clock;
  final FakeVaultServer server;
  final HostedClient client;
  final String cacheRoot;
  final opener = _Wi140UrlOpener();
  final revealer = FakeFileRevealer();

  HostedAttachmentsAccess access({
    String vault = 'seed',
    HostedClient? over,
    int maxCachedBytes = hostedAttachmentCacheMaxBytesForTests,
  }) => HostedAttachmentsAccess(
    client: over ?? client,
    vaultName: vault,
    urlOpener: opener,
    fileRevealer: revealer,
    openCacheRoot: cacheRoot,
    maxCachedBytes: maxCachedBytes,
  );

  List<http.Request> get requests => server.requests;

  int count(String method) => requests.where((r) => r.method == method).length;
}

/// A bound large enough for every test that doesn't test the bound (the
/// production constant is pinned on its own).
const hostedAttachmentCacheMaxBytesForTests = 256 * _mb;

_Env _env() {
  final clock = FakeClock();
  final server = FakeVaultServer()..serveAttachments('seed');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final root = Directory.systemTemp.createTempSync('wi140-hosted-');
  addTearDown(() => root.deleteSync(recursive: true));
  final cacheRoot = Directory(p.join(root.path, 'open cache'))..createSync();
  return _Env(
    container,
    clock,
    server,
    server.connect(container),
    cacheRoot.path,
  );
}

Uint8List _bytes(int n, [int seed = 1]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) % 256));

/// Lets queued work (fake responses, file I/O) run.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await pumpEventQueue();
  }
}

/// Pumps until [done] holds (at most a few thousand turns).
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await pumpEventQueue();
  }
  expect(done(), isTrue, reason: 'condition never held');
}

/// Starts [f] and collects its one outcome.
List<Object?> _start(Future<Object?> f) {
  final out = <Object?>[];
  unawaited(f.then<void>(out.add, onError: (Object e) => out.add(e)));
  return out;
}

void _expectAddFailed(
  Object? result,
  AttachmentAddFailureReason reason,
  String message,
) {
  expect(result, isA<AttachmentAddFailed>());
  final failed = _as<AttachmentAddFailed>(result);
  expect(failed.reason, reason);
  expect(failed.message, message);
}

void _expectNoTokenInUrls(_Env env) {
  for (final r in env.requests) {
    expect(r.url.toString(), isNot(contains(fakeServerToken)));
    expect(r.headers['authorization'], 'Bearer $fakeServerToken');
  }
}

/// [o] as a [T], failing the test (not throwing) when it is not one.
T _as<T>(Object? o) {
  expect(o, isA<T>());
  return o as T;
}

void main() {
  group('add', () {
    test(
      'hosted addBytes uploads through the attachments route with the token in the header only',
      () async {
        final env = _env();
        final bytes = _bytes(5000);

        final result = await env.access().addBytes(bytes, 'Q&A #1 notes.pdf');

        expect(env.requests, hasLength(1));
        final post = env.requests.single;
        expect(post.method, 'POST');
        expect(post.url.path, '/vaults/seed/api/v1/attachments');
        expect(post.url.queryParameters, {'name': 'Q&A #1 notes.pdf'});
        expect(post.bodyBytes, bytes, reason: 'the raw bytes, not JSON');
        _expectNoTokenInUrls(env);

        expect(result, isA<AttachmentAdded>());
        final added = _as<AttachmentAdded>(result).attachment;
        expect(added.name, 'Q&A #1 notes.pdf');
        expect(added.size, 5000);
        expect(added.type, 'application/pdf');
        expect(added.path, startsWith('objects/'));
        expect(added.path, endsWith('/Q&A #1 notes.pdf'));
        expect(env.server.storedAttachment('seed', added.path), bytes);
        expect(
          added.markdown,
          contains(encodeAttachmentName('Q&A #1 notes.pdf')),
        );
      },
    );

    test(
      'hosted add reads the file and uploads it under its base name or the given name',
      () async {
        final env = _env();
        final dir = Directory.systemTemp.createTempSync('wi140-src-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final bytes = _bytes(1200, 9);
        final file = File(p.join(dir.path, 'Q3 report.pdf'))
          ..writeAsBytesSync(bytes);

        final plain = await env.access().add(file.path, null);
        final renamed = await env.access().add(file.path, 'Signed.pdf');

        final posts = env.requests.where((r) => r.method == 'POST').toList();
        expect(posts, hasLength(2));
        expect(posts[0].url.queryParameters['name'], 'Q3 report.pdf');
        expect(posts[1].url.queryParameters['name'], 'Signed.pdf');
        for (final post in posts) {
          expect(post.url.path, '/vaults/seed/api/v1/attachments');
          expect(post.bodyBytes, bytes);
        }
        _expectNoTokenInUrls(env);
        expect(_as<AttachmentAdded>(plain).attachment.name, 'Q3 report.pdf');
        expect(_as<AttachmentAdded>(renamed).attachment.name, 'Signed.pdf');
      },
    );

    test(
      'a 60 MB hosted upload waits 60 s plus 60 s, not the 10 s JSON timeout',
      () async {
        final env = _env();
        env.server.holdAttachmentUploads = true;

        final out = _start(env.access().addBytes(Uint8List(60 * _mb), 'a.mov'));
        await _until(() => env.count('POST') == 1);

        env.clock.advance(const Duration(seconds: 11));
        await _settle();
        expect(out, isEmpty, reason: 'not the 10 s JSON timeout');

        env.clock.advance(const Duration(seconds: 108)); // 119 s
        await _settle();
        expect(out, isEmpty, reason: '60 s + 60 s has not passed');

        env.clock.advance(const Duration(seconds: 2)); // 121 s
        await _settle();
        expect(out, hasLength(1));
        _expectAddFailed(
          out.single,
          AttachmentAddFailureReason.unreachable,
          _offline,
        );
      },
    );

    test(
      'a small hosted upload waits 60 s, not the 10 s JSON timeout',
      () async {
        final env = _env();
        env.server.holdAttachmentUploads = true;

        final out = _start(env.access().addBytes(_bytes(1024), 'n.txt'));
        await _until(() => env.count('POST') == 1);

        env.clock.advance(const Duration(seconds: 11));
        await _settle();
        expect(out, isEmpty);
        env.clock.advance(const Duration(seconds: 48)); // 59 s
        await _settle();
        expect(out, isEmpty);
        env.clock.advance(const Duration(seconds: 3)); // 62 s
        await _settle();
        expect(out, hasLength(1));
        _expectAddFailed(
          out.single,
          AttachmentAddFailureReason.unreachable,
          _offline,
        );
      },
    );

    test(
      'a hosted upload over the limit surfaces the R15 text of the 413',
      () async {
        final env = _env();
        env.server.attachmentUploadLimit = 1024;

        final result = await env.access().addBytes(_bytes(2048), 'big.bin');

        _expectAddFailed(
          result,
          AttachmentAddFailureReason.tooLarge,
          "big.bin is larger than 100 MB and wasn't attached.",
        );
      },
    );
  });

  group('read, info and the LRU', () {
    test(
      'hosted read downloads the bytes with GET and percent-encodes the path',
      () async {
        final env = _env();
        final path = _path('Q&A #1? 50%.png');
        final bytes = _bytes(3000);
        env.server.putAttachment('seed', path, bytes);

        final result = await env.access().read(path);

        expect(result, isA<AttachmentBytes>());
        expect(_as<AttachmentBytes>(result).bytes, bytes);
        expect(env.requests, hasLength(1));
        final get = env.requests.single;
        expect(get.method, 'GET');
        expect(get.url.pathSegments, [
          'vaults',
          'seed',
          'api',
          'v1',
          'attachments',
          ...path.split('/'),
        ]);
        expect(get.url.query, isEmpty);
        expect(get.url.fragment, isEmpty);
        _expectNoTokenInUrls(env);
      },
    );

    test('hosted info uses HEAD and caches the size per path', () async {
      final env = _env();
      env.server.putAttachment('seed', _path('photo.png'), _bytes(1234));
      env.server.putAttachment('seed', _path('deck.pdf'), _bytes(99));
      final access = env.access();

      final first = await access.info(_path('photo.png'));
      final again = await access.info(_path('photo.png'));

      for (final info in [first, again]) {
        expect(info, isA<AttachmentInfoFound>());
        expect(_as<AttachmentInfoFound>(info).info.size, 1234);
        expect(_as<AttachmentInfoFound>(info).info.type, 'image/png');
      }
      expect(env.count('HEAD'), 1, reason: 'cached per path');
      expect(env.count('GET'), 0, reason: 'info never downloads');

      final other = await access.info(_path('deck.pdf'));
      expect(_as<AttachmentInfoFound>(other).info.size, 99);
      expect(_as<AttachmentInfoFound>(other).info.type, 'application/pdf');
      expect(env.count('HEAD'), 2);
      expect(env.requests.every((r) => r.method == 'HEAD'), isTrue);
      _expectNoTokenInUrls(env);
    });

    test(
      'a second hosted read of the same path is served from the LRU with 0 requests',
      () async {
        final env = _env();
        final bytes = _bytes(4096);
        env.server.putAttachment('seed', _path('shot.png'), bytes);
        final access = env.access();

        await access.read(_path('shot.png'));
        final before = env.requests.length;
        final second = await access.read(_path('shot.png'));

        expect(env.requests.length, before, reason: '0 requests');
        expect(_as<AttachmentBytes>(second).bytes, bytes);
      },
    );

    test(
      'the hosted LRU evicts the least recently used bytes past its bound',
      () async {
        final env = _env();
        for (final n in ['a', 'b', 'c']) {
          env.server.putAttachment('seed', _path('$n.png'), _bytes(40));
        }
        final access = env.access(maxCachedBytes: 100);

        await access.read(_path('a.png'));
        await access.read(_path('b.png'));
        await access.read(_path('a.png')); // a is now the most recent
        expect(env.count('GET'), 2);
        await access.read(_path('c.png')); // 120 > 100: b goes
        expect(env.count('GET'), 3);

        await access.read(_path('a.png'));
        await access.read(_path('c.png'));
        expect(env.count('GET'), 3, reason: 'a and c stayed');
        await access.read(_path('b.png'));
        expect(env.count('GET'), 4, reason: 'b was evicted');
      },
    );

    test('the hosted LRU keeps entries that fill its bound exactly', () async {
      final env = _env();
      env.server.putAttachment('seed', _path('a.png'), _bytes(50));
      env.server.putAttachment('seed', _path('b.png'), _bytes(50));
      final access = env.access(maxCachedBytes: 100);

      await access.read(_path('a.png'));
      await access.read(_path('b.png'));
      await access.read(_path('a.png'));
      await access.read(_path('b.png'));

      expect(env.count('GET'), 2);
    });

    test('the hosted LRU never holds bytes larger than its bound', () async {
      final env = _env();
      final big = _bytes(101);
      env.server.putAttachment('seed', _path('big.png'), big);
      final access = env.access(maxCachedBytes: 100);

      final first = await access.read(_path('big.png'));
      final second = await access.read(_path('big.png'));

      expect(_as<AttachmentBytes>(first).bytes, big);
      expect(_as<AttachmentBytes>(second).bytes, big);
      expect(env.count('GET'), 2, reason: 'never cached');
    });

    test('the hosted LRU bound is 256 MB', () {
      expect(hostedAttachmentCacheMaxBytes, 256 * 1024 * 1024);
    });
  });

  group('D13 write-through', () {
    test(
      'after a hosted addBytes info and read of the new path make 0 HEAD and 0 GET',
      () async {
        final env = _env();
        final bytes = _bytes(2500);
        final access = env.access();

        final added = await access.addBytes(bytes, 'shot.png');
        final path = _as<AttachmentAdded>(added).attachment.path;
        for (var i = 0; i < 2; i++) {
          final info = await access.info(path);
          expect(_as<AttachmentInfoFound>(info).info.size, 2500);
          expect(_as<AttachmentInfoFound>(info).info.type, 'image/png');
          final read = await access.read(path);
          expect(_as<AttachmentBytes>(read).bytes, bytes);
        }

        expect(env.count('HEAD'), 0);
        expect(env.count('GET'), 0);
        expect(env.requests, hasLength(1), reason: 'only the upload');
      },
    );

    test(
      'after a hosted add of a file info and read of the new path make 0 requests',
      () async {
        final env = _env();
        final dir = Directory.systemTemp.createTempSync('wi140-src-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final bytes = _bytes(700, 3);
        final file = File(p.join(dir.path, 'photo.png'))
          ..writeAsBytesSync(bytes);
        final access = env.access();

        final added = await access.add(file.path, null);
        final path = _as<AttachmentAdded>(added).attachment.path;
        final before = env.requests.length;
        final info = await access.info(path);
        final read = await access.read(path);
        await access.info(path);
        await access.read(path);

        expect(env.requests.length, before);
        expect(_as<AttachmentInfoFound>(info).info.size, 700);
        expect(_as<AttachmentBytes>(read).bytes, bytes);
      },
    );
  });

  group('open and reveal', () {
    test(
      'hosted open downloads to the per vault cache folder and opens the cached copy',
      () async {
        final env = _env();
        final bytes = _bytes(900);
        env.server.putAttachment('seed', _path('Q3 report.pdf'), bytes);

        final result = await env.access().open(_path('Q3 report.pdf'));

        expect(result, isA<AttachmentActionDone>());
        expect(env.opener.opened, hasLength(1));
        final copy = env.opener.opened.single;
        expect(p.isAbsolute(copy), isTrue);
        expect(p.isWithin(env.cacheRoot, copy), isTrue);
        expect(p.basename(copy), 'Q3 report.pdf');
        expect(File(copy).readAsBytesSync(), bytes);
        expect(env.revealer.paths, isEmpty);
        expect(env.count('GET'), 1);
        _expectNoTokenInUrls(env);
      },
    );

    test(
      'hosted open keeps a separate cache folder per vault and per server',
      () async {
        final env = _env();
        env.server.putAttachment('seed', _path('a.pdf'), _bytes(10, 1));
        env.server.putAttachment('other', _path('a.pdf'), _bytes(10, 2));
        final second = env.server.connect(
          env.container,
          serverId: 'srv-b',
          serverName: 'b',
          serverUrl: 'http://other.local:7878',
        );

        await env.access().open(_path('a.pdf'));
        await env.access(vault: 'other').open(_path('a.pdf'));
        await env.access(over: second).open(_path('a.pdf'));

        expect(env.opener.opened, hasLength(3));
        final dirs = env.opener.opened.map(p.dirname).toSet();
        expect(dirs, hasLength(3), reason: 'one folder per server and vault');
        for (final copy in env.opener.opened) {
          expect(p.isWithin(env.cacheRoot, copy), isTrue);
        }
        expect(File(env.opener.opened[0]).readAsBytesSync(), _bytes(10, 1));
        expect(File(env.opener.opened[1]).readAsBytesSync(), _bytes(10, 2));
      },
    );

    test(
      'hosted reveal is unsupported except for executables, which reveal the downloaded copy',
      () async {
        final env = _env();
        env.server.putAttachment('seed', _path('report.pdf'), _bytes(5));
        final bytes = _bytes(64);
        env.server.putAttachment('seed', _path('install.sh'), bytes);

        final plain = await env.access().reveal(_path('report.pdf'));

        expect(plain, isA<AttachmentActionFailed>());
        expect(
          _as<AttachmentActionFailed>(plain).failure,
          AttachmentLookupFailure.unsupported,
        );
        expect(env.revealer.paths, isEmpty);
        expect(env.opener.opened, isEmpty);
        expect(env.requests, isEmpty, reason: 'nothing is downloaded');

        final result = await env.access().reveal(_path('install.sh'));

        expect(result, isA<AttachmentActionDone>());
        expect(env.revealer.paths, hasLength(1));
        final copy = env.revealer.paths.single;
        expect(p.isWithin(env.cacheRoot, copy), isTrue);
        expect(p.basename(copy), 'install.sh');
        expect(File(copy).readAsBytesSync(), bytes);
        expect(env.opener.opened, isEmpty);
      },
    );

    test(
      'hosted open of every executable table type reveals the downloaded copy and never opens',
      () async {
        final env = _env();
        final names = [
          for (final ext in executableExtensions) ...[
            'tool.$ext',
            'TOOL.${ext.toUpperCase()}',
          ],
        ];
        final access = env.access();
        for (final name in names) {
          env.server.putAttachment('seed', _path(name), [1, 2, 3]);

          final result = await access.open(_path(name));

          expect(result, isA<AttachmentActionDone>(), reason: name);
          expect(env.revealer.paths.last, endsWith('/$name'), reason: name);
          expect(p.isWithin(env.cacheRoot, env.revealer.paths.last), isTrue);
          expect(File(env.revealer.paths.last).existsSync(), isTrue);
        }
        expect(env.revealer.paths, hasLength(names.length));
        expect(env.opener.opened, isEmpty);
      },
    );

    test(
      'hosted open of a cached copy with an executable bit reveals and never opens',
      () async {
        final env = _env();
        env.server.putAttachment('seed', _path('runme'), _bytes(8));
        final access = env.access();

        await access.open(_path('runme'));
        expect(env.opener.opened, hasLength(1));
        final copy = env.opener.opened.single;
        final chmod = await Process.run('chmod', ['755', copy]);
        expect(chmod.exitCode, 0);

        final result = await access.open(_path('runme'));

        expect(result, isA<AttachmentActionDone>());
        expect(env.revealer.paths, [copy]);
        expect(env.opener.opened, hasLength(1), reason: 'never opened again');
      },
    );
  });

  group('offline', () {
    test('offline hosted read and info give the offline result', () async {
      for (final failure in [
        FakeServerFailure.refused,
        FakeServerFailure.hostLookup,
        FakeServerFailure.drop,
      ]) {
        final env = _env();
        env.server.putAttachment('seed', _path('photo.png'), _bytes(10));
        env.server.failure = failure;

        final read = await env.access().read(_path('photo.png'));
        final info = await env.access().info(_path('photo.png'));

        expect(read, isA<AttachmentReadFailed>(), reason: '$failure');
        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.offline,
          reason: '$failure',
        );
        expect(info, isA<AttachmentInfoFailed>(), reason: '$failure');
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.offline,
          reason: '$failure',
        );
        expect(
          env.container.read(hostedConnectionStatusProvider(fakeServerId)),
          HostedConnectionStatus.unreachable,
        );
      }
    });

    test('offline hosted open fails offline and opens nothing', () async {
      final env = _env();
      env.server.putAttachment('seed', _path('report.pdf'), _bytes(10));
      env.server.putAttachment('seed', _path('setup.pkg'), _bytes(10));
      env.server.failure = FakeServerFailure.refused;

      for (final name in ['report.pdf', 'setup.pkg']) {
        final result = await env.access().open(_path(name));

        expect(result, isA<AttachmentActionFailed>(), reason: name);
        expect(
          _as<AttachmentActionFailed>(result).failure,
          AttachmentLookupFailure.offline,
          reason: name,
        );
      }
      final reveal = await env.access().reveal(_path('setup.pkg'));
      expect(
        _as<AttachmentActionFailed>(reveal).failure,
        AttachmentLookupFailure.offline,
      );
      expect(env.opener.opened, isEmpty);
      expect(env.revealer.paths, isEmpty);
    });

    test(
      'offline hosted add fails with the vault server cannot be reached reason',
      () async {
        final env = _env();
        final dir = Directory.systemTemp.createTempSync('wi140-src-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File(p.join(dir.path, 'a.pdf'))..writeAsBytesSync([1]);
        env.server.failure = FakeServerFailure.refused;

        final fromBytes = await env.access().addBytes(_bytes(10), 'b.png');
        final fromFile = await env.access().add(file.path, null);

        for (final result in [fromBytes, fromFile]) {
          _expectAddFailed(
            result,
            AttachmentAddFailureReason.unreachable,
            _offline,
          );
        }
      },
    );

    test(
      'a hosted download that never answers is offline after its long timeout, not after 10 s',
      () async {
        final env = _env();
        env.server.putAttachment('seed', _path('photo.png'), _bytes(10));
        env.server.holdAttachmentDownloads = true;

        final out = _start(env.access().read(_path('photo.png')));
        await _until(() => env.count('GET') == 1);

        env.clock.advance(const Duration(seconds: 11));
        await _settle();
        expect(out, isEmpty, reason: 'not the 10 s JSON timeout');

        env.clock.advance(const Duration(seconds: 150)); // 161 s
        await _settle();
        expect(out, hasLength(1));
        expect(out.single, isA<AttachmentReadFailed>());
        expect(
          _as<AttachmentReadFailed>(out.single).failure,
          AttachmentLookupFailure.offline,
        );
      },
    );
  });

  group('old server and missing files', () {
    test(
      'an old server gives the server too old result on every attachment route',
      () async {
        final env = _env();
        env.server.attachmentRoutesMissing = true;
        final access = env.access();

        final add = await access.addBytes(_bytes(100), 'note.txt');
        final read = await access.read(_path('photo.png'));
        final info = await access.info(_path('photo.png'));
        final open = await access.open(_path('report.pdf'));

        _expectAddFailed(
          add,
          AttachmentAddFailureReason.serverTooOld,
          _serverTooOld,
        );
        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.serverTooOld,
        );
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.serverTooOld,
          reason: 'a HEAD 404 has no body: info must still tell',
        );
        expect(
          _as<AttachmentActionFailed>(open).failure,
          AttachmentLookupFailure.serverTooOld,
        );
        expect(env.opener.opened, isEmpty);
      },
    );

    test(
      'a missing attachment 404 gives the missing result, not server too old',
      () async {
        final env = _env();
        final access = env.access();

        final read = await access.read(_path('gone.png'));
        final info = await access.info(_path('gone.pdf'));
        final open = await access.open(_path('gone.pdf'));
        final openExec = await access.open(_path('gone.sh'));

        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.missing,
        );
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.missing,
          reason: 'a HEAD 404 has no body: info must still tell',
        );
        expect(
          _as<AttachmentActionFailed>(open).failure,
          AttachmentLookupFailure.missing,
        );
        expect(
          _as<AttachmentActionFailed>(openExec).failure,
          AttachmentLookupFailure.missing,
        );
        expect(env.opener.opened, isEmpty);
        expect(env.revealer.paths, isEmpty);
      },
    );

    test(
      'before an upload over 8 MiB an old server is detected and its 413 never shows as a size error',
      () async {
        final env = _env();
        env.server.attachmentRoutesMissing = true;

        final result = await env.access().addBytes(
          Uint8List(8 * _mb + 1),
          'scan.pdf',
        );

        _expectAddFailed(
          result,
          AttachmentAddFailureReason.serverTooOld,
          _serverTooOld,
        );
        expect(env.count('POST'), 0, reason: 'the check comes first');
      },
    );

    test(
      'the check before a large upload runs once per server session on an old server',
      () async {
        final env = _env();
        env.server.attachmentRoutesMissing = true;
        env.server.serveAttachments('other');

        final first = await env.access().addBytes(Uint8List(9 * _mb), 'a.pdf');
        final checks = env.requests.length;
        final second = await env.access().addBytes(Uint8List(9 * _mb), 'b.pdf');
        final third = await env
            .access(vault: 'other')
            .addBytes(Uint8List(9 * _mb), 'c.pdf');

        for (final r in [first, second, third]) {
          _expectAddFailed(
            r,
            AttachmentAddFailureReason.serverTooOld,
            _serverTooOld,
          );
        }
        expect(checks, greaterThan(0));
        expect(env.requests.length, checks, reason: 'checked once');
      },
    );

    test(
      'the check before a large upload runs once per server session on a current server',
      () async {
        final env = _env();
        env.server.serveAttachments('other');

        final first = await env.access().addBytes(Uint8List(9 * _mb), 'a.pdf');
        final afterFirst = env.requests.length;
        final second = await env.access().addBytes(_bytes(9 * _mb), 'b.pdf');
        final third = await env
            .access(vault: 'other')
            .addBytes(_bytes(9 * _mb, 5), 'c.pdf');

        for (final r in [first, second, third]) {
          expect(r, isA<AttachmentAdded>());
        }
        expect(afterFirst, greaterThan(1), reason: 'a check, then the POST');
        expect(env.requests[afterFirst - 1].method, 'POST');
        expect(env.requests.length, afterFirst + 2, reason: 'POSTs only');
        expect(env.count('POST'), 3);
      },
    );

    test('an upload of exactly 8 MiB needs no server check', () async {
      final env = _env();

      final result = await env.access().addBytes(
        Uint8List(8 * _mb),
        'eight.bin',
      );

      expect(result, isA<AttachmentAdded>());
      expect(env.requests, hasLength(1));
      expect(env.requests.single.method, 'POST');
    });
  });
}
