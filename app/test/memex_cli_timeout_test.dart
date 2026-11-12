// #424 (391-A0, Spec #391 req 21): `MemexCli.run` takes an optional
// timeout. A process still running when it passes is killed and reaped, and
// the call throws `MemexCliTimeout`. These tests run real children
// (`/bin/sh` that execs `/bin/sleep`), never `memex`. Each child writes its
// pid to a temp file first, so the test can prove it is gone and kill any
// leftover in tearDown.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:path/path.dart' as p;

import 'support/fake_memex_cli.dart';

/// How long a test waits on `run` before calling it hung. The children
/// sleep far longer, so a `run` that ignores its timeout fails here (by a
/// `TimeoutException`, not a `MemexCliTimeout`) instead of hanging.
const _hung = Duration(seconds: 5);

/// Long enough that a loaded machine starts the child and lets it write its
/// pid before the kill (a 300 ms window raced that write), still far below
/// the children's 30 s sleep and [_hung].
const _timeout = Duration(seconds: 1);

late Directory _dir;
final List<int> _spawned = [];

bool _alive(int pid) =>
    Process.runSync('/bin/kill', ['-0', '$pid']).exitCode == 0;

/// Waits up to 2 s for [path] to hold a pid (the child writes it first).
Future<int> _readPid(String path) async {
  for (var i = 0; i < 200; i++) {
    final f = File(path);
    if (f.existsSync()) {
      final text = f.readAsStringSync().trim();
      final pid = int.tryParse(text);
      if (pid != null) {
        _spawned.add(pid);
        return pid;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('no pid written to $path');
}

/// Waits up to 2 s for [pid] to be gone (killed and reaped; a zombie still
/// answers `kill -0`).
Future<bool> _goneSoon(int pid) async {
  for (var i = 0; i < 200; i++) {
    if (!_alive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

String _pidFile(String name) => p.join(_dir.path, '$name.pid');

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('om-cli-timeout');
  });

  tearDown(() {
    for (final pid in _spawned) {
      if (_alive(pid)) Process.killPid(pid, ProcessSignal.sigkill);
    }
    _spawned.clear();
    _dir.deleteSync(recursive: true);
  });

  group('MemexCli.run with a timeout', () {
    test(
      'MemexCli run with a timeout kills a process that outlives it and throws MemexCliTimeout',
      () async {
        final pidFile = _pidFile('child');
        final args = ['-c', 'echo \$\$ > "$pidFile"; exec /bin/sleep 30'];
        final cli = MemexCli(binaryPath: '/bin/sh');

        Object? thrown;
        try {
          await cli.run(args, timeout: _timeout).timeout(_hung);
        } catch (e) {
          thrown = e;
        }
        final pid = await _readPid(pidFile);

        expect(thrown, isA<MemexCliTimeout>());
        final timeout = thrown as MemexCliTimeout;
        expect(timeout.args, args);
        expect(timeout.timeout, _timeout);
        expect(await _goneSoon(pid), isTrue, reason: 'child $pid still runs');
      },
    );

    test(
      'MemexCli run with a timeout throws promptly when a grandchild keeps stdout open',
      () async {
        final childFile = _pidFile('child');
        final grandchildFile = _pidFile('grandchild');
        final args = [
          '-c',
          '/bin/sleep 30 & echo \$! > "$grandchildFile"; '
              'echo \$\$ > "$childFile"; exec /bin/sleep 30',
        ];
        final cli = MemexCli(binaryPath: '/bin/sh');

        Object? thrown;
        try {
          await cli.run(args, timeout: _timeout).timeout(_hung);
        } catch (e) {
          thrown = e;
        }
        final child = await _readPid(childFile);
        await _readPid(grandchildFile);

        expect(thrown, isA<MemexCliTimeout>());
        expect(await _goneSoon(child), isTrue, reason: 'child $child runs');
      },
    );

    test(
      'MemexCli run with a timeout kills a process that holds its stdin open',
      () async {
        final pidFile = _pidFile('child');
        // `cat` would end at EOF; this child ignores stdin and sleeps.
        final args = ['-c', 'echo \$\$ > "$pidFile"; exec /bin/sleep 30'];
        final cli = MemexCli(binaryPath: '/bin/sh');

        await expectLater(
          cli
              .run(args, stdinBody: 'body for the child', timeout: _timeout)
              .timeout(_hung),
          throwsA(isA<MemexCliTimeout>()),
        );
        final pid = await _readPid(pidFile);
        expect(await _goneSoon(pid), isTrue, reason: 'child $pid still runs');
      },
    );

    test(
      'MemexCli run with a timeout covers a stdin body the child never reads',
      () async {
        final pidFile = _pidFile('child');
        final args = ['-c', 'echo \$\$ > "$pidFile"; exec /bin/sleep 30'];
        final cli = MemexCli(binaryPath: '/bin/sh');
        // Far above any pipe buffer, so the write blocks on a child that
        // never reads.
        final body = List.filled(4 * 1024 * 1024, 'x').join();

        await expectLater(
          cli.run(args, stdinBody: body, timeout: _timeout).timeout(_hung),
          throwsA(isA<MemexCliTimeout>()),
        );
        final pid = await _readPid(pidFile);
        expect(await _goneSoon(pid), isTrue, reason: 'child $pid still runs');
      },
    );

    test(
      'MemexCli run with a timeout returns the result of a child that closes stdin and exits early',
      () async {
        final cli = MemexCli(binaryPath: '/bin/sh');
        // The child closes stdin and exits, so the write of a body far above
        // the pipe buffer fails with EPIPE. The run must still return the
        // child result, not throw the write error.
        final body = List.filled(1024 * 1024, 'x').join();

        final r = await cli
            .run(
              ['-c', 'exec 0<&-; printf out; exit 3'],
              stdinBody: body,
              timeout: const Duration(seconds: 3),
            )
            .timeout(_hung);

        expect(r.exitCode, 3);
        expect(r.stdout, 'out');
      },
    );

    test(
      'MemexCli run with a timeout kills a child that closes stdin and keeps running',
      () async {
        final pidFile = _pidFile('child');
        final args = [
          '-c',
          'echo \$\$ > "$pidFile"; exec 0<&-; exec /bin/sleep 30',
        ];
        final cli = MemexCli(binaryPath: '/bin/sh');
        final body = List.filled(1024 * 1024, 'x').join();

        // The stdin write fails with EPIPE at once. The call must still wait
        // inside its timeout, then kill the child, not throw the write error
        // and leave the child running.
        await expectLater(
          cli.run(args, stdinBody: body, timeout: _timeout).timeout(_hung),
          throwsA(isA<MemexCliTimeout>()),
        );
        final pid = await _readPid(pidFile);
        expect(await _goneSoon(pid), isTrue, reason: 'child $pid still runs');
      },
    );

    test(
      'MemexCli run with a timeout returns the result of a process that finishes in time',
      () async {
        final cli = MemexCli(binaryPath: '/bin/sh');

        final r = await cli
            .run(
              ['-c', 'cat; printf err >&2; exit 3'],
              stdinBody: 'from stdin',
              timeout: const Duration(seconds: 20),
            )
            .timeout(_hung);

        expect(r.exitCode, 3);
        expect(r.stdout, 'from stdin');
        expect(r.stderr, 'err');
      },
    );

    test('MemexCliTimeout names the args and the timeout', () {
      final args = ['echoes', '--note-id', '01JECHO'];
      final e = MemexCliTimeout(args, Duration(milliseconds: int.parse('250')));

      expect(e, isA<Exception>());
      final text = e.toString();
      expect(text, contains('MemexCliTimeout'));
      for (final a in args) {
        expect(text, contains(a));
      }
      expect(text, contains('250'));
    });
  });

  group('MemexCli.run without a timeout', () {
    test(
      'MemexCli run without a timeout waits for a slow process and returns its output',
      () async {
        final cli = MemexCli(binaryPath: '/bin/sh');

        final r = await cli
            .run(['-c', '/bin/sleep 0.6; printf done; printf warn >&2'])
            .timeout(_hung);

        expect(r.exitCode, 0);
        expect(r.stdout, 'done');
        expect(r.stderr, 'warn');
      },
    );
  });

  group('FakeMemexCli timeout', () {
    test('FakeMemexCli records the timeout passed to run', () async {
      final cli = FakeMemexCli()..on('echoes', (_) => FakeMemexCli.ok('{}'));
      final limit = Duration(seconds: int.parse('60'));

      await cli.run(['echoes', '--note-id', 'n1'], timeout: limit);
      await cli.run(['echoes', '--note-id', 'n2']);

      expect(cli.calls, hasLength(2));
      expect(cli.calls[0].timeout, limit);
      expect(cli.calls[1].timeout, isNull);
      expect(cli.calls[0].toString(), contains('$limit'));
    });

    test('FakeMemexCli can script a MemexCliTimeout', () async {
      final cli = FakeMemexCli()..on('echoes', FakeMemexCli.timedOut);
      final args = ['echoes', '--note-id', 'n1', '--allow-download'];
      const limit = Duration(minutes: 10);

      Object? thrown;
      try {
        await cli.run(args, timeout: limit);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<MemexCliTimeout>());
      thrown as MemexCliTimeout;
      expect(thrown.args, args);
      expect(thrown.timeout, limit);
      expect(cli.callsFor('echoes').single.timeout, limit);
    });

    test(
      'FakeMemexCli scripted timeout without a timeout reports zero',
      () async {
        final cli = FakeMemexCli()..on('echoes', FakeMemexCli.timedOut);

        await expectLater(
          cli.run(['echoes']),
          throwsA(
            isA<MemexCliTimeout>().having(
              (e) => e.timeout,
              'timeout',
              Duration.zero,
            ),
          ),
        );
      },
    );
  });
}
