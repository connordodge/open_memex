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

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _script = 'scripts/leak-check.sh';

/// `LEAK <file-or-ref>:<line-or-offset> <rule>` on stdout.
final _hitLine = RegExp(r'^LEAK (.+):(\d+) (\S+)', multiLine: true);

const _warn = 'LEAK WARN: no deny-list';

// Runtime-built fixtures (never literal in the source).
final _stranger = leakPath('stranger');
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
          hidden: [_stranger],
          what: 'Users path',
        );

        final home = await _write(
          iso,
          'home.txt',
          'open ${_homeStranger}notes/x.md\n',
        );
        _expectLeak(
          await _leak(iso, ['--text', home, '--allow-empty-patterns']),
          hidden: [_homeStranger],
          what: 'home path',
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
          hidden: [_stranger],
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
          hidden: [_denyPath, other, _stranger, _email],
          what: 'multi',
        );
        final lines = _hits(r).map((m) => m.group(2)).toSet();
        expect(lines, containsAll(['1', '3']), reason: '$r');
        expect(lines.contains('2'), isFalse, reason: '$r');
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
      _expectLeak(r, hidden: [_stranger], what: 'stdin');
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
          hidden: [_email, _stranger],
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
        _expectLeak(textHit, hidden: [_stranger], what: 'text file');
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
        _expectLeak(binHit, hidden: [_stranger], what: 'binary file');
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
        hidden: [_stranger],
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
        _expectLeak(await scan(oldBlob), hidden: [_stranger], what: 'old blob');

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
        _expectLeak(
          await scan(message),
          hidden: [_stranger],
          what: 'commit message',
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
        _expectLeak(await scan(tag), hidden: [_stranger], what: 'tag message');
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
        _expectLeak(r, hidden: [_stranger], what: 'side branch');
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
          hidden: [_stranger],
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
          hidden: [_stranger],
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
          hidden: [_stranger],
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
        hidden: [_stranger],
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
      _expectLeak(
        await _leak(iso, ['--artifact', a, b], env: env),
        hidden: [_email],
        what: 'second path',
      );
    });
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
