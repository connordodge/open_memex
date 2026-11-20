// WI #133 (Spec #122 Requirement 37, Technical Decision 9; ruling D14): the
// wiring around the profile-mode benchmark that the gate can check without a
// foreground window.
//
// - `integration_test` is a dev dependency (SDK) and the lock records it.
// - The benchmark and its driver sit outside `test/`, so `flutter test` (the
//   gate) never lists them, and no CI workflow or script runs them.
// - The benchmark reports through `binding.reportData` (never `print`), on the
//   shared fixtures and core, and records every metric and scenario.
// - The README states the drive command, the foreground-window requirement
//   with its `open` step, and the output fields.
// - No home path in any of these files (the LEAK step).
//
// The runs themselves (Requirements 3-11) are MANUAL: they need a profile
// build with the window in the foreground.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../../integration_test/benchmark_core.dart';

// `flutter test` runs with the package root (`app/`) as cwd.
const _benchmark = 'integration_test/long_note_benchmark_test.dart';
const _core = 'integration_test/benchmark_core.dart';
const _readme = 'integration_test/README.md';
const _driver = 'test_driver/integration_test.dart';
const _results = 'build/long_note_benchmark_results.json';
const _driveCommand =
    'flutter drive --profile -d macos '
    '--driver=test_driver/integration_test.dart '
    '--target=integration_test/long_note_benchmark_test.dart';

/// The text of [path], failing the test with a clear message when the file
/// does not exist yet.
String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) throw TestFailure('$path does not exist');
  return f.readAsStringSync();
}

YamlMap _yamlMap(String path) => loadYaml(_read(path)) as YamlMap;

/// The constant name of each [BenchMetric], as the benchmark must spell it.
const _metricConstants = [
  'flingBuild',
  'flingRaster',
  'jumpBuild',
  'jumpRaster',
  'openFirstScreen',
  'keystroke',
  'arrow',
  'shiftSelect',
  'pointerDrag',
  'findKeystroke',
  'findNextMatch',
  'resizeBuild',
  'resizeRaster',
  'selectAll',
  'clearSelection',
];

/// [source] without its line comments (`//`, `///`), so a name in a comment
/// is not read as code.
String _code(String source) =>
    [for (final line in source.split('\n')) line.split('//').first].join('\n');

final _printCall = RegExp(r'(^|[^A-Za-z0-9_.$])print\(');
final _homePath = RegExp(r'/(Users|home)/[A-Za-z0-9._-]+/');

void main() {
  group('dependency', () {
    test(
      'app pubspec lists integration_test under dev_dependencies with the flutter sdk',
      () {
        final pubspec = _yamlMap('pubspec.yaml');
        // Control: the parser reads both blocks.
        expect(
          (pubspec['dev_dependencies'] as YamlMap),
          contains('flutter_test'),
        );
        expect(
          (pubspec['dependencies'] as YamlMap),
          contains('flutter_riverpod'),
        );
        final dev = pubspec['dev_dependencies'] as YamlMap;
        expect(dev, contains('integration_test'));
        expect((dev['integration_test'] as YamlMap)['sdk'], 'flutter');
        expect(
          (pubspec['dependencies'] as YamlMap),
          isNot(contains('integration_test')),
        );
      },
    );

    test(
      'pubspec lock records integration_test as a direct dev sdk package',
      () {
        final packages = _yamlMap('pubspec.lock')['packages'] as YamlMap;
        // Control: an existing SDK dev dependency has the same shape.
        final control = packages['flutter_test'] as YamlMap;
        expect(control['dependency'], 'direct dev');
        expect(control['source'], 'sdk');
        expect(packages, contains('integration_test'));
        final entry = packages['integration_test'] as YamlMap;
        expect(entry['dependency'], 'direct dev');
        expect(entry['source'], 'sdk');
        expect(entry['description'], 'flutter');
      },
    );
  });

  group('discovery', () {
    test(
      'the benchmark and its driver sit outside test and no workflow or script runs them',
      () {
        // The benchmark and the driver exist, outside `test/`, the only
        // directory `flutter test` lists without arguments.
        for (final path in [_benchmark, _driver]) {
          expect(File(path).existsSync(), isTrue, reason: '$path exists');
          expect(path.startsWith('test/'), isFalse, reason: path);
        }
        expect(_benchmark, endsWith('_test.dart'));
        // Nothing under test/ is the benchmark, or imports the integration
        // binding (that would make the gate run it).
        final binding = 'package:${'integration_test'}/';
        final offenders = <String>[];
        for (final e in Directory('test').listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          final segments = e.uri.pathSegments;
          if (segments.contains('integration_test')) offenders.add(e.path);
          if (e.path.endsWith('long_note_benchmark_wiring_test.dart')) continue;
          if (e.readAsStringSync().contains(binding)) offenders.add(e.path);
        }
        expect(offenders, isEmpty);
        // No CI workflow or script names the benchmark or drives it.
        final scanned = <String>[];
        final hits = <String>[];
        final roots = [
          Directory('../.github/workflows'),
          Directory('../scripts'),
        ];
        for (final root in roots) {
          if (!root.existsSync()) continue;
          for (final e in root.listSync(recursive: true)) {
            if (e is! File) continue;
            final String text;
            try {
              text = e.readAsStringSync();
            } on FileSystemException {
              continue; // binary
            } on FormatException {
              continue; // binary
            }
            scanned.add(e.path);
            if (text.contains('integration_test') ||
                text.contains('flutter drive')) {
              hits.add(e.path);
            }
          }
        }
        // Control: the scan reads the CI test workflow.
        expect(scanned, contains('../.github/workflows/test.yml'));
        expect(hits, isEmpty);
      },
    );
  });

  group('benchmark', () {
    test(
      'the benchmark reports through reportData on the shared fixtures and core',
      () {
        final src = _read(_benchmark);
        for (final needle in [
          'IntegrationTestWidgetsFlutterBinding.ensureInitialized',
          'binding.reportData',
          'long_note_fixtures.dart',
          'fake_spelling_service.dart',
          'benchmark_core.dart',
          'seedMisspellings(',
          'benchmarkMatrix(',
          'selectCases(',
          'BenchReport(',
          "String.fromEnvironment('BENCH_CASES'",
        ]) {
          expect(src, contains(needle), reason: needle);
        }
      },
    );

    test('the benchmark records every metric', () {
      final src = _code(_read(_benchmark));
      expect(_metricConstants, hasLength(BenchMetric.all.length));
      for (final name in _metricConstants) {
        // A record site, not a mention: `record(` or `_recordFrames(` with the
        // metric among its arguments (before the statement ends).
        expect(
          RegExp(
            r'record(Frames)?\(\s*[^;]*?BenchMetric\.' + name + r'\b',
            dotAll: true,
          ).hasMatch(src),
          isTrue,
          reason: 'no record site for $name',
        );
      }
    });

    test('the benchmark runs every extra scenario', () {
      final src = _code(_read(_benchmark));
      expect(ExtraScenario.values, hasLength(4));
      for (final s in ExtraScenario.values) {
        expect(src, contains('ExtraScenario.${s.name}'), reason: s.name);
        // The scenario's own function declares the id the core names for it
        // and owes the report its rows (`expectCase(id)` right after).
        final decl = RegExp(
          "const id = '${RegExp.escape(s.id)}';\\s*_report\\.expectCase\\(id\\);",
        );
        expect(decl.hasMatch(src), isTrue, reason: s.id);
      }
    });

    test(
      'the benchmark declares every case and its caret scroll to the report',
      () {
        final src = _code(_read(_benchmark));
        expect(
          RegExp(
            r'_report\s*\.\.expectCase\(id\)\s*\.\.expectCase\(\s*caretCaseId\(id\),\s*metrics: BenchMetric\.scroll,?\s*\)',
          ).hasMatch(src),
          isTrue,
          reason: 'a matrix case owes its rows and its caret scroll rows',
        );
        // The caret scroll is run and recorded under the caret id.
        expect(src, contains('_scroll(tester, caretCaseId(id))'));
        // Failed phases are reported, not swallowed.
        expect(src, contains("'failures'"));
      },
    );

    test('the benchmark runs on the real clock and the live frame policy', () {
      final src = _code(_read(_benchmark));
      // The harness installs a FakeClock that fires no timer; the benchmark
      // overrides it, and never installs one of its own.
      expect(
        src,
        contains('clockProvider.overrideWithValue(const SystemClock())'),
      );
      expect(src, isNot(contains('FakeClock')));
      expect(
        src,
        contains(
          'binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive',
        ),
      );
    });

    test('the paste scenario answers the pasteboard with text only', () {
      final src = _code(_read(_benchmark));
      expect(
        src,
        contains(
          'pasteboardReaderProvider.overrideWithValue(const _TextOnlyPasteboard())',
        ),
      );
      expect(src, contains('PasteboardContents(hasText: true)'));
    });

    test(
      'the paste scenario asks the field to paste only when the clipboard was never read',
      () {
        final src = _code(_read(_benchmark));
        final start = src.indexOf('Future<void> _pasteIntoEmpty(');
        expect(start, isNonNegative);
        final end = src.indexOf('Future<void> _reloadAfterOutsideEdit(');
        expect(end, greaterThan(start));
        final body = src.substring(start, end);
        // The wait for Cmd-V gives up as soon as the clipboard was read.
        expect(
          RegExp(
            r'for \(var i = 0; i < \d+ && reads == 0; i\+\+\)',
          ).hasMatch(body),
          isTrue,
          reason: 'the pump loop stops once the key started a paste',
        );
        // The fallback paste, and the stopwatch restart it needs, sit inside
        // the reads == 0 branch only: otherwise a paste already in flight lands
        // twice and the timing restarts under it.
        final branch = RegExp(
          r'if \(reads == 0\) \{(?<inner>[^}]*)\}',
        ).firstMatch(body);
        expect(branch, isNotNull, reason: 'a reads == 0 fallback branch');
        final inner = branch!.namedGroup('inner')!;
        expect(inner, contains('pasteText('));
        expect(inner, contains('..reset()'));
        expect('pasteText('.allMatches(body), hasLength(1));
        expect('..reset()'.allMatches(body), hasLength(1));
      },
    );

    test(
      'the benchmark scrolls with the caret only when the focus landed one',
      () {
        final src = _code(_read(_benchmark));
        expect(
          RegExp(
            r"if \(rowsHostOf\(tester\)\.focusedRow != null\) \{\s*await _phase\(\s*id,\s*'scroll with caret',\s*\(\) => _scroll\(tester, caretCaseId\(id\)\),?\s*\);\s*\}",
          ).hasMatch(src),
          isTrue,
          reason: 'a failed focus leaves the caret rows INCOMPLETE',
        );
        // The only caret scroll is the guarded one.
        expect(
          '_scroll(tester, caretCaseId(id))'.allMatches(src),
          hasLength(1),
        );
      },
    );

    test('the benchmark and its driver never call print', () {
      for (final path in [_benchmark, _core, _driver]) {
        final lines = _read(path).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first;
          expect(
            _printCall.hasMatch(code),
            isFalse,
            reason: '$path:${i + 1}: ${lines[i]}',
          );
        }
      }
    });

    test('the benchmark never names a home path', () {
      for (final path in [_benchmark, _core, _driver, _readme]) {
        expect(_homePath.hasMatch(_read(path)), isFalse, reason: path);
      }
    });
  });

  group('driver', () {
    test('the driver writes the reported data as JSON under build', () {
      final src = _read(_driver);
      expect(src, contains('integrationDriver'));
      expect(src, contains('responseDataCallback'));
      expect(src, contains(_results));
      expect(src, isNot(contains('/tmp')));
    });
  });

  group('readme', () {
    test('the README states the drive command', () {
      final text = _read(_readme).replaceAll(RegExp(r'\\\n\s*'), '');
      expect(text, contains(_driveCommand));
    });

    test('the README states the foreground window with the open step', () {
      final text = _read(_readme);
      expect(text, contains('foreground'));
      expect(
        RegExp(r'^\s*open\s+\S+', multiLine: true).hasMatch(text),
        isTrue,
        reason: 'a command line that starts with open',
      );
    });

    test(
      'the README names every metric and statistic the benchmark reports',
      () {
        final text = _read(_readme);
        expect(BenchMetric.all, isNotEmpty);
        for (final metric in BenchMetric.all) {
          expect(text, contains(metric), reason: metric);
        }
        for (final stat in ['median', 'p90', 'max', 'count']) {
          expect(text, contains(stat), reason: stat);
        }
      },
    );

    test(
      'the README explains the verdicts the case filter and the results file',
      () {
        final text = _read(_readme);
        for (final needle in [
          'PASS',
          'MISS',
          'INCOMPLETE',
          'BENCH_CASES',
          _results,
        ]) {
          expect(text, contains(needle), reason: needle);
        }
      },
    );
  });
}
