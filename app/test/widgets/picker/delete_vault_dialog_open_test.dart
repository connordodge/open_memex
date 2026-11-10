// WI #360 (Spec #357 Req 27-33, TD3, TD7; design pack 360, board S3): the
// delete-vault dialog when the vault is the open one, on the whole app
// (`_Router` → Workspace). The dialog is opened with a context inside the
// Workspace, which unmounts when the vault closes, so the flow must run
// from the dialog's own state. Covers the open-vault line, the guard, the
// busy state across the close, success (full-screen picker, vault
// forgotten, nothing recreates the folder), every failure (reopened, the
// existing message), a failed reopen, the busy guard (same-frame presses, a
// held Enter) and backup running (open or not, re-enabling by itself).
// Seams: pumpWorkspace (FakeVaultDb, FakeMemexCli, FakeClock), a recording
// guard, a recording EditorController subclass, FakeVaultTrash and
// `backupInFlightProvider`. Temp folders only; never a real Trash or vault.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/dialog_button.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:path/path.dart' as p;

import '../../support/app_harness.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_trash.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/wi349_keyboard.dart';

const _cancel = Key('delete-vault-cancel');
const _confirm = Key('delete-vault-confirm');
const _openLine = Key('delete-vault-open-line');

Finder get _dialog => find.byType(DeleteVaultDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

String _openCopy(String path) =>
    '${p.basename(path)} is open, so open memex will close it first.';

String _backupCopy(String path) =>
    'a backup of ${p.basename(path)} is running. try again when it '
    'finishes. nothing was deleted.';

String _body(String path) =>
    '$path goes to the Trash. you can put it back from there until you '
    'empty it. its backups are kept.';

/// The editor with its flushes counted.
class _Wi360DialogEditor extends EditorController {
  _Wi360DialogEditor(super.ref);

  int flushes = 0;

  @override
  void flushPendingSave() {
    flushes++;
    super.flushPendingSave();
  }
}

/// A Trash seam that really moves the folder out of the way (into a temp
/// "Trash" of its own), so a later write at the old path would show.
class _Wi360MovingTrash extends FakeVaultTrash {
  _Wi360MovingTrash() : bin = createPlainFolder('om360_bin_');

  final Directory bin;

  @override
  Future<TrashResult> trash(String path) {
    final result = super.trash(path);
    Directory(path).renameSync(p.join(bin.path, p.basename(path)));
    return result;
  }
}

class _Wi360Env {
  _Wi360Env(this.h, this.trash, this.guardCalls);

  final WorkspaceHarness h;
  final FakeVaultTrash trash;

  /// Whether each guard call's context was still mounted when asked.
  final List<bool> guardCalls;

  /// What the guard answers; [guardHold], when set, holds it.
  bool allow = true;
  Completer<bool>? guardHold;

  String get path => h.vaultPath;
  ProviderContainer get c => h.container;
  AppSettings get settings => c.read(settingsProvider);
  _Wi360DialogEditor get editor =>
      c.read(editorControllerProvider.notifier) as _Wi360DialogEditor;
  VaultRef? get current => c.read(currentVaultProvider);
}

/// The whole app with the vault at [_Wi360Env.path] open (a real vault folder:
/// manifest.json plus a V5 memex.db), first in the recents and the last
/// vault. `memex vault check` answers [check] (default safe) on a reopen.
Future<_Wi360Env> _wi360Pump(
  WidgetTester tester, {
  FakeVaultTrash? trash,
  MemexResult? check,
}) async {
  final fake = trash ?? FakeVaultTrash();
  final guardCalls = <bool>[];
  late _Wi360Env env;
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..on('vault check', (_) => check ?? FakeMemexCli.ok());
  final h = await pumpWorkspace(
    tester,
    cli: cli,
    overrides: [
      vaultTrashProvider.overrideWithValue(fake),
      editorControllerProvider.overrideWith(_Wi360DialogEditor.new),
      leaveVaultGuardProvider.overrideWithValue((ctx) async {
        guardCalls.add(ctx.mounted);
        final hold = env.guardHold;
        if (hold != null) return hold.future;
        return env.allow;
      }),
    ],
  );
  initVaultFolder(h.vaultPath);
  env = _Wi360Env(h, fake, guardCalls);
  // Flush the UI state the workspace queued before the temp dir goes.
  addTearDown(() => UiStateStore(vaultPath: h.vaultPath).flush());
  await _wi360Settle(tester);
  return env;
}

/// Let real I/O (UI state writes, prefs) and fake-clock work finish, then
/// draw. Never pumpAndSettle: the workspace animates forever.
Future<void> _wi360Settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opens the delete dialog for [path] from a context inside the Workspace
/// (as the sidebar pill menu and the picker modal will): that context
/// unmounts when the vault closes.
Future<void> _wi360Open(WidgetTester tester, String path) async {
  final workspace = find.byType(Workspace);
  expect(workspace, findsOneWidget, reason: 'a vault is open');
  unawaited(confirmDeleteVault(tester.element(workspace), path: path));
  await _wi360Settle(tester, rounds: 2);
  expect(_dialog, findsOneWidget, reason: 'the delete dialog is open');
}

/// The OmButton drawn for the DialogButton keyed [key].
OmButton _om(WidgetTester tester, Key key) => tester.widget<OmButton>(
  find.descendant(of: find.byKey(key), matching: find.byType(OmButton)),
);

SemanticsData _sem(WidgetTester tester, Key key, String label) =>
    wi349NodeLabelled(tester, find.byKey(key), label).getSemanticsData();

/// The dialog's confirm and cancel are enabled ([enabled]) or not, as
/// widgets and in semantics, with [label] on the confirm.
void _expectButtons(
  WidgetTester tester, {
  required bool confirmEnabled,
  required bool cancelEnabled,
  required String label,
}) {
  expect(tester.widget<DialogButton>(find.byKey(_confirm)).label, label);
  expect(_om(tester, _confirm).onPressed != null, confirmEnabled);
  expect(_om(tester, _cancel).onPressed != null, cancelEnabled);
  for (final (key, l, on) in [
    (_confirm, label, confirmEnabled),
    (_cancel, 'cancel', cancelEnabled),
  ]) {
    expect(
      _sem(tester, key, l),
      isSemantics(
        label: l,
        isButton: true,
        hasEnabledState: true,
        isEnabled: on,
        hasTapAction: on,
      ),
    );
  }
}

/// The dialog is busy: the spinner, `moving to trash…`, both disabled.
void _expectBusy(WidgetTester tester) {
  _expectButtons(
    tester,
    confirmEnabled: false,
    cancelEnabled: false,
    label: 'moving to trash…',
  );
  expect(
    tester.widget<DialogButton>(find.byKey(_confirm)).icon,
    LucideIcons.loader2,
  );
}

void main() {
  holdFontFetches();

  group('the open-vault line', () {
    testWidgets(
      'the open line shows under the path line for the open vault and not for another vault',
      (tester) async {
        final env = await _wi360Pump(tester);
        await _wi360Open(tester, env.path);

        final line = find.byKey(_openLine);
        expect(_inDialog(line), findsOneWidget);
        final text = find.descendant(
          of: line,
          matching: find.text(_openCopy(env.path)),
        );
        expect(text, findsOneWidget);
        final style = tester.widget<Text>(text).style!;
        expect(style.fontSize, 13.5);
        expect(style.fontWeight ?? FontWeight.w400, FontWeight.w400);
        expect(style.color, OmColors.fg1);
        final icon = find.descendant(
          of: line,
          matching: find.byIcon(LucideIcons.info),
        );
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).size, 14);
        expect(tester.widget<Icon>(icon).color, OmColors.fg2);
        // Under the path line (12 px), above the buttons, icon then text.
        final body = tester.getRect(find.text(_body(env.path)));
        final lineText = tester.getRect(text);
        expect(lineText.top - body.bottom, closeTo(12, 0.5));
        expect(
          tester.getRect(line).bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(_confirm)).top),
        );
        expect(tester.getRect(icon).right, lessThan(lineText.left));
        // Idle: both enabled, no error line.
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
        expect(_inDialog(find.byIcon(LucideIcons.triangleAlert)), findsNothing);

        await tester.tap(find.byKey(_cancel));
        await _wi360Settle(tester);
        expect(_dialog, findsNothing);

        // Another vault, while this one is open: the #351 dialog unchanged,
        // and its delete leaves the open vault open.
        final other = createVaultFolder('om360_other_').path;
        await _wi360Open(tester, other);
        expect(find.byKey(_openLine), findsNothing);
        expect(_inDialog(find.text(_openCopy(other))), findsNothing);
        expect(_inDialog(find.text(_openCopy(env.path))), findsNothing);
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);
        expect(_dialog, findsNothing);
        expect(env.trash.calls, [other]);
        expect(env.guardCalls, isEmpty);
        expect(env.current, LocalVaultRef(env.path));
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });

  group('confirming on the open vault', () {
    testWidgets(
      'confirming on the open vault closes it trashes it and shows the full-screen picker with the vault forgotten',
      (tester) async {
        final trash = _Wi360MovingTrash();
        final env = await _wi360Pump(tester, trash: trash);
        await _wi360Open(tester, env.path);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.guardCalls, [true], reason: 'asked once, mounted context');
        expect(env.trash.calls, [env.path]);
        expect(_dialog, findsNothing, reason: 'the dialog closes on success');
        expect(env.current, isNull);
        expect(env.c.read(selectedNoteIdProvider), isNull);
        expect(find.byType(Workspace), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(env.settings.lastVaultRef, isNull);
        expect(env.settings.recentRefs, isEmpty);
        expect(find.byKey(const Key('recent-row-0')), findsNothing);
        expect(env.editor.flushes, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'after a successful open-vault delete nothing recreates the folder at the old path',
      (tester) async {
        final trash = _Wi360MovingTrash();
        final env = await _wi360Pump(tester, trash: trash);
        await _wi360Open(tester, env.path);
        // Two UI state writes queued when the person presses: the second
        // only starts once the first landed, so unless the delete waits
        // for the queue it starts after the move and recreates <vault>/.memex.
        final store = UiStateStore(vaultPath: env.path);
        unawaited(store.write(UiState.empty()));
        unawaited(store.write(UiState.empty()));

        await tester.tap(find.byKey(_confirm));
        // Each queued write needs a few real I/O round trips.
        await _wi360Settle(tester, rounds: 40);
        expect(env.trash.calls, [env.path]);
        expect(env.guardCalls, [true], reason: 'the open-vault delete ran');
        expect(env.current, isNull, reason: 'the vault was closed first');
        // Everything still queued for the old path, and a while longer.
        await tester.runAsync(() => UiStateStore(vaultPath: env.path).flush());
        await _wi360Settle(tester, rounds: 10);
        env.h.clock.advance(const Duration(minutes: 1));
        await _wi360Settle(tester);

        expect(
          Directory(env.path).existsSync(),
          isFalse,
          reason: 'a late write would recreate <vault>/.memex at the old path',
        );
        expect(
          Directory(p.join(trash.bin.path, p.basename(env.path))).existsSync(),
          isTrue,
        );
      },
    );

    testWidgets(
      'with the guard saying stay nothing is flushed closed or trashed and the dialog returns to idle',
      (tester) async {
        final env = await _wi360Pump(tester);
        env.allow = false;
        await _wi360Open(tester, env.path);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.guardCalls, [true]);
        expect(env.editor.flushes, 0);
        expect(env.trash.calls, isEmpty);
        expect(env.current, LocalVaultRef(env.path));
        expect(find.byType(Workspace), findsOneWidget);
        expect(_dialog, findsOneWidget);
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
        expect(_inDialog(find.byIcon(LucideIcons.loader2)), findsNothing);
        expect(_inDialog(find.byIcon(LucideIcons.triangleAlert)), findsNothing);
        expect(find.byKey(_openLine), findsOneWidget);
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
        expect(env.settings.lastVaultRef, LocalVaultRef(env.path));
        expect(Directory(env.path).existsSync(), isTrue);
      },
    );
  });

  group('failure', () {
    final cases = <(String, TrashResult?, String Function(String path))>[
      (
        'on TrashNoTrash the open vault reopens and the dialog shows the no-trash message',
        const TrashNoTrash(),
        (path) =>
            "this drive has no trash, so ${p.basename(path)} can't be moved "
            'there. nothing was deleted.',
      ),
      (
        'on TrashPermission the open vault reopens and the dialog shows the not-allowed message',
        const TrashPermission(),
        (path) =>
            "open memex isn't allowed to move $path. nothing was deleted.",
      ),
      (
        'on TrashNotFound the open vault reopens and the dialog shows the no-longer-a-vault message',
        const TrashNotFound(),
        (path) => '$path is no longer a vault folder. nothing was deleted.',
      ),
      (
        'on TrashFailed the open vault reopens and the dialog shows the could-not-move message',
        TrashFailed(['disk', 'busy'].join(' ')),
        (path) =>
            "couldn't move ${p.basename(path)} to the trash: disk busy. "
            'nothing was deleted.',
      ),
      (
        'when the open vault folder is no longer a vault it reopens and the dialog shows the no-longer-a-vault message',
        null,
        (path) => '$path is no longer a vault folder. nothing was deleted.',
      ),
    ];
    for (final (name, result, message) in cases) {
      testWidgets(name, (tester) async {
        final env = await _wi360Pump(tester);
        if (result != null) {
          env.trash.answer(result);
        } else {
          File(p.join(env.path, 'manifest.json')).deleteSync();
        }
        final recents = env.settings.recentRefs;
        final last = env.settings.lastVaultRef;
        await _wi360Open(tester, env.path);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.guardCalls, [true]);
        expect(env.editor.flushes, 1, reason: 'it did close first');
        expect(env.h.cli.callsFor('vault check'), hasLength(1));
        expect(env.current, LocalVaultRef(env.path), reason: 'reopened');
        expect(find.byType(Workspace), findsOneWidget);
        expect(env.settings.recentRefs, recents);
        expect(env.settings.lastVaultRef, last);
        expect(_dialog, findsOneWidget, reason: 'stays on top');
        expect(_inDialog(find.text(message(env.path))), findsOneWidget);
        expect(
          _inDialog(find.byIcon(LucideIcons.triangleAlert)),
          findsOneWidget,
        );
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
        expect(Directory(env.path).existsSync(), isTrue);
      });
    }

    testWidgets(
      'after a failed open-vault delete move to trash closes the vault and tries again',
      (tester) async {
        final env = await _wi360Pump(tester);
        env.trash.answer(const TrashPermission());
        await _wi360Open(tester, env.path);
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);
        expect(env.current, LocalVaultRef(env.path));

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.guardCalls, [true, true]);
        expect(env.editor.flushes, 2);
        expect(env.trash.calls, [env.path, env.path]);
        expect(_dialog, findsNothing);
        expect(env.current, isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(env.settings.recentRefs, isEmpty);
      },
    );

    testWidgets(
      'when the reopen after a failed delete fails the full-screen picker shows and the dialog keeps the delete error',
      (tester) async {
        final env = await _wi360Pump(
          tester,
          check: FakeMemexCli.error('io', 'permission denied'),
        );
        env.trash.answer(const TrashPermission());
        await _wi360Open(tester, env.path);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.trash.calls, [env.path]);
        expect(
          env.h.cli.callsFor('vault check'),
          isNotEmpty,
          reason: 'the reopen was tried',
        );
        expect(env.current, isNull);
        expect(find.byType(Workspace), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(_dialog, findsOneWidget);
        expect(
          _inDialog(
            find.text(
              "open memex isn't allowed to move ${env.path}. "
              'nothing was deleted.',
            ),
          ),
          findsOneWidget,
        );
        expect(_om(tester, _cancel).onPressed, isNotNull);
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
      },
    );
  });

  group('busy', () {
    testWidgets(
      'the busy label reads moving to trash from the press until the result and cancel is disabled meanwhile',
      (tester) async {
        final handle = tester.ensureSemantics();
        final hold = Completer<TrashResult>();
        final env = await _wi360Pump(
          tester,
          trash: FakeVaultTrash()..hold(hold),
        );
        env.guardHold = Completer<bool>();
        await _wi360Open(tester, env.path);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester, rounds: 2);

        // 1. The guard is still deciding: busy already.
        expect(env.guardCalls, [true]);
        expect(env.editor.flushes, 0);
        _expectBusy(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _wi360Settle(tester, rounds: 2);
        await tester.tapAt(const Offset(8, 8));
        await _wi360Settle(tester, rounds: 2);
        expect(_dialog, findsOneWidget, reason: 'not dismissable while busy');

        // 2. The vault closed (the workspace is gone behind the dialog),
        // the Trash call is held: still busy, the open line still shown.
        env.guardHold!.complete(true);
        await _wi360Settle(tester);
        expect(env.current, isNull);
        expect(find.byType(Workspace), findsNothing);
        expect(env.trash.calls, [env.path]);
        expect(_dialog, findsOneWidget);
        _expectBusy(tester);
        expect(
          find.byKey(_openLine),
          findsOneWidget,
          reason: 'S3 busy keeps the idle layout',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.tap(find.byKey(_cancel), warnIfMissed: false);
        await tester.tap(find.byKey(_confirm), warnIfMissed: false);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _wi360Settle(tester, rounds: 2);
        expect(_dialog, findsOneWidget);
        expect(env.guardCalls, [true], reason: 'no second delete');
        expect(env.trash.calls, [env.path]);

        // 3. The result: idle again with the error.
        hold.complete(const TrashPermission());
        await _wi360Settle(tester);
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
        expect(_inDialog(find.text('moving to trash…')), findsNothing);
        expect(_inDialog(find.byIcon(LucideIcons.loader2)), findsNothing);
        expect(env.current, LocalVaultRef(env.path));
        handle.dispose();
      },
    );

    testWidgets(
      'the busy dialog of a vault that is not open shows no open line and leaves the open vault open',
      (tester) async {
        final hold = Completer<TrashResult>();
        final env = await _wi360Pump(
          tester,
          trash: FakeVaultTrash()..hold(hold),
        );
        final other = createVaultFolder('om360_other_').path;
        await _wi360Open(tester, other);

        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester, rounds: 2);

        _expectBusy(tester);
        expect(env.trash.calls, [other]);
        expect(find.byKey(_openLine), findsNothing);
        expect(env.guardCalls, isEmpty, reason: 'not the open vault');
        expect(env.editor.flushes, 0);
        expect(env.current, LocalVaultRef(env.path), reason: 'still open');

        hold.complete(const Trashed());
        await _wi360Settle(tester);
        expect(_dialog, findsNothing);
        expect(env.current, LocalVaultRef(env.path));
      },
    );

    testWidgets('two presses in the same frame start one open-vault delete', (
      tester,
    ) async {
      final hold = Completer<TrashResult>();
      final env = await _wi360Pump(tester, trash: FakeVaultTrash()..hold(hold));
      await _wi360Open(tester, env.path);

      // No pump between the presses: the button still holds the first
      // press's closure, so only the dialog's own guard stops a second.
      await tester.tap(find.byKey(_confirm));
      await tester.tap(find.byKey(_confirm), warnIfMissed: false);
      await _wi360Settle(tester);

      expect(env.guardCalls, [true], reason: 'one delete');
      expect(env.editor.flushes, 1);
      expect(env.trash.calls, [env.path]);
      hold.complete(const Trashed());
      await _wi360Settle(tester);
      expect(env.guardCalls, [true]);
      expect(env.trash.calls, [env.path]);
      expect(_dialog, findsNothing);
      expect(env.current, isNull);
    });

    testWidgets('a held Enter starts one open-vault delete', (tester) async {
      final hold = Completer<TrashResult>();
      final env = await _wi360Pump(tester, trash: FakeVaultTrash()..hold(hold));
      await _wi360Open(tester, env.path);
      await wi349TabTo(tester, find.byKey(_confirm), max: 4);

      await wi349HoldKey(tester, LogicalKeyboardKey.enter, repeats: 4);
      await _wi360Settle(tester);

      expect(env.guardCalls, [true], reason: 'one delete');
      expect(env.editor.flushes, 1);
      expect(env.trash.calls, [env.path]);
      hold.complete(const Trashed());
      await _wi360Settle(tester);
      expect(env.trash.calls, [env.path]);
      expect(_dialog, findsNothing);
      expect(env.current, isNull);
    });
  });

  group('backup running', () {
    testWidgets(
      'with a backup of the open vault running move to trash is disabled with the backup line and re-enables when it ends',
      (tester) async {
        final handle = tester.ensureSemantics();
        final env = await _wi360Pump(tester);
        env.c.read(backupInFlightProvider.notifier).state = {env.path};
        await _wi360Settle(tester, rounds: 2);
        await _wi360Open(tester, env.path);

        expect(_inDialog(find.text(_backupCopy(env.path))), findsOneWidget);
        expect(
          _inDialog(find.byIcon(LucideIcons.triangleAlert)),
          findsOneWidget,
        );
        expect(find.byKey(_openLine), findsOneWidget);
        _expectButtons(
          tester,
          confirmEnabled: false,
          cancelEnabled: true,
          label: 'move to trash',
        );
        await tester.tap(find.byKey(_confirm), warnIfMissed: false);
        await _wi360Settle(tester);
        expect(_dialog, findsOneWidget);
        expect(env.guardCalls, isEmpty, reason: 'nothing starts');
        expect(env.editor.flushes, 0);
        expect(env.trash.calls, isEmpty);
        expect(env.current, LocalVaultRef(env.path));

        // The backup ends: the same dialog re-enables by itself.
        env.c.read(backupInFlightProvider.notifier).state = const {};
        await _wi360Settle(tester, rounds: 2);
        expect(_inDialog(find.text(_backupCopy(env.path))), findsNothing);
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);
        expect(env.guardCalls, [true]);
        expect(env.trash.calls, [env.path]);
        expect(_dialog, findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'with a backup of a vault that is not open running its dialog disables move to trash and re-enables when it ends',
      (tester) async {
        final env = await _wi360Pump(tester);
        final other = createVaultFolder('om360_other_').path;
        await _wi360Open(tester, other);
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );

        // The backup starts while the dialog shows.
        env.c.read(backupInFlightProvider.notifier).state = {other};
        await _wi360Settle(tester, rounds: 2);
        expect(_inDialog(find.text(_backupCopy(other))), findsOneWidget);
        expect(find.byKey(_openLine), findsNothing);
        expect(_om(tester, _confirm).onPressed, isNull);
        expect(_om(tester, _cancel).onPressed, isNotNull);
        await tester.tap(find.byKey(_confirm), warnIfMissed: false);
        await _wi360Settle(tester);
        expect(env.trash.calls, isEmpty);
        expect(Directory(other).existsSync(), isTrue);

        env.c.read(backupInFlightProvider.notifier).state = const {};
        await _wi360Settle(tester, rounds: 2);
        expect(_inDialog(find.text(_backupCopy(other))), findsNothing);
        expect(_om(tester, _confirm).onPressed, isNotNull);
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);
        expect(env.trash.calls, [other]);
        expect(env.current, LocalVaultRef(env.path));
      },
    );

    testWidgets(
      'a press in the frame a backup starts moves nothing and leaves no stale refusal after the backup ends',
      (tester) async {
        final env = await _wi360Pump(tester);
        await _wi360Open(tester, env.path);
        expect(_om(tester, _confirm).onPressed, isNotNull);

        // The backup starts and the press lands before the next frame
        // rebuilds the button as disabled.
        env.c.read(backupInFlightProvider.notifier).state = {env.path};
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);

        expect(env.guardCalls, isEmpty, reason: 'the press started nothing');
        expect(env.editor.flushes, 0);
        expect(env.trash.calls, isEmpty);
        expect(env.current, LocalVaultRef(env.path));
        expect(_dialog, findsOneWidget);

        env.c.read(backupInFlightProvider.notifier).state = const {};
        await _wi360Settle(tester, rounds: 2);
        expect(
          _inDialog(find.text(_backupCopy(env.path))),
          findsNothing,
          reason: 'the press left no refusal of its own behind',
        );
        expect(_inDialog(find.byIcon(LucideIcons.triangleAlert)), findsNothing);
        _expectButtons(
          tester,
          confirmEnabled: true,
          cancelEnabled: true,
          label: 'move to trash',
        );
      },
    );

    testWidgets(
      'a backup of another vault running leaves move to trash enabled for the open vault',
      (tester) async {
        final env = await _wi360Pump(tester);
        final other = createVaultFolder('om360_other_').path;
        env.c.read(backupInFlightProvider.notifier).state = {other};
        await _wi360Settle(tester, rounds: 2);
        await _wi360Open(tester, env.path);

        expect(find.byKey(_openLine), findsOneWidget);
        expect(_inDialog(find.text(_backupCopy(env.path))), findsNothing);
        expect(_inDialog(find.text(_backupCopy(other))), findsNothing);
        expect(_om(tester, _confirm).onPressed, isNotNull);
        await tester.tap(find.byKey(_confirm));
        await _wi360Settle(tester);
        expect(env.guardCalls, [true]);
        expect(env.trash.calls, [env.path]);
      },
    );
  });
}
