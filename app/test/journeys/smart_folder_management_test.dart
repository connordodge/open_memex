// WI #25 (A8): managing Smart Folders from the Topics sidebar (Req 41, 46,
// 52, 54; Q3; Open Question default). Robot journeys over the whole
// workspace; FolderCliFake plays the server behind FakeMemexCli, so every
// tree change the tests see came from a `memex folder …` call and a re-read.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../robots/smart_folder_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

/// Games (pinned) > Design; health (unpinned); Unsorted: Loose thought
/// (role-less) and Orphan topic. See [TopicsSeed.seedTopicsFixture].
FakeVaultDb _fixture() => FakeVaultDb.v5()..seedTopicsFixture();

void main() {
  group('+ New Smart Folder (AC1)', () {
    testWidgets(
      'New Smart Folder with no folder selected asks for a name and calls folder new without parent id',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.tap(r.newFolderButton);
        expect(r.nameDialog, findsOneWidget);
        await r.enterName('Reading');
        expect(r.callsFor('folder new'), isEmpty);
        await r.tap(r.nameConfirm);

        final call = r.callsFor('folder new').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('name'), 'Reading');
        expect(call.hasFlag('parent-id'), isFalse);
        expect(r.nameDialog, findsNothing);

        const id = 'f-new-1';
        r.topics.expectShows(r.folder(id), 'Reading');
        expect(r.folderGlyph(id), findsOneWidget);
        expect(
          r.folderLabelLeft(id, 'Reading'),
          r.folderLabelLeft(TP.health, 'health'),
          reason: 'a root folder sits at the root indent',
        );
      },
    );

    testWidgets(
      'New Smart Folder with a folder selected passes that folder as parent id and shows the child pinned',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.selectFolder(TP.games);
        await r.createFolder('Combat');

        final call = r.callsFor('folder new').single;
        expect(call.flag('name'), 'Combat');
        expect(call.flag('parent-id'), TP.games);

        const id = 'f-new-1';
        await r.ensureExpanded(TP.games);
        r.topics.expectShows(r.folder(id), 'Combat');
        expect(r.folderGlyph(id), findsOneWidget);
        expect(
          r.folderLabelLeft(id, 'Combat'),
          greaterThan(r.folderLabelLeft(TP.games, 'Games')),
          reason: 'the new folder is nested under Games',
        );
      },
    );

    testWidgets(
      'Selecting a nested folder creates the new folder inside that nested folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        // Depth 3 is allowed here so the create succeeds.
        final db = _fixture()
          ..db.execute(
            "UPDATE vault_settings SET value = '3' "
            "WHERE key = 'smart_folder_max_depth'",
          );
        await r.launch(db: db);

        await r.selectFolder(TP.games);
        await r.selectFolder(TP.design);
        await r.createFolder('Bosses');

        expect(r.callsFor('folder new').single.flag('parent-id'), TP.design);
        await r.ensureExpanded(TP.design);
        expect(
          r.folderLabelLeft('f-new-1', 'Bosses'),
          greaterThan(r.folderLabelLeft(TP.design, 'Design')),
        );
      },
    );

    testWidgets('Cancelling the name dialog makes no folder new call', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());

      await r.tap(r.newFolderButton);
      await r.enterName('Reading');
      await r.tap(r.nameCancel);

      expect(r.nameDialog, findsNothing);
      expect(r.writes, isEmpty);
      expect(r.folder('f-new-1'), findsNothing);
    });
  });

  group('rename from the folder menu (AC2)', () {
    testWidgets(
      'Rename calls folder update with id and name and the row shows the new name with the pinned glyph',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(r.folderGlyph(TP.health), findsNothing);

        await r.openFolderMenu(TP.health);
        await r.tap(r.menuRename);
        expect(r.nameDialog, findsOneWidget);
        await r.enterName('Wellbeing');
        await r.tap(r.nameConfirm);

        final call = r.callsFor('folder update').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('id'), TP.health);
        expect(call.flag('name'), 'Wellbeing');
        expect(call.hasFlag('parent-id'), isFalse);
        expect(call.hasFlag('to-root'), isFalse);
        expect(call.flag('pinned'), isNot('false'));

        r.topics.expectShows(r.folder(TP.health), 'Wellbeing');
        expect(
          r.textsUnder(r.folder(TP.health)).any((t) => t.contains('health')),
          isFalse,
        );
        expect(r.folderGlyph(TP.health), findsOneWidget);
      },
    );
  });

  group('move from the folder menu (AC3)', () {
    testWidgets(
      'Move to another folder calls folder update with parent id and the folder shows under its new parent',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.openFolderMenu(TP.health);
        await r.tap(r.menuMove);
        expect(r.moveDialog, findsOneWidget);
        await r.tap(r.moveTarget(TP.games));

        final call = r.callsFor('folder update').single;
        expect(call.flag('id'), TP.health);
        expect(call.flag('parent-id'), TP.games);
        expect(call.hasFlag('to-root'), isFalse);
        expect(call.hasFlag('name'), isFalse);

        await r.ensureExpanded(TP.games);
        expect(r.folder(TP.health), findsOneWidget);
        expect(
          r.folderLabelLeft(TP.health, 'health'),
          greaterThan(r.folderLabelLeft(TP.games, 'Games')),
        );
        expect(
          r.topics.top(r.folder(TP.health)),
          greaterThan(r.topics.top(r.folder(TP.games))),
        );
      },
    );

    testWidgets(
      'Move to root calls folder update with to-root and the folder shows at root',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        final rootLeft = r.folderLabelLeft(TP.games, 'Games');
        expect(r.folderLabelLeft(TP.design, 'Design'), greaterThan(rootLeft));

        await r.moveFolder(TP.design, null);

        final call = r.callsFor('folder update').single;
        expect(call.flag('id'), TP.design);
        expect(call.hasFlag('to-root'), isTrue);
        expect(call.hasFlag('parent-id'), isFalse);

        expect(r.folder(TP.design), findsOneWidget);
        expect(r.folderLabelLeft(TP.design, 'Design'), rootLeft);
      },
    );
  });

  group('folder pinned toggle (AC4)', () {
    testWidgets(
      'The pinned toggle on a pinned folder calls folder update pinned false and the glyph disappears',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(r.folderGlyph(TP.games), findsOneWidget);

        await r.toggleFolderPinned(TP.games);

        final call = r.callsFor('folder update').single;
        expect(call.flag('id'), TP.games);
        expect(call.flag('pinned'), 'false');
        expect(call.hasFlag('name'), isFalse);
        expect(call.hasFlag('parent-id'), isFalse);
        expect(call.hasFlag('to-root'), isFalse);
        expect(r.folderGlyph(TP.games), findsNothing);
      },
    );

    testWidgets(
      'The pinned toggle on an unpinned folder calls folder update pinned true and the glyph appears',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(r.folderGlyph(TP.health), findsNothing);

        await r.toggleFolderPinned(TP.health);

        final call = r.callsFor('folder update').single;
        expect(call.flag('id'), TP.health);
        expect(call.flag('pinned'), 'true');
        expect(r.folderGlyph(TP.health), findsOneWidget);
      },
    );
  });

  group('membership pinned toggle (AC5)', () {
    testWidgets(
      'The membership menu on a pinned topic row calls folder add pinned false and its glyph disappears',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        expect(r.memberGlyph(TP.games, TP.loop), findsOneWidget);

        await r.toggleMembershipPinned(TP.games, TP.loop);

        final call = r.callsFor('folder add').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('id'), TP.games);
        expect(call.flag('note-id'), TP.loop);
        expect(call.flag('pinned'), 'false');
        expect(r.memberGlyph(TP.games, TP.loop), findsNothing);
        expect(r.topic(TP.games, TP.loop), findsOneWidget);
      },
    );

    testWidgets(
      'The membership menu on an unpinned topic row calls folder add pinned true and its glyph appears',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        expect(r.memberGlyph(TP.games, TP.economy), findsNothing);

        await r.toggleMembershipPinned(TP.games, TP.economy);

        final call = r.callsFor('folder add').single;
        expect(call.flag('id'), TP.games);
        expect(call.flag('note-id'), TP.economy);
        expect(call.flag('pinned'), 'true');
        expect(r.memberGlyph(TP.games, TP.economy), findsOneWidget);
      },
    );
  });

  group('delete from the folder menu (AC6)', () {
    testWidgets(
      'Delete asks for confirmation then calls folder rm and subfolders move up and lone topics go to Unsorted',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        expect(r.unsortedNote(TP.economy), findsNothing);

        await r.openFolderMenu(TP.games);
        await r.tap(r.menuDelete);
        expect(r.deleteDialog, findsOneWidget);
        expect(r.writes, isEmpty, reason: 'nothing is deleted before confirm');
        await r.tap(r.deleteConfirm);

        final call = r.callsFor('folder rm').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('id'), TP.games);
        expect(r.deleteDialog, findsNothing);

        expect(r.folder(TP.games), findsNothing);
        // Design re-parents to root.
        expect(r.folder(TP.design), findsOneWidget);
        expect(
          r.folderLabelLeft(TP.design, 'Design'),
          r.folderLabelLeft(TP.health, 'health'),
        );
        // Economy had no other membership: it is Unsorted now.
        expect(r.unsortedNote(TP.economy), findsOneWidget);
        // Player Loop is still in Design, so not Unsorted.
        expect(r.unsortedNote(TP.loop), findsNothing);
        await r.ensureExpanded(TP.design);
        expect(r.topic(TP.design, TP.loop), findsOneWidget);
      },
    );

    testWidgets(
      'Cancelling the delete confirmation makes no folder rm call and keeps the folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.deleteFolder(TP.health, confirm: false);

        expect(r.deleteDialog, findsNothing);
        expect(r.writes, isEmpty);
        expect(r.folder(TP.health), findsOneWidget);
      },
    );
  });

  group('drag a topic onto a folder (AC7)', () {
    testWidgets(
      'Dragging a topic row onto a folder row calls folder add and the topic shows pinned inside that folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);

        await r.dragOntoFolder(r.topic(TP.games, TP.economy), TP.health);

        final call = r.callsFor('folder add').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('id'), TP.health);
        expect(call.flag('note-id'), TP.economy);
        expect(call.flag('pinned'), anyOf(isNull, 'true'));

        await r.ensureExpanded(TP.health);
        expect(r.topic(TP.health, TP.economy), findsOneWidget);
        expect(r.memberGlyph(TP.health, TP.economy), findsOneWidget);
      },
    );

    testWidgets(
      'Dragging an Unsorted topic onto a folder moves it out of Unsorted into the folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(r.unsortedNote(TP.orphan), findsOneWidget);

        await r.dragOntoFolder(r.unsortedNote(TP.orphan), TP.health);

        final call = r.callsFor('folder add').single;
        expect(call.flag('id'), TP.health);
        expect(call.flag('note-id'), TP.orphan);
        expect(r.unsortedNote(TP.orphan), findsNothing);
        await r.ensureExpanded(TP.health);
        expect(r.memberGlyph(TP.health, TP.orphan), findsOneWidget);
      },
    );
  });

  group('drag a role-less note onto a folder (AC8)', () {
    testWidgets(
      'Dragging a role-less Unsorted note onto a folder calls folder add and with role_set true it shows as a topic inside',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(r.unsortedNote(TP.looseNote), findsOneWidget);

        await r.dragOntoFolder(r.unsortedNote(TP.looseNote), TP.games);

        final call = r.callsFor('folder add').single;
        expect(call.flag('id'), TP.games);
        expect(call.flag('note-id'), TP.looseNote);
        expect(call.flag('pinned'), anyOf(isNull, 'true'));
        final role = r.h.db.db.select(
          "SELECT json_extract(frontmatter, '\$.role') AS role "
          'FROM notes WHERE id = ?',
          [TP.looseNote],
        );
        expect(role.first['role'], 'topic', reason: 'the server set the role');

        expect(r.unsortedNote(TP.looseNote), findsNothing);
        await r.ensureExpanded(TP.games);
        expect(r.topic(TP.games, TP.looseNote), findsOneWidget);
        r.topics.expectShows(r.topic(TP.games, TP.looseNote), 'Loose thought');
        expect(r.memberGlyph(TP.games, TP.looseNote), findsOneWidget);
      },
    );
  });

  group('failed mutations show an inline error (AC13)', () {
    testWidgets(
      'A failed create leaves the tree unchanged and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder new',
          (_) => FakeMemexCli.error(
            'name_conflict',
            'A Smart Folder named Games already exists here',
          ),
        );

        await r.createFolder('Games');

        expect(r.callsFor('folder new'), hasLength(1));
        r.expectPaneError('A Smart Folder named Games already exists here');
        expect(r.depthDialog, findsNothing);
        expect(r.topics.folderRows, findsNWidgets(2));
      },
    );

    testWidgets(
      'A failed rename keeps the old name and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder update',
          (_) => FakeMemexCli.error('name_conflict', 'Name taken: Games'),
        );

        await r.renameFolder(TP.health, 'Games');

        expect(r.callsFor('folder update'), hasLength(1));
        r.expectPaneError('Name taken: Games');
        r.topics.expectShows(r.folder(TP.health), 'health');
        expect(r.folderGlyph(TP.health), findsNothing);
      },
    );

    testWidgets(
      'A failed move leaves the folder in place and shows the folder_cycle message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        final gamesLeft = r.folderLabelLeft(TP.games, 'Games');

        // Moving Games into its own child: the server answers folder_cycle.
        await r.moveFolder(TP.games, TP.design);

        expect(r.callsFor('folder update'), hasLength(1));
        r.expectPaneError('A Smart Folder cannot move inside itself');
        expect(r.depthDialog, findsNothing);
        expect(r.folderLabelLeft(TP.games, 'Games'), gamesLeft);
        expect(r.folderLabelLeft(TP.design, 'Design'), greaterThan(gamesLeft));
      },
    );

    testWidgets(
      'A failed folder pinned toggle keeps the glyph and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder update',
          (_) => FakeMemexCli.error('not_found', 'Smart Folder not found'),
        );

        await r.toggleFolderPinned(TP.games);

        expect(r.callsFor('folder update'), hasLength(1));
        r.expectPaneError('Smart Folder not found');
        expect(r.folderGlyph(TP.games), findsOneWidget);
      },
    );

    testWidgets(
      'A failed membership pinned toggle keeps the glyph and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        r.cli.on(
          'folder add',
          (_) => FakeMemexCli.error('not_found', 'note not found: loop'),
        );

        await r.toggleMembershipPinned(TP.games, TP.loop);

        expect(r.callsFor('folder add'), hasLength(1));
        r.expectPaneError('note not found: loop');
        expect(r.memberGlyph(TP.games, TP.loop), findsOneWidget);
      },
    );

    testWidgets(
      'A failed delete keeps the folder and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder rm',
          (_) => FakeMemexCli.error('not_found', 'Smart Folder gone'),
        );

        await r.deleteFolder(TP.health, confirm: true);

        expect(r.callsFor('folder rm'), hasLength(1));
        r.expectPaneError('Smart Folder gone');
        expect(r.folder(TP.health), findsOneWidget);
        expect(r.folder(TP.games), findsOneWidget);
      },
    );

    testWidgets(
      'A failed drag leaves the note where it was and shows the CLI message inline',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder add',
          (_) => FakeMemexCli.error('not_found', 'note not found: note-loose'),
        );

        await r.dragOntoFolder(r.unsortedNote(TP.looseNote), TP.health);

        expect(r.callsFor('folder add'), hasLength(1));
        r.expectPaneError('note not found: note-loose');
        expect(r.unsortedNote(TP.looseNote), findsOneWidget);
        await r.ensureExpanded(TP.health);
        expect(r.topic(TP.health, TP.looseNote), findsNothing);
      },
    );

    testWidgets('Dismissing the inline error removes it', (tester) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      r.cli.on(
        'folder rm',
        (_) => FakeMemexCli.error('not_found', 'Smart Folder gone'),
      );
      await r.deleteFolder(TP.health, confirm: true);
      r.expectPaneError('Smart Folder gone');

      await r.dismissError();

      expect(r.anyError, findsNothing);
      expect(find.textContaining('Smart Folder gone'), findsNothing);
    });

    testWidgets('No inline error shows before any mutation fails', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());

      await r.toggleFolderPinned(TP.health);

      expect(r.callsFor('folder update'), hasLength(1));
      expect(r.anyError, findsNothing);
    });
  });

  group('Open graph from the folder menu (AC14)', () {
    testWidgets(
      'Folder menu Open graph opens and activates the Graph tab for that Smart Folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.openFolderGraph(TP.health);

        expect(r.activeTab, GraphTab(const GraphScope.folder(TP.health)));
        expect(
          r.byKey(
            'tab-graph-${const GraphScope.folder(TP.health).persistedId}',
          ),
          findsOneWidget,
        );
        expect(r.writes, isEmpty);
      },
    );

    testWidgets('Open graph on a nested folder uses that nested folder scope', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.ensureExpanded(TP.games);

      await r.openFolderGraph(TP.design);

      expect(r.activeTab, GraphTab(const GraphScope.folder(TP.design)));
    });
  });

  group('Topics header Graph action (AC15)', () {
    testWidgets(
      'The Topics header Graph action opens the Whole vault Graph tab',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        expect(
          find.descendant(of: r.topics.actions, matching: r.graphAction),
          findsOneWidget,
        );

        await r.tap(r.graphAction);

        expect(r.activeTab, GraphTab(const GraphScope.vault()));
        expect(r.byKey('tab-graph-vault:all'), findsOneWidget);
        expect(r.writes, isEmpty);
      },
    );
  });
}
