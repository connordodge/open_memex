// WI #78 (W2) AC7–AC10: EditorController's save, conflict refetch and
// virtual-Today first edit go through `VaultAccess` (D13, D16). The notes and
// daily domains are recording, Completer-gated doubles over a FakeVaultDb;
// `vaultDbProvider` is null, so a controller that still read SQLite directly
// would never see the stored note.
import 'dart:async';
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

/// WI #16: the body a non-daily note is loaded with (its base text).
const _wi16Base = 'Alpha\nBravo\nCharlie\n';

/// WI #16: another writer (an agent) changes [id] to [body] at [version].
void _wi16ForeignWrite(FakeVaultDb db, String id, String body, int version) {
  db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
    body,
    version,
    id,
  ]);
}

/// WI #16: an `update` handler that writes like `memex update` (a
/// `version_conflict` unless `expected-version` is the stored version),
/// calling [before] with the 1-based call number first, so a test can make
/// another writer land between the conflict refetch and the merged save;
/// [holdFirst] keeps the first call in flight until it completes.
void _wi16VersionedUpdates(
  FakeMemexCli cli,
  FakeVaultDb db, {
  void Function(int call)? before,
  Future<void>? holdFirst,
}) {
  var calls = 0;
  cli.on('update', (call) async {
    calls++;
    before?.call(calls);
    if (calls == 1 && holdFirst != null) await holdFirst;
    final id = call.flag('note-id')!;
    final expected = int.parse(call.flag('expected-version')!);
    final current =
        (db.db.select('SELECT version FROM notes WHERE id = ?', [
                  id,
                ]).single['version']
                as num)
            .toInt();
    if (current != expected) {
      return FakeMemexCli.error(
        'version_conflict',
        'version conflict: expected $expected, current $current',
        {'expected': expected, 'current': current},
      );
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

/// WI #16: a vault with the non-daily note [_topicId] holding [_wi16Base] at
/// version 3 (role [role]; a plain note without one) and [_otherId].
FakeVaultDb _wi16Vault({String? role = 'topic'}) => FakeVaultDb.v5()
  ..seedNote(
    id: _topicId,
    title: 'Plain',
    content: _wi16Base,
    role: role,
    version: 3,
  )
  ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);

/// WI #16: the conflict refetches of [id] among [reads].
int _wi16Refetches(List<String> reads, String id) =>
    reads.where((r) => r == 'getNote:$id').length;

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

    // TEST-CHANGE (#16, Req 34a): a non-daily conflict now merges, so the
    // server changes the same line the person did (an overlap) for the
    // conflict state to stay.
    test(
      'a non-daily conflict where both sides changed the same line makes no save and keeps the local text in the conflict state',
      () async {
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _topicId,
            title: 'Plain',
            content: _wi16Base,
            role: 'topic',
            version: 3,
          );
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo theirs\nCharlie\n', 4);
        final before = e.revision;

        e.ctrl.onContentChanged('Alpha\nBravo mine\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, contains('version conflict'));
        expect(e.state.contentMd, 'Alpha\nBravo mine\nCharlie\n');
        expect(e.state.lastSavedVersion, 3);
        expect(e.stored(_topicId).contentMd, 'Alpha\nBravo theirs\nCharlie\n');
        expect(e.revision, before);

        // Nothing retries on its own: the next tick sends nothing.
        await e.fireDebounce();
        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.state.status, SaveStatus.conflict);
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

  group('non-daily conflict merge (WI 16, Req 34a)', () {
    test(
      'a local non-daily save that conflicts refetches once and saves the merged text once on the refetched version',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        final before = e.revision;
        final readsBefore = e.notes.reads.length;

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo\nCharlie theirs\n';
        expect(e.notes.writes, [
          'updateNote:$_topicId@3',
          'updateNote:$_topicId@4',
        ]);
        expect(
          _wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId),
          1,
          reason: 'one conflict is exactly one refetch',
        );
        expect(e.notes.updateBodies.last, merged);
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.stored(_topicId).version, 5);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
        expect(e.state.errorMessage, isNull);
        expect(e.revision, before + 1);

        // Saved: the next tick sends nothing more.
        await e.fireDebounce();
        expect(e.notes.writes, hasLength(2));
      },
    );

    test(
      'a plain note without a role merges a conflict like a topic note',
      () async {
        final db = _wi16Vault(role: null);
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha theirs\nBravo\nCharlie\n', 4);

        e.ctrl.onContentChanged('Alpha\nBravo\nCharlie mine\n');
        await e.fireDebounce();

        expect(e.notes.writes.last, 'updateNote:$_topicId@4');
        expect(
          e.stored(_topicId).contentMd,
          'Alpha theirs\nBravo\nCharlie mine\n',
        );
        expect(e.state.contentMd, 'Alpha theirs\nBravo\nCharlie mine\n');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
      },
    );

    test(
      'a non-daily conflict whose server text still equals the base saves the local text on the refetched version',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        // A write that changed only the version (a tag, say).
        db.db.execute('UPDATE notes SET version = 4 WHERE id = ?', [_topicId]);

        e.ctrl.onContentChanged('Alpha\nBravo mine\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, [
          'updateNote:$_topicId@3',
          'updateNote:$_topicId@4',
        ]);
        expect(e.stored(_topicId).contentMd, 'Alpha\nBravo mine\nCharlie\n');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
      },
    );

    test(
      'a merged save keeps the server footer below the merged person text',
      () async {
        const footer = '<!-- memex:topics -->\n[[Player Loop~about]]\n';
        const footerMore =
            '<!-- memex:topics -->\n[[Player Loop~about]]\n[[Combat~about]]\n';
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _topicId,
            title: 'Plain',
            content: '$_wi16Base$footer',
            role: 'topic',
            version: 3,
          );
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(
          db,
          _topicId,
          'Alpha\nBravo\nCharlie theirs\n$footerMore',
          4,
        );

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n$footer');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo\nCharlie theirs\n$footerMore';
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a local non-daily conflict where the server already holds the editor text counts as saved with no merge and no extra save',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        // Another writer stored exactly the text the person is typing.
        _wi16ForeignWrite(db, _topicId, 'Alpha mine\nBravo\nCharlie\n', 4);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.stored(_topicId).version, 4);
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie\n');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 4);
        expect(e.state.errorMessage, isNull);

        // The next save goes on the version the server holds.
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie mine\n');
        await e.fireDebounce();
        expect(e.notes.writes.last, 'updateNote:$_topicId@4');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
      },
    );

    test(
      'a merged save that conflicts again does not retry at once and the next debounce tick merges again',
      () async {
        final db = _wi16Vault();
        final cli = FakeMemexCli();
        _wi16VersionedUpdates(
          cli,
          db,
          before: (call) {
            // The agent writes again between the refetch and the merged
            // save.
            if (call == 2) {
              _wi16ForeignWrite(
                db,
                _topicId,
                'Alpha\nBravo theirs\nCharlie theirs\n',
                5,
              );
            }
          },
        );
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        final readsBefore = e.notes.reads.length;

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, [
          'updateNote:$_topicId@3',
          'updateNote:$_topicId@4',
        ]);
        expect(_wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId), 1);
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie\n');
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, couldNotSaveMessage);
        expect(e.stored(_topicId).version, 5);

        // Not at once: nothing more until the debounce comes due.
        await pumpEventQueue();
        e.clock.advance(saveDebounce - const Duration(milliseconds: 1));
        await pumpEventQueue();
        expect(e.notes.writes, hasLength(2));
        expect(_wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId), 1);

        e.clock.advance(const Duration(milliseconds: 1));
        await pumpEventQueue();

        const merged = 'Alpha mine\nBravo theirs\nCharlie theirs\n';
        expect(e.notes.writes, hasLength(3));
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(_wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId), 2);
        expect(e.notes.updateBodies.last, merged);
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.stored(_topicId).version, 6);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 6);
        expect(e.state.errorMessage, isNull);
      },
    );

    test(
      'a Vault Guide conflict with changes on different lines is not merged and shows the conflict state',
      () async {
        final db = _wi16Vault(role: 'guide');
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.stored(_topicId).contentMd, 'Alpha\nBravo\nCharlie theirs\n');
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie\n');
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, contains('version conflict'));

        await e.fireDebounce();
        expect(e.notes.writes, hasLength(1));
      },
    );

    test('a merge after two saves in a row uses the latest base', () async {
      final db = _wi16Vault();
      final e = await _editor(db);
      e.ctrl.loadNote(e.stored(_topicId));
      e.ctrl.onContentChanged('Alpha\nBravo\nCharlie mine\n');
      await e.fireDebounce();
      e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie mine\n');
      await e.fireDebounce();
      expect(e.state.lastSavedVersion, 5);
      // The agent puts the first line back; the person edits the second.
      _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie mine\n', 6);

      e.ctrl.onContentChanged('Alpha mine\nBravo mine\nCharlie mine\n');
      await e.fireDebounce();

      // Against the version 5 text the agent changed line 1 and the person
      // line 2; an older base would read the agent change as unchanged.
      const merged = 'Alpha\nBravo mine\nCharlie mine\n';
      expect(e.notes.writes.last, 'updateNote:$_topicId@6');
      expect(e.stored(_topicId).contentMd, merged);
      expect(e.state.contentMd, merged);
      expect(e.state.status, SaveStatus.clean);
      expect(e.state.lastSavedVersion, 7);
    });

    test(
      'a merge after a merged save uses the merged text as its base',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie theirs\n');
        expect(e.state.lastSavedVersion, 5);
        // The agent takes its own change back; the person edits line 2.
        _wi16ForeignWrite(db, _topicId, 'Alpha mine\nBravo\nCharlie\n', 6);

        e.ctrl.onContentChanged('Alpha mine\nBravo mine\nCharlie theirs\n');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo mine\nCharlie\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@6');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 7);
      },
    );

    for (final (name, viaOther) in [
      (
        'a merge after the editor reloaded the note uses the reloaded text as its base',
        false,
      ),
      (
        'a merge after the person came back to the note uses the text it opened with as its base',
        true,
      ),
    ]) {
      test(name, () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        if (viaOther) e.ctrl.loadNote(e.stored(_otherId));
        e.ctrl.loadNote(e.stored(_topicId));
        expect(e.state.lastSavedVersion, 4);
        // The agent takes its change back; the person edits line 1.
        _wi16ForeignWrite(db, _topicId, _wi16Base, 5);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie theirs\n');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo\nCharlie\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 6);
      });
    }

    test(
      'a merge after a foreign change was applied to the clean editor uses that change as its base',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        expect(await e.ctrl.serverChanged(_topicId), isTrue);
        expect(e.state.contentMd, 'Alpha\nBravo\nCharlie theirs\n');
        expect(e.state.lastSavedVersion, 4);
        _wi16ForeignWrite(db, _topicId, _wi16Base, 5);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie theirs\n');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo\nCharlie\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a save that conflicts after the person left the note merges against the base of that note',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        // The person leaves at once: the flushed save is still in flight
        // when the editor holds the other note.
        e.ctrl.flushPendingSave();
        e.ctrl.loadNote(e.stored(_otherId));
        await pumpEventQueue();

        expect(
          e.stored(_topicId).contentMd,
          'Alpha mine\nBravo\nCharlie theirs\n',
        );
        expect(e.stored(_topicId).version, 5);
        expect(e.stored(_otherId).contentMd, 'other body');
        expect(e.state.contentMd, 'other body');
        expect(e.state.status, SaveStatus.clean);

        // Opening the note again shows the stored merged text.
        e.ctrl.loadNote(e.stored(_topicId));
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie theirs\n');
        expect(e.state.status, SaveStatus.clean);
      },
    );
    test(
      'a non-daily conflict whose server text equals the local text but whose title differs still saves the title',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        e.ctrl.onTitleChanged('Renamed');
        // A write that changed only the version (a tag, say).
        db.db.execute('UPDATE notes SET version = 4 WHERE id = ?', [_topicId]);

        await e.fireDebounce();

        expect(e.notes.writes, [
          'updateNote:$_topicId@3',
          'updateNote:$_topicId@4',
        ]);
        expect(e.cli.callsFor('update').last.flag('title'), 'Renamed');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 5);
      },
    );

    test(
      'a Vault Guide conflict whose server text equals the local text stays a conflict',
      () async {
        final db = _wi16Vault(role: 'guide');
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha mine\nBravo\nCharlie\n', 4);

        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();

        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, contains('version conflict'));
        expect(e.state.lastSavedVersion, 3);
      },
    );

    test(
      'a merged save that conflicts again and then overlaps shows the conflict and is not retried on later ticks',
      () async {
        final db = _wi16Vault();
        final cli = FakeMemexCli();
        _wi16VersionedUpdates(
          cli,
          db,
          before: (call) {
            if (call == 2) {
              // The agent edits the line the person edits, too.
              _wi16ForeignWrite(
                db,
                _topicId,
                'Alpha theirs\nBravo\nCharlie theirs\n',
                5,
              );
            }
          },
        );
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();
        expect(e.state.errorMessage, couldNotSaveMessage);
        final readsBefore = e.notes.reads.length;

        await e.fireDebounce();

        // The second refetch finds the same line changed on both sides.
        expect(e.notes.writes, hasLength(2));
        expect(_wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId), 1);
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie\n');
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.errorMessage, contains('version conflict'));
        expect(e.state.errorMessage, isNot(couldNotSaveMessage));

        // Nothing is armed: later ticks neither refetch nor save.
        await e.fireDebounce();
        await e.fireDebounce();
        expect(e.notes.writes, hasLength(2));
        expect(_wi16Refetches(e.notes.reads.sublist(readsBefore), _topicId), 1);
      },
    );

    test(
      'a merge after a held conflict was opened again uses the base text of the held save',
      () async {
        final db = _wi16Vault();
        final e = await _editor(db);
        e.ctrl.loadNote(e.stored(_topicId));
        _wi16ForeignWrite(db, _topicId, 'Alpha\nBravo\nCharlie theirs\n', 4);
        e.ctrl.onContentChanged('Alpha\nBravo\nCharlie mine\n');
        e.ctrl.flushPendingSave();
        e.ctrl.loadNote(e.stored(_otherId));
        await pumpEventQueue();
        // Both sides changed the last line: the conflict is held.
        expect(e.notes.writes, ['updateNote:$_topicId@3']);
        // The agent takes its change back and edits the first line.
        _wi16ForeignWrite(db, _topicId, 'Alpha theirs\nBravo\nCharlie\n', 5);

        e.ctrl.loadNote(e.stored(_topicId));
        expect(e.state.status, SaveStatus.conflict);
        expect(e.state.contentMd, 'Alpha\nBravo\nCharlie mine\n');
        e.ctrl.onContentChanged('Alpha\nBravo mine\nCharlie mine\n');
        await e.fireDebounce();

        const merged = 'Alpha theirs\nBravo mine\nCharlie mine\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 6);
      },
    );

    test(
      'a merge after text was typed during a save that stored the earlier text uses that text as its base',
      () async {
        final db = _wi16Vault();
        final cli = FakeMemexCli();
        final hold = Completer<void>();
        _wi16VersionedUpdates(cli, db, holdFirst: hold.future);
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(e.stored(_topicId));
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        await e.fireDebounce();
        // The first save is in flight; the person types on.
        e.ctrl.onContentChanged('Alpha mine\nBravo mine\nCharlie\n');
        hold.complete();
        await pumpEventQueue();
        expect(e.stored(_topicId).version, 4);
        expect(e.state.status, SaveStatus.dirty);
        expect(e.state.lastSavedVersion, 4);
        _wi16ForeignWrite(
          db,
          _topicId,
          'Alpha mine\nBravo\nCharlie theirs\n',
          5,
        );

        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo mine\nCharlie theirs\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
      },
    );

    test(
      'a merge after a save landed on a note opened again uses the saved text as its base',
      () async {
        final db = _wi16Vault();
        final cli = FakeMemexCli();
        final hold = Completer<void>();
        _wi16VersionedUpdates(cli, db, holdFirst: hold.future);
        final e = await _editor(db, cli: cli);
        e.ctrl.loadNote(e.stored(_topicId));
        e.ctrl.onContentChanged('Alpha mine\nBravo\nCharlie\n');
        e.ctrl.flushPendingSave();
        await pumpEventQueue();
        e.ctrl.loadNote(e.stored(_otherId));
        e.ctrl.loadNote(e.stored(_topicId));
        hold.complete();
        await pumpEventQueue();
        expect(e.stored(_topicId).version, 4);
        expect(e.state.contentMd, 'Alpha mine\nBravo\nCharlie\n');
        expect(e.state.status, SaveStatus.clean);
        expect(e.state.lastSavedVersion, 4);
        _wi16ForeignWrite(
          db,
          _topicId,
          'Alpha mine\nBravo\nCharlie theirs\n',
          5,
        );

        e.ctrl.onContentChanged('Alpha mine\nBravo mine\nCharlie\n');
        await e.fireDebounce();

        const merged = 'Alpha mine\nBravo mine\nCharlie theirs\n';
        expect(e.notes.writes.last, 'updateNote:$_topicId@5');
        expect(e.stored(_topicId).contentMd, merged);
        expect(e.state.contentMd, merged);
        expect(e.state.status, SaveStatus.clean);
      },
    );
  });
}
