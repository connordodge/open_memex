// WI #374 (Spec #367 Req 15-17, TD 2 and 7): the app version provider and
// the wiring around it. The provider defaults to an empty string and never
// throws; `main()` reads `PackageInfo.fromPlatform().version` (never the
// build number) into it; `package_info_plus` is a dependency with both
// lockfiles committed; no hard-coded version label is left under lib/.
// `flutter test` runs with the package root (`app/`) as cwd.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_version.dart';

/// The body of `main()` in lib/main.dart.
String _mainBody() {
  final source = File('lib/main.dart').readAsStringSync();
  final start = source.indexOf('Future<void> main() async {');
  expect(start, isNonNegative, reason: 'main() not found');
  final end = source.indexOf('\n}\n', start);
  return source.substring(start, end);
}

void main() {
  group('provider', () {
    test(
      'appVersionProvider is empty and does not throw when not overridden',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(container.read(appVersionProvider), '');
      },
    );

    test('appVersionProvider holds the version it is overridden with', () {
      // Built at run time so the override is a real value, not a const.
      final version = ['0', '2', '0'].join('.');
      final container = ProviderContainer(
        overrides: [appVersionProvider.overrideWithValue(version)],
      );
      addTearDown(container.dispose);

      expect(container.read(appVersionProvider), '0.2.0');
    });
  });

  group('main', () {
    test(
      'main reads PackageInfo fromPlatform version into appVersionProvider before runApp',
      () {
        final body = _mainBody();
        final read = body.indexOf('PackageInfo.fromPlatform()');
        final override = body.indexOf('appVersionProvider.overrideWithValue(');
        final run = body.indexOf('runApp(');

        expect(run, isNonNegative, reason: 'runApp not found in main()');
        expect(read, isNonNegative, reason: 'main() never reads PackageInfo');
        expect(
          override,
          isNonNegative,
          reason: 'main() never overrides appVersionProvider',
        );
        expect(read, lessThan(run));
        expect(override, greaterThan(read));
        expect(
          RegExp(r'\.version\b').hasMatch(body),
          isTrue,
          reason: 'main() reads info.version',
        );
      },
    );

    test('main never reads the build number into the version', () {
      final body = _mainBody();

      expect(body, contains('PackageInfo.fromPlatform()'));
      expect(body, isNot(contains('buildNumber')));
    });

    test('main keeps configureFonts ahead of the version override', () {
      final body = _mainBody();

      expect(body, contains('configureFonts();'));
      expect(
        body.indexOf('configureFonts();'),
        lessThan(body.indexOf('appVersionProvider.overrideWithValue(')),
      );
    });
  });

  group('dependency', () {
    test('pubspec yaml lists package_info_plus as a dependency', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(
        RegExp(r'^  package_info_plus:', multiLine: true).hasMatch(pubspec),
        isTrue,
      );
    });

    test('pubspec lock locks package_info_plus', () {
      final lock = File('pubspec.lock').readAsStringSync();

      expect(
        RegExp(r'^  package_info_plus:', multiLine: true).hasMatch(lock),
        isTrue,
      );
    });
  });

  group('hygiene', () {
    test('no hard-coded v0.4 version label is left under lib', () {
      final offenders = <String>[
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              f.readAsStringSync().contains("'v0.4'"))
            f.path,
      ];

      expect(offenders, isEmpty);
    });
  });
}
