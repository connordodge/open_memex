// WI #74 (C0): the Dart half of the wire-contract fixture infrastructure
// (rulings D10, D10a). Pins `test/support/api_fixtures.dart`, whose public
// surface, as used here, is:
//
//   const apiV1FixturesDir = 'test/fixtures/api_v1';
//   class FixtureRow {
//     String method, path; String? request; String response; int status;
//     Map<String, String> headers;  // empty when absent
//     bool dartOnly;                // `dart_only`, false when absent
//     Object? readResponseJson();   // decoded `<domain dir>/<response>`
//   }
//   List<FixtureRow> loadFixtureRows(String domainDir);  // throws, naming
//       // `<domain>[<zero-based index>]` and the field, on a malformed row
//   FakeVaultDb seededFakeVaultDb();  // vault_schema_v5.sql + seed_vault.sql
//   class UtcOffsetCases {
//     Map<String, int> valid; List<String> invalid; Map<int, String> format;
//   }
//   UtcOffsetCases loadUtcOffsetCases();  // api_v1/server/utc_offsets.json
//
// The Rust half is crates/memex-mcp/tests/api_fixtures.rs; both parse the
// same index.json text (`api_fixtures_parity/index.json`) and assert the same values.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';

import '../support/api_fixtures.dart';

/// The shared row text, also parsed by the Rust test.
String _sharedIndexJson() =>
    File('test/fixtures/api_fixtures_parity/index.json').readAsStringSync();

String _seedSql() =>
    File('$apiV1FixturesDir/seed_vault.sql').readAsStringSync();

/// `INSERT` statements per table in the committed seed (one per row).
Map<String, int> _insertCounts(String sql) {
  final re = RegExp(
    r'^INSERT\s+(?:OR\s+\w+\s+)?INTO\s+"?([A-Za-z_][A-Za-z0-9_]*)"?[\s(]',
    multiLine: true,
    caseSensitive: false,
  );
  final counts = <String, int>{};
  for (final m in re.allMatches(sql)) {
    counts.update(m.group(1)!, (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

/// The first non-blank line after stripping heading markers, as
/// `VaultDb._snippet` computes it before its length cut.
String _snippetSourceLine(String content) {
  final stripped = content.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
  return stripped
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
}

String? _firstNonBlankLine(String content) {
  for (final l in content.split('\n')) {
    if (l.trim().isNotEmpty) return l;
  }
  return null;
}

/// Writes `<parent>/<domain>/index.json`; returns the domain dir path.
String _writeDomain(Directory parent, String domain, String indexJson) {
  final dir = Directory('${parent.path}/$domain')..createSync(recursive: true);
  File('${dir.path}/index.json').writeAsStringSync(indexJson);
  return dir.path;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('api_fixtures_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('seed vault (AC2, AC3)', () {
    test(
      'seededFakeVaultDb reads return the seed rows with the seed SQL counts',
      () {
        final db = seededFakeVaultDb();
        addTearDown(db.close);
        expect(db.schemaVersionForTest, 5);

        final counts = _insertCounts(_seedSql());
        final notes = counts['notes'] ?? 0;
        final links = counts['links'] ?? 0;
        final folders = counts['smart_folders'] ?? 0;
        expect(notes, greaterThan(0), reason: 'the seed inserts notes');
        expect(links, greaterThan(0), reason: 'the seed inserts links');
        expect(folders, greaterThan(0), reason: 'the seed inserts folders');

        final listed = db.listNotes(limit: 1000000);
        expect(listed, hasLength(notes));
        for (final n in listed) {
          final note = db.getNote(n.id);
          expect(note, isNotNull, reason: n.id);
          expect(note!.title, n.title);
        }
        final linkCount = listed.fold<int>(
          0,
          (sum, n) => sum + db.linksOutFor(n.id).length,
        );
        expect(linkCount, links);
        expect(db.smartFolders().folders, hasLength(folders));
      },
    );

    test('seededFakeVaultDb returns a fresh database each call', () {
      final a = seededFakeVaultDb();
      final b = seededFakeVaultDb();
      addTearDown(a.close);
      addTearDown(b.close);
      final before = b.listNotes(limit: 1000000).length;
      a.seedNote(id: '01KAZZZZZZZZZZZZZZZZZZZZZ9', title: 'Only in a');
      expect(b.listNotes(limit: 1000000), hasLength(before));
      expect(a.listNotes(limit: 1000000), hasLength(before + 1));
    });

    test('the seed has every D10 edge row through VaultDb reads', () {
      final db = seededFakeVaultDb();
      addTearDown(db.close);
      final listed = db.listNotes(limit: 1000000);
      final notes = [for (final n in listed) db.getNote(n.id)!];
      final snippets = {for (final n in listed) n.id: n.snippet};

      // 1. A snippet that comes from a heading-prefixed first line.
      final heading = RegExp(r'^#{1,6}\s+\S');
      final headed = notes.where((n) {
        final first = _firstNonBlankLine(n.contentMd);
        return first != null && heading.hasMatch(first);
      }).toList();
      expect(headed, isNotEmpty, reason: 'no note starts with a heading');
      expect(
        headed.any((n) {
          final s = snippets[n.id]!;
          return s.isNotEmpty && !s.startsWith('#');
        }),
        isTrue,
        reason: 'the heading note snippet drops the # marker',
      );

      // 2. Over 120 characters with a surrogate pair straddling the
      //    117-UTF-16-unit cut of VaultDb._snippet (substring(0, 117) on a
      //    line over 120 units): high surrogate at unit 116, low at 117.
      bool isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
      bool isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;
      expect(
        notes.any((n) {
          final line = _snippetSourceLine(n.contentMd);
          return line.length > 120 &&
              line.runes.length > 120 &&
              isHigh(line.codeUnitAt(116)) &&
              isLow(line.codeUnitAt(117));
        }),
        isTrue,
        reason: 'no long note with a surrogate pair at units 116-117',
      );

      // 3. A ghost link: no target, and no note has its text as a title.
      final titles = {for (final n in notes) n.title.toLowerCase()};
      final ghosts = [
        for (final n in notes)
          ...db.linksOutFor(n.id).where((l) => l.toNoteId == null),
      ];
      expect(
        ghosts.any((l) => !titles.contains(l.linkText.toLowerCase())),
        isTrue,
        reason: 'no ghost link: ${ghosts.map((l) => l.linkText).toList()}',
      );

      // 4. An unreviewed daily note.
      expect(
        db.dailyNotes().any((d) => d.reviewState == ReviewState.unreviewed),
        isTrue,
        reason: 'no unreviewed daily note',
      );

      // 5. A pinned Smart Folder.
      expect(
        db.smartFolders().folders.any((f) => f.pinned),
        isTrue,
        reason: 'no pinned Smart Folder',
      );
    });
  });

  group('row loader (AC5)', () {
    test('row loader parses every row field like the Rust loader', () {
      final dir = _writeDomain(tmp, 'rowsdemo', _sharedIndexJson());
      final rows = loadFixtureRows(dir);
      expect(rows, hasLength(2));

      final a = rows[0];
      expect(a.method, 'GET');
      expect(a.path, '/vaults/seed/api/v1/notes');
      expect(a.request, isNull);
      expect(a.response, 'notes_list.json');
      expect(a.status, 200);
      expect(a.headers, isEmpty);
      expect(a.dartOnly, isFalse);

      final b = rows[1];
      expect(b.method, 'POST');
      expect(b.path, '/vaults/seed/api/v1/notes');
      expect(b.request, 'create_note.request.json');
      expect(b.response, 'create_note.json');
      expect(b.status, 201);
      expect(b.headers, {'X-Memex-UTC-Offset': '-00:30'});
      expect(b.dartOnly, isTrue, reason: 'Dart keeps dart_only rows');
    });

    test(
      'row loader rejects a row missing method path response or status and names it',
      () {
        final full = <String, Object>{
          'method': 'GET',
          'path': '/api/v1/info',
          'response': 'info.json',
          'status': 200,
        };
        for (final field in ['method', 'path', 'response', 'status']) {
          final broken = Map<String, Object>.of(full)..remove(field);
          final dir = _writeDomain(
            Directory('${tmp.path}/$field')..createSync(),
            'rowsdemo',
            jsonEncode([full, broken]),
          );
          expect(
            () => loadFixtureRows(dir),
            throwsA(
              predicate((Object e) {
                final s = e.toString();
                return s.contains('rowsdemo') &&
                    s.contains('[1]') &&
                    s.contains(field);
              }, 'an error naming rowsdemo, [1] and $field'),
            ),
            reason: field,
          );
        }
      },
    );

    test('row loader rejects malformed index files', () {
      final missing = Directory('${tmp.path}/nodomain')..createSync();
      expect(
        () => loadFixtureRows(missing.path),
        throwsA(predicate((Object e) => e.toString().contains('index.json'))),
      );

      final notArray = _writeDomain(tmp, 'notarray', '{"method": "GET"}');
      expect(
        () => loadFixtureRows(notArray),
        throwsA(predicate((Object e) => e.toString().contains('notarray'))),
      );

      final badStatus = _writeDomain(
        tmp,
        'badstatus',
        '[{"method": "GET", "path": "/api/v1/info", '
            '"response": "info.json", "status": "200"}]',
      );
      expect(
        () => loadFixtureRows(badStatus),
        throwsA(
          predicate((Object e) {
            final s = e.toString();
            return s.contains('badstatus') &&
                s.contains('[0]') &&
                s.contains('status');
          }),
        ),
      );
    });

    test('readResponseJson decodes the response file of the row', () {
      final dir = _writeDomain(
        tmp,
        'readdemo',
        '[{"method": "GET", "path": "/x", "response": "x.json", "status": 200}]',
      );
      File('$dir/x.json').writeAsStringSync('{"a": [1, "two", null]}');
      final row = loadFixtureRows(dir).single;
      expect(row.readResponseJson(), {
        'a': [1, 'two', null],
      });
    });
  });

  group('utc offsets fixture (AC9)', () {
    test('utc offsets fixture parses into valid invalid and format rows', () {
      expect(
        File('$apiV1FixturesDir/server/utc_offsets.json').existsSync(),
        isTrue,
      );
      final cases = loadUtcOffsetCases();

      const valid = {
        '-00:30': -30,
        '+14:00': 840,
        '-12:00': -720,
        '-14:00': -840,
        '+00:00': 0,
        '+05:45': 345,
      };
      valid.forEach((h, m) {
        expect(cases.valid[h], m, reason: 'valid $h');
      });
      for (final h in [
        '+15:00',
        '+5:00',
        '+05:60',
        '+14:01',
        '05:30',
        '+0530',
        '',
      ]) {
        expect(cases.invalid, contains(h), reason: 'invalid "$h"');
        expect(cases.valid.containsKey(h), isFalse, reason: h);
      }
      const format = {
        -30: '-00:30',
        0: '+00:00',
        345: '+05:45',
        -720: '-12:00',
      };
      format.forEach((m, h) {
        expect(cases.format[m], h, reason: 'format $m');
      });
    });
  });

  group('compat unknown-key row (AC10)', () {
    test(
      'compat domain returns its one dart only info row with the full response',
      () {
        final rows = loadFixtureRows('$apiV1FixturesDir/compat');
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.method, 'GET');
        expect(row.path, '/api/v1/info');
        expect(row.status, 200);
        expect(row.dartOnly, isTrue);

        final body = row.readResponseJson();
        expect(body, isA<Map<String, Object?>>());
        final map = body! as Map<String, Object?>;
        expect(map['server_version'], isA<String>());
        expect(map['api_version'], 1);
        final extra = map.keys
            .where((k) => k != 'server_version' && k != 'api_version')
            .toList();
        expect(extra, hasLength(1), reason: 'exactly one unknown key');
      },
    );
  });
}
