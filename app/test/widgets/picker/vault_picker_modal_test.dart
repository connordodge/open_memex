// WI #362 (Spec #357 Req 5, 6, 6a, 7, 15, 16, TD1; design pack 362, boards
// A1, A2, S4; lead rulings): the vault picker modal itself, opened over the
// whole app with a vault open. Covers: it shows over the workspace and
// changes nothing; Esc, x and a scrim click close it with nothing changed;
// the same sections as the full-screen picker (one shared body); it closes
// whenever the current vault changes (another vault, a hosted flow that
// opens one inside PickerActions, none); focus starts inside, Tab stays
// inside, Enter on a focused row or button acts once (a held key once); a
// focused SERVERS row shows the ring; the dialog is min(640, width - 48)
// wide, a surface1 card with a line3 border and 40 padding, over a
// dialogShadow scrim. Seams: test/support/wi362_modal.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_body.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_modal.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/fake_vault_server.dart';
import '../../support/hosted_harness.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi349_keyboard.dart';
import '../../support/wi362_modal.dart';

/// The modal is showing, over the workspace.
void _expectModalOver() {
  expect(wi362Modal, findsOneWidget, reason: 'the vault picker modal shows');
  expect(find.byType(Workspace), findsOneWidget, reason: 'over the workspace');
}

/// The modal has closed, its future completed, and the workspace shows.
void _expectClosed(Wi362Env env) {
  expect(wi362Modal, findsNothing, reason: 'the modal closed');
  expect(env.modalDone, isTrue, reason: 'showVaultPickerModal completed');
}

void main() {
  holdFontFetches();

  group('open and close', () {
    testWidgets(
      'the modal shows over the workspace and opening it changes nothing',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        expect(env.c.read(selectedNoteIdProvider), isNotNull);

        await wi362OpenModal(tester, env);

        _expectModalOver();
        expect(env.modalDone, isFalse, reason: 'it is still open');
        expect(wi362Snapshot(env), before);
        expect(env.guardCalls, isEmpty, reason: 'opening asks no guard');
        expect(
          env.h.cli!.callsFor('vault check'),
          isEmpty,
          reason: 'opening runs no vault check',
        );
      },
    );

    for (final (name, close) in <(String, Future<void> Function(WidgetTester))>[
      (
        'Esc closes the modal with nothing changed',
        (tester) async {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await wi362Settle(tester);
        },
      ),
      (
        'the close button closes the modal with nothing changed',
        (tester) => wi362Tap(tester, wi362Close),
      ),
      (
        'a scrim click closes the modal with nothing changed',
        (tester) async {
          // Left of the 640 dialog, over the sidebar: the scrim.
          await tester.tapAt(const Offset(120, 400));
          await wi362Settle(tester);
        },
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        await wi362OpenModal(tester, env);
        _expectModalOver();

        await close(tester);

        _expectClosed(env);
        expect(find.byType(Workspace), findsOneWidget);
        expect(wi362Snapshot(env), before);
        expect(env.guardCalls, isEmpty);
        expect(env.h.cli!.callsFor('vault check'), isEmpty);
      });
    }

    testWidgets('a click inside the dialog does not close the modal', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      await tester.tap(wi362InModal(find.text('CHOOSE A VAULT')));
      await wi362Settle(tester);

      expect(wi362Modal, findsOneWidget);
      expect(env.modalDone, isFalse);
    });

    testWidgets(
      'the close button reads as a button labelled close the vault picker',
      (tester) async {
        final handle = tester.ensureSemantics();
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        expect(wi362Close, findsOneWidget);

        final node = wi349NodeLabelled(
          tester,
          wi362Close,
          'close the vault picker',
        );
        expect(node, isSemantics(isButton: true));
        // VoiceOver's activate closes it too.
        await wi349SemanticTap(tester, node);
        await wi362Settle(tester);
        _expectClosed(env);
        handle.dispose();
      },
    );
  });

  group('sections', () {
    testWidgets('the modal shows the same sections as the full screen picker', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      expect(
        wi362InModal(find.byType(VaultPickerBody)),
        findsOneWidget,
        reason: 'the one shared picker body (TD1)',
      );
      for (final text in [
        'CHOOSE A VAULT',
        'esc',
        'memex binary  fake-memex',
        'RECENT',
        'SERVERS',
        'THIS MAC',
        'VAULT SERVER',
        'BACKUP',
      ]) {
        expect(wi362InModal(find.text(text)), findsOneWidget, reason: text);
      }
      for (final key in [
        'vault-picker-create',
        'vault-picker-open',
        'vault-picker-open-on-server',
        'vault-picker-create-on-server',
        'vault-picker-restore',
        'vault-picker-modal-close',
        'server-row-$fakeServerId',
      ]) {
        expect(wi362KeyInModal(key), findsOneWidget, reason: key);
      }
      // Pack 362: the modal header replaces the full-screen brand row.
      expect(wi362InModal(find.text('open memex')), findsNothing);
      expect(find.byType(VaultPickerScreen), findsNothing);
    });

    testWidgets(
      'the modal shows the binary not found card when no binary is configured',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();

        expect(
          wi362InModal(find.text('memex binary not found')),
          findsOneWidget,
        );
        expect(wi362InModal(find.text('RECENT')), findsOneWidget);
        expect(wi362InModal(find.text('THIS MAC')), findsOneWidget);
      },
    );
  });

  group('closes on a vault change', () {
    testWidgets('the modal closes when the current vault changes to another', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      // A route outside the modal (a pill switch, say) opens another vault.
      await pumpWhile(
        tester,
        () => env.controller.openVault(LocalVaultRef(env.otherPath!)),
      );
      await wi362Settle(tester);

      expect(env.current, LocalVaultRef(env.otherPath!));
      _expectClosed(env);
      expect(find.byType(Workspace), findsOneWidget);
    });

    for (final (name, key, hook) in <(String, String, String)>[
      (
        'a hosted open flow that opens a vault inside PickerActions closes the modal',
        'vault-picker-open-on-server',
        'open',
      ),
      (
        'a hosted create flow that opens a vault inside PickerActions closes the modal',
        'vault-picker-create-on-server',
        'create',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(tester);
        Future<void> openOther() async {
          await env.controller.openVault(LocalVaultRef(env.otherPath!));
        }

        if (hook == 'open') {
          env.actions.onOpenOnServer = openOther;
        } else {
          env.actions.onCreateOnServer = openOther;
        }
        await wi362OpenModal(tester, env);
        _expectModalOver();

        await wi362Tap(tester, wi362KeyInModal(key));

        expect(env.guardCalls, [false], reason: 'the guard is asked once');
        expect(env.current, LocalVaultRef(env.otherPath!));
        _expectClosed(env);
      });
    }

    testWidgets(
      'the modal closes and the full screen picker shows when the hosted vault goes away',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();

        await pumpWhile(
          tester,
          () => env.controller.hostedVaultGoneWhileOpen(seedHostedRef),
        );
        await wi362Settle(tester);

        expect(env.current, isNull);
        _expectClosed(env);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
      },
    );

    testWidgets(
      'the modal closes and the full screen picker shows when the open vault closes underneath it',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();

        await env.controller.closeForDelete();
        await wi362Settle(tester);

        expect(env.current, isNull);
        _expectClosed(env);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
      },
    );
  });

  group('keyboard', () {
    testWidgets('the modal takes the focus when it opens', (tester) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      bool isFocused(Element e) => identical(e, focused);
      final inside = wi362FocusInModal();
      // Or the dialog route's own scope, above the modal and not above the
      // workspace.
      final routeScope =
          find
              .ancestor(
                of: wi362Modal,
                matching: find.byElementPredicate(isFocused),
              )
              .evaluate()
              .isNotEmpty &&
          find
              .ancestor(
                of: find.byType(Workspace),
                matching: find.byElementPredicate(isFocused),
              )
              .evaluate()
              .isEmpty;
      expect(inside || routeScope, isTrue, reason: 'the focus is the modal');

      // The first Tab lands on something inside the modal.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi362FocusInModal(), isTrue);
    });

    testWidgets('Tab keeps the focus inside the modal', (tester) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      final seen = <FocusNode>{};
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(wi362FocusInModal(), isTrue, reason: 'after Tab ${i + 1}');
        seen.add(FocusManager.instance.primaryFocus!);
      }
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(wi362FocusInModal(), isTrue, reason: 'after Shift+Tab ${i + 1}');
      }
      expect(
        seen.length,
        greaterThanOrEqualTo(8),
        reason: 'Tab moves through the rows, buttons and actions',
      );
      expect(wi362Modal, findsOneWidget);
    });

    testWidgets(
      'a held Enter on a focused RECENT row in the modal starts one open',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();
        expect(
          find.descendant(
            of: wi362KeyInModal('recent-row-1'),
            matching: find.text('work-notes'),
          ),
          findsOneWidget,
        );
        await wi362TabToRow(tester, 'recent-row-1');

        env.guardHold = Completer<bool>();
        await wi349HoldKey(tester, LogicalKeyboardKey.enter, repeats: 4);
        expect(env.guardCalls, hasLength(1), reason: 'one open for one press');

        env.guardHold!.complete(true);
        await wi362Settle(tester);
        expect(env.guardCalls, hasLength(1));
        expect(env.current, LocalVaultRef(env.otherPath!));
        _expectClosed(env);
      },
    );

    testWidgets(
      'a held Enter on a focused action button in the modal starts its flow once',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();
        await wi349TabTo(
          tester,
          wi362KeyInModal('vault-picker-open-on-server'),
          max: 80,
        );

        await wi349HoldKey(tester, LogicalKeyboardKey.enter, repeats: 4);
        await wi362Settle(tester);

        expect(env.guardCalls, [false]);
        expect(env.actions.calls, ['openOnServer']);
        expect(wi362Modal, findsOneWidget);
      },
    );

    testWidgets('Enter on the focused close button closes the modal', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      final before = wi362Snapshot(env);
      await wi362OpenModal(tester, env);
      _expectModalOver();
      await wi349TabTo(tester, wi362Close, max: 80);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await wi362Settle(tester);

      _expectClosed(env);
      expect(wi362Snapshot(env), before);
    });

    testWidgets(
      'a focused SERVERS row in the modal shows the accentSoft ring',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();
        final row = wi362KeyInModal('server-row-$fakeServerId');
        expect(wi349Rings(tester, row), isEmpty, reason: 'not focused yet');

        await wi362TabToRow(tester, 'server-row-$fakeServerId');
        await tester.pump();

        final rings = wi349Rings(tester, row);
        expect(rings, hasLength(1));
        expect(rings.single.$1.borderRadius, BorderRadius.circular(7.5));
        expect(env.guardCalls, isEmpty);
      },
    );
  });

  group('size and chrome', () {
    testWidgets('the modal is 640 wide at 1280', (tester) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      final rect = tester.getRect(wi362Modal);
      expect(rect.width, 640);
      expect(rect.center.dx, 640, reason: 'centred');
    });

    for (final (name, width, expected) in <(String, double, double)>[
      ('the modal is 640 wide at 720', 720, 640),
      (
        'the modal is the window width less 48 when the window is narrower than 688',
        660,
        612,
      ),
    ]) {
      testWidgets(name, (tester) async {
        // The full-screen picker as the host: the workspace itself overflows
        // this narrow under the test font. The modal's width does not
        // depend on what is under it.
        await pumpVaultPicker(tester, size: Size(width, 900));
        var done = false;
        unawaited(
          showVaultPickerModal(
            tester.element(find.byType(VaultPickerScreen)),
          ).then((_) => done = true),
        );
        await wi97Settle(tester);
        expect(wi362Modal, findsOneWidget);
        expect(done, isFalse);

        final rect = tester.getRect(wi362Modal);
        expect(rect.width, expected);
        expect(rect.center.dx, width / 2, reason: 'centred');
      });
    }

    testWidgets(
      'the modal is a surface1 card with a 1px line3 border radius 10 and 40 padding',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        _expectModalOver();
        final modal = tester.getRect(wi362Modal);

        final cards = [
          for (final e
              in find
                  .descendant(
                    of: wi362Modal,
                    matching: find.byType(DecoratedBox),
                    matchRoot: true,
                  )
                  .evaluate())
            if ((e.widget as DecoratedBox).decoration case final BoxDecoration d
                when d.color == OmColors.surface1)
              (d, tester.getRect(find.byElementPredicate((x) => x == e))),
        ];
        expect(cards, isNotEmpty, reason: 'a surface1 fill');
        final (card, cardRect) = cards.first;
        expect(cardRect, modal, reason: 'the fill is the whole dialog');
        expect(card.border, Border.all(color: OmColors.line3));
        expect(card.borderRadius, BorderRadius.circular(10));

        // 1 px border + 40 px padding: the column starts 41 in.
        final eyebrow = tester.getRect(
          wi362InModal(find.text('CHOOSE A VAULT')),
        );
        expect(eyebrow.left, modal.left + 41);
        final create = tester.getRect(
          wi362InModal(find.byKey(const Key('vault-picker-create'))),
        );
        expect(create.right, lessThanOrEqualTo(modal.right - 41));
        final row = tester.getRect(wi362KeyInModal('recent-row-0'));
        expect(row.left, modal.left + 41, reason: 'the column fills');
        expect(row.right, modal.right - 41, reason: 'the column fills');
      },
    );

    testWidgets('the modal scrim is dialogShadow and dismisses', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      await wi362OpenModal(tester, env);
      _expectModalOver();

      final scrims = find.byWidgetPredicate(
        (w) => w is ModalBarrier && w.color == OmColors.dialogShadow,
      );
      expect(scrims, findsOneWidget);
      expect(tester.widget<ModalBarrier>(scrims).dismissible, isTrue);
    });
  });
}
