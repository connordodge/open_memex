// WI #407 (SH; Spec #394 req 1, 4, 6, 8-12, 44, 46, 47; D14, D31; design
// pack design/394-agents-sheet/packs/407.md and RULINGS.md #5-#12): the
// Agents sheet shell. Header, width, tabs and their badges, the opening-tab
// rule, closing, the docs link, focus and keys, AgentsTabLoading, re-entry
// and the narrow and large-text layouts. Every test opens the sheet with
// `openAgentsSheet` through `pumpAgentsSheet` (or the running workspace for
// the Window menu entry).
//
// flutter_test draws every glyph one em wide (holdFontFetches keeps the
// fallback font), so the 1.5x layout tests are stricter than the real
// fonts.
import 'dart:async';
import 'dart:ui' show SemanticsRole, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_sheet_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/live_tab_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/recall_tab_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/tools_tab_state.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_sheet.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_tab_loading.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/live_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/recall_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/tools_tab.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/app_harness.dart';
import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ fixtures

const _localDocs =
    'https://github.com/connordodge/open_memex/blob/main/docs/claude-desktop-setup.md';
const _hostedDocs =
    'https://github.com/connordodge/open_memex/blob/main/docs/hosted-vault.md';

const _tabKeys = [
  'agents-tab-live',
  'agents-tab-connect',
  'agents-tab-tools',
  'agents-tab-recall',
];

Finder _key(String k) => find.byKey(Key(k));

Finder _inSheet(Finder f) =>
    find.descendant(of: agentsSheetFinder, matching: f);

/// Badges on every chip: the widest tab row.
final _allBadges = <Override>[
  liveTabBadgeProvider.overrideWith((ref) => '2 connected'),
  toolsTabBadgeProvider.overrideWith((ref) => '37 tools'),
  recallTabDotProvider.overrideWith((ref) => true),
];

/// A view with [connected] agents, built from run-time values.
AgentActivityView _view({int connected = 0, bool available = true}) =>
    AgentActivityView(
      connected: [
        for (var i = 0; i < connected; i++)
          ConnectedAgent(
            presence: agentPresence(
              sessionId: '01JAGENTSESSION000000000${i}Z',
              clientName: 'claude-desktop-$i',
            ),
            working: i.isEven,
          ),
      ],
      recent: [agentEntry(summary: 'filed $connected blocks')],
      available: available,
      clockOffsetMs: 0,
    );

/// Scripts `agentActivityAsyncProvider`: each build waits on [pending]; a
/// bump of [generation] rebuilds it (Riverpod keeps the previous value on
/// that AsyncLoading, as after a vault switch, D31).
class _ActivityScript {
  Completer<AgentActivityView> pending = Completer();
  final generation = StateProvider<int>((_) => 0);
  int builds = 0;
  _ScriptedActivity? notifier;

  Override get override =>
      agentActivityAsyncProvider.overrideWith(() => _ScriptedActivity(this));

  void resolve(AgentActivityView view) => pending.complete(view);

  void fail(Object error) => pending.completeError(error);

  /// A later presence-tick value while the sheet is open.
  void push(AgentActivityView view) => notifier!.push(view);
}

class _ScriptedActivity extends AgentActivityNotifier {
  _ScriptedActivity(this._script);

  final _ActivityScript _script;

  @override
  FutureOr<AgentActivityView> build() {
    ref.watch(_script.generation);
    _script.builds++;
    _script.notifier = this;
    return _script.pending.future;
  }

  void push(AgentActivityView view) => state = AsyncData(view);
}

// ------------------------------------------------------------------ helpers

/// Every chip text as one string: its text pieces trimmed and joined by a
/// space (`Live 2 connected` whether the badge is a span or its own Text).
String _chipText(WidgetTester tester, String key) {
  final parts = [
    for (final e
        in find
            .descendant(of: _key(key), matching: find.byType(RichText))
            .evaluate())
      (e.widget as RichText).text.toPlainText().trim(),
  ].where((t) => t.isNotEmpty);
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

Color? _fillOf(Widget w) => switch (w) {
  DecoratedBox(:final BoxDecoration decoration) => decoration.color,
  ColoredBox(:final color) => color,
  Material(:final color) => color,
  _ => null,
};

/// The fills drawn at or inside [f] (DecoratedBox, ColoredBox, Material).
List<int> _fills(Finder f) => [
  for (final e
      in find
          .descendant(
            of: f,
            matching: find.byWidgetPredicate((w) => _fillOf(w) != null),
            matchRoot: true,
          )
          .evaluate())
    _fillOf(e.widget)!.toARGB32(),
];

bool _isActiveChip(String key) =>
    _fills(_key(key)).contains(OmColors.surface3.toARGB32());

/// The one chip with the surface3 fill.
String _activeTab() {
  final active = [
    for (final k in _tabKeys)
      if (_isActiveChip(k)) k,
  ];
  expect(active, hasLength(1), reason: 'exactly one active chip: $active');
  return active.single;
}

/// The colour of the span whose text (trimmed) is [text] inside [f], with
/// inherited styles applied.
Color? _spanColor(WidgetTester tester, Finder f, String text) {
  Color? found;
  for (final e
      in find.descendant(of: f, matching: find.byType(RichText)).evaluate()) {
    void visit(InlineSpan span, Color? inherited) {
      final color = span.style?.color ?? inherited;
      if (span is TextSpan) {
        if ((span.text ?? '').trim() == text) found ??= color;
        for (final c in span.children ?? const <InlineSpan>[]) {
          visit(c, color);
        }
      }
    }

    visit((e.widget as RichText).text, null);
  }
  return found;
}

/// The circle dots drawn inside [f]: colour and size.
List<(int, Size)> _dots(WidgetTester tester, Finder f) => [
  for (final e
      in find
          .descendant(
            of: f,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).shape == BoxShape.circle,
            ),
          )
          .evaluate())
    (
      ((e.widget as DecoratedBox).decoration as BoxDecoration).color!
          .toARGB32(),
      (e.renderObject! as RenderBox).size,
    ),
];

/// Whether the primary focus sits on [f]'s box.
bool _focusOn(WidgetTester tester, Finder f) {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null || f.evaluate().isEmpty) {
    return false;
  }
  return tester.getRect(f).inflate(1).contains(focus.rect.center);
}

/// Where the primary focus is: one of the sheet's keyed stops, `sheet`
/// (elsewhere in the sheet) or `outside`.
String _focusStop(WidgetTester tester) {
  for (final k in [
    ..._tabKeys,
    'agents-sheet-docs',
    'agents-sheet-footer-close',
    'agents-sheet-close',
  ]) {
    if (_focusOn(tester, _key(k))) return k;
  }
  return _focusOn(tester, agentsSheetFinder) ? 'sheet' : 'outside';
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// ⇧⌘A as key events; returns whether the framework handled the A.
Future<bool> _pressShiftCmdA(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  return handled;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(_key(key));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<SemanticsNode> _semanticsWithRole(
  WidgetTester tester,
  SemanticsRole role,
) {
  final out = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    if (n.getSemanticsData().role == role) out.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  final root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  visit(root);
  return out;
}

/// The vertical Scrollables inside the sheet.
List<Element> _verticalScrollables() => [
  for (final e in _inSheet(find.byType(Scrollable)).evaluate())
    if (axisDirectionToAxis((e.widget as Scrollable).axisDirection) ==
        Axis.vertical)
      e,
];

/// The horizontal Scrollable that holds the tab chips.
Finder _tabRowScrollable() => find.ancestor(
  of: _key('agents-tab-live'),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Scrollable &&
        axisDirectionToAxis(w.axisDirection) == Axis.horizontal,
  ),
);

/// Every text in the header, tab row and footer: none cut or laid out
/// shorter than its lines. [exempt] texts may ellipsize (the vault chip).
void _expectChromeNotClipped(
  WidgetTester tester,
  String why, {
  Set<String> exempt = const {},
}) {
  expect(tester.takeException(), isNull, reason: '$why: no overflow');
  final sheet = tester.getRect(agentsSheetFinder);
  final chrome = <Finder>[
    for (final k in [
      ..._tabKeys,
      'agents-sheet-close',
      'agents-sheet-footer-close',
      'agents-sheet-docs',
    ])
      _key(k),
  ];
  for (final f in chrome) {
    expect(f, findsOneWidget, reason: why);
    for (final e
        in find
            .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
            .evaluate()) {
      final p = e.renderObject! as RenderParagraph;
      final text = p.text.toPlainText();
      if (exempt.contains(text)) continue;
      expect(p.didExceedMaxLines, isFalse, reason: '$why: "$text" is cut');
      // OmButton's fixed height trims only the line's leading at 1.5x (its
      // glyphs still fit); its label is checked for width alone.
      final inButton = find
          .ancestor(
            of: find.byWidget(e.widget),
            matching: find.byType(OmButton),
          )
          .evaluate()
          .isNotEmpty;
      if (!inButton) {
        expect(
          p.size.height + 0.5,
          greaterThanOrEqualTo(p.getMinIntrinsicHeight(p.size.width)),
          reason: '$why: "$text" is laid out shorter than its lines',
        );
      }
      expect(
        p.size.width + 0.5,
        greaterThanOrEqualTo(p.getMinIntrinsicWidth(p.size.height)),
        reason: '$why: "$text" is squeezed',
      );
    }
  }
  for (final k in [
    'agents-sheet-close',
    'agents-sheet-footer-close',
    'agents-sheet-docs',
  ]) {
    final r = tester.getRect(_key(k));
    expect(r.left, greaterThanOrEqualTo(sheet.left - 0.5), reason: '$why $k');
    expect(r.right, lessThanOrEqualTo(sheet.right + 0.5), reason: '$why $k');
  }
}

void main() {
  holdFontFetches();

  // ================================================================ AC 1
  group('header (AC1)', () {
    testWidgets(
      'openAgentsSheet shows agents-sheet with the Agents header, the local vault chip and a close x',
      (tester) async {
        await pumpAgentsSheet(tester);

        expect(agentsSheetFinder, findsOneWidget);
        final title = _inSheet(
          find.byWidgetPredicate(
            (w) =>
                w is RichText && w.text.toPlainText().toLowerCase() == 'agents',
          ),
        );
        expect(title, findsOneWidget);
        final chip = _inSheet(_key('agents-sheet-vault-chip'));
        expect(chip, findsOneWidget);
        expect(
          _chipText(tester, 'agents-sheet-vault-chip'),
          'Studio · local vault',
        );
        final close = _inSheet(_key('agents-sheet-close'));
        expect(close, findsOneWidget);

        // One row, left to right: title, chip, then the x at the far right.
        final t = tester.getRect(title);
        final c = tester.getRect(chip);
        final x = tester.getRect(close);
        expect(t.right, lessThanOrEqualTo(c.left));
        expect(c.right, lessThanOrEqualTo(x.left));
        expect((t.center.dy - x.center.dy).abs(), lessThan(4));
        expect(x.top, greaterThan(tester.getRect(agentsSheetFinder).top));
        expect(
          x.top,
          lessThan(tester.getRect(_key('agents-tab-live')).top),
          reason: 'the header sits above the tab row',
        );
      },
    );

    testWidgets('a hosted vault shows the chip vault then server then hosted', (
      tester,
    ) async {
      await pumpAgentsSheet(tester, vault: agentsSheetHostedVault);

      expect(agentsSheetFinder, findsOneWidget);
      expect(
        _chipText(tester, 'agents-sheet-vault-chip'),
        'studio · nas · hosted',
      );
    });

    testWidgets('the close x is a 24 px button announced as close', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpAgentsSheet(tester);

      expect(tester.getSize(_key('agents-sheet-close')), const Size(24, 24));
      final data = tester.getSemantics(_key('agents-sheet-close'));
      expect(data.label, 'close');
      expect(data.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });
  });

  // ================================================================ AC 2
  group('width and height (AC2)', () {
    testWidgets(
      'the sheet is 720 wide in a 1000 px window and 32 narrower than a 700 px window',
      (tester) async {
        for (final (window, width) in [
          (1000.0, 720.0),
          (753.0, 720.0),
          (752.0, 720.0),
          (751.0, 719.0),
          (700.0, 668.0),
          (480.0, 448.0),
        ]) {
          await pumpAgentsSheet(tester, size: Size(window, 800));
          final r = tester.getRect(agentsSheetFinder);
          expect(r.width, width, reason: '$window px window');
          expect(r.center.dx, window / 2, reason: '$window: centred');
          expect(r.top, 0, reason: '$window: top-anchored');
          await tester.pumpWidget(const SizedBox());
        }
      },
    );

    testWidgets(
      'in a short window the sheet is no taller than the window and its body scrolls between the tabs and the footer',
      (tester) async {
        // 160 px is shorter than the chrome (header, tabs, body padding,
        // footer), so the body has to shrink and scroll.
        await pumpAgentsSheet(tester, size: const Size(1000, 160));

        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(agentsSheetFinder);
        expect(sheet.height, lessThanOrEqualTo(160.5));
        expect(sheet.bottom, lessThanOrEqualTo(160.5));
        final footerClose = tester.getRect(_key('agents-sheet-footer-close'));
        expect(footerClose.bottom, lessThanOrEqualTo(sheet.bottom));
        expect(footerClose.top, greaterThanOrEqualTo(0));

        final body = _verticalScrollables();
        expect(body, isNotEmpty, reason: 'the body scrolls vertically');
        final tabsBottom = tester.getRect(_key('agents-tab-connect')).bottom;
        final footerTop = tester.getRect(_key('agents-sheet-docs')).top;
        final scroll = tester.getRect(find.byWidget(body.first.widget));
        expect(scroll.top, greaterThanOrEqualTo(tabsBottom - 0.5));
        expect(scroll.bottom, lessThanOrEqualTo(footerTop + 0.5));
        final position = tester
            .state<ScrollableState>(find.byWidget(body.first.widget))
            .position;
        expect(
          position.maxScrollExtent,
          greaterThan(0),
          reason: 'the body is taller than the room left and scrolls',
        );
      },
    );

    testWidgets(
      'the sheet uses the setup-sheet frame: surface2, line2 sides and bottom, no top border, bottom radius 10 and the dialog shadow',
      (tester) async {
        await pumpAgentsSheet(tester);

        final decorations = [
          for (final e
              in find
                  .descendant(
                    of: agentsSheetFinder,
                    matching: find.byType(DecoratedBox),
                    matchRoot: true,
                  )
                  .evaluate())
            (e.widget as DecoratedBox).decoration,
        ].whereType<BoxDecoration>().where((d) => d.color == OmColors.surface2);
        expect(decorations, isNotEmpty, reason: 'a surface2 panel');
        final d = decorations.first;
        expect(
          d.border,
          Border(
            left: BorderSide(color: OmColors.line2),
            right: BorderSide(color: OmColors.line2),
            bottom: BorderSide(color: OmColors.line2),
          ),
        );
        expect(
          d.borderRadius,
          const BorderRadius.vertical(bottom: Radius.circular(10)),
        );
        expect(d.boxShadow, [
          const BoxShadow(
            color: OmColors.dialogShadow,
            offset: Offset(0, 24),
            blurRadius: 64,
          ),
        ]);

        // The barrier: surface0 at 184, fully faded in; a 150 ms fade.
        final barrier = tester
            .widgetList<ModalBarrier>(find.byType(ModalBarrier))
            .last;
        expect(barrier.color, OmColors.surface0.withAlpha(184));
        final route = ModalRoute.of(tester.element(agentsSheetFinder))!;
        expect(route.transitionDuration, const Duration(milliseconds: 150));
        expect(route, isA<PopupRoute<dynamic>>());
      },
    );
  });

  // ================================================================ AC 3
  group('tabs (AC3)', () {
    testWidgets(
      'tabs render Live Connect Tools Semantic recall in order with the active chip surface3 and fg0 and the others fg2',
      (tester) async {
        await pumpAgentsSheet(tester);

        final labels = ['Live', 'Connect', 'Tools', 'Semantic recall'];
        double? lastLeft;
        for (var i = 0; i < _tabKeys.length; i++) {
          final chip = _inSheet(_key(_tabKeys[i]));
          expect(chip, findsOneWidget, reason: _tabKeys[i]);
          expect(_chipText(tester, _tabKeys[i]), labels[i]);
          final left = tester.getRect(chip).left;
          if (lastLeft != null) expect(left, greaterThan(lastLeft));
          lastLeft = left;
        }

        // No agents connected: Connect is active.
        expect(_activeTab(), 'agents-tab-connect');
        for (var i = 0; i < _tabKeys.length; i++) {
          final active = _tabKeys[i] == 'agents-tab-connect';
          expect(
            _spanColor(tester, _key(_tabKeys[i]), labels[i])?.toARGB32(),
            (active ? OmColors.fg0 : OmColors.fg2).toARGB32(),
            reason: '${labels[i]} label colour',
          );
          expect(
            _fills(_key(_tabKeys[i])).contains(OmColors.surface3.toARGB32()),
            active,
            reason: '${labels[i]} fill',
          );
        }
        // The active tab's body shows.
        expect(find.byType(ConnectTab), findsOneWidget);
        expect(find.byType(LiveTab), findsNothing);
        expect(find.byType(ToolsTab), findsNothing);
        expect(find.byType(RecallTab), findsNothing);
      },
    );

    testWidgets(
      'the tab chips are announced as tabs in a tab bar with the active one selected',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpAgentsSheet(tester);

        final tabs = _semanticsWithRole(tester, SemanticsRole.tab);
        expect(tabs, hasLength(4));
        final labels = [for (final t in tabs) t.getSemanticsData().label];
        expect(labels[0], startsWith('Live'));
        expect(labels[1], startsWith('Connect'));
        expect(labels[2], startsWith('Tools'));
        expect(labels[3], startsWith('Semantic recall'));
        expect(
          [
            for (final t in tabs)
              t.getSemanticsData().flagsCollection.isSelected,
          ],
          [
            Tristate.isFalse,
            Tristate.isTrue,
            Tristate.isFalse,
            Tristate.isFalse,
          ],
        );
        for (final t in tabs) {
          expect(t.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
          var parent = t.parent;
          var inTabBar = false;
          while (parent != null) {
            if (parent.getSemanticsData().role == SemanticsRole.tabBar) {
              inTabBar = true;
              break;
            }
            parent = parent.parent;
          }
          expect(inTabBar, isTrue, reason: '${t.label} sits in a tab bar');
        }

        // The selected state follows the active tab.
        await _press(tester, LogicalKeyboardKey.arrowRight);
        final after = _semanticsWithRole(tester, SemanticsRole.tab);
        expect(
          [
            for (final t in after)
              t.getSemanticsData().flagsCollection.isSelected,
          ],
          [
            Tristate.isFalse,
            Tristate.isFalse,
            Tristate.isTrue,
            Tristate.isFalse,
          ],
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'tapping a chip makes it active and shows its body, and a tab can switch tabs with select',
      (tester) async {
        final s = await pumpAgentsSheet(tester);

        await _tapKey(tester, 'agents-tab-tools');
        expect(_activeTab(), 'agents-tab-tools');
        expect(s.read(agentsSheetTabProvider), AgentsTab.tools);
        expect(find.byType(ToolsTab), findsOneWidget);
        expect(find.byType(ConnectTab), findsNothing);

        s.read(agentsSheetTabProvider.notifier).select(AgentsTab.recall);
        await s.settle();
        expect(_activeTab(), 'agents-tab-recall');
        expect(find.byType(RecallTab), findsOneWidget);

        s.read(agentsSheetTabProvider.notifier).select(AgentsTab.live);
        await s.settle();
        expect(_activeTab(), 'agents-tab-live');
        expect(find.byType(LiveTab), findsOneWidget);
      },
    );

    testWidgets(
      'the tab chips are 28 high and the footer Close is 28 high at 1x text',
      (tester) async {
        await pumpAgentsSheet(tester);
        for (final k in _tabKeys) {
          expect(tester.getSize(_key(k)).height, 28, reason: k);
        }
        expect(tester.getSize(_key('agents-sheet-footer-close')).height, 28);
      },
    );
  });

  // ================================================================ AC 4
  group('badges (AC4)', () {
    testWidgets(
      'badge suffixes render from their providers and the recall dot follows its provider',
      (tester) async {
        await pumpAgentsSheet(tester, overrides: _allBadges);

        expect(_chipText(tester, 'agents-tab-live'), 'Live 2 connected');
        expect(_chipText(tester, 'agents-tab-tools'), 'Tools 37 tools');
        expect(_chipText(tester, 'agents-tab-connect'), 'Connect');
        expect(_chipText(tester, 'agents-tab-recall'), 'Semantic recall');

        // Suffixes are fg2, even beside an fg0 label.
        expect(
          _spanColor(
            tester,
            _key('agents-tab-live'),
            '2 connected',
          )?.toARGB32(),
          OmColors.fg2.toARGB32(),
        );
        // Ruling 7: no dot on the Live tab.
        expect(_dots(tester, _key('agents-tab-live')), isEmpty);
        expect(_dots(tester, _key('agents-tab-tools')), isEmpty);
        expect(_dots(tester, _key('agents-tab-recall')), [
          (OmColors.accent.toARGB32(), const Size(6, 6)),
        ]);

        // In the active chip the suffix stays fg2 while the label is fg0.
        await _tapKey(tester, 'agents-tab-tools');
        expect(
          _spanColor(tester, _key('agents-tab-tools'), 'Tools')?.toARGB32(),
          OmColors.fg0.toARGB32(),
        );
        expect(
          _spanColor(tester, _key('agents-tab-tools'), '37 tools')?.toARGB32(),
          OmColors.fg2.toARGB32(),
        );
      },
    );

    testWidgets('an off recall dot is fg2', (tester) async {
      await pumpAgentsSheet(
        tester,
        overrides: [recallTabDotProvider.overrideWith((ref) => false)],
      );
      expect(agentsSheetFinder, findsOneWidget);
      expect(_dots(tester, _key('agents-tab-recall')), [
        (OmColors.fg2.toARGB32(), const Size(6, 6)),
      ]);
    });

    testWidgets(
      'with every badge provider null the chips read bare Live and Tools and show no dot',
      (tester) async {
        await pumpAgentsSheet(
          tester,
          overrides: [
            liveTabBadgeProvider.overrideWith((ref) => null),
            toolsTabBadgeProvider.overrideWith((ref) => null),
            recallTabDotProvider.overrideWith((ref) => null),
          ],
        );
        expect(agentsSheetFinder, findsOneWidget);
        expect(_chipText(tester, 'agents-tab-live'), 'Live');
        expect(_chipText(tester, 'agents-tab-tools'), 'Tools');
        expect(_chipText(tester, 'agents-tab-recall'), 'Semantic recall');
        for (final k in _tabKeys) {
          expect(_dots(tester, _key(k)), isEmpty, reason: k);
        }
      },
    );

    testWidgets(
      'a badge that changes while the sheet is open updates its chip',
      (tester) async {
        final count = StateProvider<int>((_) => 1);
        final s = await pumpAgentsSheet(
          tester,
          overrides: [
            liveTabBadgeProvider.overrideWith(
              (ref) => '${ref.watch(count)} connected',
            ),
          ],
        );
        expect(_chipText(tester, 'agents-tab-live'), 'Live 1 connected');
        s.read(count.notifier).state = 3;
        await s.settle();
        expect(_chipText(tester, 'agents-tab-live'), 'Live 3 connected');
      },
    );
  });

  // ================================================================ AC 5
  group('opening tab (AC5, D31)', () {
    Future<(AgentsSheetHarness, _ActivityScript)> launch(
      WidgetTester tester,
    ) async {
      final script = _ActivityScript();
      final s = await pumpAgentsSheet(
        tester,
        open: false,
        overrides: [script.override],
      );
      await s.launch();
      expect(agentsSheetFinder, findsOneWidget, reason: 'the sheet is open');
      return (s, script);
    }

    testWidgets(
      'activity resolving at 200 ms with one connected agent opens on Live',
      (tester) async {
        final (s, script) = await launch(tester);
        s.clock.advance(const Duration(milliseconds: 200));
        script.resolve(_view(connected: 1));
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 100));
        await s.settle();

        expect(_activeTab(), 'agents-tab-live');
        expect(s.read(agentsSheetTabProvider), AgentsTab.live);
        expect(find.byType(LiveTab), findsOneWidget);
      },
    );

    testWidgets(
      'activity resolving at 299 ms with one connected agent opens on Live',
      (tester) async {
        final (s, script) = await launch(tester);
        s.clock.advance(const Duration(milliseconds: 299));
        await s.settle();
        script.resolve(_view(connected: 1));
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 1));
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 500));
        await s.settle();

        expect(_activeTab(), 'agents-tab-live');
      },
    );

    testWidgets(
      'activity resolving at 200 ms with none connected opens on Connect',
      (tester) async {
        final (s, script) = await launch(tester);
        s.clock.advance(const Duration(milliseconds: 200));
        script.resolve(_view());
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 100));
        await s.settle();

        expect(_activeTab(), 'agents-tab-connect');
        expect(s.read(agentsSheetTabProvider), AgentsTab.connect);
        expect(find.byType(ConnectTab), findsOneWidget);
      },
    );

    testWidgets(
      'activity still loading at 300 ms opens on Connect and stays there when it resolves with agents',
      (tester) async {
        final (s, script) = await launch(tester);
        s.clock.advance(const Duration(milliseconds: 300));
        await s.settle();
        expect(_activeTab(), 'agents-tab-connect');

        script.resolve(_view(connected: 2));
        await s.settle();
        s.clock.advance(const Duration(seconds: 5));
        await s.settle();
        expect(_activeTab(), 'agents-tab-connect');
        expect(s.read(agentsSheetTabProvider), AgentsTab.connect);
      },
    );

    testWidgets(
      'unavailable activity opens on Connect even with a connected agent',
      (tester) async {
        final (s, script) = await launch(tester);
        s.clock.advance(const Duration(milliseconds: 200));
        script.resolve(_view(connected: 1, available: false));
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 100));
        await s.settle();

        expect(_activeTab(), 'agents-tab-connect');
      },
    );

    testWidgets('errored activity opens on Connect', (tester) async {
      final (s, script) = await launch(tester);
      s.clock.advance(const Duration(milliseconds: 200));
      script.fail(StateError('read failed'));
      await s.settle();
      s.clock.advance(const Duration(milliseconds: 100));
      await s.settle();

      expect(tester.takeException(), isNull);
      expect(_activeTab(), 'agents-tab-connect');
    });

    testWidgets(
      'activity that already holds one connected agent when the sheet opens opens on Live',
      (tester) async {
        final script = _ActivityScript();
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          overrides: [script.override],
        );
        s.container.listen(agentActivityAsyncProvider, (_, _) {});
        script.resolve(_view(connected: 1));
        await s.settle();

        await s.open();
        expect(_activeTab(), 'agents-tab-live');
      },
    );

    testWidgets(
      'a reload still loading at 300 ms with a previous one-agent value opens on Connect',
      (tester) async {
        final script = _ActivityScript();
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          overrides: [script.override],
        );
        s.container.listen(agentActivityAsyncProvider, (_, _) {});
        script.resolve(_view(connected: 1));
        await s.settle();
        // A vault switch: AsyncLoading that still carries the old value.
        script.pending = Completer();
        s.read(script.generation.notifier).state++;
        await s.settle();
        final state = s.read(agentActivityAsyncProvider);
        expect(state.isLoading, isTrue);
        expect(state.valueOrNull?.connected, hasLength(1));

        await s.open();
        expect(_activeTab(), 'agents-tab-connect');
      },
    );

    testWidgets(
      'once open on Live the sheet stays on Live when every agent disconnects',
      (tester) async {
        final (s, script) = await launch(tester);
        script.resolve(_view(connected: 1));
        await s.settle();
        await s.decide();
        expect(_activeTab(), 'agents-tab-live');

        script.push(_view());
        await s.settle();
        s.clock.advance(const Duration(seconds: 10));
        await s.settle();
        expect(_activeTab(), 'agents-tab-live');
      },
    );

    testWidgets(
      'the opening-tab decision waits for the injected clock, not wall time',
      (tester) async {
        final (s, script) = await launch(tester);
        // A second of frames with the clock still at the open time.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        script.resolve(_view(connected: 1));
        await s.settle();
        s.clock.advance(const Duration(milliseconds: 300));
        await s.settle();
        expect(_activeTab(), 'agents-tab-live');
      },
    );
  });

  // ================================================================ AC 6
  group('closing (AC6)', () {
    testWidgets('Esc closes the sheet and completes the open call', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      expect(s.openCallsCompleted, 0);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(agentsSheetFinder, findsNothing);
      expect(s.openCallsCompleted, 1);
    });

    testWidgets('the close x closes the sheet', (tester) async {
      await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      await _tapKey(tester, 'agents-sheet-close');
      expect(agentsSheetFinder, findsNothing);
    });

    testWidgets('the footer Close closes the sheet', (tester) async {
      await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      expect(_chipText(tester, 'agents-sheet-footer-close'), 'Close');
      await _tapKey(tester, 'agents-sheet-footer-close');
      expect(agentsSheetFinder, findsNothing);
    });

    testWidgets('a tap on the barrier closes the sheet', (tester) async {
      await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      // Beside the 720 px panel in a 1000 px window.
      await tester.tapAt(const Offset(20, 400));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(agentsSheetFinder, findsNothing);
    });

    testWidgets('a tap inside the panel keeps the sheet open', (tester) async {
      await pumpAgentsSheet(tester);
      final r = tester.getRect(agentsSheetFinder);
      await tester.tapAt(Offset(r.center.dx, r.top + 4));
      await tester.pump(const Duration(milliseconds: 300));
      expect(agentsSheetFinder, findsOneWidget);
    });
  });

  // ================================================================ AC 7
  group('docs link (AC7)', () {
    testWidgets(
      'the docs link opens the local setup doc once on a local vault',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        expect(
          _chipText(tester, 'agents-sheet-docs'),
          'docs/claude-desktop-setup.md ↗',
        );
        await _tapKey(tester, 'agents-sheet-docs');
        expect(s.opener.opened, [_localDocs]);
      },
    );

    testWidgets(
      'the docs link opens the hosted vault doc once on a hosted vault',
      (tester) async {
        final s = await pumpAgentsSheet(tester, vault: agentsSheetHostedVault);
        expect(
          _chipText(tester, 'agents-sheet-docs'),
          'docs/hosted-vault.md ↗',
        );
        await _tapKey(tester, 'agents-sheet-docs');
        expect(s.opener.opened, [_hostedDocs]);
      },
    );

    testWidgets('the docs link is mono info text in the footer row', (
      tester,
    ) async {
      await pumpAgentsSheet(tester);
      expect(
        _spanColor(
          tester,
          _key('agents-sheet-docs'),
          'docs/claude-desktop-setup.md ↗',
        )?.toARGB32(),
        OmColors.info.toARGB32(),
      );
      final docs = tester.getRect(_key('agents-sheet-docs'));
      final close = tester.getRect(_key('agents-sheet-footer-close'));
      expect(
        docs.right,
        lessThan(close.left),
        reason: 'docs left, Close right',
      );
      expect((docs.center.dy - close.center.dy).abs(), lessThan(4));
      expect(
        close.right,
        greaterThan(tester.getRect(agentsSheetFinder).right - 40),
        reason: 'Close is pushed right',
      );
    });
  });

  // ================================================================ AC 8
  group('focus and keys (AC8)', () {
    testWidgets('focus starts on the active tab chip', (tester) async {
      final s = await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      expect(_focusStop(tester), 'agents-tab-connect');
      expect(s.originFocus.hasFocus, isFalse);
    });

    testWidgets('focus starts on the Live chip when the sheet opens on Live', (
      tester,
    ) async {
      final agents = FakeAgentsAccess(
        vaultPath: agentsSheetLocalVault.path,
        script: [
          AgentActivity(
            agents: [agentPresence()],
            recent: const [],
            available: true,
          ),
        ],
      );
      await pumpAgentsSheet(tester, agents: agents);
      expect(_activeTab(), 'agents-tab-live');
      expect(_focusStop(tester), 'agents-tab-live');
    });

    testWidgets(
      'Tab cycles tabs then body then footer and never leaves the sheet',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        expect(_focusStop(tester), 'agents-tab-connect');

        final stops = <String>['agents-tab-connect'];
        for (var i = 0; i < 12; i++) {
          await _press(tester, LogicalKeyboardKey.tab);
          final stop = _focusStop(tester);
          expect(stop, isNot('outside'), reason: 'Tab $i left the sheet');
          expect(s.originFocus.hasFocus, isFalse, reason: 'Tab $i');
          stops.add(stop);
        }
        final docs = stops.indexOf('agents-sheet-docs');
        final close = stops.indexOf('agents-sheet-footer-close');
        expect(
          docs,
          greaterThan(0),
          reason: 'Tab reaches the docs link: $stops',
        );
        expect(close, greaterThan(docs), reason: 'docs, then Close: $stops');
        expect(
          stops.indexOf('agents-tab-connect', close),
          greaterThan(close),
          reason: 'it comes back round to the active chip: $stops',
        );
      },
    );

    testWidgets('Shift Tab from the active chip stays in the sheet', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);
      expect(_focusStop(tester), 'agents-tab-connect');
      for (var i = 0; i < 6; i++) {
        await _press(tester, LogicalKeyboardKey.tab, shift: true);
        expect(_focusStop(tester), isNot('outside'), reason: 'Shift Tab $i');
        expect(s.originFocus.hasFocus, isFalse);
      }
    });

    testWidgets(
      'Left and Right move the active tab and its focus between chips',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        expect(_activeTab(), 'agents-tab-connect');

        for (final (key, expected, tab) in [
          (LogicalKeyboardKey.arrowRight, 'agents-tab-tools', AgentsTab.tools),
          (
            LogicalKeyboardKey.arrowRight,
            'agents-tab-recall',
            AgentsTab.recall,
          ),
          (LogicalKeyboardKey.arrowLeft, 'agents-tab-tools', AgentsTab.tools),
          (
            LogicalKeyboardKey.arrowLeft,
            'agents-tab-connect',
            AgentsTab.connect,
          ),
          (LogicalKeyboardKey.arrowLeft, 'agents-tab-live', AgentsTab.live),
        ]) {
          await _press(tester, key);
          expect(_activeTab(), expected);
          expect(s.read(agentsSheetTabProvider), tab);
          expect(_focusStop(tester), expected, reason: 'focus follows');
        }
        expect(find.byType(LiveTab), findsOneWidget);
      },
    );

    testWidgets('Right with focus on the footer Close leaves the tab alone', (
      tester,
    ) async {
      await pumpAgentsSheet(tester);
      for (var i = 0; i < 12; i++) {
        if (_focusStop(tester) == 'agents-sheet-footer-close') break;
        await _press(tester, LogicalKeyboardKey.tab);
      }
      expect(_focusStop(tester), 'agents-sheet-footer-close');
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_activeTab(), 'agents-tab-connect');
      expect(agentsSheetFinder, findsOneWidget);
    });

    testWidgets('after Esc focus is back on the previously focused field', (
      tester,
    ) async {
      final s = await pumpAgentsSheet(tester);
      expect(agentsSheetFinder, findsOneWidget);
      expect(s.originFocus.hasFocus, isFalse);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(agentsSheetFinder, findsNothing);
      expect(s.originFocus.hasPrimaryFocus, isTrue);
    });

    testWidgets(
      'after the footer Close focus is back on the previously focused field',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        await _tapKey(tester, 'agents-sheet-footer-close');
        expect(agentsSheetFinder, findsNothing);
        expect(s.originFocus.hasPrimaryFocus, isTrue);
      },
    );

    testWidgets(
      'Shift Cmd A with focus on a tab chip is left unhandled and opens nothing more',
      (tester) async {
        final s = await pumpAgentsSheet(tester);
        expect(_focusStop(tester), 'agents-tab-connect');

        expect(await _pressShiftCmdA(tester), isFalse);
        await s.settle();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));
        expect(_activeTab(), 'agents-tab-connect');
      },
    );
  });

  // ================================================================ AC 9
  group('AgentsTabLoading (AC9)', () {
    testWidgets(
      'AgentsTabLoading shows nothing before 400 ms and loading in fg2 from 400 ms',
      (tester) async {
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          host: const Align(
            alignment: Alignment.topLeft,
            child: AgentsTabLoading(),
          ),
        );
        Finder text() => find.descendant(
          of: find.byType(AgentsTabLoading),
          matching: find.byType(RichText),
        );
        expect(text(), findsNothing, reason: 'empty at 0 ms');

        // Frames alone move nothing: only the injected clock does.
        await tester.pump(const Duration(seconds: 1));
        expect(text(), findsNothing);

        s.clock.advance(const Duration(milliseconds: 399));
        await tester.pump();
        expect(text(), findsNothing, reason: 'empty at 399 ms');

        s.clock.advance(const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.text('loading…'), findsOneWidget, reason: 'at 400 ms');
        final style = tester.widget<RichText>(text()).text.style;
        expect(style?.color?.toARGB32(), OmColors.fg2.toARGB32());
      },
    );

    testWidgets(
      'AgentsTabLoading removed before 400 ms leaves no timer behind',
      (tester) async {
        final show = ValueNotifier(true);
        addTearDown(show.dispose);
        final s = await pumpAgentsSheet(
          tester,
          open: false,
          host: ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (_, on, _) =>
                on ? const AgentsTabLoading() : const SizedBox.shrink(),
          ),
        );
        final before = s.clock.pendingTimers;
        show.value = false;
        await tester.pump();
        if (before > 0) expect(s.clock.pendingTimers, lessThan(before));
        s.clock.advance(const Duration(seconds: 1));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  });

  // ================================================================ AC 10
  group('re-entry (AC10)', () {
    testWidgets(
      'openAgentsSheet while the sheet is open opens nothing new, twice in one frame included',
      (tester) async {
        final s = await pumpAgentsSheet(tester, open: false);
        // Two calls in one frame.
        unawaited(openAgentsSheet(s.hostContext));
        unawaited(openAgentsSheet(s.hostContext));
        await s.settle();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));

        // Another call while it is open.
        unawaited(openAgentsSheet(s.hostContext));
        await s.settle();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));

        // Closed, it opens again.
        await _press(tester, LogicalKeyboardKey.escape);
        expect(agentsSheetFinder, findsNothing);
        await s.launch();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(2));
      },
    );

    testWidgets(
      'openAgents from the WindowMenuHost opens the sheet once and nothing while another dialog is open',
      (tester) async {
        final menu = FakeWindowMenuHost();
        final app = await pumpWorkspace(
          tester,
          overrides: [windowMenuHostProvider.overrideWithValue(menu)],
        );
        expect(menu.isAttached, isTrue, reason: 'the workspace attaches');
        expect(menu.attachCount, 1);

        // Another dialog is open: openAgents does nothing.
        final ctx = tester.element(find.byType(Workspace));
        unawaited(
          showDialog<void>(
            context: ctx,
            builder: (_) => const Center(
              child: SizedBox(key: Key('other-dialog'), width: 40, height: 40),
            ),
          ),
        );
        await pumpFrames(tester);
        expect(find.byKey(const Key('other-dialog')), findsOneWidget);
        menu.simulateOpenAgents();
        await pumpFrames(tester);
        app.clock.advance(const Duration(milliseconds: 300));
        await pumpFrames(tester);
        expect(agentsSheetFinder, findsNothing);
        expect(find.byKey(const Key('other-dialog')), findsOneWidget);

        // Once it closes, openAgents opens the sheet; again while open adds
        // nothing.
        Navigator.of(
          tester.element(find.byKey(const Key('other-dialog'))),
        ).pop();
        await pumpFrames(tester);
        menu.simulateOpenAgents();
        await pumpFrames(tester);
        app.clock.advance(const Duration(milliseconds: 300));
        await pumpFrames(tester);
        expect(agentsSheetFinder, findsOneWidget);
        menu.simulateOpenAgents();
        menu.simulateOpenAgents();
        await pumpFrames(tester);
        expect(agentsSheetFinder, findsOneWidget);
      },
    );
  });

  // ================================================================ AC 15
  group('large text and narrow windows (AC15)', () {
    testWidgets(
      'at 1.5x text nothing in the header tabs or footer overflows at 720 px and at a 672 px window',
      (tester) async {
        for (final window in [1000.0, 672.0]) {
          await pumpAgentsSheet(
            tester,
            size: Size(window, 800),
            textScale: 1.5,
            overrides: _allBadges,
          );
          expect(agentsSheetFinder, findsOneWidget);
          _expectChromeNotClipped(
            tester,
            '$window px at 1.5x',
            exempt: {'Studio · local vault'},
          );
          expect(_chipText(tester, 'agents-tab-live'), 'Live 2 connected');
          expect(_chipText(tester, 'agents-tab-tools'), 'Tools 37 tools');
          await tester.pumpWidget(const SizedBox());
        }
      },
    );

    testWidgets('at a 480 px window nothing overflows at 1x and 1.5x text', (
      tester,
    ) async {
      for (final scale in [1.0, 1.5]) {
        for (final vault in <VaultRef>[
          agentsSheetLocalVault,
          agentsSheetHostedVault,
        ]) {
          await pumpAgentsSheet(
            tester,
            vault: vault,
            size: const Size(480, 800),
            textScale: scale,
            overrides: _allBadges,
          );
          expect(agentsSheetFinder, findsOneWidget);
          expect(tester.getSize(agentsSheetFinder).width, 448);
          _expectChromeNotClipped(
            tester,
            '480 px at ${scale}x $vault',
            exempt: {'Studio · local vault', 'studio · nas · hosted'},
          );
          await tester.pumpWidget(const SizedBox());
        }
      }
    });

    testWidgets(
      'a long vault name ellipsizes the chip and keeps the close x in the sheet at 480 px',
      (tester) async {
        const vault = LocalVaultRef(
          '/Users/tester/vaults/a-vault-with-a-rather-long-folder-name-for-the-chip',
        );
        await pumpAgentsSheet(
          tester,
          vault: vault,
          size: const Size(480, 800),
          textScale: 1.5,
        );
        expect(tester.takeException(), isNull);
        final chip = tester.getRect(_key('agents-sheet-vault-chip'));
        final close = tester.getRect(_key('agents-sheet-close'));
        expect(chip.right, lessThanOrEqualTo(close.left + 0.5));
        expect(
          close.right,
          lessThanOrEqualTo(tester.getRect(agentsSheetFinder).right),
        );
        final p = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: _key('agents-sheet-vault-chip'),
            matching: find.byType(RichText),
          ),
        );
        expect(p.text.toPlainText(), startsWith('a-vault-with'));
        expect(p.overflow, TextOverflow.ellipsis);
      },
    );
  });

  // ================================================================ AC 16
  group('tab row scrolls (AC16)', () {
    bool inView(WidgetTester tester, String key) {
      final viewport = tester.getRect(_tabRowScrollable());
      final chip = tester.getRect(_key(key));
      return chip.left >= viewport.left - 0.5 &&
          chip.right <= viewport.right + 0.5;
    }

    testWidgets(
      'when the tabs do not fit the tab row scrolls sideways and the arrow keys scroll the active tab fully into view',
      (tester) async {
        await pumpAgentsSheet(
          tester,
          size: const Size(480, 800),
          textScale: 1.5,
          overrides: _allBadges,
        );
        expect(tester.takeException(), isNull);
        expect(_tabRowScrollable(), findsOneWidget);
        expect(inView(tester, 'agents-tab-connect'), isTrue);
        expect(
          inView(tester, 'agents-tab-recall'),
          isFalse,
          reason: 'precondition: Semantic recall starts out of view',
        );

        await _press(tester, LogicalKeyboardKey.arrowRight);
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_activeTab(), 'agents-tab-recall');
        expect(inView(tester, 'agents-tab-recall'), isTrue);
        expect(_chipText(tester, 'agents-tab-recall'), 'Semantic recall');

        for (var i = 0; i < 3; i++) {
          await _press(tester, LogicalKeyboardKey.arrowLeft);
        }
        expect(_activeTab(), 'agents-tab-live');
        expect(inView(tester, 'agents-tab-live'), isTrue);
        expect(_chipText(tester, 'agents-tab-live'), 'Live 2 connected');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'selecting a partly hidden tab by tap or by select scrolls it fully into view',
      (tester) async {
        final s = await pumpAgentsSheet(
          tester,
          size: const Size(480, 800),
          textScale: 1.5,
          overrides: _allBadges,
        );
        expect(inView(tester, 'agents-tab-recall'), isFalse);
        // Drag the row sideways until Semantic recall is partly shown.
        bool partlyShown() {
          final viewport = tester.getRect(_tabRowScrollable());
          final r = tester.getRect(_key('agents-tab-recall'));
          return r.left < viewport.right - 10 && r.right > viewport.right + 1;
        }

        for (var i = 0; i < 40 && !partlyShown(); i++) {
          await tester.drag(_tabRowScrollable(), const Offset(-12, 0));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(partlyShown(), isTrue, reason: 'the row drags sideways');
        final chip = tester.getRect(_key('agents-tab-recall'));
        await tester.tapAt(Offset(chip.left + 5, chip.center.dy));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(_activeTab(), 'agents-tab-recall');
        expect(inView(tester, 'agents-tab-recall'), isTrue);

        s.read(agentsSheetTabProvider.notifier).select(AgentsTab.live);
        await s.settle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_activeTab(), 'agents-tab-live');
        expect(inView(tester, 'agents-tab-live'), isTrue);
      },
    );
  });
}
