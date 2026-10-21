// WI #78 (W2) AC7–AC10: EditorController's save, conflict refetch and
// virtual-Today first edit go through `VaultAccess` (D13, D16). The notes and
// daily domains are recording, Completer-gated doubles over a FakeVaultDb;
// `vaultDbProvider` is null, so a controller that still read SQLite directly
// would never see the stored note.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _topicId = '01J9TOPIC000000000000000078';
const _otherId = '01J9OTHER000000000000000078';
const _dailyId = '01J9DAILY000000000000000078';
const _existingId = '01J9EXIST000000000000000078';
const _today = '2026-10-03';

const _person = 'Morning pages\n';
final _typed = assembleDailyBody('Morning pages\nLunch with Sam.\n', const []);
final _typedMore = assembleDailyBody(
  'Morning pages\nLunch with Sam.\nAnd tea.\n',
  const [],
);
const _agentText = 'Agent saw it.';

class _Ed {
  _Ed(this.c, this.doubles, this.db, this.cli, this.clock);
  final ProviderContainer c;
  final EditorVaultDoubles doubles;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  int get revision => c.read(vaultRevisionProvider);
  EditorNotesAccess get notes => doubles.notes;
  EditorDailyAccess get daily => doubles.daily;

  /// The stored note, read straight from the database.
  Note stored(String id) => db.getNote(id)!;

  /// Fire the 500 ms save debounce and let every write and read finish.
  Future<void> fireDebounce() async {
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }
}

Future<_Ed> _editor(FakeVaultDb db, {FakeMemexCli? cli}) async {
  final dir = await Directory.systemTemp.createTemp('om78_editor');
  final fakeCli = cli ?? (FakeMemexCli()..onUpdateWrites(db));
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: fakeCli);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(fakeCli),
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
  // Build the vault access (and the doubles) before the editor uses it.
  c.read(vaultAccessProvider);
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _Ed(c, doubles, db, fakeCli, clock);
}

/// A daily note [_dailyId] for [_today] at version 3 holding [_person] (one
/// person block).
FakeVaultDb _dailyVault() {
  final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _dailyId, version: 3);
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    assembleDailyBody(_person, const []),
    _dailyId,
  ]);
  db.seedBlock(_dailyId, 'p-morning', ord: 0, text: 'Morning pages');
  return db;
}

/// The agent appends [_agentText] to [_dailyId] behind the editor's back:
/// the stored version becomes 4 and the new block has `created_version` 4.
void _agentAppends(FakeVaultDb db) {
  db.db.execute('UPDATE notes SET content_md = ?, version = 4 WHERE id = ?', [
    assembleDailyBody('$_person$_agentText\n', const []),
    _dailyId,
  ]);
  db.seedBlock(
    _dailyId,
    'a-agent',
    ord: 1,
    text: _agentText,
    source: 'agent',
    createdVersion: 4,
  );
}

/// An `update` handler that answers `version_conflict` [conflicts] times,
/// then writes like `memex update` (stdin body, version + 1).
void _onUpdateConflictsThenWrites(
  FakeMemexCli cli,
  FakeVaultDb db, {
  required int conflicts,
}) {
  var left = conflicts;
  cli.on('update', (call) {
    final id = call.flag('note-id')!;
    final current =
        (db.db.select('SELECT version FROM notes WHERE id = ?', [
                  id,
                ]).single['version']
                as num)
            .toInt();
    if (left > 0) {
      left--;
      return FakeMemexCli.error('version_conflict', 'version conflict', {
        'expected': int.parse(call.flag('expected-version')!),
        'current': current,
      });
    }
    db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
      call.stdinBody ?? '',
      current + 1,
      id,
    ]);
    return FakeMemexCli.ok(
      jsonEncode({
        'vault_id': '01HV0000000000000000000000',
        'note_id': id,
        'version': current + 1,
        'updated_at': 1759478400000,
      }),
    );
  });
}

void main() {
  group('saving a dirty note (AC7)', () {
    test(
      'saving a dirty note calls updateNote with expected_version through the notes domain and ends clean with one revision bump',
      () async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: _topicId, title: 'Plain', content: 'old', version: 3);
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        final before = e.revision;

        e.ctrl.onContentChanged('new text');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.notes.updateBodies, ['new text']);
        expect(e.cli.callsFor('update').single.flag('expected-version'), '3');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 4);
        expect(e.state.errorMessage, isNull);
        expect(e.revision, before + 1);
      },
    );
  });

  group('conflict refetch through VaultAccess (AC8)', () {
    test(
      'a daily note save that gets version_conflict refetches the note and its blocks through VaultAccess and retries once',
      () async {
        final db = _dailyVault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_dailyId));
        _agentAppends(db);
        final before = e.revision;

        e.ctrl.onContentChanged(_typed);
        await e.fireDebounce();

        expect(e.notes.writes, [
          'updateNote:$_dailyId@3',
          'updateNote:$_dailyId@4',
        ]);
        expect(e.notes.reads, contains('getNote:$_dailyId'));
        expect(e.daily.reads, contains('blocksForNote:$_dailyId'));
        final merged = e.notes.updateBodies.last;
        expect(merged, contains('Lunch with Sam.'));
        expect(merged, contains(_agentText));
        expect(e.stored(_dailyId).version, 5);
        expect(e.stored(_dailyId).contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
        expect(e.state.errorMessage, isNull);
        expect(e.revision, before + 1);
      },
    );

    test(
      'a second daily conflict keeps the local text and shows Couldnt save then merges on the next debounce tick',
      () async {
        final db = _dailyVault();
        final cli = FakeMemexCli();
        _onUpdateConflictsThenWrites(cli, db, conflicts: 2);
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(e.stored(_dailyId));
        _agentAppends(db);

        e.ctrl.onContentChanged(_typed);
        await e.fireDebounce();

        expect(e.notes.writes, hasLength(2));
        expect(e.state.contentMd, _typed);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, couldNotSaveMessage);
        final refetches = e.notes.reads
            .where((r) => r == 'getNote:$_dailyId')
            .length;

        await e.fireDebounce();

        expect(e.notes.writes, hasLength(3));
        expect(e.notes.writes.last, 'updateNote:$_dailyId@4');
        expect(
          e.notes.reads.where((r) => r == 'getNote:$_dailyId').length,
          greaterThan(refetches),
          reason: 'the next tick refetches through VaultAccess and merges',
        );
        expect(e.notes.updateBodies.last, contains(_agentText));
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.errorMessage, isNull);
      },
    );

    test(
      'a non-daily note conflict shows the conflict state and does not retry',
      () async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: _topicId, title: 'Plain', content: 'old', version: 3);
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        db.db.execute('UPDATE notes SET version = 4 WHERE id = ?', [_topicId]);
        final before = e.revision;

        e.ctrl.onContentChanged('mine');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, contains('version conflict'));
        expect(e.state.contentMd, 'mine');
        expect(e.revision, before);
      },
    );
  });

  group('in-flight reads (AC9, architect risk)', () {
    test(
      'text typed while a save refetch is in flight is kept and saved by the next save',
      () async {
        final db = _dailyVault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_dailyId));
        _agentAppends(db);
        e.ctrl.onContentChanged(_typed);
        e.doubles.hold();

        await e.fireDebounce();
        expect(
          e.doubles.notes.gate.waiting + e.doubles.daily.gate.waiting,
          greaterThan(0),
          reason: 'the conflict refetch is in flight',
        );
        expect(e.notes.writes, ['updateNote:$_dailyId@3']);

        e.ctrl.onContentChanged(_typedMore);
        e.doubles.release();
        await pumpEventQueue();

        expect(e.state.contentMd, _typedMore, reason: 'typed text is kept');
        expect(e.state.status, SaveStatus.dirty);

        await e.fireDebounce();

        expect(e.notes.updateBodies.last, contains('And tea.'));
        expect(e.notes.updateBodies.last, contains(_agentText));
        expect(e.stored(_dailyId).contentMd, contains('And tea.'));
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.contentMd, contains('And tea.'));
      },
    );

    test(
      'a note switch during an in-flight refetch never applies that read to the new note',
      () async {
        final db = _dailyVault()
          ..seedNote(
            id: _otherId,
            title: 'Other',
            content: 'other body',
            version: 1,
          );
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_dailyId));
        _agentAppends(db);
        e.ctrl.onContentChanged(_typed);
        e.doubles.hold();
        await e.fireDebounce();
        expect(
          e.doubles.notes.gate.waiting + e.doubles.daily.gate.waiting,
          greaterThan(0),
        );

        e.ctrl.loadNote(e.stored(_otherId));
        e.doubles.release();
        await pumpEventQueue();

        expect(e.state.title, 'Other');
        expect(e.state.contentMd, 'other body');
        expect(e.state.lastSavedVersion, 1);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.errorMessage, isNull);
        expect(
          e.notes.writes.where((w) => w.startsWith('updateNote:$_otherId')),
          isEmpty,
        );
        expect(e.stored(_otherId).contentMd, 'other body');
      },
    );
  });

  group('virtual Today first edit (AC10)', () {
    test(
      'the virtual Today first edit creates the daily note through addNote with role daily and the date as title',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddDailyCreates(db)
          ..onUpdateWrites(db);
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(virtualTodayNote(_today));
        final before = e.revision;

        e.ctrl.onContentChanged('hi');
        await e.fireDebounce();

        expect(e.notes.writes.first, 'addNote:$_today:daily');
        final add = cli.callsFor('add').single;
        expect(add.flag('role'), 'daily');
        expect(add.flag('title'), _today);
        expect(add.stdinBody, 'hi');
        expect(
          e.notes.reads,
          contains('getNote:$createdDailyId'),
          reason: 'the created note is read back through VaultAccess',
        );
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 1);
        expect(e.state.contentMd, 'hi');
        expect(e.revision, greaterThan(before));
      },
    );

    test(
      'daily_note_exists resolves the virtual Today note to existing_id and saves the typed text there',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _existingId, version: 2);
        db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          assembleDailyBody('Earlier line\n', const []),
          _existingId,
        ]);
        final cli = FakeMemexCli()
          ..onAddReturns(
            FakeMemexCli.error(
              'daily_note_exists',
              'a daily note for $_today already exists: $_existingId',
              {'date': _today, 'existing_id': _existingId},
            ),
          )
          ..onUpdateWrites(db);
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(virtualTodayNote(_today));

        e.ctrl.onContentChanged('hi');
        await e.fireDebounce();

        expect(e.notes.writes, [
          'addNote:$_today:daily',
          'updateNote:$_existingId@2',
        ]);
        final saved = e.notes.updateBodies.single;
        expect(saved, contains('Earlier line'));
        expect(saved, contains('hi'));
        expect(e.stored(_existingId).contentMd, saved);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 3);
      },
    );

    test(
      'a failed virtual Today create keeps the typed text and shows the message',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddReturns(FakeMemexCli.error('internal', 'database is locked'));
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(virtualTodayNote(_today));

        e.ctrl.onContentChanged('hi');
        await e.fireDebounce();

        expect(e.notes.writes, ['addNote:$_today:daily']);
        expect(e.state.contentMd, 'hi');
        expect(e.state.status, SaveStatus.error);
        expect(e.state.errorMessage, contains('database is locked'));
      },
    );
  });
}
