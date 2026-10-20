// WI #69 (D12): the picker recent row, the sidebar vault pills and the vaults
// header "+ new" (switch vault) go through the vault open controller, and
// leaving the current vault asks `leaveVaultGuardProvider` first.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_folders.dart';

const _keptNote = '01J9KKKKKKKKKKKKKKKKKKKKKK';

/// The vaults header action ("+ new", drawn upper case).
Finder _switchVaultAction() => find.descendant(
  of: find.ancestor(
    of: find.text('VAULTS'),
    matching: find.byType(PanelHeader),
  ),
  matching: find.text('+ NEW'),
);

/// The sidebar pill for the vault folder at [path].
Finder _pill(String path) => find.descendant(
  of: find.byType(Sidebar),
  matching: find.text(p.basename(path)),
);

/// A guard that records each call and answers [allow].
class _Wi69Guard {
  _Wi69Guard({required this.allow});
  final bool allow;
  int calls = 0;
  Future<bool> call(BuildContext context) async {
    calls++;
    return allow;
  }
}

/// Pump the workspace on its temp vault with a second vault folder in the
/// recents (so it has a pill), the last vault still the open one, and a
/// selected note.
Future<(WorkspaceHarness, String)> _workspaceWithSecondVault(
  WidgetTester tester, {
  _Wi69Guard? guard,
}) async {
  final h = await pumpWorkspace(
    tester,
    overrides: [
      if (guard != null) leaveVaultGuardProvider.overrideWithValue(guard.call),
    ],
  );
  final other = createVaultFolder('om69_pill_');
  final settings = h.read(settingsProvider.notifier);
  await tester.runAsync(() async {
    await settings.rememberVault(other.path);
    await settings.rememberVault(h.vaultPath);
  });
  h.container.read(selectedNoteIdProvider.notifier).state = _keptNote;
  await pumpFrames(tester);
  expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
  expect(h.read(settingsProvider).lastVault, h.vaultPath);
  expect(_pill(other.path), findsOneWidget);
  return (h, other.path);
}

void main() {
  group('picker recent row (AC5)', () {
    testWidgets('tapping a recent row opens that vault as a LocalVaultRef', (
      tester,
    ) async {
      final vault = createVaultFolder('om69_recent_');
      SharedPreferences.setMockInitialValues({
        'memex.binary_path': 'fake-memex',
        'memex.recent_vaults': <String>[vault.path],
      });
      final settings = await SettingsController.load();
      final db = FakeVaultDb.v5();
      final cli = FakeMemexCli()
        ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
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

      await tester.tap(find.text(p.basename(vault.path)));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pumpFrames(tester);

      expect(container.read(currentVaultProvider), LocalVaultRef(vault.path));
      expect(container.read(settingsProvider).lastVault, vault.path);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('sidebar vault pill (AC5)', () {
    testWidgets(
      'tapping a sidebar vault pill opens that vault as a LocalVaultRef and clears the selected note',
      (tester) async {
        final (h, other) = await _workspaceWithSecondVault(tester);

        await tester.tap(_pill(other));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(h.read(currentVaultProvider), LocalVaultRef(other));
        expect(h.read(settingsProvider).lastVault, other);
        expect(h.read(settingsProvider).recentVaults.first, other);
        expect(h.read(selectedNoteIdProvider), isNot(_keptNote));
        expect(find.byType(Workspace), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('leaveVaultGuardProvider (AC6)', () {
    testWidgets('leaveVaultGuardProvider allows leaving by default', (
      tester,
    ) async {
      final h = await pumpWorkspace(tester);
      final context = tester.element(find.byType(Workspace));
      final guard = h.read(leaveVaultGuardProvider);
      late bool allowed;
      await tester.runAsync(() async => allowed = await guard(context));
      expect(allowed, isTrue);
    });

    testWidgets(
      'with the default guard switch vault clears the last vault, the current vault and the selected note',
      (tester) async {
        final (h, _) = await _workspaceWithSecondVault(tester);

        await tester.tap(_switchVaultAction());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(settingsProvider).lastVault, isNull);
        expect(h.read(selectedNoteIdProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
      },
    );

    testWidgets(
      'an allowing guard is asked once and switch vault goes ahead as today',
      (tester) async {
        final guard = _Wi69Guard(allow: true);
        final (h, _) = await _workspaceWithSecondVault(tester, guard: guard);

        await tester.tap(_switchVaultAction());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(guard.calls, 1);
        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(settingsProvider).lastVault, isNull);
        expect(h.read(selectedNoteIdProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
      },
    );

    testWidgets(
      'a denying guard keeps the current vault, last vault and selected note on switch vault',
      (tester) async {
        final guard = _Wi69Guard(allow: false);
        final (h, _) = await _workspaceWithSecondVault(tester, guard: guard);

        await tester.tap(_switchVaultAction());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(guard.calls, 1);
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
        expect(h.read(settingsProvider).lastVault, h.vaultPath);
        expect(h.read(selectedNoteIdProvider), _keptNote);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsNothing);
      },
    );

    testWidgets(
      'an allowing guard is asked once and a pill tap opens that vault as today',
      (tester) async {
        final guard = _Wi69Guard(allow: true);
        final (h, other) = await _workspaceWithSecondVault(
          tester,
          guard: guard,
        );

        await tester.tap(_pill(other));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(guard.calls, 1);
        expect(h.read(currentVaultProvider), LocalVaultRef(other));
        expect(h.read(settingsProvider).lastVault, other);
        expect(h.read(selectedNoteIdProvider), isNot(_keptNote));
      },
    );

    testWidgets(
      'a denying guard keeps the current vault, last vault and selected note on a pill tap',
      (tester) async {
        final guard = _Wi69Guard(allow: false);
        final (h, other) = await _workspaceWithSecondVault(
          tester,
          guard: guard,
        );

        await tester.tap(_pill(other));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);

        expect(guard.calls, 1);
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
        expect(h.read(settingsProvider).lastVault, h.vaultPath);
        expect(h.read(settingsProvider).recentVaults.first, h.vaultPath);
        expect(h.read(selectedNoteIdProvider), _keptNote);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });
}
