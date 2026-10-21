// WI #78 (W2) AC6, AC9: `EditorController.serverChanged` reads the stored
// note through `VaultAccess` and is async (`Future<bool>`, D15). It applies a
// foreign version to a clean open note, returns false for the editor's own
// saved version (D16: no echo suppression elsewhere), and never applies a
// read that finishes after a note switch or while the person types.
// `vaultDbProvider` is null: only the notes domain holds the note.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _noteId = '01J9SERVER00000000000000078';
const _otherId = '01J9SWITCH00000000000000078';

class _Ed {
  _Ed(this.c, this.doubles, this.db, this.clock);
  final ProviderContainer c;
  final EditorVaultDoubles doubles;
  final FakeVaultDb db;
  final FakeClock clock;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  Note stored(String id) => db.getNote(id)!;

  /// A foreign writer stores [body] at [version] for [_noteId].
  void foreignWrite(String body, int version) => db.db.execute(
    'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
    [body, version, _noteId],
  );
}

Future<_Ed> _editor() async {
  final dir = await Directory.systemTemp.createTemp('om78_server');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _noteId, title: 'Shared', content: 'mine', version: 3)
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 1);
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
      editorSingleVaultOverride(doubles),
    ],
  );
  addTearDown(() {
    c.dispose();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(vaultAccessProvider);
  final e = _Ed(c, doubles, db, clock);
  e.ctrl.loadNote(e.stored(_noteId));
  return e;
}

void main() {
  group('serverChanged through VaultAccess (AC6)', () {
    test(
      'a clean open note whose stored version changed elsewhere takes the stored body and version through serverChanged',
      () async {
        final e = await _editor();
        e.foreignWrite('foreign body', 5);

        final Future<bool> pending = e.ctrl.serverChanged(_noteId);
        final changed = await pending;

        expect(changed, isTrue);
        expect(e.doubles.notes.reads, contains('getNote:$_noteId'));
        expect(e.state.contentMd, 'foreign body');
        expect(e.state.lastSavedVersion, 5);
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'serverChanged returns false for the editor own saved version',
      () async {
        final e = await _editor();
        e.ctrl.onContentChanged('saved by me');
        e.clock.advance(saveDebounce);
        await pumpEventQueue();
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 4);

        final changed = await e.ctrl.serverChanged(_noteId);

        expect(changed, isFalse);
        expect(e.doubles.notes.reads, contains('getNote:$_noteId'));
        expect(e.state.contentMd, 'saved by me');
        expect(e.state.lastSavedVersion, 4);
      },
    );

    test(
      'serverChanged returns false for the version the editor loaded',
      () async {
        final e = await _editor();

        expect(await e.ctrl.serverChanged(_noteId), isFalse);
        expect(e.state.contentMd, 'mine');
      },
    );

    test(
      'serverChanged returns false for a note the editor does not show',
      () async {
        final e = await _editor();
        e.db.db.execute('UPDATE notes SET version = 9 WHERE id = ?', [
          _otherId,
        ]);

        expect(await e.ctrl.serverChanged(_otherId), isFalse);
        expect(e.state.contentMd, 'mine');
        expect(e.state.lastSavedVersion, 3);
      },
    );

    test(
      'a dirty editor keeps its text when serverChanged sees a foreign version',
      () async {
        final e = await _editor();
        e.ctrl.onContentChanged('typing');
        e.foreignWrite('foreign body', 5);

        final changed = await e.ctrl.serverChanged(_noteId);

        expect(changed, isTrue);
        expect(e.state.contentMd, 'typing');
        expect(e.state.status, SaveStatus.dirty);
        expect(e.state.lastSavedVersion, 3, reason: 'the next save conflicts');
      },
    );
  });

  group('serverChanged in-flight read (AC9, architect risk)', () {
    test(
      'a note switch while serverChanged reads never applies the read to the new note',
      () async {
        final e = await _editor();
        e.foreignWrite('foreign body', 5);
        e.doubles.hold();

        final pending = e.ctrl.serverChanged(_noteId);
        await pumpEventQueue();
        expect(e.doubles.notes.gate.waiting, 1);
        e.ctrl.loadNote(e.stored(_otherId));
        e.doubles.release();

        expect(await pending, isFalse);
        expect(e.state.title, 'Other');
        expect(e.state.contentMd, 'other body');
        expect(e.state.lastSavedVersion, 1);
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test('text typed while serverChanged reads is kept', () async {
      final e = await _editor();
      e.foreignWrite('foreign body', 5);
      e.doubles.hold();

      final pending = e.ctrl.serverChanged(_noteId);
      await pumpEventQueue();
      expect(e.doubles.notes.gate.waiting, 1);
      e.ctrl.onContentChanged('typed meanwhile');
      e.doubles.release();
      await pending;

      expect(e.state.contentMd, 'typed meanwhile');
      expect(e.state.status, SaveStatus.dirty);
      expect(e.state.lastSavedVersion, 3);
    });
  });
}
