// WI #408 (EP; Spec #394 req 2, 6; D13; design pack
// design/394-agents-sheet/packs/408.md): the agents footer's `OPEN ↗` link.
// Only the `agent-footer-open` element of #390's AgentFooter changes: the
// label reads `OPEN ↗` (U+2197 in the string) in mono 10.5 fg2, letter
// spacing 0.8; the pointer turns it fg0 with an underline and leaving
// reverts it; the cursor is the click cursor; its tooltip is
// `Agents ⇧⌘A`; a tap calls `openAgentsSheet`. The Key stays on the label's
// text box ("Keys name their box").
//
// The footer is pumped as the page of the Agents sheet harness (closed), so
// a tap opens the real sheet over FakeAgentsAccess and a FakeClock.
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents/agent_footer.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/font_fetch_hold.dart';

const _wi408Label = 'OPEN ↗';
const _wi408Tooltip = 'Agents ⇧⌘A';
const _wi408OpenKey = Key('agent-footer-open');

final _open = find.byKey(_wi408OpenKey);
final _footer = find.byKey(const Key('agent-footer'));

/// The label's Text under (or at) the keyed box.
Finder get _labelText => find.descendant(
  of: _open,
  matching: find.text(_wi408Label),
  matchRoot: true,
);

/// Pumps AgentFooter as the harness page, 450 px wide (the test font draws
/// every glyph 1em wide, so the header needs more than the real 268 px),
/// pinned to the bottom left as in the sidebar. The sheet is closed.
Future<AgentsSheetHarness> _wi408PumpFooter(
  WidgetTester tester, {
  FakeAgentsAccess? agents,
  double textScale = 1.0,
}) async {
  final s = await pumpAgentsSheet(
    tester,
    open: false,
    agents: agents,
    textScale: textScale,
    size: const Size(1000, 800),
    host: const Align(
      alignment: Alignment.bottomLeft,
      child: SizedBox(width: 450, child: AgentFooter()),
    ),
  );
  await s.settle();
  return s;
}

/// The label's effective style: the Text's own style merged over the
/// paragraph's (so a style set by a DefaultTextStyle or a span also counts).
TextStyle _wi408LabelStyle(WidgetTester tester) {
  expect(_labelText, findsOneWidget, reason: 'the label reads $_wi408Label');
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: _labelText,
      matching: find.byType(RichText),
      matchRoot: true,
    ),
  );
  final span = paragraph.text;
  var style = span.style ?? const TextStyle();
  if (span is TextSpan && span.children != null && span.children!.isNotEmpty) {
    final child = span.children!.first.style;
    if (child != null) style = style.merge(child);
  }
  return style;
}

bool _wi408Underlined(TextStyle style) =>
    style.decoration != null &&
    style.decoration!.contains(TextDecoration.underline);

/// A mouse resting at the top left of the window, away from the footer.
Future<TestGesture> _wi408Mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    pointer: 1,
  );
  await mouse.addPointer(location: const Offset(900, 20));
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

void _wi408ExpectRest(WidgetTester tester, {required String when}) {
  final style = _wi408LabelStyle(tester);
  expect(style.color, OmColors.fg2, reason: 'fg2 $when');
  expect(_wi408Underlined(style), isFalse, reason: 'no underline $when');
}

void _wi408ExpectHover(WidgetTester tester, {required String when}) {
  final style = _wi408LabelStyle(tester);
  expect(style.color, OmColors.fg0, reason: 'fg0 $when');
  expect(_wi408Underlined(style), isTrue, reason: 'underline $when');
  expect(style.decorationColor, OmColors.fg0, reason: 'underline fg0 $when');
}

void main() {
  holdFontFetches();

  // ================================================================ AC 1
  group('label and hover (AC1)', () {
    testWidgets(
      'agent-footer-open reads OPEN ↗ in mono 10.5 fg2 with no underline on the first frame and the old label is gone',
      (tester) async {
        await _wi408PumpFooter(tester);

        expect(_open, findsOneWidget);
        expect(find.text('OPEN API ↗'), findsNothing);
        expect(find.textContaining('API'), findsNothing);
        expect(_labelText, findsOneWidget);
        expect(_wi408Label.runes.last, 0x2197, reason: 'U+2197 in the string');

        // The Key names the label's own text box.
        expect(tester.getRect(_open), tester.getRect(_labelText));

        final style = _wi408LabelStyle(tester);
        expect(style.fontSize, 10.5);
        expect(style.letterSpacing, 0.8);
        expect(style.color, OmColors.fg2);
        expect(_wi408Underlined(style), isFalse);
      },
    );

    testWidgets(
      'hovering agent-footer-open turns it fg0 with an underline and leaving reverts it to fg2 with no underline',
      (tester) async {
        await _wi408PumpFooter(tester);
        final mouse = await _wi408Mouse(tester);
        _wi408ExpectRest(tester, when: 'before the pointer arrives');

        await mouse.moveTo(tester.getCenter(_open));
        await tester.pump();
        _wi408ExpectHover(tester, when: 'while hovered');

        await mouse.moveTo(const Offset(900, 20));
        await tester.pump();
        _wi408ExpectRest(tester, when: 'after the pointer leaves');

        // A second visit hovers again.
        await mouse.moveTo(tester.getCenter(_open));
        await tester.pump();
        _wi408ExpectHover(tester, when: 'hovered a second time');

        await mouse.moveTo(const Offset(900, 20));
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets(
      'hovering inside the footer but off agent-footer-open leaves the label at rest',
      (tester) async {
        await _wi408PumpFooter(tester);
        final mouse = await _wi408Mouse(tester);

        // The eyebrow, on the same row.
        await mouse.moveTo(tester.getCenter(find.text('AGENTS · LIVE')));
        await tester.pump();
        _wi408ExpectRest(tester, when: 'with the pointer on the eyebrow');
      },
    );

    testWidgets('the pointer over agent-footer-open shows the click cursor', (
      tester,
    ) async {
      await _wi408PumpFooter(tester);
      final mouse = await _wi408Mouse(tester);
      final tracker = RendererBinding.instance.mouseTracker;
      expect(
        tracker.debugDeviceActiveCursor(1),
        isNot(SystemMouseCursors.click),
      );

      await mouse.moveTo(tester.getCenter(_open));
      await tester.pump();
      expect(tracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);

      await mouse.moveTo(const Offset(900, 20));
      await tester.pump(const Duration(seconds: 2));
      expect(
        tracker.debugDeviceActiveCursor(1),
        isNot(SystemMouseCursors.click),
      );
    });
  });

  // ================================================================ AC 2
  group('tooltip and tap (AC2)', () {
    testWidgets(
      'agent-footer-open carries the tooltip Agents ⇧⌘A and hovering shows it',
      (tester) async {
        await _wi408PumpFooter(tester);

        final tooltips = tester.widgetList<Tooltip>(
          find.ancestor(of: _open, matching: find.byType(Tooltip)),
        );
        expect(tooltips, hasLength(1), reason: 'one tooltip on the link');
        expect(tooltips.single.message, _wi408Tooltip);
        expect(find.text(_wi408Tooltip), findsNothing);

        final mouse = await _wi408Mouse(tester);
        await mouse.moveTo(tester.getCenter(_open));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(_wi408Tooltip), findsOneWidget);

        // Leave and let the tooltip's hide timers run out.
        await mouse.moveTo(const Offset(900, 20));
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets('a tap on agent-footer-open opens agents-sheet once', (
      tester,
    ) async {
      final s = await _wi408PumpFooter(tester);
      expect(agentsSheetFinder, findsNothing);

      await tester.tap(_open);
      await tester.pump();
      await s.decide();

      expect(agentsSheetFinder, findsOneWidget);
      expect(s.routes.dialogs, hasLength(1));
    });

    testWidgets(
      'a second tap on agent-footer-open while the sheet is open opens nothing new and after a close a tap opens it again',
      (tester) async {
        final s = await _wi408PumpFooter(tester);

        // Two taps before a frame: the second lands on the link while the
        // first sheet is already pushed.
        await tester.tap(_open);
        await tester.tap(_open);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await s.settle();
        await s.settle();
        expect(agentsSheetFinder, findsNothing);

        await tester.tap(_open);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(2));
      },
    );

    testWidgets(
      'only agent-footer-open is the link: a tap hover or tooltip on the eyebrow the dot and an agent row opens nothing and shows no click cursor or tooltip',
      (tester) async {
        final agents = FakeAgentsAccess(
          script: [
            AgentActivity(
              agents: [
                agentPresence(
                  clientName: 'claude-code',
                  expiresAt: agentsT0 + 3600000,
                ),
              ],
              recent: [agentEntry(summary: 'filed 2 blocks → Studio')],
              available: true,
            ),
          ],
        );
        final s = await _wi408PumpFooter(tester, agents: agents);
        final others = [
          find.text('AGENTS · LIVE'),
          find.byKey(const Key('agent-footer-dot')),
          find.byKey(const Key('agent-footer-agent-0')),
          find.byKey(const Key('agent-footer-activity-0')),
        ];
        for (final f in others) {
          expect(f, findsOneWidget);
        }

        // The Tooltip around the link is exactly the label's box: it cannot
        // have grown to the header row or the whole footer. (D52 widens the
        // hit box by hit testing only, so this still holds.)
        final tooltip = find
            .ancestor(of: _open, matching: find.byType(Tooltip))
            .first;
        expect(tester.getRect(tooltip), tester.getRect(_open));

        final mouse = await _wi408Mouse(tester);
        final tracker = RendererBinding.instance.mouseTracker;
        for (final f in others) {
          await mouse.moveTo(tester.getCenter(f));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            tracker.debugDeviceActiveCursor(1),
            isNot(SystemMouseCursors.click),
            reason: 'no click cursor over $f',
          );
          expect(find.text(_wi408Tooltip), findsNothing, reason: 'over $f');
          _wi408ExpectRest(tester, when: 'with the pointer over $f');
        }
        await mouse.moveTo(const Offset(900, 20));
        await tester.pump(const Duration(seconds: 2));

        for (final f in others) {
          await tester.tap(f, warnIfMissed: false);
          await tester.pump();
          await s.decide();
          expect(agentsSheetFinder, findsNothing, reason: 'a tap on $f');
          expect(s.routes.dialogs, isEmpty, reason: 'a tap on $f');
        }

        // The link itself still opens it.
        await tester.tap(_open);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
      },
    );
  });

  // ================================================================ AC 3
  group('the rest of the footer (AC3)', () {
    testWidgets(
      'the rest of the footer renders as 390 left it with OPEN ↗ at the right end of the header row',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final agents = FakeAgentsAccess(
          script: [
            AgentActivity(
              agents: [
                agentPresence(
                  clientName: 'claude-code',
                  expiresAt: agentsT0 + 3600000,
                ),
              ],
              recent: [agentEntry(summary: 'filed 2 blocks → Studio')],
              available: true,
            ),
          ],
        );
        await _wi408PumpFooter(tester, agents: agents);

        // #390's header pieces and rows are all still there.
        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(find.byKey(const Key('agent-footer-dot')), findsOneWidget);
        expect(find.byKey(const Key('agent-footer-agent-0')), findsOneWidget);
        expect(
          find.byKey(const Key('agent-footer-activity-0')),
          findsOneWidget,
        );

        // The link sits at the right end of the header row (padding R12),
        // vertically centred with the eyebrow, and its box is the label's.
        expect(_labelText, findsOneWidget);
        final footer = tester.getRect(_footer);
        final open = tester.getRect(_open);
        final eyebrow = tester.getRect(find.text('AGENTS · LIVE'));
        expect(open, tester.getRect(_labelText));
        expect(open.right, moreOrLessEquals(footer.right - 12, epsilon: 0.01));
        expect(open.left, greaterThan(eyebrow.right));
        expect((open.center.dy - eyebrow.center.dy).abs(), lessThan(4));

        // The footer is still one semantics leaf with #390's sentence: the
        // link adds no node of its own (it is a mouse affordance; ⇧⌘A is
        // the keyboard path).
        final node = tester.getSemantics(_footer);
        expect(node.childrenCount, 0);
        expect(node.getSemanticsData().label, startsWith('1 agent connected.'));
        semantics.dispose();
      },
    );
  });

  // ======================================================= D52 follow-up
  // The footer's one VoiceOver stop (#390: excludeSemantics kept, the rows
  // and the link add no nodes) gains a tap action that opens the sheet and
  // the hint `Opens Agents`; it is not a button. The link's hit box grows to
  // at least 24 px tall without moving any footer element, the Key stays on
  // the label's text box, and the click cursor, the tooltip and the hover
  // colour follow the hit box.
  group('D52 VoiceOver tap and 24 px hit box', () {
    // ------------------------------------------------------------ D52 AC1
    for (final c in [
      (
        'connected',
        _d52Connected,
        '1 agent connected. claude-code idle, just now. '
            'Latest: filed 2 blocks to Studio, just now',
      ),
      ('disconnected', null, 'No agents connected.'),
      (
        'unavailable',
        _d52Unavailable,
        'Agent activity unavailable on this vault server.',
      ),
    ]) {
      testWidgets(
        'D52 the footer semantics node has a tap action and the hint Opens Agents and keeps its label and no child nodes when ${c.$1}',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _wi408PumpFooter(tester, agents: c.$2?.call());

          final node = tester.getSemantics(_footer);
          final data = node.getSemanticsData();
          expect(data.label, c.$3, reason: 'the label is unchanged');
          expect(node.childrenCount, 0, reason: 'still one leaf');
          expect(data.hasAction(SemanticsAction.tap), isTrue);
          expect(data.hint, _d52Hint);
          // Not a button: the node carries the status sentence.
          expect(data.flagsCollection.isButton, isFalse);
          expect(_d52AllHints(tester), [_d52Hint], reason: 'one node only');
          semantics.dispose();
        },
      );
    }

    testWidgets(
      'D52 a semantics tap on the footer opens agents-sheet once and a second one while it is open opens nothing new',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final s = await _wi408PumpFooter(tester, agents: _d52Connected());
        expect(agentsSheetFinder, findsNothing);

        // Two taps before a frame: the second reaches the footer while the
        // first sheet is already pushed.
        final id = tester.getSemantics(_footer).id;
        _d52SemanticsTap(tester, id);
        _d52SemanticsTap(tester, id);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await s.settle();
        await s.settle();
        expect(agentsSheetFinder, findsNothing);

        // The footer still answers after a close.
        _d52SemanticsTap(tester, tester.getSemantics(_footer).id);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(2));
        semantics.dispose();
      },
    );

    // ------------------------------------------------------------ D52 AC2
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'D52 the OPEN ↗ hit box is at least 24 px tall and spans the label width at text scale $scale',
        (tester) async {
          await _wi408PumpFooter(
            tester,
            agents: _d52Connected(),
            textScale: scale,
          );
          final label = tester.getRect(_open);
          expect(label.height, lessThan(24), reason: 'the label is shorter');
          final mouse = await _wi408Mouse(tester);

          final band = await _d52ClickBand(tester, mouse);
          expect(
            band.height,
            greaterThanOrEqualTo(24 - _d52Step - 1e-9),
            reason: 'click cursor band ${band.top}..${band.bottom}',
          );
          expect(band.top, lessThan(label.top));
          expect(band.bottom, greaterThan(label.bottom));
          _d52ExpectBandEdges(label, band);

          // The width: both ends of the label, above and below its box.
          final tracker = RendererBinding.instance.mouseTracker;
          for (final dy in [band.top + _d52Step, band.bottom - _d52Step]) {
            for (final dx in [label.left + 0.25, label.right - 0.25]) {
              await mouse.moveTo(Offset(dx, dy));
              expect(
                tracker.debugDeviceActiveCursor(1),
                SystemMouseCursors.click,
                reason: 'the hit box covers ($dx, $dy)',
              );
            }
          }
          await _d52Leave(tester, mouse);
        },
      );
    }

    testWidgets(
      'D52 a tap 10 px above and 10 px below the OPEN ↗ label centre opens agents-sheet once each',
      (tester) async {
        final s = await _wi408PumpFooter(tester, agents: _d52Connected());
        final label = tester.getRect(_open);
        final above = label.center.translate(0, -10);
        final below = label.center.translate(0, 10);
        expect(label.contains(above), isFalse, reason: 'outside the label');
        expect(label.contains(below), isFalse, reason: 'outside the label');

        await tester.tapAt(above);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await s.settle();
        await s.settle();
        expect(agentsSheetFinder, findsNothing);

        await tester.tapAt(below);
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(2));
      },
    );

    testWidgets(
      'D52 hovering the OPEN ↗ hit box off the label turns it fg0 with an underline and leaving the hit box reverts it',
      (tester) async {
        await _wi408PumpFooter(tester, agents: _d52Connected());
        final label = tester.getRect(_open);
        final mouse = await _wi408Mouse(tester);
        final band = await _d52ClickBand(tester, mouse);
        _d52ExpectBandEdges(label, band);
        await _d52Leave(tester, mouse);
        _wi408ExpectRest(tester, when: 'before the pointer arrives');

        await mouse.moveTo(label.center.translate(0, -10));
        await tester.pump();
        _wi408ExpectHover(tester, when: '10 px above the label centre');

        await mouse.moveTo(label.center.translate(0, 10));
        await tester.pump();
        _wi408ExpectHover(tester, when: '10 px below the label centre');

        await mouse.moveTo(Offset(label.center.dx, band.bottom + 1));
        await tester.pump();
        _wi408ExpectRest(tester, when: 'just below the hit box');

        await mouse.moveTo(label.center.translate(0, -10));
        await tester.pump();
        _wi408ExpectHover(tester, when: 'back in the hit box');

        await mouse.moveTo(Offset(label.center.dx, band.top - 1));
        await tester.pump();
        _wi408ExpectRest(tester, when: 'just above the hit box');
        await _d52Leave(tester, mouse);
      },
    );

    // ------------------------------------------------------------ D52 AC3
    testWidgets(
      'D52 taps on the eyebrow the dot the agent rows and just outside the hit box open nothing while a tap in the hit box above the label opens agents-sheet',
      (tester) async {
        final s = await _wi408PumpFooter(tester, agents: _d52Connected());
        final label = tester.getRect(_open);
        final mouse = await _wi408Mouse(tester);
        final band = await _d52ClickBand(tester, mouse);
        _d52ExpectBandEdges(label, band);
        await _d52Leave(tester, mouse);

        final misses = <String, Offset>{
          'the eyebrow': tester.getCenter(find.text('AGENTS · LIVE')),
          'the dot': tester.getCenter(
            find.byKey(const Key('agent-footer-dot')),
          ),
          'agent row 0': tester.getCenter(
            find.byKey(const Key('agent-footer-agent-0')),
          ),
          'activity row 0': tester.getCenter(
            find.byKey(const Key('agent-footer-activity-0')),
          ),
          // Inside the link's column, just under the hit box: an oversized
          // band would take this tap from the row.
          'agent row 0 under the link': Offset(
            label.center.dx,
            tester.getRect(find.byKey(const Key('agent-footer-agent-0'))).top +
                1,
          ),
          'just above the hit box': Offset(label.center.dx, band.top - 1),
          'just below the hit box': Offset(label.center.dx, band.bottom + 1),
        };
        for (final m in misses.entries) {
          await tester.tapAt(m.value);
          await tester.pump();
          await s.decide();
          expect(agentsSheetFinder, findsNothing, reason: 'a tap on ${m.key}');
          expect(s.routes.dialogs, isEmpty, reason: 'a tap on ${m.key}');
        }

        await tester.tapAt(label.center.translate(0, -10));
        await tester.pump();
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);
        expect(s.routes.dialogs, hasLength(1));
      },
    );

    testWidgets(
      'D52 the click cursor and the Agents ⇧⌘A tooltip stay on the OPEN ↗ hit box',
      (tester) async {
        await _wi408PumpFooter(tester, agents: _d52Connected());
        final label = tester.getRect(_open);
        final tracker = RendererBinding.instance.mouseTracker;
        final mouse = await _wi408Mouse(tester);
        final band = await _d52ClickBand(tester, mouse);
        expect(band.height, greaterThanOrEqualTo(24 - _d52Step - 1e-9));
        _d52ExpectBandEdges(label, band);
        await _d52Leave(tester, mouse);

        // Inside the hit box but off the label: the cursor and the tooltip.
        for (final y in [band.top + _d52Step, band.bottom - _d52Step]) {
          await mouse.moveTo(Offset(label.center.dx, y));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(tracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
          expect(find.text(_wi408Tooltip), findsOneWidget, reason: 'at $y');
          await _d52Leave(tester, mouse);
        }

        // Outside it: neither, on the footer around the link or the rows.
        final outside = <String, Offset>{
          'just above the hit box': Offset(label.center.dx, band.top - 1),
          'just below the hit box': Offset(label.center.dx, band.bottom + 1),
          'the eyebrow': tester.getCenter(find.text('AGENTS · LIVE')),
          'the dot': tester.getCenter(
            find.byKey(const Key('agent-footer-dot')),
          ),
          'agent row 0': tester.getCenter(
            find.byKey(const Key('agent-footer-agent-0')),
          ),
          'agent row 0 under the link': Offset(
            label.center.dx,
            tester.getRect(find.byKey(const Key('agent-footer-agent-0'))).top +
                1,
          ),
        };
        for (final o in outside.entries) {
          await mouse.moveTo(o.value);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            tracker.debugDeviceActiveCursor(1),
            isNot(SystemMouseCursors.click),
            reason: 'no click cursor on ${o.key}',
          );
          expect(find.text(_wi408Tooltip), findsNothing, reason: o.key);
        }
        await _d52Leave(tester, mouse);
      },
    );

    // ------------------------------------------------------------ D52 AC4
    // Rects measured on main @ 38450843 (#506) in this harness (450 px wide,
    // pinned bottom left of 1000x800, the flutter_test font).
    for (final c in [
      (
        'connected at text scale 1.0',
        1.0,
        true,
        <String, Rect>{
          'footer': const Rect.fromLTRB(0, 715, 450, 800),
          'eyebrow': const Rect.fromLTRB(12, 725, 168, 742),
          'dot': const Rect.fromLTRB(176, 731, 181, 736),
          'open': const Rect.fromLTRB(370.2, 725.5, 438, 741.5),
          'agent0': const Rect.fromLTRB(12, 750, 438, 766),
          'activity0': const Rect.fromLTRB(12, 772, 438, 788),
        },
      ),
      (
        'disconnected at text scale 1.0',
        1.0,
        false,
        <String, Rect>{
          'footer': const Rect.fromLTRB(0, 700, 450, 800),
          'eyebrow': const Rect.fromLTRB(12, 710, 168, 727),
          'dot': const Rect.fromLTRB(176, 716, 181, 721),
          'open': const Rect.fromLTRB(370.2, 710.5, 438, 726.5),
          'empty': const Rect.fromLTRB(12, 735, 438, 752),
        },
      ),
      (
        'connected at text scale 1.3',
        1.3,
        true,
        <String, Rect>{
          'footer': const Rect.fromLTRB(0, 703, 450, 800),
          'eyebrow': const Rect.fromLTRB(12, 713, 210.9, 734),
          'dot': const Rect.fromLTRB(218.9, 721, 223.9, 726),
          'open': const Rect.fromLTRB(351.3, 713.5, 438, 733.5),
          'agent0': const Rect.fromLTRB(12, 742, 438, 762),
          'activity0': const Rect.fromLTRB(12, 768, 438, 788),
        },
      ),
      (
        'disconnected at text scale 1.3',
        1.3,
        false,
        <String, Rect>{
          'footer': const Rect.fromLTRB(0, 659, 450, 800),
          'eyebrow': const Rect.fromLTRB(12, 669, 210.9, 690),
          'dot': const Rect.fromLTRB(218.9, 677, 223.9, 682),
          'open': const Rect.fromLTRB(351.3, 669.5, 438, 689.5),
          'empty': const Rect.fromLTRB(12, 698, 438, 720),
        },
      ),
    ]) {
      testWidgets(
        'D52 no footer element moves and agent-footer-open stays on the label box with the 24 px hit box when ${c.$1}',
        (tester) async {
          final s = await _wi408PumpFooter(
            tester,
            agents: c.$3 ? _d52Connected() : null,
            textScale: c.$2,
          );
          final finders = <String, Finder>{
            'footer': _footer,
            'eyebrow': find.text('AGENTS · LIVE'),
            'dot': find.byKey(const Key('agent-footer-dot')),
            'open': _open,
            'agent0': find.byKey(const Key('agent-footer-agent-0')),
            'activity0': find.byKey(const Key('agent-footer-activity-0')),
            'empty': find.byKey(const Key('agent-footer-empty')),
          };
          for (final e in c.$4.entries) {
            expect(
              tester.getRect(finders[e.key]!),
              rectMoreOrLessEquals(e.value, epsilon: 0.05),
              reason: '${e.key} has not moved',
            );
          }
          // The Key names the label's own text box: the keyed widget is the
          // Text and its box is exactly the paragraph it draws.
          expect(tester.widget(_open), isA<Text>());
          expect(
            tester.getRect(_open),
            tester.getRect(
              find.descendant(of: _open, matching: find.byType(RichText)),
            ),
          );

          final mouse = await _wi408Mouse(tester);
          final band = await _d52ClickBand(tester, mouse);
          expect(band.height, greaterThanOrEqualTo(24 - _d52Step - 1e-9));
          final label = tester.getRect(_open);
          _d52ExpectBandEdges(label, band);

          // Just under the hit box, in the link's column, sits the first row
          // (the agent row, or the empty hint): it keeps its taps and cursor.
          final row = tester.getRect(
            find.byKey(
              Key(c.$3 ? 'agent-footer-agent-0' : 'agent-footer-empty'),
            ),
          );
          final probe = Offset(label.center.dx, row.top + 1);
          expect(probe.dy, greaterThan(band.bottom), reason: 'below the band');
          await mouse.moveTo(probe);
          expect(
            RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
            isNot(SystemMouseCursors.click),
            reason: 'no click cursor on the first row under the link',
          );
          await _d52Leave(tester, mouse);
          await tester.tapAt(probe);
          await tester.pump();
          await s.decide();
          expect(agentsSheetFinder, findsNothing, reason: 'a tap on the row');
          expect(s.routes.dialogs, isEmpty);
          // Hovering and its tooltip moved nothing either.
          for (final e in c.$4.entries) {
            expect(
              tester.getRect(finders[e.key]!),
              rectMoreOrLessEquals(e.value, epsilon: 0.05),
              reason: '${e.key} has not moved after a hover',
            );
          }
        },
      );
    }
  });
}

// ------------------------------------------------------------- D52 helpers

const _d52Hint = 'Opens Agents';

/// The scan step for the click cursor band, in logical px.
const _d52Step = 0.125;

/// One connected agent and one activity row (the AC3 fixture).
FakeAgentsAccess _d52Connected() => FakeAgentsAccess(
  script: [
    AgentActivity(
      agents: [
        agentPresence(clientName: 'claude-code', expiresAt: agentsT0 + 3600000),
      ],
      recent: [agentEntry(summary: 'filed 2 blocks → Studio')],
      available: true,
    ),
  ],
);

FakeAgentsAccess _d52Unavailable() => FakeAgentsAccess(
  script: [const AgentActivity(agents: [], recent: [], available: false)],
);

/// Every non-empty semantics hint in the tree.
List<String> _d52AllHints(WidgetTester tester) {
  final hints = <String>[];
  void visit(SemanticsNode n) {
    final h = n.getSemanticsData().hint;
    if (h.isNotEmpty) hints.add(h);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return hints;
}

/// Performs VoiceOver's activate (a semantics tap) on node [id].
void _d52SemanticsTap(WidgetTester tester, int id) {
  tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
    id,
    SemanticsAction.tap,
  );
}

/// The vertical band, on the label's centre line, where the mouse shows the
/// click cursor: scanned every [_d52Step] px from 24 px above to 24 px below
/// the label centre. The band must be one run (no gaps); its height is the
/// number of click points times the step.
Future<({double top, double bottom, double height})> _d52ClickBand(
  WidgetTester tester,
  TestGesture mouse,
) async {
  final tracker = RendererBinding.instance.mouseTracker;
  final c = tester.getRect(_open).center;
  final ys = <double>[];
  for (var i = 0; i <= 48 ~/ _d52Step; i++) {
    final y = c.dy - 24 + i * _d52Step;
    await mouse.moveTo(Offset(c.dx, y));
    if (tracker.debugDeviceActiveCursor(1) == SystemMouseCursors.click) {
      ys.add(y);
    }
  }
  expect(ys, isNotEmpty, reason: 'the label shows the click cursor');
  for (var i = 1; i < ys.length; i++) {
    expect(
      ys[i] - ys[i - 1],
      moreOrLessEquals(_d52Step, epsilon: 1e-9),
      reason: 'the click cursor band has no gap at ${ys[i - 1]}',
    );
  }
  return (top: ys.first, bottom: ys.last, height: ys.length * _d52Step);
}

/// The hit box is exactly `max(label height, 24)` tall, centred on the label
/// (the labels here are all shorter than 24 px): its edges sit 12 px from the
/// label centre, within one scan step. Caps an oversized band too.
void _d52ExpectBandEdges(
  Rect label,
  ({double top, double bottom, double height}) band,
) {
  expect(
    band.top,
    moreOrLessEquals(label.center.dy - 12, epsilon: _d52Step + 1e-9),
    reason: 'the hit box starts 12 px above the label centre',
  );
  expect(
    band.bottom,
    moreOrLessEquals(label.center.dy + 12, epsilon: _d52Step + 1e-9),
    reason: 'the hit box ends 12 px below the label centre',
  );
}

/// Moves the mouse away and lets the tooltip's timers run out.
Future<void> _d52Leave(WidgetTester tester, TestGesture mouse) async {
  await mouse.moveTo(const Offset(900, 20));
  await tester.pump(const Duration(seconds: 2));
}
