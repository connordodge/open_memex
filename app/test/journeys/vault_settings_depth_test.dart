// WI #25 (A8): the per-vault settings surface with `Smart Folder depth`
// (Req 36, TD13). Opened from the Topics header (`topics-vault-settings`);
// reads through `memex settings get` and writes through `memex settings set`
// (C2.11). FolderCliFake plays the server over `vault_settings`.
import 'package:flutter_test/flutter_test.dart';

import '../robots/smart_folder_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

FakeVaultDb _fixture({int? maxDepth}) {
  final db = FakeVaultDb.v5()..seedTopicsFixture();
  if (maxDepth != null) {
    db.db.execute(
      "UPDATE vault_settings SET value = ? WHERE key = 'smart_folder_max_depth'",
      ['$maxDepth'],
    );
  }
  return db;
}

void main() {
  group('the Smart Folder depth setting (AC12)', () {
    testWidgets(
      'The vault settings surface shows Smart Folder depth with the default value 2 from settings get',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());

        await r.openVaultSettings();

        expect(r.settingsDialog, findsOneWidget);
        expect(
          find.descendant(
            of: r.settingsDialog,
            matching: find.textContaining('Smart Folder depth'),
          ),
          findsWidgets,
        );
        expect(r.fieldText(r.depthField), '2');
        expect(r.callsFor('settings get'), isNotEmpty);
        expect(
          r.callsFor('settings get').last.flag('key'),
          'smart_folder_max_depth',
        );
      },
    );

    testWidgets('The depth field shows the stored value, not a constant', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture(maxDepth: 4));

      await r.openVaultSettings();

      expect(r.fieldText(r.depthField), '4');
    });

    testWidgets('Changing the depth to 3 calls settings set with 3', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.openVaultSettings();

      await r.saveDepth('3');

      final set = r.callsFor('settings set').single;
      expect(set.flag('vault'), r.h.vaultPath);
      expect(set.flag('key'), 'smart_folder_max_depth');
      expect(set.flag('value'), '3');
      expect(r.settingsDialog, findsNothing, reason: 'save closes the dialog');
      expect(r.server.maxDepth, 3);
    });

    testWidgets('Depth 1 is accepted and sent to settings set', (tester) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.openVaultSettings();

      await r.saveDepth('1');

      expect(r.callsFor('settings set').single.flag('value'), '1');
    });

    testWidgets('Depth 5 is accepted and sent to settings set', (tester) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.openVaultSettings();

      await r.saveDepth('5');

      expect(r.callsFor('settings set').single.flag('value'), '5');
    });

    testWidgets(
      'Depth values outside 1 to 5 or not an integer make no settings set call',
      (tester) async {
        final r = SmartFolderRobot(tester);
        await r.launch(db: _fixture());
        await r.openVaultSettings();

        for (final bad in ['0', '6', 'abc', '']) {
          await r.saveDepth(bad);
          expect(r.callsFor('settings set'), isEmpty, reason: bad);
          expect(r.settingsDialog, findsOneWidget, reason: bad);
        }
      },
    );

    testWidgets('Reopening the settings after a save shows the new value', (
      tester,
    ) async {
      final r = SmartFolderRobot(tester);
      await r.launch(db: _fixture());
      await r.openVaultSettings();
      await r.saveDepth('4');

      await r.openVaultSettings();

      expect(r.fieldText(r.depthField), '4');
    });
  });

  group('a failed settings set shows an inline error (AC13)', () {
    testWidgets(
      'A failed settings set shows the CLI message in a dismissible inline error',
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
        await r.openVaultSettings();

        await r.saveDepth('3');

        expect(r.callsFor('settings set'), hasLength(1));
        expect(r.anyError, findsOneWidget);
        expect(
          r
              .textsUnder(r.anyError)
              .any(
                (t) =>
                    t.contains('smart_folder_max_depth could not be written'),
              ),
          isTrue,
        );
        expect(r.server.maxDepth, 2);

        await r.dismissError();

        expect(r.anyError, findsNothing);
      },
    );
  });
}
