// WI #69 (D12): `package:http` and `flutter_secure_storage` are direct
// dependencies of the app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Package names declared directly under the top-level `dependencies:` key
/// of `pubspec.yaml` (two-space indented entries until the next top-level
/// key).
Set<String> _directDependencies(String pubspec) {
  final names = <String>{};
  var inDeps = false;
  for (final line in pubspec.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final topLevel = !line.startsWith(' ');
    if (topLevel) {
      inDeps = line.trimRight() == 'dependencies:';
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
    if (m != null) names.add(m.group(1)!);
  }
  return names;
}

void main() {
  test(
    'app pubspec lists http and flutter_secure_storage under dependencies',
    () {
      // `flutter test` runs with the package root (`app/`) as cwd.
      final deps = _directDependencies(File('pubspec.yaml').readAsStringSync());
      // Control: the parser reads the block at all.
      expect(deps, containsAll(<String>['flutter_riverpod', 'sqlite3']));
      expect(deps, contains('http'));
      expect(deps, contains('flutter_secure_storage'));
    },
  );

  test(
    'pubspec lock records http and flutter_secure_storage as direct main',
    () {
      final lock = File('pubspec.lock').readAsStringSync();
      String? kindOf(String package) => RegExp(
        '^  ${RegExp.escape(package)}:\n    dependency: "?([^"\n]+)"?',
        multiLine: true,
      ).firstMatch(lock)?.group(1);
      // Control: an existing direct dependency.
      expect(kindOf('sqlite3'), 'direct main');
      expect(kindOf('http'), 'direct main');
      expect(kindOf('flutter_secure_storage'), 'direct main');
    },
  );

  test('the dependency parser ignores dev_dependencies', () {
    const sample = '''
name: x
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
dev_dependencies:
  flutter_secure_storage: ^9.0.0
''';
    expect(_directDependencies(sample), {'flutter', 'http'});
  });
}
