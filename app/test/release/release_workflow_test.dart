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
//
// Self-update (#36, Spec #31 reqs 5, 8, D11, D18):
//   key decode  a release-job step whose env reads
//               secrets.SPARKLE_ED_PRIVATE_KEY_BASE64 and whose run decodes
//               it under `umask 077` to `$RUNNER_TEMP/sparkle-ed-key`
//   appcast-input  the release-job step right after the build: a SHA-pinned
//               actions/upload-artifact named `appcast-input` whose path
//               matches exactly the build's `.edsig` and `.length` files
//   appcast job `jobs.appcast`. Its steps run, in order: a checkout of the
//               tag (persist-credentials: false), the SHA-pinned
//               actions/download-artifact of `appcast-input`, a run step that
//               fails with a message naming gh-pages when the branch does not
//               exist, a checkout of gh-pages (actions/checkout with
//               `ref: gh-pages` and a `path`, or a git clone in a run step),
//               scripts/release/generate_appcast.sh from the tag checkout, and
//               a git push of gh-pages authenticated with github.token.
//               The group `appcast job runs against a fixture remote` runs
//               those steps for real against a local bare repo.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:yaml/yaml.dart';

import 'support/script_harness.dart';

const _workflowPath = '.github/workflows/release.yml';
const _checkVersion = 'scripts/release/check-version.sh';
const _buildScript = 'scripts/release/build.sh';
const _generator = 'scripts/release/generate_appcast.sh';
const _keySecret = 'SPARKLE_ED_PRIVATE_KEY_BASE64';
const _releasingDoc = 'docs/releasing.md';

const _releaseSecrets = [
  'MACOS_CERT_P12_BASE64',
  'MACOS_CERT_PASSWORD',
  'NOTARY_KEY_P8_BASE64',
  'NOTARY_KEY_ID',
  'NOTARY_ISSUER_ID',
  'LEAK_PATTERNS',
  _keySecret,
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
      'top-level permissions are contents read and only the release and appcast jobs have contents write',
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
        final writers = {release.key, 'appcast'};
        expect(
          _jobs(wf).keys,
          contains('appcast'),
          reason: 'the appcast job exists',
        );
        for (final name in writers) {
          final p = _jobs(wf)[name]!['permissions'];
          expect(p, isA<Map>(), reason: 'the $name job sets permissions');
          expect((p as Map)['contents'], 'write', reason: name);
          expect(
            p.entries.where((e) => e.value == 'write').map((e) => '${e.key}'),
            ['contents'],
            reason: 'contents is the only scope the $name job writes',
          );
        }
        for (final e in _jobs(wf).entries) {
          if (writers.contains(e.key)) continue;
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
        expect(
          [
            for (final e in _jobs(wf).entries)
              if (e.value['environment'] != null) e.key,
          ],
          [release.key],
          reason: 'release is the only job bound to any environment',
        );
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
      'each build job pins Flutter 3.50.1 stable and Rust 1.95.0 on an arm64 macOS runner and prints the Xcode version',
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
              return t.contains('3.50.1') && t.contains('stable');
            }),
            isNotEmpty,
            reason: '${e.key} pins Flutter 3.50.1 stable',
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
# build.sh's EdDSA outputs for the appcast job (Spec #31 req 6), one line each.
printf 'c2lnbmF0dXJl\n' > "$out/Open-Memex-$ver-arm64.dmg.edsig"
printf '0\n' > "$out/Open-Memex-$ver-arm64.dmg.length"
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
          'Open-Memex-0.2.0-arm64.dmg.edsig',
          'Open-Memex-0.2.0-arm64.dmg.length',
        });
      },
    );

    test(
      'the appcast-input upload matches exactly the edsig and length files the build step writes',
      () async {
        final e = await setUpEnv();
        final steps = _steps(job());
        final buildAt = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        final b = await runStep(e, steps[buildAt], tag: 'v0.2.0');
        expect(b.exitCode, 0, reason: 'the build step ran its stub\n$b');
        final upload = _appcastInputUpload(steps);
        expect(upload, isNotNull, reason: 'an appcast-input upload step');
        final patterns = '${_with(upload!)['path'] ?? ''}'
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        expect(patterns, isNotEmpty, reason: 'the upload names its files');
        final files = [
          for (final f in Directory(e.repo).listSync(recursive: true))
            if (f is File && !f.path.contains('/.git/'))
              f.path.substring(e.repo.length + 1),
        ];
        final matched = {
          for (final p in patterns)
            for (final f in files)
              if (_glob(p).hasMatch(f)) f,
        };
        expect(matched, {
          'dist/Open-Memex-0.2.0-arm64.dmg.edsig',
          'dist/Open-Memex-0.2.0-arm64.dmg.length',
        }, reason: 'only the signature and length, never the DMG itself');
      },
    );

    test(
      'the key decode step writes the decoded key to RUNNER_TEMP sparkle-ed-key with mode 600 and prints nothing',
      () async {
        final e = await setUpEnv();
        final steps = _steps(job());
        final decodeAt = _keyDecodeAt(steps);
        expect(decodeAt, greaterThanOrEqualTo(0), reason: 'a key decode step');
        final step = steps[decodeAt];
        // What `generate_keys -x` exports, base64 again as the secret.
        const exported = 'ZmFrZS1lZDI1NTE5LXNlZWQtZm9yLXRlc3RzLW9ubHk=\n';
        final secret = base64.encode(utf8.encode(exported));
        final secretEnv = {
          for (final en in ((step['env'] as Map?) ?? const {}).entries)
            if ('${en.value}'.contains('secrets.$_keySecret'))
              '${en.key}': secret,
        };
        expect(secretEnv, isNotEmpty, reason: 'the secret reaches it via env');
        final r = await Process.run(
          'bash',
          ['-eo', 'pipefail', '-c', 'umask 022\n${_run(step)}'],
          workingDirectory: e.repo,
          includeParentEnvironment: false,
          environment: {
            ...e.iso.env,
            'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
            'RUNNER_TEMP': e.temp,
            ...secretEnv,
          },
        );
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        final key = File('${e.temp}/sparkle-ed-key');
        expect(key.existsSync(), isTrue);
        expect(key.readAsStringSync(), exported);
        expect(
          key.statSync().mode & 0x1ff,
          0x180,
          reason: 'mode 600 under umask 077, whatever the runner umask is',
        );
        final out = '${r.stdout}${r.stderr}';
        expect(out, isNot(contains(secret)));
        expect(out, isNot(contains(exported.trim())));
      },
    );

    test(
      'the always step deletes RUNNER_TEMP sparkle-ed-key with the other key files',
      () async {
        final e = await setUpEnv();
        final steps = _steps(job());
        final cleanup = steps
            .where(
              (s) =>
                  _isAlways(s) && _run(s).contains('security delete-keychain'),
            )
            .single;
        expect(_run(cleanup), matches(RegExp(r'rm\s+-f[^\n]*sparkle-ed-key')));
        File('${e.bin}/security').writeAsStringSync(
          '#!/bin/bash\necho "security \$*" >> "\$STUB_LOG"\n',
        );
        await Process.run('chmod', ['+x', '${e.bin}/security']);
        for (final name in [
          'sparkle-ed-key',
          'notary-key.p8',
          'release-signing.p12',
        ]) {
          File('${e.temp}/$name').writeAsStringSync('x');
        }
        final r = await runStep(e, cleanup, tag: 'v0.2.0');
        expect(r.exitCode, 0, reason: '$r');
        expect(File('${e.temp}/sparkle-ed-key').existsSync(), isFalse);
        expect(File('${e.temp}/notary-key.p8').existsSync(), isFalse);
        final again = await runStep(e, cleanup, tag: 'v0.2.0');
        expect(again.exitCode, 0, reason: 'nothing to delete is fine\n$again');
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

  group('EdDSA key in the release job', () {
    test(
      'the release job decodes SPARKLE_ED_PRIVATE_KEY_BASE64 under umask 077 to RUNNER_TEMP sparkle-ed-key before the build',
      () {
        final steps = _steps(_releaseJob(_workflow()).value);
        final decodeAt = _keyDecodeAt(steps);
        expect(decodeAt, greaterThanOrEqualTo(0), reason: 'a key decode step');
        final run = _run(steps[decodeAt]);
        expect(
          RegExp(
            r'umask\s+0?077\b[\s\S]*base64\s+(--decode|-d|-D)\b',
          ).hasMatch(run),
          isTrue,
          reason: 'umask 077, then the decode:\n$run',
        );
        expect(
          RegExp(r'\$\{?RUNNER_TEMP\}?/sparkle-ed-key\b').hasMatch(run),
          isTrue,
          reason: run,
        );
        final buildAt = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        expect(decodeAt, lessThan(buildAt), reason: 'decoded before build');
      },
    );

    test(
      'the build step gets SPARKLE_ED_KEY_PATH set to the decoded key file and never the key itself',
      () {
        final wf = _workflow();
        final job = _releaseJob(wf).value;
        final steps = _steps(job);
        final buildAt = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        final env = _envOf(wf, job, steps[buildAt]);
        expect(
          env['SPARKLE_ED_KEY_PATH']?.replaceAll(RegExp(r'\s'), ''),
          r'${{runner.temp}}/sparkle-ed-key',
        );
        expect(_text(steps[buildAt]), isNot(contains(_keySecret)));
        final readers = [
          for (final j in _jobs(wf).values)
            for (final s in _steps(j))
              if (_text(s).contains(_keySecret)) '${s['name']}',
        ];
        expect(
          readers,
          hasLength(1),
          reason: 'only the decode step sees the private key: $readers',
        );
        expect(
          _text(job['env']),
          isNot(contains(_keySecret)),
          reason: 'not in the job env, where every step would see it',
        );
      },
    );
  });

  group('appcast-input upload', () {
    test(
      'the release job uploads appcast-input with a SHA-pinned upload-artifact right after the build step and still publishes last',
      () {
        final steps = _steps(_releaseJob(_workflow()).value);
        final buildAt = _indexWhere(steps, (s) => _runsBuild(_run(s)));
        expect(buildAt, greaterThanOrEqualTo(0));
        final upload = _appcastInputUpload(steps);
        expect(upload, isNotNull, reason: 'an appcast-input upload step');
        expect(
          steps.indexOf(upload!),
          buildAt + 1,
          reason: 'right after Build, sign and notarize',
        );
        expect(
          '${upload['uses']}',
          matches(RegExp(r'^actions/upload-artifact@[0-9a-f]{40}$')),
        );
        expect(
          _with(upload)['if-no-files-found'],
          'error',
          reason: 'a build without the .edsig or .length fails the job',
        );
        expect(upload['if'], isNull, reason: 'runs only when the build did');
        expect(upload['continue-on-error'], anyOf(isNull, isFalse));
        final runs = [for (final s in steps) _run(s)];
        expect(
          runs.indexWhere(_publishes),
          steps.lastIndexWhere((s) => !_isAlways(s)),
          reason: 'Publish the Release is still the last step',
        );
      },
    );
  });

  group('appcast job', () {
    test(
      'the appcast job needs release, has the release job if without always and runs on macos-15',
      () {
        final wf = _workflow();
        final job = _appcastJob(wf);
        final needs = job['needs'];
        expect(needs is List ? needs.map((n) => '$n').toList() : ['$needs'], [
          'release',
        ]);
        final release = _releaseJob(wf).value;
        expect(_cond(job), _cond(release), reason: 'the release job if');
        expect(_cond(job), isNot(contains('always()')));
        expect(_cond(job), isNot(contains('failure()')));
        expect(job['runs-on'], 'macos-15');
        expect(job['continue-on-error'], anyOf(isNull, isFalse));
      },
    );

    test(
      'the appcast job has contents write only, no environment and no secrets',
      () {
        final job = _appcastJob(_workflow());
        final p = job['permissions'];
        expect(p, isA<Map>());
        expect(
          Map<String, String>.from(
            (p as Map).map((k, v) => MapEntry('$k', '$v')),
          ),
          {'contents': 'write'},
        );
        expect(job['environment'], isNull);
        expect(_mentionsSecrets(job), isFalse);
      },
    );

    test(
      'the appcast job downloads appcast-input with a SHA-pinned download-artifact',
      () {
        final steps = _steps(_appcastJob(_workflow()));
        final downloads = [
          for (final s in steps)
            if (_usesAction(s, 'actions/download-artifact')) s,
        ];
        expect(downloads, hasLength(1));
        expect(
          '${downloads.single['uses']}',
          matches(RegExp(r'^actions/download-artifact@[0-9a-f]{40}$')),
        );
        expect(_with(downloads.single)['name'], 'appcast-input');
      },
    );

    test(
      'the appcast job uses concurrency group appcast without cancelling in progress',
      () {
        final c = _appcastJob(_workflow())['concurrency'];
        expect(c, isA<Map>());
        expect('${(c as Map)['group']}', 'appcast');
        expect(c['cancel-in-progress'], isFalse);
      },
    );

    test(
      'the appcast job checks out the tag without persisting credentials',
      () {
        final steps = _steps(_appcastJob(_workflow()));
        final tagCheckouts = steps.where(_isTagCheckout).toList();
        expect(tagCheckouts, isNotEmpty, reason: 'a checkout of the tag');
        for (final s in tagCheckouts) {
          expect(_with(s)['persist-credentials'], isFalse, reason: '$s');
        }
      },
    );

    test('the appcast job pushes gh-pages with github.token', () {
      final wf = _workflow();
      final job = _appcastJob(wf);
      final steps = _steps(job);
      final pushes = [
        for (final s in steps)
          if (_gitPush.hasMatch(_run(s))) s,
      ];
      expect(pushes, hasLength(1), reason: 'one push step');
      final push = pushes.single;
      expect(
        RegExp(r'--force\b|\s-f\b|\+\S*gh-pages').hasMatch(_run(push)),
        isFalse,
        reason: 'never a force push: gh-pages keeps its history',
      );
      final pushEnv = _envOf(wf, job, push).values.join('\n');
      final pagesTokens = [
        for (final s in steps)
          if (_isPagesCheckout(s)) '${_with(s)['token'] ?? ''}',
      ].join('\n');
      expect(
        pushEnv.contains('github.token') ||
            pagesTokens.contains('github.token'),
        isTrue,
        reason: 'the push is authenticated with github.token',
      );
      for (final s in steps) {
        if (RegExp(r'\bgh\s').hasMatch(_run(s))) {
          expect(
            _envOf(wf, job, s)['GH_TOKEN'],
            contains('github.token'),
            reason: 'step ${s['name']} calls gh',
          );
        }
      }
    });

    test(
      'the appcast job runs the generator from the tag checkout after the download and before the push',
      () {
        final steps = _steps(_appcastJob(_workflow()));
        final genAt = _indexWhere(steps, (s) => _run(s).contains(_generator));
        expect(genAt, greaterThanOrEqualTo(0), reason: 'the generator runs');
        final gen = steps[genAt];
        expect(
          gen['working-directory'],
          anyOf(isNull, '.'),
          reason: 'the script comes from the tag checkout root',
        );
        final line = _run(
          gen,
        ).split('\n').firstWhere((l) => l.contains(_generator));
        expect(
          RegExp(
            r'(^|[\s;&|])(\./)?scripts/release/generate_appcast\.sh\b',
          ).hasMatch(line),
          isTrue,
          reason: 'the tag checkout copy, never one from gh-pages: $line',
        );
        for (final flag in ['--version', '--input', '--appcast']) {
          expect(line, contains(flag));
        }
        final tagAt = _indexWhere(steps, _isTagCheckout);
        final downloadAt = _indexWhere(
          steps,
          (s) => _usesAction(s, 'actions/download-artifact'),
        );
        final pushAt = _indexWhere(steps, (s) => _gitPush.hasMatch(_run(s)));
        expect(tagAt, lessThan(genAt));
        expect(downloadAt, inExclusiveRange(-1, genAt));
        expect(pushAt, greaterThan(genAt));
        expect(
          steps.where((s) => '${s['uses'] ?? ''}'.startsWith('./')),
          isEmpty,
          reason: 'no local action, which could come from gh-pages',
        );
      },
    );

    test('release.yml never sets SELF_UPDATE_APPCAST_URL', () {
      expect(_rawWorkflow(), isNot(contains('SELF_UPDATE_APPCAST_URL')));
    });
  });

  group('appcast job runs against a fixture remote', () {
    // Runs every step of jobs.appcast in order against a local bare repo
    // standing in for github.com (git url.insteadOf), with a stub gh that
    // answers branch lookups from that repo. actions/checkout and
    // actions/download-artifact are simulated; run steps run for real with
    // `bash -eo pipefail`.
    const timeout = Timeout(Duration(minutes: 3));

    test(
      'the appcast job publishes the item to gh-pages on the fixture remote and keeps its history and nojekyll file',
      () async {
        final sim = await _AppcastSim.create(pages: _Pages.branch);
        final before = await sim.pagesTip();
        final run = await sim.runJob(_workflow());
        expect(run.ok, isTrue, reason: '$run');
        final items = parseAppcast(await sim.remoteAppcast());
        expect(items, hasLength(1), reason: '$run');
        final item = items.single;
        expect(item.shortVersionString, '1.2.3');
        expect(item.version, '42');
        expect(item.notes, _AppcastSim.notes);
        expect(item.edSignature, 'c2lnbmF0dXJlLWZvci0xLjIuMw==');
        expect(item.length, 38123456);
        expect(item.minimumSystemVersion, '14.0');
        expect(
          item.url,
          'https://github.com/connordodge/open_memex/releases/download/v1.2.3/Open-Memex-1.2.3-arm64.dmg',
        );
        expect(
          await sim.pagesFiles(),
          containsAll(['.nojekyll', 'appcast.xml']),
        );
        expect(
          await sim.isAncestor(before!, 'refs/heads/gh-pages'),
          isTrue,
          reason: 'a new commit on gh-pages, not a replaced history',
        );
      },
      timeout: timeout,
    );

    test(
      'the appcast job push authenticates through a credential helper that supplies github.token and never stores it',
      () async {
        final sim = await _AppcastSim.create(pages: _Pages.branch);
        final run = await sim.runJob(_workflow());
        expect(run.ok, isTrue, reason: '$run');
        final log = File(sim.pushLog).readAsStringSync();
        final argvLines = [
          for (final l in log.split('\n'))
            if (l.startsWith('ARGV: ')) l,
        ];
        expect(argvLines, hasLength(1), reason: 'one push\n$log');
        expect(log, contains('CRED: username=x-access-token'), reason: log);
        expect(log, contains('CRED: password=placeholder-token'), reason: log);
        expect(
          argvLines.single,
          isNot(contains('placeholder-token')),
          reason: 'the token is never on a command line',
        );
        final config = File(
          '${sim.workspace}/gh-pages/.git/config',
        ).readAsStringSync();
        expect(
          config,
          isNot(contains('placeholder-token')),
          reason: 'the token is never written to .git/config',
        );
        expect(
          config,
          isNot(contains('credential')),
          reason: 'the helper is set for the push only',
        );
      },
      timeout: timeout,
    );

    test(
      'rerunning the appcast job for the same Release succeeds and keeps one item',
      () async {
        final sim = await _AppcastSim.create(pages: _Pages.branch);
        final first = await sim.runJob(_workflow());
        expect(first.ok, isTrue, reason: '$first');
        final second = await sim.runJob(_workflow());
        expect(second.ok, isTrue, reason: 'Re-run failed jobs works\n$second');
        final items = parseAppcast(await sim.remoteAppcast());
        expect(items.map((i) => i.shortVersionString), ['1.2.3']);
      },
      timeout: timeout,
    );

    for (final (name, pages) in [
      (
        'the appcast job fails in its own step naming gh-pages and creates no branch when gh-pages is missing',
        _Pages.none,
      ),
      (
        'the appcast job fails in its own step naming gh-pages when only a gh-pages tag exists',
        _Pages.tagOnly,
      ),
    ]) {
      test(name, () async {
        final sim = await _AppcastSim.create(pages: pages);
        final wf = _workflow();
        final run = await sim.runJob(wf);
        expect(run.ok, isFalse, reason: '$run');
        final failed = run.steps.last;
        expect(
          failed.isRun,
          isTrue,
          reason: 'a run step of the job reports it, not a checkout\n$run',
        );
        expect(failed.output, contains('gh-pages'), reason: '$run');
        expect(
          run.steps.where((s) => s.ranGenerator),
          isEmpty,
          reason: 'it stops before the generator\n$run',
        );
        expect(await sim.pagesTip(), isNull, reason: 'no branch is created');
      }, timeout: timeout);
    }

    test(
      'the appcast job fails and leaves gh-pages unchanged when an appcast-input file is missing',
      () async {
        final sim = await _AppcastSim.create(pages: _Pages.branch);
        File('${sim.artifact}/Open-Memex-1.2.3-arm64.dmg.length').deleteSync();
        final before = await sim.pagesTip();
        final run = await sim.runJob(_workflow());
        expect(run.ok, isFalse, reason: '$run');
        expect(await sim.pagesTip(), before);
      },
      timeout: timeout,
    );
  });

  group('docs', () {
    String doc() {
      final f = File('${repoRoot()}/$_releasingDoc');
      expect(f.existsSync(), isTrue);
      return f.readAsStringSync();
    }

    test(
      'releasing.md documents the Self-update one-time setup with the keypair, secret, public key, gh-pages and Pages',
      () {
        final d = doc();
        for (final s in [
          'generate_keys',
          '-x',
          _keySecret,
          'sparkleEdPublicKey',
          'app/lib/src/updater/sparkle_ed_public_key.dart',
          'gh-pages',
          '.nojekyll',
          'GitHub Pages',
          'https://connordodge.github.io/open_memex/appcast.xml',
        ]) {
          expect(d, contains(s), reason: 'releasing.md mentions $s');
        }
        expect(
          RegExp(
            '\\|\\s*`$_keySecret`\\s*\\|\\s*environment secret\\s*\\|',
          ).hasMatch(d),
          isTrue,
          reason: 'the release environment table lists the key secret',
        );
      },
    );

    test(
      'releasing.md documents the appcast job and recovery with Re-run failed jobs',
      () {
        final d = doc();
        expect(d, contains('`appcast` job'));
        expect(d, contains('appcast-input'));
        expect(d, contains('Re-run failed jobs'));
        expect(d, contains(_generator));
      },
    );

    test('releasing.md documents key rotation and the Pages cache', () {
      final d = doc().toLowerCase();
      expect(d, contains('rotat'), reason: 'key rotation');
      expect(d, contains('old key'), reason: 'sign with the old key');
      expect(d, contains('10 minutes'), reason: 'the Pages cache');
    });
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
// ---------------------------------------------------------------------------
// Self-update helpers (#36).

Map<dynamic, dynamic> _appcastJob(Map<dynamic, dynamic> wf) {
  final job = _jobs(wf)['appcast'];
  expect(job, isNotNull, reason: 'release.yml has an appcast job');
  return job!;
}

Map<dynamic, dynamic> _with(Map<dynamic, dynamic> step) =>
    step['with'] is Map ? step['with'] as Map : const {};

bool _usesAction(Map<dynamic, dynamic> step, String action) =>
    '${step['uses'] ?? ''}'.startsWith('$action@');

bool _isPagesCheckout(Map<dynamic, dynamic> step) =>
    _usesAction(step, 'actions/checkout') &&
    RegExp(
      r'^(refs/heads/)?gh-pages$',
    ).hasMatch('${_with(step)['ref'] ?? ''}'.trim());

bool _isTagCheckout(Map<dynamic, dynamic> step) =>
    _usesAction(step, 'actions/checkout') && !_isPagesCheckout(step);

final _gitPush = RegExp(r'\bgit\b[^\n;&|]*\spush\b');

/// The release-job step that reads the private-key secret.
int _keyDecodeAt(List<Map<dynamic, dynamic>> steps) =>
    steps.indexWhere((s) => _text(s['env']).contains('secrets.$_keySecret'));

/// The upload-artifact step named appcast-input, or null.
Map<dynamic, dynamic>? _appcastInputUpload(List<Map<dynamic, dynamic>> steps) {
  for (final s in steps) {
    if (_usesAction(s, 'actions/upload-artifact') &&
        _with(s)['name'] == 'appcast-input') {
      return s;
    }
  }
  return null;
}

/// An upload-artifact path pattern as a regex over repo-relative paths: `*`
/// within a segment, `**` across segments, and any `${{ }}` expression as a
/// wildcard.
RegExp _glob(String pattern) {
  var p = pattern
      .replaceAll(RegExp(r'\$\{\{\s*github\.workspace\s*\}\}/'), '')
      .replaceAll(RegExp(r'\$\{\{[^}]*\}\}'), '\u0000');
  if (p.startsWith('./')) p = p.substring(2);
  final b = StringBuffer('^');
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (c == '*' && i + 1 < p.length && p[i + 1] == '*') {
      b.write('.*');
      i++;
    } else if (c == '*' || c == '\u0000') {
      b.write('[^/]*');
    } else if (c == '?') {
      b.write('[^/]');
    } else {
      b.write(RegExp.escape(c));
    }
  }
  b.write(r'$');
  return RegExp(b.toString());
}

enum _Pages { branch, none, tagOnly }

/// One simulated step of the appcast job.
class _SimStep {
  _SimStep(
    this.name,
    this.exitCode,
    this.output, {
    required this.isRun,
    this.ranGenerator = false,
  });

  final String name;
  final int exitCode;
  final String output;
  final bool isRun;
  final bool ranGenerator;

  @override
  String toString() =>
      '--- ${isRun ? 'run' : 'uses'}: $name (exit $exitCode)\n$output';
}

class _JobRun {
  _JobRun(this.steps);

  final List<_SimStep> steps;

  bool get ok => steps.isNotEmpty && steps.every((s) => s.exitCode == 0);

  @override
  String toString() => 'JobRun(ok: $ok)\n${steps.join('\n')}';
}

/// A fixture for running jobs.appcast: a bare repo standing in for
/// github.com/example-owner/example-repo (tag v1.2.3 holding the real
/// generator, a pubspec 1.2.3+42, the notes and the real pbxproj; gh-pages
/// per [_Pages]), the tag checkout as GITHUB_WORKSPACE, the appcast-input
/// artifact, RUNNER_TEMP and a stub gh.
class _AppcastSim {
  _AppcastSim._(this.iso, this.w, this.sha);

  static const repoName = 'example-owner/example-repo';
  static const notes = '## Highlights\n- Self-update ]]> & more\n';

  final IsolatedEnv iso;
  final String w;
  final String sha;

  String get remotes => '$w/remotes';
  String get bare => '$remotes/$repoName.git';
  String get workspace => '$w/workspace';
  String get artifact => '$w/artifact';
  String get temp => '$w/runner-temp';
  String get bin => '$w/bin';
  String get jobGitConfig => '$w/job-gitconfig';
  String get pushLog => '$w/git-push.log';

  static const _stubGh = r'''#!/bin/bash
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$STUB_LOG"
all="$*"
if [ "$1" = api ]; then
  case "$all" in
    *"repos/$GITHUB_REPOSITORY/branches/gh-pages"*|*"repos/$GITHUB_REPOSITORY/git/ref/heads/gh-pages"*|*"repos/$GITHUB_REPOSITORY/git/refs/heads/gh-pages"*)
      if git --git-dir="$STUB_REMOTE" rev-parse --verify --quiet refs/heads/gh-pages >/dev/null; then
        case "$all" in
          *--jq*) printf 'gh-pages\n' ;;
          *) printf '{"name":"gh-pages"}\n' ;;
        esac
        exit 0
      fi
      printf '{"message":"Branch not found","status":"404"}\n'
      echo 'gh: Branch not found (HTTP 404)' >&2
      exit 1
      ;;
  esac
fi
echo "stub gh: unexpected call: $all" >&2
exit 99
''';

  // A git in front of the real one. For a push it first runs the credential
  // lookup git itself would run for an https remote, with the same leading
  // -c settings, and logs what came back and the push command line. The
  // simulator rewrites https://github.com/ to a local path, and git never
  // asks a credential helper about a local path, so without this nothing
  // would ever run the helper the push step sets.
  static const _stubGit = r'''#!/bin/bash
real=$(PATH="${PATH#"$STUB_BIN":}" command -v git)
args=("$@")
cfg=()
i=0
while [ "${args[$i]:-}" = -c ]; do
  cfg+=(-c "${args[$((i + 1))]}")
  i=$((i + 2))
done
if [ "${args[$i]:-}" = push ]; then
  {
    printf 'ARGV: %s\n' "$*"
    printf 'protocol=https\nhost=github.com\n\n' |
      "$real" ${cfg[@]+"${cfg[@]}"} credential fill 2>&1 | sed 's/^/CRED: /' || true
  } >> "$STUB_PUSH_LOG"
fi
exec "$real" "$@"
''';

  static Future<_AppcastSim> create({required _Pages pages}) async {
    final iso = await isolatedEnv();
    final w = iso.work.path;
    final root = repoRoot();

    final src = '$w/src';
    final gen = File('$root/$_generator');
    if (gen.existsSync()) {
      gen.copySync(
        (File('$src/$_generator')..createSync(recursive: true)).path,
      );
      await Process.run('chmod', ['+x', '$src/$_generator']);
    }
    File('$src/app/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('name: open_memex_app\nversion: 1.2.3+42\n');
    File('$src/release-notes/v1.2.3.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(notes);
    const pbx = 'app/macos/Runner.xcodeproj/project.pbxproj';
    File(
      '$root/$pbx',
    ).copySync((File('$src/$pbx')..createSync(recursive: true)).path);
    await runGit(iso, src, ['init', '-q']);
    await runGit(iso, src, ['add', '-A']);
    await runGit(iso, src, ['commit', '-q', '-m', 'release 1.2.3']);
    await runGit(iso, src, ['tag', 'v1.2.3']);
    final sha = (await runGit(iso, src, ['rev-parse', 'HEAD'])).stdout.trim();

    final sim = _AppcastSim._(iso, w, sha);
    Directory('${sim.remotes}/example-owner').createSync(recursive: true);
    await runGit(iso, w, ['clone', '-q', '--bare', src, sim.bare]);
    Link('${sim.remotes}/$repoName').createSync(sim.bare);

    if (pages != _Pages.none) {
      final p = '$w/pages';
      Directory(p).createSync();
      File('$p/.nojekyll').writeAsStringSync('');
      File('$p/appcast.xml').writeAsStringSync(
        File(
          '$root/app/test/fixtures/updater/appcast_empty_channel.xml',
        ).readAsStringSync(),
      );
      await runGit(iso, p, ['init', '-q']);
      await runGit(iso, p, ['add', '-A']);
      await runGit(iso, p, ['commit', '-q', '-m', 'empty channel']);
      await runGit(iso, p, [
        'push',
        '-q',
        sim.bare,
        pages == _Pages.branch
            ? 'HEAD:refs/heads/gh-pages'
            : 'HEAD:refs/tags/gh-pages',
      ]);
    }

    await runGit(iso, w, ['clone', '-q', sim.bare, sim.workspace]);
    await runGit(iso, sim.workspace, ['checkout', '-q', '--detach', 'v1.2.3']);
    await runGit(iso, sim.workspace, [
      'remote',
      'set-url',
      'origin',
      'https://github.com/$repoName',
    ]);

    Directory(sim.artifact).createSync();
    File(
      '${sim.artifact}/Open-Memex-1.2.3-arm64.dmg.edsig',
    ).writeAsStringSync('c2lnbmF0dXJlLWZvci0xLjIuMw==\n');
    File(
      '${sim.artifact}/Open-Memex-1.2.3-arm64.dmg.length',
    ).writeAsStringSync('38123456\n');
    Directory(sim.temp).createSync();
    Directory(sim.bin).createSync();
    File('${sim.bin}/gh').writeAsStringSync(_stubGh);
    await Process.run('chmod', ['+x', '${sim.bin}/gh']);
    File('${sim.bin}/git').writeAsStringSync(_stubGit);
    await Process.run('chmod', ['+x', '${sim.bin}/git']);
    // A runner has no git identity: the job must set its own.
    File(sim.jobGitConfig).writeAsStringSync(
      [
        '[user]',
        '\tuseConfigOnly = true',
        '[commit]',
        '\tgpgsign = false',
        '[tag]',
        '\tgpgsign = false',
        '[init]',
        '\tdefaultBranch = main',
        '[protocol "file"]',
        '\tallow = always',
        '',
      ].join('\n'),
    );
    return sim;
  }

  Map<String, String> _baseEnv(String envFile) {
    const prefixes = [
      'https://github.com/',
      'https://x-access-token:placeholder-token@github.com/',
      'https://oauth2:placeholder-token@github.com/',
      'https://placeholder-token@github.com/',
      'git@github.com:',
    ];
    return {
      'HOME': iso.home,
      'XDG_CONFIG_HOME': iso.env['XDG_CONFIG_HOME']!,
      'GIT_CONFIG_GLOBAL': jobGitConfig,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_CONFIG_COUNT': '${prefixes.length}',
      for (var i = 0; i < prefixes.length; i++) ...{
        'GIT_CONFIG_KEY_$i': 'url.file://$remotes/.insteadOf',
        'GIT_CONFIG_VALUE_$i': prefixes[i],
      },
      'PATH': '$bin:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
      'CI': 'true',
      'GITHUB_ACTIONS': 'true',
      'GITHUB_EVENT_NAME': 'push',
      'GITHUB_REPOSITORY': repoName,
      'GITHUB_SERVER_URL': 'https://github.com',
      'GITHUB_WORKSPACE': workspace,
      'GITHUB_REF': 'refs/tags/v1.2.3',
      'GITHUB_REF_NAME': 'v1.2.3',
      'GITHUB_SHA': sha,
      'GITHUB_ENV': envFile,
      'GITHUB_OUTPUT': '$w/github-output',
      'GITHUB_STEP_SUMMARY': '$w/github-step-summary',
      'GITHUB_PATH': '$w/github-path',
      'RUNNER_TEMP': temp,
      'STUB_LOG': '$w/gh.log',
      'STUB_REMOTE': bare,
      'STUB_BIN': bin,
      'STUB_PUSH_LOG': pushLog,
    };
  }

  String _expand(String s, Map<String, String> env) =>
      s.replaceAllMapped(RegExp(r'\$\{\{\s*(.*?)\s*\}\}'), (m) {
        final e = m.group(1)!;
        if (e.startsWith('env.')) return env[e.substring(4)] ?? '';
        return switch (e) {
          'github.token' => 'placeholder-token',
          'runner.temp' => temp,
          'github.workspace' => workspace,
          'github.repository' => repoName,
          'github.ref_name' => 'v1.2.3',
          'github.ref' => 'refs/tags/v1.2.3',
          'github.sha' => sha,
          'github.server_url' => 'https://github.com',
          'github.event_name' => 'push',
          _ => throw TestFailure('the simulator does not know ${m.group(0)}'),
        };
      });

  String _resolve(String path) =>
      path.startsWith('/') ? path : '$workspace/$path';

  /// Runs jobs.appcast's steps in order, stopping at the first failure.
  ///
  /// Each call is a fresh job attempt, as Re-run failed jobs gives: an empty
  /// RUNNER_TEMP and a clean tag checkout (actions/checkout cleans it).
  Future<_JobRun> runJob(Map<dynamic, dynamic> wf) async {
    final job = _appcastJob(wf);
    Directory(temp).deleteSync(recursive: true);
    Directory(temp).createSync();
    await runGit(iso, workspace, ['clean', '-ffdxq']);
    await runGit(iso, workspace, [
      'checkout',
      '-q',
      '--force',
      '--detach',
      'v1.2.3',
    ]);
    final envFile = '$w/github-env';
    File(envFile).writeAsStringSync('');
    final base = _baseEnv(envFile);
    final jobEnv = <String, String>{
      for (final e in ((job['env'] as Map?) ?? const {}).entries)
        '${e.key}': _expand('${e.value}', const {}),
    };
    final defaultsRun = (job['defaults'] is Map)
        ? (job['defaults'] as Map)['run']
        : null;
    final jobWd = defaultsRun is Map ? defaultsRun['working-directory'] : null;
    final steps = <_SimStep>[];
    for (final step in _steps(job)) {
      final name = '${step['name'] ?? step['uses'] ?? 'run'}';
      final c = _cond(step);
      if (c.isNotEmpty && c != 'success()') {
        throw TestFailure('the simulator does not evaluate step if: $c');
      }
      final exported = <String, String>{
        for (final l in File(envFile).readAsLinesSync())
          if (l.contains('='))
            l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
      };
      final ctx = {...jobEnv, ...exported};
      final stepEnv = {
        ...ctx,
        for (final e in ((step['env'] as Map?) ?? const {}).entries)
          '${e.key}': _expand('${e.value}', ctx),
      };
      final _SimStep r;
      if (step['uses'] != null) {
        r = await _uses(name, step, base, ctx);
      } else {
        final wd = step['working-directory'] ?? jobWd;
        final run = _expand('${step['run'] ?? ''}', ctx);
        final p = await Process.run(
          'bash',
          ['--noprofile', '--norc', '-eo', 'pipefail', '-c', run],
          workingDirectory: wd == null
              ? workspace
              : _resolve(_expand('$wd', ctx)),
          includeParentEnvironment: false,
          environment: {...base, ...stepEnv},
        );
        r = _SimStep(
          name,
          p.exitCode,
          '${p.stdout}${p.stderr}',
          isRun: true,
          ranGenerator: run.contains(_generator),
        );
      }
      steps.add(r);
      if (r.exitCode != 0) break;
    }
    return _JobRun(steps);
  }

  Future<_SimStep> _uses(
    String name,
    Map<dynamic, dynamic> step,
    Map<String, String> base,
    Map<String, String> ctx,
  ) async {
    final inputs = {
      for (final e in _with(step).entries)
        '${e.key}': _expand('${e.value}', ctx),
    };
    _SimStep done(int code, String out) =>
        _SimStep(name, code, out, isRun: false);
    if (_usesAction(step, 'actions/checkout')) {
      final path = inputs['path'];
      if (_isPagesCheckout(step)) {
        if (path == null) {
          return done(
            1,
            'simulated checkout: no path, so it would replace the tag checkout',
          );
        }
        final p = await Process.run(
          'git',
          [
            'clone',
            '-q',
            '--branch',
            'gh-pages',
            'https://github.com/$repoName',
            _resolve(path),
          ],
          includeParentEnvironment: false,
          environment: base,
          workingDirectory: workspace,
        );
        return p.exitCode == 0
            ? done(0, '')
            : done(
                1,
                'simulated checkout: the requested ref could not be fetched',
              );
      }
      if (path == null) return done(0, '');
      final p = await Process.run(
        'git',
        [
          'clone',
          '-q',
          '--branch',
          'v1.2.3',
          'https://github.com/$repoName',
          _resolve(path),
        ],
        includeParentEnvironment: false,
        environment: base,
        workingDirectory: workspace,
      );
      return done(p.exitCode, '${p.stderr}');
    }
    if (_usesAction(step, 'actions/download-artifact')) {
      if (inputs['name'] != 'appcast-input') {
        return done(1, 'simulated download: no artifact ${inputs['name']}');
      }
      final dest = Directory(_resolve(inputs['path'] ?? '.'))
        ..createSync(recursive: true);
      for (final f in Directory(artifact).listSync().whereType<File>()) {
        f.copySync('${dest.path}/${f.uri.pathSegments.last}');
      }
      return done(0, '');
    }
    throw TestFailure('the simulator does not run ${step['uses']}');
  }

  Future<ScriptResult> _git(List<String> args) =>
      runTool(iso, 'git', ['--git-dir=$bare', ...args], workingDirectory: w);

  /// The gh-pages branch tip on the fixture remote, or null.
  Future<String?> pagesTip() async {
    final r = await Process.run('git', [
      '--git-dir=$bare',
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/heads/gh-pages',
    ], environment: iso.env);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
  }

  Future<String> remoteAppcast() async =>
      (await _git(['show', 'refs/heads/gh-pages:appcast.xml'])).stdout;

  Future<List<String>> pagesFiles() async => (await _git([
    'ls-tree',
    '--name-only',
    'refs/heads/gh-pages',
  ])).stdout.split('\n').where((l) => l.isNotEmpty).toList();

  Future<bool> isAncestor(String a, String b) async {
    final r = await Process.run('git', [
      '--git-dir=$bare',
      'merge-base',
      '--is-ancestor',
      a,
      b,
    ], environment: iso.env);
    final tip = await pagesTip();
    return r.exitCode == 0 && tip != a;
  }
}
