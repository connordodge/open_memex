// WI #349 (Spec #347 req 18, TD7): keyboard, focus-ring and semantics probes
// for the shared keyboard buttons (`DialogButton`, `PickerRowIconButton`).
// They look at what a person or a screen reader gets (where the focus is,
// the border drawn, the semantics node inside the button's box), never at a
// widget's private state.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';

/// Whether the primary focus is on [target]'s widget or inside it.
bool wi349FocusIn(Finder target) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return find
      .descendant(
        of: target,
        matching: find.byElementPredicate((e) => identical(e, focused)),
        matchRoot: true,
      )
      .evaluate()
      .isNotEmpty;
}

/// Presses Tab until the focus is inside [target]; fails after [max] presses.
Future<void> wi349TabTo(
  WidgetTester tester,
  Finder target, {
  int max = 60,
}) async {
  for (var i = 0; i < max; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (wi349FocusIn(target)) return;
  }
  fail('Tab never reached $target');
}

/// Forces the focus highlight [strategy] for the rest of the test.
void wi349HighlightStrategy(FocusHighlightStrategy strategy) {
  final previous = FocusManager.instance.highlightStrategy;
  FocusManager.instance.highlightStrategy = strategy;
  addTearDown(() => FocusManager.instance.highlightStrategy = previous);
}

/// The `accentSoft` borders drawn at or under [target] (a focus ring), as
/// their decorations and global rects.
List<(BoxDecoration, Rect)> wi349Rings(WidgetTester tester, Finder target) {
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
    final ring = sides.any(
      (s) =>
          s.style != BorderStyle.none &&
          s.width > 0 &&
          s.color == OmColors.accentSoft,
    );
    if (!ring) continue;
    final box = e.renderObject! as RenderBox;
    out.add((d, box.localToGlobal(Offset.zero) & box.size));
  }
  return out;
}

/// The single semantics node labelled exactly [label] whose rect lies inside
/// [target]'s box (2 px slack). Fails when there is none or more than one.
/// Needs `tester.ensureSemantics()`.
SemanticsNode wi349NodeLabelled(
  WidgetTester tester,
  Finder target,
  String label,
) {
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
        box.contains(r.bottomRight) &&
        n.getSemanticsData().label == label) {
      out.add(n);
    }
    n.visitChildren((c) {
      walk(c, m);
      return true;
    });
  }

  // The root node is in physical pixels; the test's rects are logical.
  final dpr = tester.view.devicePixelRatio;
  walk(root, Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1));
  expect(
    out,
    hasLength(1),
    reason: 'one semantics node labelled "$label" inside $target',
  );
  return out.single;
}

/// Performs the semantic tap (what VoiceOver's activate does) on [node].
Future<void> wi349SemanticTap(WidgetTester tester, SemanticsNode node) async {
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await tester.pump();
}

/// Moves a mouse over [target]'s centre and returns the cursor shown there.
/// The mouse is removed afterwards.
Future<MouseCursor?> wi349CursorOver(WidgetTester tester, Finder target) async {
  final at = tester.getCenter(target);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  try {
    await tester.pump();
    await mouse.moveTo(at);
    await tester.pump();
    return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
  } finally {
    await mouse.removePointer();
    await tester.pump();
  }
}

/// Holds [key] down like a real keyboard: a key-down, [repeats] key-repeat
/// events, then a key-up. A button that presses on every repeat is pressed
/// [repeats] + 1 times; one that presses once per key press, once.
Future<void> wi349HoldKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  int repeats = 3,
}) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump();
  for (var i = 0; i < repeats; i++) {
    await tester.sendKeyRepeatEvent(key);
    await tester.pump();
  }
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}
