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
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show requiredVaultSchemaVersion;

import '../support/api_fixtures.dart';

/// The shared row text, also parsed by the Rust test.
String _sharedIndexJson() => File(parityIndexJsonPath).readAsStringSync();

/// `api_fixtures_parity/row_cases.json`: the accepted and rejected row cases
/// the Rust row-loader tests run too.
Map<String, Object?> _sharedRowCases() =>
    jsonDecode(
          File(
            'test/fixtures/api_fixtures_parity/row_cases.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

/// The rejected cases whose first error starts with [prefix], as
/// (why, row, error substrings).
List<(String, Map<String, Object?>, List<String>)> _rejectedCases(
  String prefix,
) => [
  for (final c
      in (_sharedRowCases()['rejected']! as List<Object?>)
          .cast<Map<String, Object?>>())
    if ((c['error']! as List<Object?>).first.toString().startsWith(prefix))
      (
        c['why']! as String,
        c['row']! as Map<String, Object?>,
        [for (final e in c['error']! as List<Object?>) e! as String],
      ),
];

/// A valid row put before each case, so the error must name row `[1]`.
const _leadingGoodRow = {
  'method': 'GET',
  'path': '/x',
  'response': 'x.json',
  'status': 200,
};

/// A matcher for an error whose text holds every one of [parts].
Matcher _errorWith(List<String> parts) => throwsA(
  predicate((Object e) {
    final s = e.toString();
    return parts.every(s.contains);
  }, 'an error containing $parts'),
);

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
        expect(db.schemaVersionForTest, requiredVaultSchemaVersion);

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

    test(
      'the Pacing Notes snippet backs off to 116 units instead of splitting its surrogate pair',
      () {
        final db = seededFakeVaultDb();
        addTearDown(db.close);
        final item = db
            .listNotes(limit: 1000000)
            .singleWhere((n) => n.title == 'Pacing Notes');
        final line = _snippetSourceLine(db.getNote(item.id)!.contentMd);
        expect(line.length, greaterThan(120));
        final unitCut = line.substring(0, 117);
        final runeCut = String.fromCharCodes(line.runes.take(117));
        expect(
          runeCut,
          isNot(unitCut),
          reason: 'a cut by code points must differ from the UTF-16 cut',
        );
        final last = unitCut.codeUnitAt(116);
        expect(
          last >= 0xD800 && last <= 0xDBFF,
          isTrue,
          reason: 'a 117-unit cut would end on a lone high surrogate',
        );
        // WI #81 TEST-CHANGE (ruling D10b): the snippet backs off one unit
        // rather than keep the lone high surrogate.
        expect(item.snippet, '${line.substring(0, 116).trim()}…');
      },
    );

    test(
      'the seed daily notes have every review state as dailyNotes computes it',
      () {
        final db = seededFakeVaultDb();
        addTearDown(db.close);
        final byDate = {for (final d in db.dailyNotes()) d.date: d};
        expect(byDate['2026-10-18']?.reviewState, ReviewState.reviewed);
        expect(byDate['2026-10-19']?.reviewState, ReviewState.unreviewed);
        expect(
          byDate['2026-10-17']?.reviewState,
          ReviewState.changedSinceReview,
          reason: '2026-10-17 was edited after its review',
        );
        final changed = db.db.select(
          'SELECT r.content_version, r.reviewed_content_version '
          'FROM day_reviews r JOIN notes n ON n.id = r.note_id '
          "WHERE n.title = '2026-10-17'",
        );
        expect(changed, hasLength(1));
        expect(
          (
            changed.first['content_version'],
            changed.first['reviewed_content_version'],
          ),
          (2, 1),
        );
        expect(
          db.reviewState(byDate['2026-10-17']!.noteId)!.state,
          ReviewState.changedSinceReview,
        );
      },
    );

    test('the seed pre-V5 daily note has no review row, blocks or marker', () {
      final db = seededFakeVaultDb();
      addTearDown(db.close);
      final row = db.dailyNoteForDate('2026-10-15');
      expect(row, isNotNull, reason: '2026-10-15 is a daily note');
      expect(row!.reviewState, ReviewState.unreviewed);
      expect(
        db.db.select('SELECT 1 FROM day_reviews WHERE note_id = ?', [
          row.noteId,
        ]),
        isEmpty,
        reason: '2026-10-15 has no day_reviews row',
      );
      final info = db.reviewState(row.noteId)!;
      expect(info.state, ReviewState.unreviewed);
      expect(info.reviewedAt, isNull);
      // A real pre-V5 daily note: no blocks rows, so an empty preview, and
      // no topics marker in its body or its chunks.
      expect(db.blocksForNote(row.noteId), isEmpty);
      expect(row.preview, '');
      final body = db.db.select('SELECT content_md FROM notes WHERE id = ?', [
        row.noteId,
      ]);
      expect(body.single['content_md'], 'Read about loot tables.\n');
      final chunks = db.db.select(
        'SELECT content FROM chunks WHERE note_id = ? ORDER BY ord',
        [row.noteId],
      );
      expect(chunks.map((c) => c['content']).toList(), [
        'Read about loot tables.',
      ]);
    });

    test('the seed daily preview stops at the first newline of the block', () {
      final db = seededFakeVaultDb();
      addTearDown(db.close);
      final row = db.dailyNoteForDate('2026-10-16');
      expect(row, isNotNull);
      final first = db.blocksForNote(row!.noteId).first.text;
      expect(first, contains('\n'), reason: 'the first block spans two lines');
      expect(row.preview, 'Morning playtest with the new crafting tree');
    });

    test(
      'the Broken Frontmatter note reads as role-less and unsorted through VaultDb reads',
      () {
        final db = seededFakeVaultDb();
        addTearDown(db.close);
        final raw = db.db.select(
          "SELECT json_valid(frontmatter) AS ok FROM notes "
          "WHERE title = 'Broken Frontmatter'",
        );
        expect(raw, hasLength(1));
        expect(raw.first['ok'], 0, reason: 'its frontmatter is not JSON');

        final graph = db.graphNotes().singleWhere(
          (n) => n.title == 'Broken Frontmatter',
        );
        expect(graph.role, isNull);
        final unsorted = db.unsortedNotes().where(
          (n) => n.title == 'Broken Frontmatter',
        );
        expect(unsorted, hasLength(1));
        expect(unsorted.single.role, isNull);
        expect(
          db.dailyNotes().map((d) => d.date),
          isNot(contains('Broken Frontmatter')),
        );
      },
    );
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

    test(
      'row loader rejects request and response names that are not bare file names',
      () {
        final cases = _rejectedCases('field "re');
        expect(cases, hasLength(15), reason: 'every bare-name case');
        var n = 0;
        for (final (why, row, errors) in cases) {
          final field = errors.first.contains('"request"')
              ? 'request'
              : 'response';
          final dir = _writeDomain(
            Directory('${tmp.path}/${n++}')..createSync(),
            'barenames',
            jsonEncode([_leadingGoodRow, row]),
          );
          expect(
            () => loadFixtureRows(dir),
            _errorWith(['barenames[1]', ...errors, jsonEncode(row[field])]),
            reason: why,
          );
        }
        for (final c
            in (_sharedRowCases()['accepted']! as List<Object?>)
                .cast<Map<String, Object?>>()) {
          final row = c['row']! as Map<String, Object?>;
          final dir = _writeDomain(
            Directory('${tmp.path}/${n++}')..createSync(),
            'barenames',
            jsonEncode([row]),
          );
          final parsed = loadFixtureRows(dir).single;
          expect(parsed.response, row['response'], reason: c['why'] as String);
          expect(parsed.request, row['request'], reason: c['why'] as String);
        }
      },
    );

    test(
      'row loader rejects an unknown row key naming the row and the key',
      () {
        final cases = _rejectedCases('unknown field');
        expect(cases, hasLength(4), reason: 'every unknown-key case');
        var n = 0;
        for (final (why, row, errors) in cases) {
          final dir = _writeDomain(
            Directory('${tmp.path}/${n++}')..createSync(),
            'unknownkeys',
            jsonEncode([_leadingGoodRow, row]),
          );
          expect(
            () => loadFixtureRows(dir),
            _errorWith(['unknownkeys[1]', ...errors]),
            reason: why,
          );
        }
      },
    );

    test('row loader accepts statuses 100 to 599 only', () {
      const cases = [
        (99, false),
        (100, true),
        (599, true),
        (600, false),
        (70000, false),
        (-1, false),
      ];
      for (final (status, ok) in cases) {
        final dir = _writeDomain(
          Directory('${tmp.path}/$status')..createSync(),
          'statusrange',
          '[{"method": "GET", "path": "/api/v1/info", '
              '"response": "info.json", "status": $status}]',
        );
        if (ok) {
          expect(loadFixtureRows(dir).single.status, status);
        } else {
          expect(
            () => loadFixtureRows(dir),
            _errorWith(['statusrange[0]', 'status']),
            reason: '$status',
          );
        }
      }
    });

    test('row loader rejects optional fields of the wrong type', () {
      final cases = <(String, Object)>[
        ('request', 1),
        ('headers', ['X-Memex-UTC-Offset']),
        ('headers', {'X-Memex-UTC-Offset': 30}),
        ('dart_only', 'yes'),
        ('method', 1),
      ];
      var n = 0;
      for (final (field, value) in cases) {
        final row = <String, Object?>{
          'method': 'GET',
          'path': '/api/v1/info',
          'response': 'info.json',
          'status': 200,
        }..[field] = value;
        final dir = _writeDomain(
          Directory('${tmp.path}/${n++}')..createSync(),
          'wrongtype',
          jsonEncode([row]),
        );
        expect(
          () => loadFixtureRows(dir),
          _errorWith(['wrongtype[0]', field]),
          reason: '$field=$value',
        );
      }
      // Explicit nulls read as absent.
      final dir = _writeDomain(
        tmp,
        'nulls',
        '[{"method": "GET", "path": "/api/v1/info", "response": "info.json", '
            '"status": 200, "request": null, "headers": null, '
            '"dart_only": null}]',
      );
      final row = loadFixtureRows(dir).single;
      expect((row.request, row.headers.length, row.dartOnly), (null, 0, false));
    });
  });

  group('domain discovery', () {
    test('every api_v1 domain loads and names only files that exist', () {
      final globbed = [
        for (final e in Directory(apiV1FixturesDir).listSync())
          if (e is Directory && File('${e.path}/index.json').existsSync())
            e.path,
      ]..sort();
      final found = allDomainDirs();
      expect(found, globbed);
      final names = [for (final d in found) d.split('/').last];
      expect(names, contains('compat'));
      // No folder is special: server/ is a domain exactly when it holds an
      // index.json (#72 adds one); utc_offsets.json is simply not a row file.
      expect(
        names.contains('server'),
        File('$apiV1FixturesDir/server/index.json').existsSync(),
        reason: 'server/ is a domain iff it holds an index.json',
      );
      expect(names, [...names]..sort(), reason: 'sorted by folder name');
      expect(
        names,
        isNot(contains('api_fixtures_parity')),
        reason: 'the parity file is never a domain',
      );
      for (final d in found) {
        expect(() => checkDomainFiles(d), returnsNormally, reason: d);
      }
    });

    test('checkDomainFiles lists every missing request and response file', () {
      final dir = _writeDomain(tmp, 'missingfiles', '''
[
  {"method": "GET", "path": "/a", "response": "a.json", "status": 200},
  {"method": "POST", "path": "/b", "request": "b.request.json", "response": "b.json", "status": 201},
  {"method": "POST", "path": "/c", "request": "c.request.json", "response": "c.json", "status": 201}
]''');
      File('$dir/a.json').writeAsStringSync('{}\n');
      File('$dir/c.request.json').writeAsStringSync('{}\n');
      expect(
        () => checkDomainFiles(dir),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message.split('\n'), 'missing lines', [
                'missingfiles[1]: request file b.request.json is missing',
                'missingfiles[1]: response file b.json is missing',
                'missingfiles[2]: response file c.json is missing',
              ]),
        ),
      );
      for (final f in ['b.request.json', 'b.json', 'c.json']) {
        File('$dir/$f').writeAsStringSync('{}\n');
      }
      expect(() => checkDomainFiles(dir), returnsNormally);
      final bad = _writeDomain(
        tmp,
        'badrow',
        '[{"method": "GET", "path": "/a", "response": "../a.json", "status": 200}]',
      );
      expect(
        () => checkDomainFiles(bad),
        _errorWith(['badrow[0]', 'response']),
      );
    });

    test('the parity rows come from the one shared file', () {
      expect(
        parityIndexJsonPath,
        'test/fixtures/api_fixtures_parity/index.json',
      );
      expect(File(parityIndexJsonPath).existsSync(), isTrue);
      final rust = File(
        '../crates/memex-mcp/tests/support/api_fixtures.rs',
      ).readAsStringSync();
      expect(
        rust,
        contains('api_v1_dir().join("../api_fixtures_parity/index.json")'),
        reason: 'the Rust parity_index_path names the same file',
      );
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
