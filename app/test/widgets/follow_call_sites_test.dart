// WI #263 (N0): every moved call site goes through the navigation seam. Each
// test pumps the real workspace (or the real pane) with TabsRecorder and asserts
// the recorded target, never tab counts, so #266's flip can't break them.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/sidebar/notes_pane.dart';

import '../robots/smart_folder_robot.dart';
import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/graph_seeds.dart';
import '../support/recording_tabs.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';
import '../support/topics_seed.dart';

// The harness clock's date, so the seeded daily note is the launch tab.
const _today = '2026-10-03';
const _todayId = 'daily-2026-10-03';

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: key);
  await tester.tap(f);
  await pumpFrames(tester);
}

/// Launches the Topics sidebar over the Topics fixture with [tabs] recording.
Future<SmartFolderRobot> _launchTopics(
  WidgetTester tester,
  TabsRecorder tabs, {
  FakeVaultDb? db,
  FakeMemexCli? cli,
}) => launchTopics(
  tester,
  AccessDoubles(),
  db: db,
  cli: cli,
  overrides: [tabs.override],
);

/// Opens [noteId] without going through the seam, then taps its note menu's
/// Graph item.
Future<void> _tapNoteMenuGraph(
  WidgetTester tester,
  WorkspaceHarness h,
  String noteId,
) async {
  h.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
  await pumpFrames(tester);
  await _tap(tester, 'note-menu-button');
  await _tap(tester, 'note-menu-open-graph');
}

void main() {
  group('sidebar rows, chips and nodes record their follow target', () {
    testWidgets('a click on a footer topic chip records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedTopicNote('topic-sleep', 'Sleep')
        ..seedFooterChip(_todayId, 'topic-sleep');
      await pumpWorkspace(
        tester,
        db: db,
        surfaceSize: const Size(1600, 1400),
        overrides: [tabs.override],
      );

      await _tap(tester, 'footer-chip-topic-sleep');

      expect(tabs.followed, [const NoteTab('topic-sleep')]);
      expect(tabs.navigated, [const NoteTab('topic-sleep')]);
    });

    testWidgets('a click on a Topics row records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final r = await _launchTopics(tester, tabs);

      await r.tap(r.topics.unsortedNote(TP.looseNote));

      expect(tabs.followed, [const NoteTab(TP.looseNote)]);
      expect(tabs.navigated, [const NoteTab(TP.looseNote)]);
    });

    testWidgets(
      'a click on a topic row in a folder records its follow target',
      (tester) async {
        final tabs = TabsRecorder();
        final r = await _launchTopics(tester, tabs);
        await r.ensureExpanded(TP.health);

        await r.tap(r.topics.topic(TP.health, TP.sleep));

        expect(tabs.followed, [const NoteTab(TP.sleep)]);
      },
    );

    testWidgets('a click on a dated Days row records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final db = FakeVaultDb.v5()..seedDailyNote('2026-10-01', id: 'day-1');
      await pumpWorkspace(tester, db: db, overrides: [tabs.override]);

      await _tap(tester, 'days-row-2026-10-01');

      expect(tabs.followed, [const NoteTab('day-1')]);
      expect(tabs.navigated, [const NoteTab('day-1')]);
    });

    testWidgets(
      'a Cmd click on a dated Days row records follow and no navigate',
      (tester) async {
        final tabs = TabsRecorder();
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-01', id: 'day-1');
        await pumpWorkspace(tester, db: db, overrides: [tabs.override]);

        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        try {
          await _tap(tester, 'days-row-2026-10-01');
        } finally {
          await tester.sendKeyUpEvent(
            LogicalKeyboardKey.metaLeft,
            platform: 'macos',
          );
        }

        expect(tabs.followed, [const NoteTab('day-1')]);
        expect(tabs.navigated, isEmpty);
      },
    );

    testWidgets('a click on a Notes row records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final h = await pumpWorkspace(tester, overrides: [tabs.override]);
      // NotesPane has no host in the workspace today: pump it on the same
      // container.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: buildOmTheme(),
            home: Scaffold(
              body: NotesPane(
                notes: [
                  NoteListItem(
                    id: 'n1',
                    title: 'Alpha',
                    snippet: '',
                    version: 1,
                    updatedAt: 0,
                  ),
                ],
                onNewNote: () {},
              ),
            ),
          ),
        ),
      );
      await pumpFrames(tester);

      await _tap(tester, 'note-list-item-n1');

      expect(tabs.followed, [const NoteTab('n1')]);
      expect(tabs.navigated, [const NoteTab('n1')]);
    });

    testWidgets('a click on a canvases rail row records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final db = FakeVaultDb.v5()..seedCanvas('c1', 'Board', updatedAt: 1);
      await pumpWorkspace(tester, db: db, overrides: [tabs.override]);

      await _tap(tester, 'canvas-row-c1');

      expect(tabs.followed, [const CanvasTab('c1')]);
      expect(tabs.navigated, [const CanvasTab('c1')]);
    });

    testWidgets('a click on a graph node records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final db = FakeVaultDb.v5();
      seedGraphFixture(db);
      final h = await pumpWorkspace(tester, db: db, overrides: [tabs.override]);
      h
          .read(tabsProvider.notifier)
          .openOrFocus(GraphTab(const GraphScope.topic(G.alpha)));
      await pumpFrames(tester, frames: 20);

      await _tap(tester, 'graph-node-${G.beta}');

      expect(tabs.followed, [const NoteTab(G.beta)]);
      expect(tabs.navigated, [const NoteTab(G.beta)]);
    });
  });

  group('Graph actions record follow of a GraphTab', () {
    testWidgets(
      'the note menu Graph action records follow of the topic scope',
      (tester) async {
        final tabs = TabsRecorder();
        final db = FakeVaultDb.v5();
        seedGraphFixture(db);
        final h = await pumpWorkspace(
          tester,
          db: db,
          overrides: [tabs.override],
        );

        await _tapNoteMenuGraph(tester, h, G.alpha);

        expect(tabs.followed, [GraphTab(const GraphScope.topic(G.alpha))]);
      },
    );

    testWidgets('the note menu Graph action records follow of the day scope', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      final db = FakeVaultDb.v5();
      seedGraphFixture(db);
      final h = await pumpWorkspace(tester, db: db, overrides: [tabs.override]);

      await _tapNoteMenuGraph(tester, h, G.day0905);

      expect(tabs.followed, [GraphTab(const GraphScope.day(G.day0905))]);
    });

    testWidgets(
      'the folder menu Graph action records follow of the folder scope',
      (tester) async {
        final tabs = TabsRecorder();
        final r = await _launchTopics(tester, tabs);

        await r.openFolderGraph(TP.games);

        expect(tabs.followed, [GraphTab(const GraphScope.folder(TP.games))]);
        expect(tabs.navigated, [GraphTab(const GraphScope.folder(TP.games))]);
      },
    );

    testWidgets(
      'the Topics Graph header action records follow of the vault scope',
      (tester) async {
        final tabs = TabsRecorder();
        final r = await _launchTopics(tester, tabs);

        await r.tap(r.graphAction);

        expect(tabs.followed, [GraphTab(const GraphScope.vault())]);
        expect(tabs.navigated, [GraphTab(const GraphScope.vault())]);
      },
    );
  });

  group('created items navigate and do not follow', () {
    testWidgets(
      'New canvas records its target in navigated and nothing in followed',
      (tester) async {
        final tabs = TabsRecorder();
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          )
          ..on('canvas new', (call) {
            db.seedCanvas('c-new', call.flag('title')!, updatedAt: 1);
            return FakeMemexCli.ok(
              '{"canvas_id":"c-new","title":"${call.flag('title')}",'
              '"version":1,"created_at":1,"updated_at":1}',
            );
          });
        await pumpWorkspace(
          tester,
          db: db,
          cli: cli,
          overrides: [tabs.override],
        );

        // The second "+ NEW" in the sidebar; the first is the vaults header.
        await tester.tap(
          find
              .descendant(
                of: find.byType(Sidebar),
                matching: find.text('+ NEW'),
              )
              .at(1),
        );
        await pumpFrames(tester);
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Board',
        );
        await _tap(tester, 'new-canvas-confirm');

        expect(tabs.navigated, [const CanvasTab('c-new')]);
        expect(tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'new topic records its target in navigated and nothing in followed',
      (tester) async {
        final tabs = TabsRecorder();
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = FakeMemexCli()
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final r = await _launchTopics(tester, tabs, db: db, cli: cli);

        await r.tap(r.byKey('topics-new-topic'));
        await tester.enterText(r.byKey('new-topic-title-field'), 'Player Loop');
        await tester.pump();
        await r.tap(r.byKey('new-topic-confirm'));

        expect(tabs.navigated, [const NoteTab(createdTopicId)]);
        expect(tabs.followed, isEmpty);
      },
    );
  });
}
