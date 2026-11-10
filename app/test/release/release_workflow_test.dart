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

final _secretRef = RegExp(r'\bsecrets\s*(\.|\[)');

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
              RegExp(r'set\s+-[a-wyz]*x|set\s+-o\s+xtrace').hasMatch(run),
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
}
