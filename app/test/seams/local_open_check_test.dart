// WI #92 (D19, req 31): every local open runs `memex vault check --vault
// <path>` before any SQLite handle exists, and the check's result maps to a
// VaultOpenOutcome. Controller-level seams; the picker, pills and launch are
// in test/journeys/local_open_refusal_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart' show settingsGetMaxDepthStdout;
import '../support/fake_memex_cli.dart';
import '../support/vault_folders.dart';

/// clap's answer from a memex without `vault check` (exit 2).
const _clapUsageError =
    "error: unrecognized subcommand 'vault'\n\nUsage: memex <COMMAND>\n";

/// App state with no vault open, [recents] remembered and the fake CLI
/// behind `memexCliProvider`. `vaultDbProvider` is the real one, so a
/// SQLite handle exists only once `currentVaultProvider` names a vault.
/// With [clis], `memexCliProvider` re-reads the configured binary path and
/// answers the fake for it (null when none matches).
Future<ProviderContainer> _app({
  FakeMemexCli? cli,
  Map<String, FakeMemexCli>? clis,
  String binaryPath = 'fake-memex',
  List<String> recents = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': binaryPath,
    'memex.recent_vaults': recents,
  });
  final settings = await SettingsController.load();
  final c = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      if (clis != null)
        memexCliProvider.overrideWith(
          (ref) => clis[ref.watch(settingsProvider).memexBinaryPath],
        )
      else
        memexCliProvider.overrideWithValue(cli),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// A `vault check` handler held until [gate] completes.
FakeCliHandler _gated(Completer<MemexResult> gate) =>
    (_) => gate.future;

/// What `memex init <path>` leaves behind, as in the real binary.
MemexResult _init(FakeCliCall call) {
  initVaultFolder(call.args[1]);
  return FakeMemexCli.ok();
}

Never _spawnFailure(FakeCliCall _) => throw const ProcessException(
  'fake-memex',
  ['vault', 'check'],
  'No such file or directory',
  2,
);

/// Nothing changed: no vault open, no SQLite handle, recents and the last
/// vault as before (in memory and on disk).
Future<void> _expectNothingOpened(
  ProviderContainer c, {
  required List<String> recents,
}) async {
  expect(c.read(currentVaultProvider), isNull);
  expect(c.read(vaultDbProvider), isNull, reason: 'no SQLite handle');
  expect(c.read(settingsProvider).recentVaults, recents);
  expect(c.read(settingsProvider).lastVault, isNull);
  final prefs = await SharedPreferences.getInstance();
  expect(prefs.getString('memex.last_vault'), isNull);
  expect(prefs.getStringList('memex.recent_vaults'), recents);
}

void main() {
  group('open local vault checks first', () {
    test(
      'openVault runs vault check first and opens nothing until it returns',
      () async {
        final vault = createVaultFolder('om92_open_');
        final other = createVaultFolder('om92_other_');
        final gate = Completer<MemexResult>();
        final cli = FakeMemexCli()
          ..on('vault check', _gated(gate))
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _app(cli: cli, recents: [other.path]);

        final pending = c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));
        await pumpEventQueue();

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);
        await _expectNothingOpened(c, recents: [other.path]);

        gate.complete(FakeMemexCli.ok());
        final outcome = await pending;

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(vault.path),
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(c.read(settingsProvider).lastVault, vault.path);
        expect(c.read(settingsProvider).recentVaults, [vault.path, other.path]);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('memex.last_vault'), vault.path);
        expect(prefs.getStringList('memex.recent_vaults'), [
          vault.path,
          other.path,
        ]);
      },
    );

    test(
      'createLocalVault runs vault check on the target path before memex init',
      () async {
        final parent = createPlainFolder('om92_parent_');
        final target = p.join(parent.path, 'MyMemex');
        final gate = Completer<MemexResult>();
        final cli = FakeMemexCli()
          ..on('vault check', _gated(gate))
          ..on('init', _init)
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _app(cli: cli);

        final pending = c
            .read(vaultOpenControllerProvider)
            .createLocalVault(target);
        await pumpEventQueue();

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, ['vault', 'check', '--vault', target]);
        expect(cli.callsFor('init'), isEmpty);
        expect(Directory(target).existsSync(), isFalse);
        await _expectNothingOpened(c, recents: const []);

        gate.complete(FakeMemexCli.ok());
        final outcome = await pending;

        expect(outcome, isA<VaultOpened>());
        expect(cli.calls.map((call) => call.subcommand).toList(), [
          'vault check',
          'init',
        ]);
        expect(cli.callsFor('init').single.args, ['init', target]);
        expect(c.read(currentVaultProvider), LocalVaultRef(target));
        expect(c.read(settingsProvider).recentVaults, [target]);
      },
    );
  });

  group('vault check outcomes for open', () {
    for (final (name, handler, matcher) in [
      (
        'openVault on a network drive is the network drive refusal and opens nothing',
        (FakeCliCall _) => FakeMemexCli.error(
          'network_filesystem',
          'the vault folder is on a network filesystem',
        ),
        isA<VaultOnNetworkDrive>(),
      ),
      (
        'openVault with a memex that exits 2 is the too old refusal and opens nothing',
        (FakeCliCall _) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
        isA<VaultMemexTooOld>(),
      ),
      (
        'openVault when spawning memex throws is binary not found and opens nothing',
        _spawnFailure,
        isA<VaultBinaryNotFound>(),
      ),
    ]) {
      test(name, () async {
        final vault = createVaultFolder('om92_refused_');
        final other = createVaultFolder('om92_other_');
        final cli = FakeMemexCli()
          ..on('vault check', handler)
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _app(cli: cli, recents: [other.path]);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));

        expect(outcome, matcher);
        await _expectNothingOpened(c, recents: [other.path]);
        expect(cli.calls.map((call) => call.subcommand).toList(), [
          'vault check',
        ]);
        expect(File(p.join(vault.path, 'memex.db-wal')).existsSync(), isFalse);
        expect(File(p.join(vault.path, 'memex.db-shm')).existsSync(), isFalse);
      });
    }

    test('a refusal outcome carries the refused folder path', () async {
      final vault = createVaultFolder('om92_path_');
      final cli = FakeMemexCli()
        ..on(
          'vault check',
          (_) => FakeMemexCli.error('network_filesystem', 'network'),
        );
      final c = await _app(cli: cli);
      final drive = await c
          .read(vaultOpenControllerProvider)
          .openVault(LocalVaultRef(vault.path));
      expect(drive, isA<VaultOnNetworkDrive>());
      expect((drive as VaultOnNetworkDrive).path, vault.path);

      cli.on(
        'vault check',
        (_) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
      );
      final old = await c
          .read(vaultOpenControllerProvider)
          .openVault(LocalVaultRef(vault.path));
      expect(old, isA<VaultMemexTooOld>());
      expect((old as VaultMemexTooOld).path, vault.path);
    });

    for (final (name, result, text) in [
      (
        'openVault with exit 1 and C1 not_found is the plain open error and opens nothing',
        FakeMemexCli.error('not_found', 'no such folder here'),
        'no such folder here',
      ),
      (
        'openVault with exit 1 and non-JSON stderr is the plain open error and opens nothing',
        FakeMemexCli.failure('something odd happened\n'),
        'something odd happened',
      ),
      (
        'openVault with exit 3 and C1 network_filesystem is the plain open error and opens nothing',
        FakeMemexCli.failure(
          '{"error":{"code":"network_filesystem","message":"odd exit"}}\n',
          exitCode: 3,
        ),
        'odd exit',
      ),
    ]) {
      test(name, () async {
        final vault = createVaultFolder('om92_failed_');
        final cli = FakeMemexCli()..on('vault check', (_) => result);
        final c = await _app(cli: cli);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));

        expect(outcome, isA<VaultOpenFailure>());
        expect(outcome, isNot(isA<VaultOnNetworkDrive>()));
        expect(outcome, isNot(isA<VaultMemexTooOld>()));
        expect(outcome, isNot(isA<VaultBinaryNotFound>()));
        expect((outcome as VaultOpenFailure).message, contains(text));
        await _expectNothingOpened(c, recents: const []);
      });
    }

    test(
      'openVault with no memex binary configured is binary not found and opens nothing',
      () async {
        final vault = createVaultFolder('om92_nocli_');
        final c = await _app(cli: null, binaryPath: '');
        expect(c.read(memexCliProvider), isNull);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));

        expect(outcome, isA<VaultBinaryNotFound>());
        await _expectNothingOpened(c, recents: const []);
      },
    );
  });

  group('vault check outcomes for create', () {
    for (final (name, handler, matcher) in [
      (
        'createLocalVault on a network drive is the refusal and never runs init',
        (FakeCliCall _) => FakeMemexCli.error('network_filesystem', 'network'),
        isA<VaultOnNetworkDrive>(),
      ),
      (
        'createLocalVault with a memex that exits 2 is the too old refusal and never runs init',
        (FakeCliCall _) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
        isA<VaultMemexTooOld>(),
      ),
      (
        'createLocalVault when spawning memex throws is binary not found and never runs init',
        _spawnFailure,
        isA<VaultBinaryNotFound>(),
      ),
      (
        'createLocalVault with exit 1 and C1 not_found fails and never runs init',
        (FakeCliCall _) => FakeMemexCli.error('not_found', 'no parent'),
        isA<VaultOpenFailure>(),
      ),
    ]) {
      test(name, () async {
        final parent = createPlainFolder('om92_parent_');
        final target = p.join(parent.path, 'MyMemex');
        final cli = FakeMemexCli()
          ..on('vault check', handler)
          ..on('init', _init);
        final c = await _app(cli: cli);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(target);

        expect(outcome, matcher);
        expect(outcome, isNot(isA<VaultOpened>()));
        expect(cli.callsFor('init'), isEmpty);
        expect(Directory(target).existsSync(), isFalse);
        await _expectNothingOpened(c, recents: const []);
      });
    }

    test(
      'a create refusal carries the target vault path not its parent folder',
      () async {
        final parent = createPlainFolder('om92_parent_');
        final target = p.join(parent.path, 'OnNas');
        final cli = FakeMemexCli()
          ..on(
            'vault check',
            (_) => FakeMemexCli.error('network_filesystem', 'network'),
          );
        final c = await _app(cli: cli);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(target);

        expect((outcome as VaultOnNetworkDrive).path, target);
        expect(cli.calls.single.flag('vault'), target);
      },
    );

    test(
      'createLocalVault with no memex binary configured is binary not found and creates nothing',
      () async {
        final parent = createPlainFolder('om92_parent_');
        final target = p.join(parent.path, 'NoCli');
        final c = await _app(cli: null, binaryPath: '');

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(target);

        expect(outcome, isA<VaultBinaryNotFound>());
        expect(Directory(target).existsSync(), isFalse);
        await _expectNothingOpened(c, recents: const []);
      },
    );
  });

  group('the binary path is re-read', () {
    test(
      'after a newer binary is stored the next open runs vault check with it and opens',
      () async {
        final vault = createVaultFolder('om92_retry_');
        final oldCli = FakeMemexCli()
          ..on(
            'vault check',
            (_) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
          );
        final newCli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok())
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _app(
          clis: {'old-memex': oldCli, '/opt/staging/memex': newCli},
          binaryPath: 'old-memex',
        );
        final controller = c.read(vaultOpenControllerProvider);

        final first = await controller.openVault(LocalVaultRef(vault.path));
        expect(first, isA<VaultMemexTooOld>());
        expect(c.read(currentVaultProvider), isNull);

        await c
            .read(settingsProvider.notifier)
            .setMemexBinary('/opt/staging/memex');
        final second = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));

        expect(second, isA<VaultOpened>());
        expect(oldCli.callsFor('vault check'), hasLength(1));
        expect(newCli.callsFor('vault check'), hasLength(1));
        expect(newCli.calls.first.subcommand, 'vault check');
        expect(c.read(currentVaultProvider), LocalVaultRef(vault.path));
      },
    );

    test(
      'a controller read before the binary changed still uses the new binary',
      () async {
        final vault = createVaultFolder('om92_cached_');
        final oldCli = FakeMemexCli()
          ..on(
            'vault check',
            (_) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
          );
        final newCli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok());
        final c = await _app(
          clis: {'old-memex': oldCli, '/opt/staging/memex': newCli},
          binaryPath: 'old-memex',
        );
        final controller = c.read(vaultOpenControllerProvider);
        expect(
          await controller.openVault(LocalVaultRef(vault.path)),
          isA<VaultMemexTooOld>(),
        );

        await c
            .read(settingsProvider.notifier)
            .setMemexBinary('/opt/staging/memex');
        // The same controller instance: no CLI handle may be cached in it.
        final again = await controller.openVault(LocalVaultRef(vault.path));

        expect(again, isA<VaultOpened>());
        expect(oldCli.callsFor('vault check'), hasLength(1));
        expect(newCli.callsFor('vault check'), hasLength(1));
      },
    );
  });

  group('existing local vaults open as today', () {
    test(
      'once vault check passes an existing V5 vault opens with one settings get after the check',
      () async {
        final vault = createVaultFolder('om92_v5_');
        final cli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok())
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final c = await _app(cli: cli);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(vault.path));
        expect(outcome, isA<VaultOpened>());
        final state = await c.read(vaultOpenProvider.future);

        expect(cli.calls.map((call) => call.subcommand).toList(), [
          'vault check',
          'settings get',
        ]);
        expect(cli.callsFor('settings get').single.args, [
          'settings',
          'get',
          '--vault',
          vault.path,
          '--key',
          'smart_folder_max_depth',
        ]);
        expect(state.schemaOutdated, isFalse);
        expect(state.smartFolderMaxDepth, 2);
        expect(c.read(vaultRevisionProvider), 1);
        expect(c.read(vaultDbProvider), isNotNull);
      },
    );
  });
}
