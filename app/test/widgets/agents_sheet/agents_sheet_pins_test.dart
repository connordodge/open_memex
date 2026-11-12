// WI #407 (SH; Spec #394 req 6-12, 44): contracts of the Agents sheet shell
// that the AC tests in agents_sheet_shell_test.dart leave open, pinned one
// site at a time: the first frame before the opening-tab choice, arrow
// wrap-around, held arrows and modifier arrows, the docs link's keys, the
// focus rings, the Semantics flags and leaf nodes, the close x hover, the
// Window menu attach and detach, and a sheet closed before its 300 ms
// decision. Every test opens the sheet through `pumpAgentsSheet`.
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_sheet_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/live_tab_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/recall_tab_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/tools_tab_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_sheet.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/live_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/recall_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/tools_tab.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/font_fetch_hold.dart';

const _tabKeys = [
  'agents-tab-live',
  'agents-tab-connect',
  'agents-tab-tools',
  'agents-tab-recall',
];

const _localDocs =
    'https://github.com/connordodge/open_memex/blob/main/docs/claude-desktop-setup.md';

final _badges = <Override>[
  liveTabBadgeProvider.overrideWith((ref) => '2 connected'),
  toolsTabBadgeProvider.overrideWith((ref) => '37 tools'),
  recallTabDotProvider.overrideWith((ref) => true),
];

Finder _key(String k) => find.byKey(Key(k));

/// The fills (DecoratedBox, ColoredBox) at or inside [f].
List<int> _fills(Finder f) => [
  for (final e
      in find
          .descendant(
            of: f,
            matching: find.byWidgetPredicate(
              (w) =>
                  (w is DecoratedBox && w.decoration is BoxDecoration) ||
                  w is ColoredBox,
            ),
            matchRoot: true,
          )
          .evaluate())
    switch (e.widget) {
      DecoratedBox(:final BoxDecoration decoration) =>
        decoration.color?.toARGB32() ?? 0,
      ColoredBox(:final color) => color.toARGB32(),
      _ => 0,
    },
];

/// The active chip: the one with the surface3 fill, or null before any.
List<String> _activeChips() => [
  for (final k in _tabKeys)
    if (_fills(_key(k)).contains(OmColors.surface3.toARGB32())) k,
];

bool _focusOn(Finder f, WidgetTester tester) {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null || f.evaluate().isEmpty) {
    return false;
  }
  return tester.getRect(f).inflate(1).contains(focus.rect.center);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A key press (down and up) with the frames after it.
Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _frames(tester);
}

/// Presses [key] with [modifier] held; returns whether the key down was
/// handled.
Future<bool> _pressWith(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  final handled = await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await _frames(tester);
  return handled;
}

/// Tab until focus sits on [f] (at most 12 presses).
Future<void> _tabTo(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 12 && !_focusOn(f, tester); i++) {
    await _press(tester, LogicalKeyboardKey.tab);
  }
  expect(_focusOn(f, tester), isTrue, reason: 'Tab reaches $f');
}

/// Semantics nodes under the root that satisfy [test].
List<SemanticsNode> _semantics(
  WidgetTester tester,
  bool Function(SemanticsNode n) test,
) {
  final out = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    if (test(n)) out.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return out;
}

/// The focus ring decorations (2 px inset accent border) drawn at or inside
/// [f].
List<BoxDecoration> _rings(Finder f) => [
  for (final e
      in find
          .descendant(of: f, matching: find.byType(Container), matchRoot: true)
          .evaluate())
    if ((e.widget as Container).foregroundDecoration case final BoxDecoration d)
      d,
];

class _Never extends AgentActivityNotifier {
  @override
  FutureOr<AgentActivityView> build() => Completer<AgentActivityView>().future;
}

void main() {
  holdFontFetches();

  group('before the opening-tab choice', () {
    testWidgets(
      'before the 300 ms choice no chip is active, the body is empty and no chip is a Tab stop',
      (tester) async {
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          overrides: [agentActivityAsyncProvider.overrideWith(_Never.new)],
        );
        await s.launch();

        expect(agentsSheetFinder, findsOneWidget);
        expect(_activeChips(), isEmpty, reason: 'no chip is active yet');
        expect(find.byType(ConnectTab), findsNothing);
        expect(find.byType(LiveTab), findsNothing);
        expect(find.byType(ToolsTab), findsNothing);
        expect(find.byType(RecallTab), findsNothing);
        for (final k in _tabKeys) {
          expect(_focusOn(_key(k), tester), isFalse, reason: k);
        }

        s.clock.advance(const Duration(milliseconds: 300));
        await s.settle();
        expect(_activeChips(), ['agents-tab-connect']);
        expect(find.byType(ConnectTab), findsOneWidget);
      },
    );

    testWidgets(
      'a sheet closed before its 300 ms decision leaves nothing to fire',
      (tester) async {
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          overrides: [agentActivityAsyncProvider.overrideWith(_Never.new)],
        );
        await s.launch();
        await _press(tester, LogicalKeyboardKey.escape);
        expect(agentsSheetFinder, findsNothing);

        s.clock.advance(const Duration(seconds: 2));
        await s.settle();
        expect(tester.takeException(), isNull);
        expect(agentsSheetFinder, findsNothing);
      },
    );
  });

  group('arrow keys on a chip', () {
    testWidgets(
      'Left on the first tab wraps to the last and Right on the last wraps to the first',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        expect(_activeChips(), ['agents-tab-connect']);

        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_activeChips(), ['agents-tab-live']);
        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_activeChips(), ['agents-tab-recall']);
        expect(s.read(agentsSheetTabProvider), AgentsTab.recall);
        expect(_focusOn(_key('agents-tab-recall'), tester), isTrue);

        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_activeChips(), ['agents-tab-live']);
        expect(s.read(agentsSheetTabProvider), AgentsTab.live);
        expect(_focusOn(_key('agents-tab-live'), tester), isTrue);
      },
    );

    testWidgets('a held arrow keeps moving the active tab', (tester) async {
      await pumpAgentsSheet(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(_activeChips(), ['agents-tab-tools']);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(_activeChips(), ['agents-tab-recall']);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(_activeChips(), ['agents-tab-live']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(_activeChips(), ['agents-tab-live'], reason: 'key up is ignored');
    });

    testWidgets(
      'an arrow with Shift Ctrl Alt or Meta held does not move the tab',
      (tester) async {
        await pumpAgentsSheet(tester);
        for (final modifier in [
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.metaLeft,
        ]) {
          await _pressWith(tester, modifier, LogicalKeyboardKey.arrowRight);
          expect(_activeChips(), [
            'agents-tab-connect',
          ], reason: '${modifier.keyLabel} Right leaves the tab');
        }
        // The same key alone moves it.
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_activeChips(), ['agents-tab-tools']);
      },
    );

    testWidgets('a letter key on a chip is not handled and moves nothing', (
      tester,
    ) async {
      await pumpAgentsSheet(tester);
      final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await _frames(tester);
      expect(handled, isFalse);
      expect(_activeChips(), ['agents-tab-connect']);
    });

    testWidgets(
      'Tab visits the active chip only, never an inactive one, and Left then Tab visits the new active chip',
      (tester) async {
        await pumpAgentsSheet(tester);
        final seen = <String>{};
        // A full lap and more: the body's Tab stops (Connect has nine) sit
        // between the tab row and the footer, and the chip is the lap's last.
        for (var i = 0; i < 24; i++) {
          await _press(tester, LogicalKeyboardKey.tab);
          for (final k in _tabKeys) {
            if (_focusOn(_key(k), tester)) seen.add(k);
          }
        }
        expect(seen, {'agents-tab-connect'});

        await _tabTo(tester, _key('agents-tab-connect'));
        await _press(tester, LogicalKeyboardKey.arrowLeft);
        seen.clear();
        for (var i = 0; i < 24; i++) {
          await _press(tester, LogicalKeyboardKey.tab);
          for (final k in _tabKeys) {
            if (_focusOn(_key(k), tester)) seen.add(k);
          }
        }
        expect(seen, {'agents-tab-live'});
      },
    );
  });

  group('docs link keys', () {
    testWidgets(
      'Enter numpad Enter and Space on the focused docs link open it once each and other keys do nothing',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        await _tabTo(tester, _key('agents-sheet-docs'));
        expect(s.opener.opened, isEmpty);

        for (final (i, key) in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ].indexed) {
          await _press(tester, key);
          expect(s.opener.opened, hasLength(i + 1), reason: key.keyLabel);
          expect(s.opener.opened.last, _localDocs);
        }

        final other = await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await _frames(tester);
        expect(other, isFalse);
        expect(s.opener.opened, hasLength(3));
      },
    );

    testWidgets(
      'a held Enter or a key up on the docs link opens it no more than the key down',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        await _tabTo(tester, _key('agents-sheet-docs'));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        expect(s.opener.opened, [_localDocs]);
      },
    );
  });

  group('focus rings', () {
    tearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets(
      'the focused chip and docs link draw a 2 px inset accent ring in traditional highlight mode only',
      (tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await pumpAgentsSheet(tester);

        // The focused (active) chip has the ring; unfocused chips and the
        // unfocused docs link have none.
        final ring = _rings(_key('agents-tab-connect'));
        expect(ring, hasLength(1));
        expect(
          ring.single.border,
          Border.all(
            color: OmColors.accent,
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        );
        expect(ring.single.borderRadius, BorderRadius.circular(5));
        for (final k in ['agents-tab-live', 'agents-tab-tools']) {
          expect(_rings(_key(k)), isEmpty, reason: k);
        }
        expect(_rings(_key('agents-sheet-docs')), isEmpty);

        await _tabTo(tester, _key('agents-sheet-docs'));
        final docs = _rings(_key('agents-sheet-docs'));
        expect(docs, hasLength(1));
        expect(
          docs.single.border,
          Border.all(
            color: OmColors.accent,
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        );
        expect(docs.single.borderRadius, BorderRadius.circular(4));
        expect(_rings(_key('agents-tab-connect')), isEmpty);
      },
    );

    testWidgets('in touch highlight mode a focused chip draws no ring', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await pumpAgentsSheet(tester);
      expect(_focusOn(_key('agents-tab-connect'), tester), isTrue);
      expect(_rings(_key('agents-tab-connect')), isEmpty);
    });
  });

  group('semantics', () {
    testWidgets(
      'the Agents title is a header leaf node and the tab chips are leaf nodes labelled with their badge',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpAgentsSheet(tester, overrides: _badges);

        final headers = _semantics(
          tester,
          (n) =>
              n.getSemanticsData().flagsCollection.isHeader &&
              n.getSemanticsData().label == 'Agents',
        );
        expect(headers, hasLength(1));
        expect(headers.single.childrenCount, 0);

        final tabLabels = {
          'agents-tab-live': 'Live 2 connected',
          'agents-tab-connect': 'Connect',
          'agents-tab-tools': 'Tools 37 tools',
          'agents-tab-recall': 'Semantic recall',
        };
        for (final MapEntry(:key, :value) in tabLabels.entries) {
          final node = tester.getSemantics(_key(key));
          expect(node.label, value, reason: key);
          expect(node.childrenCount, 0, reason: '$key is a leaf');
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
        }
        semantics.dispose();
      },
    );

    testWidgets(
      'the close x is a button, the docs link is a link leaf, and the footer Close is a button',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpAgentsSheet(tester);

        final close = tester.getSemantics(_key('agents-sheet-close'));
        expect(close.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(close.label, 'close');

        final docs = tester.getSemantics(_key('agents-sheet-docs'));
        expect(docs.getSemanticsData().flagsCollection.isLink, isTrue);
        expect(docs.label, 'docs/claude-desktop-setup.md ↗');
        expect(docs.childrenCount, 0, reason: 'a leaf node');
        expect(docs.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

        final footer = tester.getSemantics(_key('agents-sheet-footer-close'));
        expect(footer.getSemanticsData().flagsCollection.isButton, isTrue);
        semantics.dispose();
      },
    );

    testWidgets('the docs link semantics tap opens the link once', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final s = await pumpAgentsSheet(tester);
      tester.binding.platformDispatcher.onSemanticsActionEvent!(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          viewId: tester.view.viewId,
          nodeId: tester.getSemantics(_key('agents-sheet-docs')).id,
        ),
      );
      await _frames(tester);
      expect(s.opener.opened, [_localDocs]);
      semantics.dispose();
    });

    testWidgets('the status bar button is a button announced as its label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpAgentsSheet(
        tester,
        open: false,
        host: const Align(
          alignment: Alignment.topLeft,
          child: AgentsStatusBarButton(key: Key('pin-status-bar-agents')),
        ),
      );
      final node = tester.getSemantics(_key('pin-status-bar-agents'));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(node.label, 'agents ⇧⌘A');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });
  });

  group('the close x hover', () {
    testWidgets('the close x fills surface3 while hovered and clears on exit', (
      tester,
    ) async {
      await pumpAgentsSheet(tester);
      Color? fill() =>
          ((tester.widget<Container>(_key('agents-sheet-close')).decoration)
                  as BoxDecoration)
              .color;
      expect(fill(), Colors.transparent, reason: 'first frame');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();

      await mouse.moveTo(tester.getCenter(_key('agents-sheet-close')));
      await tester.pump();
      expect(fill(), OmColors.surface3);

      await mouse.moveTo(const Offset(5, 400));
      await tester.pump();
      expect(fill(), Colors.transparent);
    });
  });

  group('Window menu attach', () {
    testWidgets(
      'AgentsWindowMenuAttach attaches once, opens the sheet on openAgents and detaches when it unmounts',
      (tester) async {
        final show = ValueNotifier(true);
        addTearDown(show.dispose);
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          host: ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (_, on, _) =>
                on ? const AgentsWindowMenuAttach() : const SizedBox.shrink(),
          ),
        );
        expect(s.menuHost.isAttached, isTrue);
        expect(s.menuHost.attachCount, 1);
        expect(s.menuHost.detachCount, 0);

        s.menuHost.simulateOpenAgents();
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));
        await _press(tester, LogicalKeyboardKey.escape);

        show.value = false;
        await tester.pump();
        expect(s.menuHost.isAttached, isFalse);
        expect(s.menuHost.detachCount, 1);
      },
    );
  });

  group('the sheet and its vault', () {
    testWidgets('clearing the vault with the sheet open closes the sheet', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      expect(s.openCallsCompleted, 0);

      s.container.read(currentVaultProvider.notifier).state = null;
      await tester.pumpAndSettle();

      expect(agentsSheetFinder, findsNothing);
      expect(s.openCallsCompleted, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching to another vault with the sheet open closes it', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);

      s.container.read(currentVaultProvider.notifier).state =
          const LocalVaultRef('/vaults/Other');
      await tester.pumpAndSettle();

      expect(agentsSheetFinder, findsNothing);
      expect(s.openCallsCompleted, 1);
    });

    testWidgets('the vault set again to an equal value leaves the sheet open', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);

      // A new, equal instance (built at run time so it is not the same
      // const object): the provider notifies, the vault is unchanged.
      final same = LocalVaultRef(['/Users/tester', 'vaults/Studio'].join('/'));
      expect(identical(same, agentsSheetLocalVault), isFalse);
      expect(same, agentsSheetLocalVault);
      s.container.read(currentVaultProvider.notifier).state = same;
      await tester.pumpAndSettle();

      expect(agentsSheetFinder, findsOneWidget);
      expect(s.openCallsCompleted, 0);
    });

    testWidgets(
      'while the sheet fades out after its vault was cleared the chip and docs link still name the vault it opened for',
      (tester) async {
        final s = await pumpAgentsSheet(tester, vault: agentsSheetHostedVault);
        expect(find.text('docs/hosted-vault.md ↗'), findsOneWidget);

        s.container.read(currentVaultProvider.notifier).state = null;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(agentsSheetFinder, findsOneWidget, reason: 'still fading');
        expect(
          find.descendant(
            of: _key('agents-sheet-vault-chip'),
            matching: find.text('studio · nas · hosted'),
          ),
          findsOneWidget,
        );
        expect(find.text('docs/hosted-vault.md ↗'), findsOneWidget);
        expect(find.text('docs/claude-desktop-setup.md ↗'), findsNothing);
        await tester.pumpAndSettle();
        expect(agentsSheetFinder, findsNothing);
      },
    );

    testWidgets(
      'a vault change while another dialog covers the sheet does not pop that dialog',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        final nav = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          showDialog<void>(
            context: nav.context,
            builder: (_) => const Center(
              child: SizedBox(
                key: Key('covering-dialog'),
                width: 40,
                height: 40,
              ),
            ),
          ),
        );
        await _frames(tester);
        expect(find.byKey(const Key('covering-dialog')), findsOneWidget);

        s.container.read(currentVaultProvider.notifier).state = null;
        await _frames(tester);

        expect(find.byKey(const Key('covering-dialog')), findsOneWidget);
        expect(s.openCallsCompleted, 0);
      },
    );
  });

  group('re-entry from a context with no route', () {
    // The Navigator's own context has no ModalRoute above it, so only the
    // per-navigator mark stops a second sheet.
    NavigatorState navigator(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator));

    testWidgets('two calls from the navigator context open one sheet', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester, open: false);
      final navCtx = navigator(tester).context;

      unawaited(openAgentsSheet(navCtx));
      unawaited(openAgentsSheet(navCtx));
      await s.settle();
      await s.decide();
      expect(agentsSheetFinder, findsOneWidget);
      expect(s.routes.dialogs, hasLength(1));

      unawaited(openAgentsSheet(navCtx));
      await s.settle();
      expect(s.routes.dialogs, hasLength(1));
    });

    testWidgets(
      'a reopen during the 150 ms fade-out opens nothing and one after it opens the sheet again',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        final navCtx = navigator(tester).context;
        expect(s.routes.dialogs, hasLength(1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(s.openCallsCompleted, 1, reason: 'the future completes at pop');

        unawaited(openAgentsSheet(navCtx));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(s.routes.dialogs, hasLength(1), reason: 'fading: no new sheet');
        await tester.pumpAndSettle();
        expect(agentsSheetFinder, findsNothing);
        expect(s.routes.dialogs, hasLength(1));

        unawaited(openAgentsSheet(navCtx));
        await s.settle();
        await s.decide();
        expect(s.routes.dialogs, hasLength(2));
        expect(agentsSheetFinder, findsOneWidget);
      },
    );
  });
}
