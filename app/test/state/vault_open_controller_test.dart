// WI #69 (D12): `state/vault_open_controller.dart` owns create and open of a
// local vault, with today's checks and copy (vault_picker.dart:138-181).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_folders.dart';

/// App state as `main()` builds it, with a fake CLI and database. The last
/// vault (if any) is open through `currentVaultProvider`'s default.
Future<ProviderContainer> _app({
  required FakeMemexCli? cli,
  List<Override> overrides = const [],
  String? lastVault,
  List<String> recents = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': recents,
    'memex.last_vault': ?lastVault,
  });
  final settings = await SettingsController.load();
  final db = FakeVaultDb.v5();
  final c = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      memexCliProvider.overrideWithValue(cli),
      vaultDbProvider.overrideWithValue(db),
      ...overrides,
    ],
  );
  addTearDown(db.close);
  addTearDown(c.dispose);
  return c;
}

/// A CLI whose `init` creates the vault files, as the real `memex init` does.
FakeMemexCli _initCli() => FakeMemexCli()
  ..on('init', (call) {
    initVaultFolder(call.args[1]);
    return FakeMemexCli.ok();
  })
  ..on('settings get', (_) => FakeMemexCli.ok('{"value":2}'));

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

void main() {
  group('createLocalVault (AC3)', () {
    test(
      'createLocalVault runs memex init and opens the new vault as a LocalVaultRef',
      () async {
        final parent = createPlainFolder('om69_parent_');
        final path = p.join(parent.path, 'MyMemex');
        final cli = _initCli();
        final c = await _app(cli: cli);
        expect(c.read(currentVaultProvider), isNull);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(path);

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(path),
          ),
        );
        final inits = cli.callsFor('init');
        expect(inits, hasLength(1));
        expect(inits.single.args, ['init', path]);
        expect(c.read(currentVaultProvider), LocalVaultRef(path));
        final settings = c.read(settingsProvider);
        expect(settings.lastVault, path);
        expect(settings.recentVaults.first, path);
        // Remembered on disk too, for the next launch.
        final prefs = await _prefs();
        expect(prefs.getString('memex.last_vault'), path);
        expect(prefs.getStringList('memex.recent_vaults')!.first, path);
      },
    );

    test(
      'createLocalVault into an existing empty folder still creates',
      () async {
        final dir = createPlainFolder('om69_empty_');
        final cli = _initCli();
        final c = await _app(cli: cli);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(dir.path);

        expect(outcome, isA<VaultOpened>());
        expect(cli.callsFor('init'), hasLength(1));
        expect(c.read(currentVaultProvider), LocalVaultRef(dir.path));
      },
    );

    test(
      'createLocalVault into a non-empty folder fails without calling init',
      () async {
        final open = createVaultFolder('om69_open_');
        final dir = createPlainFolder('om69_full_');
        File(p.join(dir.path, 'notes.txt')).writeAsStringSync('hi');
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: open.path,
          recents: [open.path],
        );

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(dir.path);

        expect(
          outcome,
          isA<VaultOpenFailure>().having(
            (o) => o.message,
            'message',
            '${dir.path} already exists and is not empty.',
          ),
        );
        expect(cli.callsFor('init'), isEmpty);
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, open.path);
        expect(c.read(settingsProvider).recentVaults, [open.path]);
      },
    );

    test(
      'createLocalVault reports an init failure as Could not create vault',
      () async {
        final open = createVaultFolder('om69_open_');
        final parent = createPlainFolder('om69_parent_');
        final path = p.join(parent.path, 'Broken');
        final failure = FakeMemexCli.error('io', 'permission denied');
        final cli = FakeMemexCli()..on('init', (_) => failure);
        final c = await _app(
          cli: cli,
          lastVault: open.path,
          recents: [open.path],
        );

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(path);

        // Today's copy: the caught error's own text after the prefix.
        final expected =
            'Could not create vault: '
            '${MemexException.fromCliFailure('init', failure)}';
        expect(
          outcome,
          isA<VaultOpenFailure>().having((o) => o.message, 'message', expected),
        );
        expect(
          (outcome as VaultOpenFailure).message,
          startsWith('Could not create vault: '),
        );
        expect(cli.callsFor('init'), hasLength(1));
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, open.path);
        expect(c.read(settingsProvider).recentVaults, [open.path]);
      },
    );
  });

  group('openVault (AC4)', () {
    test(
      'openVault on a folder without manifest and db leaves the current vault and says why',
      () async {
        final open = createVaultFolder('om69_open_');
        final plain = createPlainFolder('om69_notvault_');
        // Only one of the two files: still not a vault.
        File(p.join(plain.path, 'manifest.json')).writeAsStringSync('{}');
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: open.path,
          recents: [open.path],
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(plain.path));

        expect(
          outcome,
          isA<VaultOpenFailure>().having(
            (o) => o.message,
            'message',
            '${plain.path} does not look like a vault (no manifest.json + memex.db).',
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, open.path);
        expect(c.read(settingsProvider).recentVaults, [open.path]);
        expect(cli.callsFor('init'), isEmpty);
      },
    );

    test(
      'openVault on a vault folder remembers it and opens it as a LocalVaultRef',
      () async {
        final first = createVaultFolder('om69_first_');
        final second = createVaultFolder('om69_second_');
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: first.path,
          recents: [first.path],
        );

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(LocalVaultRef(second.path));

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(second.path),
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(second.path));
        final settings = c.read(settingsProvider);
        expect(settings.lastVault, second.path);
        expect(settings.recentVaults, [second.path, first.path]);
        final prefs = await _prefs();
        expect(prefs.getString('memex.last_vault'), second.path);
        expect(cli.callsFor('init'), isEmpty);
      },
    );

    test('openVault with no vault open opens the chosen vault', () async {
      final dir = createVaultFolder('om69_fresh_');
      final c = await _app(cli: _initCli());
      expect(c.read(currentVaultProvider), isNull);

      final outcome = await c
          .read(vaultOpenControllerProvider)
          .openVault(LocalVaultRef(dir.path));

      expect(outcome, isA<VaultOpened>());
      expect(c.read(currentVaultProvider), LocalVaultRef(dir.path));
      expect(c.read(settingsProvider).recentVaults, [dir.path]);
    });
  });

  group('controller contracts (verify)', () {
    test(
      'openVault of a HostedVaultRef fails as not openable yet and changes nothing',
      () async {
        final open = createVaultFolder('om69_open_');
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: open.path,
          recents: [open.path],
        );
        final hosted = HostedVaultRef(['srv', '1'].join('-'), 'work');

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(hosted);

        expect(
          outcome,
          isA<VaultOpenFailure>().having(
            (o) => o.message,
            'message',
            'Hosted vaults cannot be opened yet.',
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, open.path);
        expect(c.read(settingsProvider).recentVaults, [open.path]);
        final prefs = await _prefs();
        expect(prefs.getString('memex.last_vault'), open.path);
        expect(prefs.getStringList('memex.recent_vaults'), [open.path]);
        expect(cli.calls, isEmpty);
      },
    );

    test(
      'openVault of a HostedVaultRef with no vault open leaves no vault open',
      () async {
        final c = await _app(cli: _initCli());

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .openVault(HostedVaultRef('srv-1', 'work'));

        expect(outcome, isA<VaultOpenFailure>());
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(settingsProvider).recentVaults, isEmpty);
        expect(c.read(settingsProvider).lastVault, isNull);
      },
    );

    test(
      'createLocalVault with no memex binary fails without creating anything',
      () async {
        final open = createVaultFolder('om69_open_');
        final parent = createPlainFolder('om69_parent_');
        final path = p.join(parent.path, 'NoCli');
        final c = await _app(
          cli: null,
          lastVault: open.path,
          recents: [open.path],
        );
        expect(c.read(memexCliProvider), isNull);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(path);

        expect(
          outcome,
          isA<VaultOpenFailure>().having(
            (o) => o.message,
            'message',
            'Could not create vault: no memex binary is configured.',
          ),
        );
        expect(Directory(path).existsSync(), isFalse);
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, open.path);
        expect(c.read(settingsProvider).recentVaults, [open.path]);
      },
    );

    test(
      'createLocalVault into a non-empty folder with no memex binary reports the folder first',
      () async {
        final dir = createPlainFolder('om69_full_');
        File(p.join(dir.path, 'notes.txt')).writeAsStringSync('hi');
        final c = await _app(cli: null);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .createLocalVault(dir.path);

        expect(
          outcome,
          isA<VaultOpenFailure>().having(
            (o) => o.message,
            'message',
            '${dir.path} already exists and is not empty.',
          ),
        );
        expect(c.read(currentVaultProvider), isNull);
      },
    );

    for (final (name, allow) in [
      ('leaveVault completes true when the guard allows', true),
      ('leaveVault completes false when the guard denies', false),
    ]) {
      testWidgets(name, (tester) async {
        final open = createVaultFolder('om69_open_');
        var asked = 0;
        late BuildContext context;
        await tester.pumpWidget(
          Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox();
            },
          ),
        );
        final c = await tester.runAsync(
          () => _app(
            cli: _initCli(),
            lastVault: open.path,
            recents: [open.path],
            overrides: [
              leaveVaultGuardProvider.overrideWithValue((ctx) async {
                expect(ctx, same(context));
                asked++;
                return allow;
              }),
            ],
          ),
        );
        c!.read(selectedNoteIdProvider.notifier).state = '01KEEP';

        final left = await tester.runAsync(
          () => c.read(vaultOpenControllerProvider).leaveVault(context),
        );

        expect(left, allow);
        expect(asked, 1);
        if (allow) {
          expect(c.read(currentVaultProvider), isNull);
          expect(c.read(settingsProvider).lastVault, isNull);
          expect(c.read(selectedNoteIdProvider), isNull);
        } else {
          expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
          expect(c.read(settingsProvider).lastVault, open.path);
          expect(c.read(selectedNoteIdProvider), '01KEEP');
        }
      });
    }

    for (final (name, allow) in [
      ('switchToVault completes VaultOpened when the guard allows', true),
      (
        'switchToVault completes VaultOpenCancelled when the guard denies',
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final open = createVaultFolder('om69_open_');
        final other = createVaultFolder('om69_other_');
        var asked = 0;
        late BuildContext context;
        await tester.pumpWidget(
          Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox();
            },
          ),
        );
        final c = await tester.runAsync(
          () => _app(
            cli: _initCli(),
            lastVault: open.path,
            recents: [open.path],
            overrides: [
              leaveVaultGuardProvider.overrideWithValue((ctx) async {
                expect(ctx, same(context));
                asked++;
                return allow;
              }),
            ],
          ),
        );
        c!.read(selectedNoteIdProvider.notifier).state = '01KEEP';

        final switched = await tester.runAsync(
          () => c
              .read(vaultOpenControllerProvider)
              .switchToVault(context, LocalVaultRef(other.path)),
        );

        expect(asked, 1);
        if (allow) {
          expect(
            switched,
            isA<VaultOpened>().having(
              (o) => o.vault,
              'vault',
              LocalVaultRef(other.path),
            ),
          );
          expect(c.read(currentVaultProvider), LocalVaultRef(other.path));
          expect(c.read(settingsProvider).lastVault, other.path);
          expect(c.read(settingsProvider).recentVaults, [
            other.path,
            open.path,
          ]);
          expect(c.read(selectedNoteIdProvider), isNull);
        } else {
          expect(switched, isA<VaultOpenCancelled>());
          expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
          expect(c.read(settingsProvider).lastVault, open.path);
          expect(c.read(settingsProvider).recentVaults, [open.path]);
          expect(c.read(selectedNoteIdProvider), '01KEEP');
          final prefs = await tester.runAsync(_prefs);
          expect(prefs!.getString('memex.last_vault'), open.path);
          expect(prefs.getStringList('memex.recent_vaults'), [open.path]);
        }
      });
    }

    testWidgets('leaveVault uses the default guard and completes true', (
      tester,
    ) async {
      final open = createVaultFolder('om69_open_');
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox();
          },
        ),
      );
      final c = await tester.runAsync(
        () => _app(cli: _initCli(), lastVault: open.path),
      );

      final left = await tester.runAsync(
        () => c!.read(vaultOpenControllerProvider).leaveVault(context),
      );

      expect(left, isTrue);
      expect(c!.read(currentVaultProvider), isNull);
    });
  });
}
