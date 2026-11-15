// WI #429 (391-A4), ruling D19: `flushThenWrite` is the one flush-then-write.
// It stores the edit waiting on the save debounce, runs the write, then reads
// the stored note and rebases the editor on it: the stored text when the
// editor still holds what was flushed, else the newer editor text. A failed
// flush writes nothing and fails with `Could not save your changes first.`
// (Spec #391 req 31), carrying the editor's save error for the guide restore.
// The semantics are the guide restore's (activity_tab.dart before #429); the
// last test pins that the guide restore now calls the helper and that no
// second copy of the flow exists in lib/.
//
// Everything runs on a real EditorController over a LocalVaultAccess with a
// FakeVaultDb and FakeMemexCli; time moves only through the FakeClock.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _wi429NoteId = '01JFLUSHTHENWRITE000000429';
const _wi429Title = 'Level design';
const _wi429Body = 'Level design notes.';
const _wi429Typed = 'Level design notes. More about pacing.';
const _wi429TypedLater = 'Level design notes. More about pacing, and loot.';

/// The version the seeded note starts at; the flush stores +1, the write +2.
const _wi429Start = 3;

class _Wi429Env {
  _Wi429Env(this.c, this.db, this.cli, this.clock);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  EditorController get editor => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  Note get note => db.getNote(_wi429NoteId)!;
  String get storedBody => note.contentMd;
  int get storedVersion => note.version;

  /// Every status the editor showed since the env started.
  final List<SaveStatus> statuses = [];

  /// How many times `vaultRevisionProvider` changed since the env started.
  int bumps = 0;

  /// A write like `add-link`: appends to the stored body (as a server-side
  /// write that the editor does not hold yet), bumps the version and returns
  /// it. Records what it saw when it ran.
  Future<int> Function() appendWrite(
    List<({String body, int updates})> seen, {
    String suffix = '\n\n## Auto-added links\n\n[[Loot tables]]\n',
    void Function()? during,
  }) => () async {
    seen.add((body: storedBody, updates: cli.callsFor('update').length));
    final next = storedVersion + 1;
    db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
      '$storedBody$suffix',
      next,
      _wi429NoteId,
    ]);
    during?.call();
    return next;
  };

  /// Lets the save debounce fire and the fake CLI answer.
  Future<void> drain() async {
    clock.advance(const Duration(seconds: 2));
    await pumpEventQueue();
  }
}

Future<_Wi429Env> _wi429Launch({
  EditorVaultDoubles Function(FakeVaultDb db, FakeMemexCli cli)? gated,
}) async {
  final dir = Directory.systemTemp.createTempSync('om429_flush');
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi429NoteId,
      title: _wi429Title,
      content: _wi429Body,
      role: 'topic',
      version: _wi429Start,
    );
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final clock = FakeClock();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
      if (gated != null) editorSingleVaultOverride(gated(db, cli)),
    ],
  );
  addTearDown(() {
    c.dispose();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final env = _Wi429Env(c, db, cli, clock);
  c.listen<int>(vaultRevisionProvider, (_, _) => env.bumps++);
  c.listen<EditorStateValue>(
    editorControllerProvider,
    (_, next) => env.statuses.add(next.status),
    fireImmediately: true,
  );
  env.editor.loadNote(env.note);
  return env;
}

/// [future]'s value or the error it threw.
Future<Object?> _wi429Outcome(Future<Object?> future) async {
  try {
    return await future;
  } catch (e) {
    return e;
  }
}

void main() {
  group('flushThenWrite (D19)', () {
    test(
      'flushThenWrite stores the pending edit before it runs the write',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        expect(env.cli.callsFor('update'), isEmpty, reason: 'still pending');
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen),
        );

        expect(seen, hasLength(1), reason: 'the write ran once');
        expect(seen.single.updates, 1, reason: 'the flush saved first');
        expect(
          seen.single.body,
          _wi429Typed,
          reason: 'the write ran on the stored edit',
        );
        final update = env.cli.callsFor('update').single;
        expect(update.stdinBody, _wi429Typed);
        expect(update.flag('expected-version'), '$_wi429Start');
      },
    );

    test(
      'flushThenWrite rebases the editor onto the stored note when the editor still holds the flushed text',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen),
        );

        final linked =
            '$_wi429Typed\n\n## Auto-added links\n\n[[Loot tables]]\n';
        expect(env.storedBody, linked);
        expect(env.storedVersion, _wi429Start + 2);
        expect(env.state.contentMd, linked, reason: 'the stored text wins');
        expect(env.state.lastSavedVersion, _wi429Start + 2);
        expect(env.state.status, SaveStatus.clean);

        await env.drain();
        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'nothing is saved again, so the write is kept',
        );
        expect(env.storedBody, linked);
      },
    );

    test(
      'flushThenWrite keeps text typed while the write runs on the version the write stored',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(
            seen,
            during: () => env.editor.onContentChanged(_wi429TypedLater),
          ),
        );

        expect(
          env.state.contentMd,
          _wi429TypedLater,
          reason: 'newer text wins',
        );
        expect(env.state.lastSavedVersion, _wi429Start + 2);
        expect(env.state.status, SaveStatus.dirty);

        await env.drain();
        final updates = env.cli.callsFor('update');
        expect(updates, hasLength(2));
        expect(updates.last.stdinBody, _wi429TypedLater);
        expect(
          updates.last.flag('expected-version'),
          '${_wi429Start + 2}',
          reason: 'the next save goes on the version the write stored',
        );
        expect(env.state.status, SaveStatus.clean);
        expect(env.storedBody, _wi429TypedLater);
        expect(
          env.statuses,
          isNot(contains(SaveStatus.conflict)),
          reason: 'no conflict banner',
        );
      },
    );

    test(
      'flushThenWrite with a carryOver keeps what it makes of the text typed while the write runs',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];
        final asked = <(String, String, String)>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(
            seen,
            suffix: ' [[Loot tables]]',
            during: () => env.editor.onContentChanged(_wi429TypedLater),
          ),
          carryOver: ({required typed, required flushed, required stored}) {
            asked.add((typed, flushed, stored));
            return '$typed [[Loot tables]]';
          },
        );

        expect(asked, [
          (_wi429TypedLater, _wi429Typed, '$_wi429Typed [[Loot tables]]'),
        ]);
        const kept = '$_wi429TypedLater [[Loot tables]]';
        expect(env.state.contentMd, kept);
        expect(env.state.lastSavedVersion, _wi429Start + 2);

        await env.drain();
        expect(env.cli.callsFor('update').last.stdinBody, kept);
        expect(env.storedBody, kept);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'flushThenWrite with a carryOver and no typing during the write takes the stored text without asking it',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];
        var asked = 0;

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen, suffix: ' [[Loot tables]]'),
          carryOver: ({required typed, required flushed, required stored}) {
            asked++;
            return typed;
          },
        );

        expect(asked, 0);
        expect(env.state.contentMd, '$_wi429Typed [[Loot tables]]');
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'flushThenWrite with a carryOver keeps what it makes of text typed during the rebase read',
      () async {
        late EditorVaultDoubles doubles;
        final env = await _wi429Launch(
          gated: (db, cli) =>
              doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli),
        );
        env.editor.onContentChanged(_wi429Typed);
        env.c.read(vaultAccessProvider); // builds the doubles
        final gate = doubles.notes.gate;
        final seen = <({String body, int updates})>[];
        final asked = <(String, String, String)>[];
        final write = env.appendWrite(seen, suffix: ' [[Loot tables]]');

        // Hold the read after the write; let it through and hold the next
        // one, which is the rebase's own read of the stored note.
        final done = flushThenWrite(
          env.c,
          note: env.note,
          write: () async {
            final version = await write();
            gate.hold();
            return version;
          },
          carryOver: ({required typed, required flushed, required stored}) {
            asked.add((typed, flushed, stored));
            return '$typed [[Loot tables]]';
          },
        );
        await pumpEventQueue();
        expect(gate.waiting, 1, reason: 'the read after the write is held');
        gate.release();
        gate.hold();
        await pumpEventQueue();
        expect(gate.waiting, 1, reason: 'the rebase read is held');
        expect(asked, isEmpty, reason: 'nothing typed yet');

        env.editor.onContentChanged(_wi429TypedLater);
        gate.release();
        await done;

        expect(asked, [
          (_wi429TypedLater, _wi429Typed, '$_wi429Typed [[Loot tables]]'),
        ]);
        const kept = '$_wi429TypedLater [[Loot tables]]';
        expect(env.state.contentMd, kept);
        expect(env.state.lastSavedVersion, _wi429Start + 2);

        await env.drain();
        expect(env.storedBody, kept);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'flushThenWrite with a failed flush runs no write and throws the save-first message with the save error',
      () async {
        final env = await _wi429Launch();
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final outcome = await _wi429Outcome(
          flushThenWrite(env.c, note: env.note, write: env.appendWrite(seen)),
        );

        expect(outcome, isA<SaveFirstFailedException>());
        final error = outcome! as SaveFirstFailedException;
        expect(error.message, 'Could not save your changes first.');
        expect(error.toString(), 'Could not save your changes first.');
        expect(error.saveError, 'update failed: disk is full');
        expect(seen, isEmpty, reason: 'nothing is written');
        expect(env.storedBody, _wi429Body);
        expect(env.storedVersion, _wi429Start);
        expect(
          env.state.contentMd,
          _wi429Typed,
          reason: 'the typed text stays',
        );
        expect(env.state.status, SaveStatus.error);
      },
    );

    test(
      'flushThenWrite with a save still in flight runs no write and throws the save-first message with no save error',
      () async {
        final env = await _wi429Launch();
        final gate = Completer<void>();
        final answer = env.cli;
        // The first save is slow: it is in flight while the next edit waits.
        final slow = FakeMemexCli()..onUpdateWrites(env.db);
        answer.on('update', (call) async {
          await gate.future;
          return slow.run(call.args, stdinBody: call.stdinBody);
        });
        env.editor.onContentChanged('first words');
        env.clock.advance(const Duration(milliseconds: 600));
        await pumpEventQueue();
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'in flight');
        env.editor.onContentChanged('first words and more');
        final seen = <({String body, int updates})>[];

        final pending = _wi429Outcome(
          flushThenWrite(env.c, note: env.note, write: env.appendWrite(seen)),
        );
        await pumpEventQueue();
        gate.complete();
        final outcome = await pending;

        expect(outcome, isA<SaveFirstFailedException>());
        final error = outcome! as SaveFirstFailedException;
        expect(error.toString(), 'Could not save your changes first.');
        expect(error.saveError, isNull);
        expect(seen, isEmpty, reason: 'nothing is written');
        await env.drain();
      },
    );

    test(
      'flushThenWrite with no pending edit saves nothing and rebases onto the write',
      () async {
        final env = await _wi429Launch();
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen),
        );

        expect(env.cli.callsFor('update'), isEmpty);
        expect(seen, hasLength(1));
        final linked =
            '$_wi429Body\n\n## Auto-added links\n\n[[Loot tables]]\n';
        expect(env.state.contentMd, linked);
        expect(env.state.lastSavedVersion, _wi429Start + 1);
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'flushThenWrite leaves the editor as it is when the stored note cannot be read after the write',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        var wrote = 0;

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: () async {
              wrote++;
              env.db.db.execute('DELETE FROM notes WHERE id = ?', [
                _wi429NoteId,
              ]);
              return _wi429Start + 7;
            },
          ),
        );

        expect(outcome, isNull, reason: 'completes without an error');
        expect(wrote, 1);
        expect(env.state.contentMd, _wi429Typed);
        expect(
          env.state.lastSavedVersion,
          _wi429Start + 1,
          reason: 'still the flushed version: no rebase',
        );
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'flushThenWrite passes a failed write through and leaves the editor as it was',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final failure = MemexException(
          'add-link failed: boom',
          code: 'internal',
        );
        var wrote = 0;

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: () async {
              wrote++;
              throw failure;
            },
          ),
        );

        expect(wrote, 1, reason: 'the write ran after the flush');
        expect(identical(outcome, failure), isTrue, reason: '$outcome');
        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.state.contentMd, _wi429Typed);
        expect(env.state.lastSavedVersion, _wi429Start + 1);
        expect(env.state.status, SaveStatus.clean);
      },
    );
  });

  group('flushThenWrite runs one call at a time per container', () {
    test(
      'flushThenWrite starts a second call only after the first has finished and the second rebases onto what both wrote',
      () async {
        final env = await _wi429Launch();
        final gate = Completer<void>();
        final order = <String>[];
        final seen = <({String body, int updates})>[];

        final first = flushThenWrite(
          env.c,
          note: env.note,
          write: () async {
            order.add('first start');
            await gate.future;
            final version = await env.appendWrite(seen, suffix: ' [first]')();
            order.add('first end');
            return version;
          },
        );
        final second = flushThenWrite(
          env.c,
          note: env.note,
          write: () async {
            order.add('second start');
            return env.appendWrite(seen, suffix: ' [second]')();
          },
        );
        await pumpEventQueue();
        expect(order, ['first start'], reason: 'the second call waits');

        gate.complete();
        await first;
        await second;

        expect(order, ['first start', 'first end', 'second start']);
        const both = '$_wi429Body [first] [second]';
        expect(env.storedBody, both);
        expect(
          env.state.contentMd,
          both,
          reason: 'the second rebase keeps the first call write',
        );
        expect(env.state.lastSavedVersion, _wi429Start + 2);
        expect(env.state.status, SaveStatus.clean);
        await env.drain();
        expect(
          env.cli.callsFor('update'),
          isEmpty,
          reason: 'no later save overwrites a write',
        );
        expect(env.storedBody, both);
      },
    );

    test(
      'flushThenWrite still runs the next call after one fails on the write or on the flush',
      () async {
        final env = await _wi429Launch();
        final seen = <({String body, int updates})>[];

        final failedWrite = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: () async => throw MemexException('boom', code: 'internal'),
          ),
        );
        final afterWrite = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: env.appendWrite(seen, suffix: ' [one]'),
          ),
        );
        expect(await failedWrite, isA<MemexException>());
        expect(await afterWrite, isNull);
        expect(env.storedBody, '$_wi429Body [one]');

        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        env.editor.onContentChanged('$_wi429Body [one] typed');
        final failedFlush = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: env.appendWrite(seen, suffix: ' [no]'),
          ),
        );
        env.cli.on('update', (_) => FakeMemexCli.error('internal', 'again'));
        final afterFlush = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            write: env.appendWrite(seen, suffix: ' [two]'),
          ),
        );

        expect(await failedFlush, isA<SaveFirstFailedException>());
        expect(
          await afterFlush,
          isA<SaveFirstFailedException>(),
          reason: 'the next call ran: its own flush failed too',
        );
        expect(seen, hasLength(1), reason: 'no write after a failed flush');
      },
    );

    test(
      'flushThenWrite on another container does not wait for a call still running on this one',
      () async {
        final slow = await _wi429Launch();
        final other = await _wi429Launch();
        final gate = Completer<void>();
        final seen = <({String body, int updates})>[];
        final held = flushThenWrite(
          slow.c,
          note: slow.note,
          write: () async {
            await gate.future;
            return slow.appendWrite(seen)();
          },
        );
        await pumpEventQueue();

        await flushThenWrite(
          other.c,
          note: other.note,
          write: other.appendWrite(seen, suffix: ' [other]'),
        );

        expect(other.storedBody, '$_wi429Body [other]');
        expect(slow.storedBody, _wi429Body, reason: 'still held');
        gate.complete();
        await held;
        expect(slow.storedBody, contains('Loot tables'));
      },
    );

    test(
      'flushThenWrite enters its flush before any await when the queue has drained',
      () async {
        final env = await _wi429Launch();
        final seen = <({String body, int updates})>[];
        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen, suffix: ' [a]'),
        );
        await pumpEventQueue();
        env.editor.onContentChanged('$_wi429Body [a] typed');

        final second = flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen, suffix: ' [b]'),
        );

        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'the flush started in the same turn: no queue to wait for',
        );
        await second;
        expect(env.storedBody, '$_wi429Body [a] typed [b]');
        expect(env.state.contentMd, '$_wi429Body [a] typed [b]');
      },
    );

    test(
      'flushThenWrite holds a third call behind the second while the first has finished',
      () async {
        final env = await _wi429Launch();
        final gates = [Completer<void>(), Completer<void>()];
        final order = <String>[];
        final seen = <({String body, int updates})>[];
        Future<int> Function() gated(String name, Completer<void>? gate) =>
            () async {
              order.add('$name start');
              if (gate != null) await gate.future;
              final version = await env.appendWrite(seen, suffix: ' [$name]')();
              order.add('$name end');
              return version;
            };

        final first = flushThenWrite(
          env.c,
          note: env.note,
          write: gated('a', gates[0]),
        );
        final second = flushThenWrite(
          env.c,
          note: env.note,
          write: gated('b', gates[1]),
        );
        await pumpEventQueue();
        expect(order, ['a start']);
        gates[0].complete();
        await first;
        await pumpEventQueue();
        expect(order, ['a start', 'a end', 'b start'], reason: 'b is running');

        final third = flushThenWrite(
          env.c,
          note: env.note,
          write: gated('c', null),
        );
        await pumpEventQueue();
        expect(order, [
          'a start',
          'a end',
          'b start',
        ], reason: 'c waits for b, it does not run beside it');

        gates[1].complete();
        await second;
        await third;

        expect(order, [
          'a start',
          'a end',
          'b start',
          'b end',
          'c start',
          'c end',
        ]);
        const all = '$_wi429Body [a] [b] [c]';
        expect(env.storedBody, all);
        expect(env.state.contentMd, all);
      },
    );
  });

  group('flushThenWrite with waitForSaves', () {
    /// An editor whose first save is in flight until the returned gate
    /// completes, with `first words` saving.
    Future<(_Wi429Env, Completer<void>)> inFlight() async {
      final env = await _wi429Launch();
      final gate = Completer<void>();
      final slow = FakeMemexCli()..onUpdateWrites(env.db);
      env.cli.on('update', (call) async {
        if (env.cli.callsFor('update').length == 1) await gate.future;
        return slow.run(call.args, stdinBody: call.stdinBody);
      });
      env.editor.onContentChanged('first words');
      env.clock.advance(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(env.cli.callsFor('update'), hasLength(1), reason: 'in flight');
      return (env, gate);
    }

    test(
      'flushThenWrite with waitForSaves waits for a save in flight and flushes the newer text before it writes',
      () async {
        final (env, gate) = await inFlight();
        env.editor.onContentChanged('first words and more');
        final seen = <({String body, int updates})>[];

        final pending = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            waitForSaves: true,
            write: env.appendWrite(seen),
          ),
        );
        await pumpEventQueue();
        expect(seen, isEmpty, reason: 'waits for the save in flight');
        gate.complete();
        final outcome = await pending;

        expect(outcome, isNull, reason: 'a save in flight is not a failure');
        expect(seen, hasLength(1));
        expect(seen.single.updates, 2, reason: 'both saves landed first');
        expect(seen.single.body, 'first words and more');
        final updates = env.cli.callsFor('update');
        expect(updates.last.stdinBody, 'first words and more');
        expect(
          updates.last.flag('expected-version'),
          '${_wi429Start + 1}',
          reason: 'the flushed save goes on the version the first one stored',
        );
        expect(env.storedVersion, _wi429Start + 3);
        expect(
          env.state.contentMd,
          'first words and more\n\n## Auto-added links\n\n[[Loot tables]]\n',
        );
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'flushThenWrite with waitForSaves waits for a save in flight when nothing else is pending',
      () async {
        final (env, gate) = await inFlight();
        expect(env.state.status, SaveStatus.saving);
        final seen = <({String body, int updates})>[];

        final pending = _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            waitForSaves: true,
            write: env.appendWrite(seen),
          ),
        );
        await pumpEventQueue();
        expect(seen, isEmpty, reason: 'waits for the save in flight');
        gate.complete();

        expect(await pending, isNull);
        expect(seen.single.body, 'first words');
        expect(env.cli.callsFor('update'), hasLength(1));
      },
    );

    test(
      'flushThenWrite with waitForSaves still fails at once on a save error and waits for nothing',
      () async {
        final env = await _wi429Launch();
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            waitForSaves: true,
            write: env.appendWrite(seen),
          ),
        );

        expect(outcome, isA<SaveFirstFailedException>());
        expect(
          (outcome! as SaveFirstFailedException).saveError,
          'update failed: disk is full',
        );
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'no retry');
        expect(seen, isEmpty);
        expect(env.state.status, SaveStatus.error);
        expect(env.bumps, 0);
      },
    );

    test(
      'flushThenWrite with waitForSaves fails at once on a version conflict',
      () async {
        final env = await _wi429Launch();
        // TEST-CHANGE (#16, Req 34a): the server changed the line the
        // person typed on (an overlap), so the conflict is not merged.
        env.cli.on('update', (call) {
          env.db.db.execute(
            'UPDATE notes SET content_md = ?, version = version + 1 WHERE id = ?',
            ['Changed on the server.', call.flag('note-id')],
          );
          return FakeMemexCli.error(
            'version_conflict',
            'note changed on the server',
          );
        });
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            waitForSaves: true,
            write: env.appendWrite(seen),
          ),
        );

        expect(outcome, isA<SaveFirstFailedException>());
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'no retry');
        expect(env.state.status, SaveStatus.conflict);
        expect(seen, isEmpty);
      },
    );

    test(
      'flushThenWrite with waitForSaves gives up after three waits when the editor keeps getting newer text',
      () async {
        final env = await _wi429Launch();
        final slow = FakeMemexCli()..onUpdateWrites(env.db);
        var saves = 0;
        env.cli.on('update', (call) async {
          // The person keeps typing while each save is in flight.
          env.editor.onContentChanged('${env.state.contentMd}.');
          saves++;
          return slow.run(call.args, stdinBody: call.stdinBody);
        });
        env.editor.onContentChanged('$_wi429Body.');
        final seen = <({String body, int updates})>[];

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            waitForSaves: true,
            write: env.appendWrite(seen),
          ),
        );

        expect(outcome, isA<SaveFirstFailedException>());
        expect(
          (outcome! as SaveFirstFailedException).saveError,
          isNull,
          reason: 'nothing failed, the editor never held still',
        );
        expect(seen, isEmpty, reason: 'nothing is written');
        expect(saves, 4, reason: 'the first flush and three after waits');
      },
    );

    test(
      'flushThenWrite without waitForSaves does not wait for a save in flight',
      () async {
        final (env, gate) = await inFlight();
        final seen = <({String body, int updates})>[];

        final pending = _wi429Outcome(
          flushThenWrite(env.c, note: env.note, write: env.appendWrite(seen)),
        );
        await pumpEventQueue();

        expect(await pending, isA<SaveFirstFailedException>());
        expect(seen, isEmpty);
        gate.complete();
        await pumpEventQueue();
      },
    );
  });

  group('flushThenWrite with holdSaves', () {
    test(
      'flushThenWrite with holdSaves sends no debounced save while the write runs and saves text typed meanwhile on the version the write stored',
      () async {
        final env = await _wi429Launch();
        final gate = Completer<void>();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final flushing = flushThenWrite(
          env.c,
          note: env.note,
          holdSaves: true,
          write: () async {
            final version = await env.appendWrite(seen)();
            await gate.future;
            return version;
          },
        );
        await pumpEventQueue();
        expect(seen, hasLength(1), reason: 'the write is applied and held');
        env.editor.onContentChanged('$_wi429Typed Meanwhile.');
        env.clock.advance(const Duration(seconds: 2));
        await pumpEventQueue();

        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'only the flush saved: no save beside the write',
        );
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));

        gate.complete();
        await flushing;
        expect(env.state.contentMd, '$_wi429Typed Meanwhile.');
        expect(env.state.lastSavedVersion, _wi429Start + 2);
        expect(env.state.status, SaveStatus.dirty);

        await env.drain();
        final updates = env.cli.callsFor('update');
        expect(updates, hasLength(2));
        expect(updates.last.stdinBody, '$_wi429Typed Meanwhile.');
        expect(updates.last.flag('expected-version'), '${_wi429Start + 2}');
        expect(env.state.status, SaveStatus.clean);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'flushThenWrite without holdSaves lets a debounced save go beside the write',
      () async {
        final env = await _wi429Launch();
        final gate = Completer<void>();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final flushing = flushThenWrite(
          env.c,
          note: env.note,
          write: () async {
            final version = await env.appendWrite(seen)();
            await gate.future;
            return version;
          },
        );
        await pumpEventQueue();
        env.editor.onContentChanged('$_wi429Typed Meanwhile.');
        env.clock.advance(const Duration(seconds: 2));
        await pumpEventQueue();

        expect(
          env.cli.callsFor('update'),
          hasLength(2),
          reason: 'the default does not hold the debounce',
        );
        gate.complete();
        await flushing;
        await env.drain();
      },
    );

    test(
      'flushThenWrite with holdSaves bumps the revision once when a flushed edit and the write both landed',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          holdSaves: true,
          write: env.appendWrite(seen),
        );
        await env.drain();

        expect(env.bumps, 1);
      },
    );

    test(
      'flushThenWrite with holdSaves bumps the revision once for a write with no edit to flush',
      () async {
        final env = await _wi429Launch();
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          holdSaves: true,
          write: env.appendWrite(seen),
        );
        await env.drain();

        expect(env.bumps, 1);
      },
    );

    test(
      'flushThenWrite with holdSaves bumps the revision once when the write fails after the flush saved',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            holdSaves: true,
            write: () async => throw MemexException('boom', code: 'internal'),
          ),
        );

        expect(outcome, isA<MemexException>());
        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.bumps, 1, reason: 'the flushed save landed');
      },
    );

    test(
      'flushThenWrite with holdSaves bumps nothing when the write fails and there was nothing to flush',
      () async {
        final env = await _wi429Launch();

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            holdSaves: true,
            write: () async => throw MemexException('boom', code: 'internal'),
          ),
        );

        expect(outcome, isA<MemexException>());
        expect(env.bumps, 0);
      },
    );

    test(
      'flushThenWrite with holdSaves bumps nothing when the flush fails and releases the hold',
      () async {
        final env = await _wi429Launch();
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        final outcome = await _wi429Outcome(
          flushThenWrite(
            env.c,
            note: env.note,
            holdSaves: true,
            write: env.appendWrite(seen),
          ),
        );

        expect(outcome, isA<SaveFirstFailedException>());
        expect(env.bumps, 0);
        // The hold is released: a later edit saves again at its debounce.
        env.editor.onContentChanged('$_wi429Typed more');
        await env.drain();
        expect(env.cli.callsFor('update'), hasLength(2), reason: 'not held');
      },
    );

    test(
      'flushThenWrite without holdSaves leaves the revision bumps to the editor and the caller',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged(_wi429Typed);
        final seen = <({String body, int updates})>[];

        await flushThenWrite(
          env.c,
          note: env.note,
          write: env.appendWrite(seen),
        );
        await env.drain();

        expect(env.bumps, 1, reason: 'the flushed save only, not the write');

        final quiet = await _wi429Launch();
        await flushThenWrite(
          quiet.c,
          note: quiet.note,
          write: quiet.appendWrite(seen),
        );
        expect(quiet.bumps, 0);
      },
    );

    test(
      'flushThenWrite with holdSaves reschedules the save of text typed during the write once the hold ends',
      () async {
        final env = await _wi429Launch();
        final gate = Completer<void>();
        final seen = <({String body, int updates})>[];
        final flushing = flushThenWrite(
          env.c,
          note: env.note,
          holdSaves: true,
          write: () async {
            final version = await env.appendWrite(seen)();
            await gate.future;
            return version;
          },
        );
        await pumpEventQueue();
        env.editor.onContentChanged('$_wi429Body typed during');
        env.clock.advance(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(env.cli.callsFor('update'), isEmpty, reason: 'held');

        gate.complete();
        await flushing;
        expect(env.cli.callsFor('update'), isEmpty, reason: 'debounced again');
        await env.drain();

        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.state.status, SaveStatus.clean);
      },
    );
  });

  test(
    'flushPendingSaveAndWait is called only from flushThenWrite and the guide restore and echo link go through it',
    () {
      final callers = <String, int>{};
      final call = RegExp(r'\.flushPendingSaveAndWait\(\)');
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final n = call.allMatches(entity.readAsStringSync()).length;
        if (n > 0) callers[p.posix.joinAll(p.split(entity.path))] = n;
      }
      expect(callers, {
        'lib/src/state/topic_actions.dart': 1,
      }, reason: 'one flush-then-write (D19)');
      final topicActions = File(
        'lib/src/state/topic_actions.dart',
      ).readAsStringSync();
      final helper = topicActions.indexOf('Future<void> flushThenWrite(');
      expect(helper, isNonNegative);
      expect(
        topicActions.indexOf('.flushPendingSaveAndWait()', helper),
        isNonNegative,
        reason: 'the flush is inside flushThenWrite',
      );
      final activity = File(
        'lib/src/widgets/activity_tab.dart',
      ).readAsStringSync();
      expect(activity, contains('flushThenWrite('));
      expect(activity, isNot(contains('flushPendingSaveAndWait')));
      expect(activity, isNot(contains('rebaseEditorOnVersionIn')));
      final echoLink = File(
        'lib/src/state/echo_link_actions.dart',
      ).readAsStringSync();
      expect(echoLink, contains('flushThenWrite('));
    },
  );
}
