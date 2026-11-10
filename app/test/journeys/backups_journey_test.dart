// WI #326 (A5, D23, D24): the backups row in the real app (Spec #315
// requirements 24, 31a, 37; ledger L9; design pack
// design/315-vault-backups/packs/326.md, board B1).
//
// - Robot journey 1 (Testing Strategy): turn backups on with a provider,
//   press "back up now", and the new backup shows, by Keys alone. The real
//   app runs over the journey harness with A3's live controller over the A0
//   fakes (runner, state reader, folder probe) and A2's destination resolver
//   seam answering the picked folder.
// - The row's place in the sidebar (B1: under the vault pills, above the
//   hairline before canvases), and D23/D24: `Sidebar.build` watches
//   `backupControllerProvider`; workspace.dart and the tab bar stay out of it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:path/path.dart' as p;

import '../robots/backups_robot.dart';
import '../support/app_harness.dart';
import '../support/backup_fakes.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';

const _account = 'connor@example.com';
const _googleDest =
    '$fakeHome/Library/CloudStorage/GoogleDrive-$_account/My Drive/'
    'Open Memex Backups';
const _file = 'memex-20261019T070000Z-01HV0000000000000000000069.memex.zip';
const _bytes = 41200000;

/// A2's resolver seam for the journey: a picked row resolves to its own
/// path (a provider row) or the picked folder, with no file-system work.
class _Wi326Resolver extends BackupDestinationResolver {
  _Wi326Resolver(super.probe);

  @override
  Future<BackupDestinationResolution> resolve(
    BackupDestinationOption option, {
    String? pickedFolder,
  }) async {
    return BackupDestinationResolved(option.path ?? pickedFolder!);
  }
}

/// The vault pill (its 26 px frame) whose label is [name], in the sidebar.
Rect _pillRect(WidgetTester tester, String name) {
  final label = find.descendant(
    of: find.byType(Sidebar),
    matching: find.text(name),
  );
  expect(label, findsOneWidget, reason: 'the "$name" pill');
  final frames = find
      .ancestor(of: label, matching: find.byType(GestureDetector))
      .evaluate()
      .map((e) {
        final box = e.renderObject! as RenderBox;
        return box.localToGlobal(Offset.zero) & box.size;
      })
      .where((r) => (r.height - 26).abs() <= 0.5)
      .toList();
  expect(frames, isNotEmpty, reason: 'a 26 px pill frame around "$name"');
  return frames.first;
}

void main() {
  holdFontFetches();

  group('robot journey 1', () {
    testWidgets(
      'turn backups on with a provider then back up now and the new backup shows by Keys alone',
      (tester) async {
        final vault = createVaultFolder('om326_journey_');
        final probe = FakeCloudFolderProbe()..seedGoogleDrive(_account);
        final reader = FakeBackupStateReader();
        final runner = FakeBackupRunner()
          ..defaultBackupResult = const BackupCreated(
            file: '$_googleDest/$_file',
            bytes: _bytes,
            fingerprint: 'f1',
          );
        final resolver = _Wi326Resolver(probe);
        JourneyApp? started;
        // A real run records its result in backup-state.json.
        runner.onCall = (call) {
          if (call is! FakeBackupCall) return;
          final at = started!.clock.now().toUtc();
          reader.setEntry(
            call.vaultPath,
            call.destination,
            BackupStatus(
              lastAttemptAt: at,
              lastSuccessAt: at,
              lastResult: 'created',
              lastFile: _file,
              lastFileCreatedAt: at,
              lastBytes: _bytes,
              lastFingerprint: 'f1',
            ),
          );
        };
        final app = started = await pumpJourneyApp(
          tester,
          db: FakeVaultDb.v5(),
          recents: [LocalVaultRef(vault.path)],
          lastVault: LocalVaultRef(vault.path),
          overrides: [
            backupRunnerProvider.overrideWithValue(runner),
            backupStateReaderProvider.overrideWithValue(reader),
            cloudFolderProbeProvider.overrideWithValue(probe),
            resolveBackupDestinationProvider.overrideWithValue(resolver),
          ],
        );
        final r = BackupsRobot(app);
        expect(app.read(currentVaultProvider), LocalVaultRef(vault.path));

        // The sidebar row reads off; no warning.
        expect(r.entryText, contains('off'));
        expect(r.warning, findsNothing);

        // The row opens the sheet; turn backups on with Google Drive.
        await r.openSheet();
        await r.turnOnWith(r.destination(BackupProvider.googleDrive, 0));
        expect(
          app.read(vaultBackupSettingsProvider(vault.path)),
          const VaultBackupSettings(enabled: true, destination: _googleDest),
        );
        expect(runner.backupCalls, isEmpty, reason: 'turning on runs nothing');

        // Back up now: one run without --if-changed; the sheet shows it.
        await r.backUpNow();
        expect(runner.backupCalls, hasLength(1));
        final call = runner.backupCalls.single;
        expect(call.vaultPath, vault.path);
        expect(call.destination, _googleDest);
        expect(call.keep, backupKeepDefault);
        expect(call.ifChanged, isFalse);
        expect(r.statusText, contains(_file));

        // Closed, the sidebar row shows the new backup's age.
        await r.closeSheet();
        expect(r.entryText, contains('just now'));
        expect(r.entryText, isNot(contains('off')));
        expect(r.warning, findsNothing);
        expect(runner.backupCalls, hasLength(1), reason: 'nothing else ran');
      },
    );
  });

  group('the row in the sidebar', () {
    testWidgets(
      'the backups row sits under the vault pills and above the canvases hairline',
      (tester) async {
        final controller = FakeBackupController();
        final h = await pumpWorkspace(
          tester,
          overrides: [backupControllerProvider.overrideWith((_) => controller)],
        );
        final sidebar = find.byType(Sidebar);
        final entry = find.descendant(
          of: sidebar,
          matching: find.byKey(backupsEntryKey),
        );
        expect(entry, findsOneWidget, reason: 'the row is in the sidebar');
        final side = tester.getRect(sidebar);
        final row = tester.getRect(entry);
        final pill = _pillRect(tester, p.basename(h.vaultPath));

        // 12 px side margins inside the sidebar (its 1 px right border).
        expect(row.left - side.left, moreOrLessEquals(12, epsilon: 0.5));
        expect(side.right - 1 - row.right, moreOrLessEquals(12, epsilon: 0.5));
        // The pills' own 10 px bottom padding is the gap above the row.
        expect(row.top - pill.bottom, moreOrLessEquals(10, epsilon: 0.5));
        expect(row.overlaps(pill), isFalse, reason: 'never inside a pill');
        // Then 10 px, then the hairline before the canvases header.
        final hairlines = find
            .descendant(of: sidebar, matching: find.byType(OmHairline))
            .evaluate()
            .map((e) {
              final box = e.renderObject! as RenderBox;
              return box.localToGlobal(Offset.zero).dy;
            })
            .toList();
        expect(
          hairlines.any((top) => (top - (row.bottom + 10)).abs() <= 0.5),
          isTrue,
          reason:
              'a hairline 10 px under the row (row ${row.bottom}, '
              'hairlines $hairlines)',
        );
      },
    );

    testWidgets(
      'Sidebar build watches the backup controller and workspace and the tab bar stay unchanged',
      (tester) async {
        // D23: Sidebar.build keeps the app-wide controller alive.
        final sidebarSource = File(
          'lib/src/widgets/sidebar.dart',
        ).readAsStringSync();
        final start = sidebarSource.indexOf('class Sidebar extends');
        expect(start, isNot(-1));
        final build = sidebarSource.indexOf('Widget build(', start);
        final firstReturn = sidebarSource.indexOf('return ', build);
        expect(build, greaterThan(start));
        expect(firstReturn, greaterThan(build));
        expect(
          RegExp(
            r'ref\s*\.\s*watch\(\s*backupControllerProvider\s*\)',
          ).hasMatch(sidebarSource.substring(build, firstReturn)),
          isTrue,
          reason: 'Sidebar.build watches backupControllerProvider',
        );

        // D24: nothing of backups in workspace.dart or the tab state.
        for (final path in [
          'lib/src/screens/workspace.dart',
          'lib/src/state/tabs_state.dart',
        ]) {
          expect(
            File(path).readAsStringSync().toLowerCase().contains('backup'),
            isFalse,
            reason: '$path stays out of backups',
          );
        }

        // In the running app: one controller, built for the sidebar; the
        // warning shows in the sidebar row, never in the tab bar.
        var built = 0;
        final controller = FakeBackupController();
        final h = await pumpWorkspace(
          tester,
          overrides: [
            backupControllerProvider.overrideWith((_) {
              built++;
              return controller;
            }),
          ],
        );
        expect(built, 1, reason: 'the sidebar builds the controller');
        final vault = LocalVaultRef(h.vaultPath);
        final failedAt = h.clock.now().toUtc();
        controller.setViewState(
          vault,
          BackupViewState(
            mode: BackupSheetMode.error,
            settings: const VaultBackupSettings(
              enabled: true,
              destination: _googleDest,
            ),
            errorCode: 'backup_destination_unavailable',
            automatic: true,
            failedAt: failedAt,
            message: backupFailureMessage(
              code: 'backup_destination_unavailable',
              automatic: true,
              failedAt: failedAt,
              now: h.clock.now(),
              destination: _googleDest,
              provider: BackupProvider.googleDrive,
            ),
            warning: true,
          ),
        );
        await pumpFrames(tester);
        final sidebar = find.byType(Sidebar);
        expect(
          find.descendant(
            of: sidebar,
            matching: find.byKey(backupsEntryWarningKey),
          ),
          findsOneWidget,
          reason: 'the warning is the sidebar row',
        );
        final tabBar = find.byKey(const Key('workspace-tab-bar'));
        expect(tabBar, findsOneWidget);
        expect(
          find.descendant(of: tabBar, matching: find.byKey(backupsEntryKey)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: tabBar,
            matching: find.byKey(backupsEntryWarningKey),
          ),
          findsNothing,
        );
        expect(built, 1, reason: 'still the one controller');
      },
    );
  });
}
