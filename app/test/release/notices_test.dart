// Tests for scripts/release/notices.sh (#375, Spec #367 requirement 20).
//
// Usage under test: scripts/release/notices.sh [--fonts-dir <dir>] <out-file>
// (the fonts directory defaults to app/assets/google_fonts/).
//
// A fake `cargo` first on PATH logs its arguments (one tab-separated line per
// call) and answers `cargo metadata` with fixture JSON built at runtime. The
// fixture crates' licence files live in a temp registry directory. The
// onnxruntime notices are the committed files under
// scripts/release/third_party/onnxruntime/.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _notices = 'scripts/release/notices.sh';
const _ortDir = 'scripts/release/third_party/onnxruntime';
const _registry = 'registry+https://github.com/rust-lang/crates.io-index';

const _fakeCargo = r'''#!/bin/bash
{
  printf 'cargo'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >>"$FAKE_LOG"
for a in "$@"; do
  if [ "$a" = metadata ]; then
    cat "$FAKE_CARGO_METADATA"
    exit 0
  fi
done
echo "fake cargo: only metadata is supported" >&2
exit 101
''';

/// One fixture crate: its licence files (name -> text) live in its own dir.
class _Crate {
  const _Crate(
    this.name,
    this.version, {
    this.license,
    this.licenseFile,
    this.files = const {},
  });

  final String name;
  final String version;
  final String? license;

  /// The manifest's license-file value (relative to the crate dir).
  final String? licenseFile;
  final Map<String, String> files;

  String get id => '$_registry#$name@$version';
}

/// Licence text markers, one per file.
String _mark(String crate, String file) => 'LICENCE-TEXT $crate $file';

_Crate _dual(String name, String version) => _Crate(
  name,
  version,
  license: 'MIT OR Apache-2.0',
  files: {
    'LICENSE-MIT': _mark('$name-$version', 'LICENSE-MIT'),
    'LICENSE-APACHE': _mark('$name-$version', 'LICENSE-APACHE'),
  },
);

// Linked into memex (normal dependencies reachable from memex-mcp).
final _anyhow = _dual('anyhow', '1.0.102');
final _serde = _dual('serde', '1.0.228');
final _regex = _dual('regex', '1.11.1');
final _regexSyntax = _Crate(
  'regex-syntax',
  '0.8.5',
  license: 'MIT OR Apache-2.0',
  files: {'LICENSE': _mark('regex-syntax', 'LICENSE')},
);
final _memchr = _Crate(
  'memchr',
  '2.7.4',
  license: 'Unlicense OR MIT',
  files: {
    'COPYING': _mark('memchr', 'COPYING'),
    'LICENSE-MIT': _mark('memchr', 'LICENSE-MIT'),
    'UNLICENSE': _mark('memchr', 'UNLICENSE'),
  },
);
final _oddLicense = _Crate(
  'oddlicense',
  '0.3.1',
  licenseFile: 'LEGAL.txt',
  files: {'LEGAL.txt': _mark('oddlicense', 'LEGAL.txt')},
);
final _bitflags1 = _Crate(
  'bitflags',
  '1.3.2',
  license: 'MIT/Apache-2.0',
  files: {'LICENSE-MIT': _mark('bitflags-1.3.2', 'LICENSE-MIT')},
);
final _bitflags2 = _Crate(
  'bitflags',
  '2.9.0',
  license: 'MIT OR Apache-2.0',
  files: {'LICENSE-MIT': _mark('bitflags-2.9.0', 'LICENSE-MIT')},
);
final _onceCell = _Crate(
  'once_cell',
  '1.21.3',
  license: 'MIT OR Apache-2.0',
  files: {'LICENSE-MIT': _mark('once_cell', 'LICENSE-MIT')},
);

// Not linked into memex. The dev-only and build-only crates have no licence
// files, so including them would also fail the run.
const _tempfile = _Crate('tempfile', '3.20.0', license: 'MIT OR Apache-2.0');
const _cc = _Crate('cc', '1.2.27', license: 'MIT OR Apache-2.0');
final _fastrand = _Crate(
  'fastrand',
  '2.3.0',
  license: 'Apache-2.0 OR MIT',
  files: {'LICENSE-MIT': _mark('fastrand', 'LICENSE-MIT')},
);
final _jobserver = _Crate(
  'jobserver',
  '0.1.33',
  license: 'MIT OR Apache-2.0',
  files: {'LICENSE-MIT': _mark('jobserver', 'LICENSE-MIT')},
);
final _insta = _Crate(
  'insta',
  '1.43.1',
  license: 'Apache-2.0',
  files: {'LICENSE': _mark('insta', 'LICENSE')},
);
final _criterion = _Crate(
  'criterion',
  '0.5.1',
  license: 'Apache-2.0 OR MIT',
  files: {'LICENSE-MIT': _mark('criterion', 'LICENSE-MIT')},
);

const _noLicense = _Crate('nolicense-crate', '0.2.0', license: 'MIT');

final _linked = [
  _anyhow,
  _serde,
  _regex,
  _regexSyntax,
  _memchr,
  _oddLicense,
  _bitflags1,
  _bitflags2,
  _onceCell,
];
final _excluded = [_tempfile, _cc, _fastrand, _jobserver, _insta, _criterion];

const _ofl = {
  'OFL-InterTight.txt': 'FONT-OFL-TEXT Inter Tight',
  'OFL-JetBrainsMono.txt': 'FONT-OFL-TEXT JetBrains Mono',
  'OFL-Newsreader.txt': 'FONT-OFL-TEXT Newsreader',
};

class _Fx {
  _Fx(this.iso, this.bin, this.log, this.metadata, this.fonts, this.out);

  final IsolatedEnv iso;
  final String bin;
  final String log;
  final String metadata;
  final String fonts;
  final String out;

  Map<String, String> get env => {
    ...iso.env,
    'PATH': '$bin:/usr/bin:/bin:/usr/sbin:/sbin',
    'FAKE_LOG': log,
    'FAKE_CARGO_METADATA': metadata,
  };
}

Map<String, Object?> _dep(_Crate c, List<String?> kinds) => {
  'name': c.name,
  'pkg': c.id,
  'dep_kinds': [
    for (final k in kinds) {'kind': k, 'target': null},
  ],
};

/// The fixture workspace: memex-mcp and memex-core link the [_linked] crates
/// (plus [extraLinked], linked through regex); dev-only, build-only and
/// another member's crates are in the graph but not linked into memex.
Future<_Fx> _fixture({List<_Crate> extraLinked = const []}) async {
  final iso = await isolatedEnv();
  final w = iso.work.path;
  final bin = Directory('$w/fakebin')..createSync();
  final fakeCargo = File('${bin.path}/cargo')..writeAsStringSync(_fakeCargo);
  await Process.run('/bin/chmod', ['755', fakeCargo.path]);

  final ws = Directory('$w/workspace')..createSync();
  File('${ws.path}/LICENSE').writeAsStringSync('MIT License\nworkspace\n');
  final reg = Directory('$w/registry')..createSync();

  final crates = [..._linked, ..._excluded, ...extraLinked];
  final packages = <Map<String, Object?>>[];
  for (final c in crates) {
    final dir = Directory('${reg.path}/${c.name}-${c.version}')..createSync();
    File('${dir.path}/Cargo.toml').writeAsStringSync('[package]\n');
    File('${dir.path}/README.md').writeAsStringSync('readme ${c.name}\n');
    c.files.forEach((n, text) {
      File('${dir.path}/$n').writeAsStringSync('$text\nline two of $n\n');
    });
    packages.add({
      'name': c.name,
      'version': c.version,
      'id': c.id,
      'license': c.license,
      'license_file': c.licenseFile,
      'source': _registry,
      'manifest_path': '${dir.path}/Cargo.toml',
      'dependencies': [],
      'targets': [],
      'features': {},
    });
  }
  String member(String name) => 'path+file://${ws.path}/crates/$name#0.1.0';
  for (final m in ['memex-mcp', 'memex-core', 'memex-bench']) {
    final dir = Directory('${ws.path}/crates/$m')..createSync(recursive: true);
    File('${dir.path}/Cargo.toml').writeAsStringSync('[package]\n');
    packages.add({
      'name': m,
      'version': '0.1.0',
      'id': member(m),
      'license': 'MIT',
      'license_file': null,
      'source': null,
      'manifest_path': '${dir.path}/Cargo.toml',
      'dependencies': [],
      'targets': [],
      'features': {},
    });
  }
  final coreDep = {
    'name': 'memex_core',
    'pkg': member('memex-core'),
    'dep_kinds': [
      {'kind': null, 'target': null},
    ],
  };
  Map<String, Object?> node(String id, List<Map<String, Object?>> deps) => {
    'id': id,
    'dependencies': [for (final d in deps) d['pkg']],
    'deps': deps,
    'features': [],
  };
  final nodes = [
    node(member('memex-mcp'), [
      coreDep,
      _dep(_anyhow, [null]),
      _dep(_serde, [null]),
      _dep(_regex, [null]),
      _dep(_oddLicense, [null]),
      _dep(_bitflags1, [null]),
      _dep(_onceCell, ['dev', null]),
      _dep(_tempfile, ['dev']),
    ]),
    node(member('memex-core'), [
      _dep(_serde, [null]),
      _dep(_bitflags2, [null]),
      _dep(_cc, ['build']),
      _dep(_insta, ['dev']),
    ]),
    node(member('memex-bench'), [
      coreDep,
      _dep(_criterion, [null]),
    ]),
    node(_regex.id, [
      _dep(_regexSyntax, [null]),
      _dep(_memchr, [null]),
      for (final c in extraLinked) _dep(c, [null]),
    ]),
    node(_tempfile.id, [
      _dep(_fastrand, [null]),
    ]),
    node(_cc.id, [
      _dep(_jobserver, [null]),
    ]),
    for (final c in [
      _anyhow,
      _serde,
      _regexSyntax,
      _memchr,
      _oddLicense,
      _bitflags1,
      _bitflags2,
      _onceCell,
      _fastrand,
      _jobserver,
      _insta,
      _criterion,
      ...extraLinked,
    ])
      node(c.id, []),
  ];
  final members = [
    member('memex-core'),
    member('memex-mcp'),
    member('memex-bench'),
  ];
  final metadata = File('$w/metadata.json')
    ..writeAsStringSync(
      jsonEncode({
        'packages': packages,
        'workspace_members': members,
        'workspace_default_members': members,
        'resolve': {'nodes': nodes, 'root': null},
        'target_directory': '${ws.path}/target',
        'version': 1,
        'workspace_root': ws.path,
        'metadata': null,
      }),
    );

  final fonts = Directory('$w/google_fonts')..createSync();
  _ofl.forEach((n, text) {
    File('${fonts.path}/$n').writeAsStringSync(
      'SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007\n$text\n',
    );
  });
  File('${fonts.path}/InterTight-Regular.ttf').writeAsStringSync('fake font');

  return _Fx(
    iso,
    bin.path,
    '$w/cargo.log',
    metadata.path,
    fonts.path,
    '$w/out/THIRD_PARTY_NOTICES.txt',
  );
}

Future<ScriptResult> _run(_Fx fx, {Map<String, String> env = const {}}) {
  Directory(File(fx.out).parent.path).createSync(recursive: true);
  return runScript(
    _notices,
    ['--fonts-dir', fx.fonts, fx.out],
    env: {...fx.env, ...env},
  );
}

String _read(_Fx fx) {
  final f = File(fx.out);
  expect(f.existsSync(), isTrue, reason: 'no notices file written');
  return f.readAsStringSync();
}

/// A line holding the crate's name and version as separate words.
RegExp _nameVersion(_Crate c) => RegExp(
  '(^|[^A-Za-z0-9_-])${RegExp.escape(c.name)}([^A-Za-z0-9_-].*)?'
  '(^|[^0-9.])v?${RegExp.escape(c.version)}([^0-9.]|\$)',
  multiLine: true,
);

List<List<String>> _cargoCalls(_Fx fx) {
  final f = File(fx.log);
  if (!f.existsSync()) return [];
  return f
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .map((l) => l.split('\t').sublist(1))
      .toList();
}

void main() {
  test(
    'notices list each linked crate with its name version licence and licence text',
    () async {
      final fx = await _fixture();
      final r = await _run(fx);
      expect(r.exitCode, 0, reason: '$r');
      final text = _read(fx);
      for (final c in _linked) {
        expect(
          _nameVersion(c).hasMatch(text),
          isTrue,
          reason: 'no line names ${c.name} ${c.version}',
        );
        if (c.license != null) {
          expect(text, contains(c.license), reason: 'licence of ${c.name}');
        }
      }
      for (final c in [_anyhow, _serde, _regex, _regexSyntax, _bitflags1]) {
        for (final t in c.files.values) {
          expect(
            text,
            contains('$t\nline two of '),
            reason: 'text of ${c.name}',
          );
        }
      }
      expect(text, contains(_mark('memchr', 'COPYING')));
      expect(text, contains(_mark('memchr', 'LICENSE-MIT')));
    },
  );

  test(
    'notices include the licence file a crate names in license_file',
    () async {
      final fx = await _fixture();
      final r = await _run(fx);
      expect(r.exitCode, 0, reason: '$r');
      final text = _read(fx);
      expect(_nameVersion(_oddLicense).hasMatch(text), isTrue);
      expect(text, contains(_mark('oddlicense', 'LEGAL.txt')));
    },
  );

  test('notices list both versions of a crate linked twice', () async {
    final fx = await _fixture();
    final r = await _run(fx);
    expect(r.exitCode, 0, reason: '$r');
    final text = _read(fx);
    expect(_nameVersion(_bitflags1).hasMatch(text), isTrue);
    expect(_nameVersion(_bitflags2).hasMatch(text), isTrue);
    expect(text, contains(_mark('bitflags-1.3.2', 'LICENSE-MIT')));
    expect(text, contains(_mark('bitflags-2.9.0', 'LICENSE-MIT')));
  });

  test('notices exclude dev-only build-only and unreachable crates', () async {
    final fx = await _fixture();
    final r = await _run(fx);
    expect(r.exitCode, 0, reason: '$r');
    final text = _read(fx);
    // A crate that is both a dev and a normal dependency is linked.
    expect(_nameVersion(_onceCell).hasMatch(text), isTrue);
    expect(text, contains(_mark('once_cell', 'LICENSE-MIT')));
    for (final c in _excluded) {
      expect(
        _nameVersion(c).hasMatch(text),
        isFalse,
        reason: '${c.name} ${c.version} is not linked into memex',
      );
      for (final t in c.files.values) {
        expect(text, isNot(contains(t)), reason: 'text of ${c.name}');
      }
    }
  });

  test(
    'notices include the onnxruntime LICENSE and ThirdPartyNotices and the font OFL texts',
    () async {
      final fx = await _fixture();
      final r = await _run(fx);
      expect(r.exitCode, 0, reason: '$r');
      final text = _read(fx);
      final root = repoRoot();
      for (final n in ['LICENSE', 'ThirdPartyNotices.txt']) {
        final f = File('$root/$_ortDir/$n');
        expect(f.existsSync(), isTrue, reason: '$_ortDir/$n is missing');
        final body = f.readAsStringSync().trim();
        expect(body, isNotEmpty, reason: '$_ortDir/$n is empty');
        expect(text, contains(body), reason: '$_ortDir/$n not in the notices');
      }
      _ofl.forEach((n, marker) {
        expect(text, contains(marker), reason: '$n not in the notices');
      });
    },
  );

  test(
    'notices fail naming the crate when a linked crate has no licence text',
    () async {
      final fx = await _fixture(extraLinked: [_noLicense]);
      final r = await _run(fx);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains(_noLicense.name), reason: '$r');
      // The dev-only and build-only crates without licence files are not the
      // ones it names.
      expect(r.output, isNot(contains(_tempfile.name)), reason: '$r');
      expect(
        RegExp(r'(^|[^A-Za-z0-9_-])cc([^A-Za-z0-9_-]|$)').hasMatch(r.output),
        isFalse,
        reason: '$r',
      );
    },
  );

  test(
    'notices read cargo metadata for aarch64-apple-darwin and run no other cargo command',
    () async {
      final fx = await _fixture();
      final r = await _run(fx);
      expect(r.exitCode, 0, reason: '$r');
      final calls = _cargoCalls(fx);
      expect(calls, isNotEmpty, reason: 'cargo metadata was not run');
      for (final a in calls) {
        expect(a, contains('metadata'), reason: 'cargo ${a.join(' ')}');
        expect(a, isNot(contains('install')), reason: 'cargo ${a.join(' ')}');
      }
      final joined = calls.map((a) => a.join(' ')).toList();
      expect(
        joined.any(
          (a) =>
              RegExp(
                r'--filter-platform[= ]aarch64-apple-darwin\b',
              ).hasMatch(a) &&
              RegExp(r'--format-version[= ]1\b').hasMatch(a),
        ),
        isTrue,
        reason: '$joined',
      );
    },
  );

  test('notices.sh exits 2 naming jq when jq is missing', () async {
    final fx = await _fixture();
    // A PATH holding every system tool except jq, plus the fake cargo.
    final noJq = Directory('${fx.iso.work.path}/nojq')..createSync();
    for (final dir in ['/usr/bin', '/bin', '/usr/sbin', '/sbin']) {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = e.path.split('/').last;
        if (name == 'jq') continue;
        final link = Link('${noJq.path}/$name');
        if (link.existsSync() || File(link.path).existsSync()) continue;
        link.createSync(e.path);
      }
    }
    Link('${noJq.path}/cargo').createSync('${fx.bin}/cargo');
    final r = await _run(fx, env: {'PATH': noJq.path});
    expect(r.exitCode, 2, reason: '$r');
    expect(r.output, contains('jq'), reason: '$r');
  });

  test('notices.sh without an output file exits 2', () async {
    final fx = await _fixture();
    final r = await runScript(_notices, [], env: fx.env);
    expect(r.exitCode, 2, reason: '$r');
    expect(_cargoCalls(fx), isEmpty);
    expect(r.output.toLowerCase(), contains('usage'), reason: '$r');
  });

  test('the committed onnxruntime notices note their upstream version', () {
    final dir = Directory('${repoRoot()}/$_ortDir');
    expect(dir.existsSync(), isTrue, reason: '$_ortDir is missing');
    final license = File('${dir.path}/LICENSE');
    expect(license.existsSync(), isTrue);
    final lt = license.readAsStringSync();
    expect(lt, contains('MIT License'));
    expect(lt, contains('Microsoft Corporation'));
    final tpn = File('${dir.path}/ThirdPartyNotices.txt');
    expect(tpn.existsSync(), isTrue);
    expect(tpn.lengthSync(), greaterThan(1000));
    final version = RegExp(
      r'^.*(onnxruntime|ONNX Runtime).*\bv?1\.\d+\.\d+\b',
      multiLine: true,
      caseSensitive: false,
    );
    final all = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join('\n');
    expect(version.hasMatch(all), isTrue, reason: 'no upstream version noted');
  });

  test('notices.sh is an executable bash script', () {
    final f = File('${repoRoot()}/$_notices');
    expect(f.existsSync(), isTrue, reason: '$_notices is missing');
    expect(f.statSync().mode & 0x49, 0x49, reason: 'not executable');
    final first = f.readAsLinesSync().first;
    expect(first.startsWith('#!'), isTrue);
    expect(first, contains('bash'));
  });
}
