// WI #363 (Spec #357 Req 1, 2, 3; design pack 363, board S1): the sidebar's
// VAULTS header action is the MANAGE button (`sidebar-vaults-manage`). It
// opens the vault picker modal over the open vault (nothing changes, no
// full-screen picker), shows its pressed state (`surface4`, `fg0`) while
// the modal shows and idle again once it closes, takes the keyboard focus
// with a 1px `accentSoft` ring, and opens the modal once per Enter or Space
// press (a held key and a same-frame double press open one). CANVASES
// keeps its plain `+ NEW`. Also `PanelHeader.trailing` replacing the text
// action. Seams: test/support/wi362_modal.dart (whole app, temp vaults,
// fakes) and wi363_sidebar.dart.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/wi349_keyboard.dart';
import '../support/wi362_modal.dart';
import '../support/wi363_sidebar.dart';

const _manageLabel = 'manage vaults: open the vault picker';

/// MANAGE draws idle: no fill, no visible border, `fg2` text.
void _expectIdle(WidgetTester tester, {String? why}) {
  expect(wi363ManageFills(tester), isEmpty, reason: 'no fill ${why ?? ''}');
  expect(
    wi363ManageBorders(tester),
    isEmpty,
    reason: 'a transparent border ${why ?? ''}',
  );
  expect(
    wi363TextColour(tester, wi363Manage, 'MANAGE'),
    OmColors.fg2,
    reason: 'fg2 text ${why ?? ''}',
  );
}

/// MANAGE draws pressed: `surface4` fill and border, `fg0` text.
void _expectPressed(WidgetTester tester) {
  expect(wi363ManageFills(tester), [OmColors.surface4]);
  expect(wi363ManageBorders(tester), [OmColors.surface4]);
  expect(wi363TextColour(tester, wi363Manage, 'MANAGE'), OmColors.fg0);
}

/// Gives MANAGE the keyboard focus: its own focus node (the nearest Focus
/// around its text) takes the primary focus, in the traditional (keyboard)
/// highlight mode. Tab can't be used here: the open daily note's editor
/// row keeps Tab for itself.
Future<void> _focusManage(WidgetTester tester) async {
  expect(wi363Manage, findsOneWidget);
  wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
  final node = Focus.of(
    tester.element(
      find.descendant(of: wi363Manage, matching: find.text('MANAGE')),
    ),
  );
  expect(node.canRequestFocus, isTrue, reason: 'MANAGE is focusable');
  expect(node.skipTraversal, isFalse, reason: 'MANAGE is in the Tab order');
  node.requestFocus();
  await tester.pump();
  expect(wi349FocusIn(wi363Manage), isTrue, reason: 'MANAGE has the focus');
}

/// The modal shows over the open vault, with nothing else changed.
void _expectModalOverOpenVault(Wi362Env env, String before) {
  expect(wi362Modal, findsOneWidget, reason: 'the vault picker modal shows');
  expect(find.byType(Workspace), findsOneWidget, reason: 'the vault stays');
  expect(find.byType(VaultPickerScreen), findsNothing);
  expect(wi362Snapshot(env), before, reason: 'current and last vault kept');
  expect(env.guardCalls, isEmpty, reason: 'the open vault is not left');
}

void main() {
  holdFontFetches();

  group('header (AC1)', () {
    testWidgets(
      'the vaults header action reads MANAGE and the canvases header keeps its plus new',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        expect(wi363Manage, findsOneWidget);
        expect(
          find.descendant(of: wi363Header('VAULTS'), matching: wi363Manage),
          findsOneWidget,
          reason: 'MANAGE is the VAULTS header action',
        );
        expect(
          find.descendant(of: wi363Manage, matching: find.text('MANAGE')),
          findsOneWidget,
          reason: 'PanelHeader draws manage upper case',
        );
        expect(
          find.descendant(
            of: wi363Header('VAULTS'),
            matching: find.text('+ NEW'),
          ),
          findsNothing,
          reason: 'no + NEW in the VAULTS header',
        );
        expect(
          find.descendant(
            of: wi363Header('CANVASES'),
            matching: find.text('+ NEW'),
          ),
          findsOneWidget,
          reason: 'CANVASES keeps + NEW',
        );
        expect(wi363InSidebar(find.text('+ NEW')), findsOneWidget);
        // CANVASES is unchanged: its + NEW still ends 16 from the content
        // edge (the sidebar is 267 wide inside its 1px right border).
        final sidebar = tester.getRect(find.byType(Sidebar));
        expect(
          tester
              .getRect(
                find.descendant(
                  of: wi363Header('CANVASES'),
                  matching: find.text('+ NEW'),
                ),
              )
              .right,
          moreOrLessEquals(sidebar.left + 267 - 16),
        );
      },
    );

    testWidgets(
      'the MANAGE button is 57 by 22 and ends 8.5 from the sidebar content edge',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        expect(tester.getSize(wi363Manage), const Size(57, 22));
        final sidebar = tester.getRect(find.byType(Sidebar));
        expect(
          tester.getRect(wi363Manage).right,
          moreOrLessEquals(sidebar.left + 267 - 8.5),
        );
      },
    );

    testWidgets(
      'the MANAGE button reads as one button labelled manage vaults open the vault picker',
      (tester) async {
        final handle = tester.ensureSemantics();
        await wi362PumpLocal(tester, openNote: false);

        final node = wi349NodeLabelled(tester, wi363Manage, _manageLabel);
        expect(
          node,
          isSemantics(
            label: _manageLabel,
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
          ),
        );
        expect(
          wi362ButtonNodesIn(tester, wi363Manage),
          hasLength(1),
          reason: 'one button node, the MANAGE text merged or excluded',
        );

        await wi349SemanticTap(tester, node);
        await wi362Settle(tester);
        expect(wi362Modal, findsOneWidget, reason: 'activate opens the modal');
        handle.dispose();
      },
    );
  });

  group('opens the modal over the open vault (AC2)', () {
    testWidgets(
      'pressing MANAGE opens the vault picker modal and keeps the open vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);

        await wi362Tap(tester, wi363Manage);

        _expectModalOverOpenVault(env, before);
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(env.settings.lastVaultRef, LocalVaultRef(env.openPath!));
        expect(
          wi362KeyInModal('recent-row-open-tag-0'),
          findsOneWidget,
          reason: 'the modal lists the open vault first under OPEN',
        );
      },
    );

    testWidgets(
      'pressing MANAGE with a hosted vault open opens the modal and keeps that vault',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        final before = wi362Snapshot(env);

        await wi362Tap(tester, wi363Manage);

        _expectModalOverOpenVault(env, before);
        expect(env.current, seedHostedRef);
      },
    );

    testWidgets(
      'closing the modal opened by MANAGE leaves the open vault as it was',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);

        await wi362Tap(tester, wi363Manage);
        expect(wi362Modal, findsOneWidget);
        await wi362Tap(tester, wi362Close);

        expect(wi362Modal, findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsNothing);
        expect(wi362Snapshot(env), before);
      },
    );
  });

  group('pressed, focus and keyboard (AC7)', () {
    testWidgets('MANAGE draws idle on its first frame', (tester) async {
      await wi362PumpLocal(tester, openNote: false);

      _expectIdle(tester, why: 'before any press');
      expect(
        wi349Rings(tester, wi363Manage),
        isEmpty,
        reason: 'no focus ring before it has the focus',
      );
    });

    testWidgets(
      'MANAGE shows its pressed state while the modal is open and returns to idle when it closes',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        await wi362Tap(tester, wi363Manage);
        expect(wi362Modal, findsOneWidget);
        _expectPressed(tester);

        // Still pressed while the modal stays up.
        await wi362Settle(tester);
        _expectPressed(tester);

        await wi362Tap(tester, wi362Close);
        expect(wi362Modal, findsNothing);
        _expectIdle(tester, why: 'after the modal closed');
      },
    );

    testWidgets('MANAGE returns to idle when the modal closes with Escape', (
      tester,
    ) async {
      await wi362PumpLocal(tester, openNote: false);

      await wi362Tap(tester, wi363Manage);
      _expectPressed(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wi362Settle(tester);

      expect(wi362Modal, findsNothing);
      expect(
        wi363ManageFills(tester),
        isNot(contains(OmColors.surface4)),
        reason: 'no longer pressed',
      );
      expect(wi363TextColour(tester, wi363Manage, 'MANAGE'), OmColors.fg2);
    });

    testWidgets(
      'MANAGE takes the keyboard focus with a 1px accentSoft ring and no fill',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        await _focusManage(tester);

        expect(wi349FocusIn(wi363Manage), isTrue);
        final rings = wi349Rings(tester, wi363Manage);
        expect(rings, isNotEmpty, reason: 'an accentSoft focus ring');
        final ring = rings.first.$1.border! as Border;
        expect(ring.top.width, 1);
        expect(ring.top.color, OmColors.accentSoft);
        expect(wi363ManageBorders(tester), [OmColors.accentSoft]);
        expect(wi363ManageFills(tester), isEmpty, reason: 'no fill on focus');
        expect(wi363TextColour(tester, wi363Manage, 'MANAGE'), OmColors.fg2);
        expect(wi362Modal, findsNothing, reason: 'focus alone opens nothing');
      },
    );

    for (final (name, key) in [
      (
        'Enter on the focused MANAGE opens the modal once',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on the focused MANAGE opens the modal once',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(tester, openNote: false);
        final before = wi362Snapshot(env);
        await _focusManage(tester);

        await tester.sendKeyEvent(key);
        await wi362Settle(tester);

        expect(wi362Modal, findsOneWidget, reason: 'exactly one modal');
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsNothing);
        expect(wi362Snapshot(env), before);
        _expectPressed(tester);
      });
    }

    testWidgets(
      'a button activate intent on the focused MANAGE opens the modal once',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);
        await _focusManage(tester);

        final context = tester.element(
          find.descendant(of: wi363Manage, matching: find.text('MANAGE')),
        );
        Actions.invoke(context, const ButtonActivateIntent());
        Actions.invoke(context, const ButtonActivateIntent());
        await wi362Settle(tester);

        expect(wi362Modal, findsOneWidget, reason: 'one modal');
        _expectPressed(tester);
      },
    );

    testWidgets('a held Enter on MANAGE opens one modal', (tester) async {
      await wi362PumpLocal(tester, openNote: false);
      await _focusManage(tester);

      // Down and its repeats land before a frame moves the focus into the
      // modal: the repeats must not open more.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await wi362Settle(tester);

      expect(wi362Modal, findsOneWidget, reason: 'one modal, repeats ignored');
    });

    testWidgets('a repeat of Enter alone on the focused MANAGE opens nothing', (
      tester,
    ) async {
      await wi362PumpLocal(tester, openNote: false);
      await _focusManage(tester);

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await wi362Settle(tester);

      expect(wi362Modal, findsNothing, reason: 'a KeyRepeatEvent is ignored');
      expect(wi349FocusIn(wi363Manage), isTrue);
    });

    testWidgets('two presses of MANAGE in the same frame open one modal', (
      tester,
    ) async {
      await wi362PumpLocal(tester, openNote: false);
      await _focusManage(tester);

      // Two whole Enter presses before any frame: the focus is still on
      // MANAGE for the second.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await wi362Settle(tester);

      expect(wi362Modal, findsOneWidget, reason: 'one modal');
      await wi362Tap(tester, wi362Close);
      expect(wi362Modal, findsNothing, reason: 'none left under it');
    });

    testWidgets(
      'two semantic taps on MANAGE in the same frame open one modal',
      (tester) async {
        final handle = tester.ensureSemantics();
        await wi362PumpLocal(tester, openNote: false);
        final node = wi349NodeLabelled(tester, wi363Manage, _manageLabel);

        node.owner!.performAction(node.id, SemanticsAction.tap);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pump();
        await wi362Settle(tester);

        expect(wi362Modal, findsOneWidget, reason: 'one modal');
        await wi362Tap(tester, wi362Close);
        expect(wi362Modal, findsNothing, reason: 'none left under it');
        handle.dispose();
      },
    );

    testWidgets('MANAGE opens the modal again after the first one closed', (
      tester,
    ) async {
      await wi362PumpLocal(tester, openNote: false);

      await wi362Tap(tester, wi363Manage);
      await wi362Tap(tester, wi362Close);
      expect(wi362Modal, findsNothing);

      await wi362Tap(tester, wi363Manage);
      expect(wi362Modal, findsOneWidget, reason: 'opens again');
      _expectPressed(tester);
    });

    testWidgets(
      'MANAGE returns to idle when the modal closes for a vault switch from it',
      (tester) async {
        final env = await wi362PumpLocal(tester, openNote: false);

        await wi362Tap(tester, wi363Manage);
        _expectPressed(tester);
        // RECENT row 1 is work-notes (the open memex is row 0).
        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));
        await wi362Settle(tester, rounds: 12);

        expect(env.current, LocalVaultRef(env.otherPath!));
        expect(wi362Modal, findsNothing);
        expect(wi363Manage, findsOneWidget);
        _expectIdle(tester, why: 'after the switch closed the modal');
      },
    );
  });

  group('VAULTS header height', () {
    testWidgets(
      'the VAULTS header is 40.5 high and the pills start where it ends',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        final header = tester.getRect(wi363Header('VAULTS'));
        // 11.25 + the 22 high button + 7.25: the pack's "41 high" (a 40.5
        // layout), so MANAGE's height costs the header nothing.
        expect(
          header.height,
          moreOrLessEquals(40.5),
          reason: 'the 41 high pack',
        );
        expect(
          tester.getRect(wi363PillBox('memex')).top,
          moreOrLessEquals(header.bottom),
          reason: 'the pills sit right under the header',
        );
        // A 22 high button and the eyebrow share one centre line.
        expect(
          tester.getCenter(find.text('VAULTS')).dy,
          moreOrLessEquals(tester.getCenter(wi363Manage).dy, epsilon: 0.5),
          reason: 'eyebrow and MANAGE are centred together',
        );
      },
    );
  });

  group('PanelHeader.trailing', () {
    Future<void> pumpHeader(WidgetTester tester, PanelHeader header) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SizedBox(width: 268, child: header)),
          ),
        );

    testWidgets(
      'PanelHeader shows its trailing widget in place of the text action',
      (tester) async {
        var tapped = 0;
        await pumpHeader(
          tester,
          PanelHeader(
            eyebrow: 'vaults',
            count: 3,
            action: '+ new',
            onAction: () => tapped++,
            trailing: SizedBox(
              key: Key(['wi363', 'trailing'].join('-')),
              width: 57,
              height: 22,
            ),
          ),
        );

        expect(find.byKey(const Key('wi363-trailing')), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const Key('wi363-trailing'))),
          const Size(57, 22),
        );
        expect(find.text('+ NEW'), findsNothing);
        expect(find.text('VAULTS'), findsOneWidget);
        expect(find.text('· 3'), findsOneWidget);
        expect(tapped, 0);
      },
    );

    testWidgets(
      'PanelHeader without trailing keeps its upper case text action',
      (tester) async {
        var tapped = 0;
        await pumpHeader(
          tester,
          PanelHeader(
            eyebrow: 'canvases',
            action: '+ new',
            onAction: () => tapped++,
          ),
        );

        expect(find.text('+ NEW'), findsOneWidget);
        await tester.tap(find.text('+ NEW'));
        expect(tapped, 1);
      },
    );
  });
}
