// WI #78 (W2) AC4, AC5: the note providers read through the `notes` domain
// (D13) and keep synchronous facades (D14a): previous value during a
// same-vault reload, today's empty value before the first load, with no
// vault, and whenever the loaded vault is not the open one.
//
// `vaultDbProvider` is null in every container here, so a facade that still
// read SQLite directly would always be empty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_vault_db.dart';

const _vaultA = '/tmp/om-78-vault-a';
const _vaultB = '/tmp/om-78-vault-b';
const _noteId = '01J9NOTE00000000000000000A';

FakeVaultDb _db() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

void _seedLink(FakeVaultDb db, String from, String to, String kind, int at) {
  db.db.execute(
    'INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, '
    'position, source) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ['l-$from-$at', from, to, to, kind, at, 'inline_body'],
  );
}

/// Vault A: note [_noteId] "Alpha title" plus "Alpha other", one `supports`
/// link. Vault B: the same note id titled "Beta title", one `refutes` link.
({FakeVaultDb a, FakeVaultDb b}) _twoVaults() {
  final a = _db()
    ..seedNote(id: _noteId, title: 'Alpha title', content: 'alpha body')
    ..seedNote(id: 'a-other', title: 'Alpha other', updatedAt: 1759500000001);
  _seedLink(a, _noteId, 'a-other', 'supports', 0);
  final b = _db()
    ..seedNote(id: _noteId, title: 'Beta title', content: 'beta body')
    ..seedNote(id: 'b-other', title: 'Beta other', updatedAt: 1759500000001);
  _seedLink(b, _noteId, 'b-other', 'refutes', 0);
  return (a: a, b: b);
}

class _Vaults {
  _Vaults(this.c, this.a, this.b);
  final ProviderContainer c;
  final EditorVaultDoubles a;
  final EditorVaultDoubles b;

  void open(String? path) => c.read(currentVaultProvider.notifier).state =
      path == null ? null : LocalVaultRef(path);

  void bump() => c.read(vaultRevisionProvider.notifier).state++;
}

_Vaults _container({String? open = _vaultA, String? selected = _noteId}) {
  final dbs = _twoVaults();
  final a = EditorVaultDoubles(notesDb: dbs.a, dailyDb: dbs.a);
  final b = EditorVaultDoubles(notesDb: dbs.b, dailyDb: dbs.b);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => open == null ? null : LocalVaultRef(open),
      ),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      editorAccessOverride({_vaultA: a, _vaultB: b}),
    ],
  );
  addTearDown(c.dispose);
  c.read(selectedNoteIdProvider.notifier).state = selected;
  return _Vaults(c, a, b);
}

List<String> _titles(List<NoteTitle> rows) => [for (final r in rows) r.title];

void main() {
  group('note providers read through the notes domain (AC4)', () {
    test(
      'selectedNoteProvider reads the selected note through the notes domain',
      () async {
        final v = _container();

        final note = await settled(v.c, selectedNoteProvider);

        expect(note, isNotNull);
        expect(note!.id, _noteId);
        expect(note.title, 'Alpha title');
        expect(note.contentMd, 'alpha body');
        expect(v.a.notes.reads, contains('getNote:$_noteId'));
      },
    );

    test(
      'noteTitlesProvider and linkKindsProvider read through the notes domain',
      () async {
        final v = _container();

        final titles = await settled(v.c, noteTitlesProvider);
        final kinds = await settled(v.c, linkKindsProvider);

        expect(
          _titles(titles),
          unorderedEquals(['Alpha title', 'Alpha other']),
        );
        expect(kinds, ['supports']);
        expect(
          v.a.notes.reads,
          containsAll(['allTitles', 'distinctLinkKinds']),
        );
      },
    );

    test(
      'the async note providers yield the rows stamped with the vault they were loaded for',
      () async {
        final v = _container();

        final note = await v.c.read(selectedNoteAsyncProvider.future);
        final titles = await v.c.read(noteTitlesAsyncProvider.future);
        final kinds = await v.c.read(linkKindsAsyncProvider.future);

        expect(note.vault, const LocalVaultRef(_vaultA));
        expect(note.value!.title, 'Alpha title');
        expect(titles.vault, const LocalVaultRef(_vaultA));
        expect(_titles(titles.value), contains('Alpha other'));
        expect(kinds.vault, const LocalVaultRef(_vaultA));
        expect(kinds.value, ['supports']);
      },
    );

    test(
      'the note facades are empty before the first notes read completes',
      () async {
        final v = _container();
        v.a.holdFromStart = true;
        final note = v.c.listen(selectedNoteProvider, (_, _) {});
        final titles = v.c.listen(noteTitlesProvider, (_, _) {});
        final kinds = v.c.listen(linkKindsProvider, (_, _) {});
        await pumpEventQueue();

        expect(v.a.notes.gate.waiting, greaterThan(0));
        expect(note.read(), isNull);
        expect(titles.read(), isEmpty);
        expect(kinds.read(), isEmpty);

        v.a.release();
        await pumpEventQueue();

        expect(note.read()!.title, 'Alpha title');
        expect(_titles(titles.read()), contains('Alpha title'));
        expect(kinds.read(), ['supports']);
      },
    );

    test('the note facades are empty with no vault open', () async {
      final v = _container(open: null);

      expect(await settled(v.c, selectedNoteProvider), isNull);
      expect(await settled(v.c, noteTitlesProvider), isEmpty);
      expect(await settled(v.c, linkKindsProvider), isEmpty);
    });

    test('selectedNoteProvider is null with no note selected', () async {
      final v = _container(selected: null);

      expect(await settled(v.c, selectedNoteProvider), isNull);
      expect(v.a.noteReads.where((r) => r.startsWith('getNote')), isEmpty);
    });
  });

  group('same-vault reload keeps the previous value (AC4)', () {
    test(
      'on a revision bump the note facades keep their previous values until the new read completes',
      () async {
        final v = _container();
        final note = v.c.listen(selectedNoteProvider, (_, _) {});
        final titles = v.c.listen(noteTitlesProvider, (_, _) {});
        final kinds = v.c.listen(linkKindsProvider, (_, _) {});
        await pumpEventQueue();
        expect(note.read()!.title, 'Alpha title');

        final db = v.a.notesDb! as FakeVaultDb;
        db.db.execute('UPDATE notes SET title = ? WHERE id = ?', [
          'Alpha renamed',
          _noteId,
        ]);
        _seedLink(db, 'a-other', _noteId, 'extends', 1);
        v.a.hold();
        v.bump();
        await pumpEventQueue();

        expect(v.a.notes.gate.waiting, greaterThan(0));
        expect(note.read()!.title, 'Alpha title');
        expect(_titles(titles.read()), contains('Alpha title'));
        expect(kinds.read(), ['supports']);

        v.a.release();
        await pumpEventQueue();

        expect(note.read()!.title, 'Alpha renamed');
        expect(_titles(titles.read()), contains('Alpha renamed'));
        expect(kinds.read(), ['extends', 'supports']);
      },
    );
  });

  group('switching vaults (AC5, D14a)', () {
    test(
      'switching vaults never shows the previous vault rows in selectedNoteProvider',
      () async {
        final v = _container();
        final note = v.c.listen(selectedNoteProvider, (_, _) {});
        await pumpEventQueue();
        expect(note.read()!.title, 'Alpha title');

        v.b.holdFromStart = true;
        v.open(_vaultB);
        await pumpEventQueue();

        expect(note.read(), isNull, reason: 'B is still loading');

        v.b.release();
        await pumpEventQueue();
        expect(note.read()!.title, 'Beta title');
      },
    );

    test(
      'switching vaults never shows the previous vault rows in noteTitlesProvider',
      () async {
        final v = _container();
        final titles = v.c.listen(noteTitlesProvider, (_, _) {});
        await pumpEventQueue();
        expect(_titles(titles.read()), contains('Alpha other'));

        v.b.holdFromStart = true;
        v.open(_vaultB);
        await pumpEventQueue();

        expect(titles.read(), isEmpty, reason: 'B is still loading');

        v.b.release();
        await pumpEventQueue();
        expect(
          _titles(titles.read()),
          unorderedEquals(['Beta title', 'Beta other']),
        );
      },
    );

    test(
      'switching vaults never shows the previous vault rows in linkKindsProvider',
      () async {
        final v = _container();
        final kinds = v.c.listen(linkKindsProvider, (_, _) {});
        await pumpEventQueue();
        expect(kinds.read(), ['supports']);

        v.b.holdFromStart = true;
        v.open(_vaultB);
        await pumpEventQueue();

        expect(kinds.read(), isEmpty, reason: 'B is still loading');

        v.b.release();
        await pumpEventQueue();
        expect(kinds.read(), ['refutes']);
      },
    );

    test(
      'switching back to a vault never shows the other vault rows while it reloads',
      () async {
        final v = _container();
        final note = v.c.listen(selectedNoteProvider, (_, _) {});
        await pumpEventQueue();
        v.open(_vaultB);
        await pumpEventQueue();
        expect(note.read()!.title, 'Beta title');

        v.a.hold();
        v.open(_vaultA);
        await pumpEventQueue();

        expect(note.read(), isNull, reason: 'A is reloading; B must not show');

        v.a.release();
        await pumpEventQueue();
        expect(note.read()!.title, 'Alpha title');
      },
    );

    test('closing the vault empties the note facades at once', () async {
      final v = _container();
      final note = v.c.listen(selectedNoteProvider, (_, _) {});
      final titles = v.c.listen(noteTitlesProvider, (_, _) {});
      await pumpEventQueue();
      expect(note.read(), isNotNull);

      v.open(null);

      expect(note.read(), isNull);
      expect(titles.read(), isEmpty);
    });
  });
}
