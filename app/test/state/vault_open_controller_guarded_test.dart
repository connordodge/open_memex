// WI #360 (Spec #357 TD2, Req 9, 28.3, 30): the controller additions the
// vault picker modal and the open-vault delete need.
// - `openVaultGuarded` asks the leave guard once; stay changes nothing,
//   allow is exactly `openVault` (folder check, remember).
// - `closeForDelete` clears the current vault and the selected note (the DB
//   handle goes with them) and leaves the last vault and recents alone.
// - `reopenAfterFailedDelete` reopens the way a pill switch does: no guard,
//   `memex vault check`, no folder shape check.
// Seams: FakeMemexCli (`vault check`), mock prefs, temp vault folders.
import 'dart:async';
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
import '../support/vault_folders.dart';

/// One app state: prefs with [recents] (most recent first, the first is the
/// last vault), [open] as the current vault (null: none), a recording guard
/// answering [allow], and [cli] as the memex binary.
class _Wi360App {
  _Wi360App(this.c, this.cli, this.guardContexts);

  final ProviderContainer c;
  final FakeMemexCli cli;

  /// The context each guard call was given, in order.
  final List<BuildContext> guardContexts;

  VaultOpenController get ctrl => c.read(vaultOpenControllerProvider);
  AppSettings get settings => c.read(settingsProvider);

  /// The settings state and every stored preference.
  Future<Map<String, Object?>> snapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'recentRefs': settings.recentRefs,
      'lastVaultRef': settings.lastVaultRef,
      'prefs': {for (final k in prefs.getKeys()) k: prefs.get(k)},
    };
  }
}

/// A CLI whose `memex vault check` answers [check] (default: safe).
FakeMemexCli _wi360Cli([MemexResult? check]) =>
    FakeMemexCli()..on('vault check', (_) => check ?? FakeMemexCli.ok());

Future<_Wi360App> _wi360Pump({
  required List<String> recents,
  String? open,
  bool allow = true,
  FakeMemexCli? cli,
  bool realDb = false,
}) async {
  SharedPreferences.setMockInitialValues({'memex.binary_path': 'fake-memex'});
  final settings = await SettingsController.load();
  for (final path in recents.reversed) {
    await settings.rememberVault(path);
  }
  final fake = cli ?? _wi360Cli();
  final contexts = <BuildContext>[];
  final c = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      memexCliProvider.overrideWithValue(fake),
      if (!realDb) vaultDbProvider.overrideWithValue(null),
      if (open != null)
        currentVaultProvider.overrideWith((_) => LocalVaultRef(open)),
      leaveVaultGuardProvider.overrideWithValue((ctx) async {
        contexts.add(ctx);
        return allow;
      }),
    ],
  );
  addTearDown(c.dispose);
  return _Wi360App(c, fake, contexts);
}

Future<BuildContext> _wi360Context(WidgetTester tester) async {
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

/// An outcome as comparable data: its type, its vault and its message.
Object? _wi360Shape(VaultOpenOutcome? o) => switch (o) {
  VaultOpened(:final vault) => ('opened', vault),
  VaultOpenFailure(:final message) => (o.runtimeType, message),
  null => null,
  _ => o.runtimeType,
};

void main() {
  group('openVaultGuarded', () {
    testWidgets(
      'openVaultGuarded with the guard saying stay completes VaultOpenCancelled and changes nothing',
      (tester) async {
        final open = createVaultFolder('om360_open_');
        final other = createVaultFolder('om360_other_');
        final context = await _wi360Context(tester);
        final app = (await tester.runAsync(
          () => _wi360Pump(
            recents: [open.path, other.path],
            open: open.path,
            allow: false,
          ),
        ))!;
        app.c.read(selectedNoteIdProvider.notifier).state = '01KEEP360';
        final before = (await tester.runAsync(app.snapshot))!;

        final outcome = await tester.runAsync(
          () => app.ctrl.openVaultGuarded(context, LocalVaultRef(other.path)),
        );

        expect(outcome, isA<VaultOpenCancelled>());
        expect(app.guardContexts, [same(context)], reason: 'asked once');
        expect(app.cli.calls, isEmpty, reason: 'no vault check ran');
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(app.c.read(selectedNoteIdProvider), '01KEEP360');
        expect(await tester.runAsync(app.snapshot), before);
      },
    );

    // Each case runs openVault in one app and openVaultGuarded (guard
    // allows) in a twin app: same outcome, same settings, same CLI calls.
    final cases = <(String, String Function(), MemexResult?)>[
      (
        'openVaultGuarded with the guard allowing opens a vault exactly as openVault does',
        () => createVaultFolder('om360_target_').path,
        null,
      ),
      (
        'openVaultGuarded with the guard allowing refuses a folder that is not a vault exactly as openVault does',
        () => createPlainFolder('om360_plain_').path,
        null,
      ),
      (
        'openVaultGuarded with the guard allowing reports a failed vault check exactly as openVault does',
        () => createVaultFolder('om360_refused_').path,
        FakeMemexCli.error('io', 'permission denied'),
      ),
    ];
    for (final (name, target, check) in cases) {
      testWidgets(name, (tester) async {
        final open = createVaultFolder('om360_open_');
        final path = target();
        final context = await _wi360Context(tester);

        Future<(Object?, Map<String, Object?>, List<List<String>>, VaultRef?)>
        run(Future<VaultOpenOutcome> Function(_Wi360App app) call) async {
          final app = (await tester.runAsync(
            () => _wi360Pump(
              recents: [open.path],
              open: open.path,
              cli: _wi360Cli(check),
            ),
          ))!;
          final outcome = await tester.runAsync(() => call(app));
          final snap = (await tester.runAsync(app.snapshot))!;
          return (
            _wi360Shape(outcome),
            snap,
            [for (final c in app.cli.calls) c.args],
            app.c.read(currentVaultProvider),
          );
        }

        final plain = await run(
          (app) => app.ctrl.openVault(LocalVaultRef(path)),
        );
        late _Wi360App guardedApp;
        final guarded = await run((app) {
          guardedApp = app;
          return app.ctrl.openVaultGuarded(context, LocalVaultRef(path));
        });

        expect(guardedApp.guardContexts, [same(context)], reason: 'asked once');
        expect(guarded.$1, plain.$1, reason: 'same outcome');
        expect(guarded.$2, plain.$2, reason: 'same settings writes');
        expect(guarded.$3, plain.$3, reason: 'same memex calls');
        expect(guarded.$4, plain.$4, reason: 'same current vault');
      });
    }

    testWidgets(
      'openVaultGuarded with the guard allowing remembers the opened vault first in the recents and as the last vault',
      (tester) async {
        final open = createVaultFolder('om360_open_');
        final other = createVaultFolder('om360_other_');
        final context = await _wi360Context(tester);
        final app = (await tester.runAsync(
          () => _wi360Pump(recents: [open.path, other.path], open: open.path),
        ))!;

        final outcome = await tester.runAsync(
          () => app.ctrl.openVaultGuarded(context, LocalVaultRef(other.path)),
        );

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(other.path),
          ),
        );
        expect(app.c.read(currentVaultProvider), LocalVaultRef(other.path));
        expect(app.settings.lastVaultRef, LocalVaultRef(other.path));
        expect(app.settings.recentRefs, [
          LocalVaultRef(other.path),
          LocalVaultRef(open.path),
        ]);
        expect(
          app.cli.callsFor('vault check').single.args,
          contains(other.path),
        );
      },
    );
  });

  group('closeForDelete', () {
    test(
      'closeForDelete clears the current vault and the selected note and leaves the last vault and recents alone',
      () async {
        final open = createVaultFolder('om360_open_');
        final other = createVaultFolder('om360_other_');
        final app = await _wi360Pump(
          recents: [open.path, other.path],
          open: open.path,
        );
        app.c.read(selectedNoteIdProvider.notifier).state = '01NOTE360';
        final before = await app.snapshot();

        await app.ctrl.closeForDelete();

        expect(app.c.read(currentVaultProvider), isNull);
        expect(app.c.read(selectedNoteIdProvider), isNull);
        expect(await app.snapshot(), before);
        expect(app.settings.lastVaultRef, LocalVaultRef(open.path));
        expect(app.settings.recentRefs.first, LocalVaultRef(open.path));
        expect(app.guardContexts, isEmpty, reason: 'no guard of its own');
        expect(app.cli.calls, isEmpty);
      },
    );

    test('closeForDelete closes the open vault database handle', () async {
      final open = createVaultFolder('om360_open_');
      final app = await _wi360Pump(
        recents: [open.path],
        open: open.path,
        realDb: true,
      );
      // Read, not listened to: nothing rebuilds the provider on its own
      // until a frame, as in the app between a close and the next frame.
      final db = app.c.read(vaultDbProvider)!;
      expect(db.db.select('SELECT 1 AS one').single['one'], 1);

      // No await before the checks: the handle is closed by the time the
      // call returns, not on the next frame or microtask turn (the Trash
      // call follows at once and must find memex.db closed).
      final closed = app.ctrl.closeForDelete();

      expect(
        () => db.db.select('SELECT 1'),
        throwsA(anything),
        reason: 'the old handle is closed, so nothing holds memex.db open',
      );
      await closed;
      expect(
        app.c.read(vaultDbProvider),
        isNull,
        reason: 'no handle with no vault open',
      );
    });
  });

  group('reopenAfterFailedDelete', () {
    test(
      'reopenAfterFailedDelete reopens the vault without asking the guard and leaves the last vault and recents as they were',
      () async {
        final open = createVaultFolder('om360_open_');
        final other = createVaultFolder('om360_other_');
        final app = await _wi360Pump(
          recents: [open.path, other.path],
          open: open.path,
          allow: false,
        );
        app.c.read(selectedNoteIdProvider.notifier).state = '01NOTE360';
        final before = await app.snapshot();
        await app.ctrl.closeForDelete();

        final outcome = await app.ctrl.reopenAfterFailedDelete(
          LocalVaultRef(open.path),
        );

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(open.path),
          ),
        );
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(app.guardContexts, isEmpty, reason: 'the guard said stay');
        expect(app.cli.callsFor('vault check'), hasLength(1));
        expect(
          app.cli.callsFor('vault check').single.args,
          contains(open.path),
        );
        expect(await app.snapshot(), before);
        expect(app.c.read(selectedNoteIdProvider), isNull);
      },
    );

    test(
      'reopenAfterFailedDelete skips the folder shape check as a pill switch does',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(recents: [open.path], open: open.path);
        await app.ctrl.closeForDelete();
        // The isVault re-check failed: the folder lost its manifest.
        File(p.join(open.path, 'manifest.json')).deleteSync();

        final outcome = await app.ctrl.reopenAfterFailedDelete(
          LocalVaultRef(open.path),
        );

        expect(outcome, isA<VaultOpened>());
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(app.cli.callsFor('vault check'), hasLength(1));
      },
    );

    test(
      'reopenAfterFailedDelete that fails leaves no vault open and the last vault and recents as they were',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(
          recents: [open.path],
          open: open.path,
          cli: _wi360Cli(FakeMemexCli.error('io', 'permission denied')),
        );
        final before = await app.snapshot();
        await app.ctrl.closeForDelete();

        final outcome = await app.ctrl.reopenAfterFailedDelete(
          LocalVaultRef(open.path),
        );

        expect(outcome, isA<VaultOpenFailure>());
        expect(
          (outcome as VaultOpenFailure).message,
          contains('permission denied'),
        );
        expect(app.c.read(currentVaultProvider), isNull);
        expect(await app.snapshot(), before);
      },
    );
  });

  group('launchReopen while a delete has the vault closed', () {
    test(
      'launchReopen leaves the vault closed for its delete closed and asks nothing',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(recents: [open.path], open: open.path);
        await app.ctrl.closeForDelete();
        final before = await app.snapshot();

        final outcome = await app.ctrl.launchReopen();

        expect(outcome, isA<NoVaultToReopen>());
        expect(app.c.read(currentVaultProvider), isNull);
        expect(app.cli.calls, isEmpty, reason: 'no vault check, no open');
        expect(await app.snapshot(), before);
      },
    );

    test(
      'launchReopen reopens the last vault again once the reopen after a failed delete failed',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(
          recents: [open.path],
          open: open.path,
          cli: _wi360Cli(FakeMemexCli.error('io', 'permission denied')),
        );
        await app.ctrl.closeForDelete();
        await app.ctrl.reopenAfterFailedDelete(LocalVaultRef(open.path));
        expect(app.c.read(currentVaultProvider), isNull);
        app.cli.on('vault check', (_) => FakeMemexCli.ok());

        final outcome = await app.ctrl.launchReopen();

        expect(
          outcome,
          isA<VaultOpened>().having(
            (o) => o.vault,
            'vault',
            LocalVaultRef(open.path),
          ),
        );
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
      },
    );

    test(
      'launchReopen leaves the vault closed while the reopen after a failed delete is still checking it',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(recents: [open.path], open: open.path);
        final gate = Completer<void>();
        app.cli.on('vault check', (_) async {
          await gate.future;
          return FakeMemexCli.ok();
        });
        await app.ctrl.closeForDelete();
        final reopen = app.ctrl.reopenAfterFailedDelete(
          LocalVaultRef(open.path),
        );
        await pumpEventQueue();
        expect(app.cli.callsFor('vault check'), hasLength(1), reason: 'held');
        expect(app.c.read(currentVaultProvider), isNull);

        // The picker mounts meanwhile and asks for its launch reopen.
        final launch = await app.ctrl.launchReopen();

        expect(launch, isA<NoVaultToReopen>());
        expect(
          app.cli.callsFor('vault check'),
          hasLength(1),
          reason: 'no second open runs in parallel',
        );
        gate.complete();
        expect(await reopen, isA<VaultOpened>());
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
        expect(app.cli.callsFor('vault check'), hasLength(1));
      },
    );

    test(
      'launchReopen reopens the last vault again once the vault was opened again after its close for a delete',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(recents: [open.path], open: open.path);
        await app.ctrl.closeForDelete();
        expect(await app.ctrl.launchReopen(), isA<NoVaultToReopen>());

        // The person opens the same vault again, then leaves it.
        final opened = await app.ctrl.openVault(LocalVaultRef(open.path));
        expect(opened, isA<VaultOpened>());
        app.c.read(currentVaultProvider.notifier).state = null;

        final outcome = await app.ctrl.launchReopen();

        expect(outcome, isA<VaultOpened>());
        expect(app.c.read(currentVaultProvider), LocalVaultRef(open.path));
      },
    );

    test(
      'launchReopen reopens the last vault when no delete closed it',
      () async {
        final open = createVaultFolder('om360_open_');
        final app = await _wi360Pump(recents: [open.path]);

        final outcome = await app.ctrl.launchReopen();

        expect(outcome, isA<VaultOpened>());
        expect(app.cli.callsFor('vault check'), hasLength(1));
      },
    );
  });
}
