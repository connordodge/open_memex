// WI #133: the `flutter drive` side of the profile-mode long-note benchmark
// (`integration_test/long_note_benchmark_test.dart`). It writes the data the
// benchmark reports through `binding.reportData` (the cases, the verdicts and
// the Markdown table) to `build/long_note_benchmark_results.json`, relative
// to the app package (the directory the drive command runs in).
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  // The whole matrix runs for a long time; BENCH_CASES narrows it.
  timeout: const Duration(hours: 4),
  // A failed scenario still leaves the numbers that were reported.
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final file = File('build/long_note_benchmark_results.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data ?? const {}),
    );
  },
);
