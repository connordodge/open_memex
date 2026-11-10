// Static checks of .github/workflows/release.yml (#376, Spec #367
// requirements 25-28).
//
// The workflow runs only on the public repo after the cutover (D5); nothing
// here runs it. The tests parse the file with package:yaml and walk its jobs
// and steps. Raw text is read only for what the ACs state textually (the
// lockfile flags) and for comments, which the YAML parser drops (the version
// comment beside each pinned action).
//
// Shapes the tests recognise (the gh CLI, not third-party release actions):
//   draft     a step whose run has `gh release create ... --draft` (or
//             `gh api ... releases` with `draft=true`)
//   upload    a step whose run has `gh release upload` or
//             `gh release create`, naming each asset
//             (`Open-Memex-<v>-arm64.dmg`, `memex-<v>-macos-arm64.zip`,
//             `THIRD_PARTY_NOTICES.txt`, `SHA256SUMS.txt`)
//   publish   a step whose run has `--draft=false` (`gh release edit`) or
//             `draft=false` (`gh api` PATCH)
//   keychain  `security create-keychain` + `security import`, and a step
//             with `always()` in its `if` that runs
//             `security delete-keychain`
//   push-only a job whose `if` requires `github.event_name == 'push'` with
//             no `||`; every other job can run on workflow_dispatch
// `if: always()` steps (clean-up) don't count when finding the last step.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'support/script_harness.dart';

const _workflowPath = '.github/workflows/release.yml';
const _checkVersion = 'scripts/release/check-version.sh';
const _buildScript = 'scripts/release/build.sh';

const _releaseSecrets = [
  'MACOS_CERT_P12_BASE64',
  'MACOS_CERT_PASSWORD',
  'NOTARY_KEY_P8_BASE64',
  'NOTARY_KEY_ID',
  'NOTARY_ISSUER_ID',
  'LEAK_PATTERNS',
];

/// A `secrets.X` / `secrets['X']` reference, or any `${{ }}` expression that
/// names `secrets` (`toJSON(secrets)` reads them all).
final _secretRef = RegExp(r'\bsecrets\s*(\.|\[)|\$\{\{[^}]*\bsecrets\b');

/// Shell tracing: `set -x` (alone or in a flag cluster), `set -o xtrace` and
/// a shell started with `-x` (`bash -x`, `sh -ex`, `shell: bash -x`).
final _tracing = RegExp(
  r'\bset\s+-[a-zA-Z]*x|\bset\s+-o\s+xtrace|\b(?:ba)?sh\s+(?:-[a-zA-Z]+\s+)*-[a-zA-Z]*x|\bBASH_XTRACEFD\b',
);

String _rawWorkflow() {
  final f = File('${repoRoot()}/$_workflowPath');
  expect(f.existsSync(), isTrue, reason: '$_workflowPath exists');
  return f.readAsStringSync();
}

Map<dynamic, dynamic> _workflow() {
  final doc = loadYaml(_rawWorkflow());
  expect(doc, isA<Map>(), reason: '$_workflowPath is a YAML map');
  return doc as Map;
}

/// The `on:` block. YAML 1.1 parsers read a bare `on` as `true`.
Map<dynamic, dynamic> _triggers(Map<dynamic, dynamic> wf) {
  final on = wf['on'] ?? wf[true];
  expect(on, isA<Map>(), reason: 'on: is a map of events');
  return on as Map;
}

Map<String, Map<dynamic, dynamic>> _jobs(Map<dynamic, dynamic> wf) {
  final jobs = wf['jobs'];
  expect(jobs, isA<Map>(), reason: 'jobs: is a map');
  return {
    for (final e in (jobs as Map).entries)
      e.key.toString(): e.value as Map<dynamic, dynamic>,
  };
}

List<Map<dynamic, dynamic>> _steps(Map<dynamic, dynamic> job) => [
  for (final s in (job['steps'] as List? ?? const [])) s as Map,
];

/// Every key and scalar under [node], as strings.
Iterable<String> _strings(Object? node) sync* {
  if (node is Map) {
    for (final e in node.entries) {
      yield e.key.toString();
      yield* _strings(e.value);
    }
  } else if (node is List) {
    for (final v in node) {
      yield* _strings(v);
    }
  } else if (node != null) {
    yield node.toString();
  }
}

bool _mentionsSecrets(Object? node) {
  if (_strings(node).any(_secretRef.hasMatch)) return true;
  if (node is Map) {
    if (node['secrets'] == 'inherit') return true;
    return node.values.any(_mentionsSecrets);
  }
  if (node is List) return node.any(_mentionsSecrets);
  return false;
}

String _text(Object? node) => _strings(node).join('\n');

/// The step's `run:` with backslash-newline continuations joined.
String _run(Map<dynamic, dynamic> step) =>
    (step['run']?.toString() ?? '').replaceAll(RegExp(r'\\\s*\n\s*'), ' ');

/// A job's or step's `if:` without `${{ }}` and with whitespace collapsed.
String _cond(Map<dynamic, dynamic> node) => (node['if']?.toString() ?? '')
    .replaceAll(r'${{', ' ')
    .replaceAll('}}', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _isAlways(Map<dynamic, dynamic> step) => _cond(step).contains('always()');

bool _isReleaseEnv(Object? env) =>
    env == 'release' || (env is Map && env['name'] == 'release');

MapEntry<String, Map<dynamic, dynamic>> _releaseJob(Map<dynamic, dynamic> wf) {
  final bound = _jobs(
    wf,
  ).entries.where((e) => _isReleaseEnv(e.value['environment'])).toList();
  expect(
    bound,
    hasLength(1),
    reason: 'exactly one job is bound to environment: release',
  );
  return bound.single;
}

bool _isPushOnly(Map<dynamic, dynamic> job) {
  final c = _cond(job);
  return c.contains("github.event_name == 'push'") && !c.contains('||');
}

/// The jobs that can run on a workflow_dispatch event.
Map<String, Map<dynamic, dynamic>> _dispatchJobs(Map<dynamic, dynamic> wf) {
  final jobs = _jobs(wf);
  final pushOnly = {
    for (final e in jobs.entries)
      if (_isPushOnly(e.value)) e.key,
  };
  bool needsPushOnly(Map<dynamic, dynamic> job) {
    final needs = job['needs'];
    final names = needs is List ? needs.map((n) => '$n') : ['${needs ?? ''}'];
    return names.any(pushOnly.contains);
  }

  return {
    for (final e in jobs.entries)
      if (!pushOnly.contains(e.key) && !needsPushOnly(e.value)) e.key: e.value,
  };
}

Map<String, String> _envOf(
  Map<dynamic, dynamic> wf,
  Map<dynamic, dynamic> job,
  Map<dynamic, dynamic> step,
) => {
  for (final m in [wf['env'], job['env'], step['env']])
    if (m is Map)
      for (final e in m.entries) e.key.toString(): e.value.toString(),
};

final _ghCreate = RegExp(r'gh\s+release\s+create\b');
final _ghUpload = RegExp(r'gh\s+release\s+upload\b');
final _apiRelease = RegExp(r'gh\s+api\b[^\n]*releases');

bool _createsDraft(String run) =>
    (_ghCreate.hasMatch(run) && run.contains('--draft')) ||
    (_apiRelease.hasMatch(run) && RegExp(r'draft\s*[:=]\s*true').hasMatch(run));

bool _uploads(String run) => _ghUpload.hasMatch(run) || _ghCreate.hasMatch(run);

bool _publishes(String run) =>
    RegExp(r'--draft\s*=\s*false').hasMatch(run) ||
    (_apiRelease.hasMatch(run) &&
        RegExp(r'draft\s*[:=]\s*false').hasMatch(run));

bool _runsBuild(String run) => run.contains(_buildScript);

/// The build.sh command lines in [run].
Iterable<String> _buildLines(String run) =>
    run.split('\n').where((l) => l.contains(_buildScript));

int _indexWhere(
  List<Map<dynamic, dynamic>> steps,
  bool Function(Map<dynamic, dynamic>) test,
) => steps.indexWhere(test);

/// The jobs that run build.sh.
Map<String, Map<dynamic, dynamic>> _buildJobs(Map<dynamic, dynamic> wf) => {
  for (final e in _jobs(wf).entries)
    if (_steps(e.value).any((s) => _runsBuild(_run(s)))) e.key: e.value,
};

const _arm64Runners = {
  'macos-14',
  'macos-15',
  'macos-26',
  'macos-latest',
  'macos-14-xlarge',
  'macos-15-xlarge',
  'macos-26-xlarge',
  'macos-latest-xlarge',
};

void main() {
  group('triggers', () {
    test(
      'release.yml triggers only on v* tag pushes and workflow_dispatch with a required version input',
      () {
        final on = _triggers(_workflow());
        expect(on.keys.map((k) => '$k').toSet(), {
          'push',
          'workflow_dispatch',
        }, reason: 'no other event starts the workflow');
        final push = on['push'] as Map;
        expect(push.keys.map((k) => '$k').toSet(), {
          'tags',
        }, reason: 'push has only a tag filter: no branches or paths');
        expect(push['tags'], ['v*']);
        final dispatch = on['workflow_dispatch'] as Map;
        final inputs = dispatch['inputs'] as Map;
        expect(inputs.keys.map((k) => '$k').toSet(), {'version'});
        expect((inputs['version'] as Map)['required'], isTrue);
      },
    );
  });

  group('secrets and the release job', () {
    test(
      'every secrets reference in release.yml is inside the job bound to environment release',
      () {
        final wf = _workflow();
        final release = _releaseJob(wf);
        expect(
          _mentionsSecrets(release.value),
          isTrue,
          reason: 'the release job uses the environment secrets',
        );
        for (final e in _jobs(wf).entries) {
          if (e.key == release.key) continue;
          expect(
            _mentionsSecrets(e.value),
            isFalse,
            reason: 'job ${e.key} references no secrets',
          );
        }
        final outside = Map<dynamic, dynamic>.from(wf)..remove('jobs');
        expect(
          _mentionsSecrets(outside),
          isFalse,
          reason: 'no workflow-level env or default references a secret',
        );
      },
    );

    test('the release job if requires a push event and a refs/tags/v ref', () {
      final job = _releaseJob(_workflow()).value;
      final c = _cond(job);
      expect(c, contains("github.event_name == 'push'"));
      expect(c, contains("startsWith(github.ref, 'refs/tags/v')"));
      expect(c, contains('&&'), reason: 'both conditions must hold: $c');
      expect(c, isNot(contains('||')), reason: 'no alternative path: $c');
      expect(c, isNot(contains('always()')), reason: c);
      expect(_isPushOnly(job), isTrue);
    });

    test(
      'the release job reads each named environment secret and the MACOS_SIGN_IDENTITY variable',
      () {
        final text = _text(_releaseJob(_workflow()).value);
        for (final name in _releaseSecrets) {
          expect(
            RegExp('secrets\\.$name\\b').hasMatch(text),
            isTrue,
            reason: 'the release job reads secrets.$name',
          );
        }
        expect(text, contains('vars.MACOS_SIGN_IDENTITY'));
        expect(
          text,
          isNot(contains('secrets.MACOS_SIGN_IDENTITY')),
          reason: 'the identity is a variable, not a secret',
        );
      },
    );

    test(
      'no run script in release.yml expands a secret inline or turns on shell tracing',
      () {
        final wf = _workflow();
        var runs = 0;
        for (final job in _jobs(wf).values) {
          for (final step in _steps(job)) {
            final run = _run(step);
            if (run.isEmpty) continue;
            runs++;
            expect(
              _secretRef.hasMatch(run),
              isFalse,
              reason: 'secrets reach run scripts through env only:\n$run',
            );
            expect(
              _tracing.hasMatch(run),
              isFalse,
              reason: 'no set -x where secrets are in the environment:\n$run',
            );
          }
        }
        expect(runs, greaterThan(0), reason: 'the workflow has run steps');
      },
    );

    test(
      'the release job imports the p12 into a temporary keychain before the build and deletes it in an always step',
      () {
        final job = _releaseJob(_workflow()).value;
        final steps = _steps(job);
        final import = _indexWhere(steps, (s) {
          final r = _run(s);
          return r.contains('security create-keychain') &&
              r.contains('security import');
        });
        expect(import, greaterThanOrEqualTo(0), reason: 'a keychain import');
        final importText = _text(steps[import]);
        expect(importText, contains('secrets.MACOS_CERT_P12_BASE64'));
        expect(importText, contains('secrets.MACOS_CERT_PASSWORD'));
        final build = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        expect(build, greaterThan(import), reason: 'import before build');
        final cleanup = _indexWhere(
          steps,
          (s) => _isAlways(s) && _run(s).contains('security delete-keychain'),
        );
        expect(cleanup, greaterThan(import), reason: 'an always() clean-up');
        expect(
          steps.where((s) => _run(s).contains('security delete-keychain')),
          everyElement(predicate<Map<dynamic, dynamic>>(_isAlways)),
          reason: 'the keychain is deleted only by the always() step',
        );
      },
    );

    test(
      'the always step also removes the decoded p8 key and the p12 file',
      () {
        final steps = _steps(_releaseJob(_workflow()).value);
        final cleanup = steps.where(
          (s) => _isAlways(s) && _run(s).contains('security delete-keychain'),
        );
        expect(cleanup, hasLength(1));
        final run = _run(cleanup.single);
        expect(run, matches(RegExp(r'rm\s+-f[^\n]*notary-key\.p8')));
        expect(run, matches(RegExp(r'rm\s+-f[^\n]*signing\.p12')));
        // The files it removes are the ones earlier steps wrote.
        expect(
          steps.where((s) => _run(s).contains('notary-key.p8')).length,
          greaterThan(1),
        );
      },
    );

    test(
      'the release job runs check-version before the signed build with the notary and leak env from secrets',
      () {
        final wf = _workflow();
        final job = _releaseJob(wf).value;
        final steps = _steps(job);
        final checkAt = _indexWhere(
          steps,
          (s) => _run(s).contains(_checkVersion),
        );
        expect(checkAt, greaterThanOrEqualTo(0), reason: 'check-version runs');
        final buildAt = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        expect(buildAt, greaterThan(checkAt), reason: 'check before build');
        final build = steps[buildAt];
        for (final line in _buildLines(_run(build))) {
          expect(line, contains('--version'), reason: line);
          expect(line, isNot(contains('--dry-run')), reason: 'signed: $line');
        }
        final env = _envOf(wf, job, build);
        expect(
          env['MACOS_SIGN_IDENTITY'],
          contains('vars.MACOS_SIGN_IDENTITY'),
        );
        expect(env['NOTARY_KEY_ID'], contains('secrets.NOTARY_KEY_ID'));
        expect(env['NOTARY_ISSUER_ID'], contains('secrets.NOTARY_ISSUER_ID'));
        expect(env['LEAK_PATTERNS'], contains('secrets.LEAK_PATTERNS'));
        expect(env['NOTARY_KEY_P8_PATH'], isNotNull);
        expect(env['NOTARY_KEY_P8_PATH']!.trim(), isNotEmpty);
        final decodeAt = _indexWhere(
          steps,
          (s) =>
              _text(s).contains('secrets.NOTARY_KEY_P8_BASE64') &&
              _run(s).contains('base64'),
        );
        expect(decodeAt, greaterThanOrEqualTo(0), reason: 'the .p8 is decoded');
        expect(decodeAt, lessThan(buildAt), reason: 'decoded before build');
      },
    );
  });

  group('permissions', () {
    test(
      'top-level permissions are contents read and only the release job has contents write',
      () {
        final wf = _workflow();
        final top = wf['permissions'];
        expect(top, isA<Map>(), reason: 'permissions is a map, not read-all');
        expect(
          Map<String, String>.from(
            (top as Map).map((k, v) => MapEntry('$k', '$v')),
          ),
          {'contents': 'read'},
        );
        final release = _releaseJob(wf);
        final rp = release.value['permissions'];
        expect(rp, isA<Map>(), reason: 'the release job sets permissions');
        expect((rp as Map)['contents'], 'write');
        expect(
          rp.entries.where((e) => e.value == 'write').map((e) => '${e.key}'),
          ['contents'],
          reason: 'contents is the only scope the release job writes',
        );
        for (final e in _jobs(wf).entries) {
          if (e.key == release.key) continue;
          final p = e.value['permissions'];
          expect(p, isNot('write-all'), reason: e.key);
          if (p is Map) {
            expect(
              p.values.where((v) => v == 'write'),
              isEmpty,
              reason: 'job ${e.key} writes nothing',
            );
          } else {
            expect(p, anyOf(isNull, 'read-all'), reason: e.key);
          }
        }
      },
    );
  });

  group('publishing', () {
    test(
      'the release job creates a draft, uploads all four assets and publishes in its last step',
      () {
        final job = _releaseJob(_workflow()).value;
        final steps = _steps(job);
        final runs = [for (final s in steps) _run(s)];
        final draftAt = runs.indexWhere(_createsDraft);
        expect(draftAt, greaterThanOrEqualTo(0), reason: 'a draft Release');
        final publishAt = runs.indexWhere(_publishes);
        expect(publishAt, greaterThan(draftAt), reason: 'publish after draft');
        expect(
          runs.where(_publishes),
          hasLength(1),
          reason: 'exactly one step flips the draft to published',
        );
        final lastNormal = steps.lastIndexWhere((s) => !_isAlways(s));
        expect(
          publishAt,
          lastNormal,
          reason: 'publishing is the last step (always() clean-up aside)',
        );
        expect(_isAlways(steps[publishAt]), isFalse);
        expect(_uploads(runs[publishAt]), isFalse, reason: 'publish only');
        final uploadRuns = [
          for (var i = 0; i < runs.length; i++)
            if (_uploads(runs[i])) i,
        ];
        expect(uploadRuns, isNotEmpty, reason: 'assets are uploaded');
        expect(
          uploadRuns.every((i) => i >= draftAt && i < publishAt),
          isTrue,
          reason: 'every upload sits between the draft and the publish',
        );
        final uploaded = uploadRuns.map((i) => runs[i]).join('\n');
        for (final asset in [
          RegExp(r'Open-Memex-\S*-arm64\.dmg'),
          RegExp(r'memex-\S*-macos-arm64\.zip'),
          RegExp(r'THIRD_PARTY_NOTICES\.txt'),
          RegExp(r'SHA256SUMS\.txt'),
        ]) {
          expect(
            asset.hasMatch(uploaded),
            isTrue,
            reason: 'an upload names ${asset.pattern}',
          );
        }
      },
    );

    test('no step in release.yml creates a Release that is not a draft', () {
      final wf = _workflow();
      var creates = 0;
      for (final job in _jobs(wf).values) {
        for (final step in _steps(job)) {
          for (final line in _run(step).split('\n')) {
            if (!_ghCreate.hasMatch(line)) continue;
            creates++;
            expect(line, contains('--draft'), reason: line);
          }
        }
      }
      expect(creates, greaterThan(0), reason: 'gh release create runs');
    });

    test(
      'no release job step before the publish can fail without stopping the job',
      () {
        final job = _releaseJob(_workflow()).value;
        expect(job['continue-on-error'], anyOf(isNull, isFalse));
        for (final step in _steps(job)) {
          if (_isAlways(step)) continue;
          expect(
            step['continue-on-error'],
            anyOf(isNull, isFalse),
            reason: 'step ${step['name']} stops the job when it fails',
          );
        }
      },
    );

    test(
      'the release job titles the Release Open Memex version, marks pre-releases and builds the body from the notes and generate-notes',
      () {
        final job = _releaseJob(_workflow()).value;
        final runs = _steps(job).map(_run).join('\n');
        expect(runs, contains('--title'));
        expect(runs, contains('Open Memex '));
        expect(
          RegExp(r'--prerelease|prerelease\s*[:=]').hasMatch(runs),
          isTrue,
          reason: 'versions below 1.0.0 are marked pre-release',
        );
        expect(runs, contains('release-notes/v'));
        expect(runs, contains("## What's changed"));
        expect(runs, contains('generate-notes'));
        expect(runs, contains('previous_tag_name'));
        expect(
          RegExp(r'sort\s+-V|v:refname|version:refname').hasMatch(runs),
          isTrue,
          reason: 'the previous tag is found by version sort',
        );
      },
    );

    test('release.yml uses no third-party release action', () {
      final wf = _workflow();
      final uses = [
        for (final job in _jobs(wf).values)
          for (final s in _steps(job))
            if (s['uses'] != null) '${s['uses']}',
      ];
      expect(uses, isNotEmpty, reason: 'actions/checkout at least');
      for (final u in uses) {
        expect(u.toLowerCase(), isNot(contains('release')), reason: u);
      }
    });
  });

  group('workflow_dispatch dry run', () {
    test(
      'the workflow_dispatch path runs check-version and build.sh --dry-run and nothing that signs, notarizes or publishes',
      () {
        final wf = _workflow();
        final dispatch = _dispatchJobs(wf);
        expect(dispatch, isNotEmpty, reason: 'a job runs on dispatch');
        final release = _releaseJob(wf);
        expect(dispatch.keys, isNot(contains(release.key)));
        final runs = [
          for (final job in dispatch.values)
            for (final s in _steps(job)) _run(s),
        ].join('\n');
        expect(runs, contains(_checkVersion));
        final builds = _buildLines(runs).toList();
        expect(builds, isNotEmpty, reason: 'build.sh runs on dispatch');
        for (final line in builds) {
          expect(line, contains('--dry-run'), reason: line);
          expect(line, contains('--version'), reason: line);
        }
        expect(
          _text(dispatch.values.toList()),
          contains('inputs.version'),
          reason: 'the dry run uses the version input',
        );
        for (final forbidden in [
          RegExp(r'\bcodesign\b'),
          RegExp(r'\bnotarytool\b'),
          RegExp(r'\bstapler\b'),
          RegExp(r'security\s+(import|create-keychain)'),
          RegExp(r'gh\s+release\b'),
          RegExp(r'gh\s+api\b'),
        ]) {
          expect(
            forbidden.hasMatch(runs),
            isFalse,
            reason: 'the dry run never runs ${forbidden.pattern}',
          );
        }
        for (final e in dispatch.entries) {
          expect(e.value['environment'], isNull, reason: e.key);
          expect(_mentionsSecrets(e.value), isFalse, reason: e.key);
        }
      },
    );

    test('release.yml runs check-version.sh from the repo root', () {
      final wf = _workflow();
      var calls = 0;
      for (final e in _jobs(wf).entries) {
        final defaults = e.value['defaults'];
        for (final step in _steps(e.value)) {
          if (!_run(step).contains(_checkVersion)) continue;
          calls++;
          expect(
            step['working-directory'],
            anyOf(isNull, '.'),
            reason: 'check-version reads files from the cwd (${e.key})',
          );
          if (defaults is Map && defaults['run'] is Map) {
            expect(
              (defaults['run'] as Map)['working-directory'],
              anyOf(isNull, '.'),
              reason: e.key,
            );
          }
        }
      }
      expect(calls, greaterThanOrEqualTo(2), reason: 'dry run and release');
    });
  });

  group('toolchains and locked dependencies', () {
    test(
      'release.yml installs with flutter pub get --enforce-lockfile before each build',
      () {
        final raw = _rawWorkflow();
        expect(raw, contains('flutter pub get --enforce-lockfile'));
        for (final m in RegExp(r'flutter\s+pub\s+get[^\n]*').allMatches(raw)) {
          expect(m.group(0), contains('--enforce-lockfile'));
        }
        final jobs = _buildJobs(_workflow());
        expect(jobs, isNotEmpty);
        for (final e in jobs.entries) {
          final steps = _steps(e.value);
          final pubGet = _indexWhere(
            steps,
            (s) => _run(s).contains('flutter pub get --enforce-lockfile'),
          );
          final build = _indexWhere(steps, (s) => _runsBuild(_run(s)));
          expect(pubGet, greaterThanOrEqualTo(0), reason: e.key);
          expect(pubGet, lessThan(build), reason: e.key);
        }
      },
    );

    test(
      'release.yml builds cargo only through build.sh, which uses cargo build --locked',
      () {
        final raw = _rawWorkflow();
        for (final m in RegExp(r'cargo\s+build[^\n]*').allMatches(raw)) {
          expect(m.group(0), contains('--locked'));
        }
        final build = File('${repoRoot()}/$_buildScript').readAsStringSync();
        expect(
          RegExp(r'cargo build[^\n]*--locked').hasMatch(build),
          isTrue,
          reason: 'build.sh builds memex with --locked',
        );
        expect(_buildJobs(_workflow()), isNotEmpty);
      },
    );

    test(
      'each build job pins Flutter 3.47.5 stable and Rust 1.95.0 on an arm64 macOS runner and prints the Xcode version',
      () {
        final jobs = _buildJobs(_workflow());
        expect(
          jobs.length,
          greaterThanOrEqualTo(2),
          reason: 'dry run, release',
        );
        for (final e in jobs.entries) {
          expect(
            _arm64Runners,
            contains('${e.value['runs-on']}'),
            reason: e.key,
          );
          final steps = _steps(e.value);
          expect(
            steps.where((s) {
              final t = _text(s);
              return t.contains('3.47.5') && t.contains('stable');
            }),
            isNotEmpty,
            reason: '${e.key} pins Flutter 3.47.5 stable',
          );
          expect(
            steps.where((s) => _text(s).contains('1.95.0')),
            isNotEmpty,
            reason: '${e.key} pins Rust 1.95.0',
          );
          expect(
            steps.where((s) => _run(s).contains('xcodebuild -version')),
            isNotEmpty,
            reason: '${e.key} prints the Xcode version',
          );
        }
      },
    );

    test(
      'every action in release.yml is pinned to a full commit SHA with a version comment',
      () {
        final wf = _workflow();
        final uses = [
          for (final job in _jobs(wf).values)
            for (final s in _steps(job))
              if (s['uses'] != null) '${s['uses']}',
        ];
        expect(uses, isNotEmpty);
        for (final u in uses) {
          if (u.startsWith('./')) continue;
          expect(
            RegExp(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$').hasMatch(u),
            isTrue,
            reason: '$u is pinned to a commit SHA',
          );
        }
        final lines = _rawWorkflow()
            .split('\n')
            .where((l) => RegExp(r'^\s*-?\s*uses:').hasMatch(l));
        for (final l in lines) {
          if (l.contains('./')) continue;
          expect(
            RegExp(r'@[0-9a-f]{40}\s+#\s*\S+').hasMatch(l),
            isTrue,
            reason: 'version comment beside the SHA: $l',
          );
        }
      },
    );
  });

  group('detectors', () {
    for (final (name, text, expected) in [
      ('secret detector sees a dotted reference', r'${{ secrets.A }}', true),
      ('secret detector sees an index reference', r"${{ secrets['A'] }}", true),
      (
        'secret detector sees toJSON of all secrets',
        r'${{ toJSON(secrets) }}',
        true,
      ),
      ('secret detector ignores a variable reference', r'${{ vars.A }}', false),
      (
        'secret detector ignores the word in prose',
        'keep secrets out of logs',
        false,
      ),
    ]) {
      test(name, () => expect(_secretRef.hasMatch(text), expected));
    }

    for (final (name, text, expected) in [
      ('tracing detector sees set -x', 'set -x', true),
      ('tracing detector sees set -ex', 'set -ex', true),
      ('tracing detector sees set -euxo pipefail', 'set -euxo pipefail', true),
      ('tracing detector sees set -o xtrace', 'set -o xtrace', true),
      ('tracing detector sees bash -x', 'bash -x ./run.sh', true),
      ('tracing detector sees sh -ex', 'sh -ex run.sh', true),
      ('tracing detector sees a bash -x shell value', 'bash -x {0}', true),
      ('tracing detector ignores set -eo pipefail', 'set -eo pipefail', false),
      (
        'tracing detector ignores the default bash shell value',
        'bash --noprofile --norc -eo pipefail {0}',
        false,
      ),
      (
        'tracing detector ignores base64 flags',
        'openssl rand -base64 32',
        false,
      ),
    ]) {
      test(name, () => expect(_tracing.hasMatch(text), expected));
    }
  });

  group('shell', () {
    test(
      'release.yml runs every step in bash with the default error flags and no tracing',
      () {
        final wf = _workflow();
        final defaults = wf['defaults'];
        expect(defaults, isA<Map>());
        expect(
          ((defaults as Map)['run'] as Map)['shell'],
          'bash',
          reason: 'shell: bash means bash -eo pipefail, so a failed pipe stops',
        );
        for (final job in _jobs(wf).values) {
          final jd = job['defaults'];
          if (jd is Map && jd['run'] is Map) {
            expect((jd['run'] as Map)['shell'], anyOf(isNull, 'bash'));
          }
          for (final step in _steps(job)) {
            expect(
              step['shell'],
              anyOf(isNull, 'bash'),
              reason: 'step ${step['name']} keeps the bash default',
            );
          }
        }
      },
    );
  });

  group('release job steps run against a stub gh', () {
    // Each test runs the real `run:` text of one release-job step with
    // `bash -eo pipefail` (what `shell: bash` runs) in a fixture git repo,
    // with a stub `gh` first on PATH that logs every call and answers the
    // tag lookup and generate-notes. Nothing reaches the network.
    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const moved = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const repoName = 'example-owner/example-repo';
    const allTags = ['v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.10.0', 'v1.0.0'];

    Map<dynamic, dynamic> job() => _releaseJob(_workflow()).value;

    Map<dynamic, dynamic> stepWhere(bool Function(String run) test) {
      final found = _steps(job()).where((s) => test(_run(s))).toList();
      expect(found, hasLength(1), reason: 'exactly one matching step');
      return found.single;
    }

    // The step that only checks the tag (no gh release call).
    bool isTagCheck(String run) =>
        run.contains('commits/tags') && !run.contains('gh release');
    bool isCreate(String run) => _createsDraft(run);
    bool isPublish(String run) => _publishes(run);
    bool isUpload(String run) => _ghUpload.hasMatch(run);
    bool isBody(String run) => run.contains('generate-notes');

    const stubGh = r'''#!/bin/bash
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$STUB_LOG"
all="$*"
case "$1" in
  api)
    case "$all" in
      *generate-notes*)
        printf '%s\n' "$STUB_CHANGES"
        exit 0
        ;;
      *"repos/$GITHUB_REPOSITORY/commits/tags/$TAG"*|*"repos/$GITHUB_REPOSITORY/commits/refs/tags/$TAG"*|*"repos/$GITHUB_REPOSITORY/commits/$TAG"*)
        [ -z "${STUB_API_FAIL:-}" ] || exit 1
        printf '%s\n' "$STUB_TAG_SHA"
        exit 0
        ;;
    esac
    echo "stub gh: unexpected api call: $all" >&2
    exit 99
    ;;
  release)
    sub=$2
    shift 2
    case "$sub" in
      create)
        prev=""
        for a in "$@"; do
          if [ "$prev" = --notes-file ] && [ ! -f "$a" ]; then
            echo "stub gh: no notes file $a" >&2
            exit 1
          fi
          prev=$a
        done
        ;;
      upload)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --repo) shift 2 ;;
            -*) shift ;;
            *)
              if [ ! -f "$1" ]; then
                echo "stub gh: no such asset file: $1" >&2
                exit 1
              fi
              shift
              ;;
          esac
        done
        ;;
      edit) ;;
      *)
        echo "stub gh: unexpected release subcommand $sub" >&2
        exit 99
        ;;
    esac
    exit 0
    ;;
esac
echo "stub gh: unexpected call: $all" >&2
exit 99
''';

    // Emulates build.sh's CLI and output names (the names are pinned against
    // the real script by a test below).
    const stubBuild = r'''#!/bin/bash
ver="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) ver=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "stub build.sh: bad version $ver" >&2
  exit 2
fi
mkdir -p "$out"
for f in "Open-Memex-$ver-arm64.dmg" "memex-$ver-macos-arm64.zip" THIRD_PARTY_NOTICES.txt SHA256SUMS.txt; do
  : > "$out/$f"
done
''';

    Future<_StepEnv> setUpEnv() async {
      final iso = await isolatedEnv();
      final repo = Directory('${iso.work.path}/repo')..createSync();
      final bin = Directory('${iso.work.path}/bin')..createSync();
      final temp = Directory('${iso.work.path}/runner-temp')..createSync();
      final log = File('${iso.work.path}/gh.log');
      File('${bin.path}/gh').writeAsStringSync(stubGh);
      await Process.run('chmod', ['+x', '${bin.path}/gh']);
      File('${repo.path}/scripts/release/build.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync(stubBuild);
      await Process.run('chmod', [
        '+x',
        '${repo.path}/scripts/release/build.sh',
      ]);
      await runGit(iso, repo.path, ['init']);
      await runGit(iso, repo.path, ['commit', '--allow-empty', '-m', 'init']);
      for (final t in allTags) {
        await runGit(iso, repo.path, ['tag', t]);
        File('${repo.path}/release-notes/$t.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('NOTES-BODY $t\n');
      }
      return _StepEnv(iso, repo.path, bin.path, temp.path, log);
    }

    Future<_StepResult> runStep(
      _StepEnv e,
      Map<dynamic, dynamic> step, {
      required String tag,
      String tagSha = sha,
      bool apiFails = false,
    }) async {
      final r = await Process.run(
        'bash',
        ['-eo', 'pipefail', '-c', _run(step)],
        workingDirectory: e.repo,
        includeParentEnvironment: false,
        environment: {
          ...e.iso.env,
          'PATH': '${e.bin}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
          'TAG': tag,
          'GITHUB_SHA': sha,
          'GITHUB_REPOSITORY': repoName,
          'RUNNER_TEMP': e.temp,
          'GH_TOKEN': 'placeholder-token',
          'STUB_LOG': e.log.path,
          'STUB_TAG_SHA': tagSha,
          'STUB_CHANGES': 'STUB-CHANGES',
          if (apiFails) 'STUB_API_FAIL': '1',
        },
      );
      return _StepResult(
        r.exitCode,
        '${r.stdout}',
        '${r.stderr}',
        e.log.existsSync() ? e.log.readAsLinesSync() : const [],
      );
    }

    test(
      'the tag check step passes while the tag points at GITHUB_SHA and fails once it has moved',
      () async {
        final step = stepWhere(isTagCheck);
        final e = await setUpEnv();
        final ok = await runStep(e, step, tag: 'v0.2.0');
        expect(ok.exitCode, 0, reason: '$ok');
        expect(
          ok.calls.where((l) => l.startsWith('[api]') && l.contains('v0.2.0')),
          hasLength(1),
          reason: 'it asks the API where the tag points\n$ok',
        );
        final bad = await runStep(e, step, tag: 'v0.2.0', tagSha: moved);
        expect(bad.exitCode, 1, reason: '$bad');
        expect(bad.stderr, contains('v0.2.0'));
        expect(bad.stderr, contains(moved));
        expect(bad.stderr, contains(sha));
      },
    );

    test('the tag check step fails when the API call fails', () async {
      final e = await setUpEnv();
      final r = await runStep(
        e,
        stepWhere(isTagCheck),
        tag: 'v0.2.0',
        apiFails: true,
      );
      expect(r.exitCode, isNot(0), reason: 'fails closed: $r');
    });

    test('the tag check step fails when the API answers nothing', () async {
      final e = await setUpEnv();
      final r = await runStep(
        e,
        stepWhere(isTagCheck),
        tag: 'v0.2.0',
        tagSha: '',
      );
      expect(r.exitCode, 1, reason: '$r');
    });

    test(
      'the tag check step runs after checkout and before check-version and the build',
      () {
        final steps = _steps(job());
        final checkout = _indexWhere(
          steps,
          (s) => '${s['uses']}'.startsWith('actions/checkout@'),
        );
        final tagCheck = _indexWhere(steps, (s) => isTagCheck(_run(s)));
        final version = _indexWhere(
          steps,
          (s) => _run(s).contains(_checkVersion),
        );
        final build = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        expect(checkout, greaterThanOrEqualTo(0));
        expect(tagCheck, greaterThan(checkout));
        expect(tagCheck, lessThan(version));
        expect(tagCheck, lessThan(build));
      },
    );

    test(
      'the create step does not create the draft when the tag has moved or the lookup fails',
      () async {
        final step = stepWhere(isCreate);
        final e = await setUpEnv();
        final bad = await runStep(e, step, tag: 'v0.2.0', tagSha: moved);
        expect(bad.exitCode, 1, reason: '$bad');
        expect(
          bad.calls.where((l) => l.startsWith('[release]')),
          isEmpty,
          reason: 'no Release is created for a moved tag\n$bad',
        );
        final apiFail = await runStep(e, step, tag: 'v0.2.0', apiFails: true);
        expect(apiFail.exitCode, isNot(0), reason: '$apiFail');
        expect(apiFail.calls.where((l) => l.startsWith('[release]')), isEmpty);
      },
    );

    test(
      'the publish step does not publish when the tag has moved and publishes the draft when it has not',
      () async {
        final step = stepWhere(isPublish);
        final e = await setUpEnv();
        final bad = await runStep(e, step, tag: 'v0.2.0', tagSha: moved);
        expect(bad.exitCode, 1, reason: '$bad');
        expect(
          bad.calls.where((l) => l.startsWith('[release]')),
          isEmpty,
          reason: 'nothing is published for a moved tag\n$bad',
        );
        final apiFail = await runStep(e, step, tag: 'v0.2.0', apiFails: true);
        expect(apiFail.exitCode, isNot(0), reason: '$apiFail');
        expect(apiFail.calls.where((l) => l.startsWith('[release]')), isEmpty);
        final ok = await runStep(e, step, tag: 'v0.2.0');
        expect(ok.exitCode, 0, reason: '$ok');
        expect(ok.calls.where((l) => l.startsWith('[release][edit]')), [
          '[release][edit][v0.2.0][--repo][$repoName][--draft=false]',
        ], reason: '$ok');
      },
    );

    for (final (name, tag, prerelease) in [
      (
        'the create step makes a draft titled Open Memex 0.2.0 and marks 0.2.0 as a pre-release',
        'v0.2.0',
        true,
      ),
      (
        'the create step makes a draft titled Open Memex 0.10.0 and marks 0.10.0 as a pre-release',
        'v0.10.0',
        true,
      ),
      (
        'the create step makes a draft titled Open Memex 1.0.0 and does not mark 1.0.0 as a pre-release',
        'v1.0.0',
        false,
      ),
    ]) {
      test(name, () async {
        final e = await setUpEnv();
        final body = await runStep(e, stepWhere(isBody), tag: tag);
        expect(body.exitCode, 0, reason: '$body');
        final r = await runStep(e, stepWhere(isCreate), tag: tag);
        expect(r.exitCode, 0, reason: '$r');
        final creates = r.calls
            .where((l) => l.startsWith('[release][create]'))
            .toList();
        expect(creates, hasLength(1), reason: '$r');
        final version = tag.substring(1);
        final line = creates.single;
        expect(line, contains('[release][create][$tag]'));
        expect(line, contains('[--repo][$repoName]'));
        expect(line, contains('[--draft]'));
        expect(line, contains('[--verify-tag]'));
        expect(line, contains('[--title][Open Memex $version]'));
        expect(line, contains('[--notes-file][${e.temp}/release-body.md]'));
        expect(line.contains('[--prerelease]'), prerelease, reason: line);
      });
    }

    for (final (name, tag, previous) in [
      (
        'the body step asks generate-notes for changes since v0.1.0 when releasing v0.2.0',
        'v0.2.0',
        'v0.1.0',
      ),
      (
        'the body step sorts versions numerically so v0.10.0 follows v0.3.0',
        'v0.10.0',
        'v0.3.0',
      ),
      (
        'the body step picks the highest tag below v1.0.0 even when it is a later minor',
        'v1.0.0',
        'v0.10.0',
      ),
      ('the body step picks the tag just below v0.3.0', 'v0.3.0', 'v0.2.0'),
      (
        'the body step omits previous_tag_name for the first release v0.1.0',
        'v0.1.0',
        '',
      ),
    ]) {
      test(name, () async {
        final e = await setUpEnv();
        final r = await runStep(e, stepWhere(isBody), tag: tag);
        expect(r.exitCode, 0, reason: '$r');
        final api = r.calls.where((l) => l.contains('generate-notes')).toList();
        expect(api, hasLength(1), reason: '$r');
        expect(api.single, contains('[--method][POST]'));
        expect(api.single, contains('repos/$repoName/releases/generate-notes'));
        expect(api.single, contains('[tag_name=$tag]'));
        if (previous.isEmpty) {
          expect(api.single, isNot(contains('previous_tag_name')));
        } else {
          expect(api.single, contains('[previous_tag_name=$previous]'));
          expect(
            RegExp('previous_tag_name').allMatches(api.single),
            hasLength(1),
          );
        }
      });
    }

    test(
      'the body step writes the release notes, then a What changed heading, then the generated changes',
      () async {
        final e = await setUpEnv();
        final r = await runStep(e, stepWhere(isBody), tag: 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
        final body = File('${e.temp}/release-body.md').readAsStringSync();
        expect(
          body,
          "NOTES-BODY v0.2.0\n\n## What's changed\n\nSTUB-CHANGES\n",
        );
      },
    );

    test('the body step fails when the notes file is missing', () async {
      final e = await setUpEnv();
      File('${e.repo}/release-notes/v0.2.0.md').deleteSync();
      final r = await runStep(e, stepWhere(isBody), tag: 'v0.2.0');
      expect(r.exitCode, isNot(0), reason: '$r');
    });

    test(
      'the upload step names exactly the four files the build step writes to its out directory',
      () async {
        final e = await setUpEnv();
        final build = _steps(job()).firstWhere((s) => _runsBuild(_run(s)));
        final b = await runStep(e, build, tag: 'v0.2.0');
        expect(b.exitCode, 0, reason: 'the build step ran its stub\n$b');
        final r = await runStep(e, stepWhere(isUpload), tag: 'v0.2.0');
        expect(r.exitCode, 0, reason: 'every uploaded file exists\n$r');
        final uploads = r.calls
            .where((l) => l.startsWith('[release][upload]'))
            .toList();
        expect(uploads, hasLength(1), reason: '$r');
        final out = RegExp(
          r'--out\s+(\S+)',
        ).firstMatch(_run(build))!.group(1)!.replaceAll('"', '');
        expect(
          uploads.single,
          '[release][upload][v0.2.0][--repo][$repoName]'
          '[$out/Open-Memex-0.2.0-arm64.dmg]'
          '[$out/memex-0.2.0-macos-arm64.zip]'
          '[$out/THIRD_PARTY_NOTICES.txt]'
          '[$out/SHA256SUMS.txt]',
        );
        final built = Directory(
          '${e.repo}/$out',
        ).listSync().map((f) => f.path.split('/').last).toSet();
        expect(built, {
          'Open-Memex-0.2.0-arm64.dmg',
          'memex-0.2.0-macos-arm64.zip',
          'THIRD_PARTY_NOTICES.txt',
          'SHA256SUMS.txt',
        });
      },
    );

    test('the stub build.sh uses the asset names of the real build.sh', () {
      final src = File('${repoRoot()}/$_buildScript').readAsStringSync();
      expect(src, contains(r'DMG_NAME="Open-Memex-$VERSION-arm64.dmg"'));
      expect(src, contains(r'ZIP_NAME="memex-$VERSION-macos-arm64.zip"'));
      expect(src, contains('NOTICES_NAME=THIRD_PARTY_NOTICES.txt'));
      expect(src, contains('SUMS_NAME=SHA256SUMS.txt'));
      expect(src, contains('--out'), reason: 'build.sh takes --out <dir>');
    });

    test(
      'every release job step that calls gh gets GH_TOKEN and every step that reads TAG sees it from the ref name',
      () {
        final wf = _workflow();
        final j = job();
        for (final step in _steps(j)) {
          final env = _envOf(wf, j, step);
          if (RegExp(r'\bgh\s').hasMatch(_run(step))) {
            expect(
              env['GH_TOKEN'],
              contains('github.token'),
              reason: 'step ${step['name']} calls gh',
            );
          }
          if (_run(step).contains(r'$TAG')) {
            expect(
              env['TAG'],
              contains('github.ref_name'),
              reason: 'step ${step['name']} reads TAG',
            );
          }
        }
      },
    );
  });
}

/// A fixture for running one workflow step: a repo, a stub-gh bin directory,
/// a RUNNER_TEMP and the stub's call log.
class _StepEnv {
  _StepEnv(this.iso, this.repo, this.bin, this.temp, this.log);

  final IsolatedEnv iso;
  final String repo;
  final String bin;
  final String temp;
  final File log;
}

class _StepResult {
  _StepResult(this.exitCode, this.stdout, this.stderr, this.calls);

  final int exitCode;
  final String stdout;
  final String stderr;

  /// The stub gh's call log, one line per call, each argument in brackets.
  final List<String> calls;

  @override
  String toString() =>
      'StepResult(exit $exitCode)\n--- stdout ---\n$stdout\n--- stderr ---\n$stderr\n--- gh calls ---\n${calls.join('\n')}';
}
