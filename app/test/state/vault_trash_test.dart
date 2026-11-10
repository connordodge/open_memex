// WI #348 (Spec #347, TD1-TD3): the Trash seam. `PlatformVaultTrash` sends
// `trashItem` on `open_memex/files` and maps the native reply to a
// `TrashResult`. The Swift side is a thin pass-through (MANUAL); every
// mapping row is pinned here over a mock channel.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';

const _path = '/Users/test/My Vaults/alpha @home~1';
const _cocoa = 'NSCocoaErrorDomain';

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

/// A native side that fails with `trash_failed`.
void _nativeFails({
  required String domain,
  required int code,
  String message = 'native text',
}) => _native(
  (_) => throw PlatformException(
    code: 'trash_failed',
    message: message,
    details: {'domain': domain, 'code': code},
  ),
);

/// A native side that fails with the given raw error.
void _nativeThrows(PlatformException e) => _native((_) => throw e);

Future<TrashResult> _trash() => const PlatformVaultTrash().trash(_path);

Matcher _failedWith(String message) =>
    isA<TrashFailed>().having((f) => f.message, 'message', message);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_received.clear);
  tearDown(() => _messenger.setMockMethodCallHandler(vaultFilesChannel, null));

  group('PlatformVaultTrash call', () {
    test(
      'trash invokes trashItem on open_memex/files with the path string',
      () async {
        _native((_) => null);
        await _trash();
        expect(vaultFilesChannel.name, 'open_memex/files');
        expect(_received, hasLength(1));
        expect(_received.single.$1, 'trashItem');
        expect(_received.single.$2, isA<String>());
        expect(_received.single.$2, _path);
      },
    );

    test('vaultTrashProvider hands out the platform trash', () async {
      _native((_) => null);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container.read(vaultTrashProvider).trash(_path);
      expect(result, isA<Trashed>());
      expect(_received.single.$1, 'trashItem');
      expect(_received.single.$2, _path);
    });
  });

  group('PlatformVaultTrash reply mapping', () {
    test('a null reply maps to Trashed', () async {
      _native((_) => null);
      expect(await _trash(), isA<Trashed>());
    });

    test('trash_failed NSCocoaErrorDomain 3328 maps to TrashNoTrash', () async {
      _nativeFails(domain: _cocoa, code: 3328);
      expect(await _trash(), isA<TrashNoTrash>());
    });

    test(
      'trash_failed NSCocoaErrorDomain 257 maps to TrashPermission',
      () async {
        _nativeFails(domain: _cocoa, code: 257);
        expect(await _trash(), isA<TrashPermission>());
      },
    );

    test(
      'trash_failed NSCocoaErrorDomain 513 maps to TrashPermission',
      () async {
        _nativeFails(domain: _cocoa, code: 513);
        expect(await _trash(), isA<TrashPermission>());
      },
    );

    test('trash_failed NSCocoaErrorDomain 4 maps to TrashNotFound', () async {
      _nativeFails(domain: _cocoa, code: 4);
      expect(await _trash(), isA<TrashNotFound>());
    });

    test('trash_failed NSCocoaErrorDomain 260 maps to TrashNotFound', () async {
      _nativeFails(domain: _cocoa, code: 260);
      expect(await _trash(), isA<TrashNotFound>());
    });

    test(
      'an unlisted NSCocoaErrorDomain code maps to TrashFailed with the reply message',
      () async {
        _nativeFails(domain: _cocoa, code: 999, message: 'disk on fire');
        expect(await _trash(), _failedWith('disk on fire'));
      },
    );

    test(
      'codes next to the listed ones map to TrashFailed, not a named result',
      () async {
        for (final code in [
          0,
          3,
          5,
          256,
          258,
          259,
          261,
          512,
          514,
          3327,
          3329,
        ]) {
          _nativeFails(domain: _cocoa, code: code, message: 'm$code');
          expect(await _trash(), _failedWith('m$code'), reason: 'code $code');
        }
      },
    );

    test('a listed code in another error domain maps to TrashFailed', () async {
      for (final code in [3328, 257, 513, 4, 260]) {
        _nativeFails(
          domain: 'NSPOSIXErrorDomain',
          code: code,
          message: 'posix $code',
        );
        expect(
          await _trash(),
          _failedWith('posix $code'),
          reason: 'code $code',
        );
      }
    });

    test(
      'a PlatformException code other than trash_failed maps to TrashFailed even with listed details',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'something_else',
            message: 'other text',
            details: {'domain': _cocoa, 'code': 3328},
          ),
        );
        expect(await _trash(), _failedWith('other text'));
      },
    );

    test('bad_arguments maps to TrashFailed with the reply message', () async {
      _nativeThrows(
        PlatformException(code: 'bad_arguments', message: 'path must be text'),
      );
      expect(await _trash(), _failedWith('path must be text'));
    });

    test('trash_failed with no details maps to TrashFailed', () async {
      _nativeThrows(PlatformException(code: 'trash_failed', message: 'no det'));
      expect(await _trash(), _failedWith('no det'));
    });

    test(
      'trash_failed with details that are not a map maps to TrashFailed',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            message: 'text details',
            details: 'NSCocoaErrorDomain 3328',
          ),
        );
        expect(await _trash(), _failedWith('text details'));
      },
    );

    test(
      'trash_failed with details missing the code maps to TrashFailed',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            message: 'no code',
            details: {'domain': _cocoa},
          ),
        );
        expect(await _trash(), _failedWith('no code'));
      },
    );

    test(
      'trash_failed with details missing the domain maps to TrashFailed',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            message: 'no domain',
            details: {'code': 3328},
          ),
        );
        expect(await _trash(), _failedWith('no domain'));
      },
    );

    test(
      'trash_failed with a code that is not an int maps to TrashFailed',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            message: 'text code',
            details: {'domain': _cocoa, 'code': '3328'},
          ),
        );
        expect(await _trash(), _failedWith('text code'));
      },
    );

    test(
      'trash_failed with a domain that is not text maps to TrashFailed',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            message: 'odd domain',
            details: {'domain': 1, 'code': 3328},
          ),
        );
        expect(await _trash(), _failedWith('odd domain'));
      },
    );

    test(
      'a failure with no message maps to TrashFailed with some text',
      () async {
        _nativeThrows(PlatformException(code: 'bad_arguments'));
        final result = await _trash();
        expect(result, isA<TrashFailed>());
        expect((result as TrashFailed).message, isNotEmpty);
      },
    );

    test(
      'a failure with no message and unlisted details maps to TrashFailed with some text',
      () async {
        _nativeThrows(
          PlatformException(
            code: 'trash_failed',
            details: {'domain': _cocoa, 'code': 999},
          ),
        );
        final result = await _trash();
        expect(result, isA<TrashFailed>());
        expect((result as TrashFailed).message, isNotEmpty);
      },
    );

    test(
      'a MissingPluginException maps to TrashFailed with the exception text',
      () async {
        // No native handler installed.
        _messenger.setMockMethodCallHandler(vaultFilesChannel, null);
        final result = await _trash();
        expect(result, isA<TrashFailed>());
        expect(
          (result as TrashFailed).message,
          contains('No implementation found for method trashItem'),
        );
      },
    );
  });
}
