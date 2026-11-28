// WI #29 (A11): the right panel's Activity tab becomes the per-note change
// log read from `agent_changes` (newest first, timestamp + day reviewed +
// bullets). Topic notes show their own entries; no entries shows the
// existing empty copy.
//
// WI #15 (Spec #7 A3, rulings D16 to D19): an agent edit's entry on a plain
// or topic note gets a Restore button (Key `note-restore-<agentChangeId>`)
// while its `note_revisions` row still exists and `agentEditsAvailableProvider`
// is true. Restore asks with the Vault Guide's text, then restores through
// `NoteEditsActions.restoreNoteRevision` (one call, one bump); the open editor
// rebases on the restored version. The guide's Restore keeps its own Keys.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/note_edits_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/activity_tab.dart';
import 'package:open_memex_app/src/widgets/agent_edits_keys.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/activity_seeds.dart';
import '../support/agent_edits_fakes.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/feedback_seeds.dart';
import '../support/font_fetch_hold.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

const _dailyId = 'daily-2026-09-05';

// The shared Eyebrow atom renders its text upper-cased.
const _eyebrow = 'AGENT ACTIVITY · THIS NOTE';
const _emptyCopy =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

int _ms(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

Finder _entry(String id) => find.byKey(Key('activity-entry-$id'));

Finder _in(Finder entry, String text) =>
    find.descendant(of: entry, matching: find.textContaining(text));

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

/// Seed a daily note with three entries inserted out of display order.
FakeVaultDb _dbWithThreeEntries() {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-09-05', id: _dailyId);
  // Insert order: middle, oldest, newest. Id order differs from both.
  db.seedAgentChange(
    'ac-3',
    _dailyId,
    day: '2026-09-05',
    createdAt: _ms(2026, 9, 5, 14, 32),
    bullets: ['Tidied the morning list', 'Linked Gardening', 'Flagged a typo'],
  );
  db.seedAgentChange(
    'ac-1',
    _dailyId,
    day: '2026-09-02',
    createdAt: _ms(2026, 9, 3, 8, 5),
    bullets: ['Read the Sep 2 entry'],
  );
  db.seedAgentChange(
    'ac-2',
    _dailyId,
    day: '2026-09-04',
    createdAt: _ms(2026, 9, 6, 7, 40),
    bullets: ['Added a Topics chip', 'Moved a stray line'],
  );
  return db;
}

Future<WorkspaceHarness> _openActivity(
  WidgetTester tester,
  FakeVaultDb db,
  String noteId,
) async {
  final h = await pumpWorkspace(tester, db: db);
  await openNoteTab(tester, h, noteId);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.activity;
  await pumpFrames(tester);
  return h;
}

void main() {
  holdFontFetches();

  group('Activity tab entries (AC7)', () {
    testWidgets(
      'the Activity tab lists a note with three agent_changes rows newest first',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(_entry('ac-1'), findsOneWidget);
        expect(_entry('ac-2'), findsOneWidget);
        expect(_entry('ac-3'), findsOneWidget);
        // Newest (6 Sep) above 5 Sep above 3 Sep.
        expect(
          _top(tester, _entry('ac-2')),
          lessThan(_top(tester, _entry('ac-3'))),
        );
        expect(
          _top(tester, _entry('ac-3')),
          lessThan(_top(tester, _entry('ac-1'))),
        );
        expect(find.byKey(const Key('activity-empty')), findsNothing);
      },
    );

    testWidgets(
      'each Activity entry shows its timestamp as 5 Sep 2026, 14:32 and its day reviewed as 2026-09-05',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(_in(_entry('ac-3'), '5 Sep 2026, 14:32'), findsOneWidget);
        expect(_in(_entry('ac-3'), '2026-09-05'), findsOneWidget);
        // The other entries carry their own timestamp and day, zero padded.
        expect(_in(_entry('ac-1'), '3 Sep 2026, 08:05'), findsOneWidget);
        expect(_in(_entry('ac-1'), '2026-09-02'), findsOneWidget);
        expect(_in(_entry('ac-2'), '6 Sep 2026, 07:40'), findsOneWidget);
        expect(_in(_entry('ac-2'), '2026-09-04'), findsOneWidget);
        // The time is local, not the day reviewed: no cross-contamination.
        expect(_in(_entry('ac-3'), '2026-09-04'), findsNothing);
        expect(_in(_entry('ac-1'), '5 Sep 2026'), findsNothing);
      },
    );

    testWidgets('each Activity entry shows every bullet in stored order', (
      tester,
    ) async {
      await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

      final b1 = _in(_entry('ac-3'), 'Tidied the morning list');
      final b2 = _in(_entry('ac-3'), 'Linked Gardening');
      final b3 = _in(_entry('ac-3'), 'Flagged a typo');
      expect(b1, findsOneWidget);
      expect(b2, findsOneWidget);
      expect(b3, findsOneWidget);
      expect(_top(tester, b1), lessThan(_top(tester, b2)));
      expect(_top(tester, b2), lessThan(_top(tester, b3)));

      expect(_in(_entry('ac-2'), 'Added a Topics chip'), findsOneWidget);
      expect(_in(_entry('ac-2'), 'Moved a stray line'), findsOneWidget);
      expect(_in(_entry('ac-1'), 'Read the Sep 2 entry'), findsOneWidget);
      // A bullet belongs to its own entry only.
      expect(_in(_entry('ac-1'), 'Linked Gardening'), findsNothing);
    });

    testWidgets(
      'the Activity tab keeps the agent activity eyebrow when it lists entries',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(find.text(_eyebrow), findsOneWidget);
      },
    );

    testWidgets(
      'a new agent_changes row appears in the open Activity tab after a vault revision bump',
      (tester) async {
        final db = _dbWithThreeEntries();
        final h = await _openActivity(tester, db, _dailyId);
        expect(_entry('ac-4'), findsNothing);

        db.seedAgentChange(
          'ac-4',
          _dailyId,
          day: '2026-09-06',
          createdAt: _ms(2026, 9, 7, 10, 0),
          bullets: ['Fresh entry'],
        );
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(_entry('ac-4'), findsOneWidget);
        expect(_in(_entry('ac-4'), 'Fresh entry'), findsOneWidget);
        // Newest first: the new entry sits above the previous newest.
        expect(
          _top(tester, _entry('ac-4')),
          lessThan(_top(tester, _entry('ac-2'))),
        );
      },
    );
  });

  group('Activity tab for topic notes (AC8)', () {
    testWidgets(
      'the Activity tab for a topic note lists that topic note entries and not the daily note ones',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        db.seedTopicNote('topic-1', 'Gardening');
        db.seedAgentChange(
          'ac-daily',
          _dailyId,
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 14, 32),
          bullets: ['Daily only bullet'],
        );
        db.seedAgentChange(
          'ac-topic',
          'topic-1',
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 15, 0),
          bullets: ['Topic only bullet'],
        );
        final h = await _openActivity(tester, db, 'topic-1');

        expect(_entry('ac-topic'), findsOneWidget);
        expect(_in(_entry('ac-topic'), 'Topic only bullet'), findsOneWidget);
        expect(_entry('ac-daily'), findsNothing);
        expect(find.text('Daily only bullet'), findsNothing);

        // Switching to the daily note swaps the log.
        await openNoteTab(tester, h, _dailyId);

        expect(_entry('ac-daily'), findsOneWidget);
        expect(_entry('ac-topic'), findsNothing);
        expect(find.text('Topic only bullet'), findsNothing);
      },
    );
  });

  group('Activity tab empty states (AC9, AC11)', () {
    testWidgets(
      'the Activity tab for a note with no entries shows the empty copy under Key activity-empty',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        await _openActivity(tester, db, _dailyId);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
        expect(find.text(_eyebrow), findsOneWidget);
      },
    );

    testWidgets(
      'the Activity tab shows the empty copy for a note whose only entries belong to another note',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        db.seedTopicNote('topic-1', 'Gardening');
        db.seedAgentChange(
          'ac-topic',
          'topic-1',
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 15, 0),
          bullets: ['Topic only bullet'],
        );
        await _openActivity(tester, db, _dailyId);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(_entry('ac-topic'), findsNothing);
      },
    );

    testWidgets(
      'the Activity tab on a V4 vault shows the empty copy and does not throw',
      (tester) async {
        final db = FakeVaultDb.v4();
        db.seedNote(id: _dailyId, title: '2026-09-05', role: 'daily');
        await _openActivity(tester, db, _dailyId);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
      },
    );

    testWidgets(
      'the Activity tab drops the empty copy once the note has an entry',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        final h = await _openActivity(tester, db, _dailyId);
        expect(find.byKey(const Key('activity-empty')), findsOneWidget);

        db.seedAgentChange(
          'ac-1',
          _dailyId,
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 14, 32),
          bullets: ['First entry'],
        );
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(find.byKey(const Key('activity-empty')), findsNothing);
        expect(_entry('ac-1'), findsOneWidget);
      },
    );
  });

  _wi15AgentEditRestoreTests();
}

// ------------------------------------------------------------ WI #15 (A3)

const _wi15Plain = '01JWI15PLAINNOTE0000000015';
const _wi15Topic = '01JWI15TOPICNOTE0000000015';
const _wi15Title = 'Pricing notes';
const _wi15Body = 'current pricing text';
const _wi15Version = 4;

/// What revision `rev-e1` (agent change `ac-e1`, the newest edit) holds.
const _wi15PreviousE1 = 'older pricing text';

/// What revision `rev-e0` (agent change `ac-e0`) holds.
const _wi15PreviousE0 = 'oldest pricing text';
const _wi15Typed = 'current pricing text and my unsaved words';
const _wi15ConfirmText =
    'Restore this version? The current text is kept as a version you can return to.';
const _wi15RestoreBullet = 'Restored an earlier version';
const _wi15RestoreFailed =
    'revisions restore failed: revision not found: rev-e1';

int _wi15Ms(int day, int hour) =>
    DateTime(2026, 10, day, hour).millisecondsSinceEpoch;

/// Seeds [noteId]'s agent edits: `ac-e1` (newest, revision `rev-e1`), `ac-e0`
/// (revision `rev-e0`), `ac-pruned` (its revision was pruned) and a revision
/// `rev-orphan` that names no agent change. Revision ids are per note
/// ([noteId] suffix) except on the plain note.
void _wi15SeedAgentEdits(FakeVaultDb db, String noteId) {
  final s = noteId == _wi15Plain ? '' : '-$noteId';
  db.seedAgentChange(
    'ac-pruned$s',
    noteId,
    day: '2026-09-30',
    createdAt: _wi15Ms(1, 8),
    bullets: ['Tidied the pricing table'],
  );
  db.seedAgentChange(
    'ac-e0$s',
    noteId,
    day: '2026-10-01',
    createdAt: _wi15Ms(1, 10),
    bullets: ['Fixed a typo in pricing'],
  );
  db.seedAgentChange(
    'ac-e1$s',
    noteId,
    day: '2026-10-02',
    createdAt: _wi15Ms(2, 10),
    bullets: ['Rewrote the pricing intro', 'Linked Gardening'],
  );
  db.seedNoteRevision(
    id: 'rev-orphan$s',
    noteId: noteId,
    previousMd: 'orphan text',
    previousVersion: 1,
    newVersion: 2,
    createdAt: _wi15Ms(1, 7),
  );
  db.seedNoteRevision(
    id: 'rev-e0$s',
    noteId: noteId,
    agentChangeId: 'ac-e0$s',
    previousMd: _wi15PreviousE0,
    previousVersion: 2,
    newVersion: 3,
    createdAt: _wi15Ms(1, 10),
  );
  db.seedNoteRevision(
    id: 'rev-e1$s',
    noteId: noteId,
    agentChangeId: 'ac-e1$s',
    previousMd: _wi15PreviousE1,
    previousVersion: 3,
    newVersion: _wi15Version,
    createdAt: _wi15Ms(2, 10),
  );
}

/// A V8 vault with a plain note (no role) and a topic note, each with the
/// agent edits of [_wi15SeedAgentEdits]. [v7] gives a vault exactly at V7
/// (no `note_revisions`): the plain note's `ac-e1` change and no revisions.
FakeVaultDb _wi15Db({bool v7 = false}) {
  final db = v7 ? agentEditsV7Vault() : FakeVaultDb.v5();
  db.seedNote(
    id: _wi15Plain,
    title: _wi15Title,
    content: _wi15Body,
    version: _wi15Version,
  );
  db.seedNote(
    id: _wi15Topic,
    title: 'Gardening',
    content: _wi15Body,
    role: 'topic',
    version: _wi15Version,
  );
  if (v7) {
    db.seedAgentChange(
      'ac-e1',
      _wi15Plain,
      day: '2026-10-02',
      createdAt: _wi15Ms(2, 10),
      bullets: ['Rewrote the pricing intro', 'Linked Gardening'],
    );
  } else {
    _wi15SeedAgentEdits(db, _wi15Plain);
    _wi15SeedAgentEdits(db, _wi15Topic);
  }
  return db;
}

/// The agent-edit notes fake, plus what R2's restore also stores: the
/// replaced text is kept as a new revision linked to one new agent change
/// whose bullet is `Restored an earlier version`. It also records how many
/// `memex update` calls (the editor's saves) ran before each restore call.
class _Wi15NotesAccess extends FakeAgentEditsNotesAccess {
  _Wi15NotesAccess({required FakeVaultDb db, required FakeMemexCli cli})
    : _wi15Cli = cli,
      super(db: db, cli: cli);

  final FakeMemexCli _wi15Cli;

  /// For each restore call, the `update` calls already made when it started.
  final updatesBeforeRestore = <int>[];

  @override
  Future<NoteRevisionRestoreResult> restoreNoteRevision({
    required String noteId,
    required String revisionId,
  }) async {
    updatesBeforeRestore.add(_wi15Cli.callsFor('update').length);
    final db = fakeDb!;
    final kept = db.db.select(
      'SELECT content_md, version FROM notes WHERE id = ?',
      [noteId],
    ).first;
    final out = await super.restoreNoteRevision(
      noteId: noteId,
      revisionId: revisionId,
    );
    final changeId = 'ac-restored-${out.version}';
    db.seedAgentChange(
      changeId,
      noteId,
      day: '2026-10-03',
      createdAt: _wi15Ms(3, 9),
      bullets: const [_wi15RestoreBullet],
    );
    db.seedNoteRevision(
      id: 'rev-kept-${out.version}',
      noteId: noteId,
      agentChangeId: changeId,
      previousMd: kept['content_md'] as String,
      previousVersion: (kept['version'] as num).toInt(),
      newVersion: out.version,
      createdAt: _wi15Ms(3, 9),
    );
    return out;
  }
}

class _Wi15Env {
  _Wi15Env(this.h, this.notes, this.cli);
  final AgentEditsHarness h;
  final _Wi15NotesAccess notes;
  final FakeMemexCli cli;
  FakeVaultDb get db => h.db;
}

/// The gate the tests flip (true unless set).
final _wi15Gate = StateProvider<bool>((_) => true);

/// Pumps the note editor beside the Activity tab on [noteId], through the
/// frozen A1 seam (`pumpAgentEdits`), with `memex update` writing to the
/// database. [gated] puts `agentEditsAvailableProvider` behind [_wi15Gate].
Future<_Wi15Env> _wi15Open(
  WidgetTester tester, {
  FakeVaultDb? db,
  String noteId = _wi15Plain,
  bool gated = false,
}) async {
  final database = db ?? _wi15Db();
  final cli = FakeMemexCli()..onUpdateWrites(database);
  final notes = _Wi15NotesAccess(db: database, cli: cli);
  final h = await pumpAgentEdits(
    tester,
    Row(
      children: [
        Expanded(
          child: NoteEditor(rightPanelOpen: true, onToggleRightPanel: () {}),
        ),
        const SizedBox(width: 480, child: ActivityTab()),
      ],
    ),
    db: database,
    cli: cli,
    notes: notes,
    noteId: noteId,
    surfaceSize: const Size(1600, 1200),
    overrides: [
      if (gated)
        agentEditsAvailableProvider.overrideWith((ref) => ref.watch(_wi15Gate)),
    ],
  );
  await pumpFrames(tester);
  return _Wi15Env(h, notes, cli);
}

Finder _wi15Entry(String id) => find.byKey(Key('activity-entry-$id'));

Finder _wi15Restore(String agentChangeId) =>
    find.byKey(noteRestoreKey(agentChangeId));

/// Every agent-edit Restore button (not the dialog buttons).
Finder get _wi15AnyNoteRestore => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('note-restore-') &&
      w.key != noteRestoreConfirmKey &&
      w.key != noteRestoreCancelKey,
);

/// Every guide Restore button (not the dialog buttons).
Finder get _wi15AnyGuideRestore => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('guide-restore-') &&
      !const {
        'guide-restore-confirm',
        'guide-restore-cancel',
      }.contains((w.key! as ValueKey<String>).value),
);

Finder _wi15InEntry(String id, String text) =>
    find.descendant(of: _wi15Entry(id), matching: find.text(text));

Future<void> _wi15Tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: '$f');
  await tester.tap(f);
  await pumpFrames(tester);
}

/// Restore on entry [agentChangeId], then Restore in the dialog.
Future<void> _wi15RestoreAndConfirm(
  WidgetTester tester, [
  String agentChangeId = 'ac-e1',
]) async {
  await _wi15Tap(tester, _wi15Restore(agentChangeId));
  await _wi15Tap(tester, find.byKey(noteRestoreConfirmKey));
}

/// Types [text] into the body and leaves the save debounce pending.
Future<void> _wi15TypePending(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(editorBodyKey), text);
  await tester.pump();
}

String _wi15Stored(FakeVaultDb db, String noteId) =>
    db.db.select('SELECT content_md FROM notes WHERE id = ?', [
          noteId,
        ]).first['content_md']
        as String;

Finder _wi15SnackText(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

void _wi15AgentEditRestoreTests() {
  group('WI 15 agent-edit Restore shows for entries with a revision', () {
    testWidgets(
      'a plain note agent-edit entry with a stored revision shows a Restore button keyed note-restore and its agent change id',
      (tester) async {
        await _wi15Open(tester);

        expect(_wi15Entry('ac-e1'), findsOneWidget);
        expect(_wi15Restore('ac-e1'), findsOneWidget);
        expect(
          find.descendant(
            of: _wi15Entry('ac-e1'),
            matching: _wi15Restore('ac-e1'),
          ),
          findsOneWidget,
          reason: 'the button sits inside its own entry',
        );
        expect(
          find.descendant(
            of: _wi15Restore('ac-e1'),
            matching: find.text('Restore'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _wi15Entry('ac-e0'),
            matching: _wi15Restore('ac-e0'),
          ),
          findsOneWidget,
          reason: 'every entry with a revision gets its own button',
        );
        expect(_wi15AnyGuideRestore, findsNothing);
      },
    );

    testWidgets(
      'a topic note agent-edit entry with a stored revision shows a Restore button keyed note-restore and its agent change id',
      (tester) async {
        const e1 = 'ac-e1-$_wi15Topic';
        final env = await _wi15Open(tester, noteId: _wi15Topic);

        expect(
          find.descendant(of: _wi15Entry(e1), matching: _wi15Restore(e1)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _wi15Restore(e1), matching: find.text('Restore')),
          findsOneWidget,
        );
        expect(_wi15Restore('ac-e0-$_wi15Topic'), findsOneWidget);
        expect(_wi15Restore('ac-e1'), findsNothing, reason: 'plain note only');
        expect(_wi15AnyGuideRestore, findsNothing);

        await _wi15RestoreAndConfirm(tester, e1);
        expect(env.notes.restoreNoteRevisionCalls, [
          (noteId: _wi15Topic, revisionId: 'rev-e1-$_wi15Topic'),
        ]);
      },
    );

    testWidgets(
      'a note revision with no agent change adds no Restore button to any agent-edit entry',
      (tester) async {
        await _wi15Open(tester);

        expect(
          _wi15AnyNoteRestore,
          findsNWidgets(2),
          reason: 'only ac-e1 and ac-e0 have a revision',
        );
      },
    );
  });

  group('WI 15 agent-edit Restore hides for pruned revisions', () {
    testWidgets(
      'an agent-edit entry whose revision was pruned shows its bullets and no Restore button',
      (tester) async {
        await _wi15Open(tester);

        expect(_wi15Entry('ac-pruned'), findsOneWidget);
        expect(
          _wi15InEntry('ac-pruned', '· Tidied the pricing table'),
          findsOneWidget,
        );
        expect(_wi15Restore('ac-pruned'), findsNothing);
        expect(
          _wi15Restore('ac-e1'),
          findsOneWidget,
          reason: 'an entry whose revision exists keeps its button',
        );
      },
    );

    testWidgets(
      'an agent-edit entry loses its Restore button once its revision is pruned and keeps its bullets',
      (tester) async {
        final env = await _wi15Open(tester);
        expect(_wi15Restore('ac-e0'), findsOneWidget);

        env.db.db.execute("DELETE FROM note_revisions WHERE id = 'rev-e0'");
        env.h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(_wi15Restore('ac-e0'), findsNothing);
        expect(
          _wi15InEntry('ac-e0', '· Fixed a typo in pricing'),
          findsOneWidget,
        );
        expect(_wi15Restore('ac-e1'), findsOneWidget);
      },
    );
  });

  group('WI 15 agent-edit Restore follows the agent edits gate', () {
    testWidgets(
      'the agent-edit Restore button hides while agentEditsAvailableProvider is false and the bullets still show',
      (tester) async {
        final env = await _wi15Open(tester, gated: true);
        expect(_wi15Restore('ac-e1'), findsOneWidget, reason: 'gate open');

        env.h.container.read(_wi15Gate.notifier).state = false;
        // The first frame after the flip, before the revisions re-read ends:
        // the previous list must not keep its buttons on screen.
        await tester.pump();
        expect(
          _wi15AnyNoteRestore,
          findsNothing,
          reason: 'no stale buttons while the revisions re-read',
        );
        await pumpFrames(tester);

        expect(_wi15AnyNoteRestore, findsNothing);
        expect(
          _wi15InEntry('ac-e1', '· Rewrote the pricing intro'),
          findsOneWidget,
        );
        expect(_wi15InEntry('ac-e1', '· Linked Gardening'), findsOneWidget);
        expect(
          _wi15InEntry('ac-e0', '· Fixed a typo in pricing'),
          findsOneWidget,
        );

        env.h.container.read(_wi15Gate.notifier).state = true;
        await pumpFrames(tester);

        expect(_wi15Restore('ac-e1'), findsOneWidget, reason: 'open again');
      },
    );

    testWidgets(
      'on a V7 vault an agent-edit entry shows its bullets and no Restore until the vault reaches V8',
      (tester) async {
        final db = _wi15Db(v7: true);
        final env = await _wi15Open(tester, db: db);

        expect(env.h.read(agentEditsAvailableProvider), isFalse);
        expect(
          _wi15InEntry('ac-e1', '· Rewrote the pricing intro'),
          findsOneWidget,
        );
        expect(_wi15AnyNoteRestore, findsNothing);
        expect(
          env.notes.noteRevisionsCalls,
          isEmpty,
          reason: 'an older vault never sees the revisions read',
        );

        db.migrateAgentEditsToV8();
        db.seedNoteRevision(
          id: 'rev-e1',
          noteId: _wi15Plain,
          agentChangeId: 'ac-e1',
          previousMd: _wi15PreviousE1,
          previousVersion: 3,
          newVersion: _wi15Version,
        );
        env.h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(env.h.read(agentEditsAvailableProvider), isTrue);
        expect(_wi15Restore('ac-e1'), findsOneWidget);
      },
    );
  });

  group('WI 15 agent-edit Restore confirm dialog', () {
    testWidgets(
      'pressing an agent-edit Restore opens the confirm dialog with the guide text and its note-restore buttons',
      (tester) async {
        final env = await _wi15Open(tester);

        await _wi15Tap(tester, _wi15Restore('ac-e1'));

        expect(find.text(_wi15ConfirmText), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(noteRestoreCancelKey),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(noteRestoreConfirmKey),
            matching: find.text('Restore'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('guide-restore-confirm')), findsNothing);
        expect(find.byKey(const Key('guide-restore-cancel')), findsNothing);
        expect(
          env.notes.restoreNoteRevisionCalls,
          isEmpty,
          reason: 'nothing is restored before the person confirms',
        );
      },
    );

    testWidgets(
      'Cancel on the agent-edit Restore dialog closes it with zero restore calls and no bump',
      (tester) async {
        final env = await _wi15Open(tester);

        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        await _wi15Tap(tester, find.byKey(noteRestoreCancelKey));

        expect(find.text(_wi15ConfirmText), findsNothing);
        expect(env.notes.restoreNoteRevisionCalls, isEmpty);
        expect(env.h.bumps, 0);
        expect(env.h.read(editorControllerProvider).contentMd, _wi15Body);
        expect(_wi15Stored(env.db, _wi15Plain), _wi15Body);

        // The button works again after a Cancel.
        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        expect(find.text(_wi15ConfirmText), findsOneWidget);
        await _wi15Tap(tester, find.byKey(noteRestoreCancelKey));
        expect(env.notes.restoreNoteRevisionCalls, isEmpty);
      },
    );

    testWidgets(
      'dismissing the agent-edit Restore dialog outside it makes zero restore calls',
      (tester) async {
        final env = await _wi15Open(tester);

        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        await tester.tapAt(const Offset(2, 2));
        await pumpFrames(tester);

        expect(find.text(_wi15ConfirmText), findsNothing);
        expect(env.notes.restoreNoteRevisionCalls, isEmpty);
        expect(env.h.bumps, 0);
        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        expect(
          find.text(_wi15ConfirmText),
          findsOneWidget,
          reason: 'the button works again after a dismiss',
        );
      },
    );
  });

  group('WI 15 confirming an agent-edit Restore', () {
    testWidgets(
      'confirming an agent-edit Restore calls restoreNoteRevision once with its revision id and bumps the vault revision once',
      (tester) async {
        final env = await _wi15Open(tester);

        await _wi15RestoreAndConfirm(tester);

        expect(env.notes.restoreNoteRevisionCalls, [
          (noteId: _wi15Plain, revisionId: 'rev-e1'),
        ]);
        expect(env.h.bumps, 1, reason: 'NoteEditsActions bumps; nobody else');
        expect(find.text(_wi15ConfirmText), findsNothing);
        expect(
          env.cli.callsFor('update'),
          isEmpty,
          reason: 'nothing was pending, so nothing is saved first',
        );
      },
    );

    testWidgets(
      'confirming the agent-edit Restore of an older entry restores that entry revision',
      (tester) async {
        final env = await _wi15Open(tester);

        await _wi15RestoreAndConfirm(tester, 'ac-e0');

        expect(env.notes.restoreNoteRevisionCalls, [
          (noteId: _wi15Plain, revisionId: 'rev-e0'),
        ]);
        expect(env.h.read(editorControllerProvider).contentMd, _wi15PreviousE0);
      },
    );

    testWidgets(
      'confirming an agent-edit Restore stores the pending edit before the restore call',
      (tester) async {
        final env = await _wi15Open(tester);
        await _wi15TypePending(tester, _wi15Typed);
        expect(env.cli.callsFor('update'), isEmpty, reason: 'still pending');

        await _wi15RestoreAndConfirm(tester);

        final updates = env.cli.callsFor('update');
        expect(updates, hasLength(1));
        expect(updates.single.stdinBody, _wi15Typed);
        expect(updates.single.flag('expected-version'), '$_wi15Version');
        expect(env.notes.updatesBeforeRestore, [
          1,
        ], reason: 'the pending edit is stored before the one restore call');
        expect(env.notes.restoreNoteRevisionCalls, hasLength(1));
      },
    );

    testWidgets(
      'an agent-edit Restore whose flush fails makes no restore call and shows the save error in a SnackBar',
      (tester) async {
        final env = await _wi15Open(tester);
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        await _wi15TypePending(tester, _wi15Typed);

        await _wi15RestoreAndConfirm(tester);

        expect(tester.takeException(), isNull);
        expect(env.notes.restoreNoteRevisionCalls, isEmpty);
        expect(_wi15Stored(env.db, _wi15Plain), _wi15Body);
        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, _wi15Typed, reason: 'the typed text stays');
        expect(editorBodyText(tester), _wi15Typed);
        expect(_wi15SnackText('update failed: disk is full'), findsOneWidget);
      },
    );
  });

  group('WI 15 the open editor after an agent-edit Restore', () {
    testWidgets(
      'after an agent-edit Restore the open editor shows the restored text on the new version with no conflict',
      (tester) async {
        final env = await _wi15Open(tester);
        expect(editorBodyText(tester), _wi15Body);

        await _wi15RestoreAndConfirm(tester);

        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, _wi15PreviousE1);
        expect(editorBodyText(tester), _wi15PreviousE1);
        expect(editor.lastSavedVersion, _wi15Version + 1);
        expect(editor.status, isNot(SaveStatus.conflict));
        expect(editor.status, isNot(SaveStatus.error));
        expect(find.textContaining('conflict'), findsNothing);
        expect(_wi15Stored(env.db, _wi15Plain), _wi15PreviousE1);
      },
    );

    testWidgets(
      'a pending edit is replaced by the restored text after an agent-edit Restore',
      (tester) async {
        final env = await _wi15Open(tester);
        await _wi15TypePending(tester, _wi15Typed);

        await _wi15RestoreAndConfirm(tester);

        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, _wi15PreviousE1);
        expect(editorBodyText(tester), _wi15PreviousE1);
        expect(editor.lastSavedVersion, _wi15Version + 2);
        expect(find.textContaining('unsaved words'), findsNothing);
      },
    );

    testWidgets(
      'the next edit after an agent-edit Restore saves against the restored version without a conflict',
      (tester) async {
        final env = await _wi15Open(tester);
        await _wi15RestoreAndConfirm(tester);

        await tester.enterText(
          find.byKey(editorBodyKey),
          '$_wi15PreviousE1 plus more',
        );
        await tester.pump();
        env.h.clock.advance(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await pumpFrames(tester);

        final update = env.cli.callsFor('update').single;
        expect(update.flag('note-id'), _wi15Plain);
        expect(update.flag('expected-version'), '${_wi15Version + 1}');
        expect(update.stdinBody, '$_wi15PreviousE1 plus more');
        final editor = env.h.read(editorControllerProvider);
        expect(editor.status, SaveStatus.clean);
        expect(editor.lastSavedVersion, _wi15Version + 2);
        expect(_wi15Stored(env.db, _wi15Plain), '$_wi15PreviousE1 plus more');
      },
    );
  });

  group('WI 15 the Activity list after an agent-edit Restore', () {
    testWidgets(
      'after an agent-edit Restore the Activity list shows the Restored an earlier version entry with its own Restore button',
      (tester) async {
        await _wi15Open(tester);
        expect(_wi15Entry('ac-restored-5'), findsNothing);

        await _wi15RestoreAndConfirm(tester);

        expect(_wi15Entry('ac-restored-5'), findsOneWidget);
        expect(
          _wi15InEntry('ac-restored-5', '· $_wi15RestoreBullet'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _wi15Entry('ac-restored-5'),
            matching: _wi15Restore('ac-restored-5'),
          ),
          findsOneWidget,
        );
        expect(
          _wi15Restore('ac-e1'),
          findsOneWidget,
          reason: 'the restored entry keeps its own button',
        );
      },
    );
  });

  group('WI 15 a failed agent-edit Restore', () {
    testWidgets(
      'a failed agent-edit Restore shows the CLI message in a SnackBar leaves the text unchanged and bumps nothing',
      (tester) async {
        final env = await _wi15Open(tester);
        env.notes.restoreNoteRevisionError = MemexException(
          _wi15RestoreFailed,
          code: 'not_found',
        );

        await _wi15RestoreAndConfirm(tester);

        expect(tester.takeException(), isNull);
        expect(env.notes.restoreNoteRevisionCalls, hasLength(1));
        expect(_wi15SnackText(_wi15RestoreFailed), findsOneWidget);
        expect(env.h.bumps, 0);
        expect(env.h.read(editorControllerProvider).contentMd, _wi15Body);
        expect(editorBodyText(tester), _wi15Body);
        expect(
          env.h.read(editorControllerProvider).lastSavedVersion,
          _wi15Version,
        );
        expect(_wi15Stored(env.db, _wi15Plain), _wi15Body);
        expect(find.text(_wi15ConfirmText), findsNothing);
        expect(_wi15Entry('ac-restored-5'), findsNothing);

        // The button is offered again after a failure.
        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        expect(find.text(_wi15ConfirmText), findsOneWidget);
      },
    );

    testWidgets(
      'a failed agent-edit Restore with a server message shows that message in a SnackBar',
      (tester) async {
        const serverMessage = 'This note is busy on the server. Try again.';
        final env = await _wi15Open(tester);
        env.notes.restoreNoteRevisionError = MemexException(
          serverMessage,
          code: 'internal',
        );

        await _wi15RestoreAndConfirm(tester);

        expect(_wi15SnackText(serverMessage), findsOneWidget);
        expect(env.h.bumps, 0);
        expect(env.h.read(editorControllerProvider).contentMd, _wi15Body);
      },
    );
  });

  group('WI 15 agent-edit Restore busy guard', () {
    testWidgets(
      'two presses on an agent-edit Restore in the same frame open one dialog and start one restore',
      (tester) async {
        final env = await _wi15Open(tester);
        final button = _wi15Restore('ac-e1');
        expect(button, findsOneWidget);

        // Both presses reach the handler before any frame: a tap would be
        // absorbed by the dialog's route, so call the button's handler twice.
        final press = tester.widget<OmButton>(button).onPressed!;
        press();
        press();
        await tester.pump();
        await pumpFrames(tester);

        expect(find.text(_wi15ConfirmText), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);

        await _wi15Tap(tester, find.byKey(noteRestoreConfirmKey));

        expect(find.byType(AlertDialog), findsNothing, reason: 'no second');
        expect(env.notes.restoreNoteRevisionCalls, hasLength(1));
        expect(env.h.bumps, 1);
      },
    );

    testWidgets(
      'a press on an agent-edit Restore while its restore is still running starts no second restore',
      (tester) async {
        final env = await _wi15Open(tester);
        final hold = Completer<void>();
        env.notes.holdRestoreNoteRevision = hold;

        await _wi15RestoreAndConfirm(tester);
        expect(env.notes.restoreNoteRevisionCalls, hasLength(1));

        await tester.tap(_wi15Restore('ac-e1'));
        await pumpFrames(tester);
        expect(
          find.byType(AlertDialog),
          findsNothing,
          reason: 'busy: no second dialog while the restore runs',
        );

        env.notes.holdRestoreNoteRevision = null;
        hold.complete();
        await pumpFrames(tester);

        expect(env.notes.restoreNoteRevisionCalls, hasLength(1));
        expect(env.h.bumps, 1);
        await _wi15Tap(tester, _wi15Restore('ac-e1'));
        expect(
          find.text(_wi15ConfirmText),
          findsOneWidget,
          reason: 'the button works again once the restore finished',
        );
      },
    );
  });

  group('WI 15 agent-edit Restore of an entry with two revisions', () {
    testWidgets(
      'an agent-edit entry whose change produced two revisions restores the newest one',
      (tester) async {
        final db = _wi15Db()
          ..seedNoteRevision(
            id: 'rev-e1-later',
            noteId: _wi15Plain,
            agentChangeId: 'ac-e1',
            previousMd: 'later previous text',
            previousVersion: 4,
            newVersion: 5,
            createdAt: _wi15Ms(2, 11),
          );
        final env = await _wi15Open(tester, db: db);

        expect(_wi15Restore('ac-e1'), findsOneWidget, reason: 'one per entry');
        await _wi15RestoreAndConfirm(tester);

        expect(env.notes.restoreNoteRevisionCalls, [
          (noteId: _wi15Plain, revisionId: 'rev-e1-later'),
        ]);
      },
    );
  });

  group('WI 15 Vault Guide Restore stays as it is', () {
    testWidgets(
      'a plain note entry named by both a guide revision and a note revision shows only its note-restore button',
      (tester) async {
        final db = _wi15Db()
          ..seedGuideRevision(
            'rev-guide-stray',
            noteId: _wi15Plain,
            agentChangeId: 'ac-e1',
            createdAt: _wi15Ms(2, 11),
          );
        final env = await _wi15Open(tester, db: db);

        expect(_wi15Restore('ac-e1'), findsOneWidget);
        expect(_wi15AnyGuideRestore, findsNothing);

        await _wi15RestoreAndConfirm(tester);
        expect(env.notes.restoreNoteRevisionCalls, [
          (noteId: _wi15Plain, revisionId: 'rev-e1'),
        ]);
      },
    );
  });
}
