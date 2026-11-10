// WI #322 (A1, D20): the one source of backup and restore copy (Spec 22a, 31b
// and 35). The wording is the approved design's, every string lowercase: the
// Message table of `design/315-vault-backups/packs/325.md` and the Copy table
// of `packs/327.md`. All instants below are local `DateTime`s so the
// expected text does not depend on the machine's time zone.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart'
    show memexTooOldMessage, networkDriveRefusalMessage;

final _now = DateTime(2026, 11, 9, 14, 3);
final _failedToday = DateTime(2026, 11, 9, 9, 0);

const _gdrive =
    '/Users/tester/Library/CloudStorage/GoogleDrive-connor@example.com/'
    'My Drive/Open Memex Backups';
const _icloud =
    '/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/'
    'Open Memex Backups';
const _onedrive =
    '/Users/tester/Library/CloudStorage/OneDrive-Personal/Open Memex Backups';
const _nasFolder = '/Volumes/nas share/memex';

const _unavailableTail =
    ". check that it's still there and connected (a nas share mounted, the "
    'cloud app signed in), and that open memex may use it in system settings '
    '› privacy & security › files and folders.';

BackupMessage _local(
  String code, {
  String? message,
  bool automatic = true,
  DateTime? failedAt,
  String? destination = _gdrive,
  BackupProvider? provider = BackupProvider.googleDrive,
}) => backupFailureMessage(
  code: code,
  message: message,
  automatic: automatic,
  failedAt: failedAt ?? _failedToday,
  now: _now,
  destination: destination,
  provider: provider,
);

BackupMessage _hosted(
  String code, {
  String? message,
  DateTime? failedAt,
  String server = 'nas',
}) => backupFailureMessage(
  code: code,
  message: message,
  automatic: true,
  failedAt: failedAt ?? DateTime(2026, 11, 9, 3, 0),
  now: _now,
  serverName: server,
);

void main() {
  group('backupWhen', () {
    test('today reads today at the local clock time', () {
      expect(backupWhen(DateTime(2026, 11, 9, 14, 3), _now), 'today at 14:03');
      expect(backupWhen(DateTime(2026, 11, 9, 9, 2), _now), 'today at 09:02');
    });

    test('yesterday reads yesterday at the local clock time', () {
      expect(
        backupWhen(DateTime(2026, 11, 8, 9, 2), _now),
        'yesterday at 09:02',
      );
    });

    test('earlier reads the day and month in lowercase', () {
      expect(backupWhen(DateTime(2026, 11, 7, 14, 3), _now), '7 nov at 14:03');
      expect(
        backupWhen(DateTime(2026, 10, 19, 14, 3), _now),
        '19 oct at 14:03',
      );
    });

    test('every month has its three letter lowercase name', () {
      const names = [
        'jan',
        'feb',
        'mar',
        'apr',
        'may',
        'jun',
        'jul',
        'aug',
        'sep',
        'oct',
        'nov',
        'dec',
      ];
      final now = DateTime(2026, 12, 31, 12, 0);
      for (var month = 1; month <= 12; month++) {
        final text = backupWhen(DateTime(2026, month, 5, 8, 7), now);
        expect(text, '5 ${names[month - 1]} at 08:07');
      }
    });

    test('today and yesterday follow the calendar day not 24 hours', () {
      // 2 minutes apart across midnight: yesterday.
      expect(
        backupWhen(DateTime(2026, 11, 8, 23, 59), DateTime(2026, 11, 9, 0, 1)),
        'yesterday at 23:59',
      );
      // Nearly 24 hours apart on the same day: today.
      expect(
        backupWhen(DateTime(2026, 11, 9, 0, 0), DateTime(2026, 11, 9, 23, 59)),
        'today at 00:00',
      );
      // 47 hours apart but the calendar says yesterday.
      expect(
        backupWhen(DateTime(2026, 11, 8, 0, 30), DateTime(2026, 11, 9, 23, 30)),
        'yesterday at 00:30',
      );
      // Two calendar days, 24 hours and 2 minutes apart.
      expect(
        backupWhen(DateTime(2026, 11, 7, 23, 59), DateTime(2026, 11, 9, 0, 1)),
        '7 nov at 23:59',
      );
    });

    test('yesterday crosses a month and a year boundary', () {
      expect(
        backupWhen(DateTime(2026, 10, 31, 22, 0), DateTime(2026, 11, 1, 8, 0)),
        'yesterday at 22:00',
      );
      expect(
        backupWhen(DateTime(2025, 12, 31, 22, 0), DateTime(2026, 1, 1, 8, 0)),
        'yesterday at 22:00',
      );
    });

    test('the clock is zero padded to two digits', () {
      expect(backupWhen(DateTime(2026, 11, 9, 0, 5), _now), 'today at 00:05');
      expect(backupWhen(DateTime(2026, 11, 9, 13, 0), _now), 'today at 13:00');
    });

    test('a UTC instant shows in the viewer local time', () {
      final at = DateTime.utc(2026, 11, 9, 9, 0);
      final local = at.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      // Same instant as now, so the day word is today whatever the zone.
      expect(
        backupWhen(at, at.toLocal()),
        'today at ${two(local.hour)}:${two(local.minute)}',
      );
    });
  });

  group('backupSize', () {
    test('megabytes show one decimal', () {
      expect(backupSize(41200000), '41.2 MB');
      expect(backupSize(136000000), '136.0 MB');
      expect(backupSize(18600000), '18.6 MB');
    });

    test('kilobytes show no decimal', () {
      expect(backupSize(812000), '812 KB');
      expect(backupSize(48213), '48 KB');
    });

    test('gigabytes show one decimal', () {
      expect(backupSize(1300000000), '1.3 GB');
      expect(backupSize(12000000000), '12.0 GB');
    });
  });

  group('backupFailureMessage titles', () {
    test('an automatic run says the automatic backup failed', () {
      expect(
        _local('backup_failed', message: 'x').title,
        'the automatic backup failed at 09:00',
      );
    });

    test('a run from the button says back up now failed', () {
      expect(
        _local('backup_failed', message: 'x', automatic: false).title,
        'back up now failed at 09:00',
      );
    });

    test('the failure time reads yesterday and a date for earlier days', () {
      expect(
        _local(
          'backup_failed',
          message: 'x',
          failedAt: DateTime(2026, 11, 8, 9),
        ).title,
        'the automatic backup failed yesterday at 09:00',
      );
      expect(
        _local(
          'backup_failed',
          message: 'x',
          failedAt: DateTime(2026, 11, 3, 9),
        ).title,
        'the automatic backup failed 3 nov at 09:00',
      );
      expect(
        _local(
          'backup_failed',
          message: 'x',
          automatic: false,
          failedAt: DateTime(2026, 11, 8, 9),
        ).title,
        'back up now failed yesterday at 09:00',
      );
    });

    test('the title is the same for every failure code', () {
      for (final code in [
        'backup_destination_unavailable',
        'backup_destination_inside_vault',
        'backup_in_progress',
        'backup_failed',
        'network_filesystem',
        'internal',
        'something_new',
      ]) {
        expect(
          _local(code, message: 'm').title,
          'the automatic backup failed at 09:00',
          reason: code,
        );
      }
    });

    test('a hosted failure names the server whatever started the run', () {
      expect(
        _hosted('backup_failed', message: 'x').title,
        "nas's backup failed at 03:00",
      );
      expect(
        _hosted(
          'backup_failed',
          message: 'x',
          failedAt: DateTime(2026, 11, 8, 3),
          server: 'work server',
        ).title,
        "work server's backup failed yesterday at 03:00",
      );
      expect(
        backupFailureMessage(
          code: 'backup_failed',
          message: 'x',
          automatic: false,
          failedAt: DateTime(2026, 11, 9, 3),
          now: _now,
          serverName: 'nas',
        ).title,
        "nas's backup failed at 03:00",
      );
    });
  });

  group('backupFailureMessage local details', () {
    test('destination unavailable names the provider folder', () {
      final m = _local('backup_destination_unavailable', message: 'raw');
      expect(
        m.detail,
        "can't write to Open Memex Backups in google drive$_unavailableTail",
      );
      expect(m.short, "can't write to Google Drive");
    });

    // Pack 325: <where> is lowercase ("in icloud drive"); <provider> in the
    // short tail is the display name ("iCloud Drive"), as pack 326's
    // semantic label shows it ("can't write to Google Drive").
    test('destination unavailable names each provider in lowercase', () {
      final icloud = _local(
        'backup_destination_unavailable',
        destination: _icloud,
        provider: BackupProvider.icloud,
      );
      expect(
        icloud.detail,
        "can't write to Open Memex Backups in icloud drive$_unavailableTail",
      );
      expect(icloud.short, "can't write to iCloud Drive");
      final onedrive = _local(
        'backup_destination_unavailable',
        destination: _onedrive,
        provider: BackupProvider.oneDrive,
      );
      expect(
        onedrive.detail,
        "can't write to Open Memex Backups in onedrive$_unavailableTail",
      );
      expect(onedrive.short, "can't write to OneDrive");
    });

    test('destination unavailable for a chosen folder names its full path', () {
      final m = _local(
        'backup_destination_unavailable',
        destination: _nasFolder,
        provider: null,
      );
      expect(m.detail, "can't write to $_nasFolder$_unavailableTail");
      expect(m.short, "can't write to memex");
    });

    test('destination inside the vault says to choose a folder outside it', () {
      final m = _local('backup_destination_inside_vault', message: 'raw');
      expect(
        m.detail,
        'the backup folder is inside the vault. choose a folder outside it.',
      );
      expect(m.short, 'the backup folder is inside the vault');
    });

    test('a backup already running says so', () {
      final m = _local('backup_in_progress', message: 'raw');
      expect(m.detail, 'a backup of this vault is already running.');
      expect(m.short, 'a backup is already running');
    });

    test('backup_failed carries the raw message', () {
      final m = _local(
        'backup_failed',
        message: 'backup failed: quick_check failed on the snapshot',
      );
      expect(
        m.detail,
        "the backup couldn't be made: backup failed: quick_check failed on "
        'the snapshot.',
      );
      expect(m.short, "the backup couldn't be made");
    });

    test('internal and any unknown code read as backup_failed', () {
      for (final code in ['internal', 'something_new', '']) {
        final m = _local(code, message: 'disk on fire');
        expect(
          m.detail,
          "the backup couldn't be made: disk on fire.",
          reason: code,
        );
        expect(m.short, "the backup couldn't be made", reason: code);
      }
    });

    test('a failure with no message leaves the colon out', () {
      final m = _local('internal');
      expect(m.detail, "the backup couldn't be made.");
      expect(m.short, "the backup couldn't be made");
    });

    test('a network drive uses the existing refusal copy', () {
      final m = _local('network_filesystem', message: 'raw');
      expect(m.detail, networkDriveRefusalMessage);
      expect(m.short, 'this folder is on a network drive');
    });

    test('the message text of a code that does not use it is not shown', () {
      for (final code in [
        'backup_destination_unavailable',
        'backup_destination_inside_vault',
        'backup_in_progress',
        'network_filesystem',
      ]) {
        final m = _local(code, message: 'RAW-MARKER');
        expect(m.detail, isNotEmpty, reason: code);
        expect(m.detail, isNot(contains('RAW-MARKER')), reason: code);
        expect(m.short, isNot(contains('RAW-MARKER')), reason: code);
      }
    });
  });

  group('backupFailureMessage hosted details', () {
    test('destination unavailable names the server and its backup folder', () {
      final m = _hosted('backup_destination_unavailable', message: 'raw');
      expect(
        m.detail,
        "nas can't write to its backup folder. check that the folder given "
        'to --backup-dir exists on nas and is writable.',
      );
      expect(m.short, "nas can't write to its backup folder");
    });

    test('the server name fills every place in the hosted wording', () {
      final m = _hosted('backup_destination_unavailable', server: 'office nas');
      expect(
        m.detail,
        "office nas can't write to its backup folder. check that the folder "
        'given to --backup-dir exists on office nas and is writable.',
      );
      expect(m.short, "office nas can't write to its backup folder");
    });

    test(
      'backup_failed and any other code name the server and the message',
      () {
        for (final code in ['backup_failed', 'internal', 'something_new']) {
          final m = _hosted(code, message: 'disk on fire');
          expect(
            m.detail,
            "nas couldn't make the backup: disk on fire.",
            reason: code,
          );
          expect(m.short, "nas couldn't make the backup", reason: code);
        }
      },
    );

    test(
      'inside the vault and network drive fall to the generic hosted row',
      () {
        for (final code in [
          'backup_destination_inside_vault',
          'network_filesystem',
        ]) {
          final m = _hosted(code, message: 'raw text');
          expect(
            m.detail,
            "nas couldn't make the backup: raw text.",
            reason: code,
          );
          expect(m.short, "nas couldn't make the backup", reason: code);
        }
      },
    );

    test('a hosted failure with no message leaves the colon out', () {
      final m = _hosted('internal');
      expect(m.detail, "nas couldn't make the backup.");
    });

    test('a hosted failure never uses the local wording', () {
      final m = _hosted('backup_destination_unavailable');
      expect(m.detail, contains('--backup-dir'));
      expect(m.detail, isNot(contains('system settings')));
      expect(m.detail, isNot(contains('Open Memex Backups')));
    });
  });

  group('fixed backup messages', () {
    test('exit 2 says this memex is too old to make backups', () {
      expect(
        backupTooOldMessage(),
        const BackupMessage(
          title: 'this memex is too old to make backups',
          detail: 'update memex, then try again.',
          short: 'this memex is too old to make backups',
        ),
      );
    });

    test('a missing binary says memex binary not found', () {
      expect(
        backupBinaryNotFoundMessage(),
        const BackupMessage(
          title: 'memex binary not found',
          detail: 'install memex, or locate it, then try again.',
          short: 'memex binary not found',
        ),
      );
    });
  });

  group('restoreFailureMessage', () {
    String message(
      RestoreRunResult r, {
      String name = 'work',
      String parent = '/Users/tester/Documents',
    }) => restoreFailureMessage(r, name: name, parent: parent);

    test('target not empty names the folder and its parent', () {
      expect(
        message(
          const RestoreFailure(
            code: 'restore_target_not_empty',
            message: 'raw',
          ),
          name: 'My Work',
          parent: '/Users/connor/Mobile Documents',
        ),
        "a folder named My Work already exists in /Users/connor/Mobile "
        "Documents and isn't empty. choose another name or folder.",
      );
    });

    test('an invalid backup says nothing was written', () {
      expect(
        message(const RestoreFailure(code: 'backup_invalid', message: 'raw')),
        "this file isn't an open memex backup, or it's damaged. nothing was "
        'written.',
      );
    });

    test('a newer backup reads both versions from the fields', () {
      expect(
        message(
          const RestoreFailure(
            code: 'backup_too_new',
            message: 'schema V1; supports V2',
            fields: {'schema_version': 7, 'supported_schema_version': 6},
          ),
        ),
        'this backup was made by a newer memex (schema V7; this memex '
        'supports V6). update memex, then try again.',
      );
      expect(
        message(
          const RestoreFailure(
            code: 'backup_too_new',
            message: 'raw',
            fields: {'schema_version': 12, 'supported_schema_version': 11},
          ),
        ),
        'this backup was made by a newer memex (schema V12; this memex '
        'supports V11). update memex, then try again.',
      );
    });

    const tooNewNoVersions =
        'this backup was made by a newer memex. update memex, then try again.';
    final tooNewCases = <(String, Map<String, Object?>)>[
      ('a newer backup with no version fields drops the versions', {}),
      (
        'a newer backup missing only schema_version drops the versions',
        {'supported_schema_version': 6},
      ),
      (
        'a newer backup missing only supported_schema_version drops the versions',
        {'schema_version': 7},
      ),
      (
        'a newer backup with null versions drops the versions',
        {'schema_version': null, 'supported_schema_version': null},
      ),
      (
        'a newer backup with a string schema_version drops the versions',
        {'schema_version': '7', 'supported_schema_version': 6},
      ),
      (
        'a newer backup with a string supported_schema_version drops the versions',
        {'schema_version': 7, 'supported_schema_version': '6'},
      ),
      (
        'a newer backup with a non-integer number drops the versions',
        {'schema_version': 7.5, 'supported_schema_version': 6},
      ),
    ];
    for (final (name, fields) in tooNewCases) {
      test(name, () {
        final text = message(
          RestoreFailure(
            code: 'backup_too_new',
            message: 'raw detail',
            fields: fields,
          ),
        );
        expect(text, tooNewNoVersions);
        expect(text, isNot(contains('null')));
        expect(text, isNot(contains('V')));
        expect(text, isNot(contains('raw detail')));
      });
    }

    test('a network drive uses the existing refusal copy', () {
      expect(
        message(
          const RestoreFailure(code: 'network_filesystem', message: 'raw'),
        ),
        networkDriveRefusalMessage,
      );
    });

    test('exit 2 uses the existing too old memex copy', () {
      expect(message(const RestoreTooOld()), memexTooOldMessage);
      // The sheet's too old text is a different message.
      expect(
        message(const RestoreTooOld()),
        isNot(backupTooOldMessage().title),
      );
    });

    test('a missing binary says memex binary not found', () {
      expect(
        message(const RestoreBinaryNotFound()),
        'memex binary not found. install memex, or locate it, then try again.',
      );
    });

    test('internal and any other code carry the raw message', () {
      for (final code in ['internal', 'something_new']) {
        expect(
          message(RestoreFailure(code: code, message: 'disk on fire')),
          "the backup couldn't be restored: disk on fire.",
          reason: code,
        );
      }
    });

    test('a restored vault has no error text', () {
      expect(
        message(const RestoreFailure(code: 'backup_invalid', message: 'raw')),
        isNotEmpty,
      );
      expect(
        message(
          RestoreOk(
            vaultId: '01JCB7Q4M8V2X5N9R3T6W0YZAE',
            path: '/Users/tester/Documents/work',
            createdAt: DateTime.utc(2026, 11, 9, 9),
          ),
        ),
        '',
      );
    });
  });

  group('verify: boundaries and fallbacks', () {
    test(
      'backupSize switches unit exactly at 1000 and rounds up across units',
      () {
        const expected = {
          0: '0 B',
          999: '999 B',
          1000: '1 KB',
          1499: '1 KB',
          1500: '2 KB',
          999499: '999 KB',
          999500: '1.0 MB',
          999999: '1.0 MB',
          1000000: '1.0 MB',
          999949999: '999.9 MB',
          999950000: '1.0 GB',
          1000000000: '1.0 GB',
          1550000000: '1.6 GB',
        };
        for (final entry in expected.entries) {
          expect(backupSize(entry.key), entry.value, reason: '${entry.key}');
        }
      },
    );

    test('an empty message leaves the colon out like a missing one', () {
      expect(
        _local('backup_failed', message: '').detail,
        "the backup couldn't be made.",
      );
      expect(
        _hosted('backup_failed', message: '').detail,
        "nas couldn't make the backup.",
      );
      expect(
        restoreFailureMessage(
          const RestoreFailure(code: 'internal', message: ''),
          name: 'w',
          parent: '/p',
        ),
        "the backup couldn't be restored.",
      );
    });

    test(
      'a chosen folder is named by its last segment however it is written',
      () {
        const folders = {
          '/Volumes/nas share/memex/': 'memex',
          r'C:\Backups\memex': 'memex',
          '/memex': 'memex',
          'memex': 'memex',
          '/': 'the backup folder',
          '': 'the backup folder',
        };
        for (final entry in folders.entries) {
          final m = _local(
            'backup_destination_unavailable',
            destination: entry.key,
            provider: null,
          );

          expect(m.short, "can't write to ${entry.value}", reason: entry.key);
        }
        final none = _local(
          'backup_destination_unavailable',
          destination: null,
          provider: null,
        );
        expect(none.short, "can't write to the backup folder");
        expect(
          none.detail,
          startsWith("can't write to the backup folder. check"),
        );
      },
    );

    test(
      'a day with the same date in another month or year reads as a date',
      () {
        final now = DateTime(2026, 11, 9, 14, 3);

        expect(backupWhen(DateTime(2026, 10, 9, 14, 3), now), '9 oct at 14:03');
        expect(backupWhen(DateTime(2025, 11, 9, 14, 3), now), '9 nov at 14:03');
        expect(
          backupWhen(DateTime(2026, 11, 8, 23, 59), now),
          'yesterday at 23:59',
        );
        expect(
          backupWhen(DateTime(2026, 11, 7, 23, 59), now),
          '7 nov at 23:59',
        );
      },
    );

    test(
      'a failure title keeps a date or yesterday and only drops the today word',
      () {
        expect(
          _local('backup_failed', failedAt: DateTime(2026, 11, 8, 9, 0)).title,
          'the automatic backup failed yesterday at 09:00',
        );
        expect(
          _local('backup_failed', failedAt: DateTime(2026, 11, 2, 9, 0)).title,
          'the automatic backup failed 2 nov at 09:00',
        );
        expect(
          _local('backup_failed').title,
          'the automatic backup failed at 09:00',
        );
      },
    );

    test(
      'backup_too_new names the versions found in the fields whatever they are',
      () {
        expect(
          restoreFailureMessage(
            const RestoreFailure(
              code: 'backup_too_new',
              message: 'raw',
              fields: {'schema_version': 3, 'supported_schema_version': 2},
            ),
            name: 'w',
            parent: '/p',
          ),
          contains('(schema V3; this memex supports V2)'),
        );
      },
    );
  });
}
