// WI #322 (A1, D20): `CliBackupRunner`, the `memex backup` / `memex restore`
// wrapper and its outcome classifier. Exit 0 parses the D18 fixtures (req 17,
// 34); exit 2 is "too old" whatever stderr says; a `ProcessException` is
// "binary not found"; any other failure is the C1 code and the raw C1 message
// (`backup_too_new` also keeps its fields). Args are always a list, never a
// shell.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/backup_cli_fakes.dart';
import '../support/fake_memex_cli.dart';

/// A vault path with a space, `~` and `@`: the normal case on macOS.
const _vault = '/Users/connor@example.com/Mobile Documents/My Vault';
const _dest =
    '/Users/tester/Library/CloudStorage/GoogleDrive-connor@example.com/'
    'My Drive/Open Memex Backups';
const _icloud =
    '/Users/person/Library/Mobile Documents/com~apple~CloudDocs/'
    'Open Memex Backups';

Future<BackupRunResult> _backup(
  FakeMemexCli cli, {
  String vaultPath = _vault,
  String destination = _dest,
  int keep = 30,
  bool ifChanged = false,
}) => CliBackupRunner(cli).backup(
  vaultPath: vaultPath,
  destination: destination,
  keep: keep,
  ifChanged: ifChanged,
);

Future<RestoreRunResult> _restore(
  FakeMemexCli cli, {
  String from = '/Users/tester/Downloads/My Backups/notes.memex.zip',
  String to = '/Users/tester/Documents/notes restored',
}) => CliBackupRunner(cli).restore(from: from, to: to);

void main() {
  group('backup arguments', () {
    test(
      'backup runs memex backup with vault dest and keep as one argument each',
      () async {
        final cli = backupFakeCli();

        await _backup(cli, keep: 30);

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'backup',
          '--vault',
          _vault,
          '--dest',
          _dest,
          '--keep',
          '30',
        ]);
        expect(cli.calls.single.stdinBody, isNull);
      },
    );

    test('backup adds if-changed as the last argument when asked', () async {
      final cli = backupFakeCli();

      await _backup(cli, keep: 7, ifChanged: true);

      expect(cli.calls.single.args, [
        'backup',
        '--vault',
        _vault,
        '--dest',
        _dest,
        '--keep',
        '7',
        '--if-changed',
      ]);
    });

    test('backup passes keep at both ends of the range', () async {
      final cli = backupFakeCli();

      await _backup(cli, keep: backupKeepMin);
      await _backup(cli, keep: backupKeepMax, ifChanged: true);

      expect(cli.calls.map((c) => c.flag('keep')), ['1', '365']);
      expect(cli.calls.map((c) => c.hasFlag('if-changed')), [false, true]);
    });

    test('backup keeps spaces tilde and at signs in a path intact', () async {
      final cli = backupFakeCli();

      await _backup(
        cli,
        vaultPath: '/Users/a b/~vault@home/My Vault',
        destination: _icloud,
      );

      final call = cli.calls.single;
      expect(call.flag('vault'), '/Users/a b/~vault@home/My Vault');
      expect(call.flag('dest'), _icloud);
      expect(call.args, hasLength(7));
    });

    test(
      'restore runs memex restore with from and to as one argument each',
      () async {
        final cli = backupFakeCli();

        await _restore(
          cli,
          from: '/Users/tester/Downloads/My Backups/notes~1@x.memex.zip',
          to: '/Users/tester/Documents/notes restored',
        );

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'restore',
          '--from',
          '/Users/tester/Downloads/My Backups/notes~1@x.memex.zip',
          '--to',
          '/Users/tester/Documents/notes restored',
        ]);
        expect(cli.calls.single.stdinBody, isNull);
      },
    );
  });

  group('backup output', () {
    test('exit 0 created parses file bytes fingerprint and removed', () async {
      final cli = backupFakeCli(backup: fixtureBackupCreated());

      final result = await _backup(cli);

      expect(
        result,
        const BackupCreated(
          file:
              '$_icloud/notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE'
              '.memex.zip',
          bytes: 48213,
          fingerprint:
              '406effb1e9c59672c66a598c2b21e331b23b16c54024e96d6df3e7c173549791',
          removed: [
            '$_icloud/notes-20261008T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE'
                '.memex.zip',
            '$_icloud/notes-20261009T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE'
                '.memex.zip',
          ],
        ),
      );
    });

    test(
      'exit 0 created with nothing removed has an empty removed list',
      () async {
        final cli = backupFakeCli(
          backup: FakeMemexCli.ok(
            jsonEncode({
              'result': 'created',
              'vault_id': '01JCB7Q4M8V2X5N9R3T6W0YZAE',
              'file':
                  '/d/x-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip',
              'bytes': 10,
              'fingerprint': 'ab',
              'removed': <String>[],
            }),
          ),
        );

        final result = await _backup(cli);

        expect(result, isA<BackupCreated>());
        expect((result as BackupCreated).removed, isEmpty);
        expect(result.bytes, 10);
      },
    );

    test('exit 0 unchanged parses the last file', () async {
      final cli = backupFakeCli(backup: fixtureBackupUnchanged());

      final result = await _backup(cli, ifChanged: true);

      expect(
        result,
        const BackupUnchanged(
          lastFile:
              '$_icloud/notes-20261108T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE'
              '.memex.zip',
        ),
      );
    });

    test('exit 0 unchanged with a null last file has no last file', () async {
      final cli = backupFakeCli(backup: fixtureBackupUnchangedNever());

      final result = await _backup(cli, ifChanged: true);

      expect(result, const BackupUnchanged(lastFile: null));
    });

    test(
      'exit 0 with output that is not the contract is an internal failure',
      () async {
        for (final stdout in ['', 'not json', '[]', '{"result":"exploded"}']) {
          final cli = backupFakeCli(backup: FakeMemexCli.ok(stdout));

          final result = await _backup(cli);

          expect(result, isA<BackupFailure>(), reason: 'stdout: $stdout');
          expect((result as BackupFailure).code, 'internal');
        }
      },
    );
  });

  group('backup failures', () {
    test('exit 2 is too old even when stderr looks like a C1 error', () async {
      final cli = backupFakeCli(backup: fixtureTooOldWithC1Stderr());

      expect(await _backup(cli), const BackupTooOld());
    });

    test('exit 2 with clap usage text is too old', () async {
      final cli = backupFakeCli(backup: fixtureTooOld());

      expect(await _backup(cli), const BackupTooOld());
    });

    test('exit 2 with empty stderr is too old', () async {
      final cli = backupFakeCli(backup: FakeMemexCli.failure('', exitCode: 2));

      expect(await _backup(cli), const BackupTooOld());
    });

    test(
      'a spawn failure is binary not found and backup does not throw',
      () async {
        final cli = backupFakeCli(onBackup: throwBinaryNotFound);

        expect(await _backup(cli), const BackupBinaryNotFound());
      },
    );

    test(
      'no memex configured is binary not found without running anything',
      () async {
        final runner = const CliBackupRunner(null);

        expect(
          await runner.backup(
            vaultPath: _vault,
            destination: _dest,
            keep: 30,
            ifChanged: false,
          ),
          const BackupBinaryNotFound(),
        );
        expect(
          await runner.restore(from: '/a.memex.zip', to: '/b'),
          const RestoreBinaryNotFound(),
        );
      },
    );

    for (final c in [
      (
        'exit 1 backup_destination_unavailable keeps the code and raw message',
        'backup_destination_unavailable',
        'backup destination unavailable: /Volumes/nas share/memex is not writable',
      ),
      (
        'exit 1 backup_destination_inside_vault keeps the code and raw message',
        'backup_destination_inside_vault',
        'backup destination is inside the vault: /Users/a b/Vault/backups',
      ),
      (
        'exit 1 backup_in_progress keeps the code and raw message',
        'backup_in_progress',
        'a backup of this vault is already running: Vault',
      ),
      (
        'exit 1 backup_failed keeps the code and raw message',
        'backup_failed',
        'backup failed: quick_check failed on the snapshot',
      ),
      (
        'exit 1 network_filesystem keeps the code and raw message',
        'network_filesystem',
        'the vault is on a network filesystem',
      ),
      (
        'exit 1 internal keeps the code and raw message',
        'internal',
        'internal error: disk on fire',
      ),
    ]) {
      test(c.$1, () async {
        final cli = backupFakeCli(backup: FakeMemexCli.error(c.$2, c.$3));

        expect(await _backup(cli), BackupFailure(code: c.$2, message: c.$3));
      });
    }

    test(
      'exit 1 carries the C1 message without the operation prefix',
      () async {
        final cli = backupFakeCli(
          backup: FakeMemexCli.error('backup_failed', 'boom'),
        );

        final result = await _backup(cli);

        expect(
          result,
          const BackupFailure(code: 'backup_failed', message: 'boom'),
        );
      },
    );

    test('exit 1 finds the C1 line after log lines on stderr', () async {
      final cli = backupFakeCli(
        backup: FakeMemexCli.failure(
          'warning: slow disk\n'
          '${jsonEncode({
            'error': {'code': 'backup_destination_unavailable', 'message': 'gone'},
          })}\n',
        ),
      );

      expect(
        await _backup(cli),
        const BackupFailure(
          code: 'backup_destination_unavailable',
          message: 'gone',
        ),
      );
    });

    test(
      'exit 1 with stderr that is not a C1 line is an internal failure',
      () async {
        final cli = backupFakeCli(
          backup: FakeMemexCli.failure('something broke\n'),
        );

        final result = await _backup(cli);

        expect(result, isA<BackupFailure>());
        expect((result as BackupFailure).code, 'internal');
        expect(result.message, contains('something broke'));
      },
    );

    test('any other exit code is a failure and never too old', () async {
      for (final exit in [3, 101, 137]) {
        final cli = backupFakeCli(
          backup: FakeMemexCli.failure('killed\n', exitCode: exit),
        );

        final result = await _backup(cli);

        expect(result, isA<BackupFailure>(), reason: 'exit $exit');
        expect((result as BackupFailure).code, 'internal');
      }
    });
  });

  group('restore output', () {
    test('exit 0 parses the restored vault id path and created_at', () async {
      final cli = backupFakeCli(restore: fixtureRestoreOk());

      final result = await _restore(cli);

      expect(
        result,
        RestoreOk(
          vaultId: '01JCB7Q4M8V2X5N9R3T6W0YZAE',
          path: '/Users/person/Documents/notes restored',
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            1794214800000,
            isUtc: true,
          ),
        ),
      );
      expect((result as RestoreOk).createdAt.isUtc, isTrue);
    });

    test(
      'exit 0 with output that is not the contract is an internal failure',
      () async {
        for (final stdout in ['', 'nope', '{"vault_id":"x"}']) {
          final cli = backupFakeCli(restore: FakeMemexCli.ok(stdout));

          final result = await _restore(cli);

          expect(result, isA<RestoreFailure>(), reason: 'stdout: $stdout');
          expect((result as RestoreFailure).code, 'internal');
        }
      },
    );

    test(
      'backup_too_new reads both versions from fields not the message',
      () async {
        final cli = backupFakeCli(restore: fixtureBackupTooNew());

        final result = await _restore(cli);

        expect(
          result,
          const RestoreFailure(
            code: 'backup_too_new',
            message:
                'backup too new: it holds schema V7; this memex supports V6',
            fields: {'schema_version': 7, 'supported_schema_version': 6},
          ),
        );
      },
    );

    test(
      'backup_too_new keeps the fields when the message has other numbers',
      () async {
        final cli = backupFakeCli(
          restore: FakeMemexCli.error('backup_too_new', 'schema V1 vs V2', {
            'schema_version': 9,
            'supported_schema_version': 8,
          }),
        );

        final result = await _restore(cli);

        expect(result, isA<RestoreFailure>());
        expect((result as RestoreFailure).fields, {
          'schema_version': 9,
          'supported_schema_version': 8,
        });
        expect(result.message, 'schema V1 vs V2');
      },
    );

    for (final c in [
      (
        'restore exit 1 restore_target_not_empty keeps the code and message',
        'restore_target_not_empty',
        'restore target is not empty: /Users/a b/Documents/work',
      ),
      (
        'restore exit 1 backup_invalid keeps the code and message',
        'backup_invalid',
        'backup invalid: manifest.json is missing',
      ),
      (
        'restore exit 1 network_filesystem keeps the code and message',
        'network_filesystem',
        'the folder is on a network filesystem',
      ),
      (
        'restore exit 1 internal keeps the code and message',
        'internal',
        'internal error: nope',
      ),
    ]) {
      test(c.$1, () async {
        final cli = backupFakeCli(restore: FakeMemexCli.error(c.$2, c.$3));

        expect(await _restore(cli), RestoreFailure(code: c.$2, message: c.$3));
      });
    }

    test(
      'restore exit 2 is too old even when stderr looks like a C1 error',
      () async {
        final cli = backupFakeCli(restore: fixtureTooOldWithC1Stderr());

        expect(await _restore(cli), const RestoreTooOld());
      },
    );

    test('restore exit 2 with clap usage text is too old', () async {
      final cli = backupFakeCli(restore: fixtureTooOld());

      expect(await _restore(cli), const RestoreTooOld());
    });

    test(
      'restore spawn failure is binary not found and does not throw',
      () async {
        final cli = backupFakeCli(onRestore: throwBinaryNotFound);

        expect(await _restore(cli), const RestoreBinaryNotFound());
      },
    );

    test('restore with a non C1 stderr is an internal failure', () async {
      final cli = backupFakeCli(restore: FakeMemexCli.failure('oops\n'));

      final result = await _restore(cli);

      expect(result, isA<RestoreFailure>());
      expect((result as RestoreFailure).code, 'internal');
      expect(result.fields, isEmpty);
    });
  });

  group('backupRunnerProvider', () {
    test('backupRunnerProvider runs the configured memex', () async {
      final cli = backupFakeCli();
      final container = ProviderContainer(
        overrides: [memexCliProvider.overrideWithValue(cli)],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(backupRunnerProvider)
          .backup(
            vaultPath: _vault,
            destination: _dest,
            keep: 30,
            ifChanged: true,
          );

      expect(result, isA<BackupCreated>());
      expect(cli.calls.single.args.first, 'backup');
      expect(cli.calls.single.hasFlag('if-changed'), isTrue);
    });

    test(
      'backupRunnerProvider with no memex configured is binary not found',
      () async {
        final container = ProviderContainer(
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        addTearDown(container.dispose);

        final runner = container.read(backupRunnerProvider);

        expect(
          await runner.backup(
            vaultPath: _vault,
            destination: _dest,
            keep: 30,
            ifChanged: false,
          ),
          const BackupBinaryNotFound(),
        );
      },
    );
  });

  group('backup_cli_fakes parity', () {
    Object? fixture(String relative) =>
        jsonDecode(File('$backupFixturesDir/$relative').readAsStringSync());

    test('backup_cli_fakes defaults equal the D18 cli fixtures', () async {
      final cli = backupFakeCli();

      final backup = await cli.run(['backup', '--vault', _vault]);
      final restore = await cli.run(['restore', '--from', 'a', '--to', 'b']);

      expect(backup.exitCode, 0);
      expect(jsonDecode(backup.stdout), fixture('cli/backup_created.json'));
      expect(restore.exitCode, 0);
      expect(jsonDecode(restore.stdout), fixture('cli/restore_ok.json'));
      expect(
        jsonDecode(fixtureBackupUnchanged().stdout),
        fixture('cli/backup_unchanged.json'),
      );
      expect(
        jsonDecode(fixtureBackupUnchangedNever().stdout),
        fixture('cli/backup_unchanged_never.json'),
      );
      final tooNew = fixtureBackupTooNew();
      expect(tooNew.exitCode, 1);
      expect(
        jsonDecode(tooNew.stderr.trim()),
        fixture('cli/errors/backup_too_new.json'),
      );
      // The runner accepts what the fake defaults serve.
      expect(await _backup(cli), isA<BackupCreated>());
      expect(await _restore(cli), isA<RestoreOk>());
    });

    test(
      'backup_cli_fakes defaults read through the runner as the fixtures say',
      () async {
        final cli = backupFakeCli();

        final created = await _backup(cli);
        final restored = await _restore(cli);
        final unchanged = await _backup(
          backupFakeCli(backup: fixtureBackupUnchanged()),
        );
        final never = await _backup(
          backupFakeCli(backup: fixtureBackupUnchangedNever()),
        );

        final createdJson = fixture('cli/backup_created.json')! as Map;
        expect(
          created,
          BackupCreated(
            file: createdJson['file']! as String,
            bytes: createdJson['bytes']! as int,
            fingerprint: createdJson['fingerprint']! as String,
            removed: (createdJson['removed']! as List).cast<String>(),
          ),
        );
        final restoreJson = fixture('cli/restore_ok.json')! as Map;
        expect(
          restored,
          RestoreOk(
            vaultId: restoreJson['vault_id']! as String,
            path: restoreJson['path']! as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              restoreJson['created_at']! as int,
              isUtc: true,
            ),
          ),
        );
        expect(
          unchanged,
          BackupUnchanged(
            lastFile:
                (fixture('cli/backup_unchanged.json')! as Map)['last_file']!
                    as String,
          ),
        );
        expect(never, const BackupUnchanged(lastFile: null));
      },
    );

    test('backup_cli_fakes handlers can be replaced per command', () async {
      final cli = backupFakeCli(
        backup: FakeMemexCli.error('backup_failed', 'x'),
        restore: fixtureTooOld(),
      );

      expect(
        await _backup(cli),
        const BackupFailure(code: 'backup_failed', message: 'x'),
      );
      expect(await _restore(cli), const RestoreTooOld());
    });
  });
}
