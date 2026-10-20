// WI #69 review round 1 (finding 4): the picker shows the vault open
// controller's failure copy for "open existing vault…" and "create new
// vault…", as main did, and a recent row opens as it did on main.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_folders.dart';

/// A directory chooser that answers every `getDirectoryPath` with [answer].
class _Wi69FakePicker extends FilePicker {
  _Wi69FakePicker(this.answer);

  String? answer;
  int directoryCalls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    directoryCalls++;
    return answer;
  }
}

/// The picker app with no vault open: settings with [recents], a fake CLI
/// (so "create new vault…" is enabled) and a fake directory chooser.
Future<ProviderContainer> _pumpPicker(
  WidgetTester tester, {
  required FakeMemexCli cli,
  List<String> recents = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': recents,
  });
  final settings = (await tester.runAsync(SettingsController.load))!;
  final db = FakeVaultDb.v5();
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OpenMemexApp(),
    ),
  );
  await pumpFrames(tester);
  expect(find.byType(VaultPickerScreen), findsOneWidget);
  expect(container.read(currentVaultProvider), isNull);
  return container;
}

/// Let the controller's async work (prefs, fake CLI) finish, then draw.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpFrames(tester);
}

/// "create new vault…": choose [parent] as the parent folder, name the
/// vault [name] and press create.
Future<void> _createVault(
  WidgetTester tester,
  _Wi69FakePicker picker, {
  required String parent,
  required String name,
}) async {
  await tester.tap(find.byKey(const Key('vault-picker-create')));
  await pumpFrames(tester);
  expect(find.text('CREATE NEW VAULT'), findsOneWidget);
  picker.answer = parent;
  await tester.tap(find.text('choose…'));
  await _settle(tester);
  await tester.enterText(find.byType(TextField), name);
  await pumpFrames(tester);
  await tester.tap(find.text('create'));
  await _settle(tester);
}

void main() {
  late _Wi69FakePicker picker;

  setUp(() {
    picker = _Wi69FakePicker(null);
    FilePicker.platform = picker;
  });

  group('open existing vault (review finding 4)', () {
    testWidgets(
      'open existing vault on a folder that is not a vault shows why and opens nothing',
      (tester) async {
        final plain = createPlainFolder('om69_pick_plain_');
        final cli = FakeMemexCli();
        final c = await _pumpPicker(tester, cli: cli);
        picker.answer = plain.path;

        await tester.tap(find.byKey(const Key('vault-picker-open')));
        await _settle(tester);

        expect(picker.directoryCalls, 1);
        expect(
          find.text(
            '${plain.path} does not look like a vault (no manifest.json + memex.db).',
          ),
          findsOneWidget,
        );
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, isEmpty);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'open existing vault on a vault folder opens it with no error shown',
      (tester) async {
        final vault = createVaultFolder('om69_pick_vault_');
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _pumpPicker(tester, cli: cli);
        picker.answer = vault.path;

        await tester.tap(find.byKey(const Key('vault-picker-open')));
        await _settle(tester);

        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('cancelling the open existing vault chooser changes nothing', (
      tester,
    ) async {
      final c = await _pumpPicker(tester, cli: FakeMemexCli());
      picker.answer = null;

      await tester.tap(find.byKey(const Key('vault-picker-open')));
      await _settle(tester);

      expect(picker.directoryCalls, 1);
      expect(c.read(currentVaultProvider), isNull);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('create new vault (review finding 4)', () {
    testWidgets(
      'create new vault over a non-empty folder shows already exists and is not empty',
      (tester) async {
        final parent = createPlainFolder('om69_pick_parent_');
        final full = Directory(p.join(parent.path, 'Full'))..createSync();
        File(p.join(full.path, 'notes.txt')).writeAsStringSync('hi');
        final cli = FakeMemexCli();
        final c = await _pumpPicker(tester, cli: cli);

        await _createVault(tester, picker, parent: parent.path, name: 'Full');

        expect(
          find.text('${full.path} already exists and is not empty.'),
          findsOneWidget,
        );
        expect(cli.callsFor('init'), isEmpty);
        expect(c.read(currentVaultProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'create new vault shows Could not create vault with the init error',
      (tester) async {
        final parent = createPlainFolder('om69_pick_parent_');
        final failure = FakeMemexCli.error('io', 'permission denied');
        final cli = FakeMemexCli()..on('init', (_) => failure);
        final c = await _pumpPicker(tester, cli: cli);

        await _createVault(tester, picker, parent: parent.path, name: 'Broken');

        expect(cli.callsFor('init'), hasLength(1));
        expect(
          find.text(
            'Could not create vault: '
            '${MemexException.fromCliFailure('init', failure)}',
          ),
          findsOneWidget,
        );
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, isEmpty);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('create new vault opens the new vault with no error shown', (
      tester,
    ) async {
      final parent = createPlainFolder('om69_pick_parent_');
      final cli = FakeMemexCli()
        ..on('init', (call) {
          initVaultFolder(call.args[1]);
          return FakeMemexCli.ok();
        })
        ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
      final c = await _pumpPicker(tester, cli: cli);

      await _createVault(tester, picker, parent: parent.path, name: 'Fresh');

      final path = p.join(parent.path, 'Fresh');
      expect(cli.callsFor('init').single.args, ['init', path]);
      expect(c.read(currentVaultProvider), LocalVaultRef(path));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('picker recent row as on main (lead ruling)', () {
    testWidgets(
      'tapping a recent row of a folder that is not a vault does nothing as today',
      (tester) async {
        // On main the row of a folder that is not a vault is drawn with the
        // folderX icon and has no tap handler.
        final plain = createPlainFolder('om69_recent_plain_');
        final c = await _pumpPicker(
          tester,
          cli: FakeMemexCli(),
          recents: [plain.path],
        );

        await tester.tap(find.text(p.basename(plain.path)));
        await _settle(tester);

        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).lastVault, isNull);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a recent row of a folder that is not a vault still opens it as today',
      (tester) async {
        // The row was drawn while the folder was a vault; by the tap it no
        // longer is (memex.db gone, no rebuild in between). On main the tap
        // opened it with no check: rememberVault, then the current vault.
        // #92 adds the check (`memex vault check`); until then a recent row
        // must not check the folder (lead ruling, behaviour-preserving WI).
        final vault = createVaultFolder('om69_recent_stale_');
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _pumpPicker(tester, cli: cli, recents: [vault.path]);
        File(p.join(vault.path, 'memex.db')).deleteSync();

        await tester.tap(find.text(p.basename(vault.path)));
        await _settle(tester);

        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(c.read(settingsProvider).lastVault, vault.path);
        expect(c.read(settingsProvider).recentVaults, [vault.path]);
      },
    );
  });
}
