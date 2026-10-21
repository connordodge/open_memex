// WI #92 (D19, L20, req 31): local opens from the picker, the sidebar vault
// pills and launch run `memex vault check` first; the network-drive refusal
// (board A9 state 1), the too-old-memex refusal (derived from A9 state 1,
// design pack 92) and the launch "opening" recent row (A3 state 3).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/memex_too_old_dialog.dart';
import 'package:open_memex_app/src/widgets/network_drive_refusal_dialog.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/vault_open_refusal.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/file_picker_fakes.dart';
import '../support/vault_folders.dart';

// Spec copy, verbatim (req 31, L20).
const _networkCopy =
    'this folder is on a network drive. vaults on network drives can be '
    'corrupted — connect to a vault server instead.';
const _tooOldCopy =
    'this memex is too old to open vaults safely. update memex, then try again.';
const _setUpLabel = 'set up a vault server…';
const _connectLabel = 'connect to a vault server…';
const _locateLabel = 'locate memex binary…';

// Stable keys (reused by #105).
const _refusal = Key('network-drive-refusal');
const _refusalSetup = Key('network-drive-refusal-setup');
const _refusalConnect = Key('network-drive-refusal-connect');
const _refusalCancel = Key('network-drive-refusal-cancel');
const _tooOld = Key('memex-too-old-refusal');
const _tooOldLocate = Key('memex-too-old-locate');
const _tooOldCancel = Key('memex-too-old-cancel');
const _openingRow = Key('recent-row-opening');

/// clap's answer from a memex without `vault check` (exit 2).
const _clapUsageError =
    "error: unrecognized subcommand 'vault'\n\nUsage: memex <COMMAND>\n";

MemexResult _networkDrive() => FakeMemexCli.error(
  'network_filesystem',
  'the vault folder is on a network filesystem',
);

MemexResult _tooOldMemex() =>
    FakeMemexCli.failure(_clapUsageError, exitCode: 2);

Never _spawnFailure(FakeCliCall _) => throw const ProcessException(
  'fake-memex',
  ['vault', 'check'],
  'No such file or directory',
  2,
);

/// A fake CLI whose `vault check` answers [check] and whose `settings get`
/// answers the C2.11 sample.
FakeMemexCli _cli(FakeCliHandler check, {String binaryPath = 'fake-memex'}) =>
    FakeMemexCli(binaryPath: binaryPath)
      ..on('vault check', check)
      ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
      ..on('init', (call) {
        initVaultFolder(call.args[1]);
        return FakeMemexCli.ok();
      });

List<String> _subcommands(FakeMemexCli cli) =>
    cli.calls.map((c) => c.subcommand).toList();

/// Pump the whole app as `main()` builds it: settings from SharedPreferences
/// ([recents], [lastVault], [binaryPath]), no `currentVaultProvider`
/// override, a [FakeVaultDb] behind `vaultDbProvider`, and [cli] behind
/// `memexCliProvider`. With [clis], `memexCliProvider` re-reads the binary
/// path and answers the fake for it.
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  FakeMemexCli? cli,
  Map<String, FakeMemexCli>? clis,
  String binaryPath = 'fake-memex',
  List<String> recents = const [],
  String? lastVault,
  FakeVaultDb? db,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': binaryPath,
    'memex.recent_vaults': recents,
    'memex.last_vault': ?lastVault,
  });
  final settings = await SettingsController.load();
  final fakeDb = db ?? FakeVaultDb.v5();
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      vaultDbProvider.overrideWithValue(fakeDb),
      if (clis != null)
        memexCliProvider.overrideWith(
          (ref) => clis[ref.watch(settingsProvider).memexBinaryPath],
        )
      else
        memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(fakeDb.close);
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
  return container;
}

/// Let real-async work (file writes, prefs) land, then pump frames.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpFrames(tester);
}

Future<void> _tapOpenLocalVault(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('vault-picker-open')));
  await _settle(tester);
}

/// Opens the create dialog, picks [parent] with "choose…" and submits the
/// default name with [name].
Future<void> _createVault(
  WidgetTester tester,
  FakeFilePicker picker, {
  required String parent,
  required String name,
}) async {
  await tester.tap(find.byKey(const Key('vault-picker-create')));
  await pumpFrames(tester);
  picker.directories.add(parent);
  await tester.tap(find.text('choose…'));
  await pumpFrames(tester);
  await tester.enterText(find.byType(TextField), name);
  await pumpFrames(tester);
  await tester.tap(find.text('create'));
  await _settle(tester);
}

Finder _inside(Key key, Finder matching) =>
    find.descendant(of: find.byKey(key), matching: matching);

OmButton _button(WidgetTester tester, Key key) => tester.widget<OmButton>(
  find.descendant(
    of: find.byKey(key),
    matching: find.byType(OmButton),
    matchRoot: true,
  ),
);

/// The sidebar pill for the vault folder at [path].
Finder _pill(String path) => find.descendant(
  of: find.byType(Sidebar),
  matching: find.text(p.basename(path)),
);

void _expectNoRefusal() {
  expect(find.byKey(_refusal), findsNothing);
  expect(find.byKey(_tooOld), findsNothing);
}

/// Shows a refusal dialog from a bare app, taps [tapKey] and returns what
/// the dialog completed with.
Future<T?> _choiceFrom<T>(
  WidgetTester tester,
  Future<T?> Function(BuildContext context) show,
  Key tapKey,
) async {
  T? result;
  var done = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => show(ctx).then((v) {
              result = v;
              done = true;
            }),
            child: const Text('show'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('show'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(tapKey));
  await tester.pumpAndSettle();
  expect(done, isTrue, reason: 'the dialog completed');
  expect(find.byKey(tapKey), findsNothing, reason: 'the dialog closed');
  return result;
}

void main() {
  group('open local vault runs vault check first', () {
    testWidgets(
      'open local vault runs vault check before opening and opens the workspace on exit 0',
      (tester) async {
        final vault = createVaultFolder('om92_open_');
        final picker = installFakeFilePicker()..directories.add(vault.path);
        final gate = Completer<MemexResult>();
        final cli = _cli((_) => gate.future);
        final c = await _pumpApp(tester, cli: cli);

        await _tapOpenLocalVault(tester);

        expect(picker.calls.single.method, 'getDirectoryPath');
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);
        expect(c.read(currentVaultProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);

        gate.complete(FakeMemexCli.ok());
        await _settle(tester);

        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(c.read(settingsProvider).lastVault, vault.path);
        expect(c.read(settingsProvider).recentVaults.first, vault.path);
        expect(find.byType(Workspace), findsOneWidget);
        expect(_subcommands(cli), ['vault check', 'settings get']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a recent row runs vault check before any other call', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_recent_');
      final gate = Completer<MemexResult>();
      final cli = _cli((_) => gate.future);
      final c = await _pumpApp(tester, cli: cli, recents: [vault.path]);

      await tester.tap(find.text(p.basename(vault.path)));
      await _settle(tester);

      expect(cli.calls.single.args, ['vault', 'check', '--vault', vault.path]);
      expect(c.read(currentVaultProvider), isNull);
      expect(find.byType(Workspace), findsNothing);

      gate.complete(FakeMemexCli.ok());
      await _settle(tester);

      expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
      expect(find.byType(Workspace), findsOneWidget);
      expect(_subcommands(cli), ['vault check', 'settings get']);
    });

    testWidgets('a sidebar vault pill runs vault check before any other call', (
      tester,
    ) async {
      final gate = Completer<MemexResult>();
      final cli = _cli((_) => gate.future);
      final h = await pumpWorkspace(tester, cli: cli);
      final other = createVaultFolder('om92_pill_');
      final settings = h.read(settingsProvider.notifier);
      await tester.runAsync(() async {
        await settings.rememberVault(other.path);
        await settings.rememberVault(h.vaultPath);
      });
      await pumpFrames(tester);
      cli.calls.clear();

      await tester.tap(_pill(other.path));
      await _settle(tester);

      expect(cli.calls, hasLength(1));
      expect(cli.calls.single.args, ['vault', 'check', '--vault', other.path]);
      expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      expect(h.read(settingsProvider).lastVault, h.vaultPath);

      gate.complete(FakeMemexCli.ok());
      await _settle(tester);

      expect(h.read(currentVaultProvider), LocalVaultRef(other.path));
      expect(h.read(settingsProvider).lastVault, other.path);
      expect(cli.calls.first.subcommand, 'vault check');
      expect(find.byType(Workspace), findsOneWidget);
    });

    testWidgets(
      'create local vault runs vault check on the target path before memex init',
      (tester) async {
        final parent = createPlainFolder('om92_parent_');
        final target = p.join(parent.path, 'NewVault');
        final picker = installFakeFilePicker();
        final gate = Completer<MemexResult>();
        final cli = _cli((_) => gate.future);
        final c = await _pumpApp(tester, cli: cli);

        await _createVault(
          tester,
          picker,
          parent: parent.path,
          name: 'NewVault',
        );

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, ['vault', 'check', '--vault', target]);
        expect(cli.callsFor('init'), isEmpty);
        expect(Directory(target).existsSync(), isFalse);
        expect(c.read(currentVaultProvider), isNull);

        gate.complete(FakeMemexCli.ok());
        await _settle(tester);

        expect(_subcommands(cli).take(2), ['vault check', 'init']);
        expect(c.read(currentVaultProvider), LocalVaultRef(target));
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });

  group('launch reopens the last local vault through vault check', () {
    testWidgets(
      'at launch the picker shows the last vault row as opening while vault check runs',
      (tester) async {
        final vault = createVaultFolder('om92_last_');
        final gate = Completer<MemexResult>();
        final cli = _cli((_) => gate.future);
        final c = await _pumpApp(
          tester,
          cli: cli,
          recents: [vault.path],
          lastVault: vault.path,
        );

        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(c.read(currentVaultProvider), isNull);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);

        // The opening row (A3 state 3, A12 "opening · fg2, spinner").
        expect(find.byKey(_openingRow), findsOneWidget);
        expect(_inside(_openingRow, find.text(vault.path)), findsOneWidget);
        expect(
          _inside(_openingRow, find.text(p.basename(vault.path))),
          findsOneWidget,
        );
        final spinner = tester.widget<Icon>(
          _inside(_openingRow, find.byIcon(LucideIcons.loader2)),
        );
        expect(spinner.size, 14);
        expect(spinner.color, OmColors.fg2);
        expect(
          _inside(_openingRow, find.byIcon(LucideIcons.folder)),
          findsNothing,
        );
        expect(
          _inside(_openingRow, find.byIcon(LucideIcons.x)),
          findsNothing,
          reason: 'no remove button while opening',
        );

        // The opening row is not tappable: no second check starts.
        await tester.tap(find.byKey(_openingRow), warnIfMissed: false);
        await _settle(tester);
        expect(cli.callsFor('vault check'), hasLength(1));

        gate.complete(FakeMemexCli.ok());
        await _settle(tester);

        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byType(Workspace), findsOneWidget);
        expect(_subcommands(cli), ['vault check', 'settings get']);
      },
    );

    testWidgets('at launch with no last vault no vault check runs', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_nolast_');
      final cli = _cli((_) => FakeMemexCli.ok());
      final c = await _pumpApp(tester, cli: cli, recents: [vault.path]);

      expect(cli.calls, isEmpty);
      expect(find.byKey(_openingRow), findsNothing);
      expect(find.byType(VaultPickerScreen), findsOneWidget);
      expect(c.read(currentVaultProvider), isNull);
    });

    testWidgets(
      'at launch a network drive refusal shows over the picker and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_lastnas_');
        final cli = _cli((_) => _networkDrive());
        final c = await _pumpApp(
          tester,
          cli: cli,
          recents: [vault.path],
          lastVault: vault.path,
        );
        await _settle(tester);

        expect(find.byKey(_refusal), findsOneWidget);
        expect(
          _inside(_refusal, find.text('OPEN LOCAL VAULT')),
          findsOneWidget,
        );
        expect(_inside(_refusal, find.text(vault.path)), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, [vault.path]);
        expect(_subcommands(cli), ['vault check']);

        await tester.tap(find.byKey(_refusalCancel));
        await _settle(tester);

        expect(find.byKey(_refusal), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byKey(_openingRow), findsNothing);
        expect(find.text(p.basename(vault.path)), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    testWidgets(
      'at launch a memex that exits 2 shows the too old refusal over the picker',
      (tester) async {
        final vault = createVaultFolder('om92_lastold_');
        final cli = _cli((_) => _tooOldMemex());
        final c = await _pumpApp(
          tester,
          cli: cli,
          recents: [vault.path],
          lastVault: vault.path,
        );
        await _settle(tester);

        expect(find.byKey(_tooOld), findsOneWidget);
        expect(_inside(_tooOld, find.text(_tooOldCopy)), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(c.read(currentVaultProvider), isNull);
        expect(_subcommands(cli), ['vault check']);
      },
    );

    testWidgets(
      'at launch with no memex binary configured the picker shows the binary not found card and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_lastnocli_');
        final c = await _pumpApp(
          tester,
          cli: null,
          binaryPath: '',
          recents: [vault.path],
          lastVault: vault.path,
        );
        await _settle(tester);

        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(find.text('memex binary not found'), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
      },
    );
  });

  group('network drive refusal', () {
    testWidgets(
      'a network drive shows the refusal with the path, copy, link and buttons and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_nas_');
        final other = createVaultFolder('om92_kept_');
        installFakeFilePicker().directories.add(vault.path);
        final cli = _cli((_) => _networkDrive());
        final c = await _pumpApp(tester, cli: cli, recents: [other.path]);

        await _tapOpenLocalVault(tester);

        expect(find.byKey(_refusal), findsOneWidget);
        expect(
          _inside(_refusal, find.text('OPEN LOCAL VAULT')),
          findsOneWidget,
        );
        expect(_inside(_refusal, find.text(vault.path)), findsOneWidget);
        expect(_inside(_refusal, find.text(_networkCopy)), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_refusalSetup),
            matching: find.text(_setUpLabel),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_refusalCancel),
            matching: find.text('cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_refusalConnect),
            matching: find.text(_connectLabel),
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, [other.path]);
        expect(c.read(settingsProvider).lastVault, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList('memex.recent_vaults'), [other.path]);
        expect(_subcommands(cli), ['vault check']);
      },
    );

    testWidgets('the network drive refusal matches board A9 state 1', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_nasdesign_');
      installFakeFilePicker().directories.add(vault.path);
      await _pumpApp(tester, cli: _cli((_) => _networkDrive()));

      await _tapOpenLocalVault(tester);

      final drive = tester.widget<Icon>(
        _inside(_refusal, find.byIcon(LucideIcons.hardDrive)),
      );
      expect(drive.size, 14);
      expect(drive.color, OmColors.fg2);
      final path = tester.widget<Text>(
        _inside(_refusal, find.text(vault.path)),
      );
      expect(path.style!.fontSize, 12);
      expect(path.style!.color, OmColors.fg1);
      expect(path.maxLines, 1);
      final message = tester.widget<Text>(
        _inside(_refusal, find.text(_networkCopy)),
      );
      expect(message.style!.fontSize, 13.5);
      expect(message.style!.color, OmColors.fg0);
      final help = tester.widget<Icon>(
        _inside(_refusalSetup, find.byIcon(LucideIcons.circleHelp)),
      );
      expect(help.size, 12);
      expect(help.color, OmColors.info);
      final link = tester.widget<Text>(
        _inside(_refusalSetup, find.text(_setUpLabel)),
      );
      expect(link.style!.fontSize, 12);
      expect(link.style!.color, OmColors.info);
      expect(_button(tester, _refusalConnect).kind, OmButtonKind.primary);
      expect(_button(tester, _refusalCancel).kind, OmButtonKind.ghost);
    });

    testWidgets(
      'in the create flow the network drive refusal eyebrow is CREATE NEW VAULT and init never runs',
      (tester) async {
        final parent = createPlainFolder('om92_nasparent_');
        final target = p.join(parent.path, 'OnNas');
        final picker = installFakeFilePicker();
        final cli = _cli((_) => _networkDrive());
        final c = await _pumpApp(tester, cli: cli);

        await _createVault(tester, picker, parent: parent.path, name: 'OnNas');

        expect(find.byKey(_refusal), findsOneWidget);
        expect(
          _inside(_refusal, find.text('CREATE NEW VAULT')),
          findsOneWidget,
        );
        expect(_inside(_refusal, find.text('OPEN LOCAL VAULT')), findsNothing);
        expect(_inside(_refusal, find.text(target)), findsOneWidget);
        expect(_inside(_refusal, find.text(_networkCopy)), findsOneWidget);
        expect(cli.callsFor('init'), isEmpty);
        expect(Directory(target).existsSync(), isFalse);
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    testWidgets('cancel closes the refusal and leaves the picker as it was', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_nascancel_');
      final other = createVaultFolder('om92_kept_');
      installFakeFilePicker().directories.add(vault.path);
      final c = await _pumpApp(
        tester,
        cli: _cli((_) => _networkDrive()),
        recents: [other.path],
      );

      await _tapOpenLocalVault(tester);
      await tester.tap(find.byKey(_refusalCancel));
      await _settle(tester);

      _expectNoRefusal();
      expect(find.byType(VaultPickerScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(c.read(currentVaultProvider), isNull);
      expect(c.read(settingsProvider).recentVaults, [other.path]);
    });

    for (final (name, key) in [
      (
        'set up a vault server closes the refusal and leaves the picker as it was',
        _refusalSetup,
      ),
      (
        'connect to a vault server closes the refusal and leaves the picker as it was',
        _refusalConnect,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final vault = createVaultFolder('om92_naschoice_');
        installFakeFilePicker().directories.add(vault.path);
        final c = await _pumpApp(tester, cli: _cli((_) => _networkDrive()));

        await _tapOpenLocalVault(tester);
        await tester.tap(find.byKey(key));
        await _settle(tester);

        _expectNoRefusal();
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
      });
    }

    for (final (name, key, choice) in [
      (
        'the refusal returns setUpServer from set up a vault server',
        _refusalSetup,
        NetworkDriveRefusalChoice.setUpServer,
      ),
      (
        'the refusal returns connectServer from connect to a vault server',
        _refusalConnect,
        NetworkDriveRefusalChoice.connectServer,
      ),
      (
        'the refusal returns cancel from cancel',
        _refusalCancel,
        NetworkDriveRefusalChoice.cancel,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final result = await _choiceFrom(
          tester,
          (ctx) => showNetworkDriveRefusalDialog(
            ctx,
            path: '/Volumes/home/memex',
            eyebrow: 'OPEN LOCAL VAULT',
          ),
          key,
        );
        expect(result, choice);
      });
    }
  });

  group('too old memex refusal', () {
    testWidgets(
      'a memex that exits 2 shows the too old refusal with the path, copy and buttons and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_old_');
        installFakeFilePicker().directories.add(vault.path);
        final cli = _cli((_) => _tooOldMemex());
        final c = await _pumpApp(tester, cli: cli);

        await _tapOpenLocalVault(tester);

        expect(find.byKey(_tooOld), findsOneWidget);
        expect(_inside(_tooOld, find.text('OPEN LOCAL VAULT')), findsOneWidget);
        expect(_inside(_tooOld, find.text(vault.path)), findsOneWidget);
        expect(_inside(_tooOld, find.text(_tooOldCopy)), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_tooOldCancel),
            matching: find.text('cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_tooOldLocate),
            matching: find.text(_locateLabel),
          ),
          findsOneWidget,
        );
        expect(_inside(_tooOld, find.text(_setUpLabel)), findsNothing);
        expect(find.byKey(_refusal), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(c.read(currentVaultProvider), isNull);
        expect(_subcommands(cli), ['vault check']);
      },
    );

    testWidgets('the too old refusal reuses the A9 state 1 layout', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_olddesign_');
      installFakeFilePicker().directories.add(vault.path);
      await _pumpApp(tester, cli: _cli((_) => _tooOldMemex()));

      await _tapOpenLocalVault(tester);

      // The path row uses the folder icon: a drive icon would claim a
      // network drive (design pack 92).
      final folder = tester.widget<Icon>(
        _inside(_tooOld, find.byIcon(LucideIcons.folder)),
      );
      expect(folder.size, 14);
      expect(folder.color, OmColors.fg2);
      expect(
        _inside(_tooOld, find.byIcon(LucideIcons.hardDrive)),
        findsNothing,
      );
      final path = tester.widget<Text>(_inside(_tooOld, find.text(vault.path)));
      expect(path.style!.fontSize, 12);
      expect(path.style!.color, OmColors.fg1);
      final message = tester.widget<Text>(
        _inside(_tooOld, find.text(_tooOldCopy)),
      );
      expect(message.style!.fontSize, 13.5);
      expect(message.style!.color, OmColors.fg0);
      expect(_button(tester, _tooOldLocate).kind, OmButtonKind.primary);
      expect(_button(tester, _tooOldCancel).kind, OmButtonKind.ghost);
    });

    testWidgets(
      'in the create flow the too old refusal eyebrow is CREATE NEW VAULT and init never runs',
      (tester) async {
        final parent = createPlainFolder('om92_oldparent_');
        final target = p.join(parent.path, 'Fresh');
        final picker = installFakeFilePicker();
        final cli = _cli((_) => _tooOldMemex());
        final c = await _pumpApp(tester, cli: cli);

        await _createVault(tester, picker, parent: parent.path, name: 'Fresh');

        expect(find.byKey(_tooOld), findsOneWidget);
        expect(_inside(_tooOld, find.text('CREATE NEW VAULT')), findsOneWidget);
        expect(_inside(_tooOld, find.text(target)), findsOneWidget);
        expect(cli.callsFor('init'), isEmpty);
        expect(Directory(target).existsSync(), isFalse);
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    testWidgets(
      'cancel closes the too old refusal and leaves the picker as it was',
      (tester) async {
        final vault = createVaultFolder('om92_oldcancel_');
        installFakeFilePicker().directories.add(vault.path);
        final c = await _pumpApp(tester, cli: _cli((_) => _tooOldMemex()));

        await _tapOpenLocalVault(tester);
        await tester.tap(find.byKey(_tooOldCancel));
        await _settle(tester);

        _expectNoRefusal();
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).memexBinaryPath, 'fake-memex');
      },
    );

    for (final (name, key, choice) in [
      (
        'the too old refusal returns locateBinary from locate memex binary',
        _tooOldLocate,
        MemexTooOldChoice.locateBinary,
      ),
      (
        'the too old refusal returns cancel from cancel',
        _tooOldCancel,
        MemexTooOldChoice.cancel,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final result = await _choiceFrom(
          tester,
          (ctx) => showMemexTooOldDialog(
            ctx,
            path: '/Users/me/memex',
            eyebrow: 'OPEN LOCAL VAULT',
          ),
          key,
        );
        expect(result, choice);
      });
    }

    testWidgets(
      'locate memex binary stores the picked binary and the next open runs vault check with it',
      (tester) async {
        final vault = createVaultFolder('om92_locate_');
        final binDir = createPlainFolder('om92_bin_');
        final newBinary = p.join(binDir.path, 'memex');
        File(newBinary).writeAsStringSync('#!/bin/sh\n');
        final picker = installFakeFilePicker()..files.add(newBinary);
        final oldCli = _cli((_) => _tooOldMemex());
        final newCli = _cli((_) => FakeMemexCli.ok());
        final c = await _pumpApp(
          tester,
          clis: {'old-memex': oldCli, newBinary: newCli},
          binaryPath: 'old-memex',
          recents: [vault.path],
        );

        await tester.tap(find.text(p.basename(vault.path)));
        await _settle(tester);
        expect(find.byKey(_tooOld), findsOneWidget);

        await tester.tap(find.byKey(_tooOldLocate));
        await _settle(tester);

        expect(picker.calls.single.method, 'pickFiles');
        expect(c.read(settingsProvider).memexBinaryPath, newBinary);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('memex.binary_path'), newBinary);
        _expectNoRefusal();
        expect(c.read(currentVaultProvider), isNull);
        expect(
          newCli.calls,
          isEmpty,
          reason: 'the next attempt is the persons',
        );

        // The next attempt at the same open uses the new binary.
        await tester.tap(find.text(p.basename(vault.path)));
        await _settle(tester);

        expect(oldCli.callsFor('vault check'), hasLength(1));
        expect(newCli.calls.first.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);
        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    for (final (name, picked) in [
      (
        'locate memex binary with a path that does not exist keeps the old binary',
        '/nonexistent/om92/memex',
      ),
      ('cancelling the binary picker keeps the old binary', null),
    ]) {
      testWidgets(name, (tester) async {
        final vault = createVaultFolder('om92_locatekeep_');
        final picker = installFakeFilePicker()
          ..directories.add(vault.path)
          ..files.add(picked);
        final c = await _pumpApp(tester, cli: _cli((_) => _tooOldMemex()));

        await _tapOpenLocalVault(tester);
        await tester.tap(find.byKey(_tooOldLocate));
        await _settle(tester);

        expect(picker.calls.last.method, 'pickFiles');
        expect(c.read(settingsProvider).memexBinaryPath, 'fake-memex');
        expect(c.read(currentVaultProvider), isNull);
      });
    }
  });

  group('other vault check failures show the open error', () {
    for (final (name, result, text) in [
      (
        'exit 1 with C1 not_found shows the open error in a snackbar and opens nothing',
        FakeMemexCli.error('not_found', 'no such folder here'),
        'no such folder here',
      ),
      (
        'exit 1 with non-JSON stderr shows the open error in a snackbar and opens nothing',
        FakeMemexCli.failure('something odd happened\n'),
        'something odd happened',
      ),
      (
        'exit 3 with C1 network_filesystem shows the open error in a snackbar and opens nothing',
        FakeMemexCli.failure(
          '{"error":{"code":"network_filesystem","message":"odd exit"}}\n',
          exitCode: 3,
        ),
        'odd exit',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final vault = createVaultFolder('om92_err_');
        installFakeFilePicker().directories.add(vault.path);
        final cli = _cli((_) => result);
        final c = await _pumpApp(tester, cli: cli);

        await _tapOpenLocalVault(tester);

        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining(text),
          ),
          findsOneWidget,
        );
        _expectNoRefusal();
        expect(c.read(currentVaultProvider), isNull);
        expect(find.byType(Workspace), findsNothing);
        expect(_subcommands(cli), ['vault check']);
      });
    }
  });

  group('memex binary not found', () {
    testWidgets(
      'when spawning memex throws the picker shows the memex binary not found card and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_spawn_');
        installFakeFilePicker().directories.add(vault.path);
        final c = await _pumpApp(tester, cli: _cli(_spawnFailure));
        expect(find.text('memex binary not found'), findsNothing);

        await _tapOpenLocalVault(tester);

        expect(find.text('memex binary not found'), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
        expect(find.byType(Workspace), findsNothing);
        _expectNoRefusal();
      },
    );

    testWidgets(
      'with no memex binary configured open local vault opens nothing',
      (tester) async {
        final vault = createVaultFolder('om92_nobin_');
        installFakeFilePicker().directories.add(vault.path);
        final c = await _pumpApp(tester, cli: null, binaryPath: '');

        await _tapOpenLocalVault(tester);

        expect(c.read(currentVaultProvider), isNull);
        expect(find.byType(Workspace), findsNothing);
        expect(find.text('memex binary not found'), findsOneWidget);
      },
    );

    testWidgets('with no memex binary configured a recent row opens nothing', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_nobinrow_');
      final c = await _pumpApp(
        tester,
        cli: null,
        binaryPath: '',
        recents: [vault.path],
      );

      await tester.tap(find.text(p.basename(vault.path)));
      await _settle(tester);

      expect(c.read(currentVaultProvider), isNull);
      expect(find.byType(Workspace), findsNothing);
    });
  });

  group('existing local vaults open as today', () {
    testWidgets(
      'a V4 vault opened through the picker after vault check shows the schema banner',
      (tester) async {
        final vault = createVaultFolder('om92_v4_');
        final cli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok())
          ..on(
            'settings get',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'settings'\n",
              exitCode: 2,
            ),
          );
        final c = await _pumpApp(
          tester,
          cli: cli,
          recents: [vault.path],
          db: FakeVaultDb.v4(),
        );

        await tester.tap(find.text(p.basename(vault.path)));
        await _settle(tester);

        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byKey(const Key('vault-schema-outdated')), findsOneWidget);
        expect(_subcommands(cli), ['vault check', 'settings get']);
        _expectNoRefusal();
      },
    );
  });

  // Verify-mode pins: contracts the implementer handoff listed as unpinned.
  group('pill refusals (verify)', () {
    // Orchestrator ruling: switchToVault returns data only and shows
    // nothing; the caller (the pills once #96 wires them) presents the
    // refusal with showVaultOpenRefusal under the OPEN LOCAL VAULT eyebrow.

    /// Pumps the workspace with [other] remembered after the open vault, so
    /// its sidebar pill shows.
    Future<WorkspaceHarness> pumpWithOther(
      WidgetTester tester,
      FakeMemexCli cli,
      String other, {
      List<Override> overrides = const [],
    }) async {
      final h = await pumpWorkspace(tester, cli: cli, overrides: overrides);
      final settings = h.read(settingsProvider.notifier);
      await tester.runAsync(() async {
        await settings.rememberVault(other);
        await settings.rememberVault(h.vaultPath);
      });
      await pumpFrames(tester);
      return h;
    }

    /// Runs `switchToVault` from the workspace's context and returns its
    /// outcome once the frames settled.
    Future<VaultOpenOutcome> switchFromWorkspace(
      WidgetTester tester,
      WorkspaceHarness h,
      String path,
    ) async {
      final pending = h
          .read(vaultOpenControllerProvider)
          .switchToVault(
            tester.element(find.byType(Workspace)),
            LocalVaultRef(path),
          );
      await _settle(tester);
      // Checked before awaiting: a shown refusal would hold the switch open.
      expect(
        find.byType(Dialog),
        findsNothing,
        reason: 'switchToVault shows nothing',
      );
      return pending;
    }

    void expectWorkspaceAsItWas(WorkspaceHarness h, String other) {
      expect(find.byType(Workspace), findsOneWidget);
      expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      expect(h.read(settingsProvider).lastVault, h.vaultPath);
      expect(h.read(settingsProvider).recentVaults, [h.vaultPath, other]);
      expect(h.read(settingsProvider).memexBinaryPath, 'fake-memex');
    }

    for (final (name, check, matcher) in [
      (
        'switchToVault on a network drive returns the refusal and leaves the workspace as it was',
        (FakeCliCall _) => _networkDrive(),
        isA<VaultOnNetworkDrive>(),
      ),
      (
        'switchToVault with a memex that exits 2 returns the too old refusal and leaves the workspace as it was',
        (FakeCliCall _) => _tooOldMemex(),
        isA<VaultMemexTooOld>(),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final cli = _cli(check);
        final other = createVaultFolder('om92_switchrefused_').path;
        final h = await pumpWithOther(tester, cli, other);
        cli.calls.clear();

        final outcome = await switchFromWorkspace(tester, h, other);

        expect(outcome, matcher);
        expect(switch (outcome) {
          VaultOnNetworkDrive(:final path) => path,
          VaultMemexTooOld(:final path) => path,
          _ => null,
        }, other);
        expect(cli.calls.single.args, ['vault', 'check', '--vault', other]);
        expect(find.byType(Dialog), findsNothing);
        _expectNoRefusal();
        expectWorkspaceAsItWas(h, other);
      });
    }

    testWidgets('switchToVault shows nothing for a refusal', (tester) async {
      final nas = createVaultFolder('om92_pillnas_').path;
      final old = createVaultFolder('om92_pillold_').path;
      final cli = _cli(
        (call) => call.flag('vault') == nas ? _networkDrive() : _tooOldMemex(),
      );
      final h = await pumpWorkspace(tester, cli: cli);
      final settings = h.read(settingsProvider.notifier);
      await tester.runAsync(() async {
        await settings.rememberVault(old);
        await settings.rememberVault(nas);
        await settings.rememberVault(h.vaultPath);
      });
      await pumpFrames(tester);
      cli.calls.clear();

      for (final path in [nas, old]) {
        // #96 TEST-CHANGE: the sidebar pill now presents a refusal (lead
        // update on #117, test/widgets/hosted_vault_pill_test.dart AC1), so
        // this calls switchToVault directly: the controller itself still
        // returns the outcome and shows nothing.
        final outcome = h
            .read(vaultOpenControllerProvider)
            .switchToVault(
              tester.element(find.byType(Workspace)),
              LocalVaultRef(path),
            );
        await _settle(tester);
        // Past any dialog's entrance (the workspace never settles).
        await tester.pump(const Duration(seconds: 1));
        expect(await outcome, isA<VaultOpenFailure>(), reason: path);

        expect(find.byType(Dialog), findsNothing, reason: path);
        _expectNoRefusal();
        expect(find.byType(Workspace), findsOneWidget);
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      }
      expect(cli.callsFor('vault check').map((c) => c.flag('vault')).toList(), [
        nas,
        old,
      ], reason: 'both pill taps ran vault check and were refused');
      expect(h.read(settingsProvider).lastVault, h.vaultPath);
      expect(h.read(settingsProvider).recentVaults, [h.vaultPath, nas, old]);
    });

    for (final (name, check, dialog, copy, cancel) in [
      (
        'showVaultOpenRefusal over the workspace shows the network drive refusal with the OPEN LOCAL VAULT eyebrow',
        (FakeCliCall _) => _networkDrive(),
        _refusal,
        _networkCopy,
        _refusalCancel,
      ),
      (
        'showVaultOpenRefusal over the workspace shows the too old refusal with the OPEN LOCAL VAULT eyebrow',
        (FakeCliCall _) => _tooOldMemex(),
        _tooOld,
        _tooOldCopy,
        _tooOldCancel,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final cli = _cli(check);
        final other = createVaultFolder('om92_pilleyebrow_').path;
        final h = await pumpWithOther(tester, cli, other);
        final outcome = await switchFromWorkspace(tester, h, other);
        bool? shown;

        unawaited(
          showVaultOpenRefusal(
            tester.element(find.byType(Workspace)),
            outcome,
            eyebrow: 'OPEN LOCAL VAULT',
          ).then((v) => shown = v),
        );
        await _settle(tester);

        expect(find.byKey(dialog), findsOneWidget);
        expect(_inside(dialog, find.text('OPEN LOCAL VAULT')), findsOneWidget);
        expect(_inside(dialog, find.text('CREATE NEW VAULT')), findsNothing);
        expect(_inside(dialog, find.text(other)), findsOneWidget);
        expect(_inside(dialog, find.text(copy)), findsOneWidget);
        expect(find.byType(Workspace), findsOneWidget);
        expect(shown, isNull, reason: 'completes only once the dialog closes');

        await tester.tap(find.byKey(cancel));
        await _settle(tester);

        expect(shown, isTrue);
        _expectNoRefusal();
        expectWorkspaceAsItWas(h, other);
      });
    }

    testWidgets(
      'locate memex binary from a too old refusal over the workspace stores the picked binary and the next openVault runs vault check with it',
      (tester) async {
        final binDir = createPlainFolder('om92_pillbin_');
        final newBinary = p.join(binDir.path, 'memex');
        File(newBinary).writeAsStringSync('#!/bin/sh\n');
        final picker = installFakeFilePicker()..files.add(newBinary);
        final oldCli = _cli((_) => _tooOldMemex());
        final newCli = _cli((_) => FakeMemexCli.ok(), binaryPath: newBinary);
        final clis = {'fake-memex': oldCli, newBinary: newCli};
        final other = createVaultFolder('om92_pilllocate_').path;
        final h = await pumpWithOther(
          tester,
          oldCli,
          other,
          overrides: [
            memexCliProvider.overrideWith(
              (ref) => clis[ref.watch(settingsProvider).memexBinaryPath],
            ),
          ],
        );
        final outcome = await switchFromWorkspace(tester, h, other);
        expect(outcome, isA<VaultMemexTooOld>());
        bool? shown;

        unawaited(
          showVaultOpenRefusal(
            tester.element(find.byType(Workspace)),
            outcome,
            eyebrow: 'OPEN LOCAL VAULT',
          ).then((v) => shown = v),
        );
        await _settle(tester);
        expect(find.byKey(_tooOld), findsOneWidget);

        await tester.tap(find.byKey(_tooOldLocate));
        await _settle(tester);

        expect(shown, isTrue);
        expect(picker.calls.single.method, 'pickFiles');
        expect(h.read(settingsProvider).memexBinaryPath, newBinary);
        final prefs = await tester.runAsync(SharedPreferences.getInstance);
        expect(prefs!.getString('memex.binary_path'), newBinary);
        _expectNoRefusal();
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
        expect(newCli.callsFor('vault check'), isEmpty);

        final pending = h
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(other));
        await _settle(tester);
        final next = await pending;

        expect(oldCli.callsFor('vault check'), hasLength(1));
        expect(newCli.callsFor('vault check').single.args, [
          'vault',
          'check',
          '--vault',
          other,
        ]);
        expect(next, isA<VaultOpened>());
        expect(h.read(currentVaultProvider), LocalVaultRef(other));
      },
    );
  });

  group('picker outcomes (verify)', () {
    testWidgets(
      'the binary not found card hides once a different binary is located after a spawn failure',
      (tester) async {
        final vault = createVaultFolder('om92_spawnlocate_');
        final binDir = createPlainFolder('om92_spawnbin_');
        final newBinary = p.join(binDir.path, 'memex');
        File(newBinary).writeAsStringSync('#!/bin/sh\n');
        final picker = installFakeFilePicker()
          ..directories.add(vault.path)
          ..files.add(newBinary);
        // Each fake reports its own binary, as the real memexCliProvider
        // builds the CLI from the configured path.
        final brokenCli = _cli(_spawnFailure, binaryPath: 'broken-memex');
        final newCli = _cli((_) => FakeMemexCli.ok(), binaryPath: newBinary);
        final c = await _pumpApp(
          tester,
          clis: {'broken-memex': brokenCli, newBinary: newCli},
          binaryPath: 'broken-memex',
        );
        expect(find.text('memex binary not found'), findsNothing);

        await _tapOpenLocalVault(tester);
        expect(find.text('memex binary not found'), findsOneWidget);

        await tester.tap(find.text(_locateLabel));
        await _settle(tester);

        expect(picker.calls.last.method, 'pickFiles');
        expect(c.read(settingsProvider).memexBinaryPath, newBinary);
        expect(find.text('memex binary not found'), findsNothing);
        expect(find.text('memex binary  $newBinary'), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    testWidgets(
      'the binary not found card stays while the binary that could not start is still configured',
      (tester) async {
        final vault = createVaultFolder('om92_spawnstay_');
        installFakeFilePicker().directories.add(vault.path);
        final c = await _pumpApp(tester, cli: _cli(_spawnFailure));

        await _tapOpenLocalVault(tester);
        expect(find.text('memex binary not found'), findsOneWidget);
        // A settings write that keeps the binary does not hide the card.
        await tester.runAsync(
          () => c.read(settingsProvider.notifier).rememberVault('/elsewhere'),
        );
        await pumpFrames(tester);

        expect(find.text('memex binary not found'), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    testWidgets(
      'at launch a plain vault check failure clears the opening row and shows the open error in a snackbar',
      (tester) async {
        final vault = createVaultFolder('om92_launchfail_');
        final failure = FakeMemexCli.error('not_found', 'no such folder here');
        final cli = _cli((_) => failure);
        final c = await _pumpApp(
          tester,
          cli: cli,
          recents: [vault.path],
          lastVault: vault.path,
        );
        await _settle(tester);

        expect(find.byKey(_openingRow), findsNothing);
        expect(find.text(p.basename(vault.path)), findsOneWidget);
        final error = MemexException.fromCliFailure('vault check', failure);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(
              'Could not open ${vault.path}: ${error.message}',
            ),
          ),
          findsOneWidget,
        );
        _expectNoRefusal();
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, [vault.path]);
        expect(_subcommands(cli), ['vault check']);
      },
    );

    testWidgets('the opening row spinner turns once per second', (
      tester,
    ) async {
      final vault = createVaultFolder('om92_spin_');
      final gate = Completer<MemexResult>();
      await _pumpApp(
        tester,
        cli: _cli((_) => gate.future),
        recents: [vault.path],
        lastVault: vault.path,
      );
      final spin = tester.widget<RotationTransition>(
        find.descendant(
          of: find.byKey(_openingRow),
          matching: find.byType(RotationTransition),
        ),
      );
      final start = spin.turns.value;

      await tester.pump(const Duration(milliseconds: 250));
      expect((spin.turns.value - start) % 1.0, closeTo(0.25, 0.01));
      await tester.pump(const Duration(milliseconds: 750));
      expect((spin.turns.value - start) % 1.0, closeTo(0.0, 0.01));

      gate.complete(FakeMemexCli.ok());
      await _settle(tester);
    });
  });
}
