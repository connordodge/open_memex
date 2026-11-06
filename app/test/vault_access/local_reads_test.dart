// WI #70 (W0a) AC1: every local read returns exactly what the matching
// VaultDb method returns on the same database (D13).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show requiredVaultSchemaVersion;
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_access_reads.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-70-vault';

FakeVaultDb _seeded() {
  final db = seedVaultAccessFixture(FakeVaultDb.v5());
  addTearDown(db.close);
  return db;
}

void main() {
  test(
    'every local read returns what the matching VaultDb method returns',
    () async {
      final db = _seeded();
      final cli = FakeMemexCli();
      final access = LocalVaultAccess(vaultPath: _vault, db: db, cli: cli);

      for (final c in vaultAccessReadCases) {
        final expected = vaultAccessShape(c.viaDb(db));
        if (c.emptyShape != unpinnedWithoutDb) {
          // Fixture sanity: the read must see seeded data, or the comparison
          // would pass on an empty stub.
          expect(expected, isNot(equals(c.emptyShape)), reason: c.name);
        }
        expect(
          vaultAccessShape(await c.viaAccess(access)),
          equals(expected),
          reason: c.name,
        );
      }
      // Reads never shell out.
      expect(cli.calls, isEmpty);
    },
  );

  test('local linksInFor with and without kind matches VaultDb', () async {
    final db = _seeded();
    final access = LocalVaultAccess(vaultPath: _vault, db: db);

    for (final noteId in ['day-0905', 'topic-delta', 'topic-alpha']) {
      expect(
        vaultAccessShape(await access.notes.linksInFor(noteId)),
        equals(vaultAccessShape(db.linksInFor(noteId))),
        reason: noteId,
      );
      for (final kind in ['from-day', 'references', 'contradicts', 'about']) {
        expect(
          vaultAccessShape(await access.notes.linksInFor(noteId, kind: kind)),
          equals(vaultAccessShape(db.linksInFor(noteId, kind: kind))),
          reason: '$noteId kind $kind',
        );
      }
    }
    // Without kind returns more than any single kind (the filter is real).
    expect(
      (await access.notes.linksInFor('day-0905')).length,
      greaterThan(
        (await access.notes.linksInFor('day-0905', kind: 'from-day')).length,
      ),
    );
  });

  test('local schemaVersion matches VaultDb on a V4 and a V5 vault', () async {
    final v4 = FakeVaultDb.v4();
    addTearDown(v4.close);
    final v5 = FakeVaultDb.v5()
      ..addSchemaVersion(requiredVaultSchemaVersion + 1);
    addTearDown(v5.close);

    expect(
      await LocalVaultAccess(vaultPath: _vault, db: v4).schemaVersion(),
      v4.schemaVersion(),
    );
    expect(v4.schemaVersion(), 4);
    expect(
      await LocalVaultAccess(vaultPath: _vault, db: v5).schemaVersion(),
      requiredVaultSchemaVersion + 1,
    );
  });

  test('local V5 reads on a V4 vault return what VaultDb returns', () async {
    final db = FakeVaultDb.v4();
    addTearDown(db.close);
    db.seedNote(id: 'n1', title: 'Only note');
    final access = LocalVaultAccess(vaultPath: _vault, db: db);

    expect(
      vaultAccessShape(await access.notes.listNotes()),
      equals(vaultAccessShape(db.listNotes())),
    );
    expect(await access.notes.listNotes(), isNotEmpty);
    for (final c in vaultAccessReadCases) {
      expect(
        vaultAccessShape(await c.viaAccess(access)),
        equals(vaultAccessShape(c.viaDb(db))),
        reason: c.name,
      );
    }
  });

  // One test per read for diagnostics (D13: every local method is tested).
  for (final c in vaultAccessReadCases) {
    test('local ${c.name} matches VaultDb', () async {
      final db = _seeded();
      final access = LocalVaultAccess(vaultPath: _vault, db: db);
      expect(
        vaultAccessShape(await c.viaAccess(access)),
        equals(vaultAccessShape(c.viaDb(db))),
      );
    });
  }
}
