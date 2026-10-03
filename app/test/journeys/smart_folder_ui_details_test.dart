// WI #25 (A8), implementer tests: behaviour the implementation adds beyond
// the test author's ACs — the folder selection rules behind `+ New Smart
// Folder`, the dialogs' focus and indentation, and the vault settings
// surface's validation and read failure.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../robots/smart_folder_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

FakeVaultDb _fixture() => FakeVaultDb.v5()..seedTopicsFixture();

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

void main() {
  group('folder selection for + New Smart Folder', () {
    testWidgets('Tapping a folder row highlights it as the selected folder', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      expect(_fill(r.folder(TP.games)), isNot(OmColors.surface3));

      await r.selectFolder(TP.games);

      expect(_fill(r.folder(TP.games)), OmColors.surface3);
      expect(_fill(r.folder(TP.health)), isNot(OmColors.surface3));
    });

    testWidgets(
      'Tapping the selected folder again clears the selection so a new folder goes to root',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.selectFolder(TP.games);
        await r.selectFolder(TP.games);
        await r.createFolder('Reading');

        expect(_fill(r.folder(TP.games)), isNot(OmColors.surface3));
        expect(r.callsFor('folder new').single.hasFlag('parent-id'), isFalse);
      },
    );

    testWidgets(
      'After the selected folder is deleted a new folder is created at root',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.selectFolder(TP.health);
        await r.deleteFolder(TP.health, confirm: true);
        expect(r.folder(TP.health), findsNothing);
        await r.createFolder('Reading');

        expect(r.callsFor('folder new').single.hasFlag('parent-id'), isFalse);
        expect(r.anyError, findsNothing);
      },
    );
  });

  group('folder dialogs', () {
    testWidgets('The folder name field has focus when the dialog opens', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());

      await r.tap(r.newFolderButton);

      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: r.nameField,
          matching: find.byWidget(focused!.widget),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'The move picker offers root and every other folder indented by depth but not the folder itself',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.openFolderMenu(TP.health);
        await r.tap(r.menuMove);

        expect(r.moveTarget(TP.health), findsNothing);
        double left(Finder target, String label) => tester
            .getTopLeft(find.descendant(of: target, matching: find.text(label)))
            .dx;
        final root = left(r.moveTargetRoot, 'Root');
        final games = left(r.moveTarget(TP.games), 'Games');
        final design = left(r.moveTarget(TP.design), 'Design');
        expect(games, greaterThan(root));
        expect(design, greaterThan(games));
      },
    );

    testWidgets(
      'Dismissing the depth dialog without an answer counts as Cancel',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.selectFolder(TP.games);
        await r.selectFolder(TP.design);
        await r.createFolder('Bosses');
        expect(r.depthDialog, findsOneWidget);

        await tester.tapAt(const Offset(4, 4));
        await pumpFramesFor(tester);

        expect(r.depthDialog, findsNothing);
        expect(r.writes, ['folder new']);
        expect(r.anyError, findsNothing);
      },
    );
  });

  group('vault settings surface', () {
    testWidgets(
      'The depth field shows no validation message until an invalid save',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.openVaultSettings();
        final message = find.text('Enter a whole number from 1 to 5.');
        expect(message, findsNothing);

        await r.saveDepth('9');

        expect(message, findsOneWidget);
      },
    );

    testWidgets(
      'A failed settings get shows the CLI message and leaves the depth field empty',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        r.cli.on(
          'settings get',
          (_) => FakeMemexCli.error('setting_invalid', 'vault is locked'),
        );

        await r.openVaultSettings();

        expect(r.fieldText(r.depthField), '');
        expect(
          r.textsUnder(r.anyError).any((t) => t.contains('vault is locked')),
          isTrue,
        );
      },
    );
  });
}

/// Pump enough frames for a dialog's exit animation.
Future<void> pumpFramesFor(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
