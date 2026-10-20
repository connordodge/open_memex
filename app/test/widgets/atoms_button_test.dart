// WI #69 (lead decisions on design pack #69, board A12): `OmButton` keeps its
// primary / secondary / ghost / agent styling, dims to 40% when disabled and
// gains a small (24 px) size.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildOmTheme(),
    home: Scaffold(
      body: Center(child: UnconstrainedBox(child: child)),
    ),
  ),
);

BoxDecoration _decorationIn(WidgetTester tester, Finder of) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(of: of, matching: find.byType(DecoratedBox))
                  .first,
            )
            .decoration
        as BoxDecoration;

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

void main() {
  group('OmButton kinds render as before', () {
    // (kind, fill, border colour, label colour) as drawn today.
    final cases = <(String, OmButtonKind, Color, Color, Color)>[
      (
        'a primary OmButton keeps its accent fill and accentFg label',
        OmButtonKind.primary,
        OmColors.accent,
        Colors.transparent,
        OmColors.accentFg,
      ),
      (
        'a secondary OmButton keeps its surface3 fill, line2 border and fg0 label',
        OmButtonKind.secondary,
        OmColors.surface3,
        OmColors.line2,
        OmColors.fg0,
      ),
      (
        'a ghost OmButton keeps no fill, no border and its fg1 label',
        OmButtonKind.ghost,
        Colors.transparent,
        Colors.transparent,
        OmColors.fg1,
      ),
      (
        'an agent OmButton keeps its agentBg fill, agent border and agent label',
        OmButtonKind.agent,
        OmColors.agentBg,
        OmColors.agent.withAlpha(70),
        OmColors.agent,
      ),
    ];
    for (final (name, kind, fill, border, label) in cases) {
      testWidgets(name, (tester) async {
        await _pump(
          tester,
          OmButton(kind: kind, label: 'go', onPressed: () {}),
        );
        final button = find.byType(OmButton);
        final d = _decorationIn(tester, button);
        expect(d.color, fill);
        expect((d.border! as Border).top.color, border);
        expect((d.border! as Border).top.width, 1);
        expect(d.borderRadius, BorderRadius.circular(6));
        final text = tester.widget<Text>(
          find.descendant(of: button, matching: find.text('go')),
        );
        expect(text.style!.color, label);
        expect(text.style!.fontSize, 13);
        expect(tester.getSize(button).height, 30);
        expect(_paintedOpacity(tester, button), 1.0);
      });
    }
  });

  group('OmButton disabled (A12)', () {
    testWidgets('a disabled primary OmButton renders at 40 percent opacity', (
      tester,
    ) async {
      await _pump(
        tester,
        const OmButton(
          kind: OmButtonKind.primary,
          label: 'open',
          onPressed: null,
        ),
      );
      expect(
        _paintedOpacity(tester, find.byType(OmButton)),
        closeTo(0.4, 1e-9),
      );
    });

    testWidgets('a disabled secondary OmButton renders at 40 percent opacity', (
      tester,
    ) async {
      await _pump(
        tester,
        const OmButton(
          kind: OmButtonKind.secondary,
          label: 'open',
          onPressed: null,
        ),
      );
      expect(
        _paintedOpacity(tester, find.byType(OmButton)),
        closeTo(0.4, 1e-9),
      );
    });

    testWidgets(
      'an enabled primary and secondary OmButton render at full opacity',
      (tester) async {
        for (final kind in [OmButtonKind.primary, OmButtonKind.secondary]) {
          await _pump(
            tester,
            OmButton(kind: kind, label: 'open', onPressed: () {}),
          );
          expect(_paintedOpacity(tester, find.byType(OmButton)), 1.0);
        }
      },
    );

    testWidgets(
      'a disabled ghost OmButton also renders at 40 percent opacity',
      (tester) async {
        await _pump(
          tester,
          const OmButton(
            kind: OmButtonKind.ghost,
            icon: LucideIcons.x,
            onPressed: null,
          ),
        );
        expect(
          _paintedOpacity(tester, find.byType(OmButton)),
          closeTo(0.4, 1e-9),
        );
      },
    );

    testWidgets('a button that becomes enabled returns to full opacity', (
      tester,
    ) async {
      await _pump(tester, const OmButton(label: 'retry', onPressed: null));
      expect(
        _paintedOpacity(tester, find.byType(OmButton)),
        closeTo(0.4, 1e-9),
      );
      await _pump(tester, OmButton(label: 'retry', onPressed: () {}));
      await tester.pumpAndSettle();
      expect(_paintedOpacity(tester, find.byType(OmButton)), 1.0);
    });
  });

  group('OmButton small size (A12, 24 px)', () {
    testWidgets(
      'a small OmButton uses a 12 px label, 12 px icon and 10 px horizontal padding',
      (tester) async {
        Future<({double inset, double gap, double iconSize, double label})>
        measure(double size) async {
          await _pump(
            tester,
            OmButton(
              // A fresh button per size: no height animation between them.
              key: ValueKey(size),
              size: size,
              icon: LucideIcons.refreshCw,
              label: 'retry',
              onPressed: () {},
            ),
          );
          final button = find.byType(OmButton);
          final icon = find.byIcon(LucideIcons.refreshCw);
          final text = find.descendant(
            of: button,
            matching: find.text('retry'),
          );
          expect(tester.getSize(button).height, size);
          return (
            inset: tester.getTopLeft(icon).dx - tester.getTopLeft(button).dx,
            gap: tester.getTopLeft(text).dx - tester.getTopRight(icon).dx,
            iconSize: tester.getSize(icon).width,
            label: tester.widget<Text>(text).style!.fontSize!,
          );
        }

        final normal = await measure(30);
        final small = await measure(24);

        // Today's default: 13 px label, 14 px icon, padding 12.
        expect(normal.label, 13);
        expect(normal.iconSize, 14);
        // Small: label 12, icon 12, padding 10 (2 px less than 12, the
        // 1 px border inset is the same for both).
        expect(small.label, 12);
        expect(small.iconSize, 12);
        expect(normal.inset - small.inset, 2);
        // The icon to label gap stays 7.
        expect(normal.gap, 7);
        expect(small.gap, 7);
      },
    );

    testWidgets('a small OmButton has equal left and right padding', (
      tester,
    ) async {
      await _pump(
        tester,
        OmButton(size: 24, label: 'update token', onPressed: () {}),
      );
      final button = find.byType(OmButton);
      final text = find.descendant(
        of: button,
        matching: find.text('update token'),
      );
      final left = tester.getTopLeft(text).dx - tester.getTopLeft(button).dx;
      final right = tester.getTopRight(button).dx - tester.getTopRight(text).dx;
      expect(left, right);
      // Border 1 + padding 10.
      expect(left, 11);
    });
  });

  group('OmButton hover (verify)', () {
    testWidgets(
      'a secondary OmButton takes its hover fill on pointer enter and drops it on exit',
      (tester) async {
        await _pump(
          tester,
          OmButton(
            kind: OmButtonKind.secondary,
            label: 'open',
            onPressed: () {},
          ),
        );
        final button = find.byType(OmButton);
        expect(_decorationIn(tester, button).color, OmColors.surface3);

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(button));
        await tester.pumpAndSettle();
        expect(_decorationIn(tester, button).color, OmColors.surface4);

        await gesture.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_decorationIn(tester, button).color, OmColors.surface3);
      },
    );
  });
}
