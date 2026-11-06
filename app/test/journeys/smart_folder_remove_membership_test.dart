// WI #262 (F10): `Remove from <Smart Folder>` in the membership menu of a
// topic row (secondary click), beside `Pin in folder`. It calls `memex folder
// remove` once, for pinned and unpinned memberships. Unsorted rows have no
// such menu, a drop on a folder still adds and pins, and a failed removal
// shows the dismissible Topics error.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/smart_folder_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

/// Games (pinned) > Design; health. Player Loop is pinned in Games and
/// unpinned in Design; Economy is unpinned in Games.
FakeVaultDb _fixture() => FakeVaultDb.v5()..seedTopicsFixture();

Finder _remove(String folderId, String noteId) =>
    find.byKey(Key('membership-menu-remove-$folderId-$noteId'));

Finder _removeLabelled(String folderName) =>
    find.text('Remove from $folderName');

int _membershipRows(FakeVaultDb db, String folderId, String noteId) =>
    (db.db.select(
              'SELECT COUNT(*) AS n FROM smart_folder_members '
              'WHERE smart_folder_id = ? AND note_id = ?',
              [folderId, noteId],
            ).first['n']
            as num)
        .toInt();

void main() {
  group('Remove from Smart Folder (AC8)', () {
    testWidgets(
      'the membership menu of an unpinned topic row offers Remove from the folder name beside Unpin or Pin in folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);

        await r.openMembershipMenu(TP.games, TP.economy);

        expect(_remove(TP.games, TP.economy), findsOneWidget);
        expect(_removeLabelled('Games'), findsOneWidget);
        expect(r.membershipPinned(TP.games, TP.economy), findsOneWidget);
        expect(find.text('Pin in folder'), findsOneWidget);
        expect(
          tester.getTopLeft(_remove(TP.games, TP.economy)).dy,
          greaterThan(
            tester.getTopLeft(r.membershipPinned(TP.games, TP.economy)).dy,
          ),
          reason: 'the Remove item comes after the pin item',
        );
      },
    );

    testWidgets(
      'choosing Remove on an unpinned membership calls folder remove once and the row leaves the folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.games);

        await r.openMembershipMenu(TP.games, TP.economy);
        await r.tap(_remove(TP.games, TP.economy));

        final call = r.callsFor('folder remove').single;
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('id'), TP.games);
        expect(call.flag('note-id'), TP.economy);
        expect(r.writes, ['folder remove'], reason: 'one write, nothing else');
        expect(_membershipRows(db, TP.games, TP.economy), 0);
        expect(r.topic(TP.games, TP.economy), findsNothing);
        expect(
          r.unsortedNote(TP.economy),
          findsOneWidget,
          reason: 'its last folder is gone, so it is Unsorted now',
        );
        expect(r.paneError, findsNothing);
      },
    );

    testWidgets(
      'choosing Remove on a pinned membership calls folder remove once and the pinned row leaves the folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.games);
        expect(r.memberGlyph(TP.games, TP.loop), findsOneWidget);

        await r.openMembershipMenu(TP.games, TP.loop);
        expect(_remove(TP.games, TP.loop), findsOneWidget);
        expect(find.text('Unpin in folder'), findsOneWidget);
        await r.tap(_remove(TP.games, TP.loop));

        final call = r.callsFor('folder remove').single;
        expect(call.flag('id'), TP.games);
        expect(call.flag('note-id'), TP.loop);
        expect(_membershipRows(db, TP.games, TP.loop), 0);
        expect(r.topic(TP.games, TP.loop), findsNothing);
        expect(r.memberGlyph(TP.games, TP.loop), findsNothing);
      },
    );

    testWidgets(
      'removing a note from one folder keeps its membership in the other folder',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.games);
        await r.ensureExpanded(TP.design);

        await r.openMembershipMenu(TP.games, TP.loop);
        await r.tap(_remove(TP.games, TP.loop));

        expect(_membershipRows(db, TP.design, TP.loop), 1);
        expect(r.topic(TP.design, TP.loop), findsOneWidget);
        expect(
          r.unsortedNote(TP.loop),
          findsNothing,
          reason: 'it is still in Design',
        );
      },
    );

    testWidgets('the Remove item names the folder of the row it belongs to', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.ensureExpanded(TP.games);
      await r.ensureExpanded(TP.design);
      await r.ensureExpanded(TP.health);

      await r.openMembershipMenu(TP.design, TP.level);
      expect(_removeLabelled('Design'), findsOneWidget);
      expect(_removeLabelled('Games'), findsNothing);
      await tester.tapAt(const Offset(2, 2));
      await pumpFrames(tester);

      await r.openMembershipMenu(TP.health, TP.sleep);
      expect(_removeLabelled('health'), findsOneWidget);
      expect(_remove(TP.health, TP.sleep), findsOneWidget);
    });

    testWidgets(
      'removing from the nested folder calls folder remove with that folder id',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        await r.ensureExpanded(TP.design);

        await r.openMembershipMenu(TP.design, TP.level);
        await r.tap(_remove(TP.design, TP.level));

        final call = r.callsFor('folder remove').single;
        expect(call.flag('id'), TP.design);
        expect(call.flag('note-id'), TP.level);
        expect(r.topic(TP.design, TP.level), findsNothing);
      },
    );

    testWidgets('opening the membership menu alone removes nothing', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      final db = _fixture();
      await r.launch(db: db);
      await r.ensureExpanded(TP.games);

      await r.openMembershipMenu(TP.games, TP.economy);

      expect(_remove(TP.games, TP.economy), findsOneWidget);
      expect(r.writes, isEmpty);
      expect(_membershipRows(db, TP.games, TP.economy), 1);
    });

    testWidgets(
      'removal bumps the vault revision once so the Topics tree re-reads',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.ensureExpanded(TP.games);
        var bumps = 0;
        final sub = r.h.container.listen<int>(
          vaultRevisionProvider,
          (_, _) => bumps++,
        );
        addTearDown(sub.close);

        await r.openMembershipMenu(TP.games, TP.economy);
        await r.tap(_remove(TP.games, TP.economy));

        expect(bumps, 1);
      },
    );
  });

  group('rows without a membership menu (AC9)', () {
    testWidgets('an Unsorted row has no Remove from item', (tester) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.ensureExpanded(TP.games);
      await r.openMembershipMenu(TP.games, TP.economy);
      expect(_remove(TP.games, TP.economy), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await pumpFrames(tester);
      expect(r.unsortedNote(TP.orphan), findsOneWidget);

      await tester.tap(r.unsortedNote(TP.orphan), buttons: kSecondaryButton);
      await pumpFrames(tester);

      expect(find.textContaining('Remove from'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'membership-menu-remove-',
              ),
        ),
        findsNothing,
      );
      expect(r.writes, isEmpty);
    });

    testWidgets(
      'dropping an Unsorted row on a folder still adds and pins it and removes nothing',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.health);

        await r.dragOntoFolder(r.unsortedNote(TP.orphan), TP.health);

        expect(r.writes, ['folder add']);
        final call = r.callsFor('folder add').single;
        expect(call.flag('id'), TP.health);
        expect(call.flag('note-id'), TP.orphan);
        expect(r.callsFor('folder remove'), isEmpty);
        expect(_membershipRows(db, TP.health, TP.orphan), 1);
        expect(r.memberGlyph(TP.health, TP.orphan), findsOneWidget);
        // The dropped note now has a membership menu with Remove.
        await r.openMembershipMenu(TP.health, TP.orphan);
        expect(_remove(TP.health, TP.orphan), findsOneWidget);
        expect(_removeLabelled('health'), findsOneWidget);
      },
    );

    testWidgets(
      'dropping a topic row from one folder on another keeps the first membership',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.games);

        await r.dragOntoFolder(r.topic(TP.games, TP.economy), TP.health);

        expect(r.callsFor('folder remove'), isEmpty);
        expect(_membershipRows(db, TP.games, TP.economy), 1);
        expect(_membershipRows(db, TP.health, TP.economy), 1);

        // Removing the dropped copy leaves the original membership.
        await r.ensureExpanded(TP.health);
        await r.openMembershipMenu(TP.health, TP.economy);
        await r.tap(_remove(TP.health, TP.economy));
        expect(r.callsFor('folder remove').single.flag('id'), TP.health);
        expect(_membershipRows(db, TP.health, TP.economy), 0);
        expect(_membershipRows(db, TP.games, TP.economy), 1);
      },
    );
  });

  group('a failed removal (AC10)', () {
    testWidgets(
      'a failed Remove keeps the row and shows the CLI message in the dismissible Topics error',
      (tester) async {
        final r = SmartFolderRobot(tester);
        final db = _fixture();
        await r.launch(db: db);
        await r.ensureExpanded(TP.games);
        r.cli.on(
          'folder remove',
          (_) => FakeMemexCli.error('not_found', 'Smart Folder gone: Games'),
        );

        await r.openMembershipMenu(TP.games, TP.economy);
        await r.tap(_remove(TP.games, TP.economy));

        expect(r.callsFor('folder remove'), hasLength(1));
        r.expectPaneError('Smart Folder gone: Games');
        expect(r.topic(TP.games, TP.economy), findsOneWidget);
        expect(_membershipRows(db, TP.games, TP.economy), 1);

        await r.dismissError();
        expect(r.paneError, findsNothing);
      },
    );

    testWidgets('a later successful Remove clears the earlier Topics error', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.ensureExpanded(TP.games);
      r.cli.on(
        'folder remove',
        (_) => FakeMemexCli.error('internal', 'disk full'),
      );

      await r.openMembershipMenu(TP.games, TP.economy);
      await r.tap(_remove(TP.games, TP.economy));
      r.expectPaneError('disk full');
      r.server.install(r.cli);

      await r.openMembershipMenu(TP.games, TP.economy);
      await r.tap(_remove(TP.games, TP.economy));

      expect(r.paneError, findsNothing);
      expect(r.topic(TP.games, TP.economy), findsNothing);
    });
  });
}
