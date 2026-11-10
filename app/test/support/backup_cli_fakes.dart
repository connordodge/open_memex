// WI #322 (A1, D18, D20): `FakeMemexCli` handlers for `memex backup` and
// `memex restore`, built from the frozen D18 fixtures under
// `test/fixtures/backup/cli/` (R0 owns them; they are read-only here). A1
// only: A5 and A6 consume it and never edit it. A parity test in
// `test/cli/backup_cli_test.dart` proves every default below equals the
// fixture file it reads.
import 'dart:convert';
import 'dart:io';

import 'package:open_memex_app/src/memex_cli.dart';
import 'package:path/path.dart' as p;

import 'fake_memex_cli.dart';

/// The D18 backup fixtures, relative to `app/` (the `flutter test` cwd).
const backupFixturesDir = 'test/fixtures/backup';

String _read(String relative) =>
    File(p.join(backupFixturesDir, relative)).readAsStringSync();

/// clap's answer when `backup` or `restore` is not a known subcommand: exit
/// 2 and no C1 line (an older `memex`).
const clapUsageError =
    "error: unrecognized subcommand 'backup'\n\n"
    'Usage: memex <COMMAND>\n\n'
    "For more information, try '--help'.\n";

/// Exit 0 with `cli/backup_created.json` on stdout.
MemexResult fixtureBackupCreated() =>
    FakeMemexCli.ok(_read('cli/backup_created.json'));

/// Exit 0 with `cli/backup_unchanged.json` on stdout.
MemexResult fixtureBackupUnchanged() =>
    FakeMemexCli.ok(_read('cli/backup_unchanged.json'));

/// Exit 0 with `cli/backup_unchanged_never.json` on stdout (`last_file` null).
MemexResult fixtureBackupUnchangedNever() =>
    FakeMemexCli.ok(_read('cli/backup_unchanged_never.json'));

/// Exit 0 with `cli/restore_ok.json` on stdout.
MemexResult fixtureRestoreOk() => FakeMemexCli.ok(_read('cli/restore_ok.json'));

/// Exit 1 with `cli/errors/backup_too_new.json` as the one C1 stderr line.
MemexResult fixtureBackupTooNew() => MemexResult(
  exitCode: 1,
  stdout: '',
  stderr:
      '${jsonEncode(jsonDecode(_read('cli/errors/backup_too_new.json')))}\n',
);

/// Exit 2 with a C1-looking stderr line: the app must still read it as "too
/// old" (D20).
MemexResult fixtureTooOldWithC1Stderr() => MemexResult(
  exitCode: 2,
  stdout: '',
  stderr:
      '${jsonEncode({
        'error': {'code': 'backup_failed', 'message': 'looks like a C1 error'},
      })}\n',
);

/// Exit 2 with clap's usage error (what a real old `memex` prints).
MemexResult fixtureTooOld() =>
    FakeMemexCli.failure(clapUsageError, exitCode: 2);

/// A [FakeMemexCli] that answers `backup` with [backup] and `restore` with
/// [restore] (defaults: the `created` and `restore_ok` fixtures). Pass a
/// [MemexResult] from the helpers above or `FakeMemexCli.error(...)`; pass a
/// handler through [onBackup] / [onRestore] to throw (a spawn failure:
/// `ProcessException`) or inspect the call.
FakeMemexCli backupFakeCli({
  MemexResult? backup,
  MemexResult? restore,
  FakeCliHandler? onBackup,
  FakeCliHandler? onRestore,
  String binaryPath = 'fake-memex',
}) {
  final cli = FakeMemexCli(binaryPath: binaryPath);
  registerBackupCliHandlers(
    cli,
    backup: backup,
    restore: restore,
    onBackup: onBackup,
    onRestore: onRestore,
  );
  return cli;
}

/// Registers the `backup` and `restore` handlers on an existing [cli] (see
/// [backupFakeCli]).
void registerBackupCliHandlers(
  FakeMemexCli cli, {
  MemexResult? backup,
  MemexResult? restore,
  FakeCliHandler? onBackup,
  FakeCliHandler? onRestore,
}) {
  cli
    ..on('backup', onBackup ?? (_) => backup ?? fixtureBackupCreated())
    ..on('restore', onRestore ?? (_) => restore ?? fixtureRestoreOk());
}

/// A spawn failure, as `Process.start` throws it for a missing binary.
Never throwBinaryNotFound(FakeCliCall call) => throw ProcessException(
  'fake-memex',
  call.args,
  'No such file or directory',
  2,
);
