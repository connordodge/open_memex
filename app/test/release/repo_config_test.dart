// WI #371 (Spec #367, requirements 1-6, 19, 28): static checks of the public
// repo files, the macOS 14 arm64 build settings and the tracked lockfiles.
//
// `flutter test` runs with `app/` as the working directory; the repo root is
// its parent. The tests read files and ask git which paths are tracked; they
// never run a build and never run a memex binary.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final Directory _root = Directory.current.parent;

File _file(String relative) => File('${_root.path}/$relative');

String _read(String relative) {
  final f = _file(relative);
  expect(f.existsSync(), isTrue, reason: '$relative exists at the repo root');
  return f.readAsStringSync();
}

/// Lowercased text with runs of whitespace collapsed, so a phrase wrapped
/// across lines still matches.
String _flat(String text) => text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

Future<bool> _tracked(String relative) async {
  final r = await Process.run('git', [
    'ls-files',
    '--error-unmatch',
    relative,
  ], workingDirectory: _root.path);
  return r.exitCode == 0;
}

/// The lines of `.gitignore` that are real patterns (no comments or blanks),
/// without a leading slash.
List<String> _ignorePatterns() => _read('.gitignore')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .map((l) => l.replaceAll(RegExp(r'^/'), ''))
    .toList();

/// The text of one `XCBuildConfiguration` block in `project.pbxproj`.
String _pbxConfigBlock(String pbx, String id) {
  final start = RegExp('\n\t\t$id /\\* [A-Za-z ]+ \\*/ = \\{').firstMatch(pbx);
  expect(start, isNotNull, reason: 'configuration $id exists in the project');
  final end = pbx.indexOf('\n\t\t};', start!.end);
  expect(end, greaterThan(start.end), reason: 'configuration $id is closed');
  return pbx.substring(start.start, end);
}

/// The configuration ids of the build configuration list named [listName].
List<String> _pbxListIds(String pbx, String listName) {
  final list = RegExp(
    '/\\* Build configuration list for $listName \\*/ = \\{'
    '[^}]*?buildConfigurations = \\(([^)]*)\\);',
    dotAll: true,
  ).firstMatch(pbx);
  expect(list, isNotNull, reason: 'a configuration list for $listName');
  return RegExp(
    r'([0-9A-F]{24}) /\*',
  ).allMatches(list!.group(1)!).map((m) => m.group(1)!).toList();
}

/// Home-directory names that read as obvious placeholders in a doc.
const _placeholderUsers = <String>{
  'you',
  'YOU',
  'YOUR_USERNAME',
  'test',
  'tester',
  'person',
  'me',
};

/// Every `/Users/<name>/` path in [text] whose name is not a placeholder.
List<String> _realHomePaths(String text) => RegExp(r'/Users/([A-Za-z0-9._-]+)/')
    .allMatches(text)
    .where((m) => !_placeholderUsers.contains(m.group(1)))
    .map((m) => m.group(0)!)
    .toList();

void main() {
  group('repo root control', () {
    test('the repo root holds Cargo.toml and the app directory', () {
      expect(_file('Cargo.toml').existsSync(), isTrue);
      expect(_file('app/pubspec.yaml').existsSync(), isTrue);
    });
  });

  group('licence and copyright', () {
    test('LICENSE holds the MIT text with the Connor Dodge LLC copyright', () {
      final text = _read('LICENSE');
      expect(text, contains('MIT License'));
      expect(text, contains('Copyright (c) 2026 Connor Dodge LLC'));
      final flat = _flat(text);
      expect(
        flat,
        contains('permission is hereby granted, free of charge, to any person'),
      );
      expect(flat, contains('the above copyright notice and this permission'));
      expect(flat, contains('the software is provided "as is", without'));
    });

    test('AppInfo xcconfig sets the product copyright to Connor Dodge LLC', () {
      final lines = _read(
        'app/macos/Runner/Configs/AppInfo.xcconfig',
      ).split('\n').map((l) => l.trim());
      expect(
        lines,
        contains(
          'PRODUCT_COPYRIGHT = Copyright \u00a9 2026 Connor Dodge LLC. '
          'MIT License.',
        ),
      );
    });

    test(
      'Cargo workspace authors is Connor Dodge LLC and Cargo has no at sign',
      () {
        final cargo = _read('Cargo.toml');
        final workspacePackage = RegExp(
          r'\[workspace\.package\]([^\[]*)',
        ).firstMatch(cargo);
        expect(workspacePackage, isNotNull);
        final section = workspacePackage!.group(1)!;
        expect(section, contains('authors = ["Connor Dodge LLC"]'));
        expect(section, contains('license = "MIT"'));
        expect(cargo, isNot(contains('@')));
      },
    );
  });

  group('contributor and security docs', () {
    test(
      'CONTRIBUTING names build and test commands and the git-filter-repo prerequisite',
      () {
        final text = _read('CONTRIBUTING.md');
        expect(text, contains('cargo build'));
        expect(text, contains('flutter run -d macos'));
        expect(text, contains('cargo test --workspace'));
        expect(text, contains('flutter test'));
        expect(text, contains('git-filter-repo'));
        expect(text, contains('brew install git-filter-repo'));
      },
    );

    test('CONTRIBUTING asks for an issue before a large PR', () {
      final flat = _flat(_read('CONTRIBUTING.md'));
      expect(
        flat,
        matches(
          RegExp(r'issue[^.]*before[^.]*large|before[^.]*large[^.]*(pr|pull)'),
        ),
      );
    });

    test('CONTRIBUTING states MIT inbound equals outbound with no CLA', () {
      final flat = _flat(_read('CONTRIBUTING.md'));
      expect(flat, contains('mit inbound = outbound'));
      expect(flat, contains('no cla'));
    });

    test(
      'CONTRIBUTING says the maintainer reads every outside PR before running anything',
      () {
        final flat = _flat(_read('CONTRIBUTING.md'));
        expect(flat, contains('maintainer reads'));
        expect(flat, contains('before running'));
      },
    );

    test('there is no code of conduct file', () {
      expect(_file('CODE_OF_CONDUCT.md').existsSync(), isFalse);
    });

    test('SECURITY points to GitHub private vulnerability reporting', () {
      final text = _read('SECURITY.md');
      final flat = _flat(text);
      expect(flat, contains('private vulnerability reporting'));
      expect(text, contains('Report a vulnerability'));
      expect(flat, contains('security tab'));
    });

    test('SECURITY asks reporters not to open a public issue', () {
      final flat = _flat(_read('SECURITY.md'));
      expect(
        flat,
        matches(
          RegExp(r'(do not|don.t|not) (open|file|use|report)[^.]*public issue'),
        ),
      );
    });
  });

  group('issue templates', () {
    test(
      'bug report template asks for macOS version Open Memex version steps expected and actual',
      () {
        final text = _read('.github/ISSUE_TEMPLATE/bug_report.yml');
        expect(text, matches(RegExp(r'^name:\s*\S', multiLine: true)));
        expect(text, contains('body:'));
        expect(text, contains('type: textarea'));
        final flat = _flat(text);
        expect(flat, contains('macos version'));
        expect(flat, contains('open memex version'));
        expect(flat, matches(RegExp(r'(picker|about)')));
        expect(flat, contains('steps'));
        expect(flat, contains('expected'));
        expect(flat, contains('actual'));
      },
    );

    test(
      'feature request template asks for the problem and the proposed behaviour',
      () {
        final text = _read('.github/ISSUE_TEMPLATE/feature_request.yml');
        expect(text, matches(RegExp(r'^name:\s*\S', multiLine: true)));
        expect(text, contains('body:'));
        expect(text, contains('type: textarea'));
        final flat = _flat(text);
        expect(flat, contains('problem'));
        expect(flat, matches(RegExp('proposed behaviou?r')));
      },
    );
  });

  group('gitignore and lockfiles', () {
    test('gitignore lists the five dev paths', () {
      final patterns = _ignorePatterns().map(
        (p) => p.replaceAll(RegExp(r'/$'), ''),
      );
      for (final path in <String>[
        '.claude/orchestration',
        '.act',
        'CLAUDE.md',
        'AGENTS.md',
        'ai_specs',
      ]) {
        expect(patterns, contains(path), reason: '.gitignore lists $path');
      }
    });

    test(
      'gitignore no longer ignores the two lockfiles but still ignores the generated plugin registrant',
      () {
        final patterns = _ignorePatterns();
        expect(patterns, isNot(contains('app/pubspec.lock')));
        expect(patterns, isNot(contains('app/macos/Podfile.lock')));
        expect(patterns, isNot(contains('pubspec.lock')));
        expect(patterns, isNot(contains('Podfile.lock')));
        expect(patterns, isNot(contains('*.lock')));
        expect(
          patterns,
          contains('app/macos/Flutter/GeneratedPluginRegistrant.swift'),
        );
      },
    );

    test(
      'the pubspec lock and the Podfile lock are tracked and non-empty',
      () async {
        for (final path in <String>[
          'app/pubspec.lock',
          'app/macos/Podfile.lock',
        ]) {
          expect(
            await _tracked(path),
            isTrue,
            reason: '$path is tracked by git',
          );
        }
        expect(_read('app/pubspec.lock'), contains('packages:'));
        final pods = _read('app/macos/Podfile.lock');
        expect(pods, contains('PODFILE CHECKSUM'));
        expect(pods, contains('COCOAPODS:'));
      },
    );

    test('app pubspec lists yaml under dev_dependencies', () {
      var inDev = false;
      final dev = <String>{};
      for (final line in _read('app/pubspec.yaml').split('\n')) {
        if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
        if (!line.startsWith(' ')) {
          inDev = line.trimRight() == 'dev_dependencies:';
          continue;
        }
        final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
        if (inDev && m != null) dev.add(m.group(1)!);
      }
      // Control: the parser reads the block at all.
      expect(dev, contains('flutter_test'));
      expect(dev, contains('yaml'));
    });
  });

  group('macOS 14 arm64 build settings', () {
    test('every MACOSX_DEPLOYMENT_TARGET in the Xcode project is 14.0', () {
      final pbx = _read('app/macos/Runner.xcodeproj/project.pbxproj');
      final targets = RegExp(
        r'MACOSX_DEPLOYMENT_TARGET = ([^;]+);',
      ).allMatches(pbx).map((m) => m.group(1)!.trim()).toList();
      // Control: the project-level Debug, Release and Profile all set it.
      expect(targets.length, greaterThanOrEqualTo(3));
      expect(targets.toSet(), <String>{'14.0'});
    });

    test('the Podfile platform is osx 14.0', () {
      final podfile = _read('app/macos/Podfile');
      expect(podfile, contains("platform :osx, '14.0'"));
      expect(podfile, isNot(contains("platform :osx, '10.15'")));
    });

    test(
      'the Podfile post_install sets 14.0 and excludes x86_64 on every pod target configuration',
      () {
        final podfile = _read('app/macos/Podfile');
        final start = podfile.indexOf('post_install do |installer|');
        expect(start, isNonNegative, reason: 'the Podfile has a post_install');
        final block = podfile.substring(start);
        expect(block, contains('installer.pods_project.targets.each'));
        expect(block, contains('build_configurations.each'));
        expect(
          block,
          matches(RegExp(r"MACOSX_DEPLOYMENT_TARGET'\]\s*=\s*'14\.0'")),
        );
        expect(block, matches(RegExp(r"EXCLUDED_ARCHS'\]\s*=\s*'x86_64'")));
        // The settings come after Flutter's own helper so they win.
        final flutterCall = block.indexOf(
          'flutter_additional_macos_build_settings(target)',
        );
        expect(flutterCall, isNonNegative);
        expect(block.indexOf('EXCLUDED_ARCHS'), greaterThan(flutterCall));
        expect(
          block.indexOf('MACOSX_DEPLOYMENT_TARGET'),
          greaterThan(flutterCall),
        );
      },
    );

    test(
      'the Runner target Debug Release and Profile configurations exclude x86_64',
      () {
        final pbx = _read('app/macos/Runner.xcodeproj/project.pbxproj');
        final ids = _pbxListIds(pbx, 'PBXNativeTarget "Runner"');
        expect(ids, hasLength(3));
        for (final id in ids) {
          final block = _pbxConfigBlock(pbx, id);
          expect(
            block,
            matches(RegExp(r'EXCLUDED_ARCHS = "?x86_64"?;')),
            reason: 'Runner configuration $id excludes x86_64',
          );
        }
      },
    );

    test('the Xcode project keeps ad hoc signing', () {
      final pbx = _read('app/macos/Runner.xcodeproj/project.pbxproj');
      expect(
        RegExp(r'CODE_SIGN_IDENTITY = "-";').allMatches(pbx).length,
        greaterThanOrEqualTo(3),
      );
    });
  });

  group('no personal data in tracked docs', () {
    test(
      'the docs test source and the acceptance doc name no real home path',
      () {
        expect(
          _realHomePaths(_read('crates/memex-mcp/tests/docs_readme.rs')),
          isEmpty,
          reason: 'docs_readme.rs must not spell a real username',
        );
        expect(_realHomePaths(_read('docs/daily-acceptance.md')), isEmpty);
      },
    );

    test('the home path scan flags a real name and allows placeholders', () {
      expect(_realHomePaths('/Users/alice/memex/x'), <String>['/Users/alice/']);
      for (final name in _placeholderUsers) {
        expect(_realHomePaths('/Users/$name/vault'), isEmpty);
      }
      expect(_realHomePaths('~/memex and /usr/local'), isEmpty);
    });
  });
}
