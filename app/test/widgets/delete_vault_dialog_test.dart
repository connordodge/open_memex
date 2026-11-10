// WI #350 (Spec #347 req 7–16, 19, 20): the delete-vault confirm, opened
// from a local recent row on the real vault picker. Its shell and exact
// copy, initial focus, cancel / Escape / tap-outside, the busy state while
// the move runs, success, every failure message, retry, the live-region
// error line and the 1.3x / 720 px layout. Seams:
// test/support/vault_picker_harness.dart (`trash:` as `vaultTrashProvider`),
// FakeVaultTrash (queued results, recorded calls, held calls) and real temp
// vault folders. Never a real Trash or vault.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/dialog_button.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_trash.dart';
import '../support/font_fetch_hold.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi349_keyboard.dart';

const _cancel = Key('delete-vault-cancel');
const _confirm = Key('delete-vault-confirm');

Finder get _dialog => find.byType(DeleteVaultDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

String _question(String path) => 'move ${p.basename(path)} to the trash?';

String _body(String path) =>
    '$path goes to the Trash. you can put it back from there until you '
    'empty it. its backups are kept.';

/// The picker with the vault at [path] as recent row 0 and [trash] as the
/// Trash seam, plus backup settings saved for [path].
class _Wi350Env {
  _Wi350Env(this.picker, this.trash, this.path, this.backups);

  final Wi97Picker picker;
  final FakeVaultTrash trash;
  final String path;
  final VaultBackupSettings backups;

  AppSettings get settings => picker.settings;
}

Future<_Wi350Env> _pump(
  WidgetTester tester, {
  FakeVaultTrash? trash,
  String? path,
  Size size = const Size(1280, 800),
}) async {
  final vaultPath = path ?? createVaultFolder('om350_dialog_').path;
  final fake = trash ?? FakeVaultTrash();
  final env = await pumpVaultPicker(
    tester,
    recents: [LocalVaultRef(vaultPath)],
    trash: fake,
    size: size,
  );
  final backups = VaultBackupSettings(
    enabled: true,
    destination: p.join(Directory.systemTemp.path, 'om350_dest'),
    keep: vaultPath.length % 50 + 2,
  );
  await tester.runAsync(
    () => env.container
        .read(settingsProvider.notifier)
        .setVaultBackup(vaultPath, backups),
  );
  await wi97Settle(tester);
  return _Wi350Env(env, fake, vaultPath, backups);
}

/// Presses the row delete button and lets the dialog open.
Future<void> _open(WidgetTester tester) async {
  final delete = find.byKey(const Key('recent-row-delete-0'));
  expect(delete, findsOneWidget, reason: 'the row has a delete button');
  await tester.tap(delete);
  await wi97Settle(tester);
  expect(_dialog, findsOneWidget, reason: 'the delete dialog is open');
}

/// Nothing changed: no Trash call, the row in the recents, its backup
/// settings and its folder kept.
void _expectUnchanged(_Wi350Env env) {
  expect(env.trash.calls, isEmpty, reason: 'no VaultTrash call');
  expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
  expect(env.settings.vaultBackups[env.path]?.keep, env.backups.keep);
  expect(
    env.settings.vaultBackups[env.path]?.destination,
    env.backups.destination,
  );
  expect(Directory(env.path).existsSync(), isTrue);
  expect(find.byKey(const Key('recent-row-0')), findsOneWidget);
}

/// The OmButton drawn for the DialogButton keyed [key].
OmButton _om(WidgetTester tester, Key key) => tester.widget<OmButton>(
  find.descendant(of: find.byKey(key), matching: find.byType(OmButton)),
);

/// The semantics data of the button keyed [key], read as [label].
SemanticsData _sem(WidgetTester tester, Key key, String label) =>
    wi349NodeLabelled(tester, find.byKey(key), label).getSemanticsData();

void main() {
  holdFontFetches();

  group('shell and copy', () {
    testWidgets(
      'pressing delete opens the dialog with the remove server shell and the exact copy',
      (tester) async {
        final env = await _pump(tester);
        expect(_dialog, findsNothing);
        await _open(tester);

        expect(tester.widget<DeleteVaultDialog>(_dialog).path, env.path);
        expect(_inDialog(find.text('DELETE VAULT')), findsOneWidget);
        expect(_inDialog(find.text(_question(env.path))), findsOneWidget);
        expect(_inDialog(find.text(_body(env.path))), findsOneWidget);

        // The remove-server shell: 472 wide, surface2, line2 border, radius 10,
        // the dialog shadow.
        final shell = find.ancestor(
          of: find.text('DELETE VAULT'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color == OmColors.surface2,
          ),
        );
        expect(shell, findsOneWidget);
        expect(tester.getSize(shell).width, 472);
        final deco =
            tester.widget<Container>(shell).decoration! as BoxDecoration;
        expect((deco.border! as Border).top.color, OmColors.line2);
        expect(deco.borderRadius, BorderRadius.circular(10));
        expect(
          deco.boxShadow?.map((s) => s.color),
          contains(OmColors.dialogShadow),
        );

        final question = tester.widget<Text>(find.text(_question(env.path)));
        expect(question.style?.fontSize, 15);
        expect(question.style?.fontWeight, FontWeight.w600);
        final body = tester.widget<Text>(find.text(_body(env.path)));
        expect(body.style?.fontSize, 13.5);
        expect(body.style?.color, OmColors.fg1);

        // Eyebrow, question, body, then the buttons, top to bottom.
        final ys = [
          tester.getTopLeft(find.text('DELETE VAULT')).dy,
          tester.getTopLeft(find.text(_question(env.path))).dy,
          tester.getTopLeft(find.text(_body(env.path))).dy,
          tester.getTopLeft(find.byKey(_confirm)).dy,
        ];
        expect(ys, orderedEquals([...ys]..sort()));

        // Ghost cancel and danger move to trash, keyboard DialogButtons.
        final cancel = tester.widget(find.byKey(_cancel));
        final confirm = tester.widget(find.byKey(_confirm));
        expect(cancel, isA<DialogButton>());
        expect(confirm, isA<DialogButton>());
        expect((cancel as DialogButton).kind, OmButtonKind.ghost);
        expect(cancel.label, 'cancel');
        expect((confirm as DialogButton).kind, OmButtonKind.danger);
        expect(confirm.label, 'move to trash');
        expect(confirm.icon, isNull, reason: 'no spinner before the move');
        expect(_om(tester, _cancel).onPressed, isNotNull);
        expect(_om(tester, _confirm).onPressed, isNotNull);

        // Right-aligned in one Wrap, cancel first.
        final wrap = find.ancestor(
          of: find.byKey(_confirm),
          matching: find.byType(Wrap),
        );
        expect(wrap, findsOneWidget);
        expect(
          find.descendant(of: wrap, matching: find.byKey(_cancel)),
          findsOneWidget,
        );
        expect(tester.widget<Wrap>(wrap).alignment, WrapAlignment.end);
        expect(tester.widget<Wrap>(wrap).spacing, 8);
        // Cancel first in reading order (beside it, or above it when the
        // Wrap runs over two lines).
        expect(
          tester
              .widget<Wrap>(wrap)
              .children
              .map((c) => c.key)
              .where((k) => k == _cancel || k == _confirm),
          [_cancel, _confirm],
        );
        final c = tester.getRect(find.byKey(_cancel));
        final m = tester.getRect(find.byKey(_confirm));
        expect(
          c.bottom <= m.top || (c.top == m.top && c.right <= m.left),
          isTrue,
          reason: 'cancel reads before move to trash',
        );
        expect(
          tester.getRect(wrap).right -
              tester.getRect(find.byKey(_confirm)).right,
          lessThan(1),
          reason: 'move to trash ends at the right edge',
        );
        _expectUnchanged(env);
      },
    );

    testWidgets(
      'before the move both buttons are enabled and read as enabled buttons',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester);
        await _open(tester);

        for (final (key, label) in [
          (_cancel, 'cancel'),
          (_confirm, 'move to trash'),
        ]) {
          expect(
            _sem(tester, key, label),
            isSemantics(
              label: label,
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              hasTapAction: true,
            ),
          );
        }
        expect(_inDialog(find.byIcon(LucideIcons.loader2)), findsNothing);
        expect(_inDialog(find.text('moving to trash…')), findsNothing);
        expect(_inDialog(find.byIcon(LucideIcons.triangleAlert)), findsNothing);
        handle.dispose();
      },
    );
  });

  group('focus and dismiss', () {
    testWidgets(
      'cancel has focus when the dialog opens and Enter closes it without calling the trash',
      (tester) async {
        final env = await _pump(tester);
        await _open(tester);

        expect(wi349FocusIn(find.byKey(_cancel)), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        _expectUnchanged(env);
      },
    );

    testWidgets('Tab moves to move to trash and Space starts the move', (
      tester,
    ) async {
      final env = await _pump(tester);
      await _open(tester);

      await wi349TabTo(tester, find.byKey(_confirm), max: 4);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await wi97Settle(tester);

      expect(env.trash.calls, [env.path]);
      expect(_dialog, findsNothing);
      expect(env.settings.recentRefs, isEmpty);
    });

    for (final (name, how) in [
      ('cancel closes the dialog and changes nothing', 'cancel'),
      ('Escape closes the dialog and changes nothing', 'escape'),
      ('a tap outside closes the dialog and changes nothing', 'outside'),
    ]) {
      testWidgets(name, (tester) async {
        final env = await _pump(tester);
        await _open(tester);

        switch (how) {
          case 'cancel':
            await tester.tap(find.byKey(_cancel));
          case 'escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          default:
            await tester.tapAt(const Offset(8, 8));
        }
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        _expectUnchanged(env);
      });
    }
  });

  group('busy', () {
    testWidgets(
      'while the move runs the confirm shows the spinner and moving to trash and both buttons are disabled',
      (tester) async {
        final handle = tester.ensureSemantics();
        final hold = Completer<TrashResult>();
        final env = await _pump(tester, trash: FakeVaultTrash()..hold(hold));
        await _open(tester);

        await tester.tap(find.byKey(_confirm));
        await wi97Settle(tester);

        expect(env.trash.calls, [env.path]);
        final confirm = tester.widget<DialogButton>(find.byKey(_confirm));
        expect(confirm.label, 'moving to trash…');
        expect(confirm.icon, LucideIcons.loader2);
        expect(confirm.onPressed, isNull);
        expect(
          tester.widget<DialogButton>(find.byKey(_cancel)).onPressed,
          isNull,
        );
        expect(
          find.descendant(
            of: find.byKey(_confirm),
            matching: find.byIcon(LucideIcons.loader2),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_confirm),
            matching: find.text('moving to trash…'),
          ),
          findsOneWidget,
        );
        expect(_inDialog(find.text('move to trash')), findsNothing);
        expect(_om(tester, _cancel).onPressed, isNull);
        expect(_om(tester, _confirm).onPressed, isNull);

        for (final (key, label) in [
          (_cancel, 'cancel'),
          (_confirm, 'moving to trash…'),
        ]) {
          expect(
            _sem(tester, key, label),
            isSemantics(
              label: label,
              isButton: true,
              hasEnabledState: true,
              isEnabled: false,
              hasTapAction: false,
            ),
          );
        }

        hold.complete(const Trashed());
        await wi97Settle(tester);
        expect(_dialog, findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'while the move runs a second press, Enter, Escape and a tap outside do nothing',
      (tester) async {
        final hold = Completer<TrashResult>();
        final env = await _pump(tester, trash: FakeVaultTrash()..hold(hold));
        await _open(tester);

        await tester.tap(find.byKey(_confirm));
        await wi97Settle(tester);
        expect(env.trash.calls, [env.path]);

        await tester.tap(find.byKey(_confirm), warnIfMissed: false);
        await wi97Settle(tester);
        await tester.tap(find.byKey(_cancel), warnIfMissed: false);
        await wi97Settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await wi97Settle(tester);
        await tester.tapAt(const Offset(8, 8));
        await wi97Settle(tester);

        expect(_dialog, findsOneWidget, reason: 'open until the move finishes');
        expect(env.trash.calls, [env.path], reason: 'exactly one move');
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);

        hold.complete(const Trashed());
        await wi97Settle(tester);
        expect(_dialog, findsNothing);
        expect(env.trash.calls, [env.path]);
        expect(env.settings.recentRefs, isEmpty);
      },
    );
  });

  group('result', () {
    testWidgets('on success the dialog closes and the row leaves the recents', (
      tester,
    ) async {
      final env = await _pump(tester);
      await _open(tester);

      await tester.tap(find.byKey(_confirm));
      await wi97Settle(tester);

      expect(_dialog, findsNothing);
      expect(env.trash.calls, [env.path]);
      expect(env.settings.recentRefs, isEmpty);
      expect(env.settings.vaultBackups.containsKey(env.path), isFalse);
      expect(find.byKey(const Key('recent-row-0')), findsNothing);
      expect(find.text(p.basename(env.path)), findsNothing);
    });

    testWidgets(
      'on failure the dialog stays open with the message as a live region error line under the body',
      (tester) async {
        final handle = tester.ensureSemantics();
        final env = await _pump(
          tester,
          trash: FakeVaultTrash()..answer(const TrashPermission()),
        );
        await _open(tester);
        await tester.tap(find.byKey(_confirm));
        await wi97Settle(tester);

        final message =
            "open memex isn't allowed to move ${env.path}. nothing was deleted.";
        final line = _inDialog(find.text(message));
        expect(_dialog, findsOneWidget);
        expect(line, findsOneWidget);
        expect(
          tester.getTopLeft(line).dy,
          greaterThanOrEqualTo(
            tester.getBottomLeft(find.text(_body(env.path))).dy,
          ),
          reason: 'under the body',
        );
        expect(
          tester.getBottomLeft(line).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.byKey(_confirm)).dy),
          reason: 'above the buttons',
        );

        // A danger line: the danger alert icon beside the message.
        final icon = _inDialog(find.byIcon(LucideIcons.triangleAlert));
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).color, OmColors.danger);

        // Its own node, carrying only the message, in a live region.
        final node = wi349NodeLabelled(tester, line, message);
        var live = false;
        for (SemanticsNode? n = node; n != null; n = n.parent) {
          if (n.getSemanticsData().flagsCollection.isLiveRegion) live = true;
        }
        expect(live, isTrue, reason: 'the error line is a live region');

        // It never takes focus; the focus stays on cancel.
        expect(wi349FocusIn(line), isFalse);
        expect(wi349FocusIn(find.byKey(_cancel)), isTrue);

        // The buttons work again.
        final confirm = tester.widget<DialogButton>(find.byKey(_confirm));
        expect(confirm.label, 'move to trash');
        expect(confirm.icon, isNull);
        expect(confirm.onPressed, isNotNull);
        expect(
          tester.widget<DialogButton>(find.byKey(_cancel)).onPressed,
          isNotNull,
        );
        expect(
          _sem(tester, _confirm, 'move to trash'),
          isSemantics(
            label: 'move to trash',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );

        // Nothing changed.
        expect(env.trash.calls, [env.path]);
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
        expect(env.settings.vaultBackups[env.path]?.keep, env.backups.keep);
        expect(find.byKey(const Key('recent-row-delete-0')), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'after a failure cancel closes the dialog and changes nothing',
      (tester) async {
        final env = await _pump(
          tester,
          trash: FakeVaultTrash()..answer(const TrashNoTrash()),
        );
        await _open(tester);
        await tester.tap(find.byKey(_confirm));
        await wi97Settle(tester);
        expect(_dialog, findsOneWidget);

        await tester.tap(find.byKey(_cancel));
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        expect(env.trash.calls, [env.path]);
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
        expect(env.settings.vaultBackups[env.path]?.keep, env.backups.keep);
        expect(find.byKey(const Key('recent-row-delete-0')), findsOneWidget);
      },
    );

    testWidgets('after a failure move to trash tries again', (tester) async {
      final env = await _pump(
        tester,
        trash: FakeVaultTrash()..answer(const TrashFailed('the disk is busy')),
      );
      await _open(tester);
      await tester.tap(find.byKey(_confirm));
      await wi97Settle(tester);
      expect(_dialog, findsOneWidget);
      expect(env.trash.calls, [env.path]);

      await tester.tap(find.byKey(_confirm));
      await wi97Settle(tester);

      expect(env.trash.calls, [env.path, env.path], reason: 'a second move');
      expect(_dialog, findsNothing);
      expect(env.settings.recentRefs, isEmpty);
    });

    testWidgets(
      'after a failure from the keyboard the focus stays on move to trash and Enter tries again',
      (tester) async {
        final env = await _pump(
          tester,
          trash: FakeVaultTrash()..answer(const TrashPermission()),
        );
        await _open(tester);
        await wi349TabTo(tester, find.byKey(_confirm), max: 4);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(_dialog, findsOneWidget);
        expect(env.trash.calls, [env.path]);
        expect(wi349FocusIn(find.byKey(_confirm)), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);
        expect(env.trash.calls, [env.path, env.path]);
        expect(_dialog, findsNothing);
      },
    );

    for (final (name, result, expected, removeFirst) in [
      (
        'the no trash message renders exactly',
        const TrashNoTrash() as TrashResult?,
        (String path) =>
            "this drive has no trash, so ${p.basename(path)} can't be moved there. nothing was deleted.",
        false,
      ),
      (
        'the permission message renders exactly',
        const TrashPermission(),
        (String path) =>
            "open memex isn't allowed to move $path. nothing was deleted.",
        false,
      ),
      (
        'the not found message renders exactly',
        const TrashNotFound(),
        (String path) =>
            '$path is no longer a vault folder. nothing was deleted.',
        false,
      ),
      (
        'the not a vault message renders exactly',
        null,
        (String path) =>
            '$path is no longer a vault folder. nothing was deleted.',
        true,
      ),
      (
        'the other failure message renders exactly with the system message',
        const TrashFailed('the volume is read only'),
        (String path) =>
            "couldn't move ${p.basename(path)} to the trash: the volume is read only. nothing was deleted.",
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final trash = FakeVaultTrash();
        if (result != null) trash.answer(result);
        final env = await _pump(tester, trash: trash);
        await _open(tester);
        if (removeFirst) deleteFolderQuietly(Directory(env.path));

        await tester.tap(find.byKey(_confirm));
        await wi97Settle(tester);

        expect(_dialog, findsOneWidget);
        expect(_inDialog(find.text(expected(env.path))), findsOneWidget);
        expect(trash.calls, removeFirst ? isEmpty : [env.path]);
        expect(env.settings.recentRefs, [LocalVaultRef(env.path)]);
      });
    }
  });

  group('layout', () {
    testWidgets(
      'at 1.3x text and a 720 px window the dialog with a long path wraps the path with no overflow',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final parent = createPlainFolder('om350_long_');
        final path = p.joinAll([
          parent.path,
          'projects-and-archives-of-many-kinds',
          'a-very-long-folder-name-for-a-scratch-vault-from-testing',
          'another-deeply-nested-vault-folder-name',
        ]);
        initVaultFolder(path);
        final env = await _pump(tester, path: path, size: const Size(720, 800));
        await _open(tester);

        expect(tester.takeException(), isNull);
        final body = _inDialog(find.text(_body(env.path)));
        expect(body, findsOneWidget);
        final text = tester.widget<Text>(body);
        expect(text.maxLines, isNull);
        expect(text.overflow, isNot(TextOverflow.ellipsis));

        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: body, matching: find.byType(RichText)),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: env.path.length),
        );
        final lines = boxes.map((b) => b.top.round()).toSet();
        expect(lines.length, greaterThan(1), reason: 'the path wraps');
        expect(paragraph.didExceedMaxLines, isFalse);

        final dialogRect = tester.getRect(_dialog);
        expect(dialogRect.right, lessThanOrEqualTo(720));
        for (final k in [_cancel, _confirm]) {
          final r = tester.getRect(find.byKey(k));
          expect(r.right, lessThanOrEqualTo(720));
          expect(r.bottom, lessThanOrEqualTo(800));
        }
      },
    );
  });
}
