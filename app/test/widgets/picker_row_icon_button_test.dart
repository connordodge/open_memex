// WI #349 (Spec #347 req 18, TD7, L5): `PickerRowIconButton` (the recent
// rows' x and the server rows' edit and remove) works from the keyboard.
// Tab reaches it, Enter and Space press it once, a mouse click still
// presses it once with the click cursor and tooltip it had, it reads as a
// button labelled `semanticLabel ?? tooltip`, and it draws an `accentSoft`
// radius-5 focus ring only while the keyboard focus highlight is on.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';

import '../support/font_fetch_hold.dart';
import '../support/wi349_keyboard.dart';

const _aKey = Key('wi349-icon-a');
const _bKey = Key('wi349-icon-b');

/// A press counter for a button's onPressed.
class _Presses {
  int count = 0;
  void call() => count++;
}

/// [children] in a row on a plain screen.
Future<void> _pump(WidgetTester tester, List<Widget> children) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );

/// Two buttons: edit (a) and remove (b), as a server row has them.
Future<(_Presses, _Presses)> _pumpPair(WidgetTester tester) async {
  final a = _Presses();
  final b = _Presses();
  await _pump(tester, [
    PickerRowIconButton(
      key: _aKey,
      icon: LucideIcons.pencil,
      tooltip: 'edit server',
      onPressed: a.call,
    ),
    const SizedBox(width: 10),
    PickerRowIconButton(
      key: _bKey,
      icon: LucideIcons.trash,
      tooltip: 'remove server',
      onPressed: b.call,
    ),
  ]);
  return (a, b);
}

void main() {
  holdFontFetches();

  // ==================================================================== AC6
  group('AC6 keyboard and mouse', () {
    testWidgets('Tab reaches a PickerRowIconButton', (tester) async {
      await _pumpPair(tester);
      expect(wi349FocusIn(find.byKey(_aKey)), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi349FocusIn(find.byKey(_aKey)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(wi349FocusIn(find.byKey(_bKey)), isTrue);
    });

    for (final (name, key) in [
      (
        'Enter on a focused PickerRowIconButton calls onPressed once',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on a focused PickerRowIconButton calls onPressed once',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (a, b) = await _pumpPair(tester);

        await wi349TabTo(tester, find.byKey(_bKey));
        await tester.sendKeyEvent(key);
        await tester.pump();

        expect(b.count, 1);
        expect(a.count, 0, reason: 'only the focused button is pressed');
      });
    }

    testWidgets(
      'a mouse click on a PickerRowIconButton calls onPressed once and draws no ring',
      (tester) async {
        final (a, b) = await _pumpPair(tester);

        await tester.tap(find.byKey(_aKey), kind: PointerDeviceKind.mouse);
        await tester.pump();

        expect(a.count, 1);
        expect(b.count, 0);
        expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
      },
    );

    testWidgets(
      'a PickerRowIconButton keeps the click cursor its tooltip and its 24 by 24 box',
      (tester) async {
        await _pumpPair(tester);

        expect(
          await wi349CursorOver(tester, find.byKey(_aKey)),
          SystemMouseCursors.click,
        );
        final tooltip = tester.widget<Tooltip>(
          find.descendant(
            of: find.byKey(_aKey),
            matching: find.byType(Tooltip),
            matchRoot: true,
          ),
        );
        expect(tooltip.message, 'edit server');
        expect(tester.getSize(find.byKey(_aKey)), const Size(24, 24));
        final icon = tester.widget<Icon>(
          find.descendant(of: find.byKey(_aKey), matching: find.byType(Icon)),
        );
        expect(icon.icon, LucideIcons.pencil);
        expect(icon.size, 12);
      },
    );

    testWidgets(
      'a focused PickerRowIconButton keeps the click cursor and its tooltip',
      (tester) async {
        await _pumpPair(tester);
        await wi349TabTo(tester, find.byKey(_aKey));

        expect(
          await wi349CursorOver(tester, find.byKey(_aKey)),
          SystemMouseCursors.click,
        );
        expect(find.byTooltip('edit server'), findsOneWidget);
        expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
      },
    );
  });

  // ==================================================================== AC7
  group('AC7 semantics', () {
    testWidgets(
      'a PickerRowIconButton reads as a button labelled with its tooltip by default',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpPair(tester);

        for (final (key, label) in [
          (_aKey, 'edit server'),
          (_bKey, 'remove server'),
        ]) {
          final node = wi349NodeLabelled(tester, find.byKey(key), label);
          expect(
            node,
            isSemantics(label: label, isButton: true, hasTapAction: true),
          );
        }
        handle.dispose();
      },
    );

    testWidgets(
      'a PickerRowIconButton reads as its semanticLabel when given while its tooltip stays',
      (tester) async {
        final handle = tester.ensureSemantics();
        final name = ['mem', 'ex'].join();
        await _pump(tester, [
          PickerRowIconButton(
            key: _aKey,
            icon: LucideIcons.trash2,
            tooltip: 'delete vault',
            semanticLabel: 'delete vault $name',
            onPressed: () {},
          ),
        ]);

        final node = wi349NodeLabelled(
          tester,
          find.byKey(_aKey),
          'delete vault memex',
        );
        expect(
          node,
          isSemantics(
            label: 'delete vault memex',
            isButton: true,
            hasTapAction: true,
          ),
        );
        expect(find.byTooltip('delete vault'), findsOneWidget);
        expect(find.byTooltip('delete vault memex'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'the semantic tap on a PickerRowIconButton calls onPressed once',
      (tester) async {
        final handle = tester.ensureSemantics();
        final (a, b) = await _pumpPair(tester);

        final node = wi349NodeLabelled(
          tester,
          find.byKey(_bKey),
          'remove server',
        );
        await wi349SemanticTap(tester, node);

        expect(b.count, 1);
        expect(a.count, 0);
        handle.dispose();
      },
    );
  });

  // ==================================================================== AC8
  group('AC8 focus ring', () {
    testWidgets(
      'a PickerRowIconButton shows the accentSoft radius 5 ring only while it has the keyboard focus highlight',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        await _pumpPair(tester);
        expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
        expect(wi349Rings(tester, find.byKey(_bKey)), isEmpty);

        await wi349TabTo(tester, find.byKey(_aKey));
        final rings = wi349Rings(tester, find.byKey(_aKey));
        expect(rings, hasLength(1), reason: 'the focused button has a ring');
        expect(rings.single.$1.borderRadius, BorderRadius.circular(5));
        expect(
          rings.single.$2,
          tester.getRect(find.byKey(_aKey)),
          reason: 'the ring is drawn on the 24 by 24 button',
        );
        expect(wi349Rings(tester, find.byKey(_bKey)), isEmpty);

        await wi349TabTo(tester, find.byKey(_bKey));
        expect(
          wi349Rings(tester, find.byKey(_aKey)),
          isEmpty,
          reason: 'the ring leaves with the focus',
        );
        expect(wi349Rings(tester, find.byKey(_bKey)), hasLength(1));

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTouch;
        await tester.pump();
        expect(wi349FocusIn(find.byKey(_bKey)), isTrue);
        expect(
          wi349Rings(tester, find.byKey(_bKey)),
          isEmpty,
          reason: 'no ring once the focus highlight is off',
        );
      },
    );

    testWidgets('a PickerRowIconButton draws no ring on its first frame', (
      tester,
    ) async {
      wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
      await _pumpPair(tester);
      expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);

      await tester.pump();
      expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
      await wi349TabTo(tester, find.byKey(_aKey));
      expect(wi349Rings(tester, find.byKey(_aKey)), hasLength(1));
    });

    testWidgets(
      'a focused PickerRowIconButton shows no ring while the focus highlight is off',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTouch);
        await _pumpPair(tester);

        await wi349TabTo(tester, find.byKey(_aKey));

        expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
        expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
      },
    );
  });
}
