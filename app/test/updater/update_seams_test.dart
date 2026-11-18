// WI #32 (Spec #31 req 10, 11, 21, TD6, D6, D7, D9): the updater seams
// implemented in full in update_seams.dart and sparkle_ed_public_key.dart.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/sparkle_ed_public_key.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _source(String file) => File('lib/src/updater/$file').readAsStringSync();

void main() {
  test(
    'updatesEnabledFor is true only for release mode with FLUTTER_TEST unset',
    () {
      expect(updatesEnabledFor(true, const {}), isTrue);
      expect(updatesEnabledFor(true, const {'HOME': '/vaults'}), isTrue);
      expect(updatesEnabledFor(true, const {'FLUTTER_TEST': 'true'}), isFalse);
      expect(updatesEnabledFor(true, const {'FLUTTER_TEST': ''}), isFalse);
      expect(updatesEnabledFor(true, const {'FLUTTER_TEST': 'false'}), isFalse);
      expect(updatesEnabledFor(false, const {}), isFalse);
      expect(updatesEnabledFor(false, const {'FLUTTER_TEST': 'true'}), isFalse);
    },
  );

  test(
    'the production updatesEnabledProvider passes kReleaseMode and Platform.environment',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(updatesEnabledProvider),
        updatesEnabledFor(kReleaseMode, Platform.environment),
      );
      // Under flutter test the seam is off (FLUTTER_TEST is set, and
      // kReleaseMode is false).
      expect(container.read(updatesEnabledProvider), isFalse);
      // kReleaseMode is a compile-time constant that is false in every test,
      // so the wiring itself is pinned on the source.
      expect(
        _source('update_seams.dart'),
        matches(
          RegExp(
            r'updatesEnabledProvider\s*=\s*Provider<bool>\(\s*\(\w*\)\s*=>\s*'
            r'updatesEnabledFor\(\s*kReleaseMode\s*,\s*Platform\.environment'
            r'\s*,?\s*\)',
          ),
        ),
      );
    },
  );

  test(
    'the LastCheckStore reads null when never stamped and round-trips a stamped time as integer milliseconds',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final store = container.read(lastCheckStoreProvider);
      expect(store, isA<SharedPrefsLastCheckStore>());
      expect(lastCheckKey, 'self_update.last_check');

      expect(await store.read(), isNull);

      final stamped = DateTime.utc(2026, 11, 17, 8, 30, 15, 250);
      await store.write(stamped);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('self_update.last_check'), 1794904215250);
      expect(
        prefs.getInt('self_update.last_check'),
        stamped.millisecondsSinceEpoch,
      );
      expect((await store.read())?.millisecondsSinceEpoch, 1794904215250);
    },
  );

  test('the LastCheckStore reads a time another run stamped', () async {
    final local = DateTime(2026, 3, 29, 1, 30); // a DST-change night
    SharedPreferences.setMockInitialValues({
      'self_update.last_check': local.millisecondsSinceEpoch,
    });

    final read = await const SharedPrefsLastCheckStore().read();

    expect(read, isNotNull);
    expect(read!.millisecondsSinceEpoch, local.millisecondsSinceEpoch);
    expect(read.isAtSameMomentAs(local), isTrue);
  });

  test('a later stamp replaces the earlier one', () async {
    SharedPreferences.setMockInitialValues({});
    const store = SharedPrefsLastCheckStore();

    await store.write(DateTime.fromMillisecondsSinceEpoch(1000));
    await store.write(DateTime.fromMillisecondsSinceEpoch(2000));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('self_update.last_check'), 2000);
    expect((await store.read())?.millisecondsSinceEpoch, 2000);
  });

  test('currentPidProvider is this process pid', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(currentPidProvider), pid);
    expect(container.read(currentPidProvider), isPositive);
  });

  test(
    'sparkleEdPublicKey defaults to the committed empty string when no key is defined',
    () {
      final source = _source('sparkle_ed_public_key.dart');
      expect(
        source,
        matches(
          RegExp(
            r'const\s+(String\s+)?sparkleEdPublicKey\s*=\s*String\.fromEnvironment\(\s*'
            r"'SPARKLE_ED_PUBLIC_KEY'\s*,\s*defaultValue:\s*_committed\s*,?\s*\)",
          ),
        ),
      );
      final committed = RegExp(
        r"const\s+(String\s+)?_committed\s*=\s*'([^']*)'",
      ).firstMatch(source);
      expect(committed, isNotNull, reason: 'a committed key constant');

      // flutter test defines no SPARKLE_ED_PUBLIC_KEY.
      expect(const bool.hasEnvironment('SPARKLE_ED_PUBLIC_KEY'), isFalse);
      expect(sparkleEdPublicKey, committed!.group(2));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(sparkleEdPublicKeyProvider), sparkleEdPublicKey);
    },
  );

  test('appBuildNumberProvider is empty until main overrides it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appBuildNumberProvider), '');
  });
}
