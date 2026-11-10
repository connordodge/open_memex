// Tests for scripts/leak-check.sh (#369, Spec #367 requirements 7-10).
//
// Every run asserts the exact exit code, and every "output lacks X" check
// sits beside a positive one (a LEAK line or the LEAK WARN line): on main the
// script is missing, so a bare non-zero exit would pass there.
//
// Fixtures never hold a literal leak: home paths and emails are built at
// runtime, so this file passes the Leak check itself (see the tree self-check
// test at the bottom).
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _script = 'scripts/leak-check.sh';

/// `LEAK <file-or-ref>:<line-or-offset> <rule>` on stdout.
final _hitLine = RegExp(r'^LEAK (.+):(\d+) (\S+)', multiLine: true);

const _warn = 'LEAK WARN: no deny-list';

// Runtime-built fixtures (never literal in the source).
const _strangerName = 'stranger';
final _stranger = leakPath(_strangerName);
final _homeStranger = ['', 'home', 'stranger', ''].join('/');
final _email = ['jo.private', 'example.org'].join('@');
final _denyPath = ['', 'srv', 'privateproj'].join('/');
final _ortPrefix = '${leakPath('runner')}work/ort-artifacts/';
final _runnerOther = '${leakPath('runner')}work/open_memex/';

const _placeholderNames = [
  'you',
  'YOU',
  'YOUR_USERNAME',
  'test',
  'tester',
  'person',
  'me',
  'a',
  't',
  'jane',
  'connor',
  'alice',
  'mcp',
  'memex',
  'Library',
];

final _rand = Random();
String _uniq() =>
    '${DateTime.now().microsecondsSinceEpoch}${_rand.nextInt(1 << 30)}';

List<RegExpMatch> _hits(ScriptResult r) =>
    _hitLine.allMatches(r.stdout).toList();

/// Exit 1, at least one LEAK line, and none of [hidden] anywhere in stdout or
/// stderr (compared case-insensitively).
void _expectLeak(
  ScriptResult r, {
  required List<String> hidden,
  String what = '',
}) {
  expect(r.exitCode, 1, reason: 'exit for $what\n$r');
  expect(_hits(r), isNotEmpty, reason: 'LEAK line for $what\n$r');
  _expectHidden(r, hidden, what);
}

void _expectHidden(ScriptResult r, List<String> hidden, String what) {
  final out = r.stdout.toLowerCase();
  final err = r.stderr.toLowerCase();
  for (final h in hidden) {
    final l = h.toLowerCase();
    expect(
      out.contains(l),
      isFalse,
      reason: 'stdout shows the leaked text ($what)',
    );
    expect(
      err.contains(l),
      isFalse,
      reason: 'stderr shows the leaked text ($what)',
    );
  }
}

/// Exit 0 and no LEAK line.
void _expectClean(ScriptResult r, {String what = ''}) {
  expect(r.exitCode, 0, reason: 'exit for $what\n$r');
  expect(_hits(r), isEmpty, reason: 'LEAK lines for $what\n$r');
}

Future<ScriptResult> _leak(
  IsolatedEnv iso,
  List<String> args, {
  Map<String, String> env = const {},
  String? stdin,
  String? workingDirectory,
}) => runScript(
  _script,
  args,
  env: {...iso.env, ...env},
  stdin: stdin,
  workingDirectory: workingDirectory,
);

/// Writes [content] under the scratch dir and returns its absolute path.
Future<String> _write(IsolatedEnv iso, String rel, String content) async {
  final f = File('${iso.work.path}/$rel');
  await f.parent.create(recursive: true);
  await f.writeAsString(content);
  return f.path;
}

Future<String> _writeBytes(IsolatedEnv iso, String rel, List<int> bytes) async {
  final f = File('${iso.work.path}/$rel');
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
  return f.path;
}

/// A patterns file outside the scratch dir (so tree scans never read it).
Future<String> _patterns(IsolatedEnv iso, List<String> lines) async {
  final f = File('${iso.root.path}/patterns-${_uniq()}.txt');
  await f.writeAsString(lines.join('\n'));
  return f.path;
}

/// Bytes shaped like a fat Mach-O: magic, nulls and high bytes around [text].
List<int> _binaryAround(String text) => [
  0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02, 0x01, 0xFF, 0x00, //
  ...utf8.encode(text),
  0x00, 0xFE, 0x07, 0x00, 0x80, 0x81, 0x00,
];

/// Text that deflates well, so the raw zip or DMG bytes never hold [leak].
String _compressible(String leak) =>
    List.filled(400, 'payload line $leak padding padding padding\n').join();

bool _bytesContain(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

Future<String> _makeRepo(IsolatedEnv iso, String name) async {
  final dir = '${iso.work.path}/$name';
  await Directory(dir).create(recursive: true);
  await runGit(iso, dir, ['init', '-q']);
  return dir;
}

Future<void> _commit(
  IsolatedEnv iso,
  String repo,
  Map<String, String> files,
  String message, {
  Map<String, String> env = const {},
}) async {
  for (final e in files.entries) {
    final f = File('$repo/${e.key}');
    await f.parent.create(recursive: true);
    await f.writeAsString(e.value);
  }
  await runGit(iso, repo, ['add', '-A']);
  await runGit(iso, repo, [
    'commit',
    '-q',
    '--allow-empty',
    '-m',
    message,
  ], env: env);
}

/// A repo with two clean commits on main.
Future<String> _cleanRepo(IsolatedEnv iso, String name) async {
  final repo = await _makeRepo(iso, name);
  await _commit(iso, repo, {'README.md': 'hello\n'}, 'first commit');
  await _commit(iso, repo, {'src/lib.txt': 'code\n'}, 'second commit');
  return repo;
}

Future<String> _zip(IsolatedEnv iso, String srcDir, String zipPath) async {
  await runTool(iso, 'zip', [
    '-q',
    '-r',
    '-9',
    zipPath,
    '.',
  ], workingDirectory: srcDir);
  return zipPath;
}

int _crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// A zip archive of (name, text) entries, deflated, written by hand so a
/// name can repeat (`zip` never writes two entries with one name).
List<int> _zipBytes(List<(String, String)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  for (final (name, text) in entries) {
    final nameBytes = utf8.encode(name);
    final raw = utf8.encode(text);
    final packed = ZLibCodec(raw: true, level: 9).encode(raw);
    final crc = _crc32(raw);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0);
    u16(out, 8);
    u16(out, 0);
    u16(out, 0x21);
    u32(out, crc);
    u32(out, packed.length);
    u32(out, raw.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(packed);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0);
    u16(central, 8);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, packed.length);
    u32(central, raw.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
  }
  final start = out.length;
  final dir = central.takeBytes();
  out.add(dir);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, dir.length);
  u32(out, start);
  u16(out, 0);
  return out.takeBytes();
}

Future<String> _dmg(IsolatedEnv iso, String srcDir, String dmgPath) async {
  await runTool(iso, 'hdiutil', [
    'create',
    '-quiet',
    '-srcfolder',
    srcDir,
    '-volname',
    'LeakFixture${_uniq()}',
    '-fs',
    'HFS+',
    '-format',
    'UDZO',
    dmgPath,
  ], workingDirectory: iso.work.path);
  return dmgPath;
}

Future<bool> _dmgAttached(IsolatedEnv iso, String dmgPath) async {
  final info = await runTool(iso, 'hdiutil', [
    'info',
  ], workingDirectory: iso.work.path);
  final name = dmgPath.split('/').last;
  return info.stdout.contains(name);
}

void main() {
  group('rule a: private deny-list', () {
    test(
      'text mode flags a deny-list path entry from a patterns file and from LEAK_PATTERNS',
      () async {
        final iso = await isolatedEnv();
        final text = await _write(
          iso,
          'body.txt',
          'intro\nsee $_denyPath/notes here\n',
        );

        final fromFile = await _leak(iso, [
          '--text',
          text,
          '--patterns',
          await _patterns(iso, [_denyPath]),
        ]);
        _expectLeak(fromFile, hidden: [_denyPath], what: 'patterns file');

        final fromEnv = await _leak(
          iso,
          ['--text', text],
          env: {'LEAK_PATTERNS': '\n$_denyPath\n\n'},
        );
        _expectLeak(fromEnv, hidden: [_denyPath], what: 'LEAK_PATTERNS');

        // Without the entry the same text is clean: the hit came from rule a.
        final without = await _leak(iso, [
          '--text',
          text,
          '--allow-empty-patterns',
        ]);
        _expectClean(without, what: 'no deny-list');
      },
    );

    test(
      'entries from a patterns file and from LEAK_PATTERNS both apply',
      () async {
        final iso = await isolatedEnv();
        final entryA = ['', 'srv', 'alpha-client'].join('/');
        final entryB = ['', 'srv', 'beta-client'].join('/');
        final pats = await _patterns(iso, [entryA]);
        final env = {'LEAK_PATTERNS': entryB};

        final onlyB = await _write(iso, 'b.txt', 'x $entryB y\n');
        _expectLeak(
          await _leak(iso, ['--patterns', pats, '--text', onlyB], env: env),
          hidden: [entryB],
          what: 'env entry',
        );

        final onlyA = await _write(iso, 'a.txt', 'x $entryA y\n');
        _expectLeak(
          await _leak(iso, ['--patterns', pats, '--text', onlyA], env: env),
          hidden: [entryA],
          what: 'file entry',
        );
      },
    );

    test(
      'blank deny-list lines are ignored and never match clean text',
      () async {
        final iso = await isolatedEnv();
        final pats = await _patterns(iso, ['', _denyPath, '', '', '']);
        final env = {'LEAK_PATTERNS': '\n\n$_email\n\n'};
        final clean = await _write(
          iso,
          'clean.txt',
          'nothing private here\n\nat all\n',
        );
        _expectClean(
          await _leak(iso, ['--text', clean, '--patterns', pats], env: env),
          what: 'clean text',
        );

        final leaky = await _write(
          iso,
          'leaky.txt',
          'nothing private here\nmail $_email\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', leaky, '--patterns', pats], env: env),
          hidden: [_email],
          what: 'email',
        );
      },
    );

    test(
      'deny-list entries match as literals and not as regular expressions',
      () async {
        final iso = await isolatedEnv();
        final pats = await _patterns(iso, [_email, '$_denyPath[1]']);
        final lookalike = await _write(
          iso,
          'look.txt',
          'mail joXprivate@exampleYorg and ${_denyPath}1\n',
        );
        _expectClean(
          await _leak(iso, ['--text', lookalike, '--patterns', pats]),
          what: 'regex lookalike',
        );

        final exact = await _write(
          iso,
          'exact.txt',
          'path $_denyPath[1] end\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', exact, '--patterns', pats]),
          hidden: ['$_denyPath[1]'],
          what: 'bracket literal',
        );
      },
    );

    test(
      'allow-empty-patterns keeps a given deny-list active and prints no warning',
      () async {
        final iso = await isolatedEnv();
        final text = await _write(iso, 'body.txt', 'see $_denyPath\n');
        final r = await _leak(
          iso,
          ['--allow-empty-patterns', '--text', text],
          env: {'LEAK_PATTERNS': _denyPath},
        );
        _expectLeak(r, hidden: [_denyPath], what: 'flag with entries');
        expect(r.output.contains(_warn), isFalse, reason: '$r');
      },
    );
  });

  group('rule a: email and path case', () {
    test(
      'an email entry matches regardless of case and a path entry matches only with the same case',
      () async {
        final iso = await isolatedEnv();
        final mixedEntry = ['Jo.Private', 'Example.org'].join('@');
        final pats = await _patterns(iso, [mixedEntry, _denyPath]);

        final upper = await _write(
          iso,
          'upper.txt',
          'contact ${_email.toUpperCase()} today\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', upper, '--patterns', pats]),
          hidden: [_email],
          what: 'upper-case email',
        );

        final lower = await _write(iso, 'lower.txt', 'contact $_email today\n');
        _expectLeak(
          await _leak(iso, ['--text', lower, '--patterns', pats]),
          hidden: [_email],
          what: 'lower-case email',
        );

        final pathOtherCase = await _write(
          iso,
          'pupper.txt',
          'dir ${_denyPath.toUpperCase()} here\n',
        );
        _expectClean(
          await _leak(iso, ['--text', pathOtherCase, '--patterns', pats]),
          what: 'path in other case',
        );

        final pathSameCase = await _write(
          iso,
          'psame.txt',
          'dir $_denyPath here\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', pathSameCase, '--patterns', pats]),
          hidden: [_denyPath],
          what: 'path same case',
        );
      },
    );

    test(
      'any entry containing an at sign is matched case-insensitively',
      () async {
        final iso = await isolatedEnv();
        final entry = ['', 'srv', 'team'].join('/') + ['', 'corp'].join('@');
        final text = await _write(iso, 't.txt', 'x ${entry.toUpperCase()} y\n');
        _expectLeak(
          await _leak(iso, ['--text', text], env: {'LEAK_PATTERNS': entry}),
          hidden: [entry],
          what: 'at-sign path',
        );
      },
    );
  });

  group('rule b: HOME', () {
    test(
      'text containing the running HOME path exits 1 even with an empty deny-list and allow-empty-patterns',
      () async {
        final iso = await isolatedEnv();
        final text = await _write(
          iso,
          'body.txt',
          'config at ${iso.home}/.config/app.toml\n',
        );

        final r = await _leak(iso, ['--text', text, '--allow-empty-patterns']);
        _expectLeak(r, hidden: [iso.home], what: 'HOME');
        expect(r.output, contains(_warn));
        // The whole HOME path is the redacted span, not a part of it.
        expect(
          r.stdout,
          contains('config at [redacted]/.config/app.toml'),
          reason: 'HOME is redacted whole\n$r',
        );

        // Under another HOME the same text is clean: the hit came from rule b.
        final other = await isolatedEnv();
        _expectClean(
          await _leak(other, ['--text', text, '--allow-empty-patterns']),
          what: 'other HOME',
        );
      },
    );
  });

  group('rule c: home-directory names', () {
    test(
      'a Users and a home path with a name outside the allow-list each exit 1 and the test vault path exits 0',
      () async {
        final iso = await isolatedEnv();
        final users = await _write(
          iso,
          'users.txt',
          'open ${_stranger}notes/x.md\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', users, '--allow-empty-patterns']),
          hidden: [_stranger, _strangerName],
          what: 'Users path',
        );
        // Only the user name is the redacted span, and all of it.
        final usersOut = await _leak(iso, [
          '--text',
          users,
          '--allow-empty-patterns',
        ]);
        expect(
          usersOut.stdout,
          contains('open ${leakPath('[redacted]')}notes/x.md'),
          reason: 'the whole name is redacted\n$usersOut',
        );

        final home = await _write(
          iso,
          'home.txt',
          'open ${_homeStranger}notes/x.md\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', home, '--allow-empty-patterns']),
          hidden: [_homeStranger, _strangerName],
          what: 'home path',
        );
        final homeOut = await _leak(iso, [
          '--text',
          home,
          '--allow-empty-patterns',
        ]);
        expect(
          homeOut.stdout,
          contains(
            'open ${['', 'home', '[redacted]', ''].join('/')}notes/x.md',
          ),
          reason: 'the whole name is redacted\n$homeOut',
        );

        final vault = await _write(
          iso,
          'vault.txt',
          'vault: /Users/test/My Vaults\n',
        );
        _expectClean(
          await _leak(iso, ['--text', vault, '--allow-empty-patterns']),
          what: 'test vault',
        );
      },
    );

    test(
      'every allow-listed placeholder name passes under Users and home',
      () async {
        final iso = await isolatedEnv();
        for (final name in _placeholderNames) {
          final lines = [
            'a ${leakPath(name)}project/file.txt',
            'b ${['', 'home', name, ''].join('/')}project/file.txt',
          ];
          final f = await _write(
            iso,
            'names/$name.txt',
            '${lines.join('\n')}\n',
          );
          _expectClean(
            await _leak(iso, ['--text', f, '--allow-empty-patterns']),
            what: name,
          );
        }
      },
    );

    test('allow-list names match exactly and case-sensitively', () async {
      final iso = await isolatedEnv();
      for (final name in ['Jane', 'Test', 'tester2', 'connors', 'mem']) {
        final f = await _write(iso, 'near/$name.txt', 'x ${leakPath(name)}y\n');
        _expectLeak(
          await _leak(iso, ['--text', f, '--allow-empty-patterns']),
          hidden: [leakPath(name)],
          what: name,
        );
      }
    });

    test(
      'an allowed path does not hide a disallowed path on the same line',
      () async {
        final iso = await isolatedEnv();
        final f = await _write(
          iso,
          'mixed.txt',
          'from /Users/test/a and ${_ortPrefix}b.cc to file://${_stranger}c\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', f, '--allow-empty-patterns']),
          hidden: [_stranger, _strangerName],
          what: 'mixed line',
        );
      },
    );
  });

  group('third-party prefixes', () {
    test(
      'the ort-artifacts prefix exits 0 while the same tail elsewhere and a deny-list entry inside it exit 1',
      () async {
        final iso = await isolatedEnv();
        final ort = await _write(
          iso,
          'ort.txt',
          'panic at ${_ortPrefix}onnxruntime/core/x.cc:12\n',
        );
        _expectClean(
          await _leak(iso, ['--text', ort, '--allow-empty-patterns']),
          what: 'ort prefix',
        );

        final other = await _write(
          iso,
          'other.txt',
          'panic at ${_runnerOther}onnxruntime/core/x.cc:12\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', other, '--allow-empty-patterns']),
          hidden: [_runnerOther],
          what: 'other runner path',
        );

        final entry = '${_ortPrefix}onnxruntime/secret-build';
        final denied = await _write(
          iso,
          'denied.txt',
          'panic at $entry/x.cc\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', denied], env: {'LEAK_PATTERNS': entry}),
          hidden: [entry],
          what: 'deny entry in prefix',
        );
      },
    );

    test('the third-party prefix also exempts the HOME rule', () async {
      final iso = await isolatedEnv();
      final prefixHome = '${_ortPrefix}h';
      final f = await _write(iso, 'h.txt', 'built in $prefixHome/out\n');
      _expectClean(
        await _leak(
          iso,
          ['--text', f, '--allow-empty-patterns'],
          env: {'HOME': prefixHome},
        ),
        what: 'HOME inside prefix',
      );

      final plainHome = ['', 'opt', 'buildhome'].join('/');
      final g = await _write(iso, 'g.txt', 'built in $plainHome/out\n');
      _expectLeak(
        await _leak(
          iso,
          ['--text', g, '--allow-empty-patterns'],
          env: {'HOME': plainHome},
        ),
        hidden: [plainHome],
        what: 'HOME outside prefix',
      );
    });

    test(
      'the third-party prefix matches only through its trailing slash',
      () async {
        final iso = await isolatedEnv();
        final near = '${leakPath('runner')}work/ort-artifacts-fork/';
        final f = await _write(iso, 'near.txt', 'x ${near}y.cc\n');
        _expectLeak(
          await _leak(iso, ['--text', f, '--allow-empty-patterns']),
          hidden: [leakPath('runner')],
          what: 'prefix lookalike',
        );
      },
    );
  });

  group('output', () {
    test(
      'a hit prints LEAK with location line and rule and redacts the match from stdout and stderr',
      () async {
        final iso = await isolatedEnv();
        final f = await _write(
          iso,
          'notes.txt',
          'first line\ncfg=$_denyPath;end\nlast line\n',
        );
        final r = await _leak(iso, [
          '--text',
          f,
          '--patterns',
          await _patterns(iso, [_denyPath]),
        ]);
        _expectLeak(r, hidden: [_denyPath], what: 'redaction');
        final hits = _hits(r);
        expect(hits, hasLength(1), reason: '$r');
        expect(hits.single.group(1), endsWith('notes.txt'), reason: '$r');
        expect(hits.single.group(2), '2', reason: '$r');
        expect(hits.single.group(3), isNotEmpty);
        expect(r.stdout, contains('cfg=[redacted];end'), reason: '$r');
      },
    );

    test(
      'every hit on a line is redacted and each hit line is reported',
      () async {
        final iso = await isolatedEnv();
        final other = ['', 'srv', 'second-secret'].join('/');
        final f = await _write(
          iso,
          'multi.txt',
          'a $_denyPath b $other c ${_stranger}d ${_email.toUpperCase()}\nclean\nagain $_denyPath\n',
        );
        final r = await _leak(
          iso,
          ['--text', f],
          env: {'LEAK_PATTERNS': '$_denyPath\n$other\n$_email'},
        );
        _expectLeak(
          r,
          hidden: [_denyPath, other, _stranger, _strangerName, _email],
          what: 'multi',
        );
        final lines = _hits(r).map((m) => m.group(2)).toSet();
        expect(lines, containsAll(['1', '3']), reason: '$r');
        expect(lines.contains('2'), isFalse, reason: '$r');
        expect(
          r.stdout,
          contains(
            'a [redacted] b [redacted] c ${leakPath('[redacted]')}d [redacted]',
          ),
          reason: 'each span, the user name included, is redacted whole\n$r',
        );
        expect(r.stdout, contains('[redacted]'));
      },
    );

    test('text mode reads stdin when the path is a dash', () async {
      final iso = await isolatedEnv();
      final r = await _leak(iso, [
        '--text',
        '-',
        '--allow-empty-patterns',
      ], stdin: 'pr body\nsee ${_stranger}x\n');
      _expectLeak(r, hidden: [_stranger, _strangerName], what: 'stdin');
      final clean = await _leak(iso, [
        '--text',
        '-',
        '--allow-empty-patterns',
      ], stdin: 'pr body\nall fine\n');
      _expectClean(clean, what: 'clean stdin');
    });
  });

  group('usage errors', () {
    test(
      'an unknown mode a missing input path a missing patterns file and an empty deny-list each exit 2',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _denyPath};
        final text = await _write(iso, 'ok.txt', 'fine\n');

        final unknown = await _leak(iso, ['--bogus', text], env: env);
        expect(unknown.exitCode, 2, reason: 'unknown mode\n$unknown');

        final missingInput = await _leak(iso, [
          '--text',
          '${iso.work.path}/absent.txt',
        ], env: env);
        expect(
          missingInput.exitCode,
          2,
          reason: 'missing input\n$missingInput',
        );

        final missingPatterns = await _leak(iso, [
          '--text',
          text,
          '--patterns',
          '${iso.root.path}/absent-patterns.txt',
        ], env: env);
        expect(
          missingPatterns.exitCode,
          2,
          reason: 'missing patterns file\n$missingPatterns',
        );

        final empty = await _leak(iso, ['--text', text]);
        expect(empty.exitCode, 2, reason: 'empty deny-list\n$empty');
      },
    );

    test(
      'every mode refuses an empty deny-list with exit 2 even when the input leaks',
      () async {
        final iso = await isolatedEnv();
        final leakText = 'see ${_stranger}x\n';
        final text = await _write(iso, 'in/t.txt', leakText);
        final diff = await _write(
          iso,
          'in/d.diff',
          '--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+$leakText',
        );
        final tree = '${iso.work.path}/in';
        final repo = await _makeRepo(iso, 'repo');
        await _commit(iso, repo, {'f.txt': leakText}, 'add');
        final bin = await _writeBytes(
          iso,
          'bin/tool',
          _binaryAround(_stranger),
        );
        final cases = <(String, List<String>)>[
          ('text', ['--text', text]),
          ('diff', ['--diff', diff]),
          ('tree', ['--tree', tree]),
          ('history', ['--history', '$repo/.git']),
          ('artifact', ['--artifact', bin]),
        ];
        for (final (mode, args) in cases) {
          for (final env in [
            <String, String>{},
            {'LEAK_PATTERNS': ''},
            {'LEAK_PATTERNS': '\n\n'},
          ]) {
            final r = await _leak(iso, args, env: env);
            expect(r.exitCode, 2, reason: '$mode with $env\n$r');
            expect(_hits(r), isEmpty, reason: '$mode with $env\n$r');
          }
          final blankFile = await _patterns(iso, ['', '', '']);
          final r = await _leak(iso, [...args, '--patterns', blankFile]);
          expect(r.exitCode, 2, reason: '$mode with a blank patterns file\n$r');
        }
      },
    );

    test('every mode exits 2 for a missing input path', () async {
      final iso = await isolatedEnv();
      final absent = '${iso.work.path}/does-not-exist';
      final present = await _writeBytes(iso, 'present.bin', [0, 1, 2]);
      final cases = <(String, List<String>)>[
        ('text', ['--text', absent]),
        ('diff', ['--diff', absent]),
        ('tree', ['--tree', absent]),
        ('history', ['--history', absent]),
        ('artifact', ['--artifact', absent]),
        ('artifact second path', ['--artifact', present, absent]),
      ];
      for (final (mode, args) in cases) {
        final r = await _leak(iso, args, env: {'LEAK_PATTERNS': _denyPath});
        expect(r.exitCode, 2, reason: '$mode\n$r');
      }
    });

    test('no arguments and a mode without its path exit 2', () async {
      final iso = await isolatedEnv();
      final env = {'LEAK_PATTERNS': _denyPath};
      for (final args in [
        <String>[],
        ['--text'],
        ['--diff'],
        ['--tree'],
        ['--history'],
        ['--artifact'],
        ['--text', '-', '--patterns'],
      ]) {
        final r = await _leak(iso, args, env: env, stdin: 'x\n');
        expect(r.exitCode, 2, reason: '$args\n$r');
      }
    });
  });

  group('empty deny-list warning', () {
    test(
      'allow-empty-patterns with an empty deny-list passes clean input and prints the warning',
      () async {
        final iso = await isolatedEnv();
        final f = await _write(
          iso,
          'clean.txt',
          'all fine\n/Users/test/My Vaults\n',
        );
        final r = await _leak(
          iso,
          ['--allow-empty-patterns', '--text', f],
          env: {'LEAK_PATTERNS': ''},
        );
        _expectClean(r, what: 'allow-empty clean');
        expect(r.output, contains(_warn), reason: '$r');

        final withList = await _leak(
          iso,
          ['--text', f],
          env: {'LEAK_PATTERNS': _denyPath},
        );
        _expectClean(withList, what: 'with deny-list');
        expect(withList.output.contains(_warn), isFalse, reason: '$withList');
      },
    );
  });

  group('diff mode', () {
    String diffWith({
      required String added,
      required String removed,
      required String context,
    }) => [
      'diff --git a/notes.md b/notes.md',
      'index 1111111..2222222 100644',
      '--- a/notes.md',
      '+++ b/notes.md',
      '@@ -1,3 +1,3 @@',
      ' $context',
      '-$removed',
      '+$added',
      ' tail',
      '',
    ].join('\n');

    test(
      'diff mode flags a leak on an added line and ignores the same text on removed and context lines',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final leaky = 'mail $_email and ${_stranger}x';

        final added = await _write(
          iso,
          'added.diff',
          diffWith(added: leaky, removed: 'old', context: 'ctx'),
        );
        _expectLeak(
          await _leak(iso, ['--diff', added], env: env),
          hidden: [_email, _stranger, _strangerName],
          what: 'added line',
        );

        final removedOnly = await _write(
          iso,
          'removed.diff',
          diffWith(added: 'new', removed: leaky, context: 'ctx'),
        );
        _expectClean(
          await _leak(iso, ['--diff', removedOnly], env: env),
          what: 'removed line',
        );

        final contextOnly = await _write(
          iso,
          'context.diff',
          diffWith(added: 'new', removed: 'old', context: leaky),
        );
        _expectClean(
          await _leak(iso, ['--diff', contextOnly], env: env),
          what: 'context line',
        );
      },
    );

    test('diff mode reads a diff from stdin when the path is a dash', () async {
      final iso = await isolatedEnv();
      final r = await _leak(
        iso,
        [
          '--patterns',
          await _patterns(iso, [_denyPath]),
          '--diff',
          '-',
        ],
        stdin: diffWith(
          added: 'cfg $_denyPath',
          removed: 'old',
          context: 'ctx',
        ),
      );
      _expectLeak(r, hidden: [_denyPath], what: 'stdin diff');
    });
  });

  group('tree mode', () {
    test(
      'tree mode flags a leak in a text file and in a binary file between non-printable bytes',
      () async {
        final iso = await isolatedEnv();
        await _write(iso, 'clean/readme.md', 'nothing here\n');
        await _writeBytes(
          iso,
          'clean/bin/tool',
          _binaryAround('/usr/lib/libSystem.B.dylib'),
        );
        _expectClean(
          await _leak(iso, [
            '--tree',
            '${iso.work.path}/clean',
            '--allow-empty-patterns',
          ]),
          what: 'clean tree',
        );

        await _write(iso, 'text/readme.md', 'nothing here\n');
        await _write(
          iso,
          'text/docs/setup.md',
          'step one\nrun ${_stranger}bin/tool\n',
        );
        final textHit = await _leak(iso, [
          '--tree',
          '${iso.work.path}/text',
          '--allow-empty-patterns',
        ]);
        _expectLeak(
          textHit,
          hidden: [_stranger, _strangerName],
          what: 'text file',
        );
        expect(
          textHit.stdout,
          contains('run ${leakPath('[redacted]')}bin/tool'),
          reason: 'the whole user name is redacted\n$textHit',
        );
        expect(
          _hits(
            textHit,
          ).any((m) => m.group(1)!.endsWith('setup.md') && m.group(2) == '2'),
          isTrue,
          reason: '$textHit',
        );

        await _write(iso, 'binary/readme.md', 'nothing here\n');
        await _writeBytes(
          iso,
          'binary/Frameworks/CSQLite',
          _binaryAround('${_stranger}src/checkout/sqlite3.c'),
        );
        final binHit = await _leak(iso, [
          '--tree',
          '${iso.work.path}/binary',
          '--allow-empty-patterns',
        ]);
        _expectLeak(
          binHit,
          hidden: [_stranger, _strangerName],
          what: 'binary file',
        );
        expect(
          _hits(binHit).any((m) => m.group(1)!.endsWith('CSQLite')),
          isTrue,
          reason: '$binHit',
        );
      },
    );

    test('tree mode reads files in nested and hidden directories', () async {
      final iso = await isolatedEnv();
      await _write(iso, 'tree/a/b/c/deep.txt', 'ok\n');
      await _write(
        iso,
        'tree/.config/settings.json',
        '{"vault": "${_stranger}vault"}\n',
      );
      _expectLeak(
        await _leak(iso, [
          '--tree',
          '${iso.work.path}/tree',
          '--allow-empty-patterns',
        ]),
        hidden: [_stranger, _strangerName],
        what: 'hidden dir',
      );
    });
  });

  group('history mode', () {
    test(
      'history mode flags a leak in an old blob a file path a commit message an author email a committer email and a tag message',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': '$_email\nsecretclient'};
        Future<ScriptResult> scan(String repo) =>
            _leak(iso, ['--history', '$repo/.git'], env: env);

        _expectClean(
          await scan(await _cleanRepo(iso, 'clean')),
          what: 'clean repo',
        );

        final oldBlob = await _cleanRepo(iso, 'old-blob');
        await _commit(iso, oldBlob, {
          'notes.txt': 'vault at ${_stranger}vault\n',
        }, 'add notes');
        await _commit(iso, oldBlob, {
          'notes.txt': 'vault at ~/vault\n',
        }, 'tidy notes');
        _expectLeak(
          await scan(oldBlob),
          hidden: [_stranger, _strangerName],
          what: 'old blob',
        );

        final path = await _cleanRepo(iso, 'path');
        await _commit(iso, path, {
          'docs/secretclient/plan.md': 'plan\n',
        }, 'add plan');
        _expectLeak(
          await scan(path),
          hidden: ['secretclient'],
          what: 'file path',
        );

        final message = await _cleanRepo(iso, 'message');
        await _commit(iso, message, {
          'm.txt': 'm\n',
        }, 'fix crash in ${_stranger}code/app');
        final messageHit = await scan(message);
        _expectLeak(
          messageHit,
          hidden: [_stranger, _strangerName],
          what: 'commit message',
        );
        expect(
          messageHit.stdout,
          contains('fix crash in ${leakPath('[redacted]')}code/app'),
          reason: 'the whole user name is redacted\n$messageHit',
        );

        final author = await _cleanRepo(iso, 'author');
        await _commit(
          iso,
          author,
          {'a.txt': 'a\n'},
          'authored',
          env: {'GIT_AUTHOR_EMAIL': _email.toUpperCase()},
        );
        _expectLeak(await scan(author), hidden: [_email], what: 'author email');

        final committer = await _cleanRepo(iso, 'committer');
        await _commit(
          iso,
          committer,
          {'c.txt': 'c\n'},
          'committed',
          env: {'GIT_COMMITTER_EMAIL': _email},
        );
        _expectLeak(
          await scan(committer),
          hidden: [_email],
          what: 'committer email',
        );

        final tag = await _cleanRepo(iso, 'tag');
        await runGit(iso, tag, [
          'tag',
          '-a',
          'v0.1.0',
          '-m',
          'notes for ${_stranger}release',
        ]);
        _expectLeak(
          await scan(tag),
          hidden: [_stranger, _strangerName],
          what: 'tag message',
        );
      },
    );

    test(
      'history mode flags a tagger email and an author name from the deny-list',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': '$_email\nJo Private'};
        Future<ScriptResult> scan(String repo) =>
            _leak(iso, ['--history', '$repo/.git'], env: env);

        final tagger = await _cleanRepo(iso, 'tagger');
        await runGit(
          iso,
          tagger,
          ['tag', '-a', 'v0.1.0', '-m', 'clean notes'],
          env: {'GIT_COMMITTER_EMAIL': _email},
        );
        _expectLeak(await scan(tagger), hidden: [_email], what: 'tagger email');

        final name = await _cleanRepo(iso, 'name');
        await _commit(
          iso,
          name,
          {'n.txt': 'n\n'},
          'named',
          env: {'GIT_AUTHOR_NAME': 'Jo Private'},
        );
        _expectLeak(
          await scan(name),
          hidden: ['Jo Private'],
          what: 'author name',
        );
      },
    );

    test(
      'history mode scans commits reachable only from another branch',
      () async {
        final iso = await isolatedEnv();
        final repo = await _cleanRepo(iso, 'branches');
        await runGit(iso, repo, ['checkout', '-q', '-b', 'side']);
        await _commit(iso, repo, {
          'side.txt': 'see ${_stranger}side\n',
        }, 'side work');
        await runGit(iso, repo, ['checkout', '-q', 'main']);
        final r = await _leak(
          iso,
          ['--history', '$repo/.git'],
          env: {'LEAK_PATTERNS': _email},
        );
        _expectLeak(r, hidden: [_stranger, _strangerName], what: 'side branch');
      },
    );
  });

  group('artifact mode', () {
    test(
      'artifact mode flags a leak inside a binary inside a zip entry and inside a DMG file and detaches the DMG',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final leak = '${_stranger}build/checkout/app.dart';

        final cleanBin = await _writeBytes(
          iso,
          'art/clean-tool',
          _binaryAround('/usr/lib/libc++.1.dylib'),
        );
        _expectClean(
          await _leak(iso, ['--artifact', cleanBin], env: env),
          what: 'clean binary',
        );

        final bin = await _writeBytes(iso, 'art/memex', _binaryAround(leak));
        _expectLeak(
          await _leak(iso, ['--artifact', bin], env: env),
          hidden: [_stranger, _strangerName],
          what: 'binary',
        );

        await _write(iso, 'zipsrc/memex/NOTICES.txt', _compressible(leak));
        final zip = await _zip(
          iso,
          '${iso.work.path}/zipsrc',
          '${iso.work.path}/art/memex-${_uniq()}.zip',
        );
        expect(
          _bytesContain(File(zip).readAsBytesSync(), utf8.encode(_stranger)),
          isFalse,
          reason:
              'fixture: the raw zip must not hold the leak, so only an inside scan finds it',
        );
        _expectLeak(
          await _leak(iso, ['--artifact', zip], env: env),
          hidden: [_stranger, _strangerName],
          what: 'zip entry',
        );

        await _write(
          iso,
          'dmgsrc/Open Memex.app/Contents/Resources/config.txt',
          _compressible(leak),
        );
        final dmg = await _dmg(
          iso,
          '${iso.work.path}/dmgsrc',
          '${iso.work.path}/art/fixture-${_uniq()}.dmg',
        );
        expect(
          _bytesContain(File(dmg).readAsBytesSync(), utf8.encode(_stranger)),
          isFalse,
          reason:
              'fixture: the raw DMG must not hold the leak, so only a mounted scan finds it',
        );
        _expectLeak(
          await _leak(iso, ['--artifact', dmg], env: env),
          hidden: [_stranger, _strangerName],
          what: 'DMG file',
        );
        expect(
          await _dmgAttached(iso, dmg),
          isFalse,
          reason: 'the DMG is still attached after the scan',
        );

        await _write(
          iso,
          'dmgclean/Open Memex.app/Contents/Resources/config.txt',
          _compressible('fine'),
        );
        final cleanDmg = await _dmg(
          iso,
          '${iso.work.path}/dmgclean',
          '${iso.work.path}/art/clean-${_uniq()}.dmg',
        );
        _expectClean(
          await _leak(iso, ['--artifact', cleanDmg], env: env),
          what: 'clean DMG',
        );
        expect(
          await _dmgAttached(iso, cleanDmg),
          isFalse,
          reason: 'the clean DMG is still attached after the scan',
        );
      },
    );

    test('artifact mode scans an app bundle and a zip inside it', () async {
      final iso = await isolatedEnv();
      final env = {'LEAK_PATTERNS': _email};
      final app = '${iso.work.path}/Open Memex.app';
      await _writeBytes(
        iso,
        'Open Memex.app/Contents/MacOS/Open Memex',
        _binaryAround('/usr/lib/libobjc.A.dylib'),
      );
      _expectClean(
        await _leak(iso, ['--artifact', app], env: env),
        what: 'clean app',
      );

      await _write(iso, 'inner/data.txt', _compressible('${_stranger}x'));
      await Directory('$app/Contents/Resources').create(recursive: true);
      await _zip(
        iso,
        '${iso.work.path}/inner',
        '$app/Contents/Resources/bundle.zip',
      );
      _expectLeak(
        await _leak(iso, ['--artifact', app], env: env),
        hidden: [_stranger, _strangerName],
        what: 'zip inside app',
      );
    });

    test('artifact mode checks every path it is given', () async {
      final iso = await isolatedEnv();
      final env = {'LEAK_PATTERNS': _email};
      final a = await _writeBytes(iso, 'a.bin', _binaryAround('fine'));
      final b = await _writeBytes(
        iso,
        'b.bin',
        _binaryAround(_email.toUpperCase()),
      );
      final last = await _leak(iso, ['--artifact', a, b], env: env);
      _expectLeak(last, hidden: [_email], what: 'second path');
      expect(
        _hits(last).map((m) => m.group(1)!.split('/').last.split(':').first),
        everyElement(startsWith('b.bin')),
        reason: 'only the second path leaks\n$last',
      );
      // The leaking path first: a loop that skips its first path misses it.
      final first = await _leak(iso, ['--artifact', b, a], env: env);
      _expectLeak(first, hidden: [_email], what: 'first path');
      expect(
        _hits(first).map((m) => m.group(1)!.split('/').last.split(':').first),
        everyElement(startsWith('b.bin')),
        reason: 'only the first path leaks\n$first',
      );
      // Three paths, the leak in the middle.
      final c = await _writeBytes(iso, 'c.bin', _binaryAround('fine'));
      _expectLeak(
        await _leak(iso, ['--artifact', a, b, c], env: env),
        hidden: [_email],
        what: 'middle path',
      );
    });
  });

  group('output detail', () {
    test(
      'every hit line names its rule and its line number or byte offset',
      () async {
        final iso = await isolatedEnv();
        final home = '${iso.home}/vault';
        final f = await _write(
          iso,
          'rules.txt',
          'one\nhome $home here\ntwo\nuser ${_stranger}x\nmail $_email\n',
        );
        final r = await _leak(
          iso,
          ['--text', f],
          env: {'LEAK_PATTERNS': _email},
        );
        expect(r.exitCode, 1, reason: '$r');
        final pairs = _hits(
          r,
        ).map((m) => '${m.group(2)}:${m.group(3)}').toSet();
        expect(pairs, {
          '2:HOME',
          '4:home-path',
          '5:deny-list',
        }, reason: 'each line names exactly the rule it hit\n$r');
        _expectHidden(r, [_stranger, _strangerName, _email], 'rule tokens');

        final bytes = [
          ...utf8.encode('abc\n'),
          ..._binaryAround('${_stranger}x'),
        ];
        await _writeBytes(iso, 'bintree/blob.bin', bytes);
        final bin = await _leak(iso, [
          '--tree',
          '${iso.work.path}/bintree',
          '--allow-empty-patterns',
        ]);
        _expectLeak(
          bin,
          hidden: [_stranger, _strangerName],
          what: 'binary offset',
        );
        expect(
          _hits(bin).any(
            (m) =>
                m.group(1)!.endsWith('blob.bin') &&
                m.group(2) == '22' &&
                m.group(3) == 'home-path',
          ),
          isTrue,
          reason: 'the name starts at byte 22 (4 + 11 + 7)\n$bin',
        );
        expect(bin.stdout, contains('[byte offset]'), reason: '$bin');
      },
    );

    test(
      'diff mode reports the new file name and the new line number of each added line',
      () async {
        final iso = await isolatedEnv();
        final diff = [
          'diff --git a/notes.md b/notes.md',
          'index 1111111..2222222 100644',
          '--- a/notes.md',
          '+++ b/notes.md',
          '@@ -10,2 +20,3 @@',
          ' ctx',
          '+first ${_stranger}a',
          ' tail',
          '@@ -50,1 +60,2 @@',
          ' ctx two',
          '+second ${_stranger}b',
          '',
        ].join('\n');
        final f = await _write(iso, 'lines.diff', diff);
        final r = await _leak(iso, ['--diff', f, '--allow-empty-patterns']);
        _expectLeak(r, hidden: [_stranger, _strangerName], what: 'diff lines');
        final pairs = _hits(
          r,
        ).map((m) => '${m.group(1)}:${m.group(2)}').toSet();
        expect(pairs, {'notes.md:21', 'notes.md:61'}, reason: '$r');
      },
    );

    test(
      'a deny-list entry that holds a home path is redacted whole and overlapping hits merge',
      () async {
        final iso = await isolatedEnv();
        // The entry also trips rule c, so two hits overlap on one line.
        final entry = '${_stranger}secretproj';
        final f1 = await _write(iso, 'overlap.txt', 'x $entry/y z\n');
        final r1 = await _leak(
          iso,
          ['--text', f1],
          env: {'LEAK_PATTERNS': entry},
        );
        _expectLeak(
          r1,
          hidden: [entry, 'stranger', 'secretproj'],
          what: 'nested',
        );
        expect(r1.stdout, contains('x [redacted]/y z'), reason: '$r1');
        expect(_hits(r1).map((m) => m.group(3)).toSet(), {
          'deny-list',
          'home-path',
        }, reason: '$r1');

        final a = ['', 'srv', 'alphabeta'].join('/');
        const b = 'betagamma';
        final f2 = await _write(iso, 'overlap2.txt', 'p ${a}gamma q\n');
        final r2 = await _leak(
          iso,
          ['--text', f2],
          env: {'LEAK_PATTERNS': '$a\n$b'},
        );
        _expectLeak(r2, hidden: [a, b, 'gamma', 'alphabeta'], what: 'partial');
        expect(r2.stdout, contains('p [redacted] q'), reason: '$r2');

        // Entries listed in the opposite order to where they occur.
        final first = ['', 'srv', 'first-secret'].join('/');
        final second = ['', 'srv', 'second-secret'].join('/');
        final f3 = await _write(
          iso,
          'order.txt',
          'A $second then $first end\n',
        );
        final r3 = await _leak(
          iso,
          ['--text', f3],
          env: {'LEAK_PATTERNS': '$first\n$second'},
        );
        _expectLeak(r3, hidden: [first, second], what: 'order');
        expect(
          r3.stdout,
          contains('A [redacted] then [redacted] end'),
          reason: '$r3',
        );
      },
    );

    test(
      'the location of a hit is redacted in a text path a tree path and a tree entry name',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};

        final text = await _write(
          iso,
          'secretclient/body.txt',
          'see secretclient\n',
        );
        final t = await _leak(iso, ['--text', text], env: env);
        _expectLeak(t, hidden: ['secretclient'], what: 'text location');
        expect(
          _hits(t).any((m) => m.group(1)!.endsWith('/[redacted]/body.txt')),
          isTrue,
          reason: '$t',
        );

        await _write(iso, 'loc/secretclient/inner.txt', 'fine\n');
        final tree = await _leak(iso, [
          '--tree',
          '${iso.work.path}/loc',
        ], env: env);
        _expectLeak(tree, hidden: ['secretclient'], what: 'tree location');
        expect(
          _hits(tree).every((m) => m.group(1)!.contains('/loc/[redacted]')),
          isTrue,
          reason: '$tree',
        );
        expect(
          _hits(tree).any((m) => m.group(1)!.endsWith('(name)')),
          isTrue,
          reason: 'the directory name is reported\n$tree',
        );
      },
    );
  });

  group('names and links', () {
    test(
      'tree and artifact modes flag a leak in an entry name and in a symlink target',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        final w = iso.work.path;

        await _write(iso, 'cleantree/readme.md', 'fine\n');
        Link('$w/cleantree/ok-link').createSync('../elsewhere');
        _expectClean(
          await _leak(iso, ['--tree', '$w/cleantree'], env: env),
          what: 'clean tree with a clean link',
        );

        await _write(iso, 'nametree/secretclient.txt', 'fine\n');
        final byName = await _leak(iso, ['--tree', '$w/nametree'], env: env);
        _expectLeak(byName, hidden: ['secretclient'], what: 'file name');
        expect(
          _hits(byName).any(
            (m) =>
                m.group(1)!.endsWith('(name)') &&
                m.group(2) == '1' &&
                m.group(3) == 'deny-list',
          ),
          isTrue,
          reason: '$byName',
        );

        await _write(iso, 'linktree/readme.md', 'fine\n');
        Link('$w/linktree/lnk').createSync('${_stranger}project');
        final byLink = await _leak(iso, [
          '--tree',
          '$w/linktree',
          '--allow-empty-patterns',
        ]);
        _expectLeak(
          byLink,
          hidden: [_stranger, _strangerName],
          what: 'symlink target',
        );
        expect(
          _hits(byLink).any(
            (m) => m.group(1)!.endsWith('/lnk (symlink)') && m.group(2) == '1',
          ),
          isTrue,
          reason: '$byLink',
        );

        final app = '$w/Open Memex.app';
        await _writeBytes(
          iso,
          'Open Memex.app/Contents/MacOS/Open Memex',
          _binaryAround('/usr/lib/libobjc.A.dylib'),
        );
        _expectClean(
          await _leak(iso, ['--artifact', app], env: env),
          what: 'clean app',
        );
        await _write(
          iso,
          'Open Memex.app/Contents/Frameworks/secretclient.dylib',
          'x',
        );
        final appName = await _leak(iso, ['--artifact', app], env: env);
        _expectLeak(appName, hidden: ['secretclient'], what: 'app entry name');
        expect(
          _hits(appName).any((m) => m.group(1)!.endsWith('(name)')),
          isTrue,
          reason: '$appName',
        );

        final app2 = '$w/Other.app';
        await _writeBytes(
          iso,
          'Other.app/Contents/MacOS/Other',
          _binaryAround('x'),
        );
        Link('$app2/Contents/lnk').createSync('${_stranger}build');
        final appLink = await _leak(iso, [
          '--artifact',
          app2,
          '--allow-empty-patterns',
        ]);
        _expectLeak(
          appLink,
          hidden: [_stranger, _strangerName],
          what: 'app symlink target',
        );
        expect(
          _hits(appLink).any((m) => m.group(1)!.endsWith('/lnk (symlink)')),
          isTrue,
          reason: '$appLink',
        );
      },
    );

    test(
      'a symlinked tree or artifact root is read through and links below it are never followed',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final w = iso.work.path;

        await _write(iso, 'real/f.txt', 'path ${_stranger}x\n');
        Link('$w/lnk-dir').createSync('$w/real');
        final tree = await _leak(iso, ['--tree', '$w/lnk-dir'], env: env);
        _expectLeak(
          tree,
          hidden: [_stranger, _strangerName],
          what: 'symlinked tree root',
        );
        expect(
          _hits(tree).any((m) => m.group(1)!.startsWith('$w/lnk-dir')),
          isTrue,
          reason: 'labelled with the path as given\n$tree',
        );
        _expectLeak(
          await _leak(iso, ['--artifact', '$w/lnk-dir'], env: env),
          hidden: [_stranger, _strangerName],
          what: 'symlinked artifact dir',
        );

        final bin = await _writeBytes(
          iso,
          'realbin/memex',
          _binaryAround('${_stranger}x'),
        );
        Link('$w/lnk-bin').createSync(bin);
        _expectLeak(
          await _leak(iso, ['--artifact', '$w/lnk-bin'], env: env),
          hidden: [_stranger, _strangerName],
          what: 'symlinked binary',
        );

        await _write(iso, 'zipsrc/data.txt', _compressible('${_stranger}x'));
        final zip = await _zip(iso, '$w/zipsrc', '$w/realbin/pack.zip');
        Link('$w/lnk-zip').createSync(zip);
        _expectLeak(
          await _leak(iso, ['--artifact', '$w/lnk-zip'], env: env),
          hidden: [_stranger, _strangerName],
          what: 'symlinked zip',
        );

        // A link below the root is not followed (a link to / would otherwise
        // scan the machine).
        await _write(iso, 'outside/leaky.txt', 'path ${_stranger}x\n');
        await _write(iso, 'below/clean.txt', 'fine\n');
        Link('$w/below/out').createSync('../outside');
        _expectClean(
          await _leak(iso, ['--tree', '$w/below'], env: env),
          what: 'link below the root',
        );
        _expectLeak(
          await _leak(iso, ['--tree', '$w/outside'], env: env),
          hidden: [_stranger, _strangerName],
          what: 'the linked directory itself',
        );
      },
    );

    test(
      'HOME is matched as given with a trailing slash and with symlinks resolved and a HOME of slash matches nothing',
      () async {
        final iso = await isolatedEnv();
        final w = iso.work.path;
        await Directory('$w/realhome').create();
        Link('$w/homelink').createSync('$w/realhome');
        final real = Directory('$w/realhome').resolveSymbolicLinksSync();
        final viaLink = '$w/homelink';

        for (final c in [
          ('as-given', '$viaLink/docs', viaLink),
          ('resolved', '$real/docs', viaLink),
          // HOME ends in a slash, the text does not: only the slash trim
          // lets the HOME rule hit it.
          ('trailing-slash', viaLink, '$viaLink/'),
        ]) {
          final f = await _write(iso, 'home-${c.$1}.txt', 'at ${c.$2}\n');
          final r = await _leak(
            iso,
            ['--text', f, '--allow-empty-patterns'],
            env: {'HOME': c.$3},
          );
          _expectLeak(r, hidden: [c.$2], what: 'HOME ${c.$1}');
          expect(
            _hits(r).any((m) => m.group(3) == 'HOME'),
            isTrue,
            reason: '${c.$1}\n$r',
          );
        }

        final f = await _write(iso, 'root-home.txt', 'at /usr/bin/tool\n');
        _expectClean(
          await _leak(
            iso,
            ['--text', f, '--allow-empty-patterns'],
            env: {'HOME': '/'},
          ),
          what: 'HOME is slash',
        );
      },
    );
  });

  group('diff mode paths and binary files', () {
    String textDiff(String path) => [
      'diff --git a/$path b/$path',
      'index 1111111..2222222 100644',
      '--- a/$path',
      '+++ b/$path',
      '@@ -1 +1 @@',
      '-old',
      '+new',
      '',
    ].join('\n');

    String binDiff(String path, String kind) {
      switch (kind) {
        case 'added':
          return [
            'diff --git a/$path b/$path',
            'new file mode 100644',
            'index 0000000..2222222',
            'Binary files /dev/null and b/$path differ',
            '',
          ].join('\n');
        case 'deleted':
          return [
            'diff --git a/$path b/$path',
            'deleted file mode 100644',
            'index 1111111..0000000',
            'Binary files a/$path and /dev/null differ',
            '',
          ].join('\n');
        case 'patch':
          return [
            'diff --git a/$path b/$path',
            'new file mode 100644',
            'index 0000000..2222222',
            'GIT binary patch',
            'literal 4',
            'LcmZQzU|?VZ0001vw1fo',
            '',
            'literal 0',
            'HcmV?d00001',
            '',
            '',
          ].join('\n');
        case 'headerless':
          return 'Binary files /dev/null and b/$path differ\n';
        default:
          return [
            'diff --git a/$path b/$path',
            'index 1111111..2222222 100644',
            'Binary files a/$path and b/$path differ',
            '',
          ].join('\n');
      }
    }

    const kinds = ['modified', 'added', 'patch', 'headerless'];

    // A clean text section first, except for the headerless entry: it has no
    // "diff --git" line, so it would read as part of the section before it.
    String withText(String bin, String kind) =>
        kind == 'headerless' ? bin : '${textDiff('notes.md')}$bin';

    test(
      'a binary file in a diff warns on stderr with its path and leaves the exit status unchanged',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        for (final kind in kinds) {
          final f = await _write(
            iso,
            'bin-$kind.diff',
            withText(binDiff('img.png', kind), kind),
          );
          final r = await _leak(iso, ['--diff', f], env: env);
          expect(r.exitCode, 0, reason: '$kind\n$r');
          expect(_hits(r), isEmpty, reason: '$kind\n$r');
          expect(
            r.stderr,
            contains('LEAK WARN: binary file not scanned: img.png'),
            reason: kind,
          );
        }

        // The same text hunk without a binary entry: no warning.
        final textOnly = await _write(
          iso,
          'text-only.diff',
          textDiff('notes.md'),
        );
        final t = await _leak(iso, ['--diff', textOnly], env: env);
        expect(t.exitCode, 0, reason: '$t');
        expect(
          t.stderr,
          isNot(contains('binary file not scanned')),
          reason: '$t',
        );
      },
    );

    test(
      'a leaking path of an added or modified binary file in a diff is a leak and is shown redacted in the warning',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        const path = 'assets/secretclient/img.png';
        for (final kind in kinds) {
          final f = await _write(
            iso,
            'leaky-$kind.diff',
            withText(binDiff(path, kind), kind),
          );
          final r = await _leak(iso, ['--diff', f], env: env);
          _expectLeak(r, hidden: ['secretclient'], what: kind);
          expect(
            _hits(r).any(
              (m) =>
                  m.group(1) == 'assets/[redacted]/img.png (name)' &&
                  m.group(2) == '1' &&
                  m.group(3) == 'deny-list',
            ),
            isTrue,
            reason: '$kind\n$r',
          );
          expect(
            r.stderr,
            contains(
              'LEAK WARN: binary file not scanned: assets/[redacted]/img.png',
            ),
            reason: kind,
          );
        }
      },
    );

    test(
      'a deleted binary file in a diff is neither warned about nor flagged',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        final f = await _write(
          iso,
          'deleted.diff',
          '${binDiff('assets/secretclient/old.png', 'deleted')}${binDiff('keep.png', 'added')}',
        );
        final r = await _leak(iso, ['--diff', f], env: env);
        expect(r.exitCode, 0, reason: '$r');
        expect(_hits(r), isEmpty, reason: '$r');
        expect(
          r.stderr,
          contains('LEAK WARN: binary file not scanned: keep.png'),
          reason: '$r',
        );
        expect(r.stderr, isNot(contains('old.png')), reason: '$r');
      },
    );

    test(
      'diff mode flags a leaking path of an added file a renamed file and a copied file but not a deleted one',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        const dir = 'docs/secretclient';
        final cases = <String, List<String>>{
          'added': [
            'diff --git a/$dir/new.md b/$dir/new.md',
            'new file mode 100644',
            'index 0000000..2222222',
            '--- /dev/null',
            '+++ b/$dir/new.md',
            '@@ -0,0 +1 @@',
            '+hello',
            '',
          ],
          'renamed': [
            'diff --git a/old.md b/$dir/moved.md',
            'similarity index 100%',
            'rename from old.md',
            'rename to $dir/moved.md',
            '',
          ],
          'copied': [
            'diff --git a/old.md b/$dir/copy.md',
            'similarity index 100%',
            'copy from old.md',
            'copy to $dir/copy.md',
            '',
          ],
        };
        for (final e in cases.entries) {
          final f = await _write(iso, '${e.key}.diff', e.value.join('\n'));
          final r = await _leak(iso, ['--diff', f], env: env);
          _expectLeak(r, hidden: ['secretclient'], what: e.key);
          expect(
            _hits(r).any(
              (m) =>
                  m.group(1)!.startsWith('docs/[redacted]/') &&
                  m.group(1)!.endsWith('.md (name)') &&
                  m.group(3) == 'deny-list',
            ),
            isTrue,
            reason: '${e.key}\n$r',
          );
        }

        final deleted = await _write(
          iso,
          'deleted-text.diff',
          [
            'diff --git a/$dir/gone.md b/$dir/gone.md',
            'deleted file mode 100644',
            'index 1111111..0000000',
            '--- a/$dir/gone.md',
            '+++ /dev/null',
            '@@ -1 +0,0 @@',
            '-hello',
            '',
          ].join('\n'),
        );
        final d = await _leak(iso, ['--diff', deleted], env: env);
        expect(d.exitCode, 0, reason: '$d');
        expect(_hits(d), isEmpty, reason: '$d');
      },
    );
  });

  group('history mode objects as stored', () {
    test(
      'a replace ref does not hide a leaky commit from history mode',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final repo = await _cleanRepo(iso, 'replaced');
        await _commit(iso, repo, {
          'leaky.txt': 'path ${_stranger}vault\n',
        }, 'add leaky file');
        final leakySha = (await runGit(iso, repo, [
          'rev-parse',
          'HEAD',
        ])).stdout.trim();
        final cleanSha = (await runGit(iso, repo, [
          'rev-parse',
          'HEAD~1',
        ])).stdout.trim();
        // With the replacement, HEAD reads as the clean commit.
        await runGit(iso, repo, ['replace', leakySha, cleanSha]);
        final shown = await runGit(iso, repo, [
          'ls-tree',
          '-r',
          '--name-only',
          'HEAD',
        ]);
        expect(
          shown.stdout,
          isNot(contains('leaky.txt')),
          reason: 'fixture: the replace ref hides the leaky file from HEAD',
        );
        _expectLeak(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          hidden: [_stranger, _strangerName],
          what: 'replaced commit',
        );
      },
    );

    test(
      'a repository with an info grafts file exits 2 instead of scanning a rewritten history',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final repo = await _cleanRepo(iso, 'grafted');
        await _commit(iso, repo, {'more.txt': 'more\n'}, 'third commit');
        _expectClean(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          what: 'before the graft file',
        );
        final head = (await runGit(iso, repo, [
          'rev-parse',
          'HEAD',
        ])).stdout.trim();
        await _write(iso, 'grafted/.git/info/grafts', '$head\n');
        final r = await _leak(iso, ['--history', '$repo/.git'], env: env);
        expect(r.exitCode, 2, reason: '$r');
        expect(_hits(r), isEmpty, reason: '$r');
        expect(r.stderr, contains('grafts'), reason: '$r');
      },
    );

    test(
      'history mode flags a file path that only the root commit adds when the user config hides root commits',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        final repo = await _makeRepo(iso, 'rootpath');
        await _commit(iso, repo, {
          'secretclient/plan.md': 'plan\n',
        }, 'root commit');
        await _commit(iso, repo, {'other.txt': 'other\n'}, 'second commit');
        await runGit(iso, repo, ['config', 'log.showRoot', 'false']);
        await runGit(iso, repo, ['config', 'diff.relative', 'true']);
        _expectLeak(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          hidden: ['secretclient'],
          what: 'root commit path',
        );
      },
    );
  });

  group('incomplete scans', () {
    test(
      'a corrupt zip and a corrupt DMG exit 2 even when another path leaks',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final good = await _writeBytes(iso, 'good.bin', _binaryAround('fine'));
        final leaky = await _writeBytes(
          iso,
          'leaky.bin',
          _binaryAround(_email),
        );
        _expectLeak(
          await _leak(iso, ['--artifact', leaky], env: env),
          hidden: [_email],
          what: 'the leaky path alone',
        );
        final badZip = await _write(
          iso,
          'bad.zip',
          'this is not a zip archive\n',
        );
        final badDmg = await _write(
          iso,
          'bad.dmg',
          'this is not a disk image\n',
        );

        for (final bad in [badZip, badDmg]) {
          final alone = await _leak(iso, ['--artifact', bad], env: env);
          expect(alone.exitCode, 2, reason: '$bad\n$alone');
          expect(_hits(alone), isEmpty, reason: '$alone');
          expect(
            alone.stderr,
            contains('the scan did not complete'),
            reason: '$alone',
          );
          final both = await _leak(iso, [
            '--artifact',
            good,
            bad,
            leaky,
          ], env: env);
          expect(both.exitCode, 2, reason: '$bad\n$both');
          expect(
            both.stderr,
            contains('the scan did not complete'),
            reason: '$both',
          );
          _expectHidden(both, [_email], 'incomplete scan');
        }
      },
    );

    test(
      'an unreadable file in a tree exits 2 even when another file leaks',
      () async {
        final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
        if (uid == '0') {
          markTestSkipped('chmod 000 does not stop root from reading');
          return;
        }
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final tree = '${iso.work.path}/locked';
        await _write(iso, 'locked/ok.txt', 'fine\n');
        final secret = await _write(iso, 'locked/secret.txt', 'fine\n');
        await runTool(iso, 'chmod', ['000', secret], workingDirectory: tree);
        addTearDown(() => Process.run('chmod', ['644', secret]));

        final r = await _leak(iso, ['--tree', tree], env: env);
        expect(r.exitCode, 2, reason: '$r');
        expect(_hits(r), isEmpty, reason: '$r');
        expect(r.stderr, contains('the scan did not complete'), reason: '$r');

        await _write(iso, 'locked/other.txt', 'mail ${_email.toUpperCase()}\n');
        final both = await _leak(iso, ['--tree', tree], env: env);
        expect(both.exitCode, 2, reason: 'incomplete beats leak\n$both');
        expect(
          both.stderr,
          contains('the scan did not complete'),
          reason: '$both',
        );
        _expectHidden(both, [_email], 'unreadable file and a leak');
      },
    );
  });

  group('review round 2: home names', () {
    test(
      'rule c flags user names with spaces or non-ASCII characters and ignores placeholders that are not names',
      () async {
        final iso = await isolatedEnv();
        final names = ['John Smith', 'jörg', 'Ünal Çelik'];
        for (var i = 0; i < names.length; i++) {
          final name = names[i];
          final f = await _write(
            iso,
            'names/n$i.txt',
            'open ${leakPath(name)}Documents/x\n',
          );
          final r = await _leak(iso, ['--text', f, '--allow-empty-patterns']);
          _expectLeak(r, hidden: [name, leakPath(name)], what: name);
          expect(
            r.stdout,
            contains('open ${leakPath('[redacted]')}Documents/x'),
            reason: 'the whole name is redacted\n$r',
          );
          expect(_hits(r).map((m) => m.group(3)).toSet(), {
            'home-path',
          }, reason: '$r');
        }

        final plain = await _write(
          iso,
          'names/not-names.txt',
          [
            'a ${leakPath('<name>')}x',
            'b ${leakPath(r'$USER')}x',
            'c ${leakPath('*')}x',
            'd ${leakPath('{user}')}x',
            'e ${leakPath('%USERNAME%')}x',
            'f see ${leakPath('')}and ${['', 'home', ''].join('/')}as roots',
            'g ${leakPath(' padded ')}x',
            '',
          ].join('\n'),
        );
        _expectClean(
          await _leak(iso, ['--text', plain, '--allow-empty-patterns']),
          what: 'placeholders that are not names',
        );
      },
    );

    test(
      'rule c finds a home path nested in another one and redacts both names',
      () async {
        final iso = await isolatedEnv();
        // The first name is "home": the path that starts at its trailing
        // slash is a second home path, with its own name.
        final inner = await _write(
          iso,
          'nested-home.txt',
          'x ${leakPath('home')}stranger/y\n',
        );
        final r = await _leak(iso, ['--text', inner, '--allow-empty-patterns']);
        _expectLeak(r, hidden: [_strangerName], what: 'nested home path');
        expect(
          r.stdout,
          contains('x ${leakPath('[redacted]')}[redacted]/y'),
          reason: 'both names are redacted\n$r',
        );

        // The first name is allow-listed, so only the nested one leaks.
        final allowed = await _write(
          iso,
          'nested-allowed.txt',
          'x ${leakPath('test')}Users/stranger/y\n',
        );
        final r2 = await _leak(iso, [
          '--text',
          allowed,
          '--allow-empty-patterns',
        ]);
        _expectLeak(r2, hidden: [_strangerName], what: 'nested after allowed');
        expect(
          r2.stdout,
          contains('x ${leakPath('test')}Users/[redacted]/y'),
          reason: 'only the nested name is redacted\n$r2',
        );
      },
    );

    test(
      'a name that starts with a dot is not a user name while a dot-free unlisted name under home still exits 1',
      () async {
        final iso = await isolatedEnv();
        final cargo = ['', 'fake', 'home', '.cargo', 'bin', 'memex'].join('/');
        final dots = await _write(
          iso,
          'dots.txt',
          'run $cargo\nsee ${leakPath('.hidden')}x\nsee ${['', 'home', '..', ''].join('/')}x\n',
        );
        _expectClean(
          await _leak(iso, ['--text', dots, '--allow-empty-patterns']),
          what: 'dot names',
        );

        final mixed = await _write(
          iso,
          'dots-mixed.txt',
          'run $cargo\nopen ${_homeStranger}notes\nname ${['', 'home', 'foo.bar', ''].join('/')}x\n',
        );
        final r = await _leak(iso, ['--text', mixed, '--allow-empty-patterns']);
        _expectLeak(r, hidden: [_strangerName, 'foo.bar'], what: 'mixed');
        expect(_hits(r).map((m) => m.group(2)).toSet(), {
          '2',
          '3',
        }, reason: 'only the dot-free names leak\n$r');
      },
    );
  });

  group('review round 2: diff input', () {
    Future<String> gitDiff(
      IsolatedEnv iso,
      String repo,
      List<String> args, {
      String? config,
    }) async => (await runGit(iso, repo, [
      if (config != null) ...['-c', config],
      'diff',
      ...args,
    ])).stdout;

    test(
      'diff mode reads colourised git diff output and flags the added line',
      () async {
        final iso = await isolatedEnv();
        final repo = await _makeRepo(iso, 'colour');
        await _commit(iso, repo, {'notes.txt': 'hello\n'}, 'first');
        await File(
          '$repo/notes.txt',
        ).writeAsString('hello\nsee ${_stranger}x\n');
        final colour = await gitDiff(iso, repo, ['--color=always']);
        expect(
          colour.contains('\u001b['),
          isTrue,
          reason: 'fixture: the diff must hold colour codes',
        );
        final f = await _write(iso, 'colour.diff', colour);
        final r = await _leak(iso, ['--diff', f, '--allow-empty-patterns']);
        _expectLeak(r, hidden: [_stranger, _strangerName], what: 'colour diff');
        expect(
          _hits(r).any(
            (m) =>
                m.group(1)!.endsWith('notes.txt') &&
                m.group(2) == '2' &&
                m.group(3) == 'home-path',
          ),
          isTrue,
          reason: 'the added line is notes.txt line 2\n$r',
        );

        // The same change with nothing leaked is clean in colour too.
        await File('$repo/notes.txt').writeAsString('hello\nfine\n');
        final clean = await _write(
          iso,
          'colour-clean.diff',
          await gitDiff(iso, repo, ['--color=always']),
        );
        _expectClean(
          await _leak(iso, ['--diff', clean, '--allow-empty-patterns']),
          what: 'clean colour diff',
        );
      },
    );

    test(
      'diff mode exits 2 on a word diff a combined diff and text that is not a diff while empty input exits 0',
      () async {
        final iso = await isolatedEnv();
        final repo = await _makeRepo(iso, 'words');
        await _commit(iso, repo, {'notes.txt': 'hello there\n'}, 'first');
        await File(
          '$repo/notes.txt',
        ).writeAsString('hello ${_stranger}x there\n');
        final word = await _write(
          iso,
          'word.diff',
          await gitDiff(iso, repo, ['--word-diff']),
        );
        final w = await _leak(iso, ['--diff', word, '--allow-empty-patterns']);
        expect(w.exitCode, 2, reason: 'word diff\n$w');
        expect(w.stderr, contains('--diff'), reason: '$w');
        _expectHidden(w, [_stranger, _strangerName], 'word diff');

        final combined = await _write(
          iso,
          'combined.diff',
          [
            'diff --cc notes.txt',
            'index 1111111,2222222..3333333',
            '--- a/notes.txt',
            '+++ b/notes.txt',
            '@@@ -1,1 -1,1 +1,2 @@@',
            '  hello',
            '++see ${_stranger}x',
            '',
          ].join('\n'),
        );
        final c = await _leak(iso, [
          '--diff',
          combined,
          '--allow-empty-patterns',
        ]);
        expect(c.exitCode, 2, reason: 'combined diff\n$c');
        expect(c.stderr, contains('--diff'), reason: '$c');
        _expectHidden(c, [_stranger, _strangerName], 'combined diff');

        final prose = await _write(
          iso,
          'prose.txt',
          'This is a note, not a diff.\nit mentions ${_stranger}x\n',
        );
        final p = await _leak(iso, ['--diff', prose, '--allow-empty-patterns']);
        expect(p.exitCode, 2, reason: 'not a diff\n$p');
        expect(p.stderr, contains('--diff'), reason: '$p');
        _expectHidden(p, [_stranger, _strangerName], 'not a diff');

        for (final blank in ['', '\n\n']) {
          final e = await _write(iso, 'blank.diff', blank);
          _expectClean(
            await _leak(iso, ['--diff', e, '--allow-empty-patterns']),
            what: 'empty input ${blank.length}',
          );
        }
        final viaStdin = await _leak(iso, [
          '--diff',
          '-',
          '--allow-empty-patterns',
        ], stdin: '');
        _expectClean(viaStdin, what: 'empty stdin');
      },
    );

    test(
      'diff mode flags the path of an empty added file under diff.noprefix and diff.mnemonicPrefix',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': 'secretclient'};
        final repo = await _makeRepo(iso, 'prefixes');
        await _commit(iso, repo, {'README.md': 'hello\n'}, 'first');
        await Directory('$repo/docs/secretclient').create(recursive: true);
        await File('$repo/docs/secretclient/empty.txt').writeAsString('');
        await File('$repo/docs/clean.txt').writeAsString('');
        await runGit(iso, repo, ['add', '-A']);

        for (final cfg in ['diff.noprefix=true', 'diff.mnemonicPrefix=true']) {
          final diff = await gitDiff(iso, repo, ['--cached'], config: cfg);
          final f = await _write(iso, 'prefix-$cfg.diff', diff);
          final r = await _leak(iso, ['--diff', f], env: env);
          _expectLeak(r, hidden: ['secretclient'], what: cfg);
          expect(
            _hits(r).any((m) => m.group(1)!.contains('(name)')),
            isTrue,
            reason: '$cfg: the path is reported as a name\n$r',
          );
        }

        // The same prefixes without a leaking path stay clean.
        await runGit(iso, repo, [
          'rm',
          '-q',
          '-r',
          '--cached',
          'docs/secretclient',
        ]);
        for (final cfg in ['diff.noprefix=true', 'diff.mnemonicPrefix=true']) {
          final diff = await gitDiff(iso, repo, ['--cached'], config: cfg);
          expect(diff, contains('clean.txt'), reason: 'fixture');
          final f = await _write(iso, 'prefix-clean-$cfg.diff', diff);
          _expectClean(
            await _leak(iso, ['--diff', f], env: env),
            what: '$cfg clean',
          );
        }
      },
    );
  });

  group('review round 2: history and artifacts', () {
    test(
      'history mode reads blobs as stored whatever info attributes or the user attributes file say',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final repo = await _cleanRepo(iso, 'attrs');
        await _commit(iso, repo, {
          'notes.txt': 'contact $_email today\n',
        }, 'add notes');
        _expectLeak(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          hidden: [_email],
          what: 'before any attribute',
        );

        // Re-encoded on checkout, the blob would hold UTF-16 text with a NUL
        // after every letter, and the deny-list entry would never match.
        // (The script names each blob file by its hash, so match every name.)
        await _write(
          iso,
          'attrs/.git/info/attributes',
          '* working-tree-encoding=UTF-16\n',
        );
        _expectLeak(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          hidden: [_email],
          what: 'info/attributes',
        );
        await File('$repo/.git/info/attributes').delete();

        final attrs = await _write(
          iso,
          'user-attributes',
          '* working-tree-encoding=UTF-16\n',
        );
        final cfg = File(iso.env['GIT_CONFIG_GLOBAL']!);
        await cfg.writeAsString(
          '[core]\n\tattributesFile = $attrs\n',
          mode: FileMode.append,
        );
        _expectLeak(
          await _leak(iso, ['--history', '$repo/.git'], env: env),
          hidden: [_email],
          what: 'core.attributesFile',
        );
      },
    );

    test(
      'artifact mode exits 2 on a zip whose entries share a name and scans a zip of distinct entries',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final leak = _compressible(_email);

        final distinct = await _writeBytes(
          iso,
          'zips/distinct.zip',
          _zipBytes([('first.txt', leak), ('second.txt', 'fine\n')]),
        );
        expect(
          _bytesContain(File(distinct).readAsBytesSync(), utf8.encode(_email)),
          isFalse,
          reason: 'fixture: the raw zip must not hold the leak',
        );
        _expectLeak(
          await _leak(iso, ['--artifact', distinct], env: env),
          hidden: [_email],
          what: 'distinct entries',
        );

        // Extraction would overwrite the leaky first entry with the clean
        // second one, and the deflated leak would go unseen.
        final same = await _writeBytes(
          iso,
          'zips/same.zip',
          _zipBytes([('data.txt', leak), ('data.txt', 'fine\n')]),
        );
        final r = await _leak(iso, ['--artifact', same], env: env);
        expect(r.exitCode, 2, reason: 'same name twice\n$r');
        expect(r.stderr, contains('collide'), reason: '$r');
        _expectHidden(r, [_email], 'colliding entries');

        // The leaky entry second and the clean one first: still incomplete.
        final reversed = await _writeBytes(
          iso,
          'zips/reversed.zip',
          _zipBytes([('data.txt', 'fine\n'), ('data.txt', leak)]),
        );
        final rr = await _leak(iso, ['--artifact', reversed], env: env);
        expect(rr.exitCode, 2, reason: 'same name twice, leak last\n$rr');
        _expectHidden(rr, [_email], 'colliding entries, leak last');

        // Names that differ only in case collide on a case-insensitive
        // volume and are two files on a case-sensitive one.
        final probe = File('${iso.work.path}/CaseProbe')..writeAsStringSync('');
        final insensitive = File('${iso.work.path}/caseprobe').existsSync();
        probe.deleteSync();
        final cased = await _writeBytes(
          iso,
          'zips/cased.zip',
          _zipBytes([('Data.txt', leak), ('data.txt', 'fine\n')]),
        );
        final rc = await _leak(iso, ['--artifact', cased], env: env);
        if (insensitive) {
          expect(rc.exitCode, 2, reason: 'names differing by case\n$rc');
          _expectHidden(rc, [_email], 'case collision');
        } else {
          _expectLeak(rc, hidden: [_email], what: 'case-sensitive volume');
        }
      },
    );

    test(
      'a DMG is attached read-only and nobrowse and detached from the same mountpoint on a clean and a leaky scan',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final wrap = Directory('${iso.root.path}/wrapbin')..createSync();
        final log = File('${iso.root.path}/hdiutil.log');
        final shim = File('${wrap.path}/hdiutil')
          ..writeAsStringSync(
            [
              '#!/bin/bash',
              'for a in "\$@"; do printf "%s\\t" "\$a" >> "${log.path}"; done',
              'printf "\\n" >> "${log.path}"',
              'exec /usr/bin/hdiutil "\$@"',
              '',
            ].join('\n'),
          );
        await Process.run('chmod', ['755', shim.path]);
        final scanEnv = {
          ...env,
          'PATH': '${wrap.path}:${Platform.environment['PATH']}',
        };

        await _write(
          iso,
          'dmgleak/Open Memex.app/Contents/Resources/config.txt',
          _compressible(_email),
        );
        await _write(
          iso,
          'dmgfine/Open Memex.app/Contents/Resources/config.txt',
          _compressible('fine'),
        );
        await Directory('${iso.work.path}/art').create();
        final leaky = await _dmg(
          iso,
          '${iso.work.path}/dmgleak',
          '${iso.work.path}/art/leaky-${_uniq()}.dmg',
        );
        final fine = await _dmg(
          iso,
          '${iso.work.path}/dmgfine',
          '${iso.work.path}/art/fine-${_uniq()}.dmg',
        );

        for (final (dmg, leaks) in [(leaky, true), (fine, false)]) {
          log.writeAsStringSync('');
          final r = await _leak(iso, ['--artifact', dmg], env: scanEnv);
          if (leaks) {
            _expectLeak(r, hidden: [_email], what: 'leaky DMG');
          } else {
            _expectClean(r, what: 'clean DMG');
          }
          final calls = log
              .readAsLinesSync()
              .map((l) => l.split('\t')..removeLast())
              .toList();
          final attach = calls.indexWhere((c) => c.first == 'attach');
          expect(attach, isNot(-1), reason: 'no attach call\n$calls');
          final args = calls[attach];
          expect(args, contains('-readonly'), reason: '$args');
          expect(args, contains('-nobrowse'), reason: '$args');
          expect(args, isNot(contains('-readwrite')), reason: '$args');
          // The script resolves the path (/var becomes /private/var).
          expect(args.last, endsWith(dmg.split('/').last), reason: '$args');
          final at = args.indexOf('-mountpoint');
          expect(at, isNot(-1), reason: '$args');
          final mount = args[at + 1];
          final detach = calls.indexWhere(
            (c) => c.first == 'detach' && c.contains(mount),
          );
          expect(
            detach,
            greaterThan(attach),
            reason: 'no detach of $mount after the attach\n$calls',
          );
          expect(await _dmgAttached(iso, dmg), isFalse, reason: dmg);
        }
      },
    );

    test(
      'a leaking archive name never appears in the error of an archive that cannot be read',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final bad = await _write(iso, 'art/x-$_email.zip', 'not a zip file\n');
        final r = await _leak(iso, ['--artifact', bad], env: env);
        expect(r.exitCode, 2, reason: '$r');
        expect(r.stderr, contains('could not unzip'), reason: '$r');
        expect(r.stderr, contains('[redacted]'), reason: '$r');
        _expectHidden(r, [_email], 'error about a leaking archive name');
      },
    );

    test(
      'history mode scans a work tree path and a linked worktree as well as a git dir',
      () async {
        final iso = await isolatedEnv();
        final env = {'LEAK_PATTERNS': _email};
        final repo = await _cleanRepo(iso, 'main-wt');
        await _commit(iso, repo, {'m.txt': 'm\n'}, 'mail $_email');
        _expectLeak(
          await _leak(iso, ['--history', repo], env: env),
          hidden: [_email],
          what: 'work tree path',
        );
        final linked = '${iso.work.path}/linked-wt';
        await runGit(iso, repo, [
          'worktree',
          'add',
          '-q',
          '-b',
          'side',
          linked,
        ]);
        _expectLeak(
          await _leak(iso, ['--history', linked], env: env),
          hidden: [_email],
          what: 'linked worktree',
        );
        final clean = await _cleanRepo(iso, 'clean-wt');
        _expectClean(
          await _leak(iso, ['--history', clean], env: env),
          what: 'clean work tree path',
        );
      },
    );
  });

  group('repo self-check', () {
    test(
      'tree mode over scripts and app/test/release with allow-empty-patterns exits 0',
      () async {
        final iso = await isolatedEnv();
        final root = repoRoot();
        for (final dir in ['scripts', 'app/test/release']) {
          final r = await _leak(iso, [
            '--tree',
            dir,
            '--allow-empty-patterns',
          ], workingDirectory: root);
          _expectClean(r, what: dir);
          expect(r.output, contains(_warn), reason: '$dir\n$r');
        }
      },
    );

    test('leak-check.sh is an executable bash script', () {
      final f = File('${repoRoot()}/$_script');
      expect(f.existsSync(), isTrue, reason: '$_script is missing');
      expect(
        f.statSync().mode & 0x49,
        0x49,
        reason: 'not executable by user, group and other',
      );
      final first = f.readAsLinesSync().first;
      expect(first.startsWith('#!'), isTrue);
      expect(first, contains('bash'));
    });

    test(
      'leak-allow.txt documents its syntax and lists the placeholder names and the ort prefix',
      () {
        final f = File('${repoRoot()}/scripts/leak-allow.txt');
        expect(
          f.existsSync(),
          isTrue,
          reason: 'scripts/leak-allow.txt is missing',
        );
        final lines = f.readAsLinesSync();
        expect(lines.first.startsWith('#'), isTrue, reason: 'header comment');
        final entries = lines
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .toList();
        expect(entries, containsAll(_placeholderNames));
        expect(entries, contains('prefix:$_ortPrefix'));
        for (final e in entries) {
          expect(
            e.startsWith('prefix:') || _placeholderNames.contains(e),
            isTrue,
            reason: 'unexpected entry $e',
          );
        }
      },
    );
  });
}
