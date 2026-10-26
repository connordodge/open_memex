// WI #166 (B3, D14): the default UrlOpener runs `/usr/bin/open <url>`
// through an injected process runner. No test ever launches a process.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/url_opener.dart';

/// A process runner that records every run and launches nothing.
class _RecordingRunner {
  final List<(String, List<String>)> runs = [];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    runs.add((executable, List.of(arguments)));
    return ProcessResult(4242, 0, '', '');
  }
}

void main() {
  test(
    'the default UrlOpener runs usr bin open with the URL as its only argument',
    () async {
      final runner = _RecordingRunner();
      final opener = SystemUrlOpener(run: runner.call);

      await opener.open('https://x.y');

      expect(runner.runs, hasLength(1));
      expect(runner.runs.single.$1, '/usr/bin/open');
      expect(runner.runs.single.$2, ['https://x.y']);
    },
  );

  test(
    'the default UrlOpener passes a URL with spaces and query characters as one verbatim argument',
    () async {
      final runner = _RecordingRunner();
      final opener = SystemUrlOpener(run: runner.call);
      // Built at run time so the opener sees a non-const string.
      final url = ['mailto:a@b.c', '?subject=hi there&body=a;b'].join();

      await opener.open(url);

      expect(runner.runs, hasLength(1));
      expect(runner.runs.single.$1, '/usr/bin/open');
      expect(runner.runs.single.$2, [url]);
    },
  );

  test('the default UrlOpener runs once per open call, in order', () async {
    final runner = _RecordingRunner();
    final opener = SystemUrlOpener(run: runner.call);

    await opener.open('http://x.y');
    await opener.open('https://a.b/c');

    expect(runner.runs.map((r) => r.$2.single), [
      'http://x.y',
      'https://a.b/c',
    ]);
    expect(runner.runs.map((r) => r.$1).toSet(), {'/usr/bin/open'});
  });

  test('the urlOpenerProvider default is the system opener', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(urlOpenerProvider), isA<SystemUrlOpener>());
  });
}
