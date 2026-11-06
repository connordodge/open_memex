import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show requiredVaultSchemaVersion;
import 'package:sqlite3/sqlite3.dart';

import '../support/fake_vault_db.dart';

void main() {
  group('FakeVaultDb (AC1)', () {
    test(
      'FakeVaultDb loads the V5 fixture in memory and listNotes returns a seeded note',
      () {
        final db = FakeVaultDb();
        addTearDown(db.close);

        expect(db.schemaVersionForTest, requiredVaultSchemaVersion);
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

        expect(db.schemaVersionForTest, requiredVaultSchemaVersion);
        expect(db.hasTables(v5Tables), isTrue);
        expect(db.hasTables(['smart_folders']), isTrue);
      },
    );
  });
}
