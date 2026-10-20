// WI #70 (W0a) AC7: VaultDb.dataVersion() and the local revision on a real
// temp SQLite vault (D9 local half, Req 22). The app's handle is read-only;
// a second connection stands in for the CLI's writes.
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

void main() {
  test(
    'dataVersion is the handle id and PRAGMA data_version and is unchanged when nothing is written',
    () {
      final vault = _tempVault();
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
}
