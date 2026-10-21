// WI #102 (H8): the hosted editor's pending-save queue (L16), its automatic
// retry once the vault server answers, and the L17 self-heal. The notes
// domain is a hosted double (`extends LocalNotesAccess`, D21) over a
// FakeVaultDb / FakeMemexCli that fails writes the way the hosted client
// does and records each write's outcome in `hostedConnectionStatusProvider`
// like the client's response hook (D17). Time is a FakeClock (D14).
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/pending_saves.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/hosted_notes_fakes.dart';
import '../support/today_cli_fakes.dart';

const _planId = '01J9PLAN0000000000000000102';
const _otherId = '01J9OTHER000000000000000102';
const _dailyId = '01J9DAILY000000000000000102';
const _agentDailyId = '01J9AGENT000000000000000102';
const _today = '2026-10-03';

/// The FakeClock's start (the harness's 09:00 local).
final _start = DateTime(2026, 10, 3, 9);

/// When the first debounced save after an edit at [_start] runs and fails.
final _firstFailure = _start.add(saveDebounce);

class _H {
  _H(this.c, this.doubles, this.db, this.cli, this.clock);
  final ProviderContainer c;
  final HostedVaultDoubles doubles;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  int get revision => c.read(vaultRevisionProvider);
  List<PendingSave> get queue => c.read(pendingSavesProvider);
  HostedNotesAccess get notes =>
      doubles.notesFor(c.read(currentVaultProvider)!);

  /// The stored note, read straight from the database.
  Note stored(String id) => db.getNote(id)!;

  PendingSave? queued(String noteId) {
    for (final p in queue) {
      if (p.noteId == noteId) return p;
    }
    return null;
  }

  /// Fire the 500 ms save debounce and let every write and read finish.
  Future<void> fireDebounce() async {
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }

  /// Make every write fail with [error] (the server can't be reached).
  void serverDown([Object? error]) {
    notes.writeError = error ?? nasUnreachable();
  }

  /// The server answers again: writes succeed, and the next request's
  /// outcome (e.g. the revision poll) records `connected`.
  Future<void> serverAnswers() async {
    notes
      ..writeError = null
      ..commitBeforeError = false;
    setHostedStatus(c, HostedConnectionStatus.connected);
    await pumpEventQueue();
  }

  /// The server is still unreachable, but the poll records `connected`
  /// again: a retry runs and fails.
  Future<void> recoveryThatFails() async {
    setHostedStatus(c, HostedConnectionStatus.connected);
    await pumpEventQueue();
  }

  /// Edit the open note to [text] and let its debounced save run.
  Future<void> typeAndSave(String text) async {
    ctrl.onContentChanged(text);
    await fireDebounce();
  }
}

Future<_H> _hosted(
  FakeVaultDb db, {
  FakeMemexCli? cli,
  VaultRef vault = hostedPlanVault,
  List<Override> overrides = const [],
}) async {
  final dir = await Directory.systemTemp.createTemp('om102_pending');
  final fakeCli = cli ?? (FakeMemexCli()..onUpdateWrites(db));
  final clock = FakeClock(_start);
  final doubles = HostedVaultDoubles(db: db, cli: fakeCli, vaultPath: dir.path);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(fakeCli),
      clockProvider.overrideWithValue(clock),
      hostedAccessOverride(doubles),
      ...overrides,
    ],
  );
  recordHostedOutcomes(doubles, c);
  addTearDown(() {
    c.dispose();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(vaultAccessProvider);
  c.listen(tabsProvider, (_, _) {});
  c.listen(editorControllerProvider, (_, _) {});
  if (vault is HostedVaultRef) {
    setHostedStatus(c, HostedConnectionStatus.connected);
  }
  await pumpEventQueue();
  return _H(c, doubles, db, fakeCli, clock);
}

/// A vault with the plain notes "Plan" (`old`, version 3) and "Other"
/// (`other body`, version 7).
FakeVaultDb _plainVault() => FakeVaultDb.v5()
  ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
  ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);

/// A daily note [_dailyId] for [_today] at version 3 holding `Morning pages`
/// (one person block).
FakeVaultDb _dailyVault() {
  final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _dailyId, version: 3);
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    assembleDailyBody('Morning pages\n', const []),
    _dailyId,
  ]);
  db.seedBlock(_dailyId, 'p-morning', ord: 0, text: 'Morning pages');
  return db;
}

/// Another writer changes [id] on the server to [body] at [version].
void _foreignWrite(FakeVaultDb db, String id, String body, int version) {
  db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
    body,
    version,
    id,
  ]);
}

/// The number of times [needle] occurs in [haystack].
int _count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

/// A daily note's stored canonical body (C3): the person text, the marker.
String _canonicalDaily(String body) =>
    assembleDailyBody(splitDailyBody(body).person, splitDailyBody(body).chips);

void _expectNoErrorState(_H h) {
  expect(h.state.status, isNot(SaveStatus.error));
  expect(h.state.status, isNot(SaveStatus.conflict));
  expect(h.state.errorMessage, isNull);
}

void main() {
  group('a hosted save that cannot reach the server is queued (AC1)', () {
    for (final (name, mayHaveCommitted) in [
      (
        'a hosted save refused by the server keeps the text and queues it with its base version and since time',
        false,
      ),
      (
        'a hosted save that timed out after sending keeps the text and queues it with its base version and since time',
        true,
      ),
    ]) {
      test(name, () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown(nasUnreachable(mayHaveCommitted: mayHaveCommitted));

        await h.typeAndSave('new text');

        expect(h.notes.writes, ['updateNote:$_planId@3']);
        expect(h.state.contentMd, 'new text');
        _expectNoErrorState(h);
        expect(h.queue, hasLength(1));
        final p = h.queue.single;
        expect(p.noteId, _planId);
        expect(p.title, 'Plan');
        expect(p.text, 'new text');
        expect(p.baseVersion, 3);
        expect(p.since, _firstFailure);
        expect(p.serverName, hostedServerName);
      });
    }

    test(
      'further edits while a save is queued replace the queued text and send nothing while the server is unreachable',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');

        h.clock.advance(const Duration(minutes: 3));
        await h.typeAndSave('newer text');
        await h.typeAndSave('newest text');

        expect(h.notes.writes, ['updateNote:$_planId@3']);
        expect(h.state.contentMd, 'newest text');
        _expectNoErrorState(h);
        final p = h.queued(_planId)!;
        expect(p.text, 'newest text');
        expect(p.baseVersion, 3);
        expect(p.since, _firstFailure);
        expect(h.queue, hasLength(1));
      },
    );

    test(
      'the since time stays the first failure time when the clock jumps backward and a retry fails again',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');

        // NTP or a manual clock change moves wall time back an hour.
        h.clock.advance(const Duration(hours: -1));
        await h.recoveryThatFails();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.queued(_planId)!.since, _firstFailure);

        h.clock.advance(const Duration(hours: 2));
        await h.recoveryThatFails();
        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.queued(_planId)!.since, _firstFailure);
      },
    );
  });

  group('every queued note retries when the server answers (AC2)', () {
    test(
      'when the server answers again every queued note retries once with its expected version and the queue empties',
      () async {
        final h = await _hosted(_plainVault());
        h.serverDown();
        h.ctrl.loadNote(h.stored(_planId));
        await h.typeAndSave('plan text');
        h.ctrl.loadNote(h.stored(_otherId));
        await h.typeAndSave('other text');
        expect(h.queue.map((p) => p.noteId), [_planId, _otherId]);
        final writesBefore = h.notes.writes.length;
        final revisionBefore = h.revision;

        await h.serverAnswers();
        await pumpEventQueue();

        final retries = h.notes.writes.sublist(writesBefore);
        expect(
          retries,
          unorderedEquals(['updateNote:$_planId@3', 'updateNote:$_otherId@7']),
        );
        expect(h.stored(_planId).contentMd, 'plan text');
        expect(h.stored(_planId).version, 4);
        expect(h.stored(_otherId).contentMd, 'other text');
        expect(h.stored(_otherId).version, 8);
        expect(h.queue, isEmpty);
        expect(h.revision, greaterThan(revisionBefore));
        // The open note's editor is saved at the new version.
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 8);
        expect(h.state.contentMd, 'other text');
      },
    );

    test(
      'a successful retry of the open note sets its saved version and bumps the vault revision once',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final revisionBefore = h.revision;

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.notes.updateBodies.last, 'new text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        expect(h.state.errorMessage, isNull);
        expect(h.revision, revisionBefore + 1);
        expect(h.queue, isEmpty);

        // The next edit saves against the version the retry got.
        await h.typeAndSave('more text');
        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.stored(_planId).contentMd, 'more text');
      },
    );

    test(
      'a retry that fails again stays queued and retries on the next recovery',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');

        await h.recoveryThatFails();
        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.queued(_planId)!.text, 'new text');
        _expectNoErrorState(h);
        await pumpEventQueue();
        // One retry per recovery, not a loop.
        expect(h.notes.updatesOf(_planId), hasLength(2));

        await h.serverAnswers();
        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        expect(h.stored(_planId).contentMd, 'new text');
      },
    );

    test(
      'several edits while queued go out as one save of the latest text when the server answers',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('one');
        await h.typeAndSave('one two');
        await h.typeAndSave('one two three');
        final writesBefore = h.notes.writes.length;

        await h.serverAnswers();
        await h.fireDebounce();

        expect(h.notes.writes.sublist(writesBefore), ['updateNote:$_planId@3']);
        expect(h.notes.updateBodies.last, 'one two three');
        expect(h.stored(_planId).contentMd, 'one two three');
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a save that fails after the status already reads connected again still retries',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        // The save's own failure records unreachable, then a revision poll
        // answers before the failure reaches the editor: by the time the
        // note is queued the status already reads connected.
        var once = true;
        h.doubles.onOutcome = (vault, status) {
          setHostedStatus(h.c, status);
          if (once && status == HostedConnectionStatus.unreachable) {
            once = false;
            h.notes.writeError = null;
            setHostedStatus(h.c, HostedConnectionStatus.connected);
          }
        };
        h.serverDown();

        await h.typeAndSave('new text');
        await h.fireDebounce();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
      },
    );

    test(
      'typing during an in-flight retry keeps the newer text and saves it next',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final gate = Completer<void>();
        h.notes.writeGate = gate;

        await h.serverAnswers();
        h.ctrl.onContentChanged('newer text');
        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();

        expect(h.state.contentMd, 'newer text');
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);

        await h.fireDebounce();
        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.contentMd, 'newer text');
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a debounced save during an in-flight retry sends nothing and marks the editor dirty until the retry lands',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final gate = Completer<void>();
        h.notes.writeGate = gate;
        await h.serverAnswers();
        expect(h.state.status, SaveStatus.saving);

        // The debounce of an edit typed during the retry fires before it
        // lands.
        await h.typeAndSave('newer text');

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);
        expect(h.queued(_planId)!.text, 'newer text');

        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();
        await h.fireDebounce();

        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a retry that fails after typing during it queues the newer text',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final gate = Completer<void>();
        h.notes.writeGate = gate;

        await h.recoveryThatFails();
        h.ctrl.onContentChanged('newer text');
        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();
        await h.fireDebounce();

        expect(h.state.contentMd, 'newer text');
        _expectNoErrorState(h);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.stored(_planId).contentMd, 'old');
      },
    );
  });

  group('self-heal (AC3)', () {
    test(
      'a retried save that gets version_conflict while the server body equals the queued text counts as saved',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        // The first attempt timed out after the server committed it.
        h.serverDown(nasUnreachable(mayHaveCommitted: true));
        h.notes.commitBeforeError = true;
        await h.typeAndSave('new text');
        expect(h.stored(_planId).version, 4);
        expect(h.queued(_planId), isNotNull);

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.state.contentMd, 'new text');
        expect(h.state.lastSavedVersion, 4);
        expect(h.queue, isEmpty);
        // Nothing was written again.
        expect(h.stored(_planId).version, 4);
        expect(h.stored(_planId).contentMd, 'new text');

        await h.typeAndSave('more text');
        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.state.status, SaveStatus.clean);
      },
    );
  });

  group('daily notes merge on a retried conflict (AC4)', () {
    test(
      'a retried daily note save whose stored canonical body differs from the local text merges and ends saved without a conflict',
      () async {
        final h = await _hosted(_dailyVault());
        h.ctrl.loadNote(h.stored(_dailyId));
        h.notes.storedForm = _canonicalDaily;
        h.serverDown(nasUnreachable(mayHaveCommitted: true));
        h.notes.commitBeforeError = true;
        const local = 'Morning pages\nLunch with Sam.';
        await h.typeAndSave(local);
        expect(h.stored(_dailyId).contentMd, isNot(local));
        expect(h.queued(_dailyId), isNotNull);

        await h.serverAnswers();
        await h.fireDebounce();

        final stored = h.stored(_dailyId);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.queue, isEmpty);
        expect(
          splitDailyBody(stored.contentMd).person.trimRight(),
          'Morning pages\nLunch with Sam.',
        );
        expect(_count(stored.contentMd, 'Lunch with Sam.'), 1);
        expect(h.state.lastSavedVersion, stored.version);
      },
    );
  });

  group('a non-daily conflict on retry (AC5)', () {
    test(
      'a non-daily retried save that gets version_conflict with a different server body shows the conflict state',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        _foreignWrite(h.db, _planId, 'their text', 4);

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.state.status, SaveStatus.conflict);
        expect(h.state.errorMessage, isNotNull);
        expect(h.state.contentMd, 'new text');
        expect(h.stored(_planId).contentMd, 'their text');
        expect(h.stored(_planId).version, 4);
      },
    );
  });

  group('switching notes with a queued save (AC6, AC7)', () {
    test(
      'switching notes keeps the failed note queued and the other note opens normally',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');

        h.ctrl.loadNote(h.stored(_otherId));

        expect(h.state.contentMd, 'other body');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 7);
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.queued(_otherId), isNull);
      },
    );

    test(
      'returning to a queued note fills the editor from the queue even after a revision bump reloaded it',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        h.ctrl.loadNote(h.stored(_otherId));
        _foreignWrite(h.db, _planId, 'server copy', 5);
        h.c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();

        // The host reloads the note: the server copy, at version 5.
        h.ctrl.loadNote(h.stored(_planId));

        expect(h.state.contentMd, 'new text');
        _expectNoErrorState(h);
        expect(h.queued(_planId)!.text, 'new text');

        // Typing on the returned note replaces the queued text.
        await h.typeAndSave('newer text');
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
      },
    );

    test(
      'serverChanged and a revision bump for a queued note never replace its editor or queued text',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        _foreignWrite(h.db, _planId, 'server copy', 5);

        await h.ctrl.serverChanged(_planId);
        h.c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();

        expect(h.state.contentMd, 'new text');
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.queued(_planId)!.baseVersion, 3);
      },
    );
  });

  group('a 401 save is queued like an unreachable one (AC8)', () {
    test('a save rejected with 401 is queued the same way', () async {
      final h = await _hosted(
        _plainVault(),
        overrides: [
          hostedServerNameProvider(hostedServerId).overrideWithValue('nas'),
        ],
      );
      h.ctrl.loadNote(h.stored(_planId));
      h.serverDown(unauthorized401());

      await h.typeAndSave('new text');

      expect(
        h.c.read(hostedConnectionStatusProvider(hostedServerId)),
        HostedConnectionStatus.tokenRejected,
      );
      expect(h.state.contentMd, 'new text');
      _expectNoErrorState(h);
      final p = h.queued(_planId)!;
      expect(p.text, 'new text');
      expect(p.baseVersion, 3);
      expect(p.since, _firstFailure);
      expect(p.serverName, 'nas');
    });

    test(
      'a queued 401 save retries once the token is updated and the server answers',
      () async {
        final h = await _hosted(
          _plainVault(),
          overrides: [
            hostedServerNameProvider(hostedServerId).overrideWithValue('nas'),
          ],
        );
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown(unauthorized401());
        await h.typeAndSave('new text');

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a 401 save takes the server name from the hosted server name seam whose default is the server id',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown(unauthorized401());

        await h.typeAndSave('new text');

        expect(
          h.c.read(hostedServerNameProvider(hostedServerId)),
          hostedServerId,
        );
        expect(h.queued(_planId)!.serverName, hostedServerId);
      },
    );
  });

  group('the virtual Today create is queued like a save (AC9)', () {
    Future<_H> virtualToday(FakeVaultDb db) async {
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddDailyCreatesOnce(db);
      final h = await _hosted(db, cli: cli);
      h.c.read(tabsProvider.notifier).openToday(date: _today);
      h.ctrl.loadNote(virtualTodayNote(_today));
      return h;
    }

    final virtualId = const VirtualTodayTab(_today).id;

    test(
      'a virtual Today create that cannot reach the server keeps its text queued',
      () async {
        final h = await virtualToday(FakeVaultDb.v5());
        h.serverDown();

        await h.typeAndSave('Morning pages');

        expect(h.notes.writes, ['addNote:$_today:daily']);
        expect(h.state.contentMd, 'Morning pages');
        _expectNoErrorState(h);
        final p = h.queued(virtualId)!;
        expect(p.text, 'Morning pages');
        expect(p.title, _today);
        expect(p.baseVersion, isNull);
        expect(p.since, _firstFailure);
        expect(p.serverName, hostedServerName);
        expect(h.c.read(tabsProvider).activeTab, const VirtualTodayTab(_today));
      },
    );

    test(
      'a queued virtual Today create retries when the server answers and resolves the tab',
      () async {
        final h = await virtualToday(FakeVaultDb.v5());
        h.serverDown();
        await h.typeAndSave('Morning pages');

        await h.serverAnswers();
        await h.fireDebounce();

        expect(h.notes.writes.where((w) => w.startsWith('addNote:')), [
          'addNote:$_today:daily',
          'addNote:$_today:daily',
        ]);
        final stored = h.stored(createdDailyId);
        expect(
          splitDailyBody(stored.contentMd).person.trimRight(),
          'Morning pages',
        );
        expect(h.queue, isEmpty);
        expect(h.c.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
      },
    );

    for (final (name, committedFirst) in [
      (
        'a retried virtual Today create that gets daily_note_exists after its own timed out create merges the queued text once',
        true,
      ),
      (
        'a retried virtual Today create that gets daily_note_exists for an agent created note merges the queued text into it',
        false,
      ),
    ]) {
      test(name, () async {
        final db = FakeVaultDb.v5();
        final h = await virtualToday(db);
        h.serverDown(nasUnreachable(mayHaveCommitted: committedFirst));
        h.notes.commitBeforeError = committedFirst;
        await h.typeAndSave('Morning pages');
        late final String existingId;
        if (committedFirst) {
          existingId = createdDailyId;
          expect(h.stored(existingId), isNotNull);
        } else {
          // An agent creates today's note while the server is unreachable
          // to this app.
          existingId = _agentDailyId;
          db.seedNote(
            id: existingId,
            title: _today,
            content: assembleDailyBody('Agent saw it.\n', const []),
            role: 'daily',
            version: 1,
          );
          db.seedBlock(
            existingId,
            'a-agent',
            ord: 0,
            text: 'Agent saw it.',
            source: 'agent',
          );
        }

        await h.serverAnswers();
        await h.fireDebounce();
        await h.fireDebounce();

        final body = h.stored(existingId).contentMd;
        expect(_count(body, 'Morning pages'), 1);
        if (!committedFirst) expect(_count(body, 'Agent saw it.'), 1);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.queue, isEmpty);
        expect(h.c.read(tabsProvider).activeTab, NoteTab(existingId));
        expect(h.state.lastSavedVersion, h.stored(existingId).version);
      });
    }
  });

  group('a save elsewhere is queued on a hosted vault (AC10)', () {
    test(
      'a hosted virtual Today note resolved after the person left it queues its text when that save fails',
      () async {
        final db = _plainVault();
        final gate = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: gate);
        final h = await _hosted(db, cli: cli);
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        // Typed while the create is in flight, then the person leaves.
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();

        gate.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(createdDailyId), [
          'updateNote:$createdDailyId@1',
        ]);
        final p = h.queued(createdDailyId)!;
        expect(p.text, 'Morning pages\nMore.');
        expect(p.baseVersion, 1);
        expect(p.serverName, hostedServerName);
        // The open note is untouched.
        expect(h.state.contentMd, 'old');
        expect(h.state.status, SaveStatus.clean);

        await h.serverAnswers();
        expect(
          splitDailyBody(h.stored(createdDailyId).contentMd).person.trimRight(),
          'Morning pages\nMore.',
        );
        expect(h.queue, isEmpty);
      },
    );
  });

  group('a save elsewhere that conflicts is merged (AC10)', () {
    test(
      'a virtual Today note resolved after the person left it merges its text when that save conflicts',
      () async {
        final db = _plainVault();
        final gate = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: gate);
        final h = await _hosted(db, cli: cli);
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        // Typed while the create is in flight, then the person leaves.
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));
        // The save elsewhere waits while an agent appends on the server.
        final slow = Completer<void>();
        h.notes.writeGate = slow;
        gate.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(createdDailyId), [
          'updateNote:$createdDailyId@1',
        ]);
        _foreignWrite(
          h.db,
          createdDailyId,
          assembleDailyBody('Morning pages\nAgent note.\n', const []),
          2,
        );
        h.db.seedBlock(
          createdDailyId,
          'a-agent',
          ord: 1,
          text: 'Agent note.',
          source: 'agent',
          createdVersion: 2,
        );
        h.notes.writeGate = null;

        slow.complete();
        await pumpEventQueue();

        final stored = h.stored(createdDailyId).contentMd;
        expect(_count(stored, 'Morning pages'), 1);
        expect(_count(stored, 'More.'), 1);
        expect(_count(stored, 'Agent note.'), 1);
        expect(h.queue, isEmpty);
        // The open note is untouched.
        expect(h.state.contentMd, 'old');
        expect(h.state.status, SaveStatus.clean);
      },
    );
  });

  group('the queue lists what is unsent (AC11)', () {
    test(
      'the queue lists each queued note with its title since time and server name and is empty once saved',
      () async {
        final h = await _hosted(_plainVault());
        h.serverDown();
        h.ctrl.loadNote(h.stored(_planId));
        await h.typeAndSave('plan text');
        h.clock.advance(const Duration(minutes: 4));
        h.ctrl.loadNote(h.stored(_otherId));
        await h.typeAndSave('other text');

        expect(h.queue.map((p) => (p.noteId, p.title, p.since, p.serverName)), [
          (_planId, 'Plan', _firstFailure, hostedServerName),
          (
            _otherId,
            'Other',
            _firstFailure.add(const Duration(minutes: 4)).add(saveDebounce),
            hostedServerName,
          ),
        ]);

        await h.serverAnswers();
        expect(h.queue, isEmpty);
      },
    );

    test('the queue is empty on a fresh hosted vault', () async {
      final h = await _hosted(_plainVault());
      expect(h.queue, isEmpty);
    });
  });

  group('a queued save stays in its vault', () {
    test(
      'a queued save never retries into another vault after a vault switch',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        expect(h.queued(_planId)!.text, 'new text');
        const other = HostedVaultRef(hostedServerId, 'other');

        h.c.read(currentVaultProvider.notifier).state = other;
        h.c.read(vaultAccessProvider);
        await pumpEventQueue();
        setHostedStatus(h.c, HostedConnectionStatus.connected);
        await pumpEventQueue();
        await h.fireDebounce();

        expect(h.doubles.notesFor(other).writes, isEmpty);
      },
    );
  });

  group('local vaults are unchanged (AC12)', () {
    for (final (name, error) in [
      (
        'a failed save on a local vault shows the error state and queues nothing',
        MemexException('update failed: disk full'),
      ),
      (
        'a local save that throws VaultUnreachableException shows the error state and queues nothing',
        nasUnreachable(),
      ),
    ]) {
      test(name, () async {
        final dir = await Directory.systemTemp.createTemp('om102_local');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final h = await _hosted(_plainVault(), vault: LocalVaultRef(dir.path));
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown(error);

        await h.typeAndSave('new text');

        expect(h.state.status, SaveStatus.error);
        expect(h.state.errorMessage, isNotNull);
        expect(h.state.contentMd, 'new text');
        expect(h.queue, isEmpty);
      });
    }

    test(
      'a failed save elsewhere on a local vault is still swallowed and queues nothing',
      () async {
        final dir = await Directory.systemTemp.createTemp('om102_local');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final db = _plainVault();
        final gate = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: gate);
        final h = await _hosted(db, cli: cli, vault: LocalVaultRef(dir.path));
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown(MemexException('update failed: disk full'));

        gate.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(createdDailyId), hasLength(1));
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, 'old');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
      },
    );
  });

  // Verify mode: contracts the implementer's doc comments promise.
  group('a retry that reaches the server and fails is held (AC5)', () {
    test(
      'a retry that gets a non-daily conflict keeps the text and the tab ring and hides the label and stops retrying on its own',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        _foreignWrite(h.db, _planId, 'their text', 4);

        await h.serverAnswers();

        expect(h.state.status, SaveStatus.conflict);
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.c.read(notePendingSaveProvider(_planId)), isTrue);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);

        // The next recovery leaves a held save alone.
        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
        await h.serverAnswers();
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), hasLength(2));

        // Reopening the note shows the queued text in the conflict state.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.conflict);
        expect(h.state.errorMessage, isNotNull);
        expect(h.state.lastSavedVersion, 3);

        // The next edit sends again, on the same base (today: it conflicts).
        await h.typeAndSave('newer text');
        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.notes.writes.last, 'updateNote:$_planId@3');
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.state.status, SaveStatus.conflict);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.stored(_planId).contentMd, 'their text');
      },
    );

    test(
      'a retry that reaches the server and fails with another error holds the save and the next edit sends it again',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        h.notes.writeError = MemexException('update failed: disk full');

        await h.recoveryThatFails();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.state.status, SaveStatus.error);
        expect(h.state.errorMessage, 'update failed: disk full');
        expect(h.state.contentMd, 'new text');
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.c.read(notePendingSaveProvider(_planId)), isTrue);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);

        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
        await h.recoveryThatFails();
        expect(h.notes.updatesOf(_planId), hasLength(2));

        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.error);
        expect(h.state.errorMessage, 'update failed: disk full');

        h.notes.writeError = null;
        await h.typeAndSave('newer text');

        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.notes.writes.last, 'updateNote:$_planId@3');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.state.lastSavedVersion, 4);
        expect(h.queue, isEmpty);
        expect(h.c.read(notePendingSaveProvider(_planId)), isFalse);
      },
    );

    test(
      'a held save whose next send cannot reach the server waits for the server again with the label',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        h.notes.writeError = MemexException('update failed: disk full');
        await h.recoveryThatFails();
        expect(h.state.status, SaveStatus.error);

        // The server drops again before the next edit's send.
        h.serverDown();
        await h.typeAndSave('newer text');

        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.state.contentMd, 'newer text');
        _expectNoErrorState(h);
        expect(h.state.status, SaveStatus.dirty);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.c.read(pendingSaveLabelProvider(_planId)), pendingLabelNas);

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), hasLength(4));
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.queue, isEmpty);
      },
    );
  });

  group('the queue survives a vault switch', () {
    const otherVault = HostedVaultRef(hostedServerId, 'other');

    Future<void> openVault(_H h, VaultRef vault) async {
      h.c.read(currentVaultProvider.notifier).state = vault;
      h.c.read(vaultAccessProvider);
      await pumpEventQueue();
    }

    test(
      'a queued save survives a vault switch and retries when the server answers after switching back',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final planNotes = h.notes;

        await openVault(h, otherVault);
        h.ctrl.loadNote(null);
        expect(h.queue, isEmpty);
        await openVault(h, hostedPlanVault);

        expect(h.queued(_planId)!.text, 'new text');
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'new text');
        expect(h.c.read(pendingSaveLabelProvider(_planId)), pendingLabelNas);

        await h.serverAnswers();

        expect(planNotes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        expect(h.doubles.notesFor(otherVault).writes, isEmpty);
      },
    );

    test(
      'a queued save retries on returning to its vault when the server answered while another vault was open',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final planNotes = h.notes;

        await openVault(h, otherVault);
        h.ctrl.loadNote(null);
        // The server answers (the poll records connected) while the other
        // vault is open.
        planNotes.writeError = null;
        setHostedStatus(h.c, HostedConnectionStatus.connected);
        await pumpEventQueue();
        expect(planNotes.updatesOf(_planId), hasLength(1));

        await openVault(h, hostedPlanVault);
        await pumpEventQueue();

        expect(planNotes.updatesOf(_planId), hasLength(2));
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.queue, isEmpty);
        expect(h.doubles.notesFor(otherVault).writes, isEmpty);
      },
    );
  });

  group('a returned note shows its queued text (AC6)', () {
    test(
      'returning to a note while its first save is in flight shows the queued text once that save cannot reach the server',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        final gate = Completer<void>();
        h.notes.writeGate = gate;
        await h.typeAndSave('new text');
        expect(h.notes.writes, ['updateNote:$_planId@3']);

        // Away and back while the first attempt is in flight: the host
        // loads the server copy.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();

        expect(h.queued(_planId)!.text, 'new text');
        expect(h.state.contentMd, 'new text');
        _expectNoErrorState(h);
        expect(h.state.status, isNot(SaveStatus.clean));

        await h.serverAnswers();
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.state.contentMd, 'new text');
        expect(h.queue, isEmpty);
      },
    );
  });

  group('what a retry sends', () {
    test('a title edited while a save is queued is sent on retry', () async {
      final h = await _hosted(_plainVault());
      h.ctrl.loadNote(h.stored(_planId));
      h.serverDown();
      await h.typeAndSave('new text');

      h.ctrl.onTitleChanged('  Plan B ');
      await h.fireDebounce();
      expect(h.queued(_planId)!.title, '  Plan B ');
      expect(h.notes.updatesOf(_planId), hasLength(1));

      await h.serverAnswers();

      expect(h.notes.updatesOf(_planId), hasLength(2));
      expect(h.notes.updateTitles.last, 'Plan B');
      expect(h.notes.updateBodies.last, 'new text');
      expect(h.queue, isEmpty);
    });

    test('a queued save elsewhere sends no title when it retries', () async {
      final db = _plainVault();
      final gate = Completer<void>();
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddDailyCreates(db, gate: gate);
      final h = await _hosted(db, cli: cli);
      h.c.read(tabsProvider.notifier).openToday(date: _today);
      h.ctrl.loadNote(virtualTodayNote(_today));
      await h.typeAndSave('Morning pages');
      h.ctrl.onContentChanged('Morning pages\nMore.');
      h.ctrl.loadNote(h.stored(_planId));
      h.serverDown();
      gate.complete();
      await pumpEventQueue();
      expect(h.queued(createdDailyId)!.title, _today);

      await h.serverAnswers();

      expect(h.notes.updatesOf(createdDailyId), hasLength(2));
      expect(h.notes.updateTitles, [null, null]);
      expect(h.queue, isEmpty);
    });

    test(
      'text typed during a merged daily retry keeps the old base and the next save merges again',
      () async {
        final h = await _hosted(_dailyVault());
        h.ctrl.loadNote(h.stored(_dailyId));
        h.serverDown();
        await h.typeAndSave('Morning pages\nLunch.');
        // An agent appends to the note on the server meanwhile.
        _foreignWrite(
          h.db,
          _dailyId,
          assembleDailyBody('Morning pages\nAgent note.\n', const []),
          4,
        );
        h.db.seedBlock(
          _dailyId,
          'a-agent',
          ord: 1,
          text: 'Agent note.',
          source: 'agent',
          createdVersion: 4,
        );
        final gate = Completer<void>();
        h.notes.writeGate = gate;

        await h.serverAnswers();
        h.ctrl.onContentChanged('Morning pages\nLunch.\nDinner.');
        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();

        // The merged retry saved; the newer text stays queued on the old base.
        expect(h.stored(_dailyId).version, 5);
        expect(h.queued(_dailyId)!.text, 'Morning pages\nLunch.\nDinner.');
        expect(h.queued(_dailyId)!.baseVersion, 3);
        expect(h.state.status, SaveStatus.dirty);

        await h.fireDebounce();

        expect(h.notes.updatesOf(_dailyId), [
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@4',
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@5',
        ]);
        final body = h.stored(_dailyId).contentMd;
        expect(_count(body, 'Agent note.'), 1);
        expect(_count(body, 'Lunch.'), 1);
        expect(_count(body, 'Dinner.'), 1);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.state.lastSavedVersion, 6);
        expect(h.state.contentMd, body);
        expect(h.queue, isEmpty);
      },
    );
  });

  group('a queued virtual Today create (AC9)', () {
    final virtualId = const VirtualTodayTab(_today).id;

    Future<_H> virtualToday(FakeVaultDb db) async {
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddDailyCreatesOnce(db);
      final h = await _hosted(db, cli: cli);
      h.c.read(tabsProvider.notifier).openToday(date: _today);
      h.ctrl.loadNote(virtualTodayNote(_today));
      return h;
    }

    List<String> adds(_H h) =>
        h.notes.writes.where((w) => w.startsWith('addNote:')).toList();

    test(
      'returning to a queued virtual Today note shows its queued text and the label with no error state',
      () async {
        final h = await virtualToday(_plainVault());
        h.serverDown();
        await h.typeAndSave('Morning pages');

        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'old');
        h.ctrl.loadNote(virtualTodayNote(_today));

        expect(h.state.contentMd, 'Morning pages');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);
        expect(h.c.read(pendingSaveLabelProvider(virtualId)), pendingLabelNas);
        expect(adds(h), hasLength(1));
      },
    );

    test(
      'a retried virtual Today create matches the longest timed out create text first',
      () async {
        final h = await virtualToday(FakeVaultDb.v5());
        // The first add times out and the server never wrote it.
        h.serverDown(nasUnreachable(mayHaveCommitted: true));
        await h.typeAndSave('pages');
        // The person prepends to the text while it is queued.
        await h.typeAndSave('Morning pages');
        expect(adds(h), hasLength(1));

        // The next recovery's add times out after the server wrote it.
        h.notes.commitBeforeError = true;
        await h.recoveryThatFails();
        expect(adds(h), hasLength(2));
        expect(h.stored(createdDailyId), isNotNull);

        await h.serverAnswers();
        await h.fireDebounce();

        expect(adds(h), hasLength(3));
        final body = h.stored(createdDailyId).contentMd;
        expect(splitDailyBody(body).person.trimRight(), 'Morning pages');
        expect(_count(body, 'pages'), 1);
        expect(_count(body, 'Morning'), 1);
        expect(h.state.contentMd, 'Morning pages');
        expect(h.state.status, SaveStatus.clean);
        expect(h.queue, isEmpty);
        expect(h.c.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
      },
    );

    test(
      'a virtual Today create whose read back cannot reach the server queues its text and resolves as its own add when the server answers',
      () async {
        final h = await virtualToday(FakeVaultDb.v5());
        h.notes.readError = nasUnreachable();

        await h.typeAndSave('Morning pages');

        expect(adds(h), hasLength(1));
        expect(h.stored(createdDailyId), isNotNull);
        expect(h.state.contentMd, 'Morning pages');
        _expectNoErrorState(h);
        expect(h.queued(virtualId)!.text, 'Morning pages');
        expect(h.c.read(pendingSaveLabelProvider(virtualId)), pendingLabelNas);
        expect(h.c.read(notePendingSaveProvider(virtualId)), isTrue);

        h.notes.readError = null;
        await h.serverAnswers();
        await h.fireDebounce();

        expect(adds(h), hasLength(2));
        final body = h.stored(createdDailyId).contentMd;
        expect(_count(body, 'Morning pages'), 1);
        expect(h.c.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.errorMessage, isNull);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a queued virtual Today create whose retry fails with another error holds its text and the next edit tries again',
      () async {
        final h = await virtualToday(FakeVaultDb.v5());
        h.serverDown();
        await h.typeAndSave('Morning pages');
        h.notes.writeError = MemexException('add failed: disk full');

        await h.recoveryThatFails();

        expect(adds(h), hasLength(2));
        expect(h.state.status, SaveStatus.error);
        expect(h.state.errorMessage, 'add failed: disk full');
        expect(h.state.contentMd, 'Morning pages');
        expect(h.queued(virtualId)!.text, 'Morning pages');
        expect(h.c.read(notePendingSaveProvider(virtualId)), isTrue);
        expect(h.c.read(pendingSaveLabelProvider(virtualId)), isNull);

        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
        await h.recoveryThatFails();
        expect(adds(h), hasLength(2));

        h.notes.writeError = null;
        await h.typeAndSave('Morning pages\nMore.');

        expect(adds(h), hasLength(3));
        expect(
          splitDailyBody(h.stored(createdDailyId).contentMd).person.trimRight(),
          'Morning pages\nMore.',
        );
        expect(h.queue, isEmpty);
        expect(h.c.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
        expect(h.state.status, SaveStatus.clean);
      },
    );

    // Verify mode (fix round 1): `_createDaily` releases a held create when
    // the edit can't be sent because the status isn't connected.
    test(
      'an edit of a held virtual Today create while the server cannot be reached waits for the server with the label',
      () async {
        final h = await virtualToday(_plainVault());
        h.serverDown();
        await h.typeAndSave('Morning pages');
        h.notes.writeError = MemexException('add failed: disk full');
        await h.recoveryThatFails();
        expect(h.state.status, SaveStatus.error);
        expect(h.c.read(pendingSaveLabelProvider(virtualId)), isNull);

        // The poll sees the server drop before the next edit.
        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
        await h.typeAndSave('Morning pages\nMore.');

        expect(adds(h), hasLength(2));
        expect(h.state.contentMd, 'Morning pages\nMore.');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);
        expect(h.queued(virtualId)!.text, 'Morning pages\nMore.');
        expect(h.c.read(pendingSaveLabelProvider(virtualId)), pendingLabelNas);

        // Away and back: the old error is gone too.
        h.ctrl.loadNote(h.stored(_planId));
        h.ctrl.loadNote(virtualTodayNote(_today));
        expect(h.state.contentMd, 'Morning pages\nMore.');
        _expectNoErrorState(h);

        await h.serverAnswers();
        await h.fireDebounce();

        expect(adds(h), hasLength(3));
        expect(
          splitDailyBody(h.stored(createdDailyId).contentMd).person.trimRight(),
          'Morning pages\nMore.',
        );
        expect(h.queue, isEmpty);
        expect(h.c.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
        expect(h.state.status, SaveStatus.clean);
      },
    );
  });

  // Verify mode (fix round 1): contracts the fix round added.
  group('fix round contracts', () {
    test(
      'an edit of a held save while the server cannot be reached waits for the server with the label and retries on the next recovery',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        h.notes.writeError = MemexException('update failed: disk full');
        await h.recoveryThatFails();
        expect(h.state.status, SaveStatus.error);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);

        // The poll sees the server drop before the next edit.
        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
        await h.typeAndSave('newer text');

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.c.read(pendingSaveLabelProvider(_planId)), pendingLabelNas);

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), hasLength(3));
        expect(h.notes.writes.last, 'updateNote:$_planId@3');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'an older first save that fails after a later save of the same note queued keeps the newer queued text',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        final older = Completer<void>();
        h.notes.writeGate = older;
        await h.typeAndSave('new text');

        // Away and back while the first save is in flight; the next edit's
        // save goes out and fails first.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        final newer = Completer<void>();
        h.notes.writeGate = newer;
        await h.typeAndSave('newer text');
        expect(h.notes.updatesOf(_planId), hasLength(2));
        h.notes.writeGate = null;
        newer.complete();
        await pumpEventQueue();
        expect(h.queued(_planId)!.text, 'newer text');

        older.complete();
        await pumpEventQueue();

        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.state.contentMd, 'newer text');
        _expectNoErrorState(h);

        await h.serverAnswers();

        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'returning to a note whose server copy changed while its first save was in flight does not fill the editor from the queue',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        final gate = Completer<void>();
        h.notes.writeGate = gate;
        await h.typeAndSave('new text');
        // Another writer changes the note on the server meanwhile.
        _foreignWrite(h.db, _planId, 'their text', 4);

        // Away and back: the host loads the newer server copy.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.lastSavedVersion, 4);
        h.notes.writeGate = null;
        gate.complete();
        await pumpEventQueue();

        // The failed save is queued on its own base; the editor keeps the
        // copy it loaded.
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.state.contentMd, 'their text');
        expect(h.state.lastSavedVersion, 4);
      },
    );

    test(
      'returning to a vault whose server already reads connected retries its queued saves once per open',
      () async {
        const otherVault = HostedVaultRef(hostedServerId, 'other');
        Future<void> openVault(_H h, VaultRef vault) async {
          h.c.read(currentVaultProvider.notifier).state = vault;
          h.c.read(vaultAccessProvider);
          await pumpEventQueue();
        }

        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        h.serverDown();
        await h.typeAndSave('new text');
        final planNotes = h.notes;

        await openVault(h, otherVault);
        h.ctrl.loadNote(null);
        // The poll records connected while the other vault is open; the
        // server still drops writes, and their outcome is not recorded, so
        // the status keeps reading connected.
        setHostedStatus(h.c, HostedConnectionStatus.connected);
        planNotes.onOutcome = null;
        await pumpEventQueue();
        expect(planNotes.updatesOf(_planId), hasLength(1));

        await openVault(h, hostedPlanVault);
        expect(planNotes.updatesOf(_planId), hasLength(2));
        expect(h.queued(_planId)!.text, 'new text');

        // Note loads, revision bumps, a rebuilt vault access and setting the
        // same vault again retry nothing more.
        h.ctrl.loadNote(h.stored(_planId));
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        h.c.read(vaultRevisionProvider.notifier).state++;
        h.c.invalidate(vaultAccessProvider);
        h.c.read(vaultAccessProvider);
        h.c.read(currentVaultProvider.notifier).state = hostedPlanVault;
        await pumpEventQueue();
        h.clock.advance(const Duration(minutes: 5));
        await pumpEventQueue();
        expect(planNotes.updatesOf(_planId), hasLength(2));

        // The next open retries once again.
        await openVault(h, otherVault);
        await openVault(h, hostedPlanVault);
        expect(planNotes.updatesOf(_planId), hasLength(3));
        expect(h.doubles.notesFor(otherVault).writes, isEmpty);
      },
    );
  });

  // Lead ruling (verify, fix round 1): a later successful save of the same
  // note never leaves older text queued; the newer text is on the server.
  group('a later successful save supersedes an older failed one', () {
    test(
      'an older first save that fails after a newer save of the same note succeeded leaves nothing queued',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final older = Completer<void>();
        h.notes.writeGate = older;
        await h.typeAndSave('new text');

        // Away and back while the first save is in flight; the next edit
        // saves.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        h.notes.writeGate = null;
        await h.typeAndSave('newer text');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 4);

        // The first save then fails as unreachable.
        h.serverDown();
        older.complete();
        await pumpEventQueue();

        expect(h.queue, isEmpty);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);
        expect(h.c.read(notePendingSaveProvider(_planId)), isFalse);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);

        await h.serverAnswers();
        await h.fireDebounce();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        _expectNoErrorState(h);
      },
    );

    test(
      'an older first save that fails while a newer save of the same note is in flight leaves nothing queued once the newer save succeeds',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final older = Completer<void>();
        h.notes.writeGate = older;
        await h.typeAndSave('new text');

        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        final newer = Completer<void>();
        h.notes.writeGate = newer;
        await h.typeAndSave('newer text');
        h.notes.writeGate = null;

        // The first save fails as unreachable while the newer one is in
        // flight; then the newer one lands.
        h.serverDown();
        older.complete();
        await pumpEventQueue();
        h.notes.writeError = null;
        newer.complete();
        await pumpEventQueue();
        await h.fireDebounce();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.queue, isEmpty);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);
        expect(h.c.read(notePendingSaveProvider(_planId)), isFalse);
        _expectNoErrorState(h);
      },
    );
  });

  // Verify mode (fix round 2): the send-order contracts the fix handoff
  // listed as unpinned, and the stale-save open risk.
  group('writes of a note are ordered by when they were sent', () {
    /// Sends an older first save of Plan (`new text` on version 3, held at
    /// the returned gate), then leaves Plan and opens it again from the
    /// server copy (`old`, version 3).
    Future<Completer<void>> olderSaveInFlight(_H h) async {
      h.ctrl.loadNote(h.stored(_planId));
      final older = Completer<void>();
      h.notes.writeGate = older;
      await h.typeAndSave('new text');
      h.ctrl.loadNote(h.stored(_otherId));
      h.ctrl.loadNote(h.stored(_planId));
      expect(h.state.contentMd, 'old');
      expect(h.state.lastSavedVersion, 3);
      return older;
    }

    /// The newer save (`newer text` on version 3) can't reach the server
    /// while the older one is still in flight: it queues on version 3.
    Future<void> newerSaveQueued(_H h) async {
      final newer = Completer<void>();
      h.notes.writeGate = newer;
      await h.typeAndSave('newer text');
      h.notes.writeGate = null;
      h.serverDown();
      newer.complete();
      await pumpEventQueue();
      expect(h.queued(_planId)!.text, 'newer text');
      expect(h.queued(_planId)!.baseVersion, 3);
    }

    test(
      'an older save that succeeds after a newer save of the same note queued moves the queued save onto the saved version and the editor stays dirty',
      () async {
        final h = await _hosted(_plainVault());
        final older = await olderSaveInFlight(h);
        await newerSaveQueued(h);
        // The status keeps reading unreachable until the poll says
        // otherwise: the older save's outcome is not recorded.
        h.notes
          ..onOutcome = null
          ..writeError = null;

        older.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 4);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), pendingLabelNas);
        expect(h.c.read(notePendingSaveProvider(_planId)), isTrue);

        await h.serverAnswers();

        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
      },
    );

    test(
      'an older save that succeeds after a newer save of the same note queued leaves the newer text saved once the server answers',
      () async {
        final h = await _hosted(_plainVault());
        final older = await olderSaveInFlight(h);
        await newerSaveQueued(h);
        h.notes.writeError = null;

        // The older save lands and its outcome reads connected again.
        older.complete();
        await pumpEventQueue();
        await h.fireDebounce();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, h.stored(_planId).version);
        _expectNoErrorState(h);
      },
    );

    test(
      'a save elsewhere that fails after a later save of the same note succeeded queues nothing',
      () async {
        final db = _plainVault();
        final create = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: create);
        final h = await _hosted(db, cli: cli);
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        // Typed while the create is in flight, then the person leaves.
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));

        // The create lands; the save elsewhere of the typed text is held.
        final elsewhere = Completer<void>();
        h.notes.writeGate = elsewhere;
        create.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(createdDailyId), [
          'updateNote:$createdDailyId@1',
        ]);

        // The person opens the new note and saves an edit meanwhile.
        h.notes.writeGate = null;
        h.ctrl.loadNote(h.stored(createdDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        await h.typeAndSave(mine);
        expect(h.stored(createdDailyId).contentMd, mine);
        expect(h.state.status, SaveStatus.clean);

        // Then the save elsewhere fails as unreachable.
        h.serverDown();
        elsewhere.complete();
        await pumpEventQueue();

        expect(h.queue, isEmpty);
        expect(h.c.read(pendingSaveLabelProvider(createdDailyId)), isNull);
        expect(h.c.read(notePendingSaveProvider(createdDailyId)), isFalse);
        expect(h.stored(createdDailyId).contentMd, mine);
        expect(h.state.contentMd, mine);
        expect(h.state.status, SaveStatus.clean);
        _expectNoErrorState(h);
      },
    );

    test(
      'a retry counts as a later write so a save elsewhere sent before it that fails keeps the queued text',
      () async {
        final db = _plainVault()
          ..seedNote(
            id: _agentDailyId,
            title: _today,
            content: assembleDailyBody('Agent saw it.\n', const []),
            role: 'daily',
            version: 1,
          );
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreatesOnce(db);
        final h = await _hosted(db, cli: cli);
        // Today's note, opened as a note, queues an edit.
        h.ctrl.loadNote(h.stored(_agentDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        h.serverDown();
        await h.typeAndSave(mine);
        expect(h.queued(_agentDailyId)!.text, mine);
        // The status changes only when the test sets it.
        h.notes
          ..onOutcome = null
          ..writeError = null;

        // The virtual Today note's create answers daily_note_exists after
        // the person left it: its text is saved elsewhere (held).
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        final create = Completer<void>();
        h.notes.writeGate = create;
        await h.typeAndSave('Morning pages');
        h.ctrl.loadNote(h.stored(_planId));
        final elsewhere = Completer<void>();
        h.notes.writeGate = elsewhere;
        create.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(_agentDailyId), hasLength(2));

        // The server answers: the queued edit retries (held), after the
        // save elsewhere was sent.
        final retry = Completer<void>();
        h.notes.writeGate = retry;
        setHostedStatus(h.c, HostedConnectionStatus.connected);
        await pumpEventQueue();
        expect(h.notes.updatesOf(_agentDailyId), hasLength(3));
        expect(h.notes.updateBodies.last, mine);

        // The save elsewhere fails as unreachable: the retry is later.
        h.notes.writeError = nasUnreachable();
        elsewhere.complete();
        await pumpEventQueue();

        expect(h.queued(_agentDailyId)!.text, mine);
        expect(h.queued(_agentDailyId)!.baseVersion, 1);

        h.notes.writeError = null;
        retry.complete();
        await pumpEventQueue();

        expect(h.stored(_agentDailyId).contentMd, mine);
        expect(h.stored(_agentDailyId).version, 2);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a stale save that succeeds after the note was opened again and edited keeps the editor dirty and the newer text still saves',
      () async {
        final h = await _hosted(_plainVault());
        final older = await olderSaveInFlight(h);
        // Edited after opening it again; the debounce has not fired yet.
        h.ctrl.onContentChanged('newer text');
        h.notes.writeGate = null;

        older.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);

        await h.fireDebounce();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, h.stored(_planId).version);
        _expectNoErrorState(h);
        expect(h.queue, isEmpty);
      },
    );

    // Lead ruling (fix round 3): a successful save of a note never drops a
    // queued edit whose text it did not send.
    test(
      'a save elsewhere that succeeds while an older edit of the note is queued keeps the queued text and it still saves',
      () async {
        final db = _plainVault()
          ..seedNote(
            id: _agentDailyId,
            title: _today,
            content: assembleDailyBody('Agent saw it.\n', const []),
            role: 'daily',
            version: 1,
          );
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreatesOnce(db);
        final h = await _hosted(db, cli: cli);
        // Today's note, opened as a note, queues an edit.
        h.ctrl.loadNote(h.stored(_agentDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        h.serverDown();
        await h.typeAndSave(mine);
        expect(h.queued(_agentDailyId)!.text, mine);
        // The status changes only when the test sets it.
        h.notes
          ..onOutcome = null
          ..writeError = null;

        // The virtual Today note's create answers daily_note_exists after
        // the person left it: its text is saved elsewhere, and lands.
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        final create = Completer<void>();
        h.notes.writeGate = create;
        await h.typeAndSave('Morning pages');
        h.ctrl.loadNote(h.stored(_planId));
        h.notes.writeGate = null;
        create.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(_agentDailyId), hasLength(2));
        expect(h.stored(_agentDailyId).version, 2);

        expect(h.queued(_agentDailyId)!.text, mine);
        expect(h.queued(_agentDailyId)!.baseVersion, 1);
        expect(h.c.read(notePendingSaveProvider(_agentDailyId)), isTrue);

        // The server answers: the queued edit retries, meets the saved
        // text as a conflict and merges (a daily note).
        setHostedStatus(h.c, HostedConnectionStatus.connected);
        await pumpEventQueue();

        expect(
          splitDailyBody(h.stored(_agentDailyId).contentMd).person,
          contains('Mine.'),
        );
        expect(h.queue, isEmpty);
      },
    );

    // Lead ruling (fix round 4): a failed save elsewhere never puts its
    // content over an older queued edit of the note; the virtual Today
    // text it carried is appended to the queued person section (C3.1).
    test(
      'a save elsewhere that fails while an older edit of the note is queued keeps the queued text',
      () async {
        final db = _plainVault()
          ..seedNote(
            id: _agentDailyId,
            title: _today,
            content: assembleDailyBody('Agent saw it.\n', const []),
            role: 'daily',
            version: 1,
          );
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreatesOnce(db);
        final h = await _hosted(db, cli: cli);
        // Today's note, opened as a note, queues an edit.
        h.ctrl.loadNote(h.stored(_agentDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        h.serverDown();
        await h.typeAndSave(mine);
        expect(h.queued(_agentDailyId)!.text, mine);
        // The status changes only when the test sets it.
        h.notes
          ..onOutcome = null
          ..writeError = null;

        // The virtual Today note's create answers daily_note_exists after
        // the person left it; the server then stops answering, so its save
        // elsewhere can't reach it.
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        final create = Completer<void>();
        h.notes.writeGate = create;
        await h.typeAndSave('Morning pages');
        h.ctrl.loadNote(h.stored(_planId));
        h.notes
          ..writeGate = null
          ..onOutcome = (_) {
            h.notes.onOutcome = null;
            h.serverDown();
          };
        create.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(_agentDailyId), hasLength(2));
        expect(h.stored(_agentDailyId).version, 1);

        // The queued edit keeps its text and base; the virtual Today text
        // is appended to its person section.
        final queued = h.queued(_agentDailyId)!;
        expect(
          queued.text,
          assembleDailyBody(
            appendToPerson('Mine.\n', 'Morning pages'),
            const [],
          ),
        );
        expect(queued.baseVersion, 1);
        expect(h.c.read(notePendingSaveProvider(_agentDailyId)), isTrue);

        // The server answers: the queued edit retries and saves both.
        await h.serverAnswers();
        final person = splitDailyBody(h.stored(_agentDailyId).contentMd).person;
        expect(person, contains('Mine.'));
        expect(person, contains('Morning pages'));
        expect(person, isNot(contains('Agent saw it.')));
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a save elsewhere that succeeds after a later save of the same note queued moves the queued save onto its version before the retry',
      () async {
        final db = _plainVault();
        final create = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: create);
        final h = await _hosted(db, cli: cli);
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        // Typed while the create is in flight, then the person leaves.
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));

        // The create lands; the save elsewhere of the typed text is held.
        final elsewhere = Completer<void>();
        h.notes.writeGate = elsewhere;
        create.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(createdDailyId), [
          'updateNote:$createdDailyId@1',
        ]);

        // The person opens the new note; their edit can't reach the server
        // and queues on version 1.
        h.notes.writeGate = null;
        h.ctrl.loadNote(h.stored(createdDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        h.serverDown();
        await h.typeAndSave(mine);
        expect(h.queued(createdDailyId)!.text, mine);
        expect(h.queued(createdDailyId)!.baseVersion, 1);

        // The save elsewhere then lands, and its outcome reads connected.
        h.notes.writeError = null;
        elsewhere.complete();
        await pumpEventQueue();

        // The queued edit retried once, on the version the save elsewhere
        // stored: no conflict.
        expect(h.notes.updatesOf(createdDailyId), [
          'updateNote:$createdDailyId@1',
          'updateNote:$createdDailyId@1',
          'updateNote:$createdDailyId@2',
        ]);
        expect(h.notes.updateBodies.last, mine);
        expect(h.stored(createdDailyId).contentMd, mine);
        expect(h.stored(createdDailyId).version, 3);
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, mine);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 3);
        _expectNoErrorState(h);
      },
    );
  });

  // Fix rounds 3 and 4: how a save that lands late meets the editor and the
  // queue, and how a failed save elsewhere meets an older queued edit.
  group('a late save meets the editor and the queue', () {
    /// Plan open; its first save (`new text` on version 3) is held at the
    /// returned gate.
    Future<Completer<void>> firstSaveHeld(_H h) async {
      h.ctrl.loadNote(h.stored(_planId));
      final first = Completer<void>();
      h.notes.writeGate = first;
      await h.typeAndSave('new text');
      h.notes.writeGate = null;
      expect(h.state.status, SaveStatus.saving);
      return first;
    }

    test(
      'a save that lands after the note was opened again and not edited shows what it saved and is clean',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final first = Completer<void>();
        h.notes.writeGate = first;
        h.ctrl.onTitleChanged('Plan B');
        await h.typeAndSave('new text');
        h.notes.writeGate = null;
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.title, 'Plan');
        expect(h.state.contentMd, 'old');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 3);

        first.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.title, 'Plan B');
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);

        // Nothing is left to save.
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), ['updateNote:$_planId@3']);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'an older save that lands after a newer save of the same text queued removes the queued save',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final first = Completer<void>();
        h.notes.writeGate = first;
        await h.typeAndSave('new text');
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        // The same text typed again can't reach the server and queues.
        final second = Completer<void>();
        h.notes.writeGate = second;
        await h.typeAndSave('new text');
        h.notes.writeGate = null;
        h.serverDown();
        second.complete();
        await pumpEventQueue();
        expect(h.queued(_planId)!.text, 'new text');
        // The status keeps reading unreachable: no retry runs.
        h.notes
          ..onOutcome = null
          ..writeError = null;

        first.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.queue, isEmpty);
        expect(h.c.read(pendingSaveLabelProvider(_planId)), isNull);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);
        await h.serverAnswers();
        expect(h.notes.updatesOf(_planId), hasLength(2));
      },
    );

    test(
      'a save that lands while a later save of the note is in flight leaves the editor saving',
      () async {
        final h = await _hosted(_plainVault());
        final first = await firstSaveHeld(h);
        // Left and opened again while the save is in flight: an edit typed
        // in this later load is not held behind the earlier load's save
        // (fix round 5 ruling), so a later save of the note is in flight.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        final second = Completer<void>();
        h.notes.writeGate = second;
        await h.typeAndSave('newer text');
        h.notes.writeGate = null;
        expect(h.notes.updatesOf(_planId), hasLength(2));

        first.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.saving);
        expect(h.state.lastSavedVersion, 3);
        _expectNoErrorState(h);
        // No third save is scheduled by the first save landing.
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), hasLength(2));
        second.complete();
        await pumpEventQueue();
      },
    );

    test(
      'a save that lands after an edit typed during it leaves the editor dirty and the edit saves on its own debounce',
      () async {
        final h = await _hosted(_plainVault());
        final first = await firstSaveHeld(h);
        // Typed during the save; its debounce is 400 ms in when the save
        // lands.
        h.ctrl.onContentChanged('newer text');
        h.clock.advance(const Duration(milliseconds: 400));
        await pumpEventQueue();

        first.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);

        // The edit's own debounce fires on time (not restarted).
        h.clock.advance(const Duration(milliseconds: 100));
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
      },
    );

    test(
      'a save that lands after a later save of an edit failed schedules the edit to save again',
      () async {
        final h = await _hosted(_plainVault());
        final first = await firstSaveHeld(h);
        // Left and opened again while the save is in flight: the edit typed
        // in this later load is sent (not held, fix round 5 ruling) and
        // fails at once.
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        h.notes.writeError = MemexException('update failed: disk full');
        await h.typeAndSave('newer text');
        expect(h.state.status, SaveStatus.error);
        h.notes.writeError = null;

        first.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        expect(h.state.lastSavedVersion, 4);

        await h.fireDebounce();

        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
      },
    );

    test(
      'an edit of a queued note waits for an older save of the note still in flight and then saves on the version it stored',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final first = Completer<void>();
        h.notes.writeGate = first;
        await h.typeAndSave('new text');
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        // The status keeps reading connected: only the test changes it.
        h.notes
          ..onOutcome = null
          ..writeGate = null;
        // The newer save can't reach the server and queues on version 3.
        h.serverDown();
        await h.typeAndSave('newer text');
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
        h.notes.writeError = null;

        // The person edits the queued note while the first save is held:
        // nothing is sent yet.
        await h.typeAndSave('newest text');
        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.queued(_planId)!.text, 'newest text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.notes.updateBodies.last, 'newest text');
        expect(h.stored(_planId).contentMd, 'newest text');
        expect(h.stored(_planId).version, 5);
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, 'newest text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
      },
    );

    // The save elsewhere of a virtual Today edit (held) lands after the
    // person queued an edit of the created note; [open]: that note is
    // still open when it lands (else Plan is).
    for (final (name, open) in [
      (
        'a save elsewhere that lands while a later queued edit of the note is open moves the editor onto the queued base',
        true,
      ),
      (
        'a save elsewhere that lands while a later queued edit of the note is not open leaves the open editor alone',
        false,
      ),
    ]) {
      test(name, () async {
        final db = _plainVault();
        final create = Completer<void>();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddDailyCreates(db, gate: create);
        final h = await _hosted(db, cli: cli);
        h.c.read(tabsProvider.notifier).openToday(date: _today);
        h.ctrl.loadNote(virtualTodayNote(_today));
        await h.typeAndSave('Morning pages');
        h.ctrl.onContentChanged('Morning pages\nMore.');
        h.ctrl.loadNote(h.stored(_planId));
        final elsewhere = Completer<void>();
        h.notes.writeGate = elsewhere;
        create.complete();
        await pumpEventQueue();

        h.notes.writeGate = null;
        h.ctrl.loadNote(h.stored(createdDailyId));
        final mine = assembleDailyBody('Mine.\n', const []);
        h.serverDown();
        await h.typeAndSave(mine);
        expect(h.queued(createdDailyId)!.baseVersion, 1);
        if (!open) h.ctrl.loadNote(h.stored(_planId));

        // It lands; the status keeps reading unreachable, so no retry.
        h.notes
          ..onOutcome = null
          ..writeError = null;
        elsewhere.complete();
        await pumpEventQueue();

        expect(h.stored(createdDailyId).version, 2);
        expect(h.queued(createdDailyId)!.text, mine);
        expect(h.queued(createdDailyId)!.baseVersion, 2);
        if (open) {
          expect(h.state.contentMd, mine);
          expect(h.state.lastSavedVersion, 2);
          expect(h.state.status, SaveStatus.dirty);
        } else {
          expect(h.state.contentMd, 'old');
          expect(h.state.lastSavedVersion, 3);
          expect(h.state.status, SaveStatus.clean);
        }
        _expectNoErrorState(h);
      });
    }

    /// Daily note [_agentDailyId] (`Agent saw it.`, version 1) queues the
    /// person's edit [mine] (server down); the status reads unreachable and
    /// only changes when the test sets it. With [hold], the queued save's
    /// retry then reaches the server and fails: it is held.
    Future<_H> agentEditQueued(String mine, {bool hold = false}) async {
      final db = _plainVault()
        ..seedNote(
          id: _agentDailyId,
          title: _today,
          content: assembleDailyBody('Agent saw it.\n', const []),
          role: 'daily',
          version: 1,
        );
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddDailyCreatesOnce(db);
      final h = await _hosted(db, cli: cli);
      h.ctrl.loadNote(h.stored(_agentDailyId));
      h.serverDown();
      await h.typeAndSave(mine);
      expect(h.queued(_agentDailyId)!.text, mine);
      if (hold) {
        h.notes.writeError = MemexException('update failed: disk full');
        await h.recoveryThatFails();
        expect(h.c.read(pendingSaveLabelProvider(_agentDailyId)), isNull);
        expect(h.notes.updatesOf(_agentDailyId), hasLength(2));
        setHostedStatus(h.c, HostedConnectionStatus.unreachable);
      }
      h.notes
        ..onOutcome = null
        ..writeError = null;
      return h;
    }

    /// The virtual Today note's create of [typed] answers
    /// daily_note_exists after the person left it for [leaveTo]; the server
    /// then stops answering, so its save elsewhere can't reach it.
    Future<void> saveElsewhereFails(_H h, String typed, Note leaveTo) async {
      h.c.read(tabsProvider.notifier).openToday(date: _today);
      h.ctrl.loadNote(virtualTodayNote(_today));
      final create = Completer<void>();
      h.notes.writeGate = create;
      await h.typeAndSave(typed);
      h.ctrl.loadNote(leaveTo);
      final writes = h.notes.updatesOf(_agentDailyId).length;
      h.notes
        ..writeGate = null
        ..onOutcome = (_) {
          h.notes.onOutcome = null;
          h.serverDown();
        };
      create.complete();
      await pumpEventQueue();
      expect(h.notes.updatesOf(_agentDailyId), hasLength(writes + 1));
      expect(h.stored(_agentDailyId).version, 1);
    }

    test(
      'a failed save elsewhere adds nothing to a queued edit whose person section already holds the text',
      () async {
        final mine = assembleDailyBody('Mine.\nMorning pages\n', ['Plan']);
        final h = await agentEditQueued(mine);

        await saveElsewhereFails(h, 'Morning pages\n\n', h.stored(_planId));

        expect(h.queued(_agentDailyId)!.text, mine);
        expect(h.queued(_agentDailyId)!.baseVersion, 1);
      },
    );

    test(
      'a failed save elsewhere appends to a queued edit and keeps its topic chips',
      () async {
        final mine = assembleDailyBody('Mine.\n', ['Plan']);
        final h = await agentEditQueued(mine);

        await saveElsewhereFails(h, 'Morning pages', h.stored(_planId));

        expect(
          h.queued(_agentDailyId)!.text,
          assembleDailyBody(appendToPerson('Mine.\n', 'Morning pages'), [
            'Plan',
          ]),
        );
      },
    );

    test(
      'a failed save elsewhere releases a held older queued edit so it waits for the server again',
      () async {
        final mine = assembleDailyBody('Mine.\n', const []);
        final h = await agentEditQueued(mine, hold: true);

        await saveElsewhereFails(h, 'Morning pages', h.stored(_planId));

        final appended = assembleDailyBody(
          appendToPerson('Mine.\n', 'Morning pages'),
          const [],
        );
        expect(h.queued(_agentDailyId)!.text, appended);
        expect(
          h.c.read(pendingSaveLabelProvider(_agentDailyId)),
          pendingLabelNas,
        );

        // The next recovery retries it.
        await h.serverAnswers();
        expect(h.stored(_agentDailyId).contentMd, appended);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a failed save elsewhere shows the appended text in the open editor of the queued note',
      () async {
        final mine = assembleDailyBody('Mine.\n', const []);
        final h = await agentEditQueued(mine);

        await saveElsewhereFails(h, 'Morning pages', h.stored(_agentDailyId));

        final appended = assembleDailyBody(
          appendToPerson('Mine.\n', 'Morning pages'),
          const [],
        );
        expect(h.queued(_agentDailyId)!.text, appended);
        expect(h.state.contentMd, appended);
        expect(h.state.lastSavedVersion, 1);
        _expectNoErrorState(h);

        await h.serverAnswers();
        expect(h.stored(_agentDailyId).contentMd, appended);
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, appended);
        expect(h.state.status, SaveStatus.clean);
      },
    );
  });

  // Fix round 5 (verifier finding, lead ruling): a plain save never goes out
  // while an earlier save of the note typed in the same editor load is in
  // flight (it is held and goes once that save's outcome is applied).
  group('an edit typed during a slow save waits for it', () {
    test(
      'an edit typed during a slow save is sent after it lands on the version it stored and never conflicts with it',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final slow = Completer<void>();
        h.notes.writeGate = slow;
        await h.typeAndSave('new text');
        expect(h.notes.updatesOf(_planId), hasLength(1));
        expect(h.state.status, SaveStatus.saving);

        // Typed during the slow save; its debounce fires before it lands.
        await h.typeAndSave('newer text');

        expect(h.notes.updatesOf(_planId), hasLength(1));
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);

        h.notes.writeGate = null;
        slow.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), hasLength(2));
        expect(h.notes.writes.last, 'updateNote:$_planId@4');
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
        expect(h.queue, isEmpty);
      },
    );

    // Verify round 5: the contracts of the held save (`_deferredSaves`).

    /// Plan open; its first save (`new text` on version 3) is held at the
    /// returned gate.
    Future<Completer<void>> slowSave(_H h) async {
      h.ctrl.loadNote(h.stored(_planId));
      final first = Completer<void>();
      h.notes.writeGate = first;
      await h.typeAndSave('new text');
      h.notes.writeGate = null;
      expect(h.state.status, SaveStatus.saving);
      return first;
    }

    /// Daily note [_dailyId] open; its first save (`Morning pages\nLunch.` on
    /// version 3) is held at the returned gate while an agent appends
    /// `Agent note.` on the server (version 4), so it conflicts and merges.
    Future<Completer<void>> slowDailySave(_H h) async {
      h.ctrl.loadNote(h.stored(_dailyId));
      final first = Completer<void>();
      h.notes.writeGate = first;
      await h.typeAndSave('Morning pages\nLunch.');
      h.notes.writeGate = null;
      _foreignWrite(
        h.db,
        _dailyId,
        assembleDailyBody('Morning pages\nAgent note.\n', const []),
        4,
      );
      h.db.seedBlock(
        _dailyId,
        'a-agent',
        ord: 1,
        text: 'Agent note.',
        source: 'agent',
        createdVersion: 4,
      );
      return first;
    }

    test(
      'an edit typed during a slow save goes out as soon as the save lands and the editor reads saving until it does',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        expect(h.notes.updatesOf(_planId), hasLength(1));
        expect(h.state.status, SaveStatus.dirty);
        final second = Completer<void>();
        h.notes.writeGate = second;

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).contentMd, 'new text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.saving);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);
        // The landing save schedules no save of its own beside it.
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), hasLength(2));

        h.notes.writeGate = null;
        second.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
      },
    );

    test(
      'an edit typed during a slow save is not sent while it is in flight so a failing write shows no error and the edit saves once the save lands',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        h.notes.writeError = MemexException('update failed: disk full');
        await h.typeAndSave('newer text');
        expect(h.notes.updatesOf(_planId), hasLength(1));
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);
        h.notes.writeError = null;

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), hasLength(2));
      },
    );

    test(
      'a second debounce during a slow save replaces the held edit and after leaving the note only the latest text is sent on the version the save stored',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        await h.typeAndSave('newest text');
        expect(h.notes.updatesOf(_planId), hasLength(1));
        h.ctrl.loadNote(h.stored(_otherId));

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.notes.updateBodies, ['new text', 'newest text']);
        expect(h.stored(_planId).contentMd, 'newest text');
        expect(h.stored(_planId).version, 5);
        expect(h.queue, isEmpty);
        // The editor shows Other: the left note's saves never reach it.
        expect(h.state.contentMd, 'other body');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 7);
        _expectNoErrorState(h);
      },
    );

    test(
      'an edit typed back to the text of a slow save sends nothing more once the save lands',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        await h.typeAndSave('new text');

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), ['updateNote:$_planId@3']);
        expect(h.stored(_planId).version, 4);
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);
        await h.fireDebounce();
        expect(h.notes.updatesOf(_planId), ['updateNote:$_planId@3']);
      },
    );

    test(
      'a slow save that cannot reach the server queues the edit typed during it and sends nothing else',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        h.serverDown();

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), ['updateNote:$_planId@3']);
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.dirty);
        _expectNoErrorState(h);

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 4);
        expect(h.queue, isEmpty);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
      },
    );

    test(
      'a slow save that cannot reach the server after the note was left queues the edit typed during it and sends nothing else',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        h.ctrl.loadNote(h.stored(_otherId));
        h.serverDown();

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), ['updateNote:$_planId@3']);
        expect(h.queue, hasLength(1));
        expect(h.queued(_planId)!.text, 'newer text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.state.contentMd, 'other body');

        await h.serverAnswers();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 4);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a slow save that fails sends the edit typed during it on the same base right away',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        final second = Completer<void>();
        h.notes
          ..writeGate = second
          ..writeError = MemexException('update failed: disk full');

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@3',
        ]);
        expect(h.notes.updateBodies.last, 'newer text');
        expect(h.stored(_planId).version, 3);
        expect(h.state.status, SaveStatus.saving);
        expect(h.state.errorMessage, isNull);

        h.notes
          ..writeError = null
          ..writeGate = null;
        second.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 4);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);
        _expectNoErrorState(h);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'a slow save that lands after the note was left and opened again sends the edit typed before leaving on the version it stored and the reopened editor never reads saving',
      () async {
        final h = await _hosted(_plainVault());
        final first = await slowSave(h);
        await h.typeAndSave('newer text');
        h.ctrl.loadNote(h.stored(_otherId));
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'old');
        expect(h.state.status, SaveStatus.clean);
        final second = Completer<void>();
        h.notes.writeGate = second;

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_planId), [
          'updateNote:$_planId@3',
          'updateNote:$_planId@4',
        ]);
        expect(h.notes.updateBodies.last, 'newer text');
        // The held edit is in flight; the reopened editor shows what the
        // first save stored and is not saving.
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 4);

        h.notes.writeGate = null;
        second.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'newer text');
        expect(h.stored(_planId).version, 5);
        expect(h.state.contentMd, 'newer text');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
        _expectNoErrorState(h);
        expect(h.queue, isEmpty);
      },
    );

    test(
      'an edit typed during a slow daily save that merged goes as a merge from the same base and keeps the agent text',
      () async {
        final h = await _hosted(_dailyVault());
        final first = await slowDailySave(h);
        await h.typeAndSave('Morning pages\nLunch.\nDinner.');
        expect(h.notes.updatesOf(_dailyId), hasLength(1));

        first.complete();
        await pumpEventQueue();

        expect(h.notes.updatesOf(_dailyId), [
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@4',
          'updateNote:$_dailyId@5',
        ]);
        final stored = h.stored(_dailyId);
        expect(stored.version, 6);
        expect(_count(stored.contentMd, 'Agent note.'), 1);
        expect(_count(stored.contentMd, 'Lunch.'), 1);
        expect(_count(stored.contentMd, 'Dinner.'), 1);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 6);
        expect(h.state.contentMd, stored.contentMd);
        _expectNoErrorState(h);
      },
    );

    test(
      'a slow daily save that merged after the note was left never sends the edit typed during it over the merged text',
      () async {
        final h = await _hosted(_dailyVault());
        final first = await slowDailySave(h);
        await h.typeAndSave('Morning pages\nLunch.\nDinner.');
        // The merged write waits at a second gate; the note is left then.
        final merged = Completer<void>();
        h.notes.writeGate = merged;
        first.complete();
        await pumpEventQueue();
        expect(h.notes.updatesOf(_dailyId), [
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@4',
        ]);
        h.ctrl.loadNote(null);
        h.notes.writeGate = null;

        merged.complete();
        await pumpEventQueue();

        // The held edit goes on its own base, not on the merged version: it
        // meets the conflict, and only a merge on the merged version (@5)
        // writes it.
        expect(h.notes.updatesOf(_dailyId), [
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@4',
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@5',
        ]);
        final bodies = h.notes.updateBodies;
        expect(bodies, hasLength(4));
        // The merge write carries the merged agent text and the held edit.
        expect(_count(bodies[3], 'Agent note.'), 1);
        expect(_count(bodies[3], 'Lunch.'), 1);
        expect(_count(bodies[3], 'Dinner.'), 1);
        final stored = h.stored(_dailyId);
        expect(stored.version, 6);
        expect(stored.contentMd, bodies[3]);
        expect(_count(stored.contentMd, 'Agent note.'), 1);
        expect(_count(stored.contentMd, 'Lunch.'), 1);
        expect(_count(stored.contentMd, 'Dinner.'), 1);
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, '');
      },
    );

    test(
      'an edit typed during a slow daily save that is left while the save merges is merged and not lost',
      () async {
        final h = await _hosted(_dailyVault());
        final first = await slowDailySave(h);
        await h.typeAndSave('Morning pages\nLunch.\nDinner.');
        // The merged write waits at a second gate; the note is left then.
        final merged = Completer<void>();
        h.notes.writeGate = merged;
        first.complete();
        await pumpEventQueue();
        h.ctrl.loadNote(null);
        h.notes.writeGate = null;

        merged.complete();
        await pumpEventQueue();

        final stored = h.stored(_dailyId);
        expect(_count(stored.contentMd, 'Agent note.'), 1);
        expect(_count(stored.contentMd, 'Lunch.'), 1);
        expect(_count(stored.contentMd, 'Dinner.'), 1);
        expect(h.queue, isEmpty);
        expect(h.state.contentMd, '');
      },
    );
  });

  group('a conflict after the note was left is never dropped', () {
    test(
      'a plain save that conflicts after the note was left is kept as a held conflict and not lost',
      () async {
        final h = await _hosted(_plainVault());
        h.ctrl.loadNote(h.stored(_planId));
        final slow = Completer<void>();
        h.notes.writeGate = slow;
        await h.typeAndSave('new text');
        _foreignWrite(h.db, _planId, 'their text', 4);
        h.ctrl.loadNote(h.stored(_otherId));
        h.notes.writeGate = null;

        slow.complete();
        await pumpEventQueue();

        expect(h.stored(_planId).contentMd, 'their text');
        expect(h.queued(_planId)!.text, 'new text');
        expect(h.queued(_planId)!.baseVersion, 3);
        expect(h.c.read(notePendingSaveProvider(_planId)), isTrue);
        final entry = h.c
            .read(pendingSaveQueueProvider)
            .singleWhere((q) => q.save.noteId == _planId);
        expect(entry.heldStatus, SaveStatus.conflict);
        expect(entry.heldMessage, isNotNull);
        // The open note is untouched.
        expect(h.state.contentMd, 'other body');
        expect(h.state.status, SaveStatus.clean);

        // Reopened: the held text with its conflict, never the server copy.
        h.ctrl.loadNote(h.stored(_planId));
        expect(h.state.contentMd, 'new text');
        expect(h.state.status, SaveStatus.conflict);
        expect(h.state.lastSavedVersion, 3);

        // An edit resends on the held base and meets the conflict again.
        await h.typeAndSave('new text 2');
        expect(h.notes.updatesOf(_planId).last, 'updateNote:$_planId@3');
        expect(h.state.status, SaveStatus.conflict);
        expect(h.stored(_planId).contentMd, 'their text');
        expect(h.queued(_planId)!.text, 'new text 2');
      },
    );
  });
}
