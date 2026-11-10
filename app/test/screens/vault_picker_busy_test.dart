// WI #362 (Spec #357 Req 5, 6, 12, 14): contracts of the picker body inside
// the modal that the AC tests leave open. While a row open or one of the
// five flows waits on the leave guard, any other press (a row or another
// flow) starts nothing, and once it ends a new press works. The action
// buttons the memex binary being missing disables take no keyboard focus,
// the others show the accentSoft radius-6 ring when focused. The dialog
// hugs its content and, in a short window, is the window height less 48
// and scrolls to its last button.
// Seams: test/support/wi362_modal.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_modal.dart';

import '../support/font_fetch_hold.dart';
import '../support/wi349_keyboard.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi362_modal.dart';

Finder _button(String key) => wi362KeyInModal(key);

void main() {
  holdFontFetches();

  group('one action at a time', () {
    testWidgets(
      'another flow press while a flow waits on the guard starts nothing and a later press works',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        env.guardHold = Completer<bool>();

        await wi362Tap(tester, _button('vault-picker-create'));
        await wi362Tap(tester, _button('vault-picker-open'));
        await wi362Tap(tester, _button('vault-picker-open-on-server'));
        await wi362Tap(tester, _button('vault-picker-create-on-server'));
        await wi362Tap(tester, _button('vault-picker-restore'));
        await wi362Tap(tester, _button('recent-row-1'));

        expect(env.guardCalls, hasLength(1), reason: 'only the first asked');
        expect(env.files.calls, isEmpty);
        expect(env.actions.calls, isEmpty);

        env.guardHold!.complete(true);
        await wi362Settle(tester);
        expect(find.text('CREATE NEW VAULT'), findsOneWidget);
        expect(env.guardCalls, hasLength(1));
        expect(env.files.calls, isEmpty);
        expect(env.h.cli!.callsFor('vault check'), isEmpty);
        await wi362Tap(tester, find.text('cancel'));
        expect(find.text('CREATE NEW VAULT'), findsNothing);

        // The first flow ended: the next press is not swallowed.
        env.guardHold = null;
        await wi362Tap(tester, _button('vault-picker-open'));
        expect(env.guardCalls, hasLength(2));
        expect(
          env.files.calls.any((c) => c.method == 'getDirectoryPath'),
          true,
        );
        expect(wi362Modal, findsOneWidget);
      },
    );

    testWidgets(
      'a flow press while a row open waits on the guard starts nothing',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        env.guardHold = Completer<bool>();

        await wi362Tap(tester, _button('recent-row-1'));
        await wi362Tap(tester, _button('vault-picker-create'));
        await wi362Tap(tester, _button('vault-picker-open-on-server'));

        expect(env.guardCalls, hasLength(1));
        expect(env.actions.calls, isEmpty);
        expect(find.text('CREATE NEW VAULT'), findsNothing);

        env.guardHold!.complete(true);
        await wi362Settle(tester);
        expect(env.current, LocalVaultRef(env.otherPath!));
        expect(env.guardCalls, hasLength(1));
        expect(env.actions.calls, isEmpty);
        expect(find.text('CREATE NEW VAULT'), findsNothing);
      },
    );

    testWidgets('a stay on a row open frees the next press', (tester) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      env.allow = false;

      await wi362Tap(tester, _button('recent-row-1'));
      await wi362Tap(tester, _button('vault-picker-open-on-server'));

      expect(env.guardCalls, hasLength(2), reason: 'each press asked once');
      expect(env.actions.calls, isEmpty, reason: 'stay starts nothing');
      expect(wi362Modal, findsOneWidget);
    });
  });

  group('keyboard focus on the action buttons', () {
    testWidgets(
      'a button disabled for the missing binary takes no focus and the others do',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await wi362OpenModal(tester, env);
        expect(wi362Modal, findsOneWidget);
        final disabled = [
          _button('vault-picker-create'),
          _button('vault-picker-open'),
          _button('vault-picker-restore'),
        ];
        final enabled = {
          'open on server': _button('vault-picker-open-on-server'),
          'create on server': _button('vault-picker-create-on-server'),
        };

        final reached = <String>{};
        for (var i = 0; i < 40; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          for (final d in disabled) {
            expect(wi349FocusIn(d), isFalse, reason: 'Tab $i reached $d');
          }
          enabled.forEach((name, f) {
            if (wi349FocusIn(f)) reached.add(name);
          });
        }
        expect(reached, enabled.keys.toSet(), reason: 'enabled ones focus');
      },
    );

    testWidgets('a focused action button shows the accentSoft radius 6 ring', (
      tester,
    ) async {
      wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      final button = _button('vault-picker-create-on-server');
      expect(wi349Rings(tester, button), isEmpty, reason: 'not focused yet');

      await wi349TabTo(tester, button, max: 80);

      final rings = wi349Rings(tester, button);
      expect(rings, hasLength(1));
      expect(rings.single.$1.borderRadius, BorderRadius.circular(6));
      final box = tester.getRect(button);
      expect(rings.single.$2, box, reason: 'around the whole button');
    });
  });

  group('modal height', () {
    testWidgets('the modal hugs its content in a tall window', (tester) async {
      final env = await wi362PumpLocal(tester, size: const Size(1280, 1600));
      await wi362OpenModal(tester, env);

      final rect = tester.getRect(wi362Modal);
      expect(rect.height, lessThan(1600 - 48), reason: 'not stretched');
      expect(rect.center.dy, closeTo(800, 1), reason: 'centred');
    });

    testWidgets(
      'in a short window the modal is the window height less 48 and scrolls to its last button',
      (tester) async {
        // The full-screen picker as the host: the workspace itself overflows
        // this short. The modal does not depend on what is under it.
        await pumpVaultPicker(tester, size: const Size(1280, 300));
        unawaited(
          showVaultPickerModal(tester.element(find.byType(VaultPickerScreen))),
        );
        await wi97Settle(tester);

        final rect = tester.getRect(wi362Modal);
        expect(rect.height, 252);
        expect(rect.top, 24);
        final restore = _button('vault-picker-restore');
        expect(
          tester.getRect(restore).bottom,
          greaterThan(rect.bottom),
          reason: 'the restore button starts below the fold',
        );

        await tester.ensureVisible(restore);
        await tester.pump();

        expect(
          tester.getRect(restore).bottom,
          lessThanOrEqualTo(tester.getRect(wi362Modal).bottom),
          reason: 'scrolled into view inside the dialog',
        );
        expect(tester.getRect(wi362Modal), rect, reason: 'the card stays');
      },
    );
  });
}
