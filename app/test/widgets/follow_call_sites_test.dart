// WI #263 (N0): every moved call site goes through the navigation seam. Each
// test pumps the real workspace (or the real pane) with TabsRecorder and asserts
// the recorded target, never tab counts, so #266's flip can't break them.
//
// WI #266 (N3), from the `plain click navigates` group on: the tab state each
// call site leaves, plain and with Cmd held.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/sidebar/notes_pane.dart';

import '../robots/smart_folder_robot.dart';
import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
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
  holdFontFetches();

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

        // The only "+ NEW" in the sidebar: the vaults header shows MANAGE
        // since #363.
        await tester.tap(
          find.descendant(
            of: find.byType(Sidebar),
            matching: find.text('+ NEW'),
          ),
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

  group('plain click navigates and Cmd click focuses or opens', () {
    testWidgets(
      'a plain click on a footer topic chip navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedTopicNote('topic-sleep', 'Sleep')
          ..seedFooterChip(_todayId, 'topic-sleep');
        final h = await pumpWorkspace(
          tester,
          db: db,
          surfaceSize: const Size(1600, 1400),
        );

        await _n3PlainAndCmd(
          tester,
          h,
          () => _tap(tester, 'footer-chip-topic-sleep'),
          const NoteTab('topic-sleep'),
          frames: 5,
        );
      },
    );

    testWidgets(
      'a plain click on a Topics row navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final r = await launchTopics(tester, AccessDoubles());

        await _n3PlainAndCmd(
          tester,
          r.h,
          () => r.tap(r.topics.unsortedNote(TP.looseNote)),
          const NoteTab(TP.looseNote),
        );
      },
    );

    testWidgets(
      'a plain click on a dated Days row navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-01', id: 'day-1');
        final h = await pumpWorkspace(tester, db: db);

        await _n3PlainAndCmd(
          tester,
          h,
          () => _tap(tester, 'days-row-2026-10-01'),
          const NoteTab('day-1'),
        );
      },
    );

    testWidgets(
      'a plain click on a Notes row navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final h = await pumpWorkspace(tester);
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

        await _n3PlainAndCmd(
          tester,
          h,
          () => _tap(tester, 'note-list-item-n1'),
          const NoteTab('n1'),
        );
      },
    );

    testWidgets(
      'a plain click on a canvases rail row navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final db = FakeVaultDb.v5()..seedCanvas('c1', 'Board', updatedAt: 1);
        final h = await pumpWorkspace(tester, db: db);

        await _n3PlainAndCmd(
          tester,
          h,
          () => _tap(tester, 'canvas-row-c1'),
          const CanvasTab('c1'),
        );
      },
    );

    testWidgets(
      'a plain click on a graph node navigates the current tab and a Cmd click focuses or opens a tab',
      (tester) async {
        final db = FakeVaultDb.v5();
        seedGraphFixture(db);
        final h = await pumpWorkspace(tester, db: db);
        h
            .read(tabsProvider.notifier)
            .openOrFocus(GraphTab(const GraphScope.topic(G.alpha)));
        await pumpFrames(tester, frames: 20);

        await _n3PlainAndCmd(
          tester,
          h,
          () => _tap(tester, 'graph-node-${G.beta}'),
          const NoteTab(G.beta),
          frames: 20,
        );
      },
    );
  });

  group('Graph actions navigate and Cmd click focuses or opens', () {
    Future<void> noteMenuGraph(
      WidgetTester tester,
      String noteId,
      GraphScope scope,
    ) async {
      final db = FakeVaultDb.v5();
      seedGraphFixture(db);
      final h = await pumpWorkspace(tester, db: db);
      h.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
      await pumpFrames(tester);

      await _n3PlainAndCmd(
        tester,
        h,
        () async {
          await _tap(tester, 'note-menu-button');
          await _tap(tester, 'note-menu-open-graph');
        },
        GraphTab(scope),
        frames: 5,
      );
    }

    testWidgets(
      'the note menu Graph action on a topic navigates on a plain click and focuses or opens on a Cmd click',
      (tester) =>
          noteMenuGraph(tester, G.alpha, const GraphScope.topic(G.alpha)),
    );

    testWidgets(
      'the note menu Graph action on a day navigates on a plain click and focuses or opens on a Cmd click',
      (tester) =>
          noteMenuGraph(tester, G.day0905, const GraphScope.day(G.day0905)),
    );

    testWidgets(
      'the folder menu Graph action navigates on a plain click and focuses or opens on a Cmd click',
      (tester) async {
        final r = await launchTopics(tester, AccessDoubles());

        await _n3PlainAndCmd(
          tester,
          r.h,
          () => r.openFolderGraph(TP.games),
          GraphTab(const GraphScope.folder(TP.games)),
        );
      },
    );

    testWidgets(
      'the Topics Graph action navigates on a plain click and focuses or opens on a Cmd click',
      (tester) async {
        final r = await launchTopics(tester, AccessDoubles());

        await _n3PlainAndCmd(
          tester,
          r.h,
          () => r.tap(r.graphAction),
          GraphTab(const GraphScope.vault()),
        );
      },
    );
  });

  group('created items navigate the current tab', () {
    for (final (name, cmd) in [
      ('New note navigates the current tab', false),
      ('New note with Cmd held navigates the current tab', true),
    ]) {
      testWidgets(name, (tester) async {
        final tabs = TabsRecorder();
        final db = FakeVaultDb.v5();
        final h = await pumpWorkspace(
          tester,
          db: db,
          cli: _n3NewNoteCli(db),
          overrides: [tabs.override],
        );
        final before = h.read(tabsProvider);

        Future<void> newNote() async {
          tester.widget<Sidebar>(find.byType(Sidebar)).onNewNote();
          await pumpFrames(tester);
        }

        await (cmd ? _n3WithCmd(tester, newNote) : newNote());

        _n3ExpectNavigatedTo(h, before, const NoteTab(_n3NewNoteId));
        expect(tabs.navigated, [const NoteTab(_n3NewNoteId)]);
        expect(tabs.followed, isEmpty);
      });
    }

    for (final (name, cmd) in [
      ('New canvas navigates the current tab', false),
      ('New canvas with Cmd held navigates the current tab', true),
    ]) {
      testWidgets(name, (tester) async {
        final db = FakeVaultDb.v5();
        final h = await pumpWorkspace(tester, db: db, cli: _n3NewCanvasCli(db));
        final before = h.read(tabsProvider);

        await (cmd
            ? _n3WithCmd(tester, () => _n3NewCanvas(tester))
            : _n3NewCanvas(tester));

        _n3ExpectNavigatedTo(h, before, const CanvasTab('c-new'));
      });
    }

    for (final (name, cmd) in [
      ('new topic navigates the current tab', false),
      ('new topic with Cmd held navigates the current tab', true),
    ]) {
      testWidgets(name, (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = FakeMemexCli()
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final r = await launchTopics(tester, AccessDoubles(), db: db, cli: cli);
        final before = r.h.read(tabsProvider);

        await (cmd
            ? _n3WithCmd(tester, () => _n3NewTopic(r, tester))
            : _n3NewTopic(r, tester));

        _n3ExpectNavigatedTo(r.h, before, const NoteTab(createdTopicId));
      });
    }
  });

  group('the tab bar and the sidebar around Back and Forward', () {
    testWidgets(
      'the chip close closes only that tab when two tabs show the same value',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: 'n1', title: 'One', content: 'one');
        final h = await pumpWorkspace(tester, db: db);
        final tabs = h.read(tabsProvider.notifier);
        tabs.openOrFocus(const NoteTab('n1'));
        tabs.setActive(0);
        tabs.navigate(const NoteTab('n1')); // [n1*] [n1]
        await pumpFrames(tester);
        expect(h.read(tabsProvider).tabs, [
          const NoteTab('n1'),
          const NoteTab('n1'),
        ]);

        await tester.tap(find.byKey(const Key('tab-close-note-n1')).at(1));
        await pumpFrames(tester);

        final now = h.read(tabsProvider);
        expect(now.tabs, [const NoteTab('n1')]);
        expect(
          now.canGoBack,
          isTrue,
          reason: 'the left tab with history stays',
        );
      },
    );

    testWidgets(
      'back and forward leave the sidebar mode the expanded folders and the right panel as they were',
      (tester) async {
        final r = await launchTopics(tester, AccessDoubles());
        final h = r.h;
        await r.ensureExpanded(TP.health);
        h.container.read(rightPanelOpenProvider.notifier).state = false;
        await pumpFrames(tester);
        final start = h.read(tabsProvider).activeTab;
        final tabs = h.read(tabsProvider.notifier);
        tabs.navigate(const NoteTab(TP.looseNote));
        await pumpFrames(tester);
        final mode = h.read(sidebarModeProvider);
        final expanded = {...h.read(expandedTopicFoldersProvider)};
        expect(mode, SidebarMode.topics);
        expect(expanded, contains(TP.health));

        tabs.back();
        await pumpFrames(tester);
        expect(h.read(tabsProvider).activeTab, start);
        expect(h.read(sidebarModeProvider), mode);
        expect(h.read(expandedTopicFoldersProvider), expanded);
        expect(h.read(rightPanelOpenProvider), isFalse);

        tabs.forward();
        await pumpFrames(tester);
        expect(h.read(tabsProvider).activeTab, const NoteTab(TP.looseNote));
        expect(h.read(sidebarModeProvider), mode);
        expect(h.read(expandedTopicFoldersProvider), expanded);
        expect(h.read(rightPanelOpenProvider), isFalse);
      },
    );
  });
}

/// Runs [click] with the real Cmd key held, releasing it even when [click]
/// throws.
Future<void> _n3WithCmd(
  WidgetTester tester,
  Future<void> Function() click,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  try {
    await click();
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  }
}

/// From the active tab: a Cmd [click] opens [target] in a new tab at the end;
/// back on the first tab, a second Cmd [click] focuses that tab; back on the
/// first tab again, a plain [click] navigates it to [target], so two tabs show
/// it. [frames] settles the view after each chip switch.
Future<void> _n3PlainAndCmd(
  WidgetTester tester,
  WorkspaceHarness h,
  Future<void> Function() click,
  WorkspaceTab target, {
  int frames = 1,
}) async {
  final tabs = h.read(tabsProvider.notifier);
  final start = h.read(tabsProvider);
  final home = start.activeIndex;
  final open = [...start.tabs];
  expect(open, isNot(contains(target)), reason: 'the target starts closed');

  await _n3WithCmd(tester, click);
  var now = h.read(tabsProvider);
  expect(now.tabs, [...open, target], reason: 'a Cmd click opens a tab');
  expect(now.activeIndex, open.length);
  expect(now.canGoBack, isFalse, reason: 'its history holds only the target');

  tabs.setActive(home);
  await pumpFrames(tester, frames: frames);
  await _n3WithCmd(tester, click);
  now = h.read(tabsProvider);
  expect(now.tabs, [...open, target], reason: 'a Cmd click focuses its tab');
  expect(now.activeIndex, open.length);

  tabs.setActive(home);
  await pumpFrames(tester, frames: frames);
  await click();
  now = h.read(tabsProvider);
  expect(now.tabs, [
    for (var i = 0; i < open.length; i++) i == home ? target : open[i],
    target,
  ], reason: 'a plain click navigates the current tab');
  expect(now.activeIndex, home);
  expect(now.canGoBack, isTrue);
}

/// The created item replaced what the active tab showed: same tab count and
/// active index, with the old target one Back away.
void _n3ExpectNavigatedTo(
  WorkspaceHarness h,
  TabsState before,
  WorkspaceTab created,
) {
  final now = h.read(tabsProvider);
  expect(now.tabs, hasLength(before.tabs.length), reason: 'no tab opened');
  expect(now.activeIndex, before.activeIndex);
  expect(now.activeTab, created);
  expect(now.canGoBack, isTrue);
}

const _n3NewNoteId = '01J9NEWNOTE000000000000266';

FakeMemexCli _n3NewNoteCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..on('add', (call) {
    db.seedNote(
      id: _n3NewNoteId,
      title: call.flag('title') ?? '',
      content: call.stdinBody ?? '',
    );
    return FakeMemexCli.ok('note_id: $_n3NewNoteId\n');
  });

FakeMemexCli _n3NewCanvasCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..on('canvas new', (call) {
    db.seedCanvas('c-new', call.flag('title')!, updatedAt: 1);
    return FakeMemexCli.ok(
      '{"canvas_id":"c-new","title":"${call.flag('title')}",'
      '"version":1,"created_at":1,"updated_at":1}',
    );
  });

Future<void> _n3NewCanvas(WidgetTester tester) async {
  // The only "+ NEW": the vaults header shows MANAGE since #363.
  await tester.tap(
    find.descendant(of: find.byType(Sidebar), matching: find.text('+ NEW')),
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
}

Future<void> _n3NewTopic(SmartFolderRobot r, WidgetTester tester) async {
  await r.tap(r.byKey('topics-new-topic'));
  await tester.enterText(r.byKey('new-topic-title-field'), 'Player Loop');
  await tester.pump();
  await r.tap(r.byKey('new-topic-confirm'));
}
