// WI #360 (Spec #357 Req 28-30, TD3, TD3a): `VaultDeleter.deleteOpenVault`
// deletes the open local vault in order: the leave guard (once), the
// editor's flushPendingSave, the close (current vault and selected note
// null), the settle (the editor's in-flight saves of that vault and the
// vault's UI state writes), and only then `VaultTrash.trash` through the
// unchanged `VaultDeleter.delete`. On success no vault is open and the
// vault is forgotten; on any failure it reopens with the last vault and
// recents untouched. Seams: a recording EditorController subclass (its
// flushPendingSave and savesSettled record and can hold), a recording
// FakeVaultTrash, a recording guard, FakeMemexCli (`vault check`), mock
// prefs and real temp vault folders. Never a real Trash or vault.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_delete.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_trash.dart';
import '../support/vault_folders.dart';

/// The editor with its two delete-time calls recorded into [events]:
/// `flush open=<current vault path or null>`, `settle <path>` and
/// `settled <path>`. [settleHold], when set, holds savesSettled.
class _Wi360Editor extends EditorController {
  _Wi360Editor(super.ref, this._events) : _r = ref;

  final Ref _r;
  final List<String> _events;
  Completer<void>? settleHold;

  /// When set, savesSettled throws it after the close.
  Object? settleError;

  @override
  void flushPendingSave() {
    _events.add('flush open=${_r.read(currentVaultProvider).localPath}');
    super.flushPendingSave();
  }

  @override
  Future<void> savesSettled(VaultRef vault) async {
    _events.add('settle ${vault.localPath}');
    await super.savesSettled(vault);
    final hold = settleHold;
    if (hold != null) await hold.future;
    final error = settleError;
    if (error != null) throw error;
    _events.add('settled ${vault.localPath}');
  }
}

/// A Trash seam that also records `trash <path>` into [events].
class _Wi360Trash extends FakeVaultTrash {
  _Wi360Trash(this._events);

  final List<String> _events;

  /// Runs as the Trash call comes in, before it answers.
  void Function(String path)? onTrash;

  @override
  Future<TrashResult> trash(String path) {
    _events.add('trash $path');
    onTrash?.call(path);
    return super.trash(path);
  }
}

class _Wi360Rig {
  _Wi360Rig(this.c, this.vault, this.other, this.events, this.trash, this.cli);

  final ProviderContainer c;
  final String vault;
  final String other;
  final List<String> events;
  final _Wi360Trash trash;
  final FakeMemexCli cli;

  /// The guard's answer and every context it was given.
  bool allow = true;
  final List<BuildContext> guardCalls = [];

  _Wi360Editor get editor =>
      c.read(editorControllerProvider.notifier) as _Wi360Editor;
  AppSettings get settings => c.read(settingsProvider);
  VaultDeleter get deleter => c.read(vaultDeleterProvider);

  /// Every store a failed delete must leave alone.
  Future<Map<String, Object?>> snapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'recentRefs': settings.recentRefs,
      'lastVaultRef': settings.lastVaultRef,
      'vaultBackups': settings.vaultBackups,
      'prefs': {for (final k in prefs.getKeys()) k: prefs.get(k)},
    };
  }
}

/// Two vault folders; [_Wi360Rig.vault] is open, first in the recents and
/// the last vault. [check] is what `memex vault check` answers on a reopen.
Future<_Wi360Rig> _wi360Create({MemexResult? check}) async {
  final vault = createVaultFolder('om360_open_').path;
  final other = createVaultFolder('om360_other_').path;
  SharedPreferences.setMockInitialValues({'memex.binary_path': 'fake-memex'});
  final settings = await SettingsController.load();
  await settings.rememberVault(other);
  await settings.rememberVault(vault);
  final events = <String>[];
  final trash = _Wi360Trash(events);
  final cli = FakeMemexCli()
    ..on('vault check', (_) => check ?? FakeMemexCli.ok());
  late _Wi360Rig rig;
  final c = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      memexCliProvider.overrideWithValue(cli),
      vaultTrashProvider.overrideWithValue(trash),
      currentVaultProvider.overrideWith((_) => LocalVaultRef(vault)),
      editorControllerProvider.overrideWith((ref) => _Wi360Editor(ref, events)),
      leaveVaultGuardProvider.overrideWithValue((ctx) async {
        rig.guardCalls.add(ctx);
        events.add('guard');
        return rig.allow;
      }),
    ],
  );
  rig = _Wi360Rig(c, vault, other, events, trash, cli);
  // The editor and the vault database live while a vault is open.
  c.listen(editorControllerProvider, (_, _) {});
  c.listen(vaultDbProvider, (_, _) {});
  c.listen<VaultRef?>(currentVaultProvider, (_, next) {
    events.add('current ${next.localPath}');
  });
  c.listen<String?>(selectedNoteIdProvider, (_, next) {
    events.add('selected $next');
  });
  c.read(selectedNoteIdProvider.notifier).state = '01NOTE360';
  events.clear();
  addTearDown(() async {
    await UiStateStore(vaultPath: vault).flush();
    c.dispose();
  });
  return rig;
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

int _at(List<String> events, String event) {
  final i = events.indexOf(event);
  expect(i, isNonNegative, reason: '$event happened: $events');
  return i;
}

void main() {
  group('the order of an open-vault delete', () {
    testWidgets(
      'deleteOpenVault asks the guard then flushes then closes then settles and only then trashes',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        final v = rig.vault;

        final result = await tester.runAsync(
          () => rig.deleter.deleteOpenVault(context, v),
        );

        expect(result, isA<VaultDeleted>());
        final e = rig.events;
        expect(rig.guardCalls, [same(context)], reason: 'asked once');
        expect(e.where((x) => x == 'guard'), hasLength(1));
        expect(e.where((x) => x.startsWith('flush')), [
          'flush open=$v',
        ], reason: 'flushed once, while the vault was still open');
        expect(_at(e, 'guard'), lessThan(_at(e, 'flush open=$v')));
        expect(_at(e, 'flush open=$v'), lessThan(_at(e, 'current null')));
        expect(_at(e, 'flush open=$v'), lessThan(_at(e, 'selected null')));
        expect(_at(e, 'current null'), lessThan(_at(e, 'settle $v')));
        expect(_at(e, 'settled $v'), lessThan(_at(e, 'trash $v')));
        expect(rig.trash.calls, [v]);
        expect(e.last, isNot('current $v'), reason: 'no reopen on success');
      },
    );

    testWidgets(
      'deleteOpenVault does not trash until the in-flight saves of the vault have settled',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        await tester.runAsync(() async {
          // Made inside runAsync: a fake-zone completer never wakes it.
          final hold = Completer<void>();
          rig.editor.settleHold = hold;
          final future = rig.deleter.deleteOpenVault(context, rig.vault);
          await pumpEventQueue();
          expect(rig.events, contains('settle ${rig.vault}'));
          expect(rig.c.read(currentVaultProvider), isNull, reason: 'closed');
          expect(rig.trash.calls, isEmpty, reason: 'saves still in flight');

          hold.complete();
          expect(await future, isA<VaultDeleted>());
          expect(rig.trash.calls, [rig.vault]);
        });
      },
    );

    testWidgets(
      'deleteOpenVault does not trash until the vault UI state writes have landed',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        final file = File(p.join(rig.vault, '.memex', 'ui_state.json'));

        await tester.runAsync(() async {
          // A UI state write still queued when the delete starts (the
          // tabs persist with fire-and-forget writes).
          unawaited(UiStateStore(vaultPath: rig.vault).write(UiState.empty()));
          bool? writtenAtTrash;
          bool? tmpAtTrash;
          rig.trash.onTrash = (_) {
            writtenAtTrash = file.existsSync();
            tmpAtTrash = File('${file.path}.tmp').existsSync();
          };
          rig.trash.hold(Completer<TrashResult>());
          final future = rig.deleter.deleteOpenVault(context, rig.vault);
          // Wait until the trash call came.
          for (var i = 0; i < 200 && rig.trash.calls.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(rig.trash.calls, [rig.vault]);
          expect(
            writtenAtTrash,
            isTrue,
            reason: 'the queued ui_state.json write landed before the move',
          );
          expect(tmpAtTrash, isFalse, reason: 'no write half done');
          unawaited(future);
        });
      },
    );
  });

  group('the guard says stay', () {
    testWidgets(
      'deleteOpenVault with the guard saying stay completes VaultDeleteCancelled and flushes closes and trashes nothing',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        rig.allow = false;
        final before = (await tester.runAsync(rig.snapshot))!;

        final result = await tester.runAsync(
          () => rig.deleter.deleteOpenVault(context, rig.vault),
        );

        expect(result, isA<VaultDeleteCancelled>());
        expect(rig.guardCalls, [same(context)]);
        expect(rig.events, ['guard'], reason: 'no flush, close or settle');
        expect(rig.trash.calls, isEmpty);
        expect(rig.c.read(currentVaultProvider), LocalVaultRef(rig.vault));
        expect(rig.c.read(selectedNoteIdProvider), '01NOTE360');
        expect(await tester.runAsync(rig.snapshot), before);
      },
    );
  });

  group('success', () {
    testWidgets(
      'deleteOpenVault on Trashed leaves no vault open unsets the last vault and drops the vault from the recents',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        expect(rig.settings.lastVaultRef, LocalVaultRef(rig.vault));

        final result = await tester.runAsync(
          () => rig.deleter.deleteOpenVault(context, rig.vault),
        );

        expect(result, isA<VaultDeleted>());
        expect(rig.c.read(currentVaultProvider), isNull);
        expect(rig.c.read(selectedNoteIdProvider), isNull);
        expect(rig.settings.lastVaultRef, isNull);
        expect(rig.settings.recentRefs, [LocalVaultRef(rig.other)]);
        final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
        expect(prefs.getString('memex.last_vault'), isNull);
        expect(rig.cli.callsFor('vault check'), isEmpty, reason: 'no reopen');
      },
    );
  });

  group('failure reopens the vault', () {
    final cases = <(String, TrashResult?, String Function(String path))>[
      (
        'deleteOpenVault on TrashNoTrash reopens the vault and keeps the last vault and recents',
        const TrashNoTrash(),
        (path) =>
            "this drive has no trash, so ${p.basename(path)} can't be moved "
            'there. nothing was deleted.',
      ),
      (
        'deleteOpenVault on TrashPermission reopens the vault and keeps the last vault and recents',
        const TrashPermission(),
        (path) =>
            "open memex isn't allowed to move $path. nothing was deleted.",
      ),
      (
        'deleteOpenVault on TrashNotFound reopens the vault and keeps the last vault and recents',
        const TrashNotFound(),
        (path) => '$path is no longer a vault folder. nothing was deleted.',
      ),
      (
        'deleteOpenVault on TrashFailed reopens the vault and keeps the last vault and recents',
        TrashFailed(['disk', 'busy'].join(' ')),
        (path) =>
            "couldn't move ${p.basename(path)} to the trash: disk busy. "
            'nothing was deleted.',
      ),
      (
        'deleteOpenVault when the folder is no longer a vault reopens the vault and keeps the last vault and recents',
        null,
        (path) => '$path is no longer a vault folder. nothing was deleted.',
      ),
    ];
    for (final (name, trashResult, message) in cases) {
      testWidgets(name, (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        if (trashResult != null) {
          rig.trash.answer(trashResult);
        } else {
          File(p.join(rig.vault, 'manifest.json')).deleteSync();
        }
        final before = (await tester.runAsync(rig.snapshot))!;

        final result = await tester.runAsync(
          () => rig.deleter.deleteOpenVault(context, rig.vault),
        );

        expect(
          result,
          isA<VaultDeleteFailed>().having(
            (f) => f.message,
            'message',
            message(rig.vault),
          ),
        );
        expect(
          rig.trash.calls,
          trashResult == null ? isEmpty : [rig.vault],
          reason: 'the isVault re-check runs before the Trash call',
        );
        expect(rig.c.read(currentVaultProvider), LocalVaultRef(rig.vault));
        expect(
          _at(rig.events, 'current null'),
          lessThan(_at(rig.events, 'current ${rig.vault}')),
          reason: 'closed, then reopened',
        );
        expect(
          rig.cli.callsFor('vault check'),
          hasLength(1),
          reason: 'reopened through memex vault check, as a pill switch',
        );
        expect(rig.guardCalls, hasLength(1), reason: 'the reopen asks nothing');
        expect(await tester.runAsync(rig.snapshot), before);
        expect(rig.settings.lastVaultRef, LocalVaultRef(rig.vault));
        expect(rig.settings.recentRefs.first, LocalVaultRef(rig.vault));
      });
    }

    testWidgets(
      'deleteOpenVault when the reopen fails leaves no vault open and still reports the delete failure',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(
          () => _wi360Create(check: FakeMemexCli.error('io', 'disk gone')),
        ))!;
        rig.trash.answer(const TrashPermission());
        final before = (await tester.runAsync(rig.snapshot))!;

        final result = await tester.runAsync(
          () => rig.deleter.deleteOpenVault(context, rig.vault),
        );

        expect(
          result,
          isA<VaultDeleteFailed>().having(
            (f) => f.message,
            'message',
            "open memex isn't allowed to move ${rig.vault}. nothing was deleted.",
          ),
        );
        expect(rig.cli.callsFor('vault check'), hasLength(1));
        expect(rig.c.read(currentVaultProvider), isNull);
        expect(await tester.runAsync(rig.snapshot), before);
      },
    );
  });

  group('a throw mid-delete never leaves the vault closed', () {
    testWidgets(
      'deleteOpenVault reopens the vault and rethrows when the settle throws',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        rig.editor.settleError = StateError('settle blew up');
        final before = (await tester.runAsync(rig.snapshot))!;

        await tester.runAsync(() async {
          await expectLater(
            rig.deleter.deleteOpenVault(context, rig.vault),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'settle blew up',
              ),
            ),
          );
        });

        expect(rig.trash.calls, isEmpty, reason: 'nothing moved');
        expect(rig.c.read(currentVaultProvider), LocalVaultRef(rig.vault));
        expect(
          _at(rig.events, 'current null'),
          lessThan(_at(rig.events, 'current ${rig.vault}')),
          reason: 'closed, then reopened',
        );
        expect(rig.cli.callsFor('vault check'), hasLength(1));
        expect(await tester.runAsync(rig.snapshot), before);
      },
    );

    testWidgets(
      'deleteOpenVault reopens the vault and rethrows when the Trash call throws',
      (tester) async {
        final context = await _wi360Context(tester);
        final rig = (await tester.runAsync(_wi360Create))!;
        rig.trash.onTrash = (_) => throw StateError('trash blew up');
        final before = (await tester.runAsync(rig.snapshot))!;

        await tester.runAsync(() async {
          await expectLater(
            rig.deleter.deleteOpenVault(context, rig.vault),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'trash blew up',
              ),
            ),
          );
        });

        expect(rig.events, contains('trash ${rig.vault}'));
        expect(rig.c.read(currentVaultProvider), LocalVaultRef(rig.vault));
        expect(rig.cli.callsFor('vault check'), hasLength(1));
        expect(await tester.runAsync(rig.snapshot), before);
      },
    );
  });
}
