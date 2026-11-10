// WI #322 (A1, req 10a): `FileBackupStateReader` reads
// `<vault>/backup-state.json` read-only. A missing file, malformed JSON,
// `format` other than 1 or an entry it cannot read gives no history (null,
// never a throw); a destination is found by its exact string. Every case of
// the shared `backup_state.json` fixture (R0 owns it) is covered.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';

const _fixturePath = 'test/fixtures/backup/backup_state.json';

const _google =
    '/Users/person/Library/CloudStorage/GoogleDrive-person@example.com/'
    'My Drive/Open Memex Backups';
const _onedrive =
    '/Users/person/Library/CloudStorage/OneDrive-Personal/Open Memex Backups';
const _icloud =
    '/Users/person/Library/Mobile Documents/com~apple~CloudDocs/'
    'Open Memex Backups';
const _nas = '/Volumes/backups/memex';
const _oldDisk = '/Volumes/old-disk/Open Memex Backups';

DateTime _ms(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// A vault folder with a space in its name, removed at test end.
Directory _vaultDir([String name = 'om322 my vault']) {
  final root = Directory.systemTemp.createTempSync('om322-');
  addTearDown(() {
    // A test may have made the folder read-only.
    if (root.existsSync()) {
      Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
      root.deleteSync(recursive: true);
    }
  });
  return Directory('${root.path}/$name')..createSync();
}

File _stateFile(Directory vault) => File('${vault.path}/backup-state.json');

Directory _vaultWith(String content, [String name = 'om322 my vault']) {
  final vault = _vaultDir(name);
  _stateFile(vault).writeAsStringSync(content);
  return vault;
}

Directory _vaultWithFixture() =>
    _vaultWith(File(_fixturePath).readAsStringSync());

Map<String, Object?> _fixtureJson() =>
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, Object?>;

const _reader = FileBackupStateReader();

Future<BackupStatus?> _read(Directory vault, String destination) =>
    _reader.read(vaultPath: vault.path, destination: destination);

/// A reader that finds the google entry of the fixture: proof that a null
/// elsewhere comes from the case under test and not from a reader that never
/// reads anything.
Future<void> _expectFixtureReads(Directory vault) async {
  expect(await _read(vault, _google), isNotNull);
}

void main() {
  group('entries of backup_state.json', () {
    for (final c in <(String, String, BackupStatus)>[
      (
        'the state reader reads a created entry',
        _google,
        BackupStatus(
          lastAttemptAt: _ms(1794214800000),
          lastSuccessAt: _ms(1794214800000),
          lastResult: 'created',
          lastError: null,
          lastFile:
              'notes-20261109T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip',
          lastFileCreatedAt: _ms(1794214800000),
          lastBytes: 48213,
          lastFingerprint:
              '406effb1e9c59672c66a598c2b21e331b23b16c54024e96d6df3e7c173549791',
        ),
      ),
      (
        'the state reader reads an unchanged entry',
        _onedrive,
        BackupStatus(
          lastAttemptAt: _ms(1794214800000),
          lastSuccessAt: _ms(1794214800000),
          lastResult: 'unchanged',
          lastError: null,
          lastFile:
              'notes-20261108T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip',
          lastFileCreatedAt: _ms(1794128400000),
          lastBytes: 47990,
          lastFingerprint:
              'aaa8d3c8d74ad3e8f6b1772aa9c7e0eaa528cb42fc93599ce2f125b00d4c424c',
        ),
      ),
      (
        'the state reader reads a failure after a success',
        _icloud,
        BackupStatus(
          lastAttemptAt: _ms(1794218400000),
          lastSuccessAt: _ms(1794128400000),
          lastResult: 'backup_failed',
          lastError: 'backup failed: quick_check failed on the snapshot',
          lastFile:
              'notes-20261108T090000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip',
          lastFileCreatedAt: _ms(1794128400000),
          lastBytes: 47990,
          lastFingerprint:
              'e0aa81dd500c530a70b5511fc95959ae1e19dc19a01034e223bfc5ed78e3bdef',
        ),
      ),
      (
        'the state reader reads a failure with no success ever',
        _nas,
        BackupStatus(
          lastAttemptAt: _ms(1794214800000),
          lastSuccessAt: null,
          lastResult: 'backup_destination_unavailable',
          lastError:
              'backup destination unavailable: /Volumes/backups/memex is not '
              'writable',
          lastFile: null,
          lastFileCreatedAt: null,
          lastBytes: null,
          lastFingerprint: null,
        ),
      ),
      (
        'the state reader reads an old destination that is unrelated',
        _oldDisk,
        BackupStatus(
          lastAttemptAt: _ms(1780387200000),
          lastSuccessAt: _ms(1780300800000),
          lastResult: 'backup_destination_unavailable',
          lastError:
              'backup destination unavailable: /Volumes/old-disk/Open Memex '
              'Backups does not exist',
          lastFile:
              'notes-20260601T080000Z-01JCB7Q4M8V2X5N9R3T6W0YZAE.memex.zip',
          lastFileCreatedAt: _ms(1780300800000),
          lastBytes: 30112,
          lastFingerprint:
              '4a85141335ea88e1921d480435429b0f22195e2af33214a94d790ad8e245d192',
        ),
      ),
    ]) {
      test(c.$1, () async {
        final vault = _vaultWithFixture();

        expect(await _read(vault, c.$2), c.$3);
      });
    }

    test('the fixture holds exactly the destinations these cases cover', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final destinations =
          (_fixtureJson()['destinations']! as Map<String, Object?>).keys
              .toSet();
      expect(destinations, {_google, _onedrive, _icloud, _nas, _oldDisk});
    });

    test(
      'a failed attempt reads as failed and a created one does not',
      () async {
        final vault = _vaultWithFixture();

        expect((await _read(vault, _icloud))!.lastAttemptFailed, isTrue);
        expect((await _read(vault, _icloud))!.hasBackup, isTrue);
        expect((await _read(vault, _nas))!.lastAttemptFailed, isTrue);
        expect((await _read(vault, _nas))!.hasBackup, isFalse);
        expect((await _read(vault, _google))!.lastAttemptFailed, isFalse);
        expect((await _read(vault, _onedrive))!.lastAttemptFailed, isFalse);
      },
    );

    test('instants come back as UTC', () async {
      final vault = _vaultWithFixture();

      final status = (await _read(vault, _google))!;

      expect(status.lastAttemptAt!.isUtc, isTrue);
      expect(status.lastFileCreatedAt!.isUtc, isTrue);
    });

    test('a vault folder with spaces tilde and at sign reads', () async {
      final vault = _vaultWith(
        File(_fixturePath).readAsStringSync(),
        'my ~vault@home',
      );

      expect((await _read(vault, _google))!.lastResult, 'created');
    });
  });

  group('no history', () {
    test('a missing file gives no history', () async {
      final withFile = _vaultWithFixture();
      final without = _vaultDir();

      await _expectFixtureReads(withFile);
      expect(await _read(without, _google), isNull);
    });

    test('a vault folder that does not exist gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());

      expect(
        await _reader.read(
          vaultPath: '/tmp/om322 no such vault/${DateTime.now().microsecond}',
          destination: _google,
        ),
        isNull,
      );
    });

    test(
      'malformed JSON gives no history and a repaired file reads again',
      () async {
        final vault = _vaultWith('{"format": 1, "destinations": {');
        final file = _stateFile(vault);

        expect(await _read(vault, _google), isNull);
        file.writeAsStringSync(File(_fixturePath).readAsStringSync());
        expect((await _read(vault, _google))?.lastResult, 'created');
      },
    );

    test('an empty or whitespace file gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());

      for (final content in ['', '  \n']) {
        expect(await _read(_vaultWith(content), _google), isNull);
      }
    });

    test('a file that is not an object gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());

      for (final content in ['[]', '"x"', '42', 'null']) {
        expect(
          await _read(_vaultWith(content), _google),
          isNull,
          reason: content,
        );
      }
    });

    test('format 2 gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final json = _fixtureJson()..['format'] = 2;

      expect(await _read(_vaultWith(jsonEncode(json)), _google), isNull);
    });

    test('a format other than the integer 1 gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());

      for (final format in <Object?>[0, '1', 1.5, null, true, 100]) {
        final json = _fixtureJson()..['format'] = format;
        expect(
          await _read(_vaultWith(jsonEncode(json)), _google),
          isNull,
          reason: 'format: $format',
        );
      }
    });

    test('a file with no format key gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final json = _fixtureJson()..remove('format');

      expect(await _read(_vaultWith(jsonEncode(json)), _google), isNull);
    });

    test('a file with no destinations gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());

      for (final json in <Map<String, Object?>>[
        {'format': 1},
        {'format': 1, 'destinations': <String, Object?>{}},
        {'format': 1, 'destinations': <Object?>[]},
        {'format': 1, 'destinations': 'x'},
        {'format': 1, 'destinations': null},
      ]) {
        expect(
          await _read(_vaultWith(jsonEncode(json)), _google),
          isNull,
          reason: jsonEncode(json),
        );
      }
    });

    test('a different destination string gives no history', () async {
      final vault = _vaultWithFixture();

      await _expectFixtureReads(vault);
      for (final other in [
        '$_google/',
        _google.toLowerCase(),
        _google.replaceFirst('/Users/person', '/Users/person/.'),
        '$_google/sub',
        _google.substring(0, _google.length - 1),
        ' $_google',
        '$_google ',
        '/Users/person/Library/CloudStorage/GoogleDrive-person@example.com/My Drive',
        'Open Memex Backups',
        '',
      ]) {
        expect(await _read(vault, other), isNull, reason: '"$other"');
      }
    });

    test(
      'an entry with a wrong typed value gives no history and never throws',
      () async {
        final json = _fixtureJson();
        final destinations = json['destinations']! as Map<String, Object?>;
        destinations[_nas] = {
          ...(destinations[_nas]! as Map<String, Object?>),
          'last_bytes': 'a lot',
        };
        destinations[_oldDisk] = 'not an entry';
        final vault = _vaultWith(jsonEncode(json));

        await _expectFixtureReads(vault);
        expect(await _read(vault, _nas), isNull);
        expect(await _read(vault, _oldDisk), isNull);
      },
    );

    test('a state file that is a folder gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final vault = _vaultDir();
      Directory('${vault.path}/backup-state.json').createSync();

      expect(await _read(vault, _google), isNull);
    });

    test('a state file that is not UTF-8 gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final vault = _vaultDir();
      _stateFile(vault).writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);

      expect(await _read(vault, _google), isNull);
    });

    test('an unreadable state file gives no history', () async {
      await _expectFixtureReads(_vaultWithFixture());
      final vault = _vaultWithFixture();
      Process.runSync('chmod', ['000', _stateFile(vault).path]);

      expect(await _read(vault, _google), isNull);
    });
  });

  group('read only', () {
    test('reading changes neither the file nor the vault folder', () async {
      final vault = _vaultWithFixture();
      final file = _stateFile(vault);
      final before = file.readAsBytesSync();
      final stat = file.statSync();
      final listing = vault.listSync().map((e) => e.path).toList()..sort();

      expect(await _read(vault, _google), isNotNull);
      expect(await _read(vault, _google), isNotNull);
      expect(await _read(vault, 'no such destination'), isNull);

      expect(file.readAsBytesSync(), before);
      expect(file.statSync().modified, stat.modified);
      expect(vault.listSync().map((e) => e.path).toList()..sort(), listing);
    });

    test('reading creates no file in a vault that has none', () async {
      final withFile = _vaultWithFixture();
      final vault = _vaultDir();

      await _expectFixtureReads(withFile);
      expect(await _read(vault, _google), isNull);

      expect(vault.listSync(), isEmpty);
    });

    test('a read only vault folder and file still read', () async {
      final vault = _vaultWithFixture();
      Process.runSync('chmod', ['444', _stateFile(vault).path]);
      Process.runSync('chmod', ['555', vault.path]);

      expect((await _read(vault, _google))?.lastResult, 'created');
    });

    test('a later write by the CLI shows on the next read', () async {
      final vault = _vaultWithFixture();
      expect(
        (await _read(vault, _nas))!.lastResult,
        'backup_destination_unavailable',
      );

      final json = _fixtureJson();
      final destinations = json['destinations']! as Map<String, Object?>;
      destinations[_nas] = {
        ...(destinations[_nas]! as Map<String, Object?>),
        'last_result': 'created',
        'last_error': null,
      };
      _stateFile(vault).writeAsStringSync(jsonEncode(json));

      expect((await _read(vault, _nas))!.lastResult, 'created');
    });
  });

  group('backupStateReaderProvider', () {
    test('backupStateReaderProvider reads state files from disk', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final vault = _vaultWithFixture();

      final status = await container
          .read(backupStateReaderProvider)
          .read(vaultPath: vault.path, destination: _icloud);

      expect(status?.lastResult, 'backup_failed');
    });
  });
}
