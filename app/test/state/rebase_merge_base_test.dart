// WI #16 (Spec #7 Req 34a), fix round 1: the topic actions' rebase helpers put
// the stored note on the version a write stored, and the editor records that
// text as the merge base. The base is true only when the read was at that
// version: when another writer got in between (the read is at a later
// version) or the read failed, the editor must not merge against it, or a
// merge would read the foreign change as the person's revert and drop it.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _id = '01J9REBASE000000000000016';
const _base = 'Alpha\nBravo\nCharlie\n';

class _Env {
  _Env(this.c, this.db, this.clock, this.doubles);
  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeClock clock;
  final EditorVaultDoubles doubles;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  Note get stored => db.getNote(_id)!;

  Future<void> fireDebounce() async {
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }

  /// Another writer stores [body] on the note at [version].
  void foreignWrite(String body, int version) {
    db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
      body,
      version,
      _id,
    ]);
  }
}

/// The note cannot be read (it is gone for now): a rebase falls back to its
/// own copy.
void _vanish(_Env e) =>
    e.db.db.execute('DELETE FROM notes WHERE id = ?', [_id]);

/// The note is back, as another writer left it: [body] at [version].
void _reappear(_Env e, String body, int version) => e.db.seedNote(
  id: _id,
  title: 'Plain',
  content: body,
  role: 'topic',
  version: version,
);

Future<_Env> _env() async {
  final dir = await Directory.systemTemp.createTemp('om16_rebase');
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _id,
      title: 'Plain',
      content: _base,
      role: 'topic',
      version: 3,
    );
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
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(vaultAccessProvider);
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _Env(c, db, clock, doubles);
}

void main() {
  group('rebaseEditorAfterWrite records the merge base', () {
    test(
      'a rebase on the version the write stored keeps the merge base so a later conflict merges',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        // A write (a tag, say) stored version 4 with the same text.
        final written = e.stored;
        e.foreignWrite(_base, 4);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.lastSavedVersion, 4);
        // An agent then changes line 3 behind the editor's back.
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.doubles.notes.writes.last, 'updateNote:$_id@5');
        expect(e.stored.contentMd, 'Alpha mine\nBravo\nCharlie theirs\n');
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a rebase of a clean editor whose read is at a later version forgets the merge base so a conflict is shown, not merged',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final written = e.stored;
        // The write stored version 4; an agent wrote version 5 before the
        // rebase read the note.
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 4);
        e.foreignWrite('Alpha\nBravo\nCharlie agent\n', 5);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie theirs\n');
        await e.fireDebounce();

        // The text read at version 5 is not the text at version 4: no base,
        // no merge.
        expect(e.doubles.notes.writes.last, 'updateNote:$_id@4');
        expect(e.doubles.notes.writes, hasLength(1));
        expect(e.state.status, SaveStatus.conflict);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie agent\n');
      },
    );

    test(
      'a rebase of an edited editor whose read is at a later version keeps the typed text and never merges away the other writer change',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final written = e.stored;
        const typed = 'Alpha mine\nBravo\nCharlie\n';
        e.ctrl.onContentChanged(typed);
        // The write stored version 4; an agent wrote version 5 before the
        // rebase read the note.
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.contentMd, typed);
        expect(e.state.lastSavedVersion, 4);

        await e.fireDebounce();

        // Merged against the text read at version 5 as the base, the typed
        // text would revert the agent's line and save over it.
        expect(e.doubles.notes.writes.where((w) => w.endsWith('@5')), isEmpty);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
        expect(e.state.contentMd, typed);
        expect(e.state.status, SaveStatus.conflict);
      },
    );

    test(
      'a rebase of an edited editor whose read is at the stored version keeps the merge base so a later conflict merges',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final written = e.stored;
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        e.foreignWrite(_base, 4);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.lastSavedVersion, 4);
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);

        await e.fireDebounce();

        expect(e.doubles.notes.writes.last, 'updateNote:$_id@5');
        expect(e.stored.contentMd, 'Alpha mine\nBravo\nCharlie theirs\n');
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a rebase of a clean editor whose read finds no note forgets the merge base so a conflict is shown, not merged',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final written = e.stored;
        _vanish(e);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.lastSavedVersion, 4);
        expect(e.state.contentMd, _base);
        _reappear(e, 'Alpha\nBravo\nCharlie theirs\n', 5);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.doubles.notes.writes.where((w) => w.endsWith('@5')), isEmpty);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
      },
    );

    test(
      'a rebase of an edited editor whose read finds no note forgets the merge base so a conflict is shown, not merged',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final written = e.stored;
        const typed = 'Alpha mine\nBravo\nCharlie\n';
        e.ctrl.onContentChanged(typed);
        _vanish(e);
        await rebaseEditorAfterWrite(
          e.c,
          e.c.read(vaultAccessProvider)!,
          note: written,
          version: 4,
        );
        expect(e.state.contentMd, typed);
        _reappear(e, 'Alpha\nBravo\nCharlie theirs\n', 5);

        await e.fireDebounce();

        expect(e.doubles.notes.writes.where((w) => w.endsWith('@5')), isEmpty);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
      },
    );
  });

  group('rebaseEditorOnVersionIn records the merge base', () {
    test(
      'a rebase whose read is at a later version forgets the merge base and never merges away the other writer change',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final fallback = e.stored;
        const typed = 'Alpha mine\nBravo\nCharlie\n';
        e.ctrl.onContentChanged(typed);
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);

        await rebaseEditorOnVersionIn(
          e.c,
          fallback: fallback,
          version: 4,
          content: typed,
        );
        expect(e.state.contentMd, typed);
        expect(e.state.lastSavedVersion, 4);
        await e.fireDebounce();

        expect(e.doubles.notes.writes.where((w) => w.endsWith('@5')), isEmpty);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
        expect(e.state.contentMd, typed);
        expect(e.state.status, SaveStatus.conflict);
      },
    );

    test(
      'a rebase whose read is at the stored version keeps the merge base so a later conflict merges',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final fallback = e.stored;
        e.foreignWrite(_base, 4);

        await rebaseEditorOnVersionIn(
          e.c,
          fallback: fallback,
          version: 4,
          content: 'Alpha mine\nBravo\nCharlie\n',
        );
        expect(e.state.lastSavedVersion, 4);
        e.foreignWrite('Alpha\nBravo\nCharlie theirs\n', 5);
        await e.fireDebounce();

        expect(e.doubles.notes.writes.last, 'updateNote:$_id@5');
        expect(e.stored.contentMd, 'Alpha mine\nBravo\nCharlie theirs\n');
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a rebase whose read finds no note forgets the merge base so a conflict is shown, not merged',
      () async {
        final e = await _env();
        e.ctrl.loadNote(e.stored);
        final fallback = e.stored;
        const typed = 'Alpha mine\nBravo\nCharlie\n';
        e.ctrl.onContentChanged(typed);
        _vanish(e);

        await rebaseEditorOnVersionIn(
          e.c,
          fallback: fallback,
          version: 4,
          content: typed,
        );
        expect(e.state.contentMd, typed);
        expect(e.state.lastSavedVersion, 4);
        _reappear(e, 'Alpha\nBravo\nCharlie theirs\n', 5);
        await e.fireDebounce();

        expect(e.doubles.notes.writes.where((w) => w.endsWith('@5')), isEmpty);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.stored.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
      },
    );
  });
}
