// Tests for scripts/release/check-version.sh (#376, Spec #367 requirement
// 24).
//
// `check-version.sh <tag>` reads `app/pubspec.yaml`, `Cargo.toml` and
// `release-notes/v<x.y.z>.md` relative to the CURRENT DIRECTORY (the repo
// root when the release workflow calls it), never relative to the script's
// own location. Every test runs the real script with its working directory
// set to a temp fixture root, so the checkout's own versions and notes never
// count.
//
// The contract these tests pin:
//   exit 0  every condition holds;
//   exit 1  one output line per failed condition, and nothing else, where
//           the line names the failure:
//             tag      the tag as given and the word `tag`
//             pubspec  `app/pubspec.yaml` and the version it found
//             Cargo    `Cargo.toml` and the version it found
//             notes    `release-notes/v<x.y.z>.md`
//             section  the heading (`## Highlights`, `## Upgrade`,
//                      `## Requirements`) and `missing` or `empty`, and
//                      not the Upgrade phrase `No vault changes`
//             Upgrade  `No vault changes` and `schema V`
//           A missing or empty `## Upgrade` section also fails the Upgrade
//           phrase condition, so it may print both lines.
//
// Fixtures hold placeholder text only.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _script = 'scripts/release/check-version.sh';

const _highlights = '## Highlights';
const _upgrade = '## Upgrade';
const _requirements = '## Requirements';

const _noVaultChanges =
    'No vault changes. Vaults made by earlier builds at schema V6 open as '
    'they are.';
const _migratesV7 =
    'This release migrates vaults to schema V7 the first time it opens '
    'them. Back up first.';

/// A pubspec shaped like the real one: the top-level `version:` plus
/// dependency constraints and a hosted dependency with its own nested
/// `version:` key, which the script must not read.
String _pubspec(String version) => [
  'name: open_memex_app',
  'description: "Fixture app."',
  "publish_to: 'none'",
  'version: $version',
  '',
  'environment:',
  '  sdk: ^3.10.0',
  '',
  'dependencies:',
  '  flutter:',
  '    sdk: flutter',
  '  fixture_hosted:',
  '    hosted: https://pub.example.invalid',
  '    version: ^9.9.9',
  '  yaml: ^3.1.3',
  '',
].join('\n');

/// A workspace `Cargo.toml`. [rootPackage] adds a `[package]` table (before
/// `[workspace.package]`) whose own `version` the script must not read.
String _cargo(String version, {String? rootPackage, bool workspace = true}) => [
  if (rootPackage != null) ...[
    '[package]',
    'name = "fixture-root"',
    'version = "$rootPackage"',
    '',
  ],
  '[workspace]',
  'resolver = "2"',
  'members = [',
  '    "crates/memex-core",',
  ']',
  '',
  if (workspace) ...[
    '[workspace.package]',
    'version = "$version"',
    'edition = "2021"',
    'license = "MIT"',
    '',
  ],
  '[workspace.dependencies]',
  'serde = { version = "1", features = ["derive"] }',
  'fixture-dep = "9.9.9"',
  '',
].join('\n');

/// Release notes with the three sections in order. Pass null to leave a
/// section out; pass '' for a heading with no body.
String _notes(
  String version, {
  String? highlights = '- The first public, signed and notarized download.',
  String? upgrade = _noVaultChanges,
  String? requirements = 'Apple silicon Mac, macOS 14 or later.',
}) {
  final b = StringBuffer('# Open Memex $version\n\n');
  if (highlights != null) b.write('$_highlights\n\n$highlights\n\n');
  if (upgrade != null) b.write('$_upgrade\n\n$upgrade\n\n');
  if (requirements != null) b.write('$_requirements\n\n$requirements\n');
  return b.toString();
}

/// Writes a fixture repo root and returns its path. [notes] null leaves
/// `release-notes/v<notesVersion>.md` out (the directory still exists, with
/// an older release's notes in it).
Future<String> _fixture({
  String pubspec = '0.2.0+2',
  String? cargo = '0.2.0',
  String? cargoText,
  bool writePubspec = true,
  String notesVersion = '0.2.0',
  String? notes,
  bool writeNotes = true,
}) async {
  final iso = await isolatedEnv();
  final root = Directory('${iso.work.path}/repo')..createSync();
  if (writePubspec) {
    File('${root.path}/app/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(_pubspec(pubspec));
  }
  final cargoBody = cargoText ?? (cargo == null ? null : _cargo(cargo));
  if (cargoBody != null) {
    File('${root.path}/Cargo.toml').writeAsStringSync(cargoBody);
  }
  final notesDir = Directory('${root.path}/release-notes')..createSync();
  File('${notesDir.path}/v0.1.0.md').writeAsStringSync(_notes('0.1.0'));
  if (writeNotes) {
    File(
      '${notesDir.path}/v$notesVersion.md',
    ).writeAsStringSync(notes ?? _notes(notesVersion));
  }
  _isoByRoot[root.path] = iso;
  return root.path;
}

final _isoByRoot = <String, IsolatedEnv>{};

Future<ScriptResult> _check(String root, String tag) => runScript(
  _script,
  [tag],
  env: _isoByRoot[root]!.env,
  workingDirectory: root,
);

/// The non-blank output lines (stdout then stderr).
List<String> _lines(ScriptResult r) => r.output
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();

/// The output lines that contain every one of [parts].
List<String> _linesWith(ScriptResult r, List<String> parts) =>
    _lines(r).where((l) => parts.every(l.contains)).toList();

bool _isSectionLine(String line, String heading) =>
    line.contains(heading) &&
    !line.contains('No vault changes') &&
    (line.toLowerCase().contains('missing') ||
        line.toLowerCase().contains('empty'));

List<String> _sectionLines(ScriptResult r, String heading) =>
    _lines(r).where((l) => _isSectionLine(l, heading)).toList();

List<String> _phraseLines(ScriptResult r) =>
    _linesWith(r, ['No vault changes', 'schema V']);

void main() {
  group('passing fixtures', () {
    test(
      'check-version v0.2.0 exits 0 for pubspec 0.2.0+2, Cargo 0.2.0 and complete notes with No vault changes',
      () async {
        final root = await _fixture();
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
        expect(_sectionLines(r, _highlights), isEmpty, reason: '$r');
        expect(_phraseLines(r), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version passes when the Upgrade section says the release migrates vaults to schema V7',
      () async {
        final root = await _fixture(
          notes: _notes('0.2.0', upgrade: _migratesV7),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
      },
    );

    test(
      'check-version reads the fixture files from the current directory for any version, such as v3.14.15',
      () async {
        // The checkout this script lives in is at another version, so a
        // script that read files next to itself would fail here.
        final root = await _fixture(
          pubspec: '3.14.15+40',
          cargo: '3.14.15',
          notesVersion: '3.14.15',
        );
        final r = await _check(root, 'v3.14.15');
        expect(r.exitCode, 0, reason: '$r');
      },
    );

    test(
      'check-version accepts a pubspec version with no build number',
      () async {
        final root = await _fixture(pubspec: '0.2.0');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
      },
    );

    test(
      'check-version reads the workspace.package version, not a root package version or a dependency version',
      () async {
        final root = await _fixture(
          cargoText: _cargo('0.2.0', rootPackage: '9.9.9'),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
      },
    );
  });

  group('tag shape', () {
    for (final (name, tag) in [
      ('check-version rejects a tag with no v prefix', '0.2.0'),
      ('check-version rejects a tag with only two version parts', 'v0.2'),
      ('check-version rejects a tag with four version parts', 'v0.2.0.1'),
      ('check-version rejects a tag with a pre-release suffix', 'v0.2.0-rc1'),
      ('check-version rejects a tag with an uppercase V prefix', 'V0.2.0'),
      ('check-version rejects a tag with letters for version parts', 'vx.y.z'),
      ('check-version rejects a tag with an empty version part', 'v0..0'),
      ('check-version rejects a full ref instead of a tag', 'refs/tags/v0.2.0'),
    ]) {
      test(name, () async {
        final root = await _fixture();
        final r = await _check(root, tag);
        expect(r.exitCode, 1, reason: '$r');
        expect(
          _lines(
            r,
          ).where((l) => l.contains(tag) && l.toLowerCase().contains('tag')),
          isNotEmpty,
          reason: 'a line names the tag $tag as malformed\n$r',
        );
      });
    }
  });

  group('versions', () {
    test(
      'check-version fails with one line naming app/pubspec.yaml when the pubspec version differs',
      () async {
        final root = await _fixture(pubspec: '0.2.1+2');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml', '0.2.1']), hasLength(1));
        expect(_lines(r), hasLength(1), reason: 'one failed condition\n$r');
        expect(_linesWith(r, ['Cargo.toml']), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version compares the whole pubspec version, so 0.2.01 does not match v0.2.0',
      () async {
        final root = await _fixture(pubspec: '0.2.01+2');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml', '0.2.01']), hasLength(1));
      },
    );

    test(
      'check-version compares the whole pubspec version, so 10.2.0 does not match v0.2.0',
      () async {
        final root = await _fixture(pubspec: '10.2.0+2');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml', '10.2.0']), hasLength(1));
      },
    );

    test(
      'check-version fails naming app/pubspec.yaml when the file is missing',
      () async {
        final root = await _fixture(writePubspec: false);
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml']), hasLength(1), reason: '$r');
        expect(_linesWith(r, ['Cargo.toml']), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version fails with one line naming Cargo.toml when the workspace version differs',
      () async {
        final root = await _fixture(cargo: '0.2.1');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml', '0.2.1']), hasLength(1));
        expect(_lines(r), hasLength(1), reason: 'one failed condition\n$r');
        expect(_linesWith(r, ['app/pubspec.yaml']), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version compares the whole Cargo version, so 0.2.01 does not match v0.2.0',
      () async {
        final root = await _fixture(cargo: '0.2.01');
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml', '0.2.01']), hasLength(1));
      },
    );

    test(
      'check-version fails when only a root package carries the tag version and workspace.package differs',
      () async {
        final root = await _fixture(
          cargoText: _cargo('0.3.0', rootPackage: '0.2.0'),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml', '0.3.0']), hasLength(1));
      },
    );

    test(
      'check-version fails naming Cargo.toml when it has no workspace.package version',
      () async {
        final root = await _fixture(
          cargoText: _cargo('0.2.0', workspace: false),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml']), hasLength(1), reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml']), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version fails naming Cargo.toml when the file is missing',
      () async {
        final root = await _fixture(cargo: null);
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml']), hasLength(1), reason: '$r');
      },
    );
  });

  group('release notes', () {
    test(
      'check-version fails naming release-notes/v0.2.0.md when the notes file is missing',
      () async {
        final root = await _fixture(writeNotes: false);
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(
          _linesWith(r, ['release-notes/v0.2.0.md']),
          isNotEmpty,
          reason: '$r',
        );
        expect(_linesWith(r, ['app/pubspec.yaml']), isEmpty, reason: '$r');
        expect(_linesWith(r, ['Cargo.toml']), isEmpty, reason: '$r');
      },
    );

    test(
      'check-version looks for the notes of the tag version, not another release',
      () async {
        // v0.1.0.md exists in the fixture; v0.2.0.md does not.
        final root = await _fixture(writeNotes: false);
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['release-notes/v0.2.0.md']), isNotEmpty);
        expect(_linesWith(r, ['v0.1.0']), isEmpty, reason: '$r');
      },
    );

    for (final (name, heading, notes, onlyLine) in [
      (
        'check-version fails when the Highlights section is missing',
        _highlights,
        _notes('0.2.0', highlights: null),
        true,
      ),
      (
        'check-version fails when the Highlights section is empty',
        _highlights,
        _notes('0.2.0', highlights: ''),
        true,
      ),
      (
        'check-version fails when the Highlights section holds only blank lines',
        _highlights,
        _notes('0.2.0', highlights: '   \n\n\t\n'),
        true,
      ),
      (
        'check-version fails when the Upgrade section is missing',
        _upgrade,
        _notes('0.2.0', upgrade: null),
        false,
      ),
      (
        'check-version fails when the Upgrade section is empty',
        _upgrade,
        _notes('0.2.0', upgrade: ''),
        false,
      ),
      (
        'check-version fails when the Requirements section is missing',
        _requirements,
        _notes('0.2.0', requirements: null),
        true,
      ),
      (
        'check-version fails when the Requirements section is empty at the end of the file',
        _requirements,
        _notes('0.2.0', requirements: ''),
        true,
      ),
    ]) {
      test(name, () async {
        final root = await _fixture(notes: notes);
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(
          _sectionLines(r, heading),
          hasLength(1),
          reason: 'one line names $heading as missing or empty\n$r',
        );
        for (final other in [_highlights, _upgrade, _requirements]) {
          if (other == heading) continue;
          expect(
            _sectionLines(r, other),
            isEmpty,
            reason: '$other is fine\n$r',
          );
        }
        if (onlyLine) {
          expect(_lines(r), hasLength(1), reason: 'one failed condition\n$r');
        }
      });
    }

    test(
      'check-version fails with one line per section when all three sections are empty',
      () async {
        final root = await _fixture(
          notes: _notes('0.2.0', highlights: '', upgrade: '', requirements: ''),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        final h = _sectionLines(r, _highlights);
        final u = _sectionLines(r, _upgrade);
        final q = _sectionLines(r, _requirements);
        expect(h, hasLength(1), reason: '$r');
        expect(u, hasLength(1), reason: '$r');
        expect(q, hasLength(1), reason: '$r');
        expect({h.single, u.single, q.single}, hasLength(3), reason: '$r');
      },
    );

    test(
      'check-version fails with one line naming both phrases when the Upgrade section has neither',
      () async {
        final root = await _fixture(
          notes: _notes('0.2.0', upgrade: 'Nothing to do; open the app.'),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_phraseLines(r), hasLength(1), reason: '$r');
        expect(_lines(r), hasLength(1), reason: 'one failed condition\n$r');
        expect(_sectionLines(r, _upgrade), isEmpty, reason: '$r');
      },
    );

    test('check-version fails when schema V has no number after it', () async {
      final root = await _fixture(
        notes: _notes('0.2.0', upgrade: 'This release changes the schema V.'),
      );
      final r = await _check(root, 'v0.2.0');
      expect(r.exitCode, 1, reason: '$r');
      expect(_phraseLines(r), hasLength(1), reason: '$r');
    });

    test(
      'check-version fails when No vault changes appears only outside the Upgrade section',
      () async {
        final root = await _fixture(
          notes: _notes(
            '0.2.0',
            highlights: '- No vault changes in this build.',
            upgrade: 'Open the app as usual.',
            requirements: 'Apple silicon Mac, macOS 14 or later.',
          ),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_phraseLines(r), hasLength(1), reason: '$r');
      },
    );

    test(
      'check-version fails when schema V7 appears only in the Requirements section',
      () async {
        final root = await _fixture(
          notes: _notes(
            '0.2.0',
            upgrade: 'Open the app as usual.',
            requirements: 'Vaults at schema V7 or older; macOS 14 or later.',
          ),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_phraseLines(r), hasLength(1), reason: '$r');
      },
    );
  });

  group('several failures', () {
    test(
      'check-version prints one line per failed condition when pubspec, Cargo and the notes all fail',
      () async {
        final root = await _fixture(
          pubspec: '0.1.0+1',
          cargo: '0.1.5',
          writeNotes: false,
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        final p = _linesWith(r, ['app/pubspec.yaml', '0.1.0']);
        final c = _linesWith(r, ['Cargo.toml', '0.1.5']);
        final n = _linesWith(r, ['release-notes/v0.2.0.md']);
        expect(p, hasLength(1), reason: '$r');
        expect(c, hasLength(1), reason: '$r');
        expect(n, isNotEmpty, reason: '$r');
        expect({p.single, c.single, n.first}, hasLength(3), reason: '$r');
      },
    );

    test(
      'check-version reports a version mismatch and an Upgrade phrase failure together',
      () async {
        final root = await _fixture(
          pubspec: '0.2.1+3',
          notes: _notes('0.2.0', upgrade: 'Open the app as usual.'),
        );
        final r = await _check(root, 'v0.2.0');
        expect(r.exitCode, 1, reason: '$r');
        expect(_linesWith(r, ['app/pubspec.yaml', '0.2.1']), hasLength(1));
        expect(_phraseLines(r), hasLength(1), reason: '$r');
        expect(_lines(r), hasLength(2), reason: 'two failed conditions\n$r');
      },
    );
  });
}
