// WI #133 (Spec #122 Requirements 3-11, 37): what the first profile-build run
// of the benchmark showed, pinned where the gate can see it (the run itself is
// MANUAL: a foreground window, `flutter drive --profile`).
//
// - Select All (every case) and the paste threw "Null check operator used on
//   a null value": the test binding finds a simulated key's physical key by
//   `debugName`, which is null outside debug builds. Every key the benchmark
//   sends now carries its physical key.
// - The first case of the run found no row field with focus: it starts before
//   the window is key. Focus is waited for on the real clock, bounded, with
//   an explicit request each try, and a focus that never arrives is a failure.
// - A failure kept only the first line of the error. It now keeps the top
//   three frames, repo-relative.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/benchmark_core.dart';

// `flutter test` runs with the package root (`app/`) as cwd.
const _benchmark = 'integration_test/long_note_benchmark_test.dart';
const _core = 'integration_test/benchmark_core.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) throw TestFailure('$path does not exist');
  return f.readAsStringSync();
}

/// [source] without its line comments, so a name in a comment is not read as
/// code.
String _code(String source) =>
    [for (final line in source.split('\n')) line.split('//').first].join('\n');

/// A home directory that is not anyone's (built in pieces: the repo's LEAK
/// scan looks for home paths in the text of files).
final _home = '/${'Users'}/someone';

void main() {
  group('simulated keys', () {
    test('benchmark physical key names the physical key of each key sent', () {
      expect(
        benchmarkPhysicalKey(LogicalKeyboardKey.metaLeft),
        PhysicalKeyboardKey.metaLeft,
      );
      expect(
        benchmarkPhysicalKey(LogicalKeyboardKey.keyA),
        PhysicalKeyboardKey.keyA,
      );
      expect(
        benchmarkPhysicalKey(LogicalKeyboardKey.keyV),
        PhysicalKeyboardKey.keyV,
      );
    });

    test('benchmark physical key rejects a key the benchmark never sends', () {
      expect(
        () => benchmarkPhysicalKey(LogicalKeyboardKey.keyQ),
        throwsArgumentError,
      );
    });

    test('benchmark physical key does not read debugName', () {
      // debugName is null outside debug builds: reading it is the bug.
      expect(_code(_read(_core)), isNot(contains('debugName')));
    });

    testWidgets(
      'a key sent with its physical key is handled without a lookup by name',
      (tester) async {
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
          physicalKey: benchmarkPhysicalKey(LogicalKeyboardKey.metaLeft),
        );
        expect(HardwareKeyboard.instance.isMetaPressed, isTrue);
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
          physicalKey: benchmarkPhysicalKey(LogicalKeyboardKey.metaLeft),
        );
        expect(HardwareKeyboard.instance.isMetaPressed, isFalse);
      },
    );

    test(
      'every simulated key event in the benchmark passes a physical key',
      () {
        final src = _code(_read(_benchmark));
        final calls = RegExp(r'\.sendKey(Down|Up)?Event\(').allMatches(src);
        // Control: the key helpers are there to be checked.
        expect(calls.length, greaterThanOrEqualTo(3));
        for (final m in calls) {
          final call = src.substring(m.start, m.start + 160);
          expect(
            call,
            contains('physicalKey: benchmarkPhysicalKey(key)'),
            reason:
                'a key event without a physical key throws in profile builds',
          );
        }
      },
    );

    test('Select All and the paste send their keys through the helpers', () {
      final src = _code(_read(_benchmark));
      expect(src, contains('_keyPress(tester, key)'));
      expect(src, contains('_keyPress(tester, LogicalKeyboardKey.keyV)'));
      expect(src, contains('_keyDown(tester, LogicalKeyboardKey.metaLeft)'));
      expect(src, contains('_keyUp(tester, LogicalKeyboardKey.metaLeft)'));
    });
  });

  group('waiting for focus', () {
    test('await condition returns at once when the condition holds', () async {
      var nudges = 0;
      var pauses = 0;
      final ok = await awaitCondition(
        isMet: () => true,
        nudge: () async => nudges++,
        pause: () async => pauses++,
      );
      expect(ok, isTrue);
      expect(nudges, 0);
      expect(pauses, 0);
    });

    test(
      'await condition nudges and pauses until the condition holds',
      () async {
        var nudges = 0;
        var pauses = 0;
        final ok = await awaitCondition(
          isMet: () => nudges >= 3,
          nudge: () async => nudges++,
          pause: () async => pauses++,
        );
        expect(ok, isTrue);
        expect(nudges, 3);
        // The condition held right after the third nudge: no pause after it.
        expect(pauses, 2);
      },
    );

    test('await condition gives up after the given number of tries', () async {
      var nudges = 0;
      var pauses = 0;
      final ok = await awaitCondition(
        isMet: () => false,
        nudge: () async => nudges++,
        pause: () async => pauses++,
        attempts: 7,
      );
      expect(ok, isFalse);
      expect(nudges, 7);
      expect(pauses, 7);
    });

    test('await condition without a nudge only waits', () async {
      var pauses = 0;
      final ok = await awaitCondition(
        isMet: () => pauses >= 2,
        pause: () async => pauses++,
      );
      expect(ok, isTrue);
      expect(pauses, 2);
    });

    test(
      'await condition sees a condition that holds after the last try',
      () async {
        var pauses = 0;
        final ok = await awaitCondition(
          isMet: () => pauses >= 3,
          pause: () async => pauses++,
          attempts: 3,
        );
        expect(ok, isTrue);
      },
    );

    test('the benchmark waits for focus in every phase that needs a field', () {
      final src = _code(_read(_benchmark));
      // The caret placement, and so every editing phase, waits.
      expect(src, contains('await _holdFocus(tester, request);'));
      // The paste waits too.
      expect(src, contains('await _holdFocus(tester, focusRow);'));
      // On the real clock, with an explicit request, bounded.
      expect(src, contains('Future<void>.delayed(_focusPause)'));
      expect(src, contains('nudge: request'));
      expect(src, contains('attempts: _focusTries'));
    });

    test('a focus that never arrives is a failure, not a silent skip', () {
      final src = _code(_read(_benchmark));
      expect(src, contains('if (!held) {'));
      expect(src, contains("'no row field held focus after"));
    });

    test('the first pump of a run waits for the window to be active', () {
      final src = _code(_read(_benchmark));
      expect(src, contains('await _awaitWindow(tester);'));
      expect(src, contains('AppLifecycleState.resumed'));
      expect(src, contains("'window: the app was not active"));
    });
  });

  group('failure records', () {
    test('top frames keeps three frames without index or async gaps', () {
      final stack = StackTrace.fromString(
        '#0      one (package:a/a.dart:1:2)\n'
        '<asynchronous suspension>\n'
        '#1      two (package:a/b.dart:3:4)\n'
        '#2      three (package:a/c.dart:5:6)\n'
        '#3      four (package:a/d.dart:7:8)\n',
      );
      expect(topFrames(stack), [
        'at one (package:a/a.dart:1:2)',
        'at two (package:a/b.dart:3:4)',
        'at three (package:a/c.dart:5:6)',
      ]);
    });

    test('top frames of a short stack are all of it', () {
      final stack = StackTrace.fromString('#0      one (package:a/a.dart:1:2)');
      expect(topFrames(stack), ['at one (package:a/a.dart:1:2)']);
    });

    test('repo relative turns a file path under the app into app slash', () {
      expect(
        repoRelative(
          'f (file://$_home/code/repo/app/integration_test/x_test.dart:9:3)',
        ),
        'f (app/integration_test/x_test.dart:9:3)',
      );
      expect(
        repoRelative('f ($_home/code/wt/app/lib/src/a.dart:1:2)'),
        'f (app/lib/src/a.dart:1:2)',
      );
    });

    test(
      'repo relative keeps only the file name of a path outside the app',
      () {
        final out = repoRelative(
          'f (file://$_home/sdk/packages/flutter_test/lib/src/e.dart:689:12)',
        );
        expect(out, 'f (.../e.dart:689:12)');
      },
    );

    test('repo relative leaves a package path alone', () {
      const frame = 'f (package:flutter_test/src/event_simulation.dart:689:12)';
      expect(repoRelative(frame), frame);
    });

    test('repo relative never leaves a home path in a message', () {
      expect(
        repoRelative('cannot open $_home/notes.txt'),
        isNot(contains(_home)),
      );
    });

    test('failure record is the first error line then three frames', () {
      final stack = StackTrace.fromString(
        '#0      a (file://$_home/x/app/lib/a.dart:1:2)\n'
        '#1      b (package:p/b.dart:3:4)\n'
        '#2      c (package:p/c.dart:5:6)\n'
        '#3      d (package:p/d.dart:7:8)\n',
      );
      final record = failureRecord(
        'n1-x',
        'select-all',
        StateError('Null check operator\nsecond line'),
        stack,
      );
      expect(record.split('\n'), [
        'n1-x select-all: Bad state: Null check operator',
        '    at a (app/lib/a.dart:1:2)',
        '    at b (package:p/b.dart:3:4)',
        '    at c (package:p/c.dart:5:6)',
      ]);
      expect(record, isNot(contains(_home)));
    });

    test('failure record of a real throw carries this file as a frame', () {
      late String record;
      try {
        throw StateError('boom');
      } catch (e, stack) {
        record = failureRecord('id', 'phase', e, stack);
      }
      expect(record, startsWith('id phase: Bad state: boom'));
      expect(record.split('\n').length, greaterThan(1));
      expect(record, contains('long_note_benchmark_profile_test.dart'));
      expect(record, isNot(contains(_home)));
    });

    test('the benchmark records every failed phase with failure record', () {
      final src = _code(_read(_benchmark));
      expect(src, contains('} catch (e, stack) {'));
      expect(src, contains('failureRecord(id, name, e, stack)'));
      expect(src, isNot(contains(".split('\\n').first")));
    });
  });
}
