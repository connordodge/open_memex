// WI #13 (Spec #7 A1, D16): the shared test seam of agent note edits. A2
// (#14, note menu + title icon) and A3 (#15, Activity tab Restore) use it from
// day one and never edit it. Frozen API (add, never change):
//
// - [agentEditsVaultPath], [agentEditsVaultId]: the local vault the pump
//   opens (never created on disk) and the vault id the fakes answer.
// - [AgentEditsVaultSeeds] on `FakeVaultDb`: [AgentEditsVaultSeeds.seedNoteRevision],
//   [AgentEditsVaultSeeds.setAgentReadOnlyForTest] (raw SQL, D15 style),
//   [AgentEditsVaultSeeds.agentReadOnlyForTest],
//   [AgentEditsVaultSeeds.downgradeAgentEditsToV7] and
//   [AgentEditsVaultSeeds.migrateAgentEditsToV8] (same handle, like the CLI
//   migrating while the app's handle stays open). [agentEditsV7Vault] is a
//   fresh vault exactly at V7.
// - [AgentEditsCliFakes.onAgentEdits] on `FakeMemexCli`: `read-only set`,
//   `read-only clear`, `revisions list` and `revisions restore` handlers that
//   behave like R4's CLI (D14 JSON) against a `FakeVaultDb`.
// - [FakeAgentEditsNotesAccess] (`extends LocalNotesAccess`, D21): records
//   every agent-edit call ([FakeAgentEditsNotesAccess.setAgentReadOnlyCalls],
//   [FakeAgentEditsNotesAccess.noteRevisionsCalls],
//   [FakeAgentEditsNotesAccess.restoreNoteRevisionCalls]), can hold a write
//   behind a Completer and make it throw a chosen error, and otherwise writes
//   the flag / the restored text straight into its `FakeVaultDb`, so the real
//   SQLite note read sees it. No CLI needed.
// - [pumpAgentEdits]: pumps a widget under an `UncontrolledProviderScope`
//   whose `currentVaultProvider` is [agentEditsVaultPath], `vaultDbProvider`
//   a `FakeVaultDb` (V8 by default), `memexCliProvider` a `FakeMemexCli`,
//   `clockProvider` a `FakeClock` and `vaultAccessProvider` a
//   `LocalVaultAccess` whose notes domain is a [FakeAgentEditsNotesAccess].
//   Returns an [AgentEditsHarness] that counts `vaultRevisionProvider` bumps.
//   The calling test file calls `holdFontFetches()` at the top of `main()`
//   (it registers `setUpAll`/`tearDownAll`, so it cannot run inside a test).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/note_edits_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'app_harness.dart' show pumpFrames;
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// The local vault folder [pumpAgentEdits] opens (never created on disk).
const agentEditsVaultPath = '/vaults/My Vault';

/// The `vault_id` every agent-edits fake answers.
const agentEditsVaultId = '01HV0000000000000000000013';

/// A fresh vault exactly at schema V7: no `notes.agent_read_only`, no
/// `note_revisions`, no `schema_version` row 8.
FakeVaultDb agentEditsV7Vault() => FakeVaultDb.v5()..downgradeAgentEditsToV7();

/// Agent-edit seeds and schema steps on a [FakeVaultDb].
extension AgentEditsVaultSeeds on FakeVaultDb {
  Set<String> _columnsOf(String table) => db
      .select('SELECT name FROM pragma_table_info(?)', [table])
      .map((r) => r['name'] as String)
      .toSet();

  bool get _hasFlagColumn => _columnsOf('notes').contains('agent_read_only');

  bool get _hasRevisionsTable => db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'note_revisions'",
      )
      .isNotEmpty;

  /// Removes what V8 adds: `note_revisions` and its triggers, the
  /// `notes.agent_read_only` column and the `schema_version` row 8.
  void downgradeAgentEditsToV7() {
    for (final s in const ['ai', 'au', 'ad']) {
      db.execute('DROP TRIGGER IF EXISTS "content_revision_note_revisions_$s"');
    }
    db.execute('DROP INDEX IF EXISTS idx_note_revisions_note');
    db.execute('DROP TABLE IF EXISTS note_revisions');
    if (_hasFlagColumn) {
      db.execute('ALTER TABLE notes DROP COLUMN agent_read_only');
    }
    db.execute('DELETE FROM schema_version WHERE version >= 8');
  }

  /// What `memex` does to a V7 vault on open, on this same handle: adds
  /// `notes.agent_read_only` (default 0, so existing notes stay writable),
  /// then replays the fixture idempotently (`note_revisions`, its index and
  /// triggers, the `schema_version` row 8).
  void migrateAgentEditsToV8() {
    if (!_hasFlagColumn) {
      db.execute(
        'ALTER TABLE notes ADD COLUMN agent_read_only INTEGER NOT NULL '
        'DEFAULT 0',
      );
    }
    migrateToV6();
  }

  /// Sets `notes.agent_read_only` of [noteId] with raw SQL (D15 style).
  void setAgentReadOnlyForTest(String noteId, bool on) => db.execute(
    'UPDATE notes SET agent_read_only = ? WHERE id = ?',
    [on ? 1 : 0, noteId],
  );

  /// The stored `notes.agent_read_only` of [noteId]; null when the note or
  /// the column is missing.
  bool? agentReadOnlyForTest(String noteId) {
    if (!_hasFlagColumn) return null;
    final rows = db.select('SELECT agent_read_only FROM notes WHERE id = ?', [
      noteId,
    ]);
    if (rows.isEmpty) return null;
    return (rows.first['agent_read_only'] as num) != 0;
  }

  /// Inserts one `note_revisions` row and returns [id]. `agent_changes` is
  /// not seeded (foreign keys are off in the fake).
  String seedNoteRevision({
    required String id,
    required String noteId,
    String? agentChangeId,
    String previousMd = 'previous text',
    int previousVersion = 1,
    int newVersion = 2,
    int createdAt = 1759500000000,
  }) {
    db.execute(
      'INSERT INTO note_revisions (id, note_id, previous_md, '
      'previous_version, new_version, agent_change_id, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        noteId,
        previousMd,
        previousVersion,
        newVersion,
        agentChangeId,
        createdAt,
      ],
    );
    return id;
  }

  /// Restores revision [revisionId] the way `memex revisions restore` does
  /// to the note text: the note takes the revision's `previous_md` and its
  /// version moves on by one. Returns the D14 restore object, or null when
  /// the revision (or the table) is missing.
  Map<String, Object?>? _restoreRevision(String revisionId) {
    if (!_hasRevisionsTable) return null;
    final rows = db.select(
      'SELECT note_id, previous_md FROM note_revisions WHERE id = ?',
      [revisionId],
    );
    if (rows.isEmpty) return null;
    final noteId = rows.first['note_id'] as String;
    final previous = rows.first['previous_md'] as String;
    final notes = db.select('SELECT version FROM notes WHERE id = ?', [noteId]);
    if (notes.isEmpty) return null;
    final version = (notes.first['version'] as num).toInt() + 1;
    db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
      previous,
      version,
      noteId,
    ]);
    return {
      'vault_id': agentEditsVaultId,
      'note_id': noteId,
      'version': version,
      'content_md': previous,
    };
  }

  bool _noteExists(String? noteId) =>
      noteId != null &&
      db.select('SELECT 1 FROM notes WHERE id = ?', [noteId]).isNotEmpty;
}

/// `read-only set|clear` and `revisions list|restore` handlers for
/// [FakeMemexCli] (D14 JSON).
extension AgentEditsCliFakes on FakeMemexCli {
  /// Registers handlers that behave like R4's CLI against [vault]:
  /// - `read-only set|clear --vault V --note-id N`: `not_found` for an
  ///   unknown note; else stores the flag and prints
  ///   `{vault_id, note_id, agent_read_only}`;
  /// - `revisions list --vault V --note-id N`: `not_found` for an unknown
  ///   note; else `{vault_id, revisions: [{id, agent_change_id,
  ///   created_at}]}` newest first (by `new_version`);
  /// - `revisions restore --vault V --revision-id R`: `not_found` for an
  ///   unknown revision; else the note takes the revision's text, its version
  ///   moves on by one, and it prints `{vault_id, note_id, version,
  ///   content_md}`.
  void onAgentEdits(FakeVaultDb vault) {
    MemexResult flag(FakeCliCall call, bool on) {
      final id = call.flag('note-id');
      if (!vault._noteExists(id)) {
        return FakeMemexCli.error('not_found', 'note not found: $id');
      }
      vault.setAgentReadOnlyForTest(id!, on);
      return FakeMemexCli.ok(
        '${jsonEncode({'vault_id': agentEditsVaultId, 'note_id': id, 'agent_read_only': on})}\n',
      );
    }

    on('read-only set', (call) => flag(call, true));
    on('read-only clear', (call) => flag(call, false));
    on('revisions list', (call) {
      final id = call.flag('note-id');
      if (!vault._noteExists(id)) {
        return FakeMemexCli.error('not_found', 'note not found: $id');
      }
      final rows = vault._hasRevisionsTable
          ? vault.db.select(
              'SELECT id, agent_change_id, created_at FROM note_revisions '
              'WHERE note_id = ? ORDER BY new_version DESC',
              [id],
            )
          : const <Map<String, Object?>>[];
      return FakeMemexCli.ok(
        '${jsonEncode({
          'vault_id': agentEditsVaultId,
          'revisions': [
            for (final r in rows) {'id': r['id'], 'agent_change_id': r['agent_change_id'], 'created_at': r['created_at']},
          ],
        })}\n',
      );
    });
    on('revisions restore', (call) {
      final id = call.flag('revision-id');
      final out = id == null ? null : vault._restoreRevision(id);
      if (out == null) {
        return FakeMemexCli.error('not_found', 'revision not found: $id');
      }
      return FakeMemexCli.ok('${jsonEncode(out)}\n');
    });
  }
}

/// A notes domain for agent-edit widget tests (D21: extends
/// [LocalNotesAccess]). Reads go to the real SQLite reads over [db]. The
/// agent-edit writes never need a CLI: each records its call, waits on its
/// hold (when set), throws its error (when set), and otherwise writes into
/// [db] (a [FakeVaultDb]) so the next note read sees the change.
class FakeAgentEditsNotesAccess extends LocalNotesAccess {
  FakeAgentEditsNotesAccess({
    super.vaultPath = agentEditsVaultPath,
    FakeVaultDb? db,
    super.cli,
  }) : fakeDb = db,
       super(db: db);

  /// The database the fake writes into (also [db]); null: nothing stored.
  final FakeVaultDb? fakeDb;

  /// Every `setAgentReadOnly` call, in order.
  final setAgentReadOnlyCalls = <({String noteId, bool on})>[];

  /// Every `noteRevisions` call (the note id), in order.
  final noteRevisionsCalls = <String>[];

  /// Every `restoreNoteRevision` call, in order.
  final restoreNoteRevisionCalls = <({String noteId, String revisionId})>[];

  /// When set, `setAgentReadOnly` throws it (after recording, nothing stored).
  Object? setAgentReadOnlyError;

  /// When set, `noteRevisions` throws it (after recording).
  Object? noteRevisionsError;

  /// When set, `restoreNoteRevision` throws it (after recording, nothing
  /// stored).
  Object? restoreNoteRevisionError;

  /// When set, `setAgentReadOnly` waits for it before storing or throwing.
  Completer<void>? holdSetAgentReadOnly;

  /// When set, `restoreNoteRevision` waits for it before storing or throwing.
  Completer<void>? holdRestoreNoteRevision;

  /// When set, `noteRevisions` answers it instead of reading [db].
  List<NoteRevision>? noteRevisionsResult;

  @override
  Future<List<NoteRevision>> noteRevisions(String noteId) async {
    noteRevisionsCalls.add(noteId);
    final e = noteRevisionsError;
    if (e != null) throw e;
    return noteRevisionsResult ?? await super.noteRevisions(noteId);
  }

  @override
  Future<AgentReadOnlyResult> setAgentReadOnly(String noteId, bool on) async {
    setAgentReadOnlyCalls.add((noteId: noteId, on: on));
    final hold = holdSetAgentReadOnly;
    if (hold != null) await hold.future;
    final e = setAgentReadOnlyError;
    if (e != null) throw e;
    final stored = fakeDb;
    if (stored != null && stored.agentReadOnlyForTest(noteId) != null) {
      stored.setAgentReadOnlyForTest(noteId, on);
    }
    return AgentReadOnlyResult(
      vaultId: agentEditsVaultId,
      noteId: noteId,
      agentReadOnly: on,
    );
  }

  @override
  Future<NoteRevisionRestoreResult> restoreNoteRevision({
    required String noteId,
    required String revisionId,
  }) async {
    restoreNoteRevisionCalls.add((noteId: noteId, revisionId: revisionId));
    final hold = holdRestoreNoteRevision;
    if (hold != null) await hold.future;
    final e = restoreNoteRevisionError;
    if (e != null) throw e;
    final out = fakeDb?._restoreRevision(revisionId);
    if (out == null || out['note_id'] != noteId) {
      throw MemexException(
        'revisions restore failed: revision not found: $revisionId',
        code: 'not_found',
      );
    }
    return NoteRevisionRestoreResult(
      vaultId: out['vault_id']! as String,
      noteId: noteId,
      version: out['version']! as int,
      contentMd: out['content_md']! as String,
    );
  }
}

/// Everything a test needs after [pumpAgentEdits].
class AgentEditsHarness {
  AgentEditsHarness({
    required this.container,
    required this.db,
    required this.cli,
    required this.notes,
    required this.clock,
  });

  final ProviderContainer container;

  /// `vaultDbProvider` and the notes domain's database.
  final FakeVaultDb db;

  /// `memexCliProvider` (null: no CLI configured).
  final FakeMemexCli? cli;

  /// The notes domain behind `vaultAccessProvider.notes`.
  final FakeAgentEditsNotesAccess notes;

  /// `clockProvider`.
  final FakeClock clock;

  /// How many times `vaultRevisionProvider` changed since the pump.
  int bumps = 0;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pumps [child] (inside `MaterialApp(theme: buildOmTheme(), home:
/// Scaffold(body: child))`) with the agent-edit seams; see the file comment.
/// Defaults: a fresh V8 [FakeVaultDb], a [FakeMemexCli] with no handlers
/// ([memexConfigured] false gives no CLI), a [FakeAgentEditsNotesAccess] over
/// that database, a [FakeClock] at 2026-10-03 09:00 local, text at
/// [textScale] 0.5 (the test font is far wider than the app's). When
/// [noteId] is given it becomes `selectedNoteIdProvider`. [overrides] are
/// appended; they must not repeat a provider the pump already overrides.
Future<AgentEditsHarness> pumpAgentEdits(
  WidgetTester tester,
  Widget child, {
  FakeVaultDb? db,
  FakeMemexCli? cli,
  bool memexConfigured = true,
  FakeAgentEditsNotesAccess? notes,
  FakeClock? clock,
  String? noteId,
  double textScale = 0.5,
  Size surfaceSize = const Size(800, 600),
  List<Override> overrides = const [],
}) async {
  final fakeDb = db ?? FakeVaultDb.v5();
  final fakeCli = memexConfigured ? (cli ?? FakeMemexCli()) : null;
  final fakeNotes =
      notes ?? FakeAgentEditsNotesAccess(db: fakeDb, cli: fakeCli);
  final fakeClock = clock ?? FakeClock();

  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;

  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => const LocalVaultRef(agentEditsVaultPath),
      ),
      vaultDbProvider.overrideWithValue(fakeDb),
      memexCliProvider.overrideWithValue(fakeCli),
      clockProvider.overrideWithValue(fakeClock),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: agentEditsVaultPath,
          db: fakeDb,
          cli: fakeCli,
          notes: fakeNotes,
        ),
      ),
      ...overrides,
    ],
  );
  if (noteId != null) {
    container.read(selectedNoteIdProvider.notifier).state = noteId;
  }
  final harness = AgentEditsHarness(
    container: container,
    db: fakeDb,
    cli: fakeCli,
    notes: fakeNotes,
    clock: fakeClock,
  );
  container.listen<int>(vaultRevisionProvider, (_, _) => harness.bumps++);

  addTearDown(fakeDb.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await pumpFrames(tester);
  return harness;
}
