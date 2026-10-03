// WI #24 (A7): the sidebar Topics tree, Unsorted and the empty state (Req 2,
// 35, 39, 46, 52, 53; TD8; Spec TS4). Robot journeys over the whole workspace
// with FakeVaultDb and FakeMemexCli seams.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../robots/topics_robot.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

const _promptText =
    'Review my daily notes.\n\n1. Read each day.\n2. File topics — carefully.\n';

FakeVaultDb _fixture() => FakeVaultDb.v5()..seedTopicsFixture();

void main() {
  group('the Topics mode shows the pane (AC11)', () {
    testWidgets(
      'selecting Topics mode shows topics-pane and topics-actions instead of the interim notes pane',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());

        // Days is the default mode: no Topics pane yet.
        expect(r.daysPane, findsOneWidget);
        expect(r.pane, findsNothing);

        await r.chooseTopics();

        expect(r.pane, findsOneWidget);
        expect(r.actions, findsOneWidget);
        expect(r.notesRail, findsNothing);
        expect(r.daysPane, findsNothing);
      },
    );

    testWidgets(
      'the pane and its action row are present in the empty state too',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: FakeVaultDb.v5());
        await r.chooseTopics();

        expect(r.pane, findsOneWidget);
        expect(r.actions, findsOneWidget);
        expect(r.notesRail, findsNothing);
      },
    );

    testWidgets('switching back to Days hides the Topics pane', (tester) async {
      final r = TopicsRobot(tester);
      await r.launch(db: _fixture());
      await r.chooseTopics();
      expect(r.pane, findsOneWidget);

      await r.chooseDays();

      expect(r.pane, findsNothing);
      expect(r.daysPane, findsOneWidget);
    });
  });

  group('expanding and collapsing Smart Folders (AC4)', () {
    testWidgets(
      'every folder starts collapsed showing only the root folders and Unsorted',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        expect(r.folder(TP.games), findsOneWidget);
        expect(r.folder(TP.health), findsOneWidget);
        expect(r.folder(TP.design), findsNothing);
        expect(r.topicRows, findsNothing);
      },
    );

    testWidgets(
      'tapping a collapsed folder toggle shows its subfolders and topic rows and tapping again collapses it',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        await r.toggleFolder(TP.games);

        expect(r.folder(TP.design), findsOneWidget);
        expect(r.topic(TP.games, TP.loop), findsOneWidget);
        expect(r.topic(TP.games, TP.economy), findsOneWidget);
        // The other folder stays collapsed.
        expect(r.topic(TP.health, TP.sleep), findsNothing);
        r.expectShows(r.topic(TP.games, TP.loop), 'Player Loop');
        r.expectShows(r.folder(TP.games), 'Games');
        r.expectShows(r.folder(TP.design), 'Design');

        await r.toggleFolder(TP.games);

        expect(r.folder(TP.design), findsNothing);
        expect(r.topicRows, findsNothing);
        expect(r.folder(TP.games), findsOneWidget);
      },
    );

    testWidgets(
      'a subfolder expands on its own and a topic in two folders is listed under both',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);
        expect(r.topic(TP.design, TP.level), findsNothing);

        await r.toggleFolder(TP.design);

        expect(r.topic(TP.design, TP.level), findsOneWidget);
        expect(r.topic(TP.design, TP.loop), findsOneWidget);
        // Player Loop also sits directly in Games (a parent with subfolders).
        expect(r.topic(TP.games, TP.loop), findsOneWidget);

        // Collapsing the parent hides the whole subtree.
        await r.toggleFolder(TP.games);
        expect(r.folder(TP.design), findsNothing);
        expect(r.topic(TP.design, TP.level), findsNothing);
      },
    );

    testWidgets(
      'folders are sorted by name ignoring case and a subfolder indents under its parent',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);

        // Games (G) before health (h); topics Economy before Player Loop.
        expect(r.top(r.folder(TP.games)), lessThan(r.top(r.folder(TP.health))));
        expect(
          r.top(r.topic(TP.games, TP.economy)),
          lessThan(r.top(r.topic(TP.games, TP.loop))),
        );
        // Design is nested: its row starts further right than its parent.
        expect(
          r.labelLeft(r.folder(TP.design), 'Design'),
          greaterThan(r.labelLeft(r.folder(TP.games), 'Games')),
        );
        // Subfolders come before the topics of their parent or after, but
        // both sit between Games and health.
        expect(
          r.top(r.folder(TP.design)),
          greaterThan(r.top(r.folder(TP.games))),
        );
        expect(
          r.top(r.folder(TP.design)),
          lessThan(r.top(r.folder(TP.health))),
        );
      },
    );

    testWidgets(
      'an expanded folder stays expanded across a vault revision bump',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);

        await r.bumpRevision();

        expect(r.topic(TP.games, TP.loop), findsOneWidget);
        expect(r.folder(TP.design), findsOneWidget);
      },
    );

    testWidgets('expansion is not persisted to ui_state.json', (tester) async {
      final r = TopicsRobot(tester);
      await r.launch(db: _fixture());
      await r.chooseTopics();
      await r.toggleFolder(TP.games);
      await r.toggleFolder(TP.design);

      // Something else is written (the sidebar mode), expansion is not.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      final json = r.uiStateJson();
      expect(json, isNot(contains(TP.games)));
      expect(json, isNot(contains(TP.design)));
    });
  });

  group('pinned glyphs (AC5)', () {
    testWidgets(
      'a pinned folder shows pinned-glyph-folder-id and an unpinned folder shows none',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        expect(r.folderGlyph(TP.games), findsOneWidget);
        expect(r.hasPinIcon(r.folderGlyph(TP.games)), isTrue);
        expect(r.folderGlyph(TP.health), findsNothing);
        expect(r.hasPinIcon(r.folder(TP.health)), isFalse);
      },
    );

    testWidgets(
      'a pinned membership shows pinned-glyph-member and unpinned memberships show none',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);
        await r.toggleFolder(TP.design);

        expect(r.memberGlyph(TP.games, TP.loop), findsOneWidget);
        expect(r.hasPinIcon(r.memberGlyph(TP.games, TP.loop)), isTrue);
        expect(r.memberGlyph(TP.games, TP.economy), findsNothing);
        expect(r.hasPinIcon(r.topic(TP.games, TP.economy)), isFalse);
        // The same note is unpinned in the Design folder.
        expect(r.memberGlyph(TP.design, TP.loop), findsNothing);
        expect(r.hasPinIcon(r.topic(TP.design, TP.loop)), isFalse);
        expect(r.memberGlyph(TP.design, TP.level), findsNothing);
      },
    );

    testWidgets(
      'the pin glyph sits inside its own row and the unpinned subfolder has none',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);

        expect(
          find.descendant(
            of: r.folder(TP.games),
            matching: r.folderGlyph(TP.games),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: r.topic(TP.games, TP.loop),
            matching: r.memberGlyph(TP.games, TP.loop),
          ),
          findsOneWidget,
        );
        expect(r.folderGlyph(TP.design), findsNothing);
      },
    );
  });

  group('the Unsorted row (AC6)', () {
    testWidgets(
      'Unsorted is the last row labelled Unsorted and lists role-less notes with no membership',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        expect(r.unsorted, findsOneWidget);
        expect(
          r.textsUnder(r.unsorted).map((t) => t.trim().toLowerCase()),
          contains('unsorted'),
        );
        expect(r.unsortedNote(TP.looseNote), findsOneWidget);
        r.expectShows(r.unsortedNote(TP.looseNote), 'Loose thought');
        // A topic note in no folder is reachable here too.
        expect(r.unsortedNote(TP.orphan), findsOneWidget);
        // Notes in a folder and daily notes are not listed.
        expect(r.unsortedNote(TP.loop), findsNothing);
        expect(r.unsortedNote(TP.sleep), findsNothing);
        expect(r.unsortedNote(TP.daily), findsNothing);
        // Loose thought sorts before Orphan topic.
        expect(
          r.top(r.unsortedNote(TP.looseNote)),
          lessThan(r.top(r.unsortedNote(TP.orphan))),
        );
      },
    );

    testWidgets(
      'Unsorted comes after every folder row and every expanded topic row',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        double lastFolderBottom() {
          var bottom = 0.0;
          for (final e in [
            ...r.folderRows.evaluate(),
            ...r.topicRows.evaluate(),
          ]) {
            final b = (e.renderObject! as RenderBox)
                .localToGlobal(
                  Offset(0, (e.renderObject! as RenderBox).size.height),
                )
                .dy;
            if (b > bottom) bottom = b;
          }
          return bottom;
        }

        expect(r.top(r.unsorted), greaterThanOrEqualTo(lastFolderBottom()));

        await r.toggleFolder(TP.games);
        await r.toggleFolder(TP.design);
        await r.toggleFolder(TP.health);

        expect(r.topicRows, findsWidgets);
        expect(r.top(r.unsorted), greaterThanOrEqualTo(lastFolderBottom()));
        // The unsorted note rows follow the Unsorted header.
        for (final e in r.unsortedRows.evaluate()) {
          expect(
            (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
            greaterThanOrEqualTo(r.top(r.unsorted)),
          );
        }
      },
    );

    testWidgets(
      'Unsorted has no menu and no pin glyph, and its note rows have none either',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();

        expect(r.unsorted, findsOneWidget);
        expect(r.unsortedNote(TP.looseNote), findsOneWidget);
        expect(r.hasMenu(r.unsorted), isFalse);
        expect(r.hasPinIcon(r.unsorted), isFalse);
        expect(r.hasMenu(r.unsortedNote(TP.looseNote)), isFalse);
        expect(r.hasPinIcon(r.unsortedNote(TP.looseNote)), isFalse);
        expect(r.keyedWithPrefix('pinned-glyph-folder-unsorted'), findsNothing);
      },
    );

    testWidgets('when no note is unsorted the Unsorted row is not shown', (
      tester,
    ) async {
      final db = FakeVaultDb.v5()
        ..seedTopicNote('t-1', 'Filed topic')
        ..seedSmartFolder('f-1', 'Folder')
        ..seedFolderMember('f-1', 't-1')
        ..seedDailyNote('2026-10-02');
      final r = TopicsRobot(tester);
      await r.launch(db: db);
      await r.chooseTopics();

      expect(r.folder('f-1'), findsOneWidget);
      expect(r.unsorted, findsNothing);
      expect(r.unsortedRows, findsNothing);
    });

    testWidgets(
      'a note leaves Unsorted once a folder contains it and the tree refreshes',
      (tester) async {
        final db = _fixture();
        final r = TopicsRobot(tester);
        await r.launch(db: db);
        await r.chooseTopics();
        expect(r.unsortedNote(TP.looseNote), findsOneWidget);

        db.seedFolderMember(TP.health, TP.looseNote);
        await r.bumpRevision();

        expect(r.unsortedNote(TP.looseNote), findsNothing);
        await r.toggleFolder(TP.health);
        expect(r.topic(TP.health, TP.looseNote), findsOneWidget);
      },
    );
  });

  group('live refresh (AC1)', () {
    testWidgets(
      'a seeded new Smart Folder appears in the open pane after a vault revision bump',
      (tester) async {
        final db = _fixture();
        final r = TopicsRobot(tester);
        await r.launch(db: db);
        await r.chooseTopics();
        expect(r.folder('f-new'), findsNothing);

        db.seedSmartFolder('f-new', 'Archive');
        // The pane does not poll the database by itself.
        await pumpFramesQuietly(tester);
        expect(r.folder('f-new'), findsNothing);

        await r.bumpRevision();

        expect(r.folder('f-new'), findsOneWidget);
        r.expectShows(r.folder('f-new'), 'Archive');
      },
    );
  });

  group('opening a topic (AC7)', () {
    testWidgets('tapping a topic row opens that note tab', (tester) async {
      final r = TopicsRobot(tester);
      await r.launch(db: _fixture());
      await r.chooseTopics();
      await r.toggleFolder(TP.games);

      await r.openTopic(TP.games, TP.economy);

      expect(r.activeTab, const NoteTab(TP.economy));
      expect(r.tabs.tabs, contains(const NoteTab(TP.economy)));
    });

    testWidgets(
      'the same topic from two folders focuses one tab and never opens a second',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);
        await r.toggleFolder(TP.design);

        await r.openTopic(TP.games, TP.loop);
        final afterFirst = r.tabs.tabs.length;
        await r.openTopic(TP.design, TP.loop);

        expect(r.activeTab, const NoteTab(TP.loop));
        expect(r.tabs.tabs.length, afterFirst);
        expect(
          r.tabs.tabs.where((t) => t == const NoteTab(TP.loop)),
          hasLength(1),
        );
      },
    );

    testWidgets(
      'the row of the active note tab is highlighted and no other row is',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: _fixture());
        await r.chooseTopics();
        await r.toggleFolder(TP.games);
        expect(_fill(r.topic(TP.games, TP.economy)), isNot(OmColors.surface4));

        await r.openTopic(TP.games, TP.economy);

        expect(_fill(r.topic(TP.games, TP.economy)), OmColors.surface4);
        expect(_fill(r.topic(TP.games, TP.loop)), isNot(OmColors.surface4));
        expect(_fill(r.unsortedNote(TP.looseNote)), isNot(OmColors.surface4));

        await r.openUnsorted(TP.looseNote);

        expect(_fill(r.unsortedNote(TP.looseNote)), OmColors.surface4);
        expect(_fill(r.unsortedNote(TP.orphan)), isNot(OmColors.surface4));
        expect(_fill(r.topic(TP.games, TP.economy)), isNot(OmColors.surface4));
      },
    );

    testWidgets('tapping an Unsorted note row opens that note tab', (
      tester,
    ) async {
      final r = TopicsRobot(tester);
      await r.launch(db: _fixture());
      await r.chooseTopics();

      await r.openUnsorted(TP.looseNote);

      expect(r.activeTab, const NoteTab(TP.looseNote));
    });
  });

  group('the empty state (AC8)', () {
    testWidgets(
      'with no Smart Folders and no topic notes the pane shows the review message and the Copy review prompt button',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: FakeVaultDb.v5());
        await r.chooseTopics();

        r.expectEmptyCopy();
        expect(r.copyButton, findsOneWidget);
        r.expectShows(r.copyButton, 'Copy review prompt');
        expect(r.folderRows, findsNothing);
        expect(r.topicRows, findsNothing);
      },
    );

    testWidgets(
      'role-less notes still show under Unsorted below the empty message',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: 'n-a', title: 'Plain note')
          ..seedNote(id: 'n-b', title: 'Another note')
          ..seedDailyNote('2026-10-02');
        final r = TopicsRobot(tester);
        await r.launch(db: db);
        await r.chooseTopics();

        r.expectEmptyCopy();
        expect(r.copyButton, findsOneWidget);
        expect(r.unsorted, findsOneWidget);
        expect(r.unsortedNote('n-a'), findsOneWidget);
        expect(r.unsortedNote('n-b'), findsOneWidget);
        expect(r.unsortedNote('daily-2026-10-02'), findsNothing);
        expect(r.top(r.unsorted), greaterThan(r.top(r.empty)));
        expect(r.top(r.unsortedNote('n-a')), greaterThan(r.top(r.empty)));
      },
    );

    testWidgets('a vault below V5 shows the empty state and does not throw', (
      tester,
    ) async {
      final db = FakeVaultDb.v4()..seedNote(id: 'n1', title: 'Old note');
      final r = TopicsRobot(tester);
      await r.launch(db: db);
      await r.chooseTopics();

      expect(r.pane, findsOneWidget);
      r.expectEmptyCopy();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Smart Folder with no notes hides the empty state', (
      tester,
    ) async {
      final db = FakeVaultDb.v5()..seedSmartFolder('f-solo', 'Solo');
      final r = TopicsRobot(tester);
      await r.launch(db: db);
      await r.chooseTopics();

      expect(r.folder('f-solo'), findsOneWidget);
      expect(r.empty, findsNothing);
      expect(r.copyButton, findsNothing);
    });

    testWidgets(
      'a topic note in no folder hides the empty state and shows under Unsorted',
      (tester) async {
        final db = FakeVaultDb.v5()..seedTopicNote('t-1', 'Only topic');
        final r = TopicsRobot(tester);
        await r.launch(db: db);
        await r.chooseTopics();

        expect(r.empty, findsNothing);
        expect(r.copyButton, findsNothing);
        expect(r.unsortedNote('t-1'), findsOneWidget);
      },
    );

    testWidgets('the populated tree has no empty message and no copy button', (
      tester,
    ) async {
      final r = TopicsRobot(tester);
      await r.launch(db: _fixture());
      await r.chooseTopics();

      expect(r.pane, findsOneWidget);
      expect(r.folder(TP.games), findsOneWidget);
      expect(r.empty, findsNothing);
      expect(r.copyButton, findsNothing);
    });

    testWidgets(
      'the empty state gives way to the tree when the agent files its first folder',
      (tester) async {
        final db = FakeVaultDb.v5()..seedNote(id: 'n-a', title: 'Plain note');
        final r = TopicsRobot(tester);
        await r.launch(db: db);
        await r.chooseTopics();
        expect(r.empty, findsOneWidget);

        db.seedTopicNote('t-1', 'First topic');
        db.seedSmartFolder('f-first', 'First');
        db.seedFolderMember('f-first', 't-1');
        await r.bumpRevision();

        expect(r.empty, findsNothing);
        expect(r.folder('f-first'), findsOneWidget);
      },
    );
  });

  group('Copy review prompt (AC9, AC10)', () {
    testWidgets(
      'tapping Copy review prompt runs memex prompt review and puts its exact stdout on the clipboard',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: FakeVaultDb.v5(), reviewPrompt: _promptText);
        await r.chooseTopics();
        expect(r.clipboardWrites, isEmpty);

        await r.copyReviewPrompt();

        expect(r.h.cli.callsFor('prompt review'), hasLength(1));
        expect(r.h.cli.callsFor('prompt review').single.args, [
          'prompt',
          'review',
        ]);
        expect(r.clipboardWrites, [_promptText]);
      },
    );

    testWidgets('a successful copy shows no inline error', (tester) async {
      final r = TopicsRobot(tester);
      await r.launch(db: FakeVaultDb.v5(), reviewPrompt: _promptText);
      await r.chooseTopics();

      await r.copyReviewPrompt();

      expect(r.clipboardWrites, [_promptText]);
      expect(
        find.descendant(of: r.pane, matching: find.textContaining('failed')),
        findsNothing,
      );
    });

    testWidgets(
      'nothing runs and nothing is copied before the button is tapped',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(db: FakeVaultDb.v5(), reviewPrompt: _promptText);
        await r.chooseTopics();

        expect(r.copyButton, findsOneWidget);
        expect(r.h.cli.callsFor('prompt review'), isEmpty);
        expect(r.clipboardWrites, isEmpty);
      },
    );

    testWidgets(
      'when memex prompt review fails the CLI error message shows inline and the clipboard is unchanged',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(
          db: FakeVaultDb.v5(),
          promptHandler: (_) =>
              FakeMemexCli.error('internal', 'review prompt unavailable'),
        );
        await r.chooseTopics();

        await r.copyReviewPrompt();

        expect(r.h.cli.callsFor('prompt review'), hasLength(1));
        expect(r.clipboardWrites, isEmpty);
        expect(
          find.descendant(
            of: r.pane,
            matching: find.textContaining('review prompt unavailable'),
          ),
          findsOneWidget,
        );
        // The button stays so the person can retry.
        expect(r.copyButton, findsOneWidget);
      },
    );

    testWidgets(
      'a failure with plain stderr shows that text inline and leaves the clipboard alone',
      (tester) async {
        final r = TopicsRobot(tester);
        await r.launch(
          db: FakeVaultDb.v5(),
          promptHandler: (_) => FakeMemexCli.failure('memex binary exploded'),
        );
        await r.chooseTopics();

        await r.copyReviewPrompt();

        expect(r.clipboardWrites, isEmpty);
        expect(
          find.descendant(
            of: r.pane,
            matching: find.textContaining('memex binary exploded'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a retry after a failure copies the prompt and clears the inline error',
      (tester) async {
        var attempts = 0;
        final r = TopicsRobot(tester);
        await r.launch(
          db: FakeVaultDb.v5(),
          promptHandler: (_) {
            attempts++;
            return attempts == 1
                ? FakeMemexCli.error('internal', 'review prompt unavailable')
                : FakeMemexCli.ok(_promptText);
          },
        );
        await r.chooseTopics();
        await r.copyReviewPrompt();
        expect(r.clipboardWrites, isEmpty);

        await r.copyReviewPrompt();

        expect(attempts, 2);
        expect(r.clipboardWrites, [_promptText]);
        expect(
          find.descendant(
            of: r.pane,
            matching: find.textContaining('review prompt unavailable'),
          ),
          findsNothing,
        );
      },
    );
  });
}

/// A few frames without touching the database, to show the pane does not
/// poll on its own.
Future<void> pumpFramesQuietly(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The fill colour of the first decorated box under [row].
Color? _fill(Finder row) {
  final box =
      find
              .descendant(
                of: row,
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.decoration is BoxDecoration,
                ),
              )
              .evaluate()
              .first
              .widget
          as Container;
  return (box.decoration! as BoxDecoration).color;
}
