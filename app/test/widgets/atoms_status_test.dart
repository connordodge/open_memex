// WI #69 (D12a, board A12 states legend): `StatusDot` and
// `OmButtonKind.danger` in widgets/atoms.dart.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  group('StatusDot (A12 status dot 6px)', () {
    testWidgets('StatusDot connected is a filled accent dot', (tester) async {
      await _pump(tester, const StatusDot(state: StatusDotState.connected));
      final d = _decorationIn(tester, find.byType(StatusDot));
      expect(d.shape, BoxShape.circle);
      expect(d.color, OmColors.accent);
      expect(d.border, isNull);
      expect(d.boxShadow, anyOf(isNull, isEmpty));
      expect(tester.getSize(find.byType(StatusDot)), const Size(6, 6));
    });

    testWidgets('StatusDot cantReach is a warn ring with no fill', (
      tester,
    ) async {
      await _pump(tester, const StatusDot(state: StatusDotState.cantReach));
      final d = _decorationIn(tester, find.byType(StatusDot));
      expect(d.shape, BoxShape.circle);
      expect(d.color, isNull);
      expect(d.border, isA<Border>());
      final border = d.border! as Border;
      expect(border.isUniform, isTrue);
      expect(border.top.color, OmColors.warn);
      expect(border.top.width, 1);
      // Drawn inside the 6 px box.
      expect(border.top.strokeAlign, BorderSide.strokeAlignInside);
      expect(d.boxShadow, anyOf(isNull, isEmpty));
      expect(tester.getSize(find.byType(StatusDot)), const Size(6, 6));
    });

    testWidgets('StatusDot tokenRejected is a filled danger dot', (
      tester,
    ) async {
      await _pump(tester, const StatusDot(state: StatusDotState.tokenRejected));
      final d = _decorationIn(tester, find.byType(StatusDot));
      expect(d.shape, BoxShape.circle);
      expect(d.color, OmColors.danger);
      expect(d.border, isNull);
      expect(tester.getSize(find.byType(StatusDot)), const Size(6, 6));
    });

    testWidgets('StatusDot checking is a filled fg2 dot', (tester) async {
      await _pump(tester, const StatusDot(state: StatusDotState.checking));
      final d = _decorationIn(tester, find.byType(StatusDot));
      expect(d.shape, BoxShape.circle);
      expect(d.color, OmColors.fg2);
      expect(d.border, isNull);
      expect(tester.getSize(find.byType(StatusDot)), const Size(6, 6));
    });

    testWidgets('StatusDot has one look per state and does not animate', (
      tester,
    ) async {
      final seen = <String>{};
      for (final s in StatusDotState.values) {
        await _pump(tester, StatusDot(state: s));
        final d = _decorationIn(tester, find.byType(StatusDot));
        seen.add('${d.color}|${d.border}');
        // No pulse: nothing is scheduled after the first frame.
        expect(tester.hasRunningAnimations, isFalse);
      }
      expect(StatusDotState.values, hasLength(4));
      expect(seen, hasLength(4));
    });
  });

  group('OmButtonKind.danger (A12 buttons)', () {
    testWidgets('a danger OmButton renders the A12 danger styling', (
      tester,
    ) async {
      await _pump(
        tester,
        OmButton(
          kind: OmButtonKind.danger,
          label: 'close anyway',
          onPressed: () {},
        ),
      );
      final button = find.byType(OmButton);
      final d = _decorationIn(tester, button);
      expect(d.color, OmColors.dangerBg);
      final border = d.border! as Border;
      expect(border.isUniform, isTrue);
      expect(border.top.color, OmColors.danger.withAlpha(69));
      expect(border.top.width, 1);
      expect(d.borderRadius, BorderRadius.circular(6));
      final label = tester.widget<Text>(
        find.descendant(of: button, matching: find.text('close anyway')),
      );
      expect(label.style!.color, OmColors.danger);
      expect(tester.getSize(button).height, 30);
    });

    testWidgets('a hovered danger OmButton keeps the danger background', (
      tester,
    ) async {
      await _pump(
        tester,
        OmButton(
          kind: OmButtonKind.danger,
          label: 'quit anyway',
          onPressed: () {},
        ),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(OmButton)));
      await tester.pumpAndSettle();

      final d = _decorationIn(tester, find.byType(OmButton));
      expect(d.color, OmColors.dangerBg);
      expect((d.border! as Border).top.color, OmColors.danger.withAlpha(69));
    });

    testWidgets('a danger OmButton calls onPressed when tapped', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        OmButton(
          kind: OmButtonKind.danger,
          label: 'switch anyway',
          onPressed: () => taps++,
        ),
      );
      await tester.tap(find.byType(OmButton));
      expect(taps, 1);
    });
  });
}
