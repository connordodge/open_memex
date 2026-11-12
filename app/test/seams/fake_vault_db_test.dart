import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/fake_vault_db.dart';

void main() {
  group('FakeVaultDb (AC1)', () {
    test(
      'FakeVaultDb loads the V5 fixture in memory and listNotes returns a seeded note',
      () {
        final db = FakeVaultDb();
        addTearDown(db.close);

        expect(db.schemaVersionForTest, fixtureSchemaVersion);
        db.seedNote(
          id: '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
          title: 'Player Loop',
          content: '# Player Loop\n\nFixed the jump arc.\n',
          version: 3,
          createdAt: 1759500000000,
          updatedAt: 1759500600000,
        );

        final notes = db.listNotes();
        expect(notes, hasLength(1));
        expect(notes.single.id, '01J9Z8Y7X6W5V4T3S2R1Q0P9N8');
        expect(notes.single.title, 'Player Loop');
        expect(notes.single.snippet, 'Player Loop');
        expect(notes.single.version, 3);
        expect(notes.single.updatedAt, 1759500600000);
      },
    );

    test(
      'seedNote stores frontmatter, timestamps and tags read by getNote',
      () {
        final db = FakeVaultDb();
        addTearDown(db.close);
        db.seedNote(
          id: '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
          title: '2026-10-03',
          content: 'Morning pages\n',
          role: 'daily',
          version: 2,
          createdAt: 1759480000000,
          updatedAt: 1759490000000,
          tags: ['journal'],
        );

        final note = db.getNote('01J9Z8Y7X6W5V4T3S2R1Q0P9N8')!;
        expect(note.title, '2026-10-03');
        expect(note.contentMd, 'Morning pages\n');
        expect(note.frontmatter, '{"role":"daily"}');
        expect(note.version, 2);
        expect(note.createdAt, 1759480000000);
        expect(note.updatedAt, 1759490000000);
        expect(note.tags, ['journal']);
      },
    );
  });

  group('VaultDb.fromDatabase and Note.role (AC2)', () {
    late Database raw;
    late VaultDb vault;

    setUp(() {
      raw = sqlite3.openInMemory();
      raw.execute(File(vaultSchemaV5FixturePath).readAsStringSync());
      vault = VaultDb.fromDatabase(raw);
    });

    tearDown(() => vault.close());

    void insert(String id, String title, String frontmatter) {
      raw.execute(
        'INSERT INTO notes (id, title, content_md, frontmatter, version, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, 1, 1, 1)',
        [id, title, '', frontmatter],
      );
    }

    test('VaultDb.fromDatabase wraps an existing Database handle', () {
      expect(identical(vault.db, raw), isTrue);
      insert('01J9AAAAAAAAAAAAAAAAAAAAAA', 'Sleep', '{}');
      expect(vault.listNotes().map((n) => n.title), ['Sleep']);
    });

    test('Note.role reads daily and topic from the frontmatter JSON', () {
      insert('01J9AAAAAAAAAAAAAAAAAAAAAA', '2026-10-03', '{"role":"daily"}');
      insert(
        '01J9BBBBBBBBBBBBBBBBBBBBBB',
        'Player Loop',
        '{"role":"topic","aliases":["loop"]}',
      );
      expect(vault.getNote('01J9AAAAAAAAAAAAAAAAAAAAAA')!.role, 'daily');
      expect(vault.getNote('01J9BBBBBBBBBBBBBBBBBBBBBB')!.role, 'topic');
    });

    test(
      'Note.role is null for empty, role-less and malformed frontmatter',
      () {
        insert('01J9AAAAAAAAAAAAAAAAAAAAAA', 'Empty', '{}');
        insert('01J9BBBBBBBBBBBBBBBBBBBBBB', 'Malformed', '{"role": "daily"');
        insert('01J9CCCCCCCCCCCCCCCCCCCCCC', 'Other keys', '{"tags":["x"]}');
        insert('01J9DDDDDDDDDDDDDDDDDDDDDD', 'Not an object', '["daily"]');
        insert('01J9EEEEEEEEEEEEEEEEEEEEEE', 'Non-string role', '{"role":5}');
        insert('01J9FFFFFFFFFFFFFFFFFFFFFF', 'Blank', '');
        for (final id in [
          '01J9AAAAAAAAAAAAAAAAAAAAAA',
          '01J9BBBBBBBBBBBBBBBBBBBBBB',
          '01J9CCCCCCCCCCCCCCCCCCCCCC',
          '01J9DDDDDDDDDDDDDDDDDDDDDD',
          '01J9EEEEEEEEEEEEEEEEEEEEEE',
          '01J9FFFFFFFFFFFFFFFFFFFFFF',
        ]) {
          expect(vault.getNote(id)!.role, isNull, reason: 'note $id');
        }
      },
    );
  });

  group('VaultDb.hasTables on V4 and V5 vaults (AC14)', () {
    test('hasTables is false for the V5 tables on a V4-schema database', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);

      expect(db.schemaVersionForTest, 4);
      expect(db.hasTables(v5Tables), isFalse);
      // V4 tables are still there, so the probe is per table, not global.
      expect(db.hasTables(['notes', 'links', 'canvases']), isTrue);
      // One missing table is enough to fail the probe.
      expect(db.hasTables(['notes', 'smart_folders']), isFalse);
      expect(db.hasTables(['vault_settings']), isFalse);
    });

    test('hasTables is true for every V5 table on a V5 database', () {
      final db = FakeVaultDb.v5();
      addTearDown(db.close);
      expect(db.hasTables(v5Tables), isTrue);
      for (final t in v5Tables) {
        expect(db.hasTables([t]), isTrue, reason: t);
      }
      expect(db.hasTables(['no_such_table']), isFalse);
    });

    test(
      'a V5 probe re-run after the CLI migrates the same handle sees the new tables',
      () {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);

        // Probe before the migration: a cached false here would be stale.
        expect(db.hasTables(v5Tables), isFalse);
        expect(db.hasTables(['smart_folders']), isFalse);

        db.migrateToV5(); // what `memex settings get` does to a V4 vault

        expect(db.schemaVersionForTest, fixtureSchemaVersion);
        expect(db.hasTables(v5Tables), isTrue);
        expect(db.hasTables(['smart_folders']), isTrue);
      },
    );
  });

  group('FakeVaultDb at V7 and FakeVaultDb.v6Only (WI 415)', () {
    test(
      'FakeVaultDb loads the V7 fixture with content_revision at 1 0 and three triggers per table',
      () {
        final db = FakeVaultDb();
        addTearDown(db.close);

        expect(db.schemaVersionForTest, 7);
        expect(db.hasTables(v7Tables), isTrue);
        expect(_wi415RevisionRows(db.db), [(1, 0)]);
        expect(db.contentRevisionForTest, 0);

        final triggers = _wi415TriggersByTable(db.db);
        final regular = _wi415RegularTables(db.db);
        expect(regular, containsAll(<String>['notes', 'schema_version']));
        expect(regular, containsAll(v7Tables.take(2)));
        expect(regular, isNot(contains('content_revision')));
        for (final t in regular) {
          expect(triggers[t], {
            'content_revision_${t}_ai',
            'content_revision_${t}_au',
            'content_revision_${t}_ad',
          }, reason: t);
        }
        expect(triggers.keys.toSet(), regular.toSet());
      },
    );

    test(
      'a write through FakeVaultDb moves content_revision by one per row',
      () {
        final db = FakeVaultDb();
        addTearDown(db.close);

        db.seedNote(
          id: '01J9Z8Y7X6W5V4T3S2R1Q0P415',
          title: 'Player Loop',
          tags: ['design', 'loop'],
        );
        expect(db.contentRevisionForTest, 3, reason: 'one note and two tags');

        db.db.execute(
          "INSERT INTO learned_words (word_key, word, created_at) "
          "VALUES ('memex', 'Memex', 1) ON CONFLICT DO NOTHING",
        );
        expect(db.contentRevisionForTest, 4);
        db.db.execute(
          "INSERT INTO learned_words (word_key, word, created_at) "
          "VALUES ('memex', 'MEMEX', 2) ON CONFLICT DO NOTHING",
        );
        expect(db.contentRevisionForTest, 4, reason: 'an existing word');

        db.db.execute("DELETE FROM tags WHERE tag = 'loop'");
        expect(db.contentRevisionForTest, 5);
      },
    );

    test(
      'FakeVaultDb.v6Only builds a V6 vault without content_revision that still takes writes',
      () {
        final current = FakeVaultDb();
        addTearDown(current.close);
        expect(current.hasTables(const ['content_revision']), isTrue);

        final db = FakeVaultDb.v6Only();
        addTearDown(db.close);

        expect(db.schemaVersionForTest, 6);
        expect(db.hasTables(v6Tables), isTrue);
        expect(db.hasTables(v5Tables), isTrue);
        for (final t in v7Tables) {
          expect(db.hasTables([t]), isFalse, reason: t);
        }
        expect(_wi415TriggersByTable(db.db), isEmpty);
        expect(db.contentRevisionForTest, isNull);

        // No trigger is left pointing at the missing counter.
        db.seedNote(
          id: '01J9Z8Y7X6W5V4T3S2R1Q0P415',
          title: 'Player Loop',
          tags: ['design'],
        );
        expect(db.listNotes().single.title, 'Player Loop');
        expect(db.getNote('01J9Z8Y7X6W5V4T3S2R1Q0P415')!.tags, ['design']);
      },
    );

    test(
      'migrateToV6 on a v6Only vault adds the V7 tables and triggers and replays twice without duplicates',
      () {
        final fresh = FakeVaultDb();
        addTearDown(fresh.close);
        final want = _wi415TriggersByTable(fresh.db);
        expect(want, isNotEmpty);

        final db = FakeVaultDb.v6Only();
        addTearDown(db.close);
        db.seedNote(id: '01J9Z8Y7X6W5V4T3S2R1Q0P415', title: 'Kept');

        db.migrateToV6();

        expect(db.schemaVersionForTest, 7);
        expect(db.hasTables(v7Tables), isTrue);
        expect(_wi415TriggersByTable(db.db), want);
        expect(_wi415RevisionRows(db.db), [(1, 0)]);
        expect(db.listNotes().single.title, 'Kept');

        db.seedNote(id: '01J9Z8Y7X6W5V4T3S2R1Q0P416', title: 'Moved');
        expect(db.contentRevisionForTest, 1);

        // A second replay creates nothing twice and keeps n.
        db.migrateToV6();
        expect(_wi415TriggersByTable(db.db), want);
        expect(_wi415RevisionRows(db.db), [(1, 1)]);
        expect(db.schemaVersionForTest, 7);
      },
    );

    test(
      'migrateToV5 on a V4 vault leaves every table with its three revision triggers',
      () {
        final fresh = FakeVaultDb();
        addTearDown(fresh.close);
        final want = _wi415TriggersByTable(fresh.db);

        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        expect(_wi415TriggersByTable(db.db), isEmpty);
        expect(db.hasTables(const ['content_revision']), isFalse);
        db.seedNote(
          id: '01J9Z8Y7X6W5V4T3S2R1Q0P415',
          title: 'Kept',
          tags: ['design'],
        );

        db.migrateToV5();

        expect(db.schemaVersionForTest, 7);
        // `tags` is rebuilt with the V6 columns; it keeps its triggers too.
        expect(
          _wi415TriggersByTable(db.db)['tags'],
          want['tags'],
          reason: 'the rebuilt tags table has its triggers',
        );
        expect(_wi415TriggersByTable(db.db), want);
        expect(db.getNote('01J9Z8Y7X6W5V4T3S2R1Q0P415')!.tags, ['design']);
        expect(db.contentRevisionForTest, 0);
        db.db.execute("DELETE FROM tags WHERE tag = 'design'");
        expect(db.contentRevisionForTest, 1);
      },
    );

    test(
      'FakeVaultDb.v5Only drops the V7 tables and triggers with the V6 ones',
      () {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);

        expect(db.schemaVersionForTest, 5);
        expect(db.hasTables(const ['content_revision']), isFalse);
        expect(_wi415TriggersByTable(db.db), isEmpty);
        db.seedNote(id: '01J9Z8Y7X6W5V4T3S2R1Q0P415', title: 'Kept');
        expect(db.listNotes().single.title, 'Kept');

        db.migrateToV6();
        expect(db.schemaVersionForTest, 7);
        expect(db.contentRevisionForTest, 0);
      },
    );
  });
}

/// Every trigger of [db], by the table it is on.
Map<String, Set<String>> _wi415TriggersByTable(Database db) {
  final out = <String, Set<String>>{};
  for (final r in db.select(
    "SELECT tbl_name, name FROM sqlite_master WHERE type = 'trigger'",
  )) {
    out
        .putIfAbsent(r['tbl_name'] as String, () => <String>{})
        .add(r['name'] as String);
  }
  return out;
}

/// Every regular table of [db] that must carry the revision triggers: all
/// but `content_revision`, `sqlite_*` and the FTS and vector tables.
List<String> _wi415RegularTables(Database db) => db
    .select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name <> 'content_revision' AND name NOT LIKE 'sqlite%' "
      "AND name NOT LIKE 'chunk_fts%' AND name NOT LIKE 'chunk_vec%' "
      'ORDER BY name',
    )
    .map((r) => r['name'] as String)
    .toList();

/// Every `content_revision` row as (id, n).
List<(int, int)> _wi415RevisionRows(Database db) => db
    .select('SELECT id, n FROM content_revision ORDER BY id')
    .map((r) => ((r['id'] as num).toInt(), (r['n'] as num).toInt()))
    .toList();
