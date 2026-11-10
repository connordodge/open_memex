// WI #362 (Spec #357 Req 13): the disabled state of `PickerRowIconButton`
// (remove server on the open hosted vault's server). Disabled means: drawn
// at 40% opacity, never focused by Tab, never pressed, read as one disabled
// button labelled `semanticLabel ?? tooltip`, and the tooltip (the reason)
// still shows on hover. The glyph size follows `iconSize` (default 12), and
// no tooltip shows when `tooltip` is null. Bare buttons in a MaterialApp.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/wi349_keyboard.dart';

const _first = Key('wi362-icon-first');
const _disabled = Key('wi362-icon-disabled');
const _last = Key('wi362-icon-last');

Future<void> _pump(
  WidgetTester tester, {
  String? tooltip = 'switch to another vault first.',
  String? semanticLabel,
  double? iconSize,
  List<String>? presses,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PickerRowIconButton(
              key: _first,
              icon: LucideIcons.pencil,
              tooltip: 'first',
              onPressed: () => presses?.add('first'),
            ),
            PickerRowIconButton(
              key: _disabled,
              icon: LucideIcons.trash,
              tooltip: tooltip,
              semanticLabel: semanticLabel,
              iconSize: iconSize ?? 12,
              onPressed: null,
            ),
            PickerRowIconButton(
              key: _last,
              icon: LucideIcons.trash,
              tooltip: 'last',
              onPressed: () => presses?.add('last'),
            ),
          ],
        ),
      ),
    ),
  ),
);

double _opacityOf(WidgetTester tester, Key key) {
  final opacities = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Opacity),
  );
  return opacities.evaluate().isEmpty
      ? 1
      : tester.widget<Opacity>(opacities.first).opacity;
}

void main() {
  holdFontFetches();

  testWidgets('a disabled icon button is drawn at 40 percent opacity', (
    tester,
  ) async {
    await _pump(tester);

    expect(_opacityOf(tester, _disabled), 0.4);
    expect(_opacityOf(tester, _first), 1, reason: 'an enabled one is not');
  });

  testWidgets('Tab skips a disabled icon button and a press does nothing', (
    tester,
  ) async {
    final presses = <String>[];
    await _pump(tester, presses: presses);

    await wi349TabTo(tester, find.byKey(_first));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(wi349FocusIn(find.byKey(_disabled)), isFalse);
    expect(wi349FocusIn(find.byKey(_last)), isTrue, reason: 'jumps past it');

    await tester.tap(find.byKey(_disabled), warnIfMissed: false);
    await tester.pump();
    expect(presses, isEmpty);
  });

  testWidgets('a disabled icon button reads as one disabled labelled button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, semanticLabel: 'remove server');

    final node = wi349NodeLabelled(
      tester,
      find.byKey(_disabled),
      'remove server',
    );
    expect(
      node,
      isSemantics(
        label: 'remove server',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets(
    'a disabled icon button is one leaf semantics node with no child nodes',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, semanticLabel: 'remove server');

      final node = wi349NodeLabelled(
        tester,
        find.byKey(_disabled),
        'remove server',
      );
      expect(
        node.childrenCount,
        0,
        reason: 'the glyph adds no node of its own',
      );
      expect(node, isSemantics(label: 'remove server', hasTapAction: false));
      handle.dispose();
    },
  );

  testWidgets(
    'an enabled icon button is one tappable leaf semantics node with no child nodes',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      final node = wi349NodeLabelled(tester, find.byKey(_first), 'first');
      expect(
        node,
        isSemantics(label: 'first', isButton: true, hasTapAction: true),
      );
      expect(
        node.childrenCount,
        0,
        reason: 'the glyph adds no node of its own',
      );
      handle.dispose();
    },
  );

  testWidgets(
    'a disabled icon button without a semanticLabel reads its tooltip',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      final node = wi349NodeLabelled(
        tester,
        find.byKey(_disabled),
        'switch to another vault first.',
      );
      expect(node, isSemantics(isButton: true, isEnabled: false));
      handle.dispose();
    },
  );

  testWidgets('a disabled icon button still shows its tooltip on hover', (
    tester,
  ) async {
    await _pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byKey(_disabled)));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(_disabled)));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('switch to another vault first.'), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('an icon button with no tooltip shows none', (tester) async {
    await _pump(tester, tooltip: null, semanticLabel: 'remove server');

    expect(
      find.descendant(
        of: find.byKey(_disabled),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
  });

  testWidgets('the glyph is 12 by default and follows iconSize', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(_disabled),
              matching: find.byType(Icon),
            ),
          )
          .size,
      12,
    );

    await _pump(tester, iconSize: 16);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(_disabled),
              matching: find.byType(Icon),
            ),
          )
          .size,
      16,
    );
    expect(tester.getSize(find.byKey(_disabled)), const Size(24, 24));
  });
}
