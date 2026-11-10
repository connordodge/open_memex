// WI #362 (pack 97 "Row chrome"): a `PickerRowShell` fills `surface2` at
// rest and `surface3` while a mouse hovers it, and only when the row can be
// tapped (a server row, which has no onTap, never lights up). The fill
// returns to rest when the pointer leaves. Bare shells in a MaterialApp; the
// probes read the fill drawn and drive a real mouse pointer.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';

import '../../support/font_fetch_hold.dart';

const _tappable = Key('wi362-hover-tappable');
const _plain = Key('wi362-hover-plain');

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: OmColors.surface1,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PickerRowShell(
                  key: _tappable,
                  onTap: () {},
                  child: const Text('tappable'),
                ),
                const SizedBox(height: 20),
                const PickerRowShell(key: _plain, child: Text('plain')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The colour of the row's rounded fill (surface2 or surface3).
Color? _fill(WidgetTester tester, Key row) {
  final fills = [
    for (final e
        in find
            .descendant(
              of: find.byKey(row),
              matching: find.byType(Container),
              matchRoot: true,
            )
            .evaluate())
      if (((e.widget as Container).decoration) case final BoxDecoration d
          when d.color == OmColors.surface2 || d.color == OmColors.surface3)
        d.color,
  ];
  expect(fills, hasLength(1), reason: 'one fill on $row');
  return fills.single;
}

void main() {
  holdFontFetches();

  testWidgets('a row fills surface2 at rest with no pointer over it', (
    tester,
  ) async {
    await _pump(tester);

    expect(_fill(tester, _tappable), OmColors.surface2);
    expect(_fill(tester, _plain), OmColors.surface2);
  });

  testWidgets(
    'a tappable row fills surface3 under the mouse and surface2 once it leaves',
    (tester) async {
      await _pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(700, 500));
      await tester.pump();
      expect(_fill(tester, _tappable), OmColors.surface2, reason: 'away');

      await mouse.moveTo(tester.getCenter(find.byKey(_tappable)));
      await tester.pump();
      expect(_fill(tester, _tappable), OmColors.surface3, reason: 'hovered');
      expect(_fill(tester, _plain), OmColors.surface2, reason: 'only that row');

      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(_fill(tester, _tappable), OmColors.surface2, reason: 'left');
    },
  );

  testWidgets('a row with no onTap keeps surface2 under the mouse', (
    tester,
  ) async {
    await _pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(_plain)));
    await tester.pump();

    expect(_fill(tester, _plain), OmColors.surface2, reason: 'under the mouse');
    await mouse.moveTo(tester.getCenter(find.byKey(_tappable)));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(_plain)));
    await tester.pump();
    expect(_fill(tester, _plain), OmColors.surface2, reason: 'after a visit');
    expect(_fill(tester, _tappable), OmColors.surface2, reason: 'moved off');
  });
}
