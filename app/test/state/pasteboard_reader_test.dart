// WI #145 (Spec #123 R8 seam): `PlatformPasteboardReader` sends
// `readPasteboard` on `open_memex/files` and maps the reply to
// `PasteboardContents` (files, PNG bytes, text presence). The Swift side is a
// thin pass-through (MANUAL); every mapping row is pinned here over a mock
// channel. A channel error reads as empty and never throws.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';
import 'package:open_memex_app/src/state/vault_trash.dart'
    show vaultFilesChannel;

import '../support/attachment_input_fakes.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Calls the mock native side received: (method, arguments).
final _received = <(String, Object?)>[];

/// Installs a native side that answers every call with [reply].
void _native(Object? Function(MethodCall call) reply) {
  _received.clear();
  _messenger.setMockMethodCallHandler(vaultFilesChannel, (call) async {
    _received.add((call.method, call.arguments));
    return reply(call);
  });
}

Future<PasteboardContents> _read() => const PlatformPasteboardReader().read();

/// [c] is empty, and the reader did ask the native side (a reader that never
/// called the channel would also read as empty).
void _expectEmpty(PasteboardContents c, {bool asked = true}) {
  if (asked) {
    expect(_received.map((r) => r.$1), contains('readPasteboard'));
  }
  expect(c.files, isEmpty);
  expect(c.png, isNull);
  expect(c.hasText, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => _messenger.setMockMethodCallHandler(vaultFilesChannel, null));

  test('the channel is the existing open_memex files channel', () {
    expect(vaultFilesChannel.name, 'open_memex/files');
  });

  test(
    'read sends readPasteboard with no arguments on the files channel',
    () async {
      _native((_) => null);

      await _read();

      expect(_received, hasLength(1));
      expect(_received.single.$1, 'readPasteboard');
      expect(_received.single.$2, isNull);
    },
  );

  test('a files reply maps to the file paths in order', () async {
    final paths = [
      '/vaults/My Vault/inbox/b report.pdf',
      '/vaults/My Vault/inbox/a.png',
      '/vaults/My Vault/inbox/it\'s here (1).txt',
    ];
    _native((_) => {'files': List.of(paths)});

    final c = await _read();

    expect(c.files, paths);
    expect(c.png, isNull);
    expect(c.hasText, isFalse);
  });

  test('a png reply maps to the exact image bytes', () async {
    final bytes = fakePngBytes(32);
    _native((_) => {'png': Uint8List.fromList(bytes)});

    final c = await _read();

    expect(c.png, isNotNull);
    expect(c.png, bytes);
    expect(c.files, isEmpty);
    expect(c.hasText, isFalse);
  });

  test('an empty map reply maps to empty', () async {
    _native((_) => <String, Object?>{});

    _expectEmpty(await _read());
  });

  test('a null reply maps to empty', () async {
    _native((_) => null);

    _expectEmpty(await _read());
  });

  test('an empty files list maps to no files', () async {
    _native((_) => {'files': <String>[]});

    _expectEmpty(await _read());
  });

  test('a reply that is not a map maps to empty without throwing', () async {
    _native((_) => 'not a map');

    _expectEmpty(await _read());
  });

  test('hasText true maps to hasText with no files and no image', () async {
    _native((_) => {'hasText': true});

    final c = await _read();

    expect(c.hasText, isTrue);
    expect(c.files, isEmpty);
    expect(c.png, isNull);
  });

  test('hasText false maps to hasText false', () async {
    _native((_) => {'hasText': false});

    _expectEmpty(await _read());
  });

  test('files and hasText together are both reported', () async {
    _native(
      (_) => {
        'files': ['/vaults/My Vault/a.txt'],
        'hasText': true,
      },
    );

    final c = await _read();

    expect(c.files, ['/vaults/My Vault/a.txt']);
    expect(c.hasText, isTrue);
  });

  test('png and hasText together are both reported', () async {
    final bytes = fakePngBytes(4);
    _native((_) => {'png': Uint8List.fromList(bytes), 'hasText': true});

    final c = await _read();

    expect(c.png, bytes);
    expect(c.hasText, isTrue);
    expect(c.files, isEmpty);
  });

  test('a platform error maps to empty without throwing', () async {
    _native(
      (_) => throw PlatformException(
        code: 'read_failed',
        message: 'native text',
        details: {'domain': 'NSPasteboard', 'code': 0},
      ),
    );

    _expectEmpty(await _read());
    expect(_received.single.$1, 'readPasteboard');
  });

  test('a bad_arguments style error with no details maps to empty', () async {
    _native((_) => throw PlatformException(code: 'bad_arguments'));

    _expectEmpty(await _read());
  });

  test('a missing native handler maps to empty without throwing', () async {
    _messenger.setMockMethodCallHandler(vaultFilesChannel, null);

    _expectEmpty(await _read(), asked: false);
  });

  test('a not implemented reply from an older runner maps to empty', () async {
    _native((_) => throw MissingPluginException('readPasteboard'));

    _expectEmpty(await _read());
  });

  test(
    'the default provider reads the clipboard through the channel',
    () async {
      final bytes = fakePngBytes(6);
      _native((_) => {'png': Uint8List.fromList(bytes), 'hasText': true});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final c = await container.read(pasteboardReaderProvider).read();

      expect(_received.single.$1, 'readPasteboard');
      expect(c.png, bytes);
      expect(c.hasText, isTrue);
    },
  );

  test('a provider override replaces the reader with a fake', () async {
    _native((_) => throw StateError('the channel must not be used'));
    final fake = FakePasteboardReader(
      PasteboardContents(files: List.of(['/vaults/My Vault/x.pdf'])),
    );
    final container = ProviderContainer(
      overrides: [pasteboardReaderProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    final c = await container.read(pasteboardReaderProvider).read();

    expect(c.files, ['/vaults/My Vault/x.pdf']);
    expect(fake.reads, 1);
    expect(_received, isEmpty);
  });

  test('PasteboardContents built from run-time values keeps every field', () {
    final files = List.of(['/vaults/My Vault/a.pdf', '/vaults/My Vault/b.pdf']);
    final png = fakePngBytes(3);

    final c = PasteboardContents(files: files, png: png, hasText: true);

    expect(c.files, files);
    expect(c.png, png);
    expect(c.hasText, isTrue);
  });

  test('PasteboardContents defaults to nothing', () {
    _expectEmpty(const PasteboardContents(), asked: false);
  });
}
