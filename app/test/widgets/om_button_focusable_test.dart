// WI #396 (Spec #393 req 8 `focusable`, req 10, TD "Focusable OmButton,
// opt-in", lead rulings LR2 and LR3, design pack 396, board `States`):
// `OmButton` gains opt-in keyboard focus and two opt-in style overrides.
//
// - `focusable: true`: a focus stop that Enter and Space press once on key
//   down (never on key repeat or key up), announced as a button labelled
//   `label ?? tooltip`, drawing a 2 px accent ring inside its box and a
//   surface4 fill while it has keyboard focus.
// - A disabled focusable button stays a focus stop, is announced disabled,
//   ignores every press and works again once re-enabled (LR3).
// - `hoverBackground` and `iconSize` override the kind's hover colour and
//   the 12 / 14 px icon (LR2).
// - Without the opt-ins an `OmButton` is drawn, hovered, clicked, announced
//   and traversed as on main.
//
// The probes look at what a person or a screen reader gets: where the focus
// is, the decorations drawn, the semantics node inside the button's box.
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../support/font_fetch_hold.dart';
import '../support/wi349_keyboard.dart';

const _a = Key('w396-a');
const _b = Key('w396-b');
const _d = Key('w396-default');

/// A press counter for a button's onPressed.
class _Presses {
  int count = 0;
  void call() => count++;
}

/// [children] in a row on a plain screen, with the app theme. Pumping the
/// same shape again keeps each button's state (and its focus).
Future<void> _pump(
  WidgetTester tester,
  List<Widget> children, {
  Widget Function(Widget row)? wrap,
}) {
  final row = Row(mainAxisSize: MainAxisSize.min, children: children);
  return tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(body: Center(child: wrap == null ? row : wrap(row))),
    ),
  );
}

/// The decorations at or under [target] that draw any accent border side
/// (a focus ring), with their global rects.
List<(BoxDecoration, Rect)> _rings(WidgetTester tester, Finder target) {
  final out = <(BoxDecoration, Rect)>[];
  final boxes = find.descendant(
    of: target,
    matching: find.byType(DecoratedBox),
    matchRoot: true,
  );
  for (final e in boxes.evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is! BoxDecoration) continue;
    final b = d.border;
    if (b == null) continue;
    final sides = [b.top, b.bottom];
    if (b is Border) sides.addAll([b.left, b.right]);
    final accent = sides.any(
      (s) =>
          s.style != BorderStyle.none &&
          s.width > 0 &&
          s.color == OmColors.accent,
    );
    if (!accent) continue;
    final box = e.renderObject! as RenderBox;
    out.add((d, box.localToGlobal(Offset.zero) & box.size));
  }
  return out;
}

/// Checks [ring] is the req 10 focus ring of a button drawn at [rect]: 2 px
/// accent on all four sides, drawn inside the box (outer edge flush with
/// the button's edge), following the 6 px radius.
void _expectFocusRing((BoxDecoration, Rect) ring, Rect rect) {
  final (d, at) = ring;
  final border = d.border;
  expect(border, isA<Border>(), reason: 'the ring is a four-sided border');
  final b = border! as Border;
  for (final s in [b.top, b.right, b.bottom, b.left]) {
    expect(s.color, OmColors.accent);
    expect(s.width, 2);
    expect(s.style, BorderStyle.solid);
    expect(
      s.strokeAlign,
      BorderSide.strokeAlignInside,
      reason: 'the ring is inset: drawn inside the box',
    );
  }
  expect(d.borderRadius, BorderRadius.circular(6));
  expect(at, rect, reason: 'the ring is drawn on the button box itself');
}

/// The button's fill: the colour of the outermost background decoration
/// the size of [target] (not a ring).
Color? _fill(WidgetTester tester, Finder target) {
  final size = tester.getSize(target);
  final boxes = find.descendant(
    of: target,
    matching: find.byType(DecoratedBox),
    matchRoot: true,
  );
  for (final e in boxes.evaluate()) {
    final w = e.widget as DecoratedBox;
    if (w.position != DecorationPosition.background) continue;
    final d = w.decoration;
    if (d is! BoxDecoration) continue;
    final b = d.border;
    if (b is Border && b.top.color == OmColors.accent) continue;
    if ((e.renderObject! as RenderBox).size != size) continue;
    return d.color;
  }
  fail('no background decoration the size of $target');
}

/// The opacity the button is painted at: the product of every opacity
/// layer inside it.
double _paintedOpacity(WidgetTester tester, Finder button) {
  var o = 1.0;
  for (final w in tester.widgetList<Opacity>(
    find.descendant(of: button, matching: find.byType(Opacity)),
  )) {
    o *= w.opacity;
  }
  for (final w in tester.widgetList<FadeTransition>(
    find.descendant(of: button, matching: find.byType(FadeTransition)),
  )) {
    o *= w.opacity.value;
  }
  return o;
}

/// Every visible, unmerged semantics node whose rect lies inside
/// [target]'s box (2 px slack). Needs `tester.ensureSemantics()`.
List<SemanticsNode> _nodesIn(WidgetTester tester, Finder target) {
  final box = tester.getRect(target).inflate(2);
  var root = tester.getSemantics(target);
  while (root.parent != null) {
    root = root.parent!;
  }
  final out = <SemanticsNode>[];
  void walk(SemanticsNode n, Matrix4 parent) {
    final m = n.transform == null ? parent : parent.multiplied(n.transform!);
    final r = MatrixUtils.transformRect(m, n.rect);
    if (!n.isInvisible &&
        !n.isMergedIntoParent &&
        r.width > 0 &&
        box.contains(r.topLeft) &&
        box.contains(r.bottomRight)) {
      out.add(n);
    }
    n.visitChildren((c) {
      walk(c, m);
      return true;
    });
  }

  final dpr = tester.view.devicePixelRatio;
  walk(root, Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1));
  return out;
}

/// The foreground (ring) decoration drawn at or under [target], or null.
BoxDecoration? _foregroundRing(WidgetTester tester, Finder target) {
  final boxes = find.descendant(
    of: target,
    matching: find.byType(DecoratedBox),
    matchRoot: true,
  );
  for (final e in boxes.evaluate()) {
    final w = e.widget as DecoratedBox;
    if (w.position != DecorationPosition.foreground) continue;
    final d = w.decoration;
    if (d is BoxDecoration && d.border != null) return d;
  }
  return null;
}

/// Pumps [children] under a parent [Focus] that records every key event it
/// is offered (key down, repeat and up) into [seen].
Future<void> _pumpRecording(
  WidgetTester tester,
  List<Widget> children,
  List<KeyEvent> seen,
) => _pump(
  tester,
  children,
  wrap: (row) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      seen.add(event);
      return KeyEventResult.ignored;
    },
    child: row,
  ),
);

/// A mouse pointer parked at the top-left corner, outside every button.
Future<TestGesture> _mouse(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await tester.pump();
  return g;
}

/// A full key press: key down, then key up.
Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump();
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

/// Tab once and settle.
Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
}

void main() {
  holdFontFetches();

  // ==================================================================== AC1
  group('AC1 a default OmButton is unchanged', () {
    testWidgets(
      'Tab skips a default OmButton and stops on the focusable ones beside it',
      (tester) async {
        final a = _Presses();
        final d = _Presses();
        final b = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'a', onPressed: a.call),
          OmButton(key: _d, label: 'plain', onPressed: d.call),
          OmButton(key: _b, focusable: true, label: 'b', onPressed: b.call),
        ]);

        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        await _tab(tester);
        expect(
          wi349FocusIn(find.byKey(_d)),
          isFalse,
          reason: 'the default OmButton is not a focus stop',
        );
        expect(wi349FocusIn(find.byKey(_b)), isTrue);
      },
    );

    testWidgets(
      'a default OmButton between two TextButtons is not a focus stop',
      (tester) async {
        await _pump(tester, [
          TextButton(key: _a, onPressed: () {}, child: const Text('a')),
          OmButton(key: _d, label: 'plain', onPressed: () {}),
          TextButton(key: _b, onPressed: () {}, child: const Text('b')),
        ]);

        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_d)), isFalse);
        expect(wi349FocusIn(find.byKey(_b)), isTrue);
      },
    );

    testWidgets('a default OmButton is not announced as a focusable button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, [
        OmButton(key: _d, label: 'plain', onPressed: () {}),
        const SizedBox(width: 8),
        OmButton(
          key: _a,
          icon: LucideIcons.x,
          tooltip: 'remove',
          onPressed: () {},
        ),
      ]);
      for (final key in [_d, _a]) {
        for (final n in _nodesIn(tester, find.byKey(key))) {
          final f = n.getSemanticsData().flagsCollection;
          expect(f.isButton, isFalse, reason: 'no button node on main');
          expect(f.isFocused, Tristate.none, reason: 'no focus node on main');
        }
      }
      handle.dispose();
    });

    testWidgets('a click on a default OmButton calls onPressed once', (
      tester,
    ) async {
      final d = _Presses();
      await _pump(tester, [
        OmButton(key: _d, label: 'plain', onPressed: d.call),
      ]);
      await tester.tap(find.byKey(_d));
      await tester.pumpAndSettle();
      expect(d.count, 1);
    });
  });

  // ==================================================================== AC2
  group('AC2 Tab reaches a focusable OmButton', () {
    testWidgets('Tab reaches a focusable OmButton and it takes focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, [
        OmButton(
          key: _a,
          focusable: true,
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.arrowRightLeft,
          tooltip: 'Move to…',
          onPressed: () {},
        ),
      ]);
      expect(wi349FocusIn(find.byKey(_a)), isFalse);

      await _tab(tester);
      expect(wi349FocusIn(find.byKey(_a)), isTrue);
      expect(
        wi349NodeLabelled(tester, find.byKey(_a), 'Move to…'),
        isSemantics(isFocusable: true, isFocused: true),
      );
      handle.dispose();
    });
  });

  // ==================================================================== AC3
  group('AC3 Enter and Space press once', () {
    for (final (name, key) in [
      (
        'Enter on a focused focusable OmButton calls onPressed once on key down',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on a focused focusable OmButton calls onPressed once on key down',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);
        expect(a.count, 0, reason: 'focus alone presses nothing');

        await tester.sendKeyDownEvent(key);
        await tester.pump();
        expect(a.count, 1, reason: 'the key down presses the button');

        await tester.sendKeyUpEvent(key);
        await tester.pump();
        expect(a.count, 1, reason: 'the key up does not press it again');
      });
    }

    for (final (name, key) in [
      (
        'holding Enter on a focused focusable OmButton calls onPressed once',
        LogicalKeyboardKey.enter,
      ),
      (
        'holding Space on a focused focusable OmButton calls onPressed once',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);

        await wi349HoldKey(tester, key, repeats: 4);
        expect(a.count, 1, reason: 'key repeats do not press it again');
      });
    }

    testWidgets('each separate Enter press calls onPressed again', (
      tester,
    ) async {
      final a = _Presses();
      await _pump(tester, [
        OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
      ]);
      await _tab(tester);

      await _press(tester, LogicalKeyboardKey.enter);
      await _press(tester, LogicalKeyboardKey.enter);
      expect(a.count, 2);
      await _press(tester, LogicalKeyboardKey.space);
      expect(a.count, 3);
    });

    testWidgets('Enter and Space press only the focused focusable OmButton', (
      tester,
    ) async {
      final a = _Presses();
      final b = _Presses();
      await _pump(tester, [
        OmButton(key: _a, focusable: true, label: 'a', onPressed: a.call),
        OmButton(key: _b, focusable: true, label: 'b', onPressed: b.call),
      ]);
      await _press(tester, LogicalKeyboardKey.enter);
      expect((a.count, b.count), (0, 0), reason: 'nothing is focused yet');

      await _tab(tester);
      await _press(tester, LogicalKeyboardKey.enter);
      expect((a.count, b.count), (1, 0));

      await _tab(tester);
      await _press(tester, LogicalKeyboardKey.space);
      expect((a.count, b.count), (1, 1));
    });

    testWidgets(
      'a focused focusable OmButton keeps Enter and Space from its parent and passes other keys on',
      (tester) async {
        final a = _Presses();
        final seen = <LogicalKeyboardKey>[];
        await _pump(
          tester,
          [
            OmButton(
              key: _a,
              focusable: true,
              label: 'open',
              onPressed: a.call,
            ),
          ],
          wrap: (row) => Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) seen.add(event.logicalKey);
              return KeyEventResult.ignored;
            },
            child: row,
          ),
        );
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        seen.clear();

        await _press(tester, LogicalKeyboardKey.enter);
        await _press(tester, LogicalKeyboardKey.space);
        expect(a.count, 2);
        await _press(tester, LogicalKeyboardKey.keyA);
        expect(a.count, 2, reason: 'a letter key does not press the button');
        expect(seen, [
          LogicalKeyboardKey.keyA,
        ], reason: 'Enter and Space are handled; other keys reach the parent');
      },
    );
  });

  // ==================================================================== AC4
  group('AC4 a click presses once', () {
    testWidgets(
      'a click on a focused focusable OmButton calls onPressed once',
      (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);

        await tester.tap(find.byKey(_a));
        await tester.pumpAndSettle();
        expect(a.count, 1);
      },
    );

    testWidgets(
      'a click on an unfocused focusable OmButton calls onPressed once',
      (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await tester.tap(find.byKey(_a));
        await tester.pumpAndSettle();
        expect(a.count, 1);
      },
    );
  });

  // ==================================================================== AC5
  group('AC5 semantics', () {
    testWidgets(
      'a focusable OmButton with a label is announced as an enabled focusable button with that label',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: () {}),
        ]);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'open'),
          isSemantics(
            label: 'open',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'an icon-only focusable OmButton is announced with its tooltip as the label',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            tooltip: 'Remove from Player Loop',
            onPressed: () {},
          ),
        ]);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'Remove from Player Loop'),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a focusable OmButton with a label and a tooltip is announced with the label',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            tooltip: 'open the vault',
            onPressed: () {},
          ),
        ]);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'open'),
          isSemantics(isButton: true),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a semantics tap on a focusable OmButton calls onPressed once',
      (tester) async {
        final handle = tester.ensureSemantics();
        final a = _Presses();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.folderInput,
            tooltip: 'File in…',
            onPressed: a.call,
          ),
        ]);
        final node = wi349NodeLabelled(tester, find.byKey(_a), 'File in…');
        expect(node, isSemantics(isButton: true, hasTapAction: true));

        await wi349SemanticTap(tester, node);
        expect(a.count, 1);
        handle.dispose();
      },
    );
  });

  // ==================================================================== AC6
  group('AC6 focus look', () {
    testWidgets(
      'a focusable OmButton draws no ring and no focus fill on its first frame',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        // The first frame, before any settle.
        expect(_rings(tester, find.byKey(_a)), isEmpty);
        expect(_fill(tester, find.byKey(_a)), Colors.transparent);

        await tester.pumpAndSettle();
        expect(_rings(tester, find.byKey(_a)), isEmpty);
        expect(_fill(tester, find.byKey(_a)), Colors.transparent);

        await _tab(tester);
        expect(_rings(tester, find.byKey(_a)), hasLength(1));
      },
    );

    testWidgets(
      'keyboard focus draws a 2 px accent ring inside the box and a surface4 fill without changing the size',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.arrowRightLeft,
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          OmButton(
            key: _b,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        final restRect = tester.getRect(a);
        expect(restRect.size, const Size(24, 24));

        await _tab(tester);
        expect(wi349FocusIn(a), isTrue);
        expect(tester.getRect(a), restRect, reason: 'focus keeps the size');
        final rings = _rings(tester, a);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, restRect);
        expect(_fill(tester, a), OmColors.surface4);
        expect(_rings(tester, find.byKey(_b)), isEmpty);

        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_b)), isTrue);
        expect(
          _rings(tester, a),
          isEmpty,
          reason: 'the ring leaves with the focus',
        );
        expect(_fill(tester, a), Colors.transparent);
        expect(tester.getRect(a), restRect);
        expect(_rings(tester, find.byKey(_b)), hasLength(1));
      },
    );

    testWidgets(
      'a focusable OmButton with a label keeps its size and draws the ring on its box',
      (tester) async {
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: () {}),
        ]);
        final a = find.byKey(_a);
        final restRect = tester.getRect(a);
        expect(restRect.height, 30);

        await _tab(tester);
        expect(tester.getRect(a), restRect);
        final rings = _rings(tester, a);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, restRect);
      },
    );

    testWidgets(
      'the focus fill is hoverBackground when set and surface4 for ghost and secondary otherwise',
      (tester) async {
        // D29 / LR9: a set hoverBackground is also the focus fill.
        const k = [
          Key('w396-k0'),
          Key('w396-k1'),
          Key('w396-k2'),
          Key('w396-k3'),
        ];
        await _pump(tester, [
          OmButton(
            key: k[0],
            focusable: true,
            kind: OmButtonKind.secondary,
            hoverBackground: OmColors.agentBg,
            label: 'a',
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          OmButton(
            key: k[1],
            focusable: true,
            kind: OmButtonKind.ghost,
            hoverBackground: OmColors.dangerBg,
            label: 'b',
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          OmButton(
            key: k[2],
            focusable: true,
            kind: OmButtonKind.secondary,
            label: 'c',
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          OmButton(
            key: k[3],
            focusable: true,
            kind: OmButtonKind.ghost,
            label: 'd',
            onPressed: () {},
          ),
        ]);
        expect(_fill(tester, find.byKey(k[0])), OmColors.surface3);
        expect(_fill(tester, find.byKey(k[1])), Colors.transparent);

        final focusFills = [
          OmColors.agentBg,
          OmColors.dangerBg,
          OmColors.surface4,
          OmColors.surface4,
        ];
        final restFills = [
          OmColors.surface3,
          Colors.transparent,
          OmColors.surface3,
          Colors.transparent,
        ];
        for (var i = 0; i < 4; i++) {
          await _tab(tester);
          for (var j = 0; j < 4; j++) {
            expect(
              _fill(tester, find.byKey(k[j])),
              j == i ? focusFills[j] : restFills[j],
              reason: 'focus on $i, button $j',
            );
          }
        }
      },
    );

    testWidgets(
      'a focused and hovered focusable OmButton keeps the focus fill and ring',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            hoverBackground: OmColors.agentBg,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          OmButton(
            key: _b,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        final b = find.byKey(_b);
        final mouse = await _mouse(tester);
        await _tab(tester);
        expect(_fill(tester, a), OmColors.agentBg, reason: 'D29 focus fill');

        await mouse.moveTo(tester.getCenter(a));
        await tester.pumpAndSettle();
        expect(_fill(tester, a), OmColors.agentBg, reason: 'focus wins');
        expect(_rings(tester, a), hasLength(1));

        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_fill(tester, a), OmColors.agentBg);
        expect(_rings(tester, a), hasLength(1));

        // Without hoverBackground focus wins over the kind hover (surface3).
        await _tab(tester);
        await mouse.moveTo(tester.getCenter(b));
        await tester.pumpAndSettle();
        expect(_fill(tester, b), OmColors.surface4, reason: 'focus wins');
        expect(_rings(tester, b), hasLength(1));
        expect(_fill(tester, a), Colors.transparent);
      },
    );

    testWidgets(
      'a mouse click leaves no focus ring on a focusable OmButton and Tab then shows it',
      (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: a.call,
          ),
        ]);
        final button = find.byKey(_a);
        final mouse = await _mouse(tester);
        await mouse.moveTo(tester.getCenter(button));
        await mouse.down(tester.getCenter(button));
        await mouse.up();
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(a.count, 1);
        expect(_rings(tester, button), isEmpty);
        expect(_fill(tester, button), Colors.transparent);

        await _tab(tester);
        expect(wi349FocusIn(button), isTrue);
        expect(_rings(tester, button), hasLength(1));
      },
    );

    testWidgets(
      'a focused focusable OmButton shows no ring while the focus highlight is off',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTouch);
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        expect(_rings(tester, find.byKey(_a)), isEmpty);
      },
    );
  });

  // ==================================================================== AC7
  group('AC7 disabled focusable (LR3)', () {
    testWidgets(
      'a disabled focusable OmButton is a focus stop announced as a disabled button',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            onPressed: null,
          ),
        ]);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'open'),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a focusable OmButton that becomes disabled keeps focus and ignores Enter Space click and semantics tap',
      (tester) async {
        final handle = tester.ensureSemantics();
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);

        await _pump(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            onPressed: null,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(
          wi349FocusIn(find.byKey(_a)),
          isTrue,
          reason: 'the button keeps focus as it becomes disabled',
        );

        await _press(tester, LogicalKeyboardKey.enter);
        await wi349HoldKey(tester, LogicalKeyboardKey.enter);
        await _press(tester, LogicalKeyboardKey.space);
        await tester.tap(find.byKey(_a));
        await tester.pumpAndSettle();
        final node = wi349NodeLabelled(tester, find.byKey(_a), 'open');
        expect(node, isSemantics(isButton: true, isEnabled: false));
        await wi349SemanticTap(tester, node);
        expect(a.count, 0, reason: 'no press reaches the old onPressed');
        expect(tester.takeException(), isNull);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        handle.dispose();
      },
    );

    testWidgets(
      'a disabled focusable OmButton that is enabled again presses on Enter',
      (tester) async {
        final a = _Presses();
        final b = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);
        await _pump(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            onPressed: null,
          ),
        ]);
        await tester.pumpAndSettle();
        await _press(tester, LogicalKeyboardKey.enter);

        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: b.call),
        ]);
        await tester.pumpAndSettle();
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        await _press(tester, LogicalKeyboardKey.enter);
        expect((a.count, b.count), (0, 1));
        await _press(tester, LogicalKeyboardKey.space);
        expect((a.count, b.count), (0, 2));
      },
    );

    testWidgets(
      'a focused disabled focusable OmButton keeps the focus ring at 40 percent opacity',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        await _tab(tester);
        await _pump(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: null,
          ),
        ]);
        await tester.pumpAndSettle();
        final a = find.byKey(_a);
        final rings = _rings(tester, a);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, tester.getRect(a));
        expect(_fill(tester, a), OmColors.surface4);
        expect(_paintedOpacity(tester, a), closeTo(0.4, 1e-9));
      },
    );

    testWidgets('a disabled focusable OmButton without focus draws no ring', (
      tester,
    ) async {
      await _pump(tester, [
        const OmButton(
          key: _a,
          focusable: true,
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.x,
          onPressed: null,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(_rings(tester, find.byKey(_a)), isEmpty);
      expect(_fill(tester, find.byKey(_a)), Colors.transparent);

      await _tab(tester);
      expect(_rings(tester, find.byKey(_a)), hasLength(1));
    });
  });

  // ==================================================================== AC8
  group('AC8 hoverBackground', () {
    for (final (name, kind, focusable, hover, rest) in [
      (
        'hoverBackground sets the hover fill of a ghost OmButton',
        OmButtonKind.ghost,
        false,
        OmColors.surface4,
        Colors.transparent,
      ),
      (
        'hoverBackground sets the hover fill of a secondary OmButton',
        OmButtonKind.secondary,
        false,
        OmColors.agentBg,
        OmColors.surface3,
      ),
      (
        'hoverBackground sets the hover fill of a focusable ghost OmButton',
        OmButtonKind.ghost,
        true,
        OmColors.surface4,
        Colors.transparent,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            kind: kind,
            focusable: focusable,
            hoverBackground: hover,
            label: 'go',
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        expect(_fill(tester, a), rest);

        final mouse = await _mouse(tester);
        await mouse.moveTo(tester.getCenter(a));
        await tester.pumpAndSettle();
        expect(_fill(tester, a), hover, reason: 'mouse in');

        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_fill(tester, a), rest, reason: 'mouse out');
      });
    }

    testWidgets(
      'without hoverBackground an OmButton hovers to its kind hover colour',
      (tester) async {
        for (final (kind, focusable, hover) in [
          (OmButtonKind.ghost, false, OmColors.surface3),
          (OmButtonKind.ghost, true, OmColors.surface3),
          (OmButtonKind.secondary, false, OmColors.surface4),
        ]) {
          await _pump(tester, [
            OmButton(
              key: ValueKey((kind, focusable)),
              kind: kind,
              focusable: focusable,
              label: 'go',
              onPressed: () {},
            ),
          ]);
          final a = find.byKey(ValueKey((kind, focusable)));
          final mouse = await _mouse(tester);
          await mouse.moveTo(tester.getCenter(a));
          await tester.pumpAndSettle();
          expect(_fill(tester, a), hover, reason: '$kind $focusable');
          await mouse.removePointer();
          await tester.pumpAndSettle();
        }
      },
    );
  });

  // ==================================================================== AC9
  group('AC9 iconSize', () {
    for (final (name, size, dense, label) in <(String, double, bool, String?)>[
      ('an iconSize 13 OmButton draws a 13 px icon', 13, false, null),
      ('a dense iconSize 13 OmButton draws a 13 px icon', 13, true, null),
      (
        'an iconSize 18 OmButton with a label draws an 18 px icon',
        18,
        false,
        'go',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            iconSize: size,
            dense: dense,
            label: label,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        expect(tester.getSize(find.byIcon(LucideIcons.x)), Size(size, size));
      });
    }

    testWidgets('without iconSize the icon is 14 px or 12 px when dense', (
      tester,
    ) async {
      for (final (dense, size) in [(false, 14.0), (true, 12.0)]) {
        await _pump(tester, [
          OmButton(
            key: ValueKey(dense),
            dense: dense,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        expect(tester.getSize(find.byIcon(LucideIcons.x)), Size(size, size));
      }
    });
  });

  // ================================================== contracts pinned in verify
  group('focusable contracts', () {
    testWidgets(
      'a focused primary focusable OmButton fills 94FFC1 and draws an accentFg ring',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.primary,
            label: 'go',
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        expect(_fill(tester, a), OmColors.accent);
        expect(_foregroundRing(tester, a), isNull);

        await _tab(tester);
        expect(_fill(tester, a), const Color(0xFF94FFC1));
        final ring = _foregroundRing(tester, a);
        expect(ring, isNotNull);
        final b = ring!.border! as Border;
        for (final side in [b.top, b.right, b.bottom, b.left]) {
          expect(side.color, OmColors.accentFg);
          expect(side.width, 2);
          expect(side.strokeAlign, BorderSide.strokeAlignInside);
        }
        expect(ring.borderRadius, BorderRadius.circular(6));
      },
    );

    for (final (name, kind, fill) in [
      (
        'a focused agent focusable OmButton fills agentBg and draws an accent ring',
        OmButtonKind.agent,
        OmColors.agentBg,
      ),
      (
        'a focused danger focusable OmButton fills dangerBg and draws an accent ring',
        OmButtonKind.danger,
        OmColors.dangerBg,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: kind,
            label: 'go',
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        expect(_rings(tester, a), isEmpty);
        await _tab(tester);
        expect(_fill(tester, a), fill);
        final rings = _rings(tester, a);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, tester.getRect(a));
      });
    }

    testWidgets(
      'numpad Enter on a focused focusable OmButton presses once on key down',
      (tester) async {
        final a = _Presses();
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ]);
        await _tab(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.numpadEnter);
        await tester.pump();
        expect(a.count, 1);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.numpadEnter);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.numpadEnter);
        await tester.pump();
        expect(a.count, 1, reason: 'repeat and key up do not press');
      },
    );

    testWidgets(
      'a focused focusable OmButton swallows every Enter and Space event from its parent',
      (tester) async {
        final a = _Presses();
        final seen = <KeyEvent>[];
        await _pumpRecording(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ], seen);
        await _tab(tester);
        seen.clear();
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ]) {
          await wi349HoldKey(tester, key);
        }
        expect(a.count, 3, reason: 'one press per key');
        expect(
          seen,
          isEmpty,
          reason: 'key down, repeat and up are all handled',
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(seen.map((e) => (e.runtimeType, e.logicalKey)).toList(), [
          (KeyDownEvent, LogicalKeyboardKey.keyA),
          (KeyRepeatEvent, LogicalKeyboardKey.keyA),
          (KeyUpEvent, LogicalKeyboardKey.keyA),
        ], reason: 'other keys, with all their events, reach the parent');
        expect(a.count, 3);
      },
    );

    testWidgets(
      'a focused disabled focusable OmButton swallows Enter and Space from its parent',
      (tester) async {
        final seen = <KeyEvent>[];
        await _pumpRecording(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            onPressed: null,
          ),
        ], seen);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        seen.clear();
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ]) {
          await wi349HoldKey(tester, key);
        }
        expect(seen, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a focused focusable OmButton follows the focus highlight mode',
      (tester) async {
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            icon: LucideIcons.x,
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        await _tab(tester);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(_rings(tester, a), hasLength(1));

        // A touch moves the highlight mode to touch; the focus stays.
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
        expect(wi349FocusIn(a), isTrue);
        expect(_rings(tester, a), isEmpty, reason: 'no ring in touch mode');
        expect(_fill(tester, a), Colors.transparent);

        // A key press brings the highlight, and the ring, back.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(_rings(tester, a), hasLength(1));
        expect(_fill(tester, a), OmColors.surface4);
      },
    );

    testWidgets(
      'a focusable OmButton disposed while focused ignores later highlight changes',
      (tester) async {
        await _pump(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: () {}),
        ]);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);
        await _pump(tester, const [SizedBox(width: 10, height: 10)]);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a focusable OmButton that stops being focusable while focused drops the ring and its focus state',
      (tester) async {
        final a = _Presses();
        Widget button({required bool focusable}) => OmButton(
          key: _a,
          focusable: focusable,
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.x,
          tooltip: 'remove',
          onPressed: a.call,
        );
        await _pump(tester, [button(focusable: true)]);
        await _tab(tester);
        expect(_rings(tester, find.byKey(_a)), hasLength(1));

        await _pump(tester, [button(focusable: false)]);
        await tester.pumpAndSettle();
        final plain = find.byKey(_a);
        expect(_rings(tester, plain), isEmpty);
        expect(_fill(tester, plain), Colors.transparent);
        await _press(tester, LogicalKeyboardKey.enter);
        expect(a.count, 0, reason: 'a plain button takes no key press');
        await tester.tap(plain);
        await tester.pumpAndSettle();
        expect(a.count, 1, reason: 'a click still presses it');

        // Focusable again: the new Focus has no focus, so no ring comes back
        // even in keyboard highlight mode (the click above set touch mode).
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        await _pump(tester, [button(focusable: true)]);
        await tester.pumpAndSettle();
        expect(wi349FocusIn(find.byKey(_a)), isFalse);
        expect(_rings(tester, find.byKey(_a)), isEmpty);
        expect(_fill(tester, find.byKey(_a)), Colors.transparent);
      },
    );

    for (final (name, label, tooltip, announced)
        in <(String, String?, String?, String)>[
          (
            'a focusable OmButton with a label is one leaf button node',
            'open',
            null,
            'open',
          ),
          (
            'a focusable OmButton with a tooltip is one leaf button node',
            null,
            'remove',
            'remove',
          ),
          (
            'a focusable OmButton with a label and a tooltip is one leaf button node',
            'open',
            'open the vault',
            'open',
          ),
        ]) {
      testWidgets(name, (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: label,
            icon: label == null ? LucideIcons.x : null,
            tooltip: tooltip,
            onPressed: () {},
          ),
        ]);
        final nodes = _nodesIn(tester, find.byKey(_a));
        expect(nodes, hasLength(1), reason: 'the button is one node');
        final node = nodes.single;
        expect(node.childrenCount, 0, reason: 'its children are excluded');
        expect(node.getSemanticsData().label, announced);
        expect(
          node,
          isSemantics(
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocused: false,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      });
    }

    testWidgets(
      'a disabled focusable OmButton offers no tap action and is one leaf node',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            tooltip: 'open the vault',
            onPressed: null,
          ),
        ]);
        final nodes = _nodesIn(tester, find.byKey(_a));
        expect(nodes, hasLength(1));
        expect(nodes.single.childrenCount, 0);
        expect(
          nodes.single,
          isSemantics(
            label: 'open',
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: false,
            isFocused: false,
            hasTapAction: false,
          ),
        );
        handle.dispose();
      },
    );
  });

  // ============================================================ review r1
  // The owned seams #398, #427 and #411 build on (D9): `focusNode`,
  // `semanticLabel`, `toggled`, modifier keys, and the button's own node.
  group('r1 seams: focusNode semanticLabel toggled modifiers container', () {
    testWidgets(
      'focusNode.requestFocus focuses the focusable OmButton and shows the ring',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        final node = FocusNode(debugLabel: 'w396 button');
        addTearDown(node.dispose);
        final a = _Presses();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'fix',
            focusNode: node,
            onPressed: a.call,
          ),
        ]);
        final button = find.byKey(_a);
        expect(node.hasPrimaryFocus, isFalse);
        expect(_rings(tester, button), isEmpty);

        node.requestFocus();
        await tester.pumpAndSettle();
        expect(node.hasPrimaryFocus, isTrue);
        expect(wi349FocusIn(button), isTrue);
        final rings = _rings(tester, button);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, tester.getRect(button));

        await _press(tester, LogicalKeyboardKey.enter);
        expect(a.count, 1, reason: 'Enter presses the button focused by node');
      },
    );

    testWidgets('Tab focuses the passed focusNode of a focusable OmButton', (
      tester,
    ) async {
      final node = FocusNode(debugLabel: 'w396 tab');
      addTearDown(node.dispose);
      await _pump(tester, [
        OmButton(
          key: _a,
          focusable: true,
          label: 'fix',
          focusNode: node,
          onPressed: () {},
        ),
      ]);
      await _tab(tester);
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets(
      'requestFocus moves focus between two focusable OmButtons by their nodes',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        final n1 = FocusNode(debugLabel: 'w396 one');
        final n2 = FocusNode(debugLabel: 'w396 two');
        addTearDown(n1.dispose);
        addTearDown(n2.dispose);
        final p1 = _Presses();
        final p2 = _Presses();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'one',
            focusNode: n1,
            onPressed: p1.call,
          ),
          OmButton(
            key: _b,
            focusable: true,
            label: 'two',
            focusNode: n2,
            onPressed: p2.call,
          ),
        ]);
        n2.requestFocus();
        await tester.pumpAndSettle();
        expect(wi349FocusIn(find.byKey(_b)), isTrue);
        expect(_rings(tester, find.byKey(_a)), isEmpty);
        expect(_rings(tester, find.byKey(_b)), hasLength(1));
        await _press(tester, LogicalKeyboardKey.enter);
        expect((p1.count, p2.count), (0, 1));

        n1.requestFocus();
        await tester.pumpAndSettle();
        expect(_rings(tester, find.byKey(_a)), hasLength(1));
        expect(_rings(tester, find.byKey(_b)), isEmpty);
        await _press(tester, LogicalKeyboardKey.enter);
        expect((p1.count, p2.count), (1, 1));
      },
    );

    testWidgets(
      'a focusNode on a default OmButton does not make it a focus stop',
      (tester) async {
        final node = FocusNode(debugLabel: 'w396 ignored');
        addTearDown(node.dispose);
        await _pump(tester, [
          OmButton(key: _d, label: 'plain', focusNode: node, onPressed: () {}),
          OmButton(key: _b, focusable: true, label: 'b', onPressed: () {}),
        ]);
        node.requestFocus();
        await tester.pump();
        expect(node.hasFocus, isFalse, reason: 'the node is not attached');
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_d)), isFalse);
        expect(wi349FocusIn(find.byKey(_b)), isTrue);
      },
    );

    testWidgets(
      'semanticLabel replaces the label as the announced label of a focusable OmButton',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'link',
            semanticLabel: 'Link Level Design to this note',
            onPressed: () {},
          ),
        ]);
        final node = wi349NodeLabelled(
          tester,
          find.byKey(_a),
          'Link Level Design to this note',
        );
        expect(
          node,
          isSemantics(
            label: 'Link Level Design to this note',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        final nodes = _nodesIn(tester, find.byKey(_a));
        expect(nodes, hasLength(1), reason: 'the visible label is not a node');
        expect(nodes.single.childrenCount, 0);
        handle.dispose();
      },
    );

    testWidgets(
      'semanticLabel replaces the tooltip of an icon-only focusable OmButton',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            icon: LucideIcons.eye,
            tooltip: 'Reveal',
            semanticLabel: 'Reveal access token',
            onPressed: () {},
          ),
        ]);
        final nodes = _nodesIn(tester, find.byKey(_a));
        expect(nodes, hasLength(1));
        expect(
          nodes.single,
          isSemantics(label: 'Reveal access token', isButton: true),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a semantics tap on a semanticLabel focusable OmButton calls onPressed once',
      (tester) async {
        final handle = tester.ensureSemantics();
        final a = _Presses();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'link',
            semanticLabel: 'Link Level Design to this note',
            onPressed: a.call,
          ),
        ]);
        await wi349SemanticTap(
          tester,
          wi349NodeLabelled(
            tester,
            find.byKey(_a),
            'Link Level Design to this note',
          ),
        );
        expect(a.count, 1);
        handle.dispose();
      },
    );

    for (final (name, toggled) in [
      (
        'toggled true announces a focusable OmButton as a toggle that is on',
        true,
      ),
      (
        'toggled false announces a focusable OmButton as a toggle that is off',
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            label: 'Reveal',
            toggled: toggled,
            onPressed: () {},
          ),
        ]);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'Reveal'),
          isSemantics(
            label: 'Reveal',
            isButton: true,
            hasToggledState: true,
            isToggled: toggled,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      });
    }

    testWidgets('toggled follows the widget when it flips', (tester) async {
      final handle = tester.ensureSemantics();
      Future<void> pump(bool? toggled) => _pump(tester, [
        OmButton(
          key: _a,
          focusable: true,
          label: 'Reveal',
          toggled: toggled,
          onPressed: () {},
        ),
      ]);
      await pump(false);
      expect(
        wi349NodeLabelled(tester, find.byKey(_a), 'Reveal'),
        isSemantics(hasToggledState: true, isToggled: false),
      );
      await pump(true);
      expect(
        wi349NodeLabelled(tester, find.byKey(_a), 'Reveal'),
        isSemantics(hasToggledState: true, isToggled: true),
      );
      await pump(null);
      expect(
        wi349NodeLabelled(tester, find.byKey(_a), 'Reveal'),
        isSemantics(hasToggledState: false, isButton: true),
      );
      handle.dispose();
    });

    testWidgets('without toggled a focusable OmButton is a plain button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, [
        OmButton(key: _a, focusable: true, label: 'open', onPressed: () {}),
      ]);
      expect(
        wi349NodeLabelled(tester, find.byKey(_a), 'open'),
        isSemantics(hasToggledState: false, isButton: true),
      );
      handle.dispose();
    });

    for (final (name, modifier) in [
      (
        'Shift with Enter, numpad Enter or Space on a focused focusable OmButton presses nothing and reaches the parent',
        LogicalKeyboardKey.shiftLeft,
      ),
      (
        'Control with Enter, numpad Enter or Space on a focused focusable OmButton presses nothing and reaches the parent',
        LogicalKeyboardKey.controlLeft,
      ),
      (
        'Alt with Enter, numpad Enter or Space on a focused focusable OmButton presses nothing and reaches the parent',
        LogicalKeyboardKey.altLeft,
      ),
      (
        'Meta with Enter, numpad Enter or Space on a focused focusable OmButton presses nothing and reaches the parent',
        LogicalKeyboardKey.metaLeft,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Presses();
        final seen = <KeyEvent>[];
        await _pumpRecording(tester, [
          OmButton(key: _a, focusable: true, label: 'open', onPressed: a.call),
        ], seen);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);

        var plain = 0;
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyDownEvent(modifier);
          seen.clear();
          await tester.sendKeyDownEvent(key);
          await tester.sendKeyRepeatEvent(key);
          await tester.sendKeyUpEvent(key);
          await tester.sendKeyUpEvent(modifier);
          await tester.pump();

          expect(
            a.count,
            plain,
            reason: 'a modified ${key.keyLabel} does not press',
          );
          expect(
            seen.where((e) => e.logicalKey == key).map((e) => e.runtimeType),
            [KeyDownEvent, KeyRepeatEvent, KeyUpEvent],
            reason: 'every event of the modified key reaches the parent',
          );

          await _press(tester, key);
          plain++;
          expect(a.count, plain, reason: 'the plain key presses again');
        }
      });
    }

    testWidgets(
      'a modified Enter on a disabled focusable OmButton still reaches the parent',
      (tester) async {
        final seen = <KeyEvent>[];
        await _pumpRecording(tester, [
          const OmButton(
            key: _a,
            focusable: true,
            label: 'open',
            onPressed: null,
          ),
        ], seen);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_a)), isTrue);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        seen.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          seen.where((e) => e.logicalKey == LogicalKeyboardKey.enter),
          hasLength(2),
          reason: 'a modified key is not swallowed by a disabled button',
        );

        seen.clear();
        await _press(tester, LogicalKeyboardKey.enter);
        expect(
          seen.where((e) => e.logicalKey == LogicalKeyboardKey.enter),
          isEmpty,
          reason: 'a plain Enter is still swallowed by a disabled button',
        );
      },
    );

    testWidgets(
      'a focusable OmButton beside a Text in a semantics container is its own node',
      (tester) async {
        final handle = tester.ensureSemantics();
        final a = _Presses();
        await _pump(tester, [
          const Text('row text'),
          OmButton(key: _a, focusable: true, label: 'fix', onPressed: a.call),
        ], wrap: (row) => Semantics(container: true, child: row));
        final node = wi349NodeLabelled(tester, find.byKey(_a), 'fix');
        expect(
          node,
          isSemantics(
            label: 'fix',
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        await wi349SemanticTap(tester, node);
        expect(a.count, 1);

        await _tab(tester);
        expect(
          wi349NodeLabelled(tester, find.byKey(_a), 'fix'),
          isSemantics(isFocused: true),
        );
        handle.dispose();
      },
    );
  });

  // =================================================================== AC11
  group('AC11 design check (board States, .ib .ib.hover .ib.focus)', () {
    testWidgets(
      'the board icon button rests hovers and focuses as drawn on the States board',
      (tester) async {
        // Board values (pack 396): 24 x 24, radius 6, 13 px fg1 icon, rest
        // transparent, hover #20262E, focus 2 px #7CFFB2 inset ring + #20262E.
        expect(OmColors.surface4, const Color(0xFF20262E));
        expect(OmColors.accent, const Color(0xFF7CFFB2));
        expect(OmColors.fg1, const Color(0xFFD6D3CC));
        await _pump(tester, [
          OmButton(
            key: _a,
            focusable: true,
            kind: OmButtonKind.ghost,
            size: 24,
            iconSize: 13,
            hoverBackground: OmColors.surface4,
            icon: LucideIcons.arrowRightLeft,
            tooltip: 'Move to…',
            onPressed: () {},
          ),
        ]);
        final a = find.byKey(_a);
        final rect = tester.getRect(a);
        expect(rect.size, const Size(24, 24));
        final icon = find.byIcon(LucideIcons.arrowRightLeft);
        expect(tester.getSize(icon), const Size(13, 13));
        expect(tester.getCenter(icon), rect.center, reason: 'icon centred');
        expect(tester.widget<Icon>(icon).color, OmColors.fg1);
        expect(_fill(tester, a), Colors.transparent);
        expect(_rings(tester, a), isEmpty);

        // .ib.hover
        final mouse = await _mouse(tester);
        await mouse.moveTo(rect.center);
        await tester.pumpAndSettle();
        expect(_fill(tester, a), OmColors.surface4);
        expect(_rings(tester, a), isEmpty, reason: 'hover draws no ring');
        expect(tester.getRect(a), rect);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_fill(tester, a), Colors.transparent);

        // .ib.focus
        await _tab(tester);
        final rings = _rings(tester, a);
        expect(rings, hasLength(1));
        _expectFocusRing(rings.single, rect);
        expect(_fill(tester, a), OmColors.surface4);
        expect(tester.getRect(a), rect);
        expect(tester.getSize(icon), const Size(13, 13));
      },
    );
  });
}
