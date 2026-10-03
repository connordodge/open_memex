// WI #25 (A8): the depth dialog (Req 37, TD11; Spec TS4 robot journey
// "depth-exceeded dialog raises the setting and retries"). FolderCliFake plays
// the server: it enforces `smart_folder_max_depth` from `vault_settings`
// (default 2) and answers C1 `depth_exceeded` with `max_depth` and
// `required_depth`.
import 'package:flutter_test/flutter_test.dart';

import '../robots/smart_folder_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

/// Games (depth 1) > Design (depth 2); health (depth 1); max depth 2.
FakeVaultDb _fixture() => FakeVaultDb.v5()..seedTopicsFixture();

String _question(int x) =>
    'Would you like to update your max Smart Folder depth setting to $x?';

/// Select Design (expanding Games first) and ask for a new folder there:
/// depth 3 > max 2.
Future<void> _createUnderDesign(SmartFolderRobot r, String name) async {
  await r.selectFolder(TP.games);
  await r.selectFolder(TP.design);
  await r.createFolder(name);
}

/// Move health (a leaf at root) under Design: required depth 2 + 1 = 3.
Future<void> _moveHealthUnderDesign(SmartFolderRobot r) async {
  await r.ensureExpanded(TP.games);
  await r.moveFolder(TP.health, TP.design);
}

void main() {
  group('the depth dialog question (AC9)', () {
    testWidgets(
      'A create past the depth limit shows the depth dialog asking to raise the setting to 3',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await _createUnderDesign(r, 'Bosses');

        expect(r.callsFor('folder new'), hasLength(1));
        expect(r.depthDialog, findsOneWidget);
        expect(
          find.descendant(of: r.depthDialog, matching: find.text(_question(3))),
          findsOneWidget,
        );
        expect(r.depthConfirm, findsOneWidget);
        expect(r.depthCancel, findsOneWidget);
        expect(r.anyError, findsNothing);
        expect(r.callsFor('settings set'), isEmpty);
      },
    );

    testWidgets(
      'A move past the depth limit shows the depth dialog asking to raise the setting to 3',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await _moveHealthUnderDesign(r);

        expect(r.callsFor('folder update'), hasLength(1));
        expect(r.depthDialog, findsOneWidget);
        expect(
          find.descendant(of: r.depthDialog, matching: find.text(_question(3))),
          findsOneWidget,
        );
        expect(r.callsFor('settings set'), isEmpty);
      },
    );

    testWidgets(
      'The dialog shows the server required_depth verbatim, not max_depth plus one',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'folder new',
          (_) => FakeMemexCli.error(
            'depth_exceeded',
            'Smart Folder depth 4 exceeds the vault maximum of 2',
            {'max_depth': 2, 'required_depth': 4},
          ),
        );

        await r.createFolder('Anything');

        expect(
          find.descendant(of: r.depthDialog, matching: find.text(_question(4))),
          findsOneWidget,
        );
        expect(find.text(_question(3)), findsNothing);
      },
    );
  });

  group('confirm raises the setting and retries (AC10)', () {
    testWidgets(
      'Confirm sets smart_folder_max_depth to 3 then retries the same folder new and the folder appears at depth 3',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await _createUnderDesign(r, 'Bosses');
        expect(r.depthDialog, findsOneWidget);

        await r.tap(r.depthConfirm);

        expect(r.depthDialog, findsNothing);
        expect(r.writes, ['folder new', 'settings set', 'folder new']);
        final set = r.callsFor('settings set').single;
        expect(set.flag('vault'), r.h.vaultPath);
        expect(set.flag('key'), 'smart_folder_max_depth');
        expect(set.flag('value'), '3');
        final news = r.callsFor('folder new');
        expect(news[1].args, news[0].args, reason: 'same arguments on retry');
        expect(news[1].flag('parent-id'), TP.design);
        expect(news[1].flag('name'), 'Bosses');

        await r.ensureExpanded(TP.design);
        r.topics.expectShows(r.folder('f-new-1'), 'Bosses');
        expect(r.folderGlyph('f-new-1'), findsOneWidget);
        expect(
          r.folderLabelLeft('f-new-1', 'Bosses'),
          greaterThan(r.folderLabelLeft(TP.design, 'Design')),
        );
        expect(r.anyError, findsNothing);
      },
    );

    testWidgets(
      'Confirm on a move sets the depth to 3 then retries the same folder update and the folder shows under its new parent',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await _moveHealthUnderDesign(r);

        await r.tap(r.depthConfirm);

        expect(r.writes, ['folder update', 'settings set', 'folder update']);
        expect(r.callsFor('settings set').single.flag('value'), '3');
        final updates = r.callsFor('folder update');
        expect(updates[1].args, updates[0].args);
        expect(updates[1].flag('id'), TP.health);
        expect(updates[1].flag('parent-id'), TP.design);

        await r.ensureExpanded(TP.design);
        expect(r.folder(TP.health), findsOneWidget);
        expect(
          r.folderLabelLeft(TP.health, 'health'),
          greaterThan(r.folderLabelLeft(TP.design, 'Design')),
        );
      },
    );

    testWidgets(
      'Confirm sends the required_depth from the error as the new setting value',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        var first = true;
        r.cli.on('folder new', (call) {
          if (first) {
            first = false;
            return FakeMemexCli.error(
              'depth_exceeded',
              'Smart Folder depth 4 exceeds the vault maximum of 2',
              {'max_depth': 2, 'required_depth': 4},
            );
          }
          return FakeMemexCli.ok(
            '{"vault_id":"01HV0000000000000000000000","id":"f-x","name":"Anything","parent_id":null,"pinned":true,"depth":1,"created_at":1759600000000,"updated_at":1759600000000}\n',
          );
        });

        await r.createFolder('Anything');
        await r.tap(r.depthConfirm);

        expect(r.callsFor('settings set').single.flag('value'), '4');
        expect(r.callsFor('folder new'), hasLength(2));
      },
    );
  });

  group('cancel changes nothing (AC11)', () {
    testWidgets(
      'Cancel closes the depth dialog with no settings set and no retry and the tree is unchanged',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await _createUnderDesign(r, 'Bosses');
        expect(r.depthDialog, findsOneWidget);

        await r.tap(r.depthCancel);

        expect(r.depthDialog, findsNothing);
        expect(r.writes, ['folder new']);
        expect(r.callsFor('settings set'), isEmpty);
        expect(r.folder('f-new-1'), findsNothing);
        expect(r.anyError, findsNothing);
        expect(r.server.maxDepth, 2);
      },
    );

    testWidgets(
      'Cancel on a move leaves the folder at root with no settings set call',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        final rootLeft = r.folderLabelLeft(TP.health, 'health');
        await _moveHealthUnderDesign(r);

        await r.tap(r.depthCancel);

        expect(r.writes, ['folder update']);
        expect(r.folderLabelLeft(TP.health, 'health'), rootLeft);
      },
    );
  });

  group('a failed depth retry shows an inline error (AC13)', () {
    testWidgets(
      'A failed settings set after confirm shows the CLI message inline with no retry and an unchanged tree',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'settings set',
          (_) => FakeMemexCli.error(
            'setting_invalid',
            'smart_folder_max_depth could not be written',
          ),
        );
        await _createUnderDesign(r, 'Bosses');

        await r.tap(r.depthConfirm);

        expect(r.writes, ['folder new', 'settings set']);
        expect(r.depthDialog, findsNothing);
        r.expectPaneError('smart_folder_max_depth could not be written');
        await r.ensureExpanded(TP.design);
        expect(r.folder('f-new-1'), findsNothing);
      },
    );

    testWidgets(
      'A retry that fails after the setting was raised shows the CLI message inline and the tree is unchanged',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        var first = true;
        r.cli.on('folder new', (_) {
          if (first) {
            first = false;
            return FakeMemexCli.error(
              'depth_exceeded',
              'Smart Folder depth 3 exceeds the vault maximum of 2',
              {'max_depth': 2, 'required_depth': 3},
            );
          }
          return FakeMemexCli.error(
            'name_conflict',
            'A Smart Folder named Bosses already exists here',
          );
        });
        await _createUnderDesign(r, 'Bosses');

        await r.tap(r.depthConfirm);

        expect(r.writes, ['folder new', 'settings set', 'folder new']);
        r.expectPaneError('A Smart Folder named Bosses already exists here');
        await r.ensureExpanded(TP.design);
        expect(r.topics.folderRows, findsNWidgets(3));
      },
    );
  });
}
