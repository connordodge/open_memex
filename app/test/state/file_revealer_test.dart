// WI #361 (Spec #357 TD4, Testing Strategy 1): the default FileRevealer runs
// `/usr/bin/open -R <path>` through an injected process runner. No test
// ever launches a process or opens Finder.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:path/path.dart' as p;

import '../support/fake_file_revealer.dart';

/// A process runner that records every run and launches nothing.
class _Wi361RecordingRunner {
  final List<(String, List<String>)> runs = [];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    runs.add((executable, List.of(arguments)));
    return ProcessResult(4361, 0, '', '');
  }
}

void main() {
  test(
    'SystemFileRevealer runs usr bin open with -R and the path exactly',
    () async {
      final runner = _Wi361RecordingRunner();
      final revealer = SystemFileRevealer(run: runner.call);
      final path = p.join(Directory.systemTemp.path, 'om361', 'memex');

      await revealer.reveal(path);

      expect(runner.runs, hasLength(1));
      expect(runner.runs.single.$1, '/usr/bin/open');
      expect(runner.runs.single.$2, ['-R', path]);
    },
  );

  test(
    'SystemFileRevealer passes a path with spaces and quotes as one verbatim argument',
    () async {
      final runner = _Wi361RecordingRunner();
      final revealer = SystemFileRevealer(run: runner.call);
      // Built at run time so the revealer sees a non-const string.
      final path = [
        Directory.systemTemp.path,
        '/my notes',
        "/it's a vault -R",
      ].join();

      await revealer.reveal(path);

      expect(runner.runs.single.$1, '/usr/bin/open');
      expect(runner.runs.single.$2, ['-R', path]);
    },
  );

  test('SystemFileRevealer runs once per reveal call in order', () async {
    final runner = _Wi361RecordingRunner();
    final revealer = SystemFileRevealer(run: runner.call);

    await revealer.reveal('/tmp/om361/a');
    await revealer.reveal('/tmp/om361/b');

    expect(runner.runs.map((r) => r.$2), [
      ['-R', '/tmp/om361/a'],
      ['-R', '/tmp/om361/b'],
    ]);
    expect(runner.runs.map((r) => r.$1).toSet(), {'/usr/bin/open'});
  });

  test('the fileRevealerProvider default is the system revealer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(fileRevealerProvider), isA<SystemFileRevealer>());
  });

  test(
    'a FakeFileRevealer override records each path and runs nothing',
    () async {
      final fake = FakeFileRevealer();
      final container = ProviderContainer(
        overrides: [fileRevealerProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      await container.read(fileRevealerProvider).reveal('/tmp/om361/x');
      await container.read(fileRevealerProvider).reveal('/tmp/om361/y');

      expect(fake.paths, ['/tmp/om361/x', '/tmp/om361/y']);
    },
  );
}
