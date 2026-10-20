// WI #69 (D12): `state/vault_open_controller.dart` owns create and open of a
// local vault, with today's checks and copy (vault_picker.dart:138-181).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_clock.dart';
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
  // #92: every local open runs `memex vault check` first; the folder is safe.
  ..on('vault check', (_) => FakeMemexCli.ok())
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
        final cli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok())
          ..on('init', (_) => failure);
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

  group('launchReopen (review round 1)', () {
    test(
      'launchReopen with a vault open completes VaultOpened with it and writes nothing',
      () async {
        final open = createVaultFolder('om69_open_');
        final other = createVaultFolder('om69_other_');
        // The open vault is not first in the recents: a rememberVault would
        // move it to the front.
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: open.path,
          recents: [other.path, open.path],
        );
        final before = c.read(currentVaultProvider);
        expect(before, LocalVaultRef(open.path));
        var notified = 0;
        c.listen(currentVaultProvider, (_, _) => notified++);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .launchReopen();

        expect(
          outcome,
          isA<VaultOpened>().having((o) => o.vault, 'vault', same(before)),
        );
        expect(c.read(currentVaultProvider), same(before));
        expect(notified, 0);
        expect(c.read(settingsProvider).recentVaults, [other.path, open.path]);
        final prefs = await _prefs();
        expect(prefs.getStringList('memex.recent_vaults'), [
          other.path,
          open.path,
        ]);
        expect(prefs.getString('memex.last_vault'), open.path);
        expect(cli.calls, isEmpty);
      },
    );

    test(
      'launchReopen keeps an open vault that is not the last vault',
      () async {
        final open = createVaultFolder('om69_open_');
        final last = createVaultFolder('om69_last_');
        final c = await _app(
          cli: _initCli(),
          lastVault: last.path,
          recents: [last.path, open.path],
          overrides: [
            currentVaultProvider.overrideWith((_) => LocalVaultRef(open.path)),
          ],
        );

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .launchReopen();

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(open.path),
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(c.read(settingsProvider).lastVault, last.path);
      },
    );

    test(
      'launchReopen with no vault open and a last vault opens it without a folder check or settings write',
      () async {
        // Not a vault folder: launch has never checked it (#92 adds that).
        final last = createPlainFolder('om69_last_plain_');
        final other = createVaultFolder('om69_other_');
        final cli = _initCli();
        final c = await _app(
          cli: cli,
          lastVault: last.path,
          recents: [other.path, last.path],
          overrides: [currentVaultProvider.overrideWith((_) => null)],
        );
        expect(c.read(currentVaultProvider), isNull);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .launchReopen();

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(last.path),
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(last.path));
        final settings = c.read(settingsProvider);
        expect(settings.lastVault, last.path);
        expect(settings.recentVaults, [other.path, last.path]);
        final prefs = await _prefs();
        expect(prefs.getStringList('memex.recent_vaults'), [
          other.path,
          last.path,
        ]);
        expect(cli.calls, isEmpty);
      },
    );

    test(
      'launchReopen with no vault open and no last vault completes NoVaultToReopen',
      () async {
        final other = createVaultFolder('om69_other_');
        final c = await _app(cli: _initCli(), recents: [other.path]);
        expect(c.read(currentVaultProvider), isNull);
        var notified = 0;
        c.listen(currentVaultProvider, (_, _) => notified++);

        final outcome = await c
            .read(vaultOpenControllerProvider)
            .launchReopen();

        expect(outcome, isA<NoVaultToReopen>());
        expect(c.read(currentVaultProvider), isNull);
        expect(notified, 0);
        expect(c.read(settingsProvider).lastVault, isNull);
        expect(c.read(settingsProvider).recentVaults, [other.path]);
      },
    );
  });

  group('switchToVault (review round 1)', () {
    testWidgets(
      'switchToVault with the default guard opens a pill folder that is not a vault without checking it',
      (tester) async {
        final open = createVaultFolder('om69_open_');
        final plain = createPlainFolder('om69_pill_plain_');
        final context = await _wi69Context(tester);
        // No guard override: the default guard is read as shipped.
        final c = await tester.runAsync(
          () => _app(
            cli: _initCli(),
            lastVault: open.path,
            recents: [open.path, plain.path],
          ),
        );
        c!.read(selectedNoteIdProvider.notifier).state = '01KEEP';

        final outcome = await tester.runAsync(
          () => c
              .read(vaultOpenControllerProvider)
              .switchToVault(context, LocalVaultRef(plain.path)),
        );

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(plain.path),
          ),
        );
        expect(c.read(currentVaultProvider), LocalVaultRef(plain.path));
        expect(c.read(settingsProvider).lastVault, plain.path);
        expect(c.read(settingsProvider).recentVaults, [plain.path, open.path]);
        expect(c.read(selectedNoteIdProvider), isNull);
      },
    );
  });

  group('current vault notifications (review round 1)', () {
    test(
      'a settings write that keeps the last vault notifies no current vault dependent',
      () async {
        final open = createVaultFolder('om69_open_');
        final other = createVaultFolder('om69_other_');
        SharedPreferences.setMockInitialValues({
          'memex.binary_path': 'fake-memex',
          'memex.recent_vaults': [open.path, other.path],
          'memex.last_vault': open.path,
        });
        final settings = await SettingsController.load();
        // The real vaultDbProvider and tabsProvider: only the settings, the
        // CLI and the clock are faked.
        final c = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith((_) => settings),
            memexCliProvider.overrideWithValue(null),
            clockProvider.overrideWithValue(FakeClock()),
          ],
        );
        addTearDown(c.dispose);
        final vault = c.read(currentVaultProvider);
        final db = c.read(vaultDbProvider);
        expect(db, isNotNull);
        final store = c.read(uiStateStoreProvider);
        final tabs = c.read(tabsProvider.notifier);
        // Let the tabs notifier emit its first selection, then pick a note.
        await Future<void>.delayed(Duration.zero);
        c.read(selectedNoteIdProvider.notifier).state = '01KEEP';
        var vaultNotified = 0;
        var dbNotified = 0;
        var selectionNotified = 0;
        c.listen(currentVaultProvider, (_, _) => vaultNotified++);
        c.listen(vaultDbProvider, (_, _) => dbNotified++);
        c.listen(selectedNoteIdProvider, (_, _) => selectionNotified++);

        await settings.setMemexBinary('/elsewhere/memex');
        await settings.forgetVault(other.path);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(settingsProvider).memexBinaryPath, '/elsewhere/memex');
        expect(c.read(settingsProvider).recentVaults, [open.path]);
        expect(vaultNotified, 0);
        expect(dbNotified, 0);
        expect(selectionNotified, 0);
        expect(c.read(currentVaultProvider), same(vault));
        expect(c.read(vaultDbProvider), same(db));
        expect(c.read(uiStateStoreProvider), same(store));
        expect(c.read(tabsProvider.notifier), same(tabs));
        expect(c.read(selectedNoteIdProvider), '01KEEP');
      },
    );

    testWidgets('a pill switch notifies current vault listeners once', (
      tester,
    ) async {
      final open = createVaultFolder('om69_open_');
      final other = createVaultFolder('om69_other_');
      final context = await _wi69Context(tester);
      final c = await tester.runAsync(
        () => _app(
          cli: _initCli(),
          lastVault: open.path,
          recents: [open.path, other.path],
        ),
      );
      final seen = <VaultRef?>[];
      c!.listen(currentVaultProvider, (_, next) => seen.add(next));

      await tester.runAsync(
        () => c
            .read(vaultOpenControllerProvider)
            .switchToVault(context, LocalVaultRef(other.path)),
      );

      expect(seen, [LocalVaultRef(other.path)]);
    });

    test('openVault notifies current vault listeners once', () async {
      final open = createVaultFolder('om69_open_');
      final other = createVaultFolder('om69_other_');
      final c = await _app(
        cli: _initCli(),
        lastVault: open.path,
        recents: [open.path],
      );
      final seen = <VaultRef?>[];
      c.listen(currentVaultProvider, (_, next) => seen.add(next));

      await c
          .read(vaultOpenControllerProvider)
          .openVault(LocalVaultRef(other.path));

      expect(seen, [LocalVaultRef(other.path)]);
    });

    test('opening the vault already open notifies no listener', () async {
      final open = createVaultFolder('om69_open_');
      final c = await _app(
        cli: _initCli(),
        lastVault: open.path,
        recents: [open.path],
      );
      final before = c.read(currentVaultProvider);
      var notified = 0;
      c.listen(currentVaultProvider, (_, _) => notified++);

      final outcome = await c
          .read(vaultOpenControllerProvider)
          .openVault(LocalVaultRef(open.path));

      expect(outcome, isA<VaultOpened>());
      expect(notified, 0);
      expect(c.read(currentVaultProvider), same(before));
    });
  });
}

/// A widget context for the guard (it takes a BuildContext).
Future<BuildContext> _wi69Context(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    Builder(
      builder: (ctx) {
        context = ctx;
        return const SizedBox();
      },
    ),
  );
  return context;
}
