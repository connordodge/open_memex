// Tests for scripts/public-cutover/rewrite-history.sh (#370, Spec #367
// requirement 11).
//
// Every run asserts the exact exit code, and every "output lacks X" or
// "ref is gone" check sits beside a positive one: on main the script is
// missing (exit 127), so a bare non-zero exit would pass there.
//
// Fixtures are temp repos inside isolatedEnv(): a bare `origin`, a `source`
// cloned from it (so refs/remotes/origin/main exists), and a pre-receive hook
// on origin that records any push attempt. No test runs the script against
// the real repo (ruling D3). Leak strings are built at runtime, never
// literal, so this file passes the Leak check itself.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _script = 'scripts/public-cutover/rewrite-history.sh';
const _leakCheck = 'scripts/leak-check.sh';

const _finalMessage = 'chore: move dev files out of the public repo';
const _noreply = '4242+fixture@users.noreply.github.com';

/// The isolated env's own git identity (support/script_harness.dart). It is
/// not on any deny-list, so it must come through the rewrite unchanged.
const _keptEmail = 'test@example.invalid';

// Runtime-built deny-list entries and look-alikes (never literal here).
final _denyHome = ['', 'Users', 'stranger'].join('/');
final _denyProj = ['', 'srv', 'PrivateProj'].join('/');
final _denyProjLower = _denyProj.toLowerCase();
final _email1 = ['Jo.Private', 'Example.org'].join('@');
final _email2 = ['connor.work', 'corp.example'].join('@');
final _email2Mixed = ['Connor.Work', 'Corp.Example'].join('@');
final _nearMiss = ['joXprivate', 'exampleYorg'].join('@');
final _fileNameLeak = ['secret', 'client'].join();

/// `LEAK <file-or-ref>:<line-or-offset> <rule>` from leak-check.sh.
final _hitLine = RegExp(r'^LEAK (.+):(\d+) (\S+)', multiLine: true);

/// Paths the final commit removes (ruling D1), as they sit in the fixtures.
const _devFiles = [
  '.act/config.yaml',
  '.claude/orchestration/adapter.md',
  'AGENTS.md',
  'CLAUDE.md',
  'ai_specs/spec.md',
];

bool _isDevPath(String p) =>
    p == 'CLAUDE.md' ||
    p == 'AGENTS.md' ||
    p.startsWith('.claude/orchestration/') ||
    p.startsWith('.act/') ||
    p.startsWith('ai_specs/');

/// One fixture: a bare origin, the source clone, the push marker the
/// origin's pre-receive hook writes, the patterns file and an out path.
class _Fx {
  _Fx(this.iso, this.origin, this.source, this.marker, this.patterns)
    : out = '${iso.work.path}/out';

  final IsolatedEnv iso;
  final String origin;
  final String source;
  final String marker;
  final String patterns;
  final String out;
}

Future<String> _git(
  IsolatedEnv iso,
  String dir,
  List<String> args, {
  Map<String, String> env = const {},
}) async => (await runGit(iso, dir, args, env: env)).stdout.trim();

/// `git` that reports failure instead of throwing.
Future<ScriptResult?> _gitTry(
  IsolatedEnv iso,
  String dir,
  List<String> args,
) async {
  try {
    return await runGit(iso, dir, args);
  } on StateError {
    return null;
  }
}

Future<void> _commit(
  IsolatedEnv iso,
  String repo,
  Map<String, String> files,
  String subject, {
  String? body,
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
    subject,
    if (body != null) ...['-m', body],
  ], env: env);
}

Future<String> _writePatterns(IsolatedEnv iso, List<String> lines) async {
  final f = File('${iso.root.path}/patterns.txt');
  await f.writeAsString('${lines.join('\n')}\n');
  return f.path;
}

/// A bare origin and a source cloned from it. The hook goes in later, by
/// [_armOrigin], once the fixture's own pushes are done.
Future<(String, String)> _originAndSource(IsolatedEnv iso) async {
  final origin = '${iso.work.path}/origin.git';
  await runGit(iso, iso.work.path, ['init', '-q', '--bare', origin]);
  final source = '${iso.work.path}/source';
  await runGit(iso, iso.work.path, ['clone', '-q', origin, source]);
  return (origin, source);
}

/// Installs a pre-receive hook on [origin] that records the attempt in the
/// returned marker path and rejects the push.
Future<String> _armOrigin(IsolatedEnv iso, String origin) async {
  final marker = '${iso.root.path}/push-attempted';
  final hook = File('$origin/hooks/pre-receive');
  await hook.parent.create(recursive: true);
  await hook.writeAsString('#!/bin/sh\ntouch "$marker"\nexit 1\n');
  await runTool(iso, 'chmod', [
    '+x',
    hook.path,
  ], workingDirectory: iso.work.path);
  return marker;
}

/// The full fixture: deny-list emails in author, committer and tagger
/// fields; deny-list paths, emails and the fixture HOME in blobs, commit
/// messages and a tag message; dev files; an extra local branch, a pushed
/// branch, a staging tag, a review ref; and an origin that moved on after
/// the source last fetched.
Future<_Fx> _fullFixture(IsolatedEnv iso) async {
  final (origin, source) = await _originAndSource(iso);
  final home = iso.home;

  await _commit(iso, source, {
    'README.md': 'hello\n',
    'src/lib.txt': 'code\n',
    '.claude/settings.json': '{}\n',
    'CLAUDE.md': 'notes at $_denyHome/dev\n',
    'AGENTS.md': 'agents\n',
    '.act/config.yaml': 'storage: github\n',
    'ai_specs/spec.md': 'spec\n',
    '.claude/orchestration/adapter.md': 'adapter\n',
  }, 'initial import');
  await _commit(
    iso,
    source,
    {'old.txt': 'see $_denyHome/old\n'},
    'add old notes',
    env: {'GIT_AUTHOR_EMAIL': _email1.toLowerCase()},
  );
  await _commit(
    iso,
    source,
    {
      'notes.txt': [
        'vault: $_denyHome/vault',
        'proj: $_denyProj/data',
        'proj-lower: $_denyProjLower/data',
        'home: $home/cfg',
        'mail: ${_email1.toUpperCase()}',
        'mail2: ${_email2.toUpperCase()}',
        'near-miss: $_nearMiss',
        'keep: $_keptEmail',
        '',
      ].join('\n'),
    },
    'add notes',
    env: {
      'GIT_AUTHOR_EMAIL': _email1.toUpperCase(),
      'GIT_COMMITTER_EMAIL': _email2Mixed,
    },
  );
  await _commit(
    iso,
    source,
    {'c4.txt': 'c4\n'},
    'fix crash in $_denyHome/code',
    body: [
      'home $home/x',
      'mail ${_email1.toLowerCase()}',
      'proj $_denyProj/y',
    ].join('\n'),
    env: {'GIT_COMMITTER_EMAIL': _email1.toLowerCase()},
  );
  await _commit(iso, source, {'old.txt': 'see nothing\n'}, 'tidy old notes');
  await runGit(
    iso,
    source,
    [
      'tag',
      '-a',
      'v0.1.0',
      '-m',
      'release notes $_denyHome/rel home $home/rel mail ${_email1.toUpperCase()}',
    ],
    env: {'GIT_COMMITTER_EMAIL': _email2},
  );
  await _commit(iso, source, {'src/more.txt': 'more\n'}, 'after release');
  await runGit(iso, source, ['push', '-q', 'origin', 'main']);

  await runGit(iso, source, ['checkout', '-q', '-b', 'feature-y']);
  await _commit(iso, source, {'y.txt': 'y\n'}, 'feature y work');
  await runGit(iso, source, ['push', '-q', 'origin', 'feature-y']);
  await runGit(iso, source, ['checkout', '-q', 'main']);
  await runGit(iso, source, ['checkout', '-q', '-b', 'feature-x']);
  await _commit(iso, source, {'x.txt': 'x\n'}, 'feature x work');
  await runGit(iso, source, ['tag', 'staging-20261110.1']);
  await runGit(iso, source, ['update-ref', 'refs/review/42', 'HEAD']);
  await runGit(iso, source, ['checkout', '-q', 'main']);

  // Origin moves on after the source last fetched: a rewrite that fetched
  // would change the source's refs/remotes/origin/main.
  final other = '${iso.work.path}/other';
  await runGit(iso, iso.work.path, ['clone', '-q', origin, other]);
  await _commit(iso, other, {'up.txt': 'up\n'}, 'upstream only');
  await runGit(iso, other, ['push', '-q', 'origin', 'main']);

  final marker = await _armOrigin(iso, origin);
  final patterns = await _writePatterns(iso, [
    _denyHome,
    _denyProj,
    _email1,
    _email2,
  ]);
  return _Fx(iso, origin, source, marker, patterns);
}

/// The small fixture the refusal tests perturb: main and v0.1.0 pushed and
/// equal to origin/main, HEAD on a checked-out `side` branch with one more
/// commit, a clean tree, and only some dev paths (CLAUDE.md and .act).
Future<_Fx> _baseline(
  IsolatedEnv iso, {
  List<String> extraDeny = const [],
}) async {
  final (origin, source) = await _originAndSource(iso);
  await _commit(iso, source, {
    'README.md': 'hello\n',
    'CLAUDE.md': 'dev\n',
    '.act/config.yaml': 'storage: github\n',
  }, 'first');
  await runGit(iso, source, ['tag', '-a', 'v0.1.0', '-m', 'first release']);
  await _commit(
    iso,
    source,
    {'src/lib.txt': 'see $_denyHome/code\n'},
    'second',
    env: {'GIT_AUTHOR_EMAIL': _email1},
  );
  await runGit(iso, source, ['push', '-q', 'origin', 'main']);
  await runGit(iso, source, ['checkout', '-q', '-b', 'side']);
  await _commit(iso, source, {'side.txt': 'side\n'}, 'side only');
  final marker = await _armOrigin(iso, origin);
  final patterns = await _writePatterns(iso, [
    _denyHome,
    _email1,
    ...extraDeny,
  ]);
  return _Fx(iso, origin, source, marker, patterns);
}

Future<ScriptResult> _rewrite(
  _Fx fx, {
  String? out,
  String noreply = _noreply,
  String? patterns,
  Map<String, String> env = const {},
}) => runScript(
  _script,
  [
    '--source',
    fx.source,
    '--out',
    out ?? fx.out,
    '--noreply',
    noreply,
    '--patterns',
    patterns ?? fx.patterns,
  ],
  env: {...fx.iso.env, ...env},
  // Not the repo root: the script must find leak-check.sh from its own dir.
  workingDirectory: fx.iso.work.path,
);

/// Everything a run must leave alone: the source's refs, HEAD, remotes,
/// local config, status and working-tree files, and the origin's refs.
Future<String> _snapshot(_Fx fx) async {
  final iso = fx.iso;
  final s = fx.source;
  final files = <String>[];
  for (final e in Directory(s).listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(s.length + 1);
    if (rel == '.git' || rel.startsWith('.git/')) continue;
    if (e is File) files.add('$rel=${e.readAsStringSync()}');
  }
  files.sort();
  return [
    '--- source refs',
    await _git(iso, s, ['for-each-ref', '--format=%(refname) %(objectname)']),
    '--- source HEAD',
    await _git(iso, s, ['symbolic-ref', 'HEAD']),
    '--- source remotes',
    await _git(iso, s, ['remote', '-v']),
    '--- source config',
    await _git(iso, s, ['config', '--local', '--list']),
    '--- source status',
    await _git(iso, s, ['status', '--porcelain=v1', '--untracked-files=all']),
    '--- source files',
    ...files,
    '--- source filter-repo dir',
    '${Directory('$s/.git/filter-repo').existsSync()}',
    '--- origin refs',
    await _git(iso, fx.origin, [
      'for-each-ref',
      '--format=%(refname) %(objectname)',
    ]),
  ].join('\n');
}

Future<void> _expectUntouched(_Fx fx, String before, ScriptResult r) async {
  expect(await _snapshot(fx), before, reason: 'source or origin changed\n$r');
  expect(
    File('${fx.origin}/hooks/pre-receive').existsSync(),
    isTrue,
    reason: 'the push trap is installed',
  );
  expect(
    File(fx.marker).existsSync(),
    isFalse,
    reason: 'the rewrite tried to push to the fixture origin\n$r',
  );
}

/// Exit 2, no out dir created, and the source and origin unchanged.
Future<void> _expectRefusal(
  _Fx fx,
  String before,
  ScriptResult r, {
  required String what,
}) async {
  expect(r.exitCode, 2, reason: 'exit for $what\n$r');
  expect(r.output.trim(), isNotEmpty, reason: 'a refusal says why ($what)\n$r');
  expect(
    Directory(fx.out).existsSync(),
    isFalse,
    reason: 'a refusal creates nothing in out ($what)\n$r',
  );
  await _expectUntouched(fx, before, r);
}

Future<Set<String>> _refs(IsolatedEnv iso, String repo) async => (await _git(
  iso,
  repo,
  ['for-each-ref', '--format=%(refname)'],
)).split('\n').where((l) => l.isNotEmpty).toSet();

/// subject -> sha for every commit on [ref] in [repo].
Future<Map<String, String>> _bySubject(
  IsolatedEnv iso,
  String repo, [
  String ref = 'refs/heads/main',
]) async {
  final out = <String, String>{};
  for (final l in (await _git(iso, repo, [
    'log',
    ref,
    '--format=%H%x09%s',
  ])).split('\n')) {
    final i = l.indexOf('\t');
    if (i > 0) out[l.substring(i + 1)] = l.substring(0, i);
  }
  return out;
}

/// `key: value` lines of a blob.
Map<String, String> _kv(String text) => {
  for (final l in text.split('\n'))
    if (l.contains(': '))
      l.substring(0, l.indexOf(': ')): l.substring(l.indexOf(': ') + 2),
};

/// Every author, committer and tagger name and email, every commit and tag
/// message, and every blob reachable in [repo], as one string.
Future<String> _allText(IsolatedEnv iso, String repo) async {
  final log = await _git(iso, repo, [
    'log',
    '--all',
    '-p',
    '--format=%an %ae %cn %ce%n%B',
  ]);
  final tags = await _git(iso, repo, [
    'for-each-ref',
    'refs/tags',
    '--format=%(taggername) %(taggeremail)%0a%(contents)',
  ]);
  return '$log\n$tags';
}

void main() {
  test('git filter-repo is installed for these tests', () async {
    final iso = await isolatedEnv();
    final r = await _gitTry(iso, iso.work.path, ['filter-repo', '--version']);
    expect(
      r,
      isNotNull,
      reason:
          'git filter-repo is a test prerequisite (CONTRIBUTING.md); '
          'install it, for example with Homebrew',
    );
  });

  group('a successful rewrite', () {
    late IsolatedEnv iso;
    late _Fx fx;
    late String before;
    late ScriptResult run;
    late String after;

    setUpAll(() async {
      iso = await isolatedEnv();
      fx = await _fullFixture(iso);
      before = await _snapshot(fx);
      run = await _rewrite(fx);
      after = await _snapshot(fx);
    });

    void expectRan() => expect(run.exitCode, 0, reason: '$run');

    test(
      'a successful rewrite exits 0 prints leaks 0 the main SHA and the push command and passes leak-check history',
      () async {
        expectRan();
        expect(run.output, contains('leaks: 0'), reason: '$run');

        final sha = await _git(iso, fx.out, ['rev-parse', 'refs/heads/main']);
        expect(sha, matches(RegExp(r'^[0-9a-f]{40}$')));
        expect(run.output, contains(sha), reason: 'main SHA\n$run');

        final outs = {
          RegExp.escape(fx.out),
          RegExp.escape(Directory(fx.out).resolveSymbolicLinksSync()),
        }.join('|');
        expect(
          run.output,
          matches(
            RegExp('git -C ["\']?($outs)["\']? push \\S+ main v0\\.1\\.0'),
          ),
          reason: 'push command\n$run',
        );

        // The fixture holds real leaks, and the output repo has none.
        final src = await runScript(_leakCheck, [
          '--history',
          fx.source,
          '--patterns',
          fx.patterns,
        ], env: iso.env);
        expect(src.exitCode, 1, reason: 'the source fixture leaks\n$src');
        expect(_hitLine.hasMatch(src.stdout), isTrue, reason: '$src');

        final res = await runScript(_leakCheck, [
          '--history',
          fx.out,
          '--patterns',
          fx.patterns,
        ], env: iso.env);
        expect(res.exitCode, 0, reason: 'leak-check on out\n$res');
        expect(_hitLine.hasMatch(res.stdout), isFalse, reason: '$res');
      },
    );

    test(
      'deny-list author committer and tagger emails in any letter case become the noreply address',
      () async {
        expectRan();
        final rows = <String, List<String>>{};
        for (final l in (await _git(iso, fx.out, [
          'log',
          'refs/heads/main',
          '--format=%s%x09%ae%x09%ce',
        ])).split('\n')) {
          final p = l.split('\t');
          rows[p[0]] = [p[1], p[2]];
        }
        // author lower-case, committer not on the deny-list
        expect(rows['add old notes'], [_noreply, _keptEmail], reason: '$rows');
        // author upper-case, committer mixed-case second entry
        expect(rows['add notes'], [_noreply, _noreply], reason: '$rows');
        // committer only
        expect(rows['fix crash in ~/code'], [
          _keptEmail,
          _noreply,
        ], reason: '$rows');
        // an email that is not on the deny-list is kept
        expect(rows['initial import'], [_keptEmail, _keptEmail]);
        expect(rows['after release'], [_keptEmail, _keptEmail]);

        final tagger = await _git(iso, fx.out, [
          'for-each-ref',
          'refs/tags/v0.1.0',
          '--format=%(taggeremail)',
        ]);
        expect(tagger, '<$_noreply>');

        final idents = (await _git(iso, fx.out, [
          'log',
          '--all',
          '--format=%ae %ce',
        ])).toLowerCase();
        expect(idents, contains(_noreply));
        expect(idents, isNot(contains(_email1.toLowerCase())));
        expect(idents, isNot(contains(_email2.toLowerCase())));
      },
    );

    test(
      'deny-list paths and HOME in blobs commit messages and tag messages become a tilde',
      () async {
        expectRan();
        final notes = _kv(
          await _git(iso, fx.out, ['show', 'refs/heads/main:notes.txt']),
        );
        expect(notes['vault'], '~/vault', reason: '$notes');
        expect(notes['proj'], '~/data', reason: '$notes');
        expect(notes['home'], '~/cfg', reason: '$notes');
        // paths match case-sensitively: another case is not the entry
        expect(notes['proj-lower'], '$_denyProjLower/data', reason: '$notes');

        final c = await _bySubject(iso, fx.out);
        expect(c.keys, contains('add old notes'), reason: '$c');
        expect(
          await _git(iso, fx.out, ['show', '${c['add old notes']}:old.txt']),
          'see ~/old',
          reason: 'an old blob',
        );
        expect(
          await _git(iso, fx.out, ['show', 'refs/heads/main~1:CLAUDE.md']),
          'notes at ~/dev',
          reason: 'dev files keep their scrubbed history',
        );

        expect(c.keys, contains('fix crash in ~/code'), reason: '$c');
        final msg = await _git(iso, fx.out, [
          'log',
          '-1',
          '--format=%B',
          c['fix crash in ~/code']!,
        ]);
        expect(msg, contains('home ~/x'));
        expect(msg, contains('proj ~/y'));
        expect(msg, isNot(contains(_denyHome)));
        expect(msg, isNot(contains(iso.home)));
        expect(msg, isNot(contains(_denyProj)));

        final tagMsg = await _git(iso, fx.out, [
          'for-each-ref',
          'refs/tags/v0.1.0',
          '--format=%(contents)',
        ]);
        expect(tagMsg, contains('release notes ~/rel home ~/rel'));
        expect(tagMsg, isNot(contains(_denyHome)));
        expect(tagMsg, isNot(contains(iso.home)));

        final all = await _allText(iso, fx.out);
        expect(all, contains('~/'));
        expect(all, isNot(contains(_denyHome)));
        expect(all, isNot(contains(_denyProj)));
        expect(all, isNot(contains(iso.home)));
      },
    );

    test(
      'a deny-list email inside a blob or a message becomes the noreply address',
      () async {
        expectRan();
        final notes = _kv(
          await _git(iso, fx.out, ['show', 'refs/heads/main:notes.txt']),
        );
        expect(notes['mail'], _noreply, reason: '$notes');
        expect(notes['mail2'], _noreply, reason: '$notes');
        // entries are literals: a regex-style near miss is not replaced
        expect(notes['near-miss'], _nearMiss, reason: '$notes');
        // an email that is not on the deny-list is kept
        expect(notes['keep'], _keptEmail, reason: '$notes');

        final c = await _bySubject(iso, fx.out);
        expect(c.keys, contains('fix crash in ~/code'), reason: '$c');
        final msg = await _git(iso, fx.out, [
          'log',
          '-1',
          '--format=%B',
          c['fix crash in ~/code']!,
        ]);
        expect(msg, contains('mail $_noreply'));

        final tagMsg = await _git(iso, fx.out, [
          'for-each-ref',
          'refs/tags/v0.1.0',
          '--format=%(contents)',
        ]);
        expect(tagMsg, contains('mail $_noreply'));

        final all = (await _allText(iso, fx.out)).toLowerCase();
        expect(all, contains(_noreply));
        expect(all, isNot(contains(_email1.toLowerCase())));
        expect(all, isNot(contains(_email2.toLowerCase())));
      },
    );

    test(
      'only refs heads main and refs tags v0.1.0 survive the rewrite',
      () async {
        expectRan();
        expect(await _refs(iso, fx.out), {
          'refs/heads/main',
          'refs/tags/v0.1.0',
        });

        // main is the source's main plus the final commit
        final srcCount = await _git(iso, fx.source, [
          'rev-list',
          '--count',
          'refs/heads/main',
        ]);
        final outCount = await _git(iso, fx.out, [
          'rev-list',
          '--count',
          'refs/heads/main',
        ]);
        expect(int.parse(outCount), int.parse(srcCount) + 1);
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%s', 'main~1']),
          'after release',
        );

        // v0.1.0 stays an annotated tag on the rewritten release commit
        expect(
          await _git(iso, fx.out, ['cat-file', '-t', 'refs/tags/v0.1.0']),
          'tag',
        );
        expect(
          await _git(iso, fx.out, [
            'log',
            '-1',
            '--format=%s',
            'refs/tags/v0.1.0^{commit}',
          ]),
          'tidy old notes',
        );

        final subjects = await _git(iso, fx.out, [
          'log',
          '--all',
          '--format=%s',
        ]);
        expect(subjects, contains('initial import'));
        expect(subjects, isNot(contains('feature x work')));
        expect(subjects, isNot(contains('feature y work')));
        expect(subjects, isNot(contains('upstream only')));
      },
    );

    test(
      'the final commit removes the dev files and is authored and committed as the noreply address',
      () async {
        expectRan();
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%B', 'main']),
          _finalMessage,
        );
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%ae%n%ce', 'main']),
          '$_noreply\n$_noreply',
        );
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%P', 'main']),
          isNot(contains(' ')),
          reason: 'one parent',
        );

        final tree = (await _git(iso, fx.out, [
          'ls-tree',
          '-r',
          '--name-only',
          'main',
        ])).split('\n');
        expect(tree.where(_isDevPath), isEmpty, reason: '$tree');
        expect(
          tree,
          containsAll([
            'README.md',
            'src/lib.txt',
            '.claude/settings.json',
            'notes.txt',
          ]),
        );

        final parentTree = (await _git(iso, fx.out, [
          'ls-tree',
          '-r',
          '--name-only',
          'main~1',
        ])).split('\n');
        expect(
          parentTree,
          containsAll(_devFiles),
          reason: 'history keeps them',
        );

        final diff = (await _git(iso, fx.out, [
          'diff',
          '--name-status',
          'main~1',
          'main',
        ])).split('\n');
        expect(diff.toSet(), {for (final p in _devFiles) 'D\t$p'});

        // the fixture's git config does not sign, so neither does the commit
        final raw = await _git(iso, fx.out, ['cat-file', 'commit', 'main']);
        expect(raw, contains('author '));
        expect(raw, isNot(contains('gpgsig')));
      },
    );

    test(
      'the output keeps no object that only a dropped ref reached',
      () async {
        expectRan();
        // Dropped refs are deleted before filter-repo, so its gc prunes
        // what only they reached: the out repo holds the objects of main and
        // v0.1.0 and nothing else.
        Future<Set<String>> lines(List<String> args) async =>
            (await _git(iso, fx.out, args)).split('\n').toSet();
        final stored = await lines([
          'cat-file',
          '--batch-all-objects',
          '--batch-check=%(objectname)',
        ]);
        final reachable = (await lines([
          'rev-list',
          '--objects',
          '--all',
        ])).map((l) => l.split(' ').first).toSet();
        expect(reachable.length, greaterThan(10), reason: 'objects of main');
        expect(stored, reachable);

        // beside it: the commits of the kept refs are all there
        expect(await _bySubject(iso, fx.out), contains('after release'));
        final all = await _git(iso, fx.out, ['log', '--all', '--format=%s']);
        expect(all, isNot(contains('feature x work')));
        expect(all, isNot(contains('feature y work')));
        expect(all, isNot(contains('upstream only')));
      },
    );

    test(
      'the success output prints the commit count and the kept refs',
      () async {
        expectRan();
        // Source main plus the final commit: counted after it was made,
        // and on main only (not --all).
        final srcCount = int.parse(
          await _git(iso, fx.source, [
            'rev-list',
            '--count',
            'refs/heads/main',
          ]),
        );
        final outCount = int.parse(
          await _git(iso, fx.out, ['rev-list', '--count', 'refs/heads/main']),
        );
        expect(srcCount, greaterThan(5), reason: 'the fixture has history');
        expect(outCount, srcCount + 1, reason: 'one commit added\n$run');
        expect(
          run.stdout,
          matches(RegExp('^commits: $outCount\$', multiLine: true)),
          reason: 'commit count line\n$run',
        );
        expect(
          run.stdout,
          matches(
            RegExp(
              r'^refs: refs/heads/main refs/tags/v0\.1\.0$',
              multiLine: true,
            ),
          ),
          reason: 'kept refs line\n$run',
        );
        // The ref list is the real one, not a constant.
        expect(await _refs(iso, fx.out), {
          'refs/heads/main',
          'refs/tags/v0.1.0',
        });
      },
    );

    test(
      'a successful rewrite leaves the source refs remotes working tree and origin unchanged and pushes nothing',
      () async {
        expectRan();
        expect(before, contains('refs/remotes/origin/main'));
        expect(before, contains('refs/heads/feature-x'));
        expect(after, before);
        await _expectUntouched(fx, before, run);
        // origin moved on and the source never fetched it
        expect(
          await _git(iso, fx.source, ['rev-parse', 'refs/remotes/origin/main']),
          isNot(await _git(iso, fx.origin, ['rev-parse', 'refs/heads/main'])),
        );
      },
    );
  });

  group('other successful runs', () {
    test(
      'a rewrite into an existing empty out dir takes main from refs heads main while HEAD is on another branch',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        await Directory(fx.out).create();
        final before = await _snapshot(fx);
        final r = await _rewrite(fx);
        expect(r.exitCode, 0, reason: '$r');
        expect(r.output, contains('leaks: 0'), reason: '$r');
        expect(await _refs(iso, fx.out), {
          'refs/heads/main',
          'refs/tags/v0.1.0',
        });
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%s', 'main~1']),
          'second',
        );
        final subjects = await _git(iso, fx.out, [
          'log',
          '--all',
          '--format=%s',
        ]);
        expect(subjects, contains('first'));
        expect(subjects, isNot(contains('side only')));
        // AGENTS.md and ai_specs are absent from this fixture
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%s', 'main']),
          _finalMessage,
        );
        final tree = (await _git(iso, fx.out, [
          'ls-tree',
          '-r',
          '--name-only',
          'main',
        ])).split('\n');
        expect(tree, containsAll(['README.md', 'src/lib.txt']));
        expect(tree.where(_isDevPath), isEmpty, reason: '$tree');
        await _expectUntouched(fx, before, r);
      },
    );

    test(
      'the final commit is signed when the git config signs commits',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        // A throwaway SSH key in the temp dir; never the developer's key.
        final key = '${iso.root.path}/signing_key';
        await runTool(iso, 'ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-C',
          'fixture',
          '-f',
          key,
        ], workingDirectory: iso.work.path);
        final pub = File('$key.pub').readAsStringSync().trim();
        final signers = File('${iso.root.path}/allowed_signers')
          ..writeAsStringSync('* namespaces="git" $pub\n');
        final cfg = iso.env['GIT_CONFIG_GLOBAL']!;
        for (final kv in [
          ['gpg.format', 'ssh'],
          ['user.signingkey', key],
          ['gpg.ssh.allowedSignersFile', signers.path],
          ['commit.gpgsign', 'true'],
        ]) {
          await runGit(iso, iso.work.path, ['config', '--file', cfg, ...kv]);
        }
        final r = await _rewrite(
          fx,
          env: {'SSH_AUTH_SOCK': '${iso.root.path}/no-agent.sock'},
        );
        expect(r.exitCode, 0, reason: '$r');
        expect(
          await _git(iso, fx.out, ['log', '-1', '--format=%s', 'main']),
          _finalMessage,
        );
        final raw = await _git(iso, fx.out, ['cat-file', 'commit', 'main']);
        expect(raw, contains('gpgsig '), reason: raw);
        final verified = await _gitTry(iso, fx.out, [
          'verify-commit',
          'refs/heads/main',
        ]);
        expect(verified, isNotNull, reason: 'git verify-commit main');
      },
    );
  });

  group('leak check failure', () {
    test(
      'a deny-list path that survives in a file name makes the rewrite exit 1 with a redacted LEAK line and keeps out',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso, extraDeny: [_fileNameLeak]);
        // --replace-text rewrites contents, never file names.
        await runGit(iso, fx.source, ['checkout', '-q', 'main']);
        await _commit(iso, fx.source, {
          'docs/$_fileNameLeak/plan.md': 'plan\n',
        }, 'add plan');
        await runGit(iso, fx.source, [
          'update-ref',
          'refs/remotes/origin/main',
          'main',
        ]);
        final before = await _snapshot(fx);

        final r = await _rewrite(fx);
        expect(r.exitCode, 1, reason: '$r');
        expect(_hitLine.hasMatch(r.output), isTrue, reason: 'LEAK line\n$r');
        expect(r.output, contains('[redacted]'), reason: '$r');
        expect(
          r.output.toLowerCase(),
          isNot(contains(_fileNameLeak)),
          reason: 'the output shows the leaked text\n$r',
        );
        expect(r.output, isNot(contains('leaks: 0')), reason: '$r');

        expect(Directory(fx.out).existsSync(), isTrue, reason: 'out is kept');
        expect(
          await _gitTry(iso, fx.out, [
            'rev-parse',
            '--verify',
            'refs/heads/main',
          ]),
          isNotNull,
          reason: 'out is a repo with main, left for inspection',
        );
        await _expectUntouched(fx, before, r);
      },
    );
  });

  group('refusals', () {
    test('the refusal baseline fixture rewrites with exit 0', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      final r = await _rewrite(fx);
      expect(r.exitCode, 0, reason: '$r');
      expect(r.output, contains('leaks: 0'), reason: '$r');
    });

    test('refuses with exit 2 when out exists and is not empty', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      final out = Directory('${iso.work.path}/busy')..createSync();
      File('${out.path}/keep.txt').writeAsStringSync('keep\n');
      final before = await _snapshot(fx);
      final r = await _rewrite(fx, out: out.path);
      expect(r.exitCode, 2, reason: '$r');
      expect(out.listSync().map((e) => e.path.split('/').last).toList(), [
        'keep.txt',
      ], reason: 'out is untouched\n$r');
      expect(File('${out.path}/keep.txt').readAsStringSync(), 'keep\n');
      expect(Directory(fx.out).existsSync(), isFalse);
      await _expectUntouched(fx, before, r);
    });

    test(
      'refuses with exit 2 when the source has uncommitted changes',
      () async {
        for (final staged in [false, true]) {
          final iso = await isolatedEnv();
          final fx = await _baseline(iso);
          File('${fx.source}/README.md').writeAsStringSync('edited\n');
          if (staged) await runGit(iso, fx.source, ['add', 'README.md']);
          final before = await _snapshot(fx);
          expect(
            before,
            matches(RegExp(r'^ ?M +README\.md$', multiLine: true)),
          );
          final r = await _rewrite(fx);
          await _expectRefusal(
            fx,
            before,
            r,
            what: staged ? 'staged change' : 'unstaged change',
          );
        }
      },
    );

    test('refuses with exit 2 when main is behind origin main', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      // HEAD is on side, so moving main leaves the working tree clean.
      await runGit(iso, fx.source, ['update-ref', 'refs/heads/main', 'main~1']);
      final before = await _snapshot(fx);
      final r = await _rewrite(fx);
      await _expectRefusal(fx, before, r, what: 'main behind origin/main');
    });

    test('refuses with exit 2 when main is ahead of origin main', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      await runGit(iso, fx.source, ['update-ref', 'refs/heads/main', 'side']);
      final before = await _snapshot(fx);
      final r = await _rewrite(fx);
      await _expectRefusal(fx, before, r, what: 'main ahead of origin/main');
    });

    test('refuses with exit 2 when git filter-repo is not on PATH', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      // System dirs only: git, bash and the coreutils, no Homebrew.
      const path = '/usr/bin:/bin:/usr/sbin:/sbin';
      final probe = await Process.run(
        '/usr/bin/git',
        ['filter-repo', '--version'],
        environment: {...iso.env, 'PATH': path},
      );
      expect(
        probe.exitCode,
        isNot(0),
        reason: 'the test PATH must lack git filter-repo',
      );
      final gitOk = await Process.run(
        '/usr/bin/git',
        ['--version'],
        environment: {...iso.env, 'PATH': path},
      );
      expect(gitOk.exitCode, 0, reason: 'the test PATH must have git');

      final before = await _snapshot(fx);
      final r = await _rewrite(fx, env: {'PATH': path});
      await _expectRefusal(fx, before, r, what: 'no git filter-repo');
    });

    test(
      'refuses with exit 2 when noreply is not a users.noreply.github.com address',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        final before = await _snapshot(fx);
        for (final bad in [
          ['someone', 'example.org'].join('@'),
          '4242+fixture@users.noreply.github.com.example.org',
          '4242+fixtureusers.noreply.github.com',
        ]) {
          final r = await _rewrite(fx, noreply: bad);
          await _expectRefusal(fx, before, r, what: 'noreply $bad');
        }
      },
    );

    test('refuses with exit 2 when the deny-list is empty', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      final before = await _snapshot(fx);
      for (final (what, content) in [
        ('empty file', ''),
        ('blank lines only', '\n\n\n'),
      ]) {
        final f = File('${iso.root.path}/empty-$what.txt')
          ..writeAsStringSync(content);
        final r = await _rewrite(fx, patterns: f.path);
        await _expectRefusal(fx, before, r, what: what);
      }
    });

    test(
      'exits 2 for a missing patterns file and for missing arguments',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        final before = await _snapshot(fx);
        final r = await _rewrite(fx, patterns: '${iso.root.path}/absent.txt');
        await _expectRefusal(fx, before, r, what: 'missing patterns file');

        final bare = await runScript(_script, [], env: iso.env);
        expect(bare.exitCode, 2, reason: 'no arguments\n$bare');
        final noOut = await runScript(_script, [
          '--source',
          fx.source,
          '--noreply',
          _noreply,
          '--patterns',
          fx.patterns,
        ], env: iso.env);
        expect(noOut.exitCode, 2, reason: 'no --out\n$noOut');
        await _expectUntouched(fx, before, noOut);
      },
    );
  });

  group('further refusals and contracts', () {
    test('refuses with exit 2 when out is inside the source', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      final before = await _snapshot(fx);
      for (final inside in ['${fx.source}/out', '${fx.source}/.git/out']) {
        final r = await _rewrite(fx, out: inside);
        expect(r.exitCode, 2, reason: 'out $inside\n$r');
        expect(r.output.trim(), isNotEmpty, reason: '$r');
        expect(Directory(inside).existsSync(), isFalse, reason: 'out $inside');
        await _expectUntouched(fx, before, r);
      }
      // beside it: out next to the source is fine
      final ok = await _rewrite(fx);
      expect(ok.exitCode, 0, reason: '$ok');
    });

    test('refuses with exit 2 when the source has an untracked file', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      File('${fx.source}/scratch.txt').writeAsStringSync('draft\n');
      final before = await _snapshot(fx);
      expect(before, contains('?? scratch.txt'));
      final r = await _rewrite(fx);
      await _expectRefusal(fx, before, r, what: 'untracked file');
    });

    test('refuses with exit 2 when the source has no v0.1.0 tag', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      await runGit(iso, fx.source, ['tag', '-d', 'v0.1.0']);
      expect(await _refs(iso, fx.source), isNot(contains('refs/tags/v0.1.0')));
      final before = await _snapshot(fx);
      final r = await _rewrite(fx);
      expect(
        r.output,
        contains('refused: --source has no refs/tags/v0.1.0'),
        reason: 'the message names the missing tag\n$r',
      );
      await _expectRefusal(fx, before, r, what: 'no v0.1.0 tag');
      // An existing empty out stays empty.
      final empty = Directory('${iso.work.path}/empty-out')..createSync();
      final again = await _rewrite(fx, out: empty.path);
      expect(again.exitCode, 2, reason: '$again');
      expect(empty.listSync(), isEmpty, reason: 'out stays empty\n$again');
      await _expectUntouched(fx, before, again);
    });

    test(
      'refuses with exit 2 when noreply has an empty or odd local part',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        final before = await _snapshot(fx);
        for (final bad in [
          '@users.noreply.github.com',
          'odd name@users.noreply.github.com',
          'a/b@users.noreply.github.com',
          'a&b@users.noreply.github.com',
          'a@b@users.noreply.github.com',
        ]) {
          final r = await _rewrite(fx, noreply: bad);
          await _expectRefusal(fx, before, r, what: 'noreply $bad');
        }
        // beside it: a plain id+name address is accepted
        final ok = await _rewrite(
          fx,
          noreply: 'x.y_z-1+n@users.noreply.github.com',
        );
        expect(ok.exitCode, 0, reason: '$ok');
      },
    );

    test(
      'a commit that only scrubbed a deny-list string stays in the history and the tag stays on it',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        await runGit(iso, fx.source, ['checkout', '-q', 'main']);
        // After the replacement both sides of this commit are identical.
        await _commit(iso, fx.source, {
          'src/lib.txt': 'see ~/code\n',
        }, 'scrub home path');
        await runGit(iso, fx.source, ['tag', '-d', 'v0.1.0']);
        await runGit(iso, fx.source, ['tag', '-a', 'v0.1.0', '-m', 'release']);
        await _commit(iso, fx.source, {'after.txt': 'a\n'}, 'after scrub');
        await runGit(iso, fx.source, [
          'update-ref',
          'refs/remotes/origin/main',
          'main',
        ]);
        final srcCount = int.parse(
          await _git(iso, fx.source, ['rev-list', '--count', 'main']),
        );
        final before = await _snapshot(fx);

        final r = await _rewrite(fx);
        expect(r.exitCode, 0, reason: '$r');
        final subjects = await _bySubject(iso, fx.out);
        expect(
          subjects.keys,
          containsAll(['scrub home path', 'after scrub', 'second', 'first']),
          reason: 'the scrub commit is kept\n$subjects',
        );
        expect(
          int.parse(await _git(iso, fx.out, ['rev-list', '--count', 'main'])),
          srcCount + 1,
          reason: 'no commit was pruned\n$r',
        );
        expect(
          await _git(iso, fx.out, [
            'log',
            '-1',
            '--format=%s',
            'refs/tags/v0.1.0^{commit}',
          ]),
          'scrub home path',
          reason: 'the tag was not moved to a parent',
        );
        await _expectUntouched(fx, before, r);
      },
    );

    test('a lightweight v0.1.0 tag is accepted and kept', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      await runGit(iso, fx.source, ['tag', '-d', 'v0.1.0']);
      await runGit(iso, fx.source, ['tag', 'v0.1.0', 'main~1']);
      expect(
        await _git(iso, fx.source, ['cat-file', '-t', 'refs/tags/v0.1.0']),
        'commit',
        reason: 'the fixture tag is lightweight',
      );
      final before = await _snapshot(fx);
      final r = await _rewrite(fx);
      expect(r.exitCode, 0, reason: '$r');
      expect(await _refs(iso, fx.out), {'refs/heads/main', 'refs/tags/v0.1.0'});
      expect(
        await _git(iso, fx.out, [
          'log',
          '-1',
          '--format=%s',
          'refs/tags/v0.1.0',
        ]),
        'first',
      );
      await _expectUntouched(fx, before, r);
    });

    test(
      'a failing git filter-repo exits 1 and leaves no ref in out to push',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        // A fake that passes the --version probe and fails a real run.
        final bin = Directory('${iso.root.path}/fake-bin')..createSync();
        final fake = File('${bin.path}/git-filter-repo')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'case "\$1" in --version) echo fake; exit 0 ;; esac\n'
            'echo "fake filter-repo: boom" >&2\n'
            'exit 1\n',
          );
        await runTool(iso, 'chmod', [
          '+x',
          fake.path,
        ], workingDirectory: iso.work.path);
        final before = await _snapshot(fx);

        final r = await _rewrite(
          fx,
          env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        );
        expect(r.exitCode, 1, reason: '$r');
        expect(r.output, contains('fake filter-repo: boom'), reason: '$r');
        expect(r.output, contains('do NOT push'), reason: '$r');
        expect(r.output, isNot(contains('leaks: 0')), reason: '$r');
        expect(Directory(fx.out).existsSync(), isTrue, reason: 'out is kept');
        expect(
          await _refs(iso, fx.out),
          isEmpty,
          reason: 'the original history must not be pushable\n$r',
        );
        await _expectUntouched(fx, before, r);
        // beside it: the same fixture rewrites fine with the real tool
        final ok = await _rewrite(fx, out: '${iso.work.path}/out-ok');
        expect(ok.exitCode, 0, reason: '$ok');
      },
    );

    test(
      'a failed signature on the final commit exits 1 and leaves no ref in out to push',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        final cfg = iso.env['GIT_CONFIG_GLOBAL']!;
        for (final kv in [
          ['gpg.format', 'ssh'],
          ['user.signingkey', '${iso.root.path}/no-such-key'],
          ['commit.gpgsign', 'true'],
        ]) {
          await runGit(iso, iso.work.path, ['config', '--file', cfg, ...kv]);
        }
        final before = await _snapshot(fx);

        final r = await _rewrite(
          fx,
          env: {'SSH_AUTH_SOCK': '${iso.root.path}/no-agent.sock'},
        );
        expect(r.exitCode, 1, reason: '$r');
        expect(r.output, contains('do NOT push'), reason: '$r');
        expect(r.output, isNot(contains('leaks: 0')), reason: '$r');
        expect(Directory(fx.out).existsSync(), isTrue, reason: 'out is kept');
        expect(
          await _refs(iso, fx.out),
          isEmpty,
          reason: 'a main that still has the dev files must not be pushable',
        );
        await _expectUntouched(fx, before, r);
      },
    );

    test(
      'an interrupted run exits 1 and leaves no ref in out to push',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        // A fake filter-repo that signals it started, then stays busy.
        final bin = Directory('${iso.root.path}/slow-bin')..createSync();
        final started = '${iso.root.path}/filter-repo-started';
        final fake = File('${bin.path}/git-filter-repo')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'case "\$1" in --version) echo fake; exit 0 ;; esac\n'
            'touch "$started"\n'
            'sleep 4\n'
            'exit 0\n',
          );
        await runTool(iso, 'chmod', [
          '+x',
          fake.path,
        ], workingDirectory: iso.work.path);
        final before = await _snapshot(fx);

        final env = <String, String>{};
        Platform.environment.forEach((k, v) {
          if (!k.startsWith('GIT_') && k != 'LEAK_PATTERNS') env[k] = v;
        });
        env
          ..addAll(fx.iso.env)
          ..['PATH'] = '${bin.path}:${Platform.environment['PATH']}';
        final proc = await Process.start(
          '${repoRoot()}/$_script',
          [
            '--source',
            fx.source,
            '--out',
            fx.out,
            '--noreply',
            _noreply,
            '--patterns',
            fx.patterns,
          ],
          environment: env,
          includeParentEnvironment: false,
          workingDirectory: fx.iso.work.path,
        );
        final stdout = proc.stdout
            .transform(const SystemEncoding().decoder)
            .join();
        final stderr = proc.stderr
            .transform(const SystemEncoding().decoder)
            .join();
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (!File(started).existsSync()) {
          if (DateTime.now().isAfter(deadline)) {
            proc.kill(ProcessSignal.sigkill);
            fail('the fake filter-repo never started');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(proc.kill(ProcessSignal.sigterm), isTrue);
        final code = await proc.exitCode;
        final out = '${await stdout}\n${await stderr}';
        expect(code, 1, reason: 'exit after SIGTERM\n$out');
        expect(out, contains('do NOT push'), reason: out);
        expect(Directory(fx.out).existsSync(), isTrue, reason: 'out is kept');
        expect(
          await _refs(iso, fx.out),
          isEmpty,
          reason: 'no ref to push\n$out',
        );
        await _expectUntouched(fx, before, ScriptResult(code, out, ''));
      },
    );

    test(
      'refuses with exit 2 when out is inside the common git dir of a linked worktree source',
      () async {
        final iso = await isolatedEnv();
        final base = await _baseline(iso);
        // A linked worktree on main: its git dir is .git/worktrees/wt, and
        // out under the main repo's .git is in neither it nor its top.
        final wt = '${iso.work.path}/wt';
        await runGit(iso, base.source, ['worktree', 'add', '-q', wt, 'main']);
        final fx = _Fx(iso, base.origin, wt, base.marker, base.patterns);
        final before = await _snapshot(fx);
        final inside = '${base.source}/.git/out';
        final r = await _rewrite(fx, out: inside);
        expect(r.exitCode, 2, reason: '$r');
        expect(r.output, contains('inside'), reason: '$r');
        expect(Directory(inside).existsSync(), isFalse, reason: '$r');
        await _expectUntouched(fx, before, r);
        // beside it: the worktree is a valid source
        final ok = await _rewrite(fx);
        expect(ok.exitCode, 0, reason: '$ok');
      },
    );

    test(
      'the help flag exits 0 with usage and an unknown flag exits 2',
      () async {
        final iso = await isolatedEnv();
        final help = await runScript(_script, ['--help'], env: iso.env);
        expect(help.exitCode, 0, reason: '$help');
        expect(help.output.toLowerCase(), contains('usage'), reason: '$help');
        final bad = await runScript(_script, ['--frobnicate'], env: iso.env);
        expect(bad.exitCode, 2, reason: '$bad');
      },
    );

    test('the output has no remote that points back at the source', () async {
      final iso = await isolatedEnv();
      final fx = await _baseline(iso);
      final r = await _rewrite(fx);
      expect(r.exitCode, 0, reason: '$r');
      expect(await _git(iso, fx.out, ['remote']), isEmpty);
      final cfg = await _git(iso, fx.out, ['config', '--local', '--list']);
      expect(cfg, isNot(contains('remote.')), reason: cfg);
      expect(cfg, isNot(contains(fx.source)), reason: cfg);
      // beside it: the kept refs are there
      expect(await _refs(iso, fx.out), {'refs/heads/main', 'refs/tags/v0.1.0'});
    });

    test(
      'deny-list entries are literals trimmed of whitespace and replaced longest first',
      () async {
        final iso = await isolatedEnv();
        final fx = await _baseline(iso);
        final deep = '$_denyProj/deep';
        final meta = ['', 'opt', 'we*ird', '(p)'].join('/');
        final decoy = ['', 'opt', 'weeeird', 'p'].join('/');
        // HOME is a symlink to the temp home, so the path as given and the
        // resolved one always differ (on any host).
        final linkHome = '${iso.root.path}/linked-fixture-home';
        Link(linkHome).createSync(iso.home);
        final realHome = Directory(linkHome).resolveSymbolicLinksSync();
        expect(realHome, isNot(linkHome), reason: 'the two HOME forms differ');
        await runGit(iso, fx.source, ['checkout', '-q', 'main']);
        await _commit(iso, fx.source, {
          'paths.txt': [
            'deep: $deep/x',
            'proj: $_denyProj/other',
            'meta: $meta/f',
            'decoy: $decoy/f',
            'crlf: $_denyHome/z',
            'home: $linkHome/cfg',
            'real-home: $realHome/cfg',
            '',
          ].join('\n'),
        }, 'add paths');
        await runGit(iso, fx.source, [
          'update-ref',
          'refs/remotes/origin/main',
          'main',
        ]);
        final patterns = File('${iso.root.path}/odd-patterns.txt')
          ..writeAsStringSync(
            [
              '  $_denyProj \t',
              deep,
              meta,
              '$_denyHome\r',
              _email1,
              '',
            ].join('\n'),
          );
        final before = await _snapshot(fx);

        final r = await _rewrite(
          fx,
          patterns: patterns.path,
          env: {'HOME': linkHome},
        );
        expect(r.exitCode, 0, reason: '$r');
        final kv = _kv(
          await _git(iso, fx.out, ['show', 'refs/heads/main:paths.txt']),
        );
        // the longer entry went first: nothing of it is left behind
        expect(kv['deep'], '~/x', reason: '$kv');
        // the trimmed shorter entry still applies to everything else
        expect(kv['proj'], '~/other', reason: '$kv');
        // entries are literals: * and () are not regex syntax
        expect(kv['meta'], '~/f', reason: '$kv');
        expect(kv['decoy'], '$decoy/f', reason: 'a look-alike is kept\n$kv');
        // a CR at the end of a line is not part of the entry
        expect(kv['crlf'], '~/z', reason: '$kv');
        // HOME as given and with symlinks resolved
        expect(kv['home'], '~/cfg', reason: '$kv');
        expect(kv['real-home'], '~/cfg', reason: '$kv');
        await _expectUntouched(fx, before, r);
      },
    );
  });

  test('rewrite-history.sh is an executable bash script', () {
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
}
