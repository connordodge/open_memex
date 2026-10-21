// WI #91 (D18): `KeychainTokenStore` keeps each vault server's access token
// in the legacy macOS file keychain through `flutter_secure_storage`, keyed
// only by the saved-server id. These tests run against the real plugin's
// Dart side with its native channel mocked; nothing reaches the Keychain.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/token_store.dart';

import '../support/token_store_fakes.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// One native call the plugin sent: method, item key and options map.
typedef _Call = ({String method, String? key, Map<String, String> options});

/// Installs an in-memory native side for the plugin's method channel and
/// returns the call log.
List<_Call> _mockKeychain(Map<String, String> items) {
  final calls = <_Call>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final args = (call.arguments as Map).cast<String, Object?>();
        final key = args['key'] as String?;
        final options = (args['options'] as Map? ?? const {})
            .cast<String, String>();
        calls.add((method: call.method, key: key, options: options));
        switch (call.method) {
          case 'write':
            items[key!] = args['value']! as String;
            return null;
          case 'read':
            return items[key];
          case 'delete':
            items.remove(key);
            return null;
          case 'containsKey':
            return items.containsKey(key);
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The plugin picks its options by target platform; the app is macOS-only.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // These run first: they need the plugin's default method-channel platform,
  // which FlutterSecureStorage.setMockInitialValues (last group) replaces.
  group('KeychainTokenStore over the plugin channel (AC9)', () {
    test(
      'KeychainTokenStore reads writes and deletes under a key derived only from the server id',
      () async {
        final items = <String, String>{};
        final calls = _mockKeychain(items);
        const store = KeychainTokenStore();

        await store.write('srv-91-one', 'tok-chan-0001');
        expect(await store.read('srv-91-one'), 'tok-chan-0001');
        await store.delete('srv-91-one');
        expect(await store.read('srv-91-one'), isNull);
        expect(items, isEmpty);

        expect(calls.map((c) => c.method), ['write', 'read', 'delete', 'read']);
        final key = calls.first.key!;
        expect(calls.map((c) => c.key).toSet(), {key});
        expect(key, isNot(contains('tok-chan-0001')));

        // Same id, another token and another store instance: same key.
        calls.clear();
        await store.write('srv-91-one', 'tok-chan-0002');
        await const KeychainTokenStore().write('srv-91-one', 'tok-chan-0003');
        expect(calls.map((c) => c.key).toSet(), {key});
        expect(items, {key: 'tok-chan-0003'});

        // Another id: another key.
        calls.clear();
        await store.write('srv-91-two', 'tok-chan-0003');
        expect(calls.single.key, isNot(key));
        expect(items, hasLength(2));
        expect(await store.read('srv-91-one'), 'tok-chan-0003');
        expect(await store.read('srv-91-two'), 'tok-chan-0003');
      },
    );

    test(
      'KeychainTokenStore passes MacOsOptions with the legacy file keychain on every call',
      () async {
        final calls = _mockKeychain({});
        const store = KeychainTokenStore();

        await store.write('srv-91-opts', 'tok-opts-0001');
        await store.read('srv-91-opts');
        await store.delete('srv-91-opts');

        expect(calls, hasLength(3));
        for (final c in calls) {
          expect(
            c.options['usesDataProtectionKeychain'],
            'false',
            reason: '${c.method} must use the legacy file keychain',
          );
        }
      },
    );

    test(
      'KeychainTokenStore reads null for a server with no access token',
      () async {
        _mockKeychain({'unrelated-item': 'tok-other-0001'});
        const store = KeychainTokenStore();

        expect(await store.read('srv-91-missing'), isNull);
        // Deleting a missing token is a no-op, not an error.
        await store.delete('srv-91-missing');
      },
    );
  });

  group('tokenStoreProvider and the fake', () {
    test('tokenStoreProvider defaults to the Keychain token store', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(tokenStoreProvider), isA<KeychainTokenStore>());
    });

    test(
      'a tokenStoreProvider override with FakeTokenStore is seen by readers',
      () async {
        final fake = FakeTokenStore({'srv-91-fake': 'tok-fake-0001'});
        final c = ProviderContainer(
          overrides: [tokenStoreProvider.overrideWithValue(fake)],
        );
        addTearDown(c.dispose);

        final store = c.read(tokenStoreProvider);
        expect(await store.read('srv-91-fake'), 'tok-fake-0001');
        await store.write('srv-91-fake', 'tok-fake-0002');
        expect(await store.read('srv-91-fake'), 'tok-fake-0002');
        await store.delete('srv-91-fake');
        expect(await store.read('srv-91-fake'), isNull);
        expect(fake.calls, [
          'read srv-91-fake',
          'write srv-91-fake',
          'read srv-91-fake',
          'delete srv-91-fake',
          'read srv-91-fake',
        ]);
      },
    );
  });

  // Last: setMockInitialValues swaps the plugin platform for the rest of
  // this file.
  group('KeychainTokenStore on the plugin mock store (AC9)', () {
    test(
      'KeychainTokenStore round trips an access token through the plugin mock store',
      () async {
        final values = <String, String>{};
        FlutterSecureStorage.setMockInitialValues(values);
        const store = KeychainTokenStore();

        await store.write('srv-91-mock', 'tok-mock-0001');
        expect(values, hasLength(1));
        final key = values.keys.single;
          expect(key, isNot(contains('tok-mock-0001')));
        expect(values[key], 'tok-mock-0001');
        expect(await store.read('srv-91-mock'), 'tok-mock-0001');

        await store.delete('srv-91-mock');
        expect(values, isEmpty);
        expect(await store.read('srv-91-mock'), isNull);
      },
    );
  });
}
