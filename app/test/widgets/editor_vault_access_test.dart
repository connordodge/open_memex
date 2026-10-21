// WI #78 (W2) widget journeys over the whole workspace: the editor and its
// widgets read through `VaultAccess` (D13), keep their previous values during
// a same-vault reload (D14a), never show another vault's rows after a vault
// switch (AC5), render excerpts through the daily domain (AC11), and label a
// clean save "saved" (AC7, Req 56).
//
// The harness's own `vaultDbProvider` database is empty (or belongs to the
// other vault), and the rows live in the doubles' databases, so a widget that
// still read SQLite directly shows nothing or the wrong vault.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _alphaId = '01J9ALPHA000000000000000078';
const _betaTopicId = '01J9BETA0000000000000000078';
const _sharedDayId = '01J9SHAREDDAY00000000000078';
const _today = '2026-10-03';

Finder _inEditor(Finder f) =>
    find.descendant(of: find.byType(NoteEditor), matching: f);

Finder get _bodyField => find.descendant(
  of: find.byKey(const Key('editor-body')),
  matching: find.byType(EditableText),
);

Future<void> _openNote(
  WidgetTester tester,
  WorkspaceHarness h,
  String id,
) async {
  h.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
  await pumpFrames(tester);
}

Future<void> _toggleSource(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editor-source-toggle')));
  await pumpFrames(tester);
}

void _bump(WorkspaceHarness h) =>
    h.read(vaultRevisionProvider.notifier).state++;

/// A V5 vault with the plain note "Alpha" (`alpha body`, version 3) and the
/// topic note "Beta Topic".
FakeVaultDb _notesVault() {
  final db = FakeVaultDb.v5()
    ..seedNote(id: _alphaId, title: 'Alpha', content: 'alpha body', version: 3)
    ..seedTopicNote(_betaTopicId, 'Beta Topic');
  addTearDown(db.close);
  return db;
}

FakeMemexCli _cli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db);

/// A vault whose today note [_sharedDayId] holds [person] (a person block and
/// an agent block [agentLine]), a footer chip to [topic] and, when [reviewed]
/// is set, a review row; plus a 2026-10-02 daily note when [withYesterday].
FakeVaultDb _dayVault({
  required String person,
  required String agentLine,
  required String topicId,
  required String topic,
  bool review = true,
  bool withYesterday = false,
}) {
  final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _sharedDayId);
  if (withYesterday) db.seedDailyNote('2026-10-02', id: '$topicId-yday');
  db.seedTopicNote(topicId, topic);
  final body = assembleDailyBody('$person\n$agentLine\n', [topic]);
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    body,
    _sharedDayId,
  ]);
  db.seedBlock(_sharedDayId, '$topicId-p', ord: 0, text: person);
  db.seedBlock(
    _sharedDayId,
    '$topicId-a',
    ord: 1,
    text: agentLine,
    source: 'agent',
    startByte: person.length + 1,
  );
  db.seedFooterChip(_sharedDayId, topicId, origin: 'person');
  if (review) db.seedDayReview(_sharedDayId, contentVersion: 1);
  return db;
}

void main() {
  group('save indicator (AC7, Req 56)', () {
    testWidgets('a successful save shows saved in the save indicator', (
      tester,
    ) async {
      final db = _notesVault();
      final cli = _cli(db);
      final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli);
      final h = await pumpWorkspace(
        tester,
        db: FakeVaultDb.v5(),
        cli: cli,
        overrides: [editorSingleVaultOverride(doubles)],
      );
      h.read(vaultAccessProvider);
      await _openNote(tester, h, _alphaId);
      await _toggleSource(tester);
      final before = h.read(vaultRevisionProvider);

      await tester.enterText(_bodyField, 'alpha body and more');
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('save-indicator')),
          matching: find.text('unsaved'),
        ),
        findsOneWidget,
      );
      h.clock.advance(const Duration(milliseconds: 600));
      await pumpFrames(tester);

      expect(doubles.notes.writes, ['updateNote:$_alphaId@3']);
      expect(h.read(editorControllerProvider).status, SaveStatus.clean);
      expect(
        find.descendant(
          of: find.byKey(const Key('save-indicator')),
          matching: find.text('saved'),
        ),
        findsOneWidget,
      );
      expect(find.text('synced'), findsNothing);
      expect(h.read(vaultRevisionProvider), before + 1);
    });
  });

  group('same-vault reload (AC4)', () {
    testWidgets(
      'on a revision bump the editor keeps the open note until the new read completes',
      (tester) async {
        final db = _notesVault();
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db);
        final h = await pumpWorkspace(
          tester,
          db: FakeVaultDb.v5(),
          overrides: [editorSingleVaultOverride(doubles)],
        );
        h.read(vaultAccessProvider);
        await _openNote(tester, h, _alphaId);
        expect(_inEditor(find.textContaining('alpha body')), findsWidgets);

        db.db.execute(
          'UPDATE notes SET content_md = ?, version = 4 '
          'WHERE id = ?',
          ['alpha body edited elsewhere', _alphaId],
        );
        doubles.hold();
        _bump(h);
        await pumpFrames(tester);

        expect(doubles.notes.gate.waiting, greaterThan(0));
        expect(_inEditor(find.textContaining('alpha body')), findsWidgets);
        expect(_inEditor(find.byKey(const Key('editor-title'))), findsWidgets);

        doubles.release();
        await pumpFrames(tester);
        expect(_inEditor(find.textContaining('alpha body')), findsWidgets);
      },
    );

    testWidgets(
      'on a revision bump the wikilink autocomplete keeps the previous titles until the new read completes',
      (tester) async {
        final db = _notesVault();
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db);
        final h = await pumpWorkspace(
          tester,
          db: FakeVaultDb.v5(),
          overrides: [editorSingleVaultOverride(doubles)],
        );
        h.read(vaultAccessProvider);
        await _openNote(tester, h, _alphaId);
        await _toggleSource(tester);
        // First load of the titles.
        await tester.enterText(_bodyField, 'alpha body [[Be');
        await pumpFrames(tester);
        await tester.enterText(_bodyField, 'alpha body [[Bet');
        await pumpFrames(tester);
        expect(
          find.byKey(const Key('wikilink-popover-item-Beta Topic')),
          findsOneWidget,
        );
        await tester.enterText(_bodyField, 'alpha body ');
        await pumpFrames(tester);

        doubles.hold();
        _bump(h);
        await pumpFrames(tester);
        await tester.enterText(_bodyField, 'alpha body [[Beta');
        await pumpFrames(tester);

        expect(doubles.notes.gate.waiting, greaterThan(0));
        expect(
          find.byKey(const Key('wikilink-popover-item-Beta Topic')),
          findsOneWidget,
        );
        doubles.release();
        await pumpFrames(tester);
        h.clock.advance(const Duration(milliseconds: 600));
        await pumpFrames(tester);
      },
    );
  });

  group('excerpt cards through the daily domain (AC11)', () {
    testWidgets(
      'excerpt cards render the daily domain text and open that day note from the caption',
      (tester) async {
        final vault = seedSegmentedVault();
        // The daily domain's own vault: 2026-09-05 has another id and text.
        final dailyDb = FakeVaultDb.v5()
          ..seedDailyNote('2026-09-05', id: 'daily-b-0905');
        dailyDb.seedBlock(
          'daily-b-0905',
          'b7k2m9',
          ord: 0,
          text: 'Served by the daily domain.',
        );
        dailyDb.seedBlock(
          'daily-b-0905',
          'c3d4e5',
          ord: 1,
          text: '- and a second block',
        );
        addTearDown(dailyDb.close);
        final doubles = EditorVaultDoubles(
          notesDb: vault.db,
          dailyDb: dailyDb,
          cli: vault.cli,
        );
        final h = await pumpWorkspace(
          tester,
          db: vault.db,
          cli: vault.cli,
          overrides: [editorSingleVaultOverride(doubles)],
        );
        h.read(vaultAccessProvider);
        final r = SegmentedEditorRobot(tester, h);
        await r.open(fixtureTopicId);

        expect(
          r.textIn(
            r.card(1),
            'Served by the daily domain.\n- and a second block',
          ),
          findsWidgets,
        );
        expect(r.textIn(r.card(1), 'Fixed the jump arc.'), findsNothing);
        expect(
          doubles.daily.reads,
          containsAll([
            'dailyNoteForDate:2026-09-05',
            'blocksForNote:daily-b-0905',
          ]),
        );

        await tester.tap(r.cardCaption(1));
        await pumpFrames(tester);

        expect(h.read(tabsProvider).activeTab, const NoteTab('daily-b-0905'));
      },
    );

    testWidgets(
      'an excerpt card whose blocks the daily domain lacks renders the removed stub',
      (tester) async {
        final vault = seedSegmentedVault();
        final dailyDb = FakeVaultDb.v5();
        addTearDown(dailyDb.close);
        final doubles = EditorVaultDoubles(
          notesDb: vault.db,
          dailyDb: dailyDb,
          cli: vault.cli,
        );
        final h = await pumpWorkspace(
          tester,
          db: vault.db,
          cli: vault.cli,
          overrides: [editorSingleVaultOverride(doubles)],
        );
        h.read(vaultAccessProvider);
        final r = SegmentedEditorRobot(tester, h);
        await r.open(fixtureTopicId);

        expect(r.textIn(r.card(1), 'removed from 2026-09-05'), findsWidgets);
      },
    );
  });

  group('switching vaults (AC5, D14a)', () {
    testWidgets(
      'switching vaults never shows the previous vault rows in the editor Days rows footer chips review chip or capture gutter',
      (tester) async {
        final dbA = _dayVault(
          person: 'Alpha day text',
          agentLine: 'Alpha agent line',
          topicId: 't-alpha',
          topic: 'Alpha Topic',
          withYesterday: true,
        );
        final dbB = _dayVault(
          person: 'Beta day text',
          agentLine: 'Beta agent line',
          topicId: 't-beta',
          topic: 'Beta Topic',
          review: false,
        );
        addTearDown(dbB.close);
        // Vault B restores a tab on the same note id as A's today note, so a
        // facade that ignored the loaded vault would show A's rows for it.
        final bDir = Directory.systemTemp.createTempSync('om78_vault_b');
        addTearDown(() {
          if (bDir.existsSync()) bDir.deleteSync(recursive: true);
        });
        final seedStore = UiStateStore(vaultPath: bDir.path);
        await tester.runAsync(() async {
          await seedStore.write(
            UiState(
              tabs: [
                PersistedTab(kind: PersistedTab.kindNote, id: _sharedDayId),
              ],
              activeTabIndex: 0,
              canvasViewports: const {},
            ),
          );
          await seedStore.flush();
        });

        final a = EditorVaultDoubles(notesDb: dbA, dailyDb: dbA);
        final b = EditorVaultDoubles(notesDb: dbB, dailyDb: dbB)
          ..holdFromStart = true;
        final h = await pumpWorkspace(
          tester,
          db: dbA,
          overrides: [
            vaultAccessProvider.overrideWith((ref) {
              final path = ref.watch(currentVaultProvider).localPath;
              if (path == null) return null;
              return path == bDir.path ? b.build(path) : a.build(path);
            }),
          ],
        );
        await pumpFrames(tester);

        // Vault A: today's note with all its rows.
        expect(h.read(tabsProvider).activeTab, const NoteTab(_sharedDayId));
        expect(_inEditor(find.textContaining('Alpha day text')), findsWidgets);
        expect(find.byKey(const Key('days-row-2026-10-02')), findsOneWidget);
        expect(find.byKey(const Key('footer-chip-t-alpha')), findsOneWidget);
        expect(find.byKey(const Key('review-chip')), findsOneWidget);
        expect(
          find.byKey(const Key('capture-gutter-rule-t-alpha-a')),
          findsOneWidget,
        );

        // Switch to B while all of B's reads are held, then show the tab of
        // the same note id.
        h.container.read(currentVaultProvider.notifier).state = LocalVaultRef(
          bDir.path,
        );
        await pumpFrames(tester);
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_sharedDayId));
        await pumpFrames(tester);

        expect(_inEditor(find.textContaining('Alpha')), findsNothing);
        expect(find.byKey(const Key('days-row-2026-10-02')), findsNothing);
        expect(find.byKey(const Key('footer-chip-t-alpha')), findsNothing);
        expect(find.byKey(const Key('review-chip')), findsNothing);
        expect(
          find.byKey(const Key('capture-gutter-rule-t-alpha-a')),
          findsNothing,
        );

        b.release();
        await pumpFrames(tester);

        expect(_inEditor(find.textContaining('Beta day text')), findsWidgets);
        expect(find.byKey(const Key('footer-chip-t-beta')), findsOneWidget);
        expect(_inEditor(find.textContaining('Alpha')), findsNothing);
      },
    );
  });
}
