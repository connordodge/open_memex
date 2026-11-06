// WI #249 (A3): LocalTagsAccess and its place on LocalVaultAccess (D21).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/tags_seed.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-249-vault';
const _note = '01J9V6000000000000000000A1';

class _DoubleTags extends LocalTagsAccess {
  _DoubleTags() : super(vaultPath: _vault);

  @override
  Future<List<TagRow>> allTags() async => const [
    TagRow(tag: 'from-double', noteCount: 1, system: false),
  ];
}

FakeVaultDb _seeded() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  db.seedNote(id: _note, title: 'Plan', updatedAt: 2000);
  db.seedTag(_note, 'work', origin: 'body', firstLine: 'a #work line');
  db.seedTag(_note, 'by-agent', origin: 'agent');
  return db;
}

void main() {
  test(
    'LocalTagsAccess reads the database and is empty with no handle',
    () async {
      final db = _seeded();
      final access = LocalTagsAccess(vaultPath: _vault, db: db);

      expect(
        vaultAccessShape(await access.allTags()),
        vaultAccessShape(db.allTags()),
      );
      expect(await access.allTags(), hasLength(2));
      expect(
        vaultAccessShape(await access.notesForTag('work')),
        vaultAccessShape(db.notesForTag('work')),
      );
      expect(
        (await access.notesForTag('work')).single.firstLine,
        'a #work line',
      );

      final none = LocalTagsAccess(vaultPath: _vault);
      expect(await none.allTags(), isEmpty);
      expect(await none.notesForTag('work'), isEmpty);
    },
  );

  test('LocalTagsAccess removeTag runs memex tag rm on its vault', () async {
    final cli = FakeMemexCli()
      ..on(
        'tag rm',
        (_) => FakeMemexCli.ok(
          '{"note_id":"$_note","tag":"by-agent","removed":true,'
          '"correction_id":4,"version":9}\n',
        ),
      );
    final access = LocalTagsAccess(vaultPath: _vault, cli: cli);

    final r = await access.removeTag(_note, 'by-agent');

    expect(cli.callsFor('tag rm'), hasLength(1));
    final call = cli.callsFor('tag rm').single;
    expect(call.flag('vault'), _vault);
    expect(call.flag('note-id'), _note);
    expect(call.flag('tag'), 'by-agent');
    expect(r.removed, isTrue);
    expect(r.correctionId, 4);
    expect(r.version, 9);
  });

  test(
    'LocalTagsAccess removeTag with no CLI throws StateError and runs nothing',
    () async {
      final db = _seeded();
      final access = LocalVaultAccess(vaultPath: _vault, db: db);

      expect(access.canWrite, isFalse);
      await expectLater(
        access.tags.removeTag(_note, 'by-agent'),
        throwsStateError,
      );
      expect(db.getNote(_note)!.tags, contains('by-agent'));
    },
  );

  test('a failed LocalTagsAccess removeTag surfaces the CLI error', () async {
    final cli = FakeMemexCli()
      ..on(
        'tag rm',
        (_) => FakeMemexCli.error('not_found', 'no such note', {'id': _note}),
      );
    final access = LocalTagsAccess(vaultPath: _vault, cli: cli);

    await expectLater(
      access.removeTag(_note, 'by-agent'),
      throwsA(
        isA<MemexException>().having((e) => e.code, 'code', 'not_found').having(
          (e) => e.fields,
          'fields',
          {'id': _note},
        ),
      ),
    );
  });

  test('LocalNotesAccess getNote carries the stored footerTags', () async {
    final db = _seeded();
    final access = LocalVaultAccess(vaultPath: _vault, db: db);

    final note = await access.notes.getNote(_note);

    expect(note!.tags, ['by-agent', 'work']);
    expect(note.footerTags, ['by-agent']);
  });

  test(
    'LocalVaultAccess builds tags over its database and CLI and takes a double in its place',
    () async {
      final db = _seeded();
      final cli = FakeMemexCli()
        ..on(
          'tag rm',
          (_) => FakeMemexCli.ok(
            '{"note_id":"$_note","tag":"t","removed":false,'
            '"correction_id":null,"version":2}\n',
          ),
        );
      final access = LocalVaultAccess(vaultPath: _vault, db: db, cli: cli);

      expect(await access.tags.allTags(), hasLength(2));
      expect((await access.tags.removeTag(_note, 't')).version, 2);
      expect(cli.callsFor('tag rm'), hasLength(1));
      expect(cli.callsFor('tag rm').single.flag('vault'), _vault);

      final withDouble = LocalVaultAccess(
        vaultPath: _vault,
        db: db,
        tags: _DoubleTags(),
      );
      expect((await withDouble.tags.allTags()).single.tag, 'from-double');
    },
  );
}
