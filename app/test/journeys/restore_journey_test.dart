// WI #327 (A6) robot journey 2 (Spec Testing Strategy, req 35): restore from
// the picker and the restored vault opens, by Keys alone. The whole app runs
// over the journey harness; the real `CliBackupRunner` runs `memex restore`
// on a FakeMemexCli whose handler does what the real command does (makes the
// vault folder at `--to`, or refuses a non-empty target with the C1
// `restore_target_not_empty`). The native pickers are the FakeFilePicker.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../robots/picker_robot.dart';
import '../support/app_harness.dart';
import '../support/backup_cli_fakes.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/file_picker_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';

const _backupName =
    'memex-20261109T140312Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';

/// What `memex restore --from <f> --to <t>` does: refuse a non-empty `--to`
/// (C1 `restore_target_not_empty`, nothing written), else make the vault
/// there and print `{"vault_id","path","created_at"}`.
MemexResult _restore(FakeCliCall call) {
  final to = call.flag('to')!;
  final target = Directory(to);
  if (target.existsSync() && target.listSync().isNotEmpty) {
    return FakeMemexCli.error(
      'restore_target_not_empty',
      'restore target is not empty: $to',
      {'path': to},
    );
  }
  initVaultFolder(to);
  return FakeMemexCli.ok(
    jsonEncode({
      'vault_id': '01JC8W5Q3M7X9R2T4V6B8N0PZK',
      'path': to,
      'created_at': 1794214800000,
    }),
  );
}

FakeMemexCli _cli() {
  final cli = FakeMemexCli()
    ..on('vault check', (_) => FakeMemexCli.ok())
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
  registerBackupCliHandlers(cli, onRestore: _restore);
  return cli;
}

/// A temp folder holding a backup file named [_backupName]; returns the
/// file's path.
String _backupFile() {
  final dir = createPlainFolder('om327_backups_');
  final file = File(p.join(dir.path, _backupName))
    ..writeAsBytesSync(List<int>.filled(2048, 7));
  return file.path;
}

void main() {
  holdFontFetches();

  testWidgets(
    'restore from the picker opens the restored vault by Keys alone',
    (tester) async {
      final backup = _backupFile();
      final parent = createPlainFolder('om327 parent ').path;
      final picker = installFakeFilePicker()
        ..files.add(backup)
        ..directories.add(parent);
      final cli = _cli();
      final app = await pumpJourneyApp(tester, cli: cli, db: FakeVaultDb.v5());
      final r = PickerRobot(app);

      await r.openRestore();
      expect(r.restoreDialog, findsOneWidget);
      expect(r.fieldText(r.restoreName), 'memex');
      await r.chooseRestoreFolder();
      final target = p.join(parent, 'memex');
      expect(r.textIn(r.restoreTarget).trim(), target);

      await r.submitRestore();

      expect(cli.callsFor('restore'), hasLength(1));
      expect(cli.callsFor('restore').single.args, [
        'restore',
        '--from',
        backup,
        '--to',
        target,
      ]);
      expect(r.restoreDialog, findsNothing);
      expect(app.read(currentVaultProvider), LocalVaultRef(target));
      expect(find.byType(Workspace), findsOneWidget);
      expect(picker.calls.map((c) => c.method), [
        'pickFiles',
        'getDirectoryPath',
      ]);
    },
  );

  testWidgets(
    'a non empty target keeps the dialog open and another name restores and opens',
    (tester) async {
      final backup = _backupFile();
      final parent = createPlainFolder('om327 parent ').path;
      // A folder named memex that holds something.
      File(p.join(parent, 'memex', 'keep.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      installFakeFilePicker()
        ..files.add(backup)
        ..directories.add(parent);
      final cli = _cli();
      final app = await pumpJourneyApp(tester, cli: cli, db: FakeVaultDb.v5());
      final r = PickerRobot(app);

      await r.openRestore();
      await r.chooseRestoreFolder();
      await r.submitRestore();

      expect(cli.callsFor('restore'), hasLength(1));
      expect(r.restoreDialog, findsOneWidget);
      expect(
        r.textIn(r.restoreError).trim(),
        "a folder named memex already exists in $parent and isn't empty. "
        'choose another name or folder.',
      );
      expect(app.read(currentVaultProvider), isNull);
      expect(
        File(p.join(parent, 'memex', 'keep.txt')).readAsStringSync(),
        'mine',
      );

      await r.enterRestoreName('memex-restored');
      await r.submitRestore();

      final target = p.join(parent, 'memex-restored');
      expect(cli.callsFor('restore'), hasLength(2));
      expect(cli.callsFor('restore').last.flag('to'), target);
      expect(r.restoreDialog, findsNothing);
      expect(app.read(currentVaultProvider), LocalVaultRef(target));
      expect(find.byType(Workspace), findsOneWidget);
    },
  );

  testWidgets('cancelling the file picker from the picker runs no restore', (
    tester,
  ) async {
    final picker = installFakeFilePicker();
    final cli = _cli();
    final app = await pumpJourneyApp(tester, cli: cli, db: FakeVaultDb.v5());
    final r = PickerRobot(app);

    await r.openRestore();

    expect(picker.calls.map((c) => c.method), ['pickFiles']);
    expect(r.restoreDialog, findsNothing);
    expect(cli.callsFor('restore'), isEmpty);
    expect(app.read(currentVaultProvider), isNull);
  });
}
