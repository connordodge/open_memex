// WI #78 (W2) verify mode: EditorController._createDaily reads the created
// daily note back through `VaultAccess.notes` (a new await). A failed or
// empty read-back must not leave the editor "saving" forever: per the WI and
// the method doc, on any failure other than `daily_note_exists` the text
// stays in the editor with the message, and the next edit tries again.
//
// The retry is safe: when it answers `daily_note_exists` with the id our
// failed add created, it resolves as that add (the text is not appended
// twice); any other `daily_note_exists` still appends (C3.1).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _today = '2026-10-03';

/// A daily note for [_today] that someone else created (not our add).
const _wi78OtherId = '01J9Z8Y7X6W5V4T3S2R1Q0P9ZZ';

/// A notes domain whose first [failGets] `getNote` reads fail ([throws]) or
/// find nothing.
class _Wi78ReadBackNotes extends EditorNotesAccess {
  _Wi78ReadBackNotes({
    required super.vaultPath,
    super.db,
    super.cli,
    required this.throws,
  });

  final bool throws;
  int failGets = 1;

  /// When set, the failing reads throw this instead.
  Object? error;

  @override
  Future<Note?> getNote(String id) async {
    if (failGets > 0) {
      failGets--;
      reads.add('getNote:$id');
      final thrown = error;
      if (thrown != null) throw thrown;
      if (throws) throw MemexException('read failed: database is locked');
      return null;
    }
    return super.getNote(id);
  }
}

/// One editor on the virtual Today note over [db] / [cli] whose notes domain
/// fails its first `getNote` read.
class _Wi78Harness {
  _Wi78Harness._(this.c, this.ctrl, this.notes, this.clock, this.db);

  static Future<_Wi78Harness> open(
    FakeVaultDb db,
    FakeMemexCli cli, {
    required bool throws,
  }) async {
    final dir = await Directory.systemTemp.createTemp('om78_readback');
    final clock = FakeClock(DateTime(2026, 10, 3, 9));
    late _Wi78ReadBackNotes notes;
    final c = ProviderContainer(
      overrides: [
        currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
        vaultDbProvider.overrideWithValue(null),
        memexCliProvider.overrideWithValue(cli),
        clockProvider.overrideWithValue(clock),
        vaultAccessProvider.overrideWith((ref) {
          final path = ref.watch(currentVaultProvider).localPath;
          if (path == null) return null;
          return LocalVaultAccess(
            vaultPath: path,
            db: db,
            cli: cli,
            notes: notes = _Wi78ReadBackNotes(
              vaultPath: path,
              db: db,
              cli: cli,
              throws: throws,
            ),
          );
        }),
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
    final ctrl = c.read(editorControllerProvider.notifier);
    ctrl.loadNote(virtualTodayNote(_today));
    return _Wi78Harness._(c, ctrl, notes, clock, db);
  }

  final ProviderContainer c;
  final EditorController ctrl;
  final _Wi78ReadBackNotes notes;
  final FakeClock clock;
  final FakeVaultDb db;

  EditorStateValue get state => c.read(editorControllerProvider);
  int get revision => c.read(vaultRevisionProvider);

  /// Types [text] and lets the debounced save run.
  Future<void> type(String text) async {
    ctrl.onContentChanged(text);
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }

  ({String content, int version}) stored(String id) {
    final row = db.db.select(
      'SELECT content_md, version FROM notes WHERE id = ?',
      [id],
    ).single;
    return (
      content: row['content_md'] as String,
      version: (row['version'] as num).toInt(),
    );
  }
}

MemexResult _wi78Exists(String existingId) => FakeMemexCli.error(
  'daily_note_exists',
  'a daily note for $_today already exists: $existingId',
  {'date': _today, 'existing_id': existingId},
);

/// `memex add --role daily`: the first call creates [createdDailyId] like the
/// real CLI; every later call runs [beforeRetry] once, then answers
/// `daily_note_exists` with [existingId].
void _wi78AddCreatesThenExists(
  FakeMemexCli cli,
  FakeVaultDb db, {
  required String existingId,
  void Function()? beforeRetry,
}) {
  var adds = 0;
  cli.on('add', (call) {
    adds++;
    if (adds == 2) beforeRetry?.call();
    if (adds > 1) return _wi78Exists(existingId);
    final date = call.flag('title')!;
    db.seedNote(
      id: createdDailyId,
      title: date,
      content: assembleDailyBody(
        splitDailyBody(call.stdinBody ?? '').person,
        const [],
      ),
      role: 'daily',
      version: 1,
    );
    return FakeMemexCli.ok(addDailyStdout(createdDailyId, date));
  });
}

/// Seeds [_wi78OtherId]: a daily note for [_today] whose person section is
/// exactly `hi` (the text the first add sends), at version 4.
void _wi78SeedOther(FakeVaultDb db) {
  db.seedNote(
    id: _wi78OtherId,
    title: _today,
    content: assembleDailyBody('hi\n', const []),
    role: 'daily',
    version: 4,
  );
}

/// [_wi78OtherId] after `hi there` is appended to its person section `hi`
/// (C3.1: blank-line separator, the Topics footer kept).
const _wi78Appended = 'hi\n\nhi there\n$topicsMarker\n';

void main() {
  group('virtual Today read back (EditorController._createDaily)', () {
    for (final (name, throws) in [
      (
        'a failed virtual Today read back does not leave the editor saving and keeps the typed text',
        true,
      ),
      (
        'an empty virtual Today read back does not leave the editor saving and keeps the typed text',
        false,
      ),
    ]) {
      test(name, () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddDailyCreates(db)
          ..onUpdateWrites(db);
        final h = await _Wi78Harness.open(db, cli, throws: throws);

        await h.type('hi');

        expect(h.notes.writes, ['addNote:$_today:daily']);
        expect(h.notes.reads, contains('getNote:$createdDailyId'));
        final state = h.state;
        expect(state.contentMd, 'hi', reason: 'the typed text stays');
        expect(
          state.status,
          isNot(SaveStatus.saving),
          reason: 'nothing is in flight any more',
        );
        expect(state.status, SaveStatus.error);
        expect(state.errorMessage, isNotNull);

        await h.type('hi there');

        expect(
          h.notes.writes.where((w) => w.startsWith('addNote:')),
          hasLength(2),
          reason: 'the next edit tries again',
        );
      });
    }

    test(
      'an empty virtual Today read back shows read failed: note <id> not found',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddDailyCreates(db)
          ..onUpdateWrites(db);
        final h = await _Wi78Harness.open(db, cli, throws: false);

        await h.type('hi');

        expect(h.state.status, SaveStatus.error);
        expect(
          h.state.errorMessage,
          'read failed: note $createdDailyId not found',
        );
      },
    );

    test('a failed virtual Today read back shows the CLI message', () async {
      final db = FakeVaultDb.v5();
      final cli = FakeMemexCli()
        ..onAddDailyCreates(db)
        ..onUpdateWrites(db);
      final h = await _Wi78Harness.open(db, cli, throws: true);

      await h.type('hi');

      expect(h.state.status, SaveStatus.error);
      expect(h.state.errorMessage, 'read failed: database is locked');
    });

    test(
      'a virtual Today read back that throws a non-Exception error still ends in error and keeps the typed text',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddDailyCreates(db)
          ..onUpdateWrites(db);
        final h = await _Wi78Harness.open(db, cli, throws: true);
        h.notes.error = StateError('row decode failed');

        await h.type('hi');

        expect(h.state.contentMd, 'hi');
        expect(h.state.status, SaveStatus.error);
        expect(h.state.errorMessage, 'Bad state: row decode failed');
      },
    );

    test(
      'a failed virtual Today read back does not bump the vault revision and the resolving retry does',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()..onUpdateWrites(db);
        _wi78AddCreatesThenExists(cli, db, existingId: createdDailyId);
        final h = await _Wi78Harness.open(db, cli, throws: true);
        final before = h.revision;

        await h.type('hi');

        expect(h.state.status, SaveStatus.error);
        expect(h.revision, before, reason: 'nothing resolved');

        await h.type('hi there');

        expect(h.state.status, SaveStatus.clean);
        expect(
          h.revision,
          before + 2,
          reason: 'one bump when the retry resolves, one for its update save',
        );
      },
    );
  });

  group('virtual Today retry after a failed read back', () {
    test(
      'a retry answered daily_note_exists with the id our failed add created saves the editor text once through update',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()..onUpdateWrites(db);
        _wi78AddCreatesThenExists(cli, db, existingId: createdDailyId);
        final h = await _Wi78Harness.open(db, cli, throws: true);

        await h.type('hi');
        expect(h.state.status, SaveStatus.error);
        await h.type('hi there');

        expect(h.notes.writes, [
          'addNote:$_today:daily',
          'addNote:$_today:daily',
          'updateNote:$createdDailyId@1',
        ]);
        expect(
          h.notes.updateBodies.single,
          'hi there',
          reason: 'the editor text replaces what our first add wrote',
        );
        final stored = h.stored(createdDailyId);
        expect(
          stored.content,
          'hi there',
          reason: "the first add's text is not appended twice",
        );
        expect(stored.version, 2, reason: 'one update after the create');
        expect(h.state.contentMd, 'hi there');
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 2);
      },
    );

    test(
      'a retry answered daily_note_exists with a different id still appends the latest text to that note person section',
      () async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()..onUpdateWrites(db);
        // Before the retry our note is gone and another device made today's
        // note, whose person section is exactly the text our failed add
        // sent: C3.1 appends to it, it never replaces it.
        _wi78AddCreatesThenExists(
          cli,
          db,
          existingId: _wi78OtherId,
          beforeRetry: () {
            db.db.execute('DELETE FROM notes WHERE id = ?', [createdDailyId]);
            _wi78SeedOther(db);
          },
        );
        final h = await _Wi78Harness.open(db, cli, throws: true);

        await h.type('hi');
        expect(h.state.status, SaveStatus.error);
        await h.type('hi there');

        expect(h.notes.writes, [
          'addNote:$_today:daily',
          'addNote:$_today:daily',
          'updateNote:$_wi78OtherId@4',
        ]);
        expect(h.notes.updateBodies.single, _wi78Appended);
        expect(h.stored(_wi78OtherId).content, _wi78Appended);
        expect(h.state.status, SaveStatus.clean);
        expect(h.state.lastSavedVersion, 5);
      },
    );

    test(
      'a failed read back of a daily_note_exists answer does not treat the retry as our own create',
      () async {
        final db = FakeVaultDb.v5();
        _wi78SeedOther(db);
        final cli = FakeMemexCli()
          ..onAddReturns(_wi78Exists(_wi78OtherId))
          ..onUpdateWrites(db);
        final h = await _Wi78Harness.open(db, cli, throws: true);

        await h.type('hi');
        expect(h.state.status, SaveStatus.error);
        await h.type('hi there');

        expect(h.notes.writes, [
          'addNote:$_today:daily',
          'addNote:$_today:daily',
          'updateNote:$_wi78OtherId@4',
        ]);
        expect(
          h.stored(_wi78OtherId).content,
          _wi78Appended,
          reason: 'the existing text stays and the latest text is appended',
        );
        expect(h.state.status, SaveStatus.clean);
      },
    );
  });
}
