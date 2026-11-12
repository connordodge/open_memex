// WI #70 (W0a) AC7: VaultDb.dataVersion() and the local revision on a real
// temp SQLite vault (D9 local half, Req 22). The app's handle is read-only;
// a second connection stands in for the CLI's writes.
//
// WI #419 (Spec #391 requirement 9, ruling D4): on a vault with
// `content_revision` (V7) the value is `<handle instance id>-<n>`, so a
// vector-only write leaves it as it was; a V6 vault keeps the
// `<handle instance id>-<data_version>` form.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/fake_vault_db.dart';

/// A temp vault folder with `manifest.json` and a V5 `memex.db`.
String _tempVault() {
  final dir = Directory.systemTemp.createTempSync('om-70-vault-');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    p.join(dir.path, 'manifest.json'),
  ).writeAsStringSync('{"vault_id":"01HV0000000000000000000070"}');
  final writer = sqlite3.open(p.join(dir.path, 'memex.db'));
  writer.execute(File(vaultSchemaV5FixturePath).readAsStringSync());
  writer.dispose();
  return dir.path;
}

/// A second, writable connection (the CLI's) on [vaultPath].
Database _writer(String vaultPath) {
  final db = sqlite3.open(p.join(vaultPath, 'memex.db'));
  addTearDown(db.dispose);
  return db;
}

VaultDb _open(String vaultPath) {
  final db = VaultDb.open(vaultPath);
  addTearDown(db.close);
  return db;
}

int _counter = 0;

void _commitNote(Database writer) {
  final id = 'n-70-${_counter++}';
  writer.execute(
    'INSERT INTO notes (id, title, content_md, frontmatter, version, '
    'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [id, 'Note $id', 'body', '{}', 1, 1759500000000, 1759500000000],
  );
}

/// The handle's own `PRAGMA data_version`.
int _pragmaDataVersion(VaultDb db) =>
    (db.db.select('PRAGMA data_version').first.values.first as num).toInt();

// ---- WI 419 helpers --------------------------------------------------------

/// A temp vault folder whose `memex.db` is exactly at schema V6: the
/// [FakeVaultDb.v6Only] database (no `content_revision`, no revision
/// triggers) copied to a file, so a second connection can write to it.
String _wi419TempV6Vault() {
  final dir = Directory.systemTemp.createTempSync('om-419-v6-');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    p.join(dir.path, 'manifest.json'),
  ).writeAsStringSync('{"vault_id":"01HV0000000000000000000419"}');
  final v6 = FakeVaultDb.v6Only();
  v6.db.execute('VACUUM INTO ?', [p.join(dir.path, 'memex.db')]);
  v6.close();
  return dir.path;
}

/// `content_revision.n`, read on [conn].
int _wi419ContentRevision(Database conn) =>
    (conn.select('SELECT n FROM content_revision WHERE id = 1').first['n']
            as num)
        .toInt();

/// The `<n>` after the handle id: everything after the last `-`.
String _wi419Suffix(String revision) =>
    revision.substring(revision.lastIndexOf('-') + 1);

/// The handle id: everything before the last `-`.
String _wi419HandleId(String revision) =>
    revision.substring(0, revision.lastIndexOf('-'));

/// The tables vec0 keeps a `chunk_vec` in (its shadow tables). The app's
/// sqlite3 has no vec0 module, so the writer makes them as plain tables:
/// what a vector-only write touches at the SQLite level. Like vec0's own,
/// they carry no revision trigger (`chunk_vec_*` is exempt, D4).
void _wi419CreateVectorTables(Database writer) {
  writer.execute(
    'CREATE TABLE chunk_vec_rowids (rowid INTEGER PRIMARY KEY, id TEXT UNIQUE, '
    'chunk_id INTEGER, chunk_offset INTEGER)',
  );
  writer.execute(
    'CREATE TABLE chunk_vec_vector_chunks00 (rowid INTEGER PRIMARY KEY, '
    'vectors BLOB NOT NULL)',
  );
}

int _wi419VectorCount = 0;

/// One vector-only commit: a `chunk_vec` row for [chunkId], written to the
/// vec0 shadow tables in one transaction.
void _wi419InsertVector(Database writer, String chunkId) {
  final row = ++_wi419VectorCount;
  writer.execute('BEGIN');
  writer.execute(
    'INSERT INTO chunk_vec_rowids (rowid, id, chunk_id, chunk_offset) '
    'VALUES (?, ?, 1, ?)',
    [row, chunkId, row],
  );
  writer.execute(
    'INSERT INTO chunk_vec_vector_chunks00 (rowid, vectors) VALUES (?, ?)',
    [row, List<int>.filled(16, row)],
  );
  writer.execute('COMMIT');
}

/// An orphan delete: [chunkId]'s vector goes, in one transaction.
void _wi419DeleteVector(Database writer, String chunkId) {
  final rows = writer.select(
    'SELECT rowid FROM chunk_vec_rowids WHERE id = ?',
    [chunkId],
  );
  expect(rows, hasLength(1), reason: 'fixture: $chunkId has a vector');
  final row = rows.first['rowid'] as int;
  writer.execute('BEGIN');
  writer.execute('DELETE FROM chunk_vec_vector_chunks00 WHERE rowid = ?', [
    row,
  ]);
  writer.execute('DELETE FROM chunk_vec_rowids WHERE rowid = ?', [row]);
  writer.execute('COMMIT');
}

/// A note save by [writer], as `memex update` commits one: the note's body
/// and version, plus a tag row, in one transaction (two rows, so `n` moves
/// by more than one per commit while `data_version` moves by one).
void _wi419SaveNote(Database writer, String noteId, int round) {
  writer.execute('BEGIN');
  writer.execute(
    'UPDATE notes SET content_md = ?, version = version + 1, updated_at = ? '
    'WHERE id = ?',
    ['saved $round', 1759500000000 + round, noteId],
  );
  writer.execute('INSERT INTO tags (note_id, tag) VALUES (?, ?)', [
    noteId,
    'saved-$round',
  ]);
  writer.execute('COMMIT');
}

/// A note [noteId] committed by [writer].
void _wi419AddNote(Database writer, String noteId) {
  writer.execute(
    'INSERT INTO notes (id, title, content_md, frontmatter, version, '
    'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [noteId, 'Note $noteId', 'body', '{}', 1, 1759500000000, 1759500000000],
  );
}

void main() {
  test(
    'dataVersion is the handle id and PRAGMA data_version and is unchanged when nothing is written',
    () {
      // A V6 vault: the data_version form is the fallback since WI 419.
      final vault = _wi419TempV6Vault();
      final db = _open(vault);

      final first = db.dataVersion();
      final dash = first.lastIndexOf('-');
      expect(
        dash,
        greaterThan(0),
        reason: '<handle instance id>-<data_version>',
      );
      expect(first.substring(dash + 1), '${_pragmaDataVersion(db)}');

      // Reads on the same handle are not writes.
      db.listNotes();
      db.schemaVersion();
      expect(db.dataVersion(), first);
      expect(db.dataVersion(), first);
    },
  );

  test('dataVersion changes after a second connection commits a write', () {
    final vault = _tempVault();
    final db = _open(vault);
    final writer = _writer(vault);

    final before = db.dataVersion();
    _commitNote(writer);
    final afterOne = db.dataVersion();
    expect(afterOne, isNot(before));
    expect(db.listNotes(), hasLength(1), reason: 'the write is committed');

    _commitNote(writer);
    final afterTwo = db.dataVersion();
    expect(afterTwo, isNot(afterOne));
    expect(afterTwo, isNot(before));
    // Stable again until the next commit.
    expect(db.dataVersion(), afterTwo);
  });

  test('dataVersion changes after a second connection commits a delete', () {
    final vault = _tempVault();
    final writer = _writer(vault);
    _commitNote(writer);
    final db = _open(vault);

    final before = db.dataVersion();
    writer.execute('DELETE FROM notes');
    expect(db.dataVersion(), isNot(before));
  });

  test(
    'a newly opened handle gives a different dataVersion than the previous handle',
    () {
      final vault = _tempVault();
      final first = VaultDb.open(vault);
      final firstValue = first.dataVersion();
      first.close();

      final second = _open(vault);
      expect(second.dataVersion(), isNot(firstValue));

      // Two handles open at once differ too, with nothing written.
      final third = _open(vault);
      expect(third.dataVersion(), isNot(second.dataVersion()));
    },
  );

  test('two in-memory handles give different dataVersions', () {
    final a = FakeVaultDb.v5();
    addTearDown(a.close);
    final b = FakeVaultDb.v5();
    addTearDown(b.close);

    expect(a.dataVersion(), isNotEmpty);
    expect(a.dataVersion(), isNot(b.dataVersion()));
  });

  test(
    'dataVersion instance ids are distinct across FakeVaultDb and both VaultDb constructors',
    () {
      String handleId(VaultDb db) {
        final v = db.dataVersion();
        return v.substring(0, v.lastIndexOf('-'));
      }

      final vault = _tempVault();
      final opened = _open(vault);
      final raw = sqlite3.openInMemory();
      final fromDatabase = VaultDb.fromDatabase(raw);
      addTearDown(fromDatabase.close);
      final fake = FakeVaultDb.v5();
      addTearDown(fake.close);
      final opened2 = _open(vault);

      final ids = [
        for (final db in [opened, fromDatabase, fake, opened2]) handleId(db),
      ];
      for (final id in ids) {
        expect(id, isNotEmpty);
      }
      expect(ids.toSet(), hasLength(ids.length), reason: '$ids');
      // Each handle keeps its id across reads.
      expect(handleId(fake), ids[2]);
      expect(handleId(opened), ids[0]);
    },
  );

  test(
    'local revision returns the handle dataVersion and changes after a commit',
    () async {
      final vault = _tempVault();
      final db = _open(vault);
      final writer = _writer(vault);
      final access = LocalVaultAccess(vaultPath: vault, db: db);

      final before = await access.revision();
      expect(before, db.dataVersion());
      expect(await access.revision(), before, reason: 'no write, no change');

      _commitNote(writer);
      final after = await access.revision();
      expect(after, isNot(before));
      expect(after, db.dataVersion());
    },
  );

  group('WI 419: dataVersion follows content_revision (D4)', () {
    test(
      'on a V7 vault a vector-only write by another connection leaves dataVersion unchanged',
      () {
        final vault = _tempVault();
        final db = _open(vault);
        final writer = _writer(vault);
        _wi419AddNote(writer, 'n-419-vec');
        _wi419CreateVectorTables(writer);
        expect(db.hasTables(const ['content_revision']), isTrue);

        final before = db.dataVersion();
        final nBefore = _wi419ContentRevision(writer);

        _wi419InsertVector(writer, 'C-419-A');
        _wi419InsertVector(writer, 'C-419-B');
        expect(
          db.dataVersion(),
          before,
          reason: 'chunk_vec inserts by another connection',
        );

        _wi419DeleteVector(writer, 'C-419-A');
        expect(db.dataVersion(), before, reason: 'a chunk_vec orphan delete');
        expect(
          writer
              .select('SELECT COUNT(*) AS c FROM chunk_vec_rowids')
              .first['c'],
          1,
          reason: 'the vector writes are committed',
        );
        expect(_wi419ContentRevision(writer), nBefore);

        // Control: a content write after them still shows.
        _wi419SaveNote(writer, 'n-419-vec', 1);
        final after = db.dataVersion();
        expect(after, isNot(before));
        expect(_wi419Suffix(after), '${_wi419ContentRevision(writer)}');
      },
    );

    test(
      'on a V7 vault a note save by another connection changes dataVersion to the handle id and content_revision n',
      () {
        final vault = _tempVault();
        final db = _open(vault);
        final writer = _writer(vault);

        final fresh = db.dataVersion();
        expect(
          _wi419Suffix(fresh),
          '${_wi419ContentRevision(writer)}',
          reason: '<handle instance id>-<content_revision.n> on a fresh vault',
        );
        final handleId = _wi419HandleId(fresh);
        expect(handleId, isNotEmpty);

        _wi419AddNote(writer, 'n-419-save');
        final seen = <String>{fresh};
        for (var round = 1; round <= 3; round++) {
          _wi419SaveNote(writer, 'n-419-save', round);
          final value = db.dataVersion();
          expect(seen, isNot(contains(value)), reason: 'save $round: $seen');
          seen.add(value);
          expect(
            value,
            '$handleId-${_wi419ContentRevision(writer)}',
            reason: 'save $round',
          );
          expect(db.dataVersion(), value, reason: 'stable until the next save');
        }
      },
    );

    test(
      'on FakeVaultDb.v6Only dataVersion falls back to the data_version form and changes after another connection commits',
      () {
        // The in-memory V6 vault itself.
        final fake = FakeVaultDb.v6Only();
        addTearDown(fake.close);
        expect(fake.contentRevisionForTest, isNull);
        expect(_wi419Suffix(fake.dataVersion()), '${_pragmaDataVersion(fake)}');

        // The same V6 database as a file, with a second connection writing.
        final vault = _wi419TempV6Vault();
        final db = _open(vault);
        final writer = _writer(vault);
        expect(db.hasTables(const ['content_revision']), isFalse);

        final before = db.dataVersion();
        expect(_wi419Suffix(before), '${_pragmaDataVersion(db)}');
        _commitNote(writer);
        final afterOne = db.dataVersion();
        expect(afterOne, isNot(before));
        expect(_wi419Suffix(afterOne), '${_pragmaDataVersion(db)}');
        expect(_wi419HandleId(afterOne), _wi419HandleId(before));

        _commitNote(writer);
        final afterTwo = db.dataVersion();
        expect(afterTwo, isNot(afterOne));
        expect(_wi419Suffix(afterTwo), '${_pragmaDataVersion(db)}');
        expect(db.dataVersion(), afterTwo, reason: 'stable with no write');
      },
    );

    test(
      'a v6Only handle switches to the content_revision form once the vault reaches V7 because every call checks',
      () {
        final fake = FakeVaultDb.v6Only();
        addTearDown(fake.close);
        final first = fake.dataVersion();
        expect(_wi419Suffix(first), '${_pragmaDataVersion(fake)}');
        expect(fake.dataVersion(), first, reason: 'a second V6 read');

        // The CLI migrates the vault while this handle stays open.
        fake.migrateToV6();
        expect(fake.hasTables(const ['content_revision']), isTrue);
        for (var i = 0; i < 3; i++) {
          fake.seedNote(
            id: 'n-419-mig-$i',
            title: 'Migrated $i',
            tags: ['t$i'],
          );
        }
        final n = fake.contentRevisionForTest!;
        expect(
          n,
          isNot(_pragmaDataVersion(fake)),
          reason: 'fixture: n and data_version tell the two forms apart',
        );

        expect(fake.dataVersion(), '${_wi419HandleId(first)}-$n');
      },
    );

    test(
      'two VaultDb handles on one V7 vault return different values with the same content_revision n',
      () {
        final vault = _tempVault();
        final a = _open(vault);
        final b = _open(vault);
        final writer = _writer(vault);

        final a0 = a.dataVersion();
        final b0 = b.dataVersion();
        expect(a0, isNot(b0), reason: 'two handles, nothing written');
        final n0 = '${_wi419ContentRevision(writer)}';
        expect([_wi419Suffix(a0), _wi419Suffix(b0)], [n0, n0]);

        _wi419AddNote(writer, 'n-419-two');
        _wi419SaveNote(writer, 'n-419-two', 1);
        final a1 = a.dataVersion();
        final b1 = b.dataVersion();
        expect(a1, isNot(b1), reason: 'two handles after a write');
        final n1 = '${_wi419ContentRevision(writer)}';
        expect([_wi419Suffix(a1), _wi419Suffix(b1)], [n1, n1]);
        expect(_wi419HandleId(a1), _wi419HandleId(a0));
        expect(_wi419HandleId(b1), _wi419HandleId(b0));
      },
    );

    test(
      'a new learned word by another connection changes dataVersion and the same word again does not',
      () {
        final vault = _tempVault();
        final db = _open(vault);
        final writer = _writer(vault);
        void learn(String word) => writer.execute(
          'INSERT INTO learned_words (word_key, word, created_at) '
          'VALUES (?, ?, ?) ON CONFLICT(word_key) DO NOTHING',
          [word.toLowerCase(), word, 1759500000000],
        );

        final before = db.dataVersion();
        learn('Zettel');
        final learned = db.dataVersion();
        expect(learned, isNot(before));
        expect(_wi419Suffix(learned), '${_wi419ContentRevision(writer)}');

        learn('zettel');
        expect(db.dataVersion(), learned, reason: 'ON CONFLICT DO NOTHING');
      },
    );

    test(
      'an agent_activity write by another connection changes dataVersion',
      () {
        final vault = _tempVault();
        final db = _open(vault);
        final writer = _writer(vault);

        final before = db.dataVersion();
        writer.execute(
          'INSERT INTO agent_activity (id, session_id, client_name, tool, '
          'summary, note_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
          ['a-419', 's-419', 'Claude', 'create_note', 'made a note', null, 1],
        );
        final after = db.dataVersion();
        expect(after, isNot(before));
        expect(_wi419Suffix(after), '${_wi419ContentRevision(writer)}');
      },
    );

    test(
      'dataVersion leaves the handle outside any transaction on V7 and V6',
      () {
        final v7 = _open(_tempVault());
        final v6 = _open(_wi419TempV6Vault());
        for (final db in [v7, v6]) {
          expect(db.db.autocommit, isTrue);
          db.dataVersion();
          expect(
            db.db.autocommit,
            isTrue,
            reason: 'no read transaction left open',
          );
        }
      },
    );
  });
}
