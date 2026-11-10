// WI #362 (lead ruling "whole-row keyboard focus", board S4, Spec #357
// Req 16): a `PickerRowShell` (recent and server rows) takes the keyboard
// focus; while the focus highlight is on it draws a 1 px `accentSoft` ring
// 1 px outside its fill, radius 7.5, and only then; Enter and Space call
// its `onTap` once per key press (a held key's repeats are ignored). Bare
// shells in a MaterialApp; the probes look at the focus and the borders
// drawn, never at private state.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/wi349_keyboard.dart';
import '../../support/wi362_modal.dart';

const _a = Key('row-a');
const _b = Key('row-b');
const _c = Key('row-c');

/// Three shells: a and b open (counting into [taps]), c has no onTap (a
/// server row, or a row that can't open).
Future<void> _pump(WidgetTester tester, Map<Key, int> taps) async {
  Widget shell(Key key, {bool tappable = true}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: PickerRowShell(
      key: key,
      onTap: tappable ? () => taps[key] = (taps[key] ?? 0) + 1 : null,
      child: Text('$key'),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: OmColors.surface1,
        body: Center(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [shell(_a), shell(_b), shell(_c, tappable: false)],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The global rect of the row's `surface2` fill.
Rect _fill(WidgetTester tester, Key row) {
  final fills = [
    for (final e
        in find
            .descendant(
              of: find.byKey(row),
              matching: find.byType(DecoratedBox),
              matchRoot: true,
            )
            .evaluate())
      if ((e.widget as DecoratedBox).decoration case final BoxDecoration d
          when d.color == OmColors.surface2 || d.color == OmColors.surface3)
        e,
  ];
  expect(fills, isNotEmpty, reason: 'the row fill');
  final box = fills.first.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The S4 ring on [row]: one 1 px accentSoft border on every side, radius
/// 7.5, 1 px outside the fill.
void _expectRing(WidgetTester tester, Key row) {
  final rings = wi349Rings(tester, find.byKey(row));
  expect(rings, hasLength(1), reason: 'one ring on $row');
  final (d, rect) = rings.single;
  expect(d.border, Border.all(color: OmColors.accentSoft));
  expect(d.borderRadius, BorderRadius.circular(7.5));
  final fill = _fill(tester, row);
  for (final (got, want, edge) in [
    (rect.left, fill.left - 1, 'left'),
    (rect.top, fill.top - 1, 'top'),
    (rect.right, fill.right + 1, 'right'),
    (rect.bottom, fill.bottom + 1, 'bottom'),
  ]) {
    expect(got, moreOrLessEquals(want, epsilon: 0.01), reason: edge);
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'a focused picker row shows the accentSoft ring only while the focus highlight is on',
    (tester) async {
      wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
      final taps = <Key, int>{};
      await _pump(tester, taps);
      for (final k in [_a, _b, _c]) {
        expect(wi349Rings(tester, find.byKey(k)), isEmpty, reason: 'frame 1');
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi362FocusedRow(), 'row-a', reason: 'Tab reaches the row');
      _expectRing(tester, _a);
      expect(wi349Rings(tester, find.byKey(_b)), isEmpty);

      // A pointer-driven highlight mode: still focused, no ring.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await tester.pump();
      expect(wi362FocusedRow(), 'row-a');
      expect(wi349Rings(tester, find.byKey(_a)), isEmpty);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      _expectRing(tester, _a);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi362FocusedRow(), 'row-b');
      expect(wi349Rings(tester, find.byKey(_a)), isEmpty, reason: 'moved on');
      _expectRing(tester, _b);
      expect(taps, isEmpty, reason: 'focus alone opens nothing');
    },
  );

  testWidgets('a picker row without onTap still takes the focus and the ring', (
    tester,
  ) async {
    wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
    final taps = <Key, int>{};
    await _pump(tester, taps);

    await wi349TabTo(tester, find.byKey(_c));
    expect(wi362FocusedRow(), 'row-c');
    _expectRing(tester, _c);
    await wi349HoldKey(tester, LogicalKeyboardKey.enter);
    expect(taps, isEmpty);
  });

  for (final (name, key) in [
    (
      'a held Enter on a focused picker row opens it once',
      LogicalKeyboardKey.enter,
    ),
    (
      'a held Space on a focused picker row opens it once',
      LogicalKeyboardKey.space,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final taps = <Key, int>{};
      await _pump(tester, taps);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi362FocusedRow(), 'row-a');

      await wi349HoldKey(tester, key, repeats: 5);
      expect(taps, {_a: 1}, reason: 'one press, however long it is held');

      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(taps, {_a: 2}, reason: 'each new press opens again');
    });
  }

  testWidgets('a tap on a picker row opens it once', (tester) async {
    final taps = <Key, int>{};
    await _pump(tester, taps);

    await tester.tap(find.byKey(_a));
    await tester.pump();

    expect(taps, {_a: 1});
  });
}
