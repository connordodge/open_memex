// WI #321 (A0, D19): the backup seam's contracts. The frozen models and Keys
// (group 1-3, red until implemented), the stub files (group 4: each filler
// deletes its stub's test when it replaces the stub), and the harness and
// fakes (group 5, which every later backup WI builds on).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_names.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/backup_fakes.dart';
import '../support/backup_harness.dart';
import '../support/fake_clock.dart';

// Unix ms of 2026-11-09 09:00:00 UTC and one day earlier.
const _t1Ms = 1794214800000;
const _t0Ms = 1794128400000;
final _t1 = DateTime.fromMillisecondsSinceEpoch(_t1Ms, isUtc: true);
final _t0 = DateTime.fromMillisecondsSinceEpoch(_t0Ms, isUtc: true);

/// Run-time values, so the constructors under test really run.
VaultBackupSettings _settings({
  bool enabled = true,
  String? destination = '/Volumes/NAS share/Open Memex Backups',
  int keep = 45,
  bool automatic = false,
}) => VaultBackupSettings(
  enabled: enabled,
  destination: destination,
  keep: keep,
  automatic: automatic,
);

BackupStatus _created() => BackupStatus(
  lastAttemptAt: _t1,
  lastSuccessAt: _t1,
  lastResult: 'created',
  lastError: null,
  lastFile: 'Notes-20261109T090000Z-01HV0000000000000000000000.memex.zip',
  lastFileCreatedAt: _t1,
  lastBytes: 136000000,
  lastFingerprint: 'ab12',
);

BackupStatus _failedAfterSuccess() => BackupStatus(
  lastAttemptAt: _t1,
  lastSuccessAt: _t0,
  lastResult: 'backup_destination_unavailable',
  lastError: 'cannot write to /Volumes/NAS',
  lastFile: 'Notes-20261108T090000Z-01HV0000000000000000000000.memex.zip',
  lastFileCreatedAt: _t0,
  lastBytes: 135000000,
  lastFingerprint: 'cd34',
);

Map<String, Object?> _createdStateJson() => {
  'last_attempt_at': _t1Ms,
  'last_success_at': _t1Ms,
  'last_result': 'created',
  'last_error': null,
  'last_file': 'Notes-20261109T090000Z-01HV0000000000000000000000.memex.zip',
  'last_file_created_at': _t1Ms,
  'last_bytes': 136000000,
  'last_fingerprint': 'ab12',
};

Map<String, Object?> _hostedJson({bool inProgress = true}) => {
  'enabled': true,
  'keep': 30,
  'in_progress': inProgress,
  'last_attempt_at': _t1Ms,
  'last_success_at': _t0Ms,
  'last_result': 'backup_failed',
  'last_error': 'disk full',
  'last_file': 'Notes-20261108T090000Z-01HV0000000000000000000000.memex.zip',
  'last_file_created_at': _t0Ms,
  'last_bytes': 135000000,
};

/// Asserts [a] and [b] are equal and hash alike, then that each variant in
/// [others] differs from [a] (it differs in exactly one field).
void _expectValueSemantics(Object a, Object b, List<Object> others) {
  expect(a, b);
  expect(a.hashCode, b.hashCode);
  for (final o in others) {
    expect(a == o, isFalse, reason: '$a must differ from $o');
  }
}

void main() {
  // ------------------------------------------------------------------
  // 1. Models
  // ------------------------------------------------------------------
  group('VaultBackupSettings', () {
    test('VaultBackupSettings defaults to keep 30 and automatic on', () {
      final s = VaultBackupSettings();
      expect(s.enabled, isFalse);
      expect(s.destination, isNull);
      expect(s.keep, 30);
      expect(s.automatic, isTrue);
    });

    test('VaultBackupSettings rejects keep outside 1 to 365', () {
      for (final keep in [1, 2, 364, 365]) {
        expect(VaultBackupSettings(keep: keep).keep, keep);
      }
      for (final keep in [0, -1, 366, 1000]) {
        expect(
          () => VaultBackupSettings(keep: keep),
          throwsA(isA<AssertionError>()),
          reason: 'keep $keep',
        );
      }
      expect(
        () => _settings().copyWith(keep: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => _settings().copyWith(keep: 366),
        throwsA(isA<AssertionError>()),
      );
    });

    test('VaultBackupSettings round-trips its JSON', () {
      final s = _settings();
      expect(s.toJson(), {
        'enabled': true,
        'destination': '/Volumes/NAS share/Open Memex Backups',
        'keep': 45,
        'automatic': false,
      });
      expect(VaultBackupSettings.fromJson(s.toJson()), s);
      final bare = _settings(enabled: false, destination: null);
      expect(bare.toJson(), {
        'enabled': false,
        'destination': null,
        'keep': 45,
        'automatic': false,
      });
      expect(VaultBackupSettings.fromJson(bare.toJson()), bare);
    });

    test('VaultBackupSettings fromJson takes defaults for missing keys', () {
      final s = VaultBackupSettings.fromJson(<String, Object?>{});
      expect(s.enabled, isFalse);
      expect(s.destination, isNull);
      expect(s.keep, 30);
      expect(s.automatic, isTrue);
      expect(
        VaultBackupSettings.fromJson(<String, Object?>{'keep': 7}).keep,
        7,
      );
    });

    test('VaultBackupSettings fromJson rejects wrong types and bad keep', () {
      final bad = <Map<String, Object?>>[
        {'enabled': 1},
        {'destination': 5},
        {'keep': 'x'},
        {'keep': 0},
        {'keep': 366},
        {'automatic': 'yes'},
      ];
      for (final json in bad) {
        expect(
          () => VaultBackupSettings.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: '$json',
        );
      }
    });

    test('VaultBackupSettings equals and hashCode distinguish every field', () {
      _expectValueSemantics(_settings(), _settings(), [
        _settings(enabled: false),
        _settings(destination: '/other'),
        _settings(destination: null),
        _settings(keep: 46),
        _settings(automatic: true),
      ]);
    });

    test('VaultBackupSettings copyWith replaces only the given fields', () {
      final s = _settings();
      expect(s.copyWith(), s);
      expect(s.copyWith(enabled: false), _settings(enabled: false));
      expect(s.copyWith(destination: '/d'), _settings(destination: '/d'));
      expect(s.copyWith(keep: 7), _settings(keep: 7));
      expect(s.copyWith(automatic: true), _settings(automatic: true));
    });
  });

  test('backup keep limits are 1 365 and 30', () {
    expect((backupKeepMin, backupKeepMax, backupKeepDefault), (1, 365, 30));
  });

  test('BackupProvider wire ids are icloud google_drive and onedrive', () {
    expect(BackupProvider.values, [
      BackupProvider.icloud,
      BackupProvider.googleDrive,
      BackupProvider.oneDrive,
    ]);
    expect(BackupProvider.icloud.wireId, 'icloud');
    expect(BackupProvider.googleDrive.wireId, 'google_drive');
    expect(BackupProvider.oneDrive.wireId, 'onedrive');
  });

  test(
    'BackupDestinationOption equals and hashCode distinguish every field',
    () {
      BackupDestinationOption option({
        BackupProvider? provider = BackupProvider.googleDrive,
        String label = 'me@example.com',
        String? path = '/g/My Drive/Open Memex Backups',
      }) =>
          BackupDestinationOption(provider: provider, label: label, path: path);
      _expectValueSemantics(option(), option(), [
        option(provider: BackupProvider.oneDrive),
        option(provider: null),
        option(label: 'you@example.com'),
        option(path: '/elsewhere'),
        option(path: null),
      ]);
    },
  );

  group('BackupStatus', () {
    test('BackupStatus reads a backup-state entry and writes it back', () {
      final s = BackupStatus.fromStateJson(_createdStateJson());
      expect(s, _created());
      expect(s.lastAttemptAt!.isUtc, isTrue);
      expect(s.lastFileCreatedAt, _t1);
      expect(s.enabled, isNull);
      expect(s.keep, isNull);
      expect(s.inProgress, isFalse);
      expect(s.toStateJson(), _createdStateJson());
      final failed = _failedAfterSuccess();
      expect(BackupStatus.fromStateJson(failed.toStateJson()), failed);
      expect(failed.toStateJson()['last_success_at'], _t0Ms);
    });

    test('BackupStatus reads an all-null state entry', () {
      final nulls = <String, Object?>{
        'last_attempt_at': _t1Ms,
        'last_success_at': null,
        'last_result': 'backup_failed',
        'last_error': 'boom',
        'last_file': null,
        'last_file_created_at': null,
        'last_bytes': null,
        'last_fingerprint': null,
      };
      final s = BackupStatus.fromStateJson(nulls);
      expect(s.lastAttemptAt, _t1);
      expect(s.lastSuccessAt, isNull);
      expect(s.lastResult, 'backup_failed');
      expect(s.lastFile, isNull);
      expect(s.toStateJson(), nulls);
      expect(
        BackupStatus.fromStateJson(<String, Object?>{}).lastResult,
        isNull,
      );
    });

    test('BackupStatus fromStateJson rejects wrong-typed values', () {
      final bad = <Map<String, Object?>>[
        {'last_attempt_at': 'x'},
        {'last_success_at': 1.5},
        {'last_result': 3},
        {'last_error': 3},
        {'last_file': 3},
        {'last_file_created_at': 'x'},
        {'last_bytes': 'x'},
        {'last_fingerprint': 3},
      ];
      for (final json in bad) {
        expect(
          () => BackupStatus.fromStateJson(json),
          throwsA(isA<FormatException>()),
          reason: '$json',
        );
      }
    });

    test('BackupStatus reads and writes the hosted GET body', () {
      final s = BackupStatus.fromHostedJson(_hostedJson());
      expect(s.enabled, isTrue);
      expect(s.keep, 30);
      expect(s.inProgress, isTrue);
      expect(s.lastAttemptAt, _t1);
      expect(s.lastSuccessAt, _t0);
      expect(s.lastResult, 'backup_failed');
      expect(s.lastError, 'disk full');
      expect(s.lastFileCreatedAt, _t0);
      expect(s.lastBytes, 135000000);
      expect(s.lastFingerprint, isNull);
      expect(s.toHostedJson(), _hostedJson());
      expect(BackupStatus.fromHostedJson(s.toHostedJson()), s);
    });

    test('BackupStatus hosted body defaults and wrong types', () {
      final off = BackupStatus.fromHostedJson(<String, Object?>{
        'enabled': false,
        'keep': null,
        'in_progress': false,
      });
      expect(off.enabled, isFalse);
      expect(off.keep, isNull);
      expect(off.inProgress, isFalse);
      expect(
        BackupStatus.fromHostedJson(<String, Object?>{}).inProgress,
        isFalse,
      );
      expect(
        const BackupStatus().toHostedJson()['enabled'],
        isFalse,
        reason: 'a null enabled is written false',
      );
      for (final json in <Map<String, Object?>>[
        {'in_progress': 1},
        {'enabled': 'yes'},
        {'keep': 'x'},
        {'last_bytes': 'x'},
      ]) {
        expect(
          () => BackupStatus.fromHostedJson(json),
          throwsA(isA<FormatException>()),
          reason: '$json',
        );
      }
    });

    test('BackupStatus lastAttemptFailed is true only for an error code', () {
      BackupStatus withResult(String? r) => BackupStatus(lastResult: r);
      expect(withResult('created').lastAttemptFailed, isFalse);
      expect(withResult('unchanged').lastAttemptFailed, isFalse);
      expect(withResult(null).lastAttemptFailed, isFalse);
      expect(withResult('backup_failed').lastAttemptFailed, isTrue);
      expect(withResult('network_filesystem').lastAttemptFailed, isTrue);
    });

    test('BackupStatus hasBackup is true once a file was written', () {
      expect(const BackupStatus().hasBackup, isFalse);
      expect(
        BackupStatus(lastResult: 'unchanged', lastSuccessAt: _t1).hasBackup,
        isFalse,
      );
      expect(BackupStatus(lastFile: 'x.memex.zip').hasBackup, isTrue);
    });

    test('BackupStatus equals and hashCode distinguish every field', () {
      BackupStatus status({
        DateTime? lastAttemptAt,
        DateTime? lastSuccessAt,
        String? lastResult = 'created',
        String? lastError,
        String? lastFile = 'a.memex.zip',
        DateTime? lastFileCreatedAt,
        int? lastBytes = 10,
        String? lastFingerprint = 'f',
        bool? enabled = true,
        int? keep = 30,
        bool inProgress = false,
      }) => BackupStatus(
        lastAttemptAt: lastAttemptAt ?? _t1,
        lastSuccessAt: lastSuccessAt ?? _t1,
        lastResult: lastResult,
        lastError: lastError,
        lastFile: lastFile,
        lastFileCreatedAt: lastFileCreatedAt ?? _t1,
        lastBytes: lastBytes,
        lastFingerprint: lastFingerprint,
        enabled: enabled,
        keep: keep,
        inProgress: inProgress,
      );
      _expectValueSemantics(status(), status(), [
        status(lastAttemptAt: _t0),
        status(lastSuccessAt: _t0),
        status(lastResult: 'unchanged'),
        status(lastError: 'e'),
        status(lastFile: 'b.memex.zip'),
        status(lastFileCreatedAt: _t0),
        status(lastBytes: 11),
        status(lastFingerprint: 'g'),
        status(enabled: false),
        status(keep: 31),
        status(inProgress: true),
      ]);
    });
  });

  group('run results', () {
    test('BackupRunResult variants compare by value on every field', () {
      BackupCreated created({
        String file = '/d/a.memex.zip',
        int bytes = 5,
        String fingerprint = 'f',
        List<String> removed = const ['/d/old.memex.zip', '/d/older.memex.zip'],
      }) => BackupCreated(
        file: file,
        bytes: bytes,
        fingerprint: fingerprint,
        removed: [...removed],
      );
      _expectValueSemantics(created(), created(), [
        created(file: '/d/b.memex.zip'),
        created(bytes: 6),
        created(fingerprint: 'g'),
        created(removed: ['/d/old.memex.zip']),
        created(removed: ['/d/older.memex.zip', '/d/old.memex.zip']),
      ]);
      _expectValueSemantics(
        BackupUnchanged(lastFile: '/d/a.memex.zip'),
        BackupUnchanged(lastFile: '/d/a.memex.zip'),
        [BackupUnchanged(lastFile: '/d/b.memex.zip'), BackupUnchanged()],
      );
      _expectValueSemantics(
        BackupFailure(code: 'backup_failed', message: 'm'),
        BackupFailure(code: 'backup_failed', message: 'm'),
        [
          BackupFailure(code: 'internal', message: 'm'),
          BackupFailure(code: 'backup_failed', message: 'n'),
        ],
      );
      expect(BackupTooOld(), BackupTooOld());
      expect(BackupBinaryNotFound(), BackupBinaryNotFound());
      final all = <BackupRunResult>[
        created(),
        BackupUnchanged(),
        BackupFailure(code: 'c', message: 'm'),
        BackupTooOld(),
        BackupBinaryNotFound(),
      ];
      for (var i = 0; i < all.length; i++) {
        for (var j = 0; j < all.length; j++) {
          expect(all[i] == all[j], i == j, reason: '$i vs $j');
        }
      }
    });

    test('RestoreRunResult variants compare by value on every field', () {
      RestoreOk ok({
        String vaultId = '01HV0000000000000000000000',
        String path = '/p/Notes',
        DateTime? createdAt,
      }) =>
          RestoreOk(vaultId: vaultId, path: path, createdAt: createdAt ?? _t1);
      _expectValueSemantics(ok(), ok(), [
        ok(vaultId: '01HV0000000000000000000001'),
        ok(path: '/p/Other'),
        ok(createdAt: _t0),
      ]);
      RestoreFailure failure({
        String code = 'backup_too_new',
        String message = 'm',
        Map<String, Object?> fields = const {
          'schema_version': 9,
          'supported_schema_version': 6,
        },
      }) => RestoreFailure(code: code, message: message, fields: {...fields});
      _expectValueSemantics(failure(), failure(), [
        failure(code: 'backup_invalid'),
        failure(message: 'n'),
        failure(fields: {'schema_version': 9}),
        failure(fields: {'schema_version': 9, 'supported_schema_version': 7}),
        failure(fields: {}),
      ]);
      expect(RestoreTooOld(), RestoreTooOld());
      expect(RestoreBinaryNotFound(), RestoreBinaryNotFound());
      final all = <RestoreRunResult>[
        ok(),
        failure(),
        RestoreTooOld(),
        RestoreBinaryNotFound(),
      ];
      for (var i = 0; i < all.length; i++) {
        for (var j = 0; j < all.length; j++) {
          expect(all[i] == all[j], i == j, reason: '$i vs $j');
        }
      }
    });
  });

  group('BackupViewState', () {
    test('BackupViewState has a value for each Backups sheet state', () {
      expect(
        [for (final m in BackupSheetMode.values) m.name],
        [
          'off',
          'pickingDestination',
          'neverBackedUp',
          'backingUp',
          'success',
          'error',
          'memexTooOld',
          'binaryNotFound',
          'hostedNotConfigured',
          'hostedUnreachable',
          'hostedServerTooOld',
        ],
      );
      // The Spec's list: off; picking a destination; on and never backed up;
      // backing up; success; error with Retry; memex too old; binary not
      // found; hosted backing up / not configured / unreachable / server too
      // old; and the entry's warning on or off.
      final states = <BackupViewState>[
        BackupViewState(mode: BackupSheetMode.off, settings: _settings()),
        BackupViewState(
          mode: BackupSheetMode.pickingDestination,
          options: [BackupDestinationOption(label: 'choose folder')],
        ),
        BackupViewState(mode: BackupSheetMode.neverBackedUp),
        BackupViewState(mode: BackupSheetMode.backingUp),
        BackupViewState(mode: BackupSheetMode.success, status: _created()),
        BackupViewState(
          mode: BackupSheetMode.error,
          errorCode: 'backup_failed',
          message: 'm',
          warning: true,
        ),
        BackupViewState(mode: BackupSheetMode.memexTooOld),
        BackupViewState(mode: BackupSheetMode.binaryNotFound),
        BackupViewState(mode: BackupSheetMode.backingUp, hosted: true),
        BackupViewState(
          mode: BackupSheetMode.hostedNotConfigured,
          hosted: true,
        ),
        BackupViewState(mode: BackupSheetMode.hostedUnreachable, hosted: true),
        BackupViewState(mode: BackupSheetMode.hostedServerTooOld, hosted: true),
      ];
      for (var i = 0; i < states.length; i++) {
        for (var j = 0; j < states.length; j++) {
          expect(states[i] == states[j], i == j, reason: '$i vs $j');
        }
      }
      expect(
        states.first,
        BackupViewState(mode: BackupSheetMode.off, settings: _settings()),
      );
      expect(
        BackupViewState(mode: BackupSheetMode.success, warning: true),
        isNot(BackupViewState(mode: BackupSheetMode.success)),
      );
    });

    test('BackupViewState equals and hashCode distinguish every field', () {
      BackupViewState view({
        BackupSheetMode mode = BackupSheetMode.error,
        bool hosted = false,
        VaultBackupSettings? settings,
        BackupStatus? status,
        String? errorCode = 'backup_failed',
        String? message = 'm',
        List<BackupDestinationOption> options = const [],
        bool warning = false,
      }) => BackupViewState(
        mode: mode,
        hosted: hosted,
        settings: settings ?? _settings(),
        status: status ?? _created(),
        errorCode: errorCode,
        message: message,
        options: [...options],
        warning: warning,
      );
      final option = BackupDestinationOption(label: 'choose folder');
      _expectValueSemantics(view(options: [option]), view(options: [option]), [
        view(options: [option], mode: BackupSheetMode.success),
        view(options: [option], hosted: true),
        view(options: [option], settings: _settings(keep: 46)),
        view(options: [option], status: _failedAfterSuccess()),
        view(options: [option], errorCode: 'internal'),
        view(options: [option], message: 'n'),
        view(),
        view(options: [option], warning: true),
      ]);
    });
  });

  // ------------------------------------------------------------------
  // 2-3. Keys
  // ------------------------------------------------------------------
  group('backup keys', () {
    final frozen = <String, (String, Key)>{
      'backupsEntryKey': ('backups-entry', backupsEntryKey),
      'backupsEntryWarningKey': (
        'backups-entry-warning',
        backupsEntryWarningKey,
      ),
      'backupsSheetKey': ('backups-sheet', backupsSheetKey),
      'backupsToggleKey': ('backups-toggle', backupsToggleKey),
      'backupsAutomaticKey': ('backups-automatic', backupsAutomaticKey),
      'backupsKeepKey': ('backups-keep', backupsKeepKey),
      'backupsDestinationChooseKey': (
        'backups-destination-choose',
        backupsDestinationChooseKey,
      ),
      'backupsNowKey': ('backups-now', backupsNowKey),
      'backupsRetryKey': ('backups-retry', backupsRetryKey),
      'vaultPickerRestoreKey': ('vault-picker-restore', vaultPickerRestoreKey),
      'restoreFolderKey': ('restore-folder', restoreFolderKey),
      'restoreSubmitKey': ('restore-submit', restoreSubmitKey),
      'backupsStatusKey': ('backups-status', backupsStatusKey),
      'restoreDialogKey': ('restore-dialog', restoreDialogKey),
      'restoreNameKey': ('restore-name', restoreNameKey),
      'restoreErrorKey': ('restore-error', restoreErrorKey),
    };

    test('backup_keys.dart holds exactly the frozen Keys', () {
      final source = File(
        'lib/src/widgets/backups/backup_keys.dart',
      ).readAsStringSync();
      final declared = <String>{
        for (final m in RegExp(
          r'^(?:const|final)\s+(?:\w+(?:<\w+>)?\s+)?(\w+)\s*=',
          multiLine: true,
        ).allMatches(source))
          m.group(1)!,
        for (final m in RegExp(
          r'^Key\s+(\w+)\(',
          multiLine: true,
        ).allMatches(source))
          m.group(1)!,
      };
      expect(declared, {...frozen.keys, 'backupDestinationKey'});
      for (final e in frozen.entries) {
        expect(e.value.$2, Key(e.value.$1), reason: e.key);
      }
    });

    test('backup keys are all distinct', () {
      final values = [for (final e in frozen.values) e.$2];
      expect(values.toSet().length, frozen.length);
      final destinations = <Key>[
        for (final provider in BackupProvider.values)
          for (var i = 0; i < 3; i++) backupDestinationKey(provider, i),
      ];
      expect(destinations.toSet().length, 9);
      expect(destinations.toSet().intersection(values.toSet()), isEmpty);
    });

    test('backupDestinationKey names the provider wire id and the index', () {
      expect(
        backupDestinationKey(BackupProvider.icloud, 0),
        const Key('backups-destination-icloud-0'),
      );
      expect(
        backupDestinationKey(BackupProvider.googleDrive, 1),
        const Key('backups-destination-google_drive-1'),
      );
      expect(
        backupDestinationKey(BackupProvider.oneDrive, 2),
        const Key('backups-destination-onedrive-2'),
      );
    });
  });

  // ------------------------------------------------------------------
  // 4. Stub files: each exists with its declared provider or class and its
  // neutral value. The filler named in each group replaces the stub and
  // deletes that group (a TEST-CHANGE in its PR).
  // ------------------------------------------------------------------
  group('stubs filled by A1 (#322)', () {
    test('CliBackupRunner stub has no result to give until A1 fills it', () {
      const runner = CliBackupRunner(null);
      expect(
        () => runner.backup(
          vaultPath: '/v',
          destination: '/d',
          keep: 30,
          ifChanged: true,
        ),
        throwsA(isA<UnimplementedError>()),
      );
      expect(
        () => runner.restore(from: '/f.memex.zip', to: '/t'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('backupRunnerProvider declares a CliBackupRunner stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(backupRunnerProvider), isA<CliBackupRunner>());
    });

    test('FileBackupStateReader stub reads null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final reader = container.read(backupStateReaderProvider);
      expect(reader, isA<FileBackupStateReader>());
      expect(await reader.read(vaultPath: '/v', destination: '/d'), isNull);
    });

    test('backup messages stubs return their neutral values', () {
      final at = DateTime.utc(2026, 11, 9, 9);
      expect(
        backupFailureMessage(
          code: 'backup_failed',
          message: 'm',
          automatic: true,
          failedAt: at,
          now: at,
        ),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        backupTooOldMessage(),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        backupBinaryNotFoundMessage(),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        restoreFailureMessage(
          RestoreFailure(code: 'backup_invalid', message: 'm'),
          name: 'Notes',
          parent: '/p',
        ),
        '',
      );
      expect(backupWhen(at, at), '');
      expect(backupSize(1), '');
    });

    test('backup names stubs return their neutral values', () {
      expect(
        parseBackupFileName(
          'Notes-20261109T090000Z-01HV0000000000000000000000.memex.zip',
        ),
        isNull,
      );
      expect(suggestedRestoreName('Notes.memex.zip'), '');
    });

    test('hostedBackupApiProvider declares a null stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(hostedBackupApiProvider), isNull);
    });
  });

  group('stubs filled by A2 (#323)', () {
    test(
      'IoCloudFolderProbe stub returns neutral values and touches nothing',
      () async {
        const probe = IoCloudFolderProbe();
        expect(await probe.home(), '');
        expect(await probe.isDirectory('/'), isFalse);
        expect(await probe.listNames('/'), isEmpty);
        await probe.createDirectory('/no-such-parent/never-created');
        expect(Directory('/no-such-parent').existsSync(), isFalse);
        expect(await probe.resolveSymbolicLinks('/'), '');
      },
    );

    test('cloudFolderProbeProvider declares an IoCloudFolderProbe stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(cloudFolderProbeProvider),
        isA<IoCloudFolderProbe>(),
      );
    });

    test('discoverBackupDestinations stub lists nothing', () async {
      final probe = FakeCloudFolderProbe()..seedIcloud();
      expect(await discoverBackupDestinations(probe), isEmpty);
    });

    test(
      'vault backup settings stubs read the defaults and save nothing',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final before = container.read(
          vaultBackupSettingsProvider('/some vault'),
        );
        expect(before.enabled, isFalse);
        expect(before.destination, isNull);
        await container.read(saveVaultBackupSettingsProvider)(
          '/some vault',
          _settings(),
        );
        final after = container.read(
          vaultBackupSettingsProvider('/some vault'),
        );
        expect(after.enabled, isFalse);
        expect(after.destination, isNull);
      },
    );
  });

  group('stubs filled by A3 (#324)', () {
    test('LiveBackupController stub reads off and starts nothing', () async {
      final h = await createBackupContainer();
      final controller = h.read(backupControllerProvider.notifier);
      expect(controller, isA<LiveBackupController>());
      const local = LocalVaultRef('/v');
      const hosted = HostedVaultRef('s1', 'seed');
      expect(controller.viewStateOf(local).mode, BackupSheetMode.off);
      await controller.backUpNow(local);
      await controller.backUpNow(hosted);
      controller.openSheet(local);
      controller.closeSheet(local);
      expect(h.runner.calls, isEmpty);
      expect(h.hostedApi.calls, isEmpty);
      expect(h.read(backupInFlightProvider), isEmpty);
      expect(h.read(backupControllerProvider), isEmpty);
    });
  });

  // ------------------------------------------------------------------
  // 5. Harness and fakes
  // ------------------------------------------------------------------
  group('backup harness', () {
    testWidgets(
      'pumpBackupWidget pumps a widget with every override in place',
      (tester) async {
        late WidgetRef captured;
        final h = await pumpBackupWidget(
          tester,
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const Text('pumped');
            },
          ),
          vault: const LocalVaultRef('/a vault'),
        );
        expect(find.text('pumped'), findsOneWidget);
        expect(identical(captured.read(clockProvider), h.clock), isTrue);
        expect(identical(captured.read(memexCliProvider), h.cli), isTrue);
        expect(
          identical(captured.read(backupRunnerProvider), h.runner),
          isTrue,
        );
        expect(
          identical(captured.read(backupStateReaderProvider), h.reader),
          isTrue,
        );
        expect(
          identical(captured.read(hostedBackupApiProvider), h.hostedApi),
          isTrue,
        );
        expect(
          identical(captured.read(cloudFolderProbeProvider), h.probe),
          isTrue,
        );
        expect(h.controller, isA<FakeBackupController>());
        expect(
          identical(
            captured.read(backupControllerProvider.notifier),
            h.controller,
          ),
          isTrue,
        );
        expect(
          captured.read(currentVaultProvider),
          const LocalVaultRef('/a vault'),
        );
        expect(captured.read(settingsProvider).memexBinaryPath, 'fake-memex');
      },
    );

    testWidgets('pumpBackupWidget runs on the FakeClock with no real timers', (
      tester,
    ) async {
      final fired = <String>[];
      final h = await pumpBackupWidget(
        tester,
        Consumer(
          builder: (context, ref, _) {
            final clock = ref.read(clockProvider);
            clock.after(const Duration(hours: 1), () => fired.add('after'));
            clock.periodic(
              const Duration(minutes: 30),
              (_) => fired.add('tick'),
            );
            return const SizedBox();
          },
        ),
        clock: FakeClock(DateTime(2026, 11, 9, 9)),
      );
      expect(h.clock.pendingTimers, 2);
      await tester.pump(const Duration(hours: 5));
      expect(fired, isEmpty, reason: 'real time never moves the FakeClock');
      h.clock.advance(const Duration(minutes: 30));
      expect(fired, ['tick']);
      h.clock.advance(const Duration(minutes: 30));
      expect(fired, hasLength(3));
      expect(fired.sublist(1), unorderedEquals(['tick', 'after']));
      h.clock.advance(const Duration(hours: 2));
      expect(fired.where((f) => f == 'after'), hasLength(1));
      // The test ends with no pending real Timer, or flutter_test fails it.
    });

    test(
      'createBackupContainer exposes every seam to a non-widget test',
      () async {
        final h = await createBackupContainer(
          vault: const HostedVaultRef('s1', 'seed'),
        );
        expect(identical(h.read(clockProvider), h.clock), isTrue);
        expect(identical(h.read(memexCliProvider), h.cli), isTrue);
        expect(identical(h.read(backupRunnerProvider), h.runner), isTrue);
        expect(identical(h.read(backupStateReaderProvider), h.reader), isTrue);
        expect(identical(h.read(hostedBackupApiProvider), h.hostedApi), isTrue);
        expect(identical(h.read(cloudFolderProbeProvider), h.probe), isTrue);
        expect(
          h.read(currentVaultProvider),
          const HostedVaultRef('s1', 'seed'),
        );
        expect(h.cli, isA<MemexCli>());
        expect(h.cli.calls, isEmpty);
      },
    );

    test('createBackupContainer runs the live controller by default', () async {
      final live = await createBackupContainer();
      expect(live.controller, isNull);
      expect(
        live.read(backupControllerProvider.notifier),
        isA<LiveBackupController>(),
      );
      final fake = FakeBackupController();
      final faked = await createBackupContainer(controller: fake);
      expect(identical(faked.controller, fake), isTrue);
      expect(
        identical(faked.read(backupControllerProvider.notifier), fake),
        isTrue,
      );
    });

    test('backup harness seeds the mock SharedPreferences', () async {
      await createBackupContainer(prefs: {'memex.vault_backups': '{}'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('memex.binary_path'), 'fake-memex');
      expect(prefs.getString('memex.vault_backups'), '{}');
    });
  });

  group('FakeBackupRunner', () {
    test('FakeBackupRunner records each call args in order', () async {
      final runner = FakeBackupRunner();
      await runner.backup(
        vaultPath: '/My Vaults/notes',
        destination: '/Users/t/Library/Mobile Documents/x~y/Open Memex Backups',
        keep: 45,
        ifChanged: true,
      );
      await runner.restore(from: '/b/Notes.memex.zip', to: '/p/Notes copy');
      await runner.backup(
        vaultPath: '/My Vaults/notes',
        destination: '/d',
        keep: 30,
        ifChanged: false,
      );
      expect(runner.calls, hasLength(3));
      expect(runner.calls[0].toString(), runner.backupCalls[0].toString());
      expect(runner.calls[1], isA<FakeRestoreCall>());
      expect(runner.calls[2], isA<FakeBackupCall>());
      expect(runner.backupCalls, hasLength(2));
      final first = runner.backupCalls[0];
      expect(first.vaultPath, '/My Vaults/notes');
      expect(
        first.destination,
        '/Users/t/Library/Mobile Documents/x~y/Open Memex Backups',
      );
      expect(first.keep, 45);
      expect(first.ifChanged, isTrue);
      final second = runner.backupCalls[1];
      expect(
        (second.destination, second.keep, second.ifChanged),
        ('/d', 30, false),
      );
      expect(runner.restoreCalls.single.from, '/b/Notes.memex.zip');
      expect(runner.restoreCalls.single.to, '/p/Notes copy');
    });

    test(
      'FakeBackupRunner answers scripted results then the default',
      () async {
        const tooOld = BackupTooOld();
        const notFound = BackupBinaryNotFound();
        const failure = BackupFailure(code: 'backup_failed', message: 'm');
        const restoreTooOld = RestoreTooOld();
        const restoreNotFound = RestoreBinaryNotFound();
        final runner = FakeBackupRunner()
          ..scriptBackup(tooOld)
          ..scriptBackup(notFound)
          ..scriptBackup(failure)
          ..scriptRestore(restoreTooOld)
          ..scriptRestore(restoreNotFound);
        Future<BackupRunResult> run() => runner.backup(
          vaultPath: '/v',
          destination: '/d',
          keep: 30,
          ifChanged: false,
        );
        expect(await run(), same(tooOld));
        expect(await run(), same(notFound));
        expect(await run(), same(failure));
        expect(await run(), same(runner.defaultBackupResult));
        expect(await run(), isA<BackupCreated>());
        expect(await runner.restore(from: '/f', to: '/t'), same(restoreTooOld));
        expect(
          await runner.restore(from: '/f', to: '/t'),
          same(restoreNotFound),
        );
        final ok = await runner.restore(from: '/f', to: '/t');
        expect(ok, isA<RestoreOk>());
        expect((ok as RestoreOk).path, '/t');
      },
    );

    test(
      'FakeBackupRunner holds a run open until the completer completes',
      () async {
        final runner = FakeBackupRunner();
        final hold = runner.holdRuns();
        var done = false;
        final run = runner
            .backup(
              vaultPath: '/v',
              destination: '/d',
              keep: 30,
              ifChanged: false,
            )
            .then((r) {
              done = true;
              return r;
            });
        await Future<void>.delayed(Duration.zero);
        expect(runner.calls, hasLength(1), reason: 'recorded at once');
        expect(runner.inFlight, 1);
        expect(done, isFalse);
        hold.complete();
        await run;
        expect(done, isTrue);
        expect(runner.inFlight, 0);
      },
    );

    test('FakeBackupRunner onCall runs before the call answers', () async {
      final runner = FakeBackupRunner();
      final seen = <String>[];
      runner.onCall = (call) => seen.add('call ${runner.calls.length}');
      await runner.backup(
        vaultPath: '/v',
        destination: '/d',
        keep: 30,
        ifChanged: true,
      );
      expect(seen, ['call 1']);
    });
  });

  group('FakeBackupStateReader', () {
    test(
      'FakeBackupStateReader finds an entry by the exact destination',
      () async {
        final entry = _created();
        final reader = FakeBackupStateReader()
          ..setEntry('/v', '/dest/Open Memex Backups', entry);
        expect(
          await reader.read(
            vaultPath: '/v',
            destination: '/dest/Open Memex Backups',
          ),
          same(entry),
        );
        expect(
          await reader.read(
            vaultPath: '/v',
            destination: '/dest/Open Memex Backups/',
          ),
          isNull,
        );
        expect(
          await reader.read(
            vaultPath: '/other',
            destination: '/dest/Open Memex Backups',
          ),
          isNull,
        );
        expect(reader.reads, hasLength(3));
        expect(reader.reads.first.vaultPath, '/v');
        reader.clearEntry('/v', '/dest/Open Memex Backups');
        expect(
          await reader.read(
            vaultPath: '/v',
            destination: '/dest/Open Memex Backups',
          ),
          isNull,
        );
      },
    );
  });

  group('FakeHostedBackupApi', () {
    test('FakeHostedBackupApi can throw VaultUnreachableException', () async {
      final api = FakeHostedBackupApi()
        ..goUnreachable(serverName: 'nas', mayHaveCommitted: true);
      for (final call in [api.status, api.start]) {
        await expectLater(
          call(),
          throwsA(
            isA<VaultUnreachableException>()
                .having((e) => e.serverName, 'serverName', 'nas')
                .having((e) => e.mayHaveCommitted, 'mayHaveCommitted', isTrue),
          ),
        );
      }
      expect(api.calls, ['status', 'start']);
      api.comeBack();
      expect(await api.status(), isA<HostedBackupOk>());
      expect((api.statusCalls, api.startCalls), (2, 1));
    });

    test('FakeHostedBackupApi answers scripted 404 and 409 outcomes', () async {
      final api = FakeHostedBackupApi()
        ..scriptStatus(const HostedBackupServerTooOld())
        ..scriptStart(const HostedBackupAlreadyRunning())
        ..scriptStart(const HostedBackupNotConfigured())
        ..scriptStatus(MemexException('x', code: 'vault_not_found'));
      expect(await api.status(), isA<HostedBackupServerTooOld>());
      expect(await api.start(), isA<HostedBackupAlreadyRunning>());
      expect(await api.start(), isA<HostedBackupNotConfigured>());
      await expectLater(
        api.status(),
        throwsA(
          isA<MemexException>().having(
            (e) => e.code,
            'code',
            'vault_not_found',
          ),
        ),
      );
      final started = await api.start();
      expect((started as HostedBackupOk).status.inProgress, isTrue);
      final read = await api.status();
      expect((read as HostedBackupOk).status.inProgress, isFalse);
    });

    test('FakeHostedBackupApi holds start open until released', () async {
      final api = FakeHostedBackupApi();
      final hold = api.holdStart();
      var done = false;
      final run = api.start().then((r) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(api.startCalls, 1);
      expect(done, isFalse);
      hold.complete();
      await run;
      expect(done, isTrue);
    });
  });

  group('FakeCloudFolderProbe', () {
    test(
      'FakeCloudFolderProbe serves a fake home with no access to the real Library',
      () async {
        final probe = FakeCloudFolderProbe()
          ..seedIcloud()
          ..seedGoogleDrive('me@example.com')
          ..seedGoogleDrive('you@example.com')
          ..seedOneDrive('Work');
        final realHome = Platform.environment['HOME'];
        expect(await probe.home(), fakeHome);
        expect(await probe.home(), isNot(realHome));
        expect(await probe.isDirectory(probe.icloudFolder), isTrue);
        expect(
          probe.icloudFolder,
          '$fakeHome/Library/Mobile Documents/com~apple~CloudDocs',
        );
        expect(await probe.listNames('$fakeHome/Library/CloudStorage'), [
          'GoogleDrive-me@example.com',
          'GoogleDrive-you@example.com',
          'OneDrive-Work',
        ], reason: 'insertion order: a caller must sort');
        expect(
          await probe.isDirectory(probe.googleDriveFolder('me@example.com')),
          isTrue,
        );
        expect(await probe.isDirectory(probe.oneDriveFolder('Home')), isFalse);
        if (realHome != null) {
          expect(await probe.isDirectory('$realHome/Library'), isFalse);
          await expectLater(
            probe.listNames('$realHome/Library/CloudStorage'),
            throwsA(isA<FileSystemException>()),
          );
        }
      },
    );

    test('FakeCloudFolderProbe reproduces file system failures', () async {
      final probe = FakeCloudFolderProbe()
        ..addFile('/Users/tester/afile')
        ..denyCreate('/Volumes/locked');
      await expectLater(
        probe.listNames('/nowhere'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'errno',
            2,
          ),
        ),
      );
      await expectLater(
        probe.listNames('/Users/tester/afile'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        probe.resolveSymbolicLinks('/nowhere/at/all'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        probe.createDirectory('/Volumes/locked/Open Memex Backups'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'errno',
            1,
          ),
        ),
      );
      await expectLater(
        probe.createDirectory('/Users/tester/afile/sub'),
        throwsA(isA<FileSystemException>()),
      );
      expect(probe.createdDirectories, isEmpty);
    });

    test(
      'FakeCloudFolderProbe createDirectory makes parents and is idempotent',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/private/real/Drive')
          ..addSymlink('/Users/tester/Drive link', '/private/real/Drive');
        expect(
          await probe.resolveSymbolicLinks('/Users/tester/Drive link'),
          '/private/real/Drive',
        );
        await probe.createDirectory(
          '/Users/tester/Drive link/Open Memex Backups',
        );
        expect(
          await probe.resolveSymbolicLinks(
            '/Users/tester/Drive link/Open Memex Backups',
          ),
          '/private/real/Drive/Open Memex Backups',
        );
        await probe.createDirectory(
          '/Users/tester/Drive link/Open Memex Backups',
        );
        expect(await probe.listNames('/private/real/Drive'), [
          'Open Memex Backups',
        ]);
        expect(
          await probe.isDirectory(
            '/Users/tester/Drive link/Open Memex Backups',
          ),
          isTrue,
        );
        await probe.createDirectory('/a/b/c');
        expect(await probe.isDirectory('/a/b'), isTrue);
        expect(probe.createdDirectories, hasLength(3));
        expect(probe.calls.first, startsWith('resolveSymbolicLinks'));
      },
    );
  });

  group('FakeBackupController', () {
    testWidgets(
      'FakeBackupController records calls and shows the view state a test sets',
      (tester) async {
        const vault = LocalVaultRef('/v');
        final h = await pumpBackupWidget(
          tester,
          Consumer(
            builder: (context, ref, _) {
              final controller = ref.watch(backupControllerProvider.notifier);
              ref.watch(backupControllerProvider);
              return Text('mode ${controller.viewStateOf(vault).mode.name}');
            },
          ),
        );
        final fake = h.controller!;
        expect(find.text('mode off'), findsOneWidget);
        fake.setViewState(
          vault,
          const BackupViewState(mode: BackupSheetMode.backingUp),
        );
        await tester.pump();
        expect(find.text('mode backingUp'), findsOneWidget);
        expect(
          fake.viewStateOf(const HostedVaultRef('s', 'seed')).hosted,
          isTrue,
          reason: 'an unseen hosted vault reads as off, hosted',
        );

        final hold = fake.holdBackUpNow();
        var done = false;
        final press = fake.backUpNow(vault).then((_) => done = true);
        fake.openSheet(vault);
        fake.closeSheet(vault);
        await tester.pump();
        expect(fake.backUpNowCalls, [vault]);
        expect(fake.openSheetCalls, [vault]);
        expect(fake.closeSheetCalls, [vault]);
        expect(done, isFalse);
        hold.complete();
        await press;
        expect(done, isTrue);
      },
    );
  });
}
