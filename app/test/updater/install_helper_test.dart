// WI #34 (Spec #31 req 25, 26, TD5, D6, D13): the install helper script's
// text, how `start` hands it to the helper-runner seam, and the production
// detached runner.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/install_helper.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';

/// The five fixed reasons, verbatim from Spec #31 req 26.
const _reasons = [
  "the disk image couldn't be opened",
  "the new app couldn't be copied",
  "the new app's signature didn't verify",
  "the new app couldn't be moved into place",
  "the app didn't quit in time",
];

/// The script's command lines, without comments and blank lines.
List<String> _commandLines(String script) => [
  for (final line in script.split('\n'))
    if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
];

/// Matches a reference to positional parameter [n] (`$n` or `${n}`).
RegExp _positional(int n) => RegExp('\\\$\\{?$n\\}?(?![0-9])');

/// The ruled failure when the helper cannot be started (lead ruling L-34a):
/// not one of the five marker reasons, and no folder.
final _couldNotStart = isA<UpdateFailure>()
    .having((f) => f.cause, 'cause', UpdateErrorCause.failureRecorded)
    .having((f) => f.reason, 'reason', "the install helper couldn't be started")
    .having((f) => f.folder, 'folder', isNull);

void main() {
  group('the helper script text', () {
    test('the helper script text is not empty and runs under sh', () async {
      expect(installHelperScript.trim(), isNotEmpty);
      // sh -n parses it without running anything.
      final parsed = await Process.run('/bin/sh', [
        '-n',
        '-c',
        installHelperScript,
      ]);
      expect(parsed.exitCode, 0, reason: '${parsed.stderr}');
    });

    test(
      'the helper script waits on the pid with the wait limit argument and records that the app did not quit in time',
      () {
        final s = installHelperScript;
        expect(s, contains('kill -0'));
        expect(s, matches(_positional(1)), reason: 'the pid is \$1');
        expect(s, matches(_positional(5)), reason: 'the wait limit is \$5');
        expect(s, contains("the app didn't quit in time"));
        // The 60-second limit is an argument, never a literal command.
        expect(_commandLines(s).join('\n'), isNot(contains('60')));
      },
    );

    test(
      'the helper script uses the new and old bundle names, verifies strictly and mounts read only without browsing',
      () {
        final s = installHelperScript;
        expect(s, contains('Open Memex.app.new'));
        expect(s, contains('Open Memex.app.old'));
        expect(s, contains('codesign --verify --deep --strict'));
        expect(s, contains('hdiutil attach -nobrowse -readonly -mountpoint'));
        // The mounted app is found at the mount root by its bundle name.
        expect(s, contains('Open Memex.app'));
        // Every reason the helper can record is one of the five.
        for (final reason in _reasons) {
          expect(s, contains(reason));
        }
        // PATH comes from the sixth argument.
        expect(s, matches(_positional(6)));
      },
    );

    test(
      'the helper script never ditto copies onto the installed app path',
      () {
        final dittoLines = _commandLines(
          installHelperScript,
        ).where((l) => RegExp(r'(^|[\s;&|(])ditto\s').hasMatch(l)).toList();

        expect(
          dittoLines,
          hasLength(1),
          reason: 'one copy, to the .new bundle',
        );
        final line = dittoLines.single;
        // The command itself, before any `|| ...` / `&& ...` / `;`.
        final command = line
            .substring(line.indexOf(RegExp(r'ditto\s')))
            .split(RegExp(r'\|\||&&|;'))[0];
        final quoted = RegExp(r'"([^"]*)"').allMatches(command).toList();
        expect(quoted.length, greaterThanOrEqualTo(2), reason: command);
        expect(
          quoted.last.group(1)!.toLowerCase(),
          contains('new'),
          reason: 'the ditto destination is the .new bundle: $command',
        );
        expect(command, isNot(matches(_positional(3))));
        // Never hard-codes /Applications.
        expect(installHelperScript, isNot(contains('/Applications')));
      },
    );
  });

  group('start', () {
    const dmg = '/vaults/Update Downloads/Open-Memex-1.3.0.dmg';
    const bundle = '/vaults/My Apps/Open Memex.app';
    const marker = '/vaults/Support Dir/self_update_failure';

    test(
      'start launches sh detached through the helper runner seam with the script and its positional arguments',
      () async {
        final io = RecordingUpdaterIo();
        final container = ProviderContainer(
          overrides: [
            installHelperRunnerProvider.overrideWithValue(io.runHelper),
            failureMarkerFileProvider.overrideWithValue(marker),
            currentPidProvider.overrideWithValue(4242),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(installHelperProvider)
            .start(
              pid: container.read(currentPidProvider),
              dmgPath: dmg,
              bundlePath: bundle,
            );

        expect(io.helperRuns, hasLength(1));
        final run = io.helperRuns.single;
        expect(run.executable, '/bin/sh');
        final args = run.arguments;
        expect(args, hasLength(9), reason: '$args');
        expect(args[0], '-c');
        expect(args[1], installHelperScript);
        expect(args[1], isNotEmpty);
        expect(args[2], isNotEmpty, reason: r'the $0 name');
        expect(args.sublist(3, 8), ['4242', dmg, bundle, marker, '60']);

        // The script is constant: no value is interpolated into it.
        for (final value in [dmg, bundle, marker, '4242']) {
          expect(args[1], isNot(contains(value)));
        }

        // A system-only PATH, never the user's.
        final path = args[8].split(':');
        expect(path, containsAll(['/usr/bin', '/bin']));
        for (final entry in path) {
          expect(['/usr/bin', '/bin', '/usr/sbin', '/sbin'], contains(entry));
        }
      },
    );

    test(
      'each start runs the helper once with the values of that call',
      () async {
        final io = RecordingUpdaterIo();
        final container = ProviderContainer(
          overrides: [
            installHelperRunnerProvider.overrideWithValue(io.runHelper),
            failureMarkerFileProvider.overrideWithValue(marker),
            currentPidProvider.overrideWithValue(31337),
          ],
        );
        addTearDown(container.dispose);
        final helper = container.read(installHelperProvider);

        final pid = int.parse(
          '3133'
          '7',
        );
        await helper.start(pid: pid, dmgPath: dmg, bundlePath: bundle);
        await helper.start(
          pid: pid,
          dmgPath: '/vaults/Other/Update.dmg',
          bundlePath: '/vaults/Other Apps/Open Memex.app',
        );

        expect(io.helperRuns, hasLength(2));
        expect(io.helperRuns[0].arguments[3], '31337');
        expect(io.helperRuns[1].arguments.sublist(3, 8), [
          '31337',
          '/vaults/Other/Update.dmg',
          '/vaults/Other Apps/Open Memex.app',
          marker,
          '60',
        ]);
      },
    );

    test(
      'start throws an update failure when the helper cannot be started',
      () async {
        final calls = <String>[];
        final container = ProviderContainer(
          overrides: [
            installHelperRunnerProvider.overrideWithValue((exe, args) async {
              calls.add(exe);
              throw ProcessException(exe, args, 'No such file', 2);
            }),
            failureMarkerFileProvider.overrideWithValue(marker),
            currentPidProvider.overrideWithValue(4242),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container
              .read(installHelperProvider)
              .start(pid: 4242, dmgPath: dmg, bundlePath: bundle),
          throwsA(_couldNotStart),
        );
        expect(calls, ['/bin/sh']);
      },
    );

    test(
      'start reports the helper could not be started when the marker path cannot be read',
      () async {
        final io = RecordingUpdaterIo();
        final container = ProviderContainer(
          overrides: [
            installHelperRunnerProvider.overrideWithValue(io.runHelper),
            failureMarkerFileProvider.overrideWith(
              (ref) => throw StateError('no app support folder'),
            ),
            currentPidProvider.overrideWithValue(4242),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container
              .read(installHelperProvider)
              .start(pid: 4242, dmgPath: dmg, bundlePath: bundle),
          throwsA(_couldNotStart),
        );
        expect(io.helperRuns, isEmpty);
      },
    );
  });

  group('real process', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('open memex runner ');
    });

    tearDown(() async {
      // Lets the started process end, then removes its files.
      File('${root.path}/stop').writeAsStringSync('');
      await root.delete(recursive: true);
    });

    test(
      'the production helper runner starts the process detached with its arguments and returns without waiting for it',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final run = container.read(installHelperRunnerProvider);
        final out = '${root.path}/out file';
        final stop = '${root.path}/stop';

        // The process writes its arguments, its parent pid and its process
        // group, then runs until `stop` exists: the runner returning at all
        // shows it does not wait for the exit.
        await run('/bin/sh', [
          '-c',
          r'printf "%s|%s|%s|%s" "$1" "$2" "$PPID" "$(/bin/ps -o pgid= -p $$)" '
              r'> "$3.tmp" && mv "$3.tmp" "$3"; '
              r'while [ ! -e "$4" ]; do sleep 0.05; done',
          'runner-probe',
          'a b',
          "it's",
          out,
          stop,
        ]).timeout(const Duration(seconds: 10));

        // Wait for the real process (bounded), not a fixed sleep.
        final file = File(out);
        for (var i = 0; i < 200 && !file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(file.existsSync(), isTrue, reason: 'the process ran');
        final seen = file.readAsStringSync().split('|');
        expect(seen.take(2).join('|'), "a b|it's");

        // Detached: the child is not this process's child (a started process
        // in the default mode has this pid as its parent) and is outside this
        // process's group (it leads a group of its own).
        final ownGroup = await Process.run('/bin/ps', [
          '-o',
          'pgid=',
          '-p',
          '$pid',
        ]);
        expect(ownGroup.exitCode, 0, reason: '${ownGroup.stderr}');
        expect(seen[2].trim(), isNot('$pid'));
        expect(seen[3].trim(), isNot((ownGroup.stdout as String).trim()));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
