// WI #32 (Spec #31 TD2, D19): the updater's `cryptography` and `xml`
// dependencies are direct dependencies of the app, recorded in the lockfile.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Package names declared directly under the top-level `dependencies:` key
/// of a pubspec.
Set<String> _wi32DirectDependencies(String pubspec) {
  final names = <String>{};
  var inDeps = false;
  for (final line in pubspec.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) {
      inDeps = line.trimRight() == 'dependencies:';
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
    if (m != null) names.add(m.group(1)!);
  }
  return names;
}

String? _wi32LockKind(String lock, String package) => RegExp(
  '^  ${RegExp.escape(package)}:\n    dependency: "?([^"\n]+)"?',
  multiLine: true,
).firstMatch(lock)?.group(1);

void main() {
  test('the app depends directly on cryptography and xml', () {
    final deps = _wi32DirectDependencies(
      File('pubspec.yaml').readAsStringSync(),
    );
    // Control: the parser reads the block at all.
    expect(deps, containsAll(<String>['flutter_riverpod', 'http']));
    expect(deps, containsAll(<String>['cryptography', 'xml']));

    final lock = File('pubspec.lock').readAsStringSync();
    expect(_wi32LockKind(lock, 'http'), 'direct main');
    expect(_wi32LockKind(lock, 'cryptography'), 'direct main');
    expect(_wi32LockKind(lock, 'xml'), 'direct main');
  });
}
