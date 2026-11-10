// WI #322 (A1, D10): the Dart side of the backup file-name grammar, checked
// against every row of the shared `file_names.json` (R0 owns it), plus the
// Restore dialog's name prefill (req 35). The grammar is strict and case
// sensitive, parsed from the right: 26-character vault id, 16-character
// timestamp, 1-64 characters of `[A-Za-z0-9_-]` label, `.memex.zip`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_names.dart';

const _vaultId = '01JCB7Q4M8V2X5N9R3T6W0YZAE';

Map<String, Object?> _fixture() =>
    jsonDecode(File('test/fixtures/backup/file_names.json').readAsStringSync())
        as Map<String, Object?>;

List<Map<String, Object?>> _rows(String key) =>
    (_fixture()[key]! as List).cast<Map<String, Object?>>();

/// `20261109T090000Z` as a UTC instant.
DateTime _stamp(String s) => DateTime.utc(
  int.parse(s.substring(0, 4)),
  int.parse(s.substring(4, 6)),
  int.parse(s.substring(6, 8)),
  int.parse(s.substring(9, 11)),
  int.parse(s.substring(11, 13)),
  int.parse(s.substring(13, 15)),
);

String _name(String label, {String stamp = '20261109T090000Z'}) =>
    '$label-$stamp-$_vaultId.memex.zip';

void main() {
  group('parseBackupFileName', () {
    test(
      'every valid row of file_names.json parses to its label timestamp and id',
      () {
        final rows = _rows('valid');
        expect(rows, isNotEmpty);
        for (final row in rows) {
          final name = row['name']! as String;
          expect(
            parseBackupFileName(name),
            ParsedBackupName(
              label: row['label']! as String,
              timestamp: _stamp(row['timestamp']! as String),
              vaultId: row['vault_id']! as String,
            ),
            reason: name,
          );
        }
      },
    );

    test('the timestamp is a UTC instant', () {
      final parsed = parseBackupFileName(_name('notes'))!;

      expect(parsed.timestamp, DateTime.utc(2026, 11, 9, 9));
      expect(parsed.timestamp.isUtc, isTrue);
      expect(
        parseBackupFileName(
          _name('notes', stamp: '20261007T235959Z'),
        )!.timestamp,
        DateTime.utc(2026, 10, 7, 23, 59, 59),
      );
    });

    test(
      'every look-alike row of file_names.json parses as the fixture says',
      () {
        final rows = _rows('look_alikes');
        expect(rows, isNotEmpty);
        for (final row in rows) {
          final name = row['name']! as String;
          final parses = row['parses'] as Map<String, Object?>?;
          final parsed = parseBackupFileName(name);
          if (parses == null) {
            expect(parsed, isNull, reason: '$name (${row['why']})');
          } else {
            expect(
              parsed,
              ParsedBackupName(
                label: parses['label']! as String,
                timestamp: _stamp(parses['timestamp']! as String),
                vaultId: parses['vault_id']! as String,
              ),
              reason: '$name (${row['why']})',
            );
          }
        }
      },
    );

    test('every partial row of file_names.json is not a backup name', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);

      final rows = _rows('partials');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(
          parseBackupFileName(row['name']! as String),
          isNull,
          reason: row['name']! as String,
        );
      }
    });

    test('every generated file name of file_names.json round trips', () {
      final rows = _rows('file_names');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final name = row['name']! as String;
        final parsed = parseBackupFileName(name);
        expect(parsed, isNotNull, reason: name);
        expect(parsed!.label, row['label'], reason: name);
        expect(parsed.vaultId, row['vault_id'], reason: name);
        expect(
          parsed.timestamp,
          DateTime.fromMillisecondsSinceEpoch(
            (row['at_ms']! as int) ~/ 1000 * 1000,
            isUtc: true,
          ),
          reason: name,
        );
      }
    });

    test('a label of 1 and of 64 characters parses and one of 65 does not', () {
      expect(parseBackupFileName(_name('a'))?.label, 'a');
      expect(parseBackupFileName(_name('a' * 64))?.label, 'a' * 64);
      expect(parseBackupFileName(_name('a' * 65)), isNull);
      expect(parseBackupFileName(_name('')), isNull);
    });

    test('a label may hold underscores digits and dashes and nothing else', () {
      expect(parseBackupFileName(_name('A_b-9'))?.label, 'A_b-9');
      for (final bad in ['a b', 'a.b', 'café', 'a/b', 'a~b', 'a@b']) {
        expect(parseBackupFileName(_name(bad)), isNull, reason: bad);
      }
    });

    test('the extension and the timestamp are case sensitive', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);
      expect(
        parseBackupFileName('notes-20261109T090000Z-$_vaultId.MEMEX.ZIP'),
        isNull,
      );
      expect(
        parseBackupFileName('notes-20261109t090000z-$_vaultId.memex.zip'),
        isNull,
      );
      expect(
        parseBackupFileName('notes-20261109T090000Z-$_vaultId.Memex.zip'),
        isNull,
      );
    });

    test('a vault id of 25 or 27 characters does not parse', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);

      expect(
        parseBackupFileName(
          'notes-20261109T090000Z-${_vaultId.substring(1)}.memex.zip',
        ),
        isNull,
      );
      expect(
        parseBackupFileName('notes-20261109T090000Z-${_vaultId}X.memex.zip'),
        isNull,
      );
    });

    test('a vault id of 26 characters must be ASCII letters and numbers', () {
      final control = parseBackupFileName(_name('notes'));
      expect(control, isNotNull);
      expect(control!.vaultId, _vaultId);

      for (final bad in ['-', '_', '.', ' ', '~', '@', 'é', 'Ł', '😀']) {
        final id = '${_vaultId.substring(0, 24)}$bad${_vaultId[25]}';
        expect(
          id.runes.length,
          26,
          reason: 'the id is 26 characters long ($bad)',
        );
        expect(
          parseBackupFileName('notes-20261109T090000Z-$id.memex.zip'),
          isNull,
          reason: 'a vault id holding "$bad"',
        );
      }
      // The first character is held to the class too.
      expect(
        parseBackupFileName(
          'notes-20261109T090000Z--${_vaultId.substring(1)}.memex.zip',
        ),
        isNull,
      );
    });

    test('the dots of the extension are literal dots', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);

      for (final tail in [
        '${_vaultId}xmemex.zip',
        '$_vaultId.memexxzip',
        '${_vaultId}xmemexxzip',
        '$_vaultId-memex-zip',
        '$_vaultId.memex.zi',
        '$_vaultId.memex.zipp',
      ]) {
        expect(
          parseBackupFileName('notes-20261109T090000Z-$tail'),
          isNull,
          reason: tail,
        );
      }
    });

    test('a timestamp of the wrong shape does not parse', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);

      for (final stamp in [
        '2026119T090000Z',
        '202611090T090000Z',
        '20261109T09000Z',
        '20261109T0900000Z',
        '20261109T090000',
        '20261109-090000Z',
        '2026110ZT090000Z',
      ]) {
        expect(
          parseBackupFileName(_name('notes', stamp: stamp)),
          isNull,
          reason: stamp,
        );
      }
    });

    test('anything around the name makes it not a backup name', () {
      expect(parseBackupFileName(_name('notes')), isNotNull);

      final name = _name('notes');
      for (final bad in [
        '',
        '.memex.zip',
        ' $name',
        '$name ',
        '$name.partial',
        '.$name.partial',
        '/Users/tester/Downloads/$name',
        'x$name.bak',
      ]) {
        expect(parseBackupFileName(bad), isNull, reason: '"$bad"');
      }
    });
  });

  group('suggestedRestoreName', () {
    test('a valid backup name prefills its label', () {
      for (final row in _rows('valid')) {
        expect(
          suggestedRestoreName(row['name']! as String),
          row['label'],
          reason: row['name']! as String,
        );
      }
    });

    test('old copy.zip prefills old copy', () {
      expect(suggestedRestoreName('old copy.zip'), 'old copy');
    });

    test('x.memex.zip prefills x', () {
      expect(suggestedRestoreName('x.memex.zip'), 'x');
    });

    test('a name that does not match keeps its stem without the extension', () {
      expect(suggestedRestoreName('photos-2025.zip'), 'photos-2025');
      expect(suggestedRestoreName('my.vault.backup.zip'), 'my.vault.backup');
      expect(suggestedRestoreName('notes.memex.zip.zip'), 'notes.memex.zip');
      expect(suggestedRestoreName('work notes.memex.zip'), 'work notes');
    });

    test('a look-alike prefills its stem and never a label', () {
      expect(
        suggestedRestoreName('notes-20261109T090000Z-$_vaultId 2.memex.zip'),
        'notes-20261109T090000Z-$_vaultId 2',
      );
      expect(
        suggestedRestoreName('notes-20261109T090000Z-$_vaultId.zip'),
        'notes-20261109T090000Z-$_vaultId',
      );
    });

    test('a file name with no extension prefills itself', () {
      expect(suggestedRestoreName('backup'), 'backup');
    });

    test('only the final extension is removed', () {
      expect(suggestedRestoreName('a.zip.memex.zip'), 'a.zip');
    });
  });

  group('backupLabelFor', () {
    test('every label row of file_names.json maps its folder to its label', () {
      final rows = _rows('labels');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(
          backupLabelFor(row['folder']! as String),
          row['label'],
          reason: row['folder']! as String,
        );
      }
    });

    test('one dash per unicode scalar not per UTF-16 code unit', () {
      expect(backupLabelFor('Notes \u{1F4DA}'), 'Notes--');
      expect(backupLabelFor('\u{1F4DA}'), '-');
      expect(backupLabelFor('\u{1F4DA}\u{1F4DA}x'), '--x');
    });

    test('a label is cut at 64 scalars and never splits one', () {
      expect(backupLabelFor('a' * 70), 'a' * 64);
      expect(backupLabelFor('\u{1F4DA}' * 70), '-' * 64);
      expect(backupLabelFor('a' * 64), 'a' * 64);
      expect(backupLabelFor('a' * 63), 'a' * 63);
    });

    test('a label from a folder name always parses back', () {
      for (final folder in ['My Notes', 'Notes \u{1F4DA}', 'work.vault', 'a']) {
        final label = backupLabelFor(folder);
        expect(parseBackupFileName(_name(label))?.label, label, reason: folder);
      }
    });
  });

  group('ASCII only', () {
    test(
      'a non ASCII scalar that truncates to an ASCII byte is still a dash',
      () {
        // U+0141 'Ł' & 0xFF == 0x41 'A' (Rust's `c as u8` bug, R1a #332).
        expect(backupLabelFor('Ł'), '-');
        expect(backupLabelFor('š'), '-'); // & 0xFF == 0x61 'a'
        expect(backupLabelFor('İ'), '-'); // & 0xFF == 0x30 '0'
        expect(backupLabelFor('aŁ\u{1F4DA}b'), 'a--b');
      },
    );

    test('exactly the ASCII letters digits underscore and dash are kept', () {
      for (var rune = 0; rune < 128; rune++) {
        final char = String.fromCharCode(rune);
        final kept = RegExp(r'^[A-Za-z0-9_-]$').hasMatch(char);

        expect(
          backupLabelFor(char),
          kept ? char : '-',
          reason: 'U+${rune.toRadixString(16)}',
        );
      }
    });

    test('non ASCII digits and letters are not part of a name', () {
      expect(
        parseBackupFileName(_name('notes', stamp: '٢026110٩T090000Z')),
        isNull,
      );
      expect(parseBackupFileName(_name('nötes')), isNull);
      expect(
        parseBackupFileName(_name('notes', stamp: '2026110９T090000Z')),
        isNull,
      );
    });
  });
}
