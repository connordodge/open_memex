// WI #360 (Spec #357 Req 28.4, TD3a): `EditorController.savesSettled(vault)`
// completes once nothing more of the editor will write into [vault]: every
// save of that vault in flight has landed, and so has a save held back
// behind one (the flushed save of `flushPendingSave`). Saves of another
// vault don't hold it. A failed save settles too. Seams: the recording
// notes/daily doubles over a FakeVaultDb, a FakeMemexCli whose `update`
// waits on a gate per call, and a FakeClock for the save debounce.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _noteA = '01J9NOTEA00000000000000360A';
const _noteB = '01J9NOTEB00000000000000360B';
const _today = '2026-11-10';

/// `memex update` calls that wait, one gate per call, until the test lets
/// them through; then it writes like the real `memex update` (version + 1)
/// or, with [fail], answers a C1 error.
class _Wi360HeldUpdates {
  _Wi360HeldUpdates(this.db);

  final FakeVaultDb db;
  final List<Completer<void>> gates = [];
  final List<String> bodies = [];
  bool fail = false;

  void install(FakeMemexCli cli) {
    cli.on('update', (call) async {
      final gate = Completer<void>();
      gates.add(gate);
      bodies.add(call.stdinBody ?? '');
      await gate.future;
      if (fail) return FakeMemexCli.error('io', 'disk full');
      final id = call.flag('note-id')!;
      final version =
          (db.db.select('SELECT version FROM notes WHERE id = ?', [
                    id,
                  ]).single['version']
                  as num)
              .toInt();
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
        [call.stdinBody ?? '', version + 1, id],
      );
      return FakeMemexCli.ok(
        jsonEncode({
          'vault_id': '01HV0000000000000000000000',
          'note_id': id,
          'version': version + 1,
          'updated_at': 1759478400000,
        }),
      );
    });
  }

  /// Lets update call [i] (0-based, in send order) through.
  Future<void> release(int i) async {
    gates[i].complete();
    await pumpEventQueue();
  }
}

class _Wi360Ed {
  _Wi360Ed(this.c, this.db, this.cli, this.clock, this.updates, this.a, this.b);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;
  final _Wi360HeldUpdates updates;

  /// Two local vaults; [a] is open first.
  final LocalVaultRef a;
  final LocalVaultRef b;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);

  /// Types [text] into the open note and fires the save debounce.
  Future<void> typeAndSave(String text) async {
    ctrl.onContentChanged(text);
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }

  /// [savesSettled] for [vault] as a flag the test can read.
  ({bool Function() done}) watch(VaultRef vault) {
    var done = false;
    unawaited(ctrl.savesSettled(vault).then((_) => done = true));
    return (done: () => done);
  }
}

Future<_Wi360Ed> _wi360Editor() async {
  final dirA = await Directory.systemTemp.createTemp('om360_ed_a');
  final dirB = await Directory.systemTemp.createTemp('om360_ed_b');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _noteA, title: 'Alpha', content: 'old', version: 3)
    ..seedNote(id: _noteB, title: 'Bravo', content: 'old b', version: 7);
  final cli = FakeMemexCli();
  final updates = _Wi360HeldUpdates(db)..install(cli);
  final clock = FakeClock(DateTime(2026, 11, 10, 9));
  final a = LocalVaultRef(dirA.path);
  final b = LocalVaultRef(dirB.path);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => a),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
      editorAccessOverride({
        dirA.path: EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli),
        dirB.path: EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli),
      }),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    // Let any save still waiting go, so nothing is left pending.
    for (final g in updates.gates) {
      if (!g.isCompleted) g.complete();
    }
    await pumpEventQueue();
    c.dispose();
    await store.flush();
    db.close();
    for (final d in [dirA, dirB]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });
  c.listen(tabsProvider, (_, _) {});
  c.listen(editorControllerProvider, (_, _) {});
  await pumpEventQueue();
  return _Wi360Ed(c, db, cli, clock, updates, a, b);
}

void main() {
  test(
    'savesSettled waits for a save of the vault in flight and completes when it lands',
    () async {
      final e = await _wi360Editor();
      e.ctrl.loadNote(e.db.getNote(_noteA));
      final idle = e.watch(e.a);
      await pumpEventQueue();
      expect(idle.done(), isTrue, reason: 'nothing in flight yet');

      await e.typeAndSave('typed in alpha');
      expect(e.updates.gates, hasLength(1), reason: 'the save is in flight');

      final w = e.watch(e.a);
      await pumpEventQueue();
      expect(w.done(), isFalse, reason: 'the save has not landed');

      await e.updates.release(0);
      expect(w.done(), isTrue);
      expect(e.db.getNote(_noteA)!.contentMd, 'typed in alpha');
    },
  );

  test('savesSettled completes when the save in flight fails', () async {
    final e = await _wi360Editor();
    e.updates.fail = true;
    e.ctrl.loadNote(e.db.getNote(_noteA));
    await e.typeAndSave('typed then failed');

    final w = e.watch(e.a);
    await pumpEventQueue();
    expect(w.done(), isFalse);

    await e.updates.release(0);
    expect(w.done(), isTrue, reason: 'a failed save writes nothing more');
    expect(e.state.status, SaveStatus.error);
  });

  test(
    'savesSettled waits for the flushed save held back behind a save in flight',
    () async {
      final e = await _wi360Editor();
      e.ctrl.loadNote(e.db.getNote(_noteA));
      await e.typeAndSave('first');
      expect(e.updates.gates, hasLength(1));
      // More text, then the flush (as the open-vault delete does): the
      // flushed save waits for the first one.
      e.ctrl.onContentChanged('first and second');
      e.ctrl.flushPendingSave();
      await pumpEventQueue();
      expect(e.updates.gates, hasLength(1), reason: 'the second save waits');

      final w = e.watch(e.a);
      await pumpEventQueue();
      expect(w.done(), isFalse);

      await e.updates.release(0);
      expect(
        e.updates.gates,
        hasLength(2),
        reason: 'the held-back save goes once the first landed',
      );
      expect(
        w.done(),
        isFalse,
        reason: 'the held-back save still writes into the vault',
      );

      await e.updates.release(1);
      expect(w.done(), isTrue);
      expect(e.updates.bodies, ['first', 'first and second']);
      expect(e.db.getNote(_noteA)!.contentMd, 'first and second');
    },
  );

  test(
    'savesSettled waits for a save sent after the vault closed and ignores saves of another vault',
    () async {
      final e = await _wi360Editor();
      e.ctrl.loadNote(e.db.getNote(_noteA));
      e.ctrl.onContentChanged('alpha text');
      // The open-vault delete: flush, then close the vault at once.
      e.ctrl.flushPendingSave();
      e.c.read(currentVaultProvider.notifier).state = null;
      await pumpEventQueue();
      expect(e.updates.gates, hasLength(1), reason: 'the flushed save went');

      final closed = e.watch(e.a);
      await pumpEventQueue();
      expect(closed.done(), isFalse);

      // Another vault opens and saves; it holds only its own vault.
      e.c.read(currentVaultProvider.notifier).state = e.b;
      await pumpEventQueue();
      e.ctrl.loadNote(e.db.getNote(_noteB));
      await e.typeAndSave('bravo text');
      expect(e.updates.gates, hasLength(2));

      final other = e.watch(e.b);
      await pumpEventQueue();
      expect(other.done(), isFalse);

      await e.updates.release(0);
      expect(closed.done(), isTrue, reason: 'vault a has nothing in flight');
      expect(other.done(), isFalse, reason: 'vault b still has its save');

      await e.updates.release(1);
      expect(other.done(), isTrue);
    },
  );

  test(
    'savesSettled wakes every waiter when the controller is disposed and completes at once afterwards',
    () async {
      final e = await _wi360Editor();
      e.ctrl.loadNote(e.db.getNote(_noteA));
      await e.typeAndSave('typed in alpha');
      expect(e.updates.gates, hasLength(1), reason: 'the save is in flight');
      final old = e.ctrl;
      final w1 = e.watch(e.a);
      final w2 = e.watch(e.b);
      final w3 = e.watch(e.a);
      await pumpEventQueue();
      expect(w1.done(), isFalse);
      expect(w3.done(), isFalse);
      expect(w2.done(), isTrue, reason: 'vault b has nothing in flight');

      e.c.invalidate(editorControllerProvider);
      await pumpEventQueue();
      // The held save is never let through: a landing save would write the
      // state of the disposed controller.
      e.updates.gates.clear();

      expect(w1.done(), isTrue, reason: 'nothing held back goes once gone');
      expect(w3.done(), isTrue);
      var after = false;
      unawaited(old.savesSettled(e.a).then((_) => after = true));
      await pumpEventQueue();
      expect(after, isTrue, reason: 'a disposed controller writes nothing');
    },
  );

  test(
    'savesSettled waits for the virtual Today create in flight and completes when it lands',
    () async {
      final e = await _wi360Editor();
      final gate = Completer<void>();
      e.cli.onAddDailyCreates(e.db, gate: gate);
      e.ctrl.loadNote(virtualTodayNote(_today));
      await e.typeAndSave('first line of today');
      expect(e.cli.callsFor('add'), hasLength(1), reason: 'the create is sent');
      expect(e.updates.gates, isEmpty, reason: 'no note exists to update yet');

      final w = e.watch(e.a);
      await pumpEventQueue();
      expect(w.done(), isFalse, reason: 'the create has not landed');

      gate.complete();
      await pumpEventQueue();
      expect(w.done(), isTrue);
      expect(e.db.getNote(createdDailyId), isNotNull, reason: 'created');
    },
  );

  test(
    'savesSettled waits for the save of a note the person left until it lands',
    () async {
      final e = await _wi360Editor();
      final gate = Completer<void>();
      e.cli.onAddDailyCreates(e.db, gate: gate);
      e.ctrl.loadNote(virtualTodayNote(_today));
      await e.typeAndSave('hi');
      expect(e.cli.callsFor('add'), hasLength(1));
      // More text while the create is in flight, then the person leaves
      // the Today note: the extra text is saved to the created note once
      // the create answers (no editor state to report to).
      e.ctrl.onContentChanged('hi there');
      e.ctrl.loadNote(e.db.getNote(_noteA));
      await pumpEventQueue();

      final w = e.watch(e.a);
      await pumpEventQueue();
      expect(w.done(), isFalse, reason: 'the create has not landed');

      gate.complete();
      await pumpEventQueue();
      expect(
        e.updates.gates,
        hasLength(1),
        reason: 'the left note is saved through update after the create',
      );
      expect(
        w.done(),
        isFalse,
        reason: 'the save of the note the person left still writes',
      );

      await e.updates.release(0);
      expect(w.done(), isTrue);
      expect(e.db.getNote(createdDailyId)!.contentMd, contains('hi there'));
    },
  );
}
