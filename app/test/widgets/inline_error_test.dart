// WI #405 (Spec #394 req 14, ruling D8, design pack 405): `InlineError`
// gains an optional `onRetry`.
//
// - With `onRetry`: a ghost, dense, 22 px `Retry` text button (Key
//   `inline-error-retry`, no icon) sits between the message and the dismiss
//   button, 2 px before it. One click or one Enter / Space key down calls
//   `onRetry` once and never `onDismiss`; it is a Tab stop announced as a
//   button labelled `Retry`; a held key does not run it again.
// - Without `onRetry`: the widget is drawn as on main. The numbers below
//   (box, dismiss rect, row children) were measured on main for a 400 px
//   wide slot under the test fallback font.
// - Dismiss runs `onDismiss` once, with and without `onRetry`.
//
// There is no board panel for the error row (pack 405), so nothing here is a
// golden against the board.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/inline_error.dart';

import '../support/font_fetch_hold.dart';
import '../support/wi349_keyboard.dart';

const _box = Key('inline-error');
const _retry = Key('inline-error-retry');
const _dismiss = Key('inline-error-dismiss');

const _short = 'read failed';
const _long = 'agent list failed: connection refused';

/// A press counter.
class _Calls {
  int count = 0;
  void call() => count++;
}

/// An [InlineError] in a 400 px wide slot at the top left of a plain screen.
Future<void> _pump(
  WidgetTester tester, {
  String message = _short,
  VoidCallback? onRetry,
  VoidCallback? onDismiss,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildOmTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          child: InlineError(
            message: message,
            onRetry: onRetry,
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    ),
  ),
);

Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
}

/// The children of the row inside the error box.
List<Widget> _rowChildren(WidgetTester tester) => tester
    .widget<Row>(
      find.descendant(of: find.byKey(_box), matching: find.byType(Row)).first,
    )
    .children;

/// The button's fill: the background decoration the size of [target].
Color? _fill(WidgetTester tester, Finder target) {
  final size = tester.getSize(target);
  for (final e
      in find
          .descendant(
            of: target,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .evaluate()) {
    final w = e.widget as DecoratedBox;
    if (w.position != DecorationPosition.background) continue;
    final d = w.decoration;
    if (d is! BoxDecoration) continue;
    if ((e.renderObject! as RenderBox).size != size) continue;
    return d.color;
  }
  fail('no background decoration the size of $target');
}

BoxDecoration _boxDecoration(WidgetTester tester) =>
    tester.widget<Container>(find.byKey(_box)).decoration! as BoxDecoration;

void main() {
  holdFontFetches();

  // ==================================================================== AC1
  group('AC1 a Retry button is shown when onRetry is given', () {
    testWidgets('an InlineError with onRetry shows a button labelled Retry', (
      tester,
    ) async {
      await _pump(tester, onRetry: () {});
      expect(find.byKey(_retry), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(_retry), matching: find.text('Retry')),
        findsOneWidget,
      );
      expect(find.byType(OmButton), findsNWidgets(2));
    });

    testWidgets(
      'the Retry button is a ghost text button with a 12 px w500 fg1 label and no icon',
      (tester) async {
        await _pump(tester, onRetry: () {});
        final retry = find.byKey(_retry);
        final button = tester.widget<OmButton>(retry);
        expect(button.kind, OmButtonKind.ghost);
        expect(button.dense, isTrue);
        expect(button.size, 22);
        expect(button.label, 'Retry');
        expect(button.icon, isNull);
        final text = tester.widget<Text>(
          find.descendant(of: retry, matching: find.text('Retry')),
        );
        expect(text.style!.fontSize, 12);
        expect(text.style!.fontWeight, FontWeight.w500);
        expect(text.style!.color, OmColors.fg1);
        expect(
          find.descendant(of: retry, matching: find.byType(Icon)),
          findsNothing,
        );
        expect(tester.getSize(retry).height, 22);
        expect(_fill(tester, retry), Colors.transparent);
      },
    );

    testWidgets(
      'a mouse over the Retry button fills it surface3 and leaving clears it',
      (tester) async {
        await _pump(tester, onRetry: () {});
        final retry = find.byKey(_retry);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(_fill(tester, retry), Colors.transparent);
        await mouse.moveTo(tester.getCenter(retry));
        await tester.pumpAndSettle();
        expect(_fill(tester, retry), OmColors.surface3);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_fill(tester, retry), Colors.transparent);
      },
    );

    testWidgets(
      'the row is the message, Retry, a 2 px gap and dismiss, in that order',
      (tester) async {
        await _pump(tester, onRetry: () {});
        final children = _rowChildren(tester);
        expect(children, hasLength(4));
        expect(children[0], isA<Expanded>());
        expect((children[1] as OmButton).key, _retry);
        expect(children[2], isA<SizedBox>());
        expect((children[2] as SizedBox).width, 2);
        expect((children[3] as OmButton).key, _dismiss);
      },
    );

    testWidgets(
      'Retry sits 2 px before dismiss, level with it, and the message ends where Retry starts',
      (tester) async {
        await _pump(tester, onRetry: () {});
        final retry = tester.getRect(find.byKey(_retry));
        final dismiss = tester.getRect(find.byKey(_dismiss));
        final message = tester.getRect(find.text(_short));
        expect(dismiss.left - retry.right, 2);
        expect(retry.top, dismiss.top);
        expect(retry.bottom, dismiss.bottom);
        expect(message.right, retry.left);
        expect(retry.width, greaterThan(22));
      },
    );

    testWidgets(
      'dismiss keeps its size and its place at the right edge when Retry is added',
      (tester) async {
        await _pump(tester, onRetry: () {});
        expect(find.byKey(_retry), findsOneWidget);
        expect(
          tester.getRect(find.byKey(_dismiss)),
          const Rect.fromLTRB(374, 4, 396, 26),
        );
        expect(tester.getSize(find.byKey(_box)), const Size(400, 38));
      },
    );

    testWidgets(
      'the error box, message style and dismiss button are the same with onRetry',
      (tester) async {
        await _pump(tester, onRetry: () {});
        expect(find.byKey(_retry), findsOneWidget);
        final c = tester.widget<Container>(find.byKey(_box));
        expect(c.margin, const EdgeInsets.only(bottom: 8));
        expect(c.padding, const EdgeInsets.fromLTRB(12, 4, 4, 4));
        final d = _boxDecoration(tester);
        expect(d.color, OmColors.dangerBg);
        expect(d.borderRadius, BorderRadius.circular(4));
        final text = tester.widget<Text>(find.text(_short));
        expect(text.style!.fontSize, 11);
        expect(text.style!.color, OmColors.danger);
        final dismiss = tester.widget<OmButton>(find.byKey(_dismiss));
        expect(dismiss.kind, OmButtonKind.ghost);
        expect(dismiss.size, 22);
        expect(dismiss.tooltip, 'dismiss');
        expect(dismiss.focusable, isFalse);
      },
    );
  });

  // ==================================================================== AC2
  group('AC2 one tap on Retry runs onRetry once', () {
    testWidgets('a tap on Retry calls onRetry once and onDismiss never', (
      tester,
    ) async {
      final retry = _Calls();
      final dismiss = _Calls();
      await _pump(tester, onRetry: retry.call, onDismiss: dismiss.call);
      await tester.tap(find.byKey(_retry));
      await tester.pumpAndSettle();
      expect(retry.count, 1);
      expect(dismiss.count, 0);
    });

    testWidgets(
      'a second tap on Retry calls onRetry again, with no busy guard',
      (tester) async {
        final retry = _Calls();
        await _pump(tester, onRetry: retry.call);
        await tester.tap(find.byKey(_retry));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_retry));
        await tester.pumpAndSettle();
        expect(retry.count, 2);
      },
    );
  });

  // ==================================================================== AC3
  group('AC3 without onRetry the widget is as on main', () {
    testWidgets('an InlineError without onRetry has no Retry button', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(_retry), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(OmButton), findsOneWidget);
      expect(find.byKey(_dismiss), findsOneWidget);
    });

    testWidgets(
      'an InlineError without onRetry has the same box and dismiss rect as on main',
      (tester) async {
        await _pump(tester);
        expect(
          tester.getRect(find.byKey(_box)),
          const Rect.fromLTRB(0, 0, 400, 38),
        );
        expect(
          tester.getRect(find.byKey(_dismiss)),
          const Rect.fromLTRB(374, 4, 396, 26),
        );
        expect(
          tester.getRect(find.text(_short)),
          const Rect.fromLTRB(12, 6.5, 374, 23.5),
        );
      },
    );

    testWidgets(
      'a long message without onRetry wraps in the same box and keeps dismiss centred, as on main',
      (tester) async {
        await _pump(tester, message: _long);
        expect(
          tester.getRect(find.byKey(_box)),
          const Rect.fromLTRB(0, 0, 400, 50),
        );
        expect(
          tester.getRect(find.byKey(_dismiss)),
          const Rect.fromLTRB(374, 10, 396, 32),
        );
        expect(
          tester.getRect(find.text(_long)),
          const Rect.fromLTRB(12, 4, 374, 38),
        );
      },
    );

    testWidgets(
      'the row without onRetry is the message and dismiss only, with no gap',
      (tester) async {
        await _pump(tester);
        final children = _rowChildren(tester);
        expect(children, hasLength(2));
        expect(children[0], isA<Expanded>());
        expect((children[1] as OmButton).key, _dismiss);
      },
    );

    testWidgets(
      'the error box, message style and dismiss button are as on main without onRetry',
      (tester) async {
        await _pump(tester);
        final c = tester.widget<Container>(find.byKey(_box));
        expect(c.margin, const EdgeInsets.only(bottom: 8));
        expect(c.padding, const EdgeInsets.fromLTRB(12, 4, 4, 4));
        final d = _boxDecoration(tester);
        expect(d.color, OmColors.dangerBg);
        expect(d.borderRadius, BorderRadius.circular(4));
        final text = tester.widget<Text>(find.text(_short));
        expect(text.style!.fontSize, 11);
        expect(text.style!.color, OmColors.danger);
        final dismiss = tester.widget<OmButton>(find.byKey(_dismiss));
        expect(dismiss.kind, OmButtonKind.ghost);
        expect(dismiss.size, 22);
        expect(dismiss.tooltip, 'dismiss');
        expect(dismiss.focusable, isFalse);
      },
    );

    testWidgets(
      'Tab skips the dismiss button of an InlineError without onRetry',
      (tester) async {
        await _pump(tester);
        await _tab(tester);
        expect(wi349FocusIn(find.byKey(_dismiss)), isFalse);
        expect(wi349FocusIn(find.byKey(_box)), isFalse);
      },
    );

    testWidgets(
      'Retry appears when onRetry is given later and goes when it is withdrawn',
      (tester) async {
        await _pump(tester);
        expect(find.byKey(_retry), findsNothing);
        await _pump(tester, onRetry: () {});
        expect(find.byKey(_retry), findsOneWidget);
        expect(find.byKey(_dismiss), findsOneWidget);
        await _pump(tester);
        expect(find.byKey(_retry), findsNothing);
        expect(
          tester.getRect(find.byKey(_dismiss)),
          const Rect.fromLTRB(374, 4, 396, 26),
        );
      },
    );
  });

  // ==================================================================== AC4
  group('AC4 dismiss runs onDismiss once', () {
    testWidgets('a tap on dismiss calls onDismiss once without onRetry', (
      tester,
    ) async {
      final dismiss = _Calls();
      await _pump(tester, onDismiss: dismiss.call);
      await tester.tap(find.byKey(_dismiss));
      await tester.pumpAndSettle();
      expect(dismiss.count, 1);
    });

    testWidgets(
      'a tap on dismiss calls onDismiss once and onRetry never with onRetry',
      (tester) async {
        final retry = _Calls();
        final dismiss = _Calls();
        await _pump(tester, onRetry: retry.call, onDismiss: dismiss.call);
        expect(find.byKey(_retry), findsOneWidget);
        await tester.tap(find.byKey(_dismiss));
        await tester.pumpAndSettle();
        expect(dismiss.count, 1);
        expect(retry.count, 0);
      },
    );

    testWidgets('a tap on the gap between Retry and dismiss calls neither', (
      tester,
    ) async {
      final retry = _Calls();
      final dismiss = _Calls();
      await _pump(tester, onRetry: retry.call, onDismiss: dismiss.call);
      final gap =
          tester.getRect(find.byKey(_retry)).centerRight + const Offset(1, 0);
      await tester.tapAt(gap);
      await tester.pumpAndSettle();
      expect(retry.count, 0);
      expect(dismiss.count, 0);
    });
  });

  // ==================================================================== AC5
  group('AC5 Retry is a focusable button', () {
    testWidgets('Retry is announced as a button labelled Retry', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, onRetry: () {});
      final node = wi349NodeLabelled(tester, find.byKey(_retry), 'Retry');
      expect(
        node,
        isSemantics(
          label: 'Retry',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      expect(node.childrenCount, 0, reason: 'a leaf: the label is not doubled');
      handle.dispose();
    });

    testWidgets('a semantic tap on Retry calls onRetry once', (tester) async {
      final handle = tester.ensureSemantics();
      final retry = _Calls();
      await _pump(tester, onRetry: retry.call);
      await wi349SemanticTap(
        tester,
        wi349NodeLabelled(tester, find.byKey(_retry), 'Retry'),
      );
      expect(retry.count, 1);
      handle.dispose();
    });

    testWidgets('Tab reaches the Retry button and it takes focus', (
      tester,
    ) async {
      await _pump(tester, onRetry: () {});
      expect(wi349FocusIn(find.byKey(_retry)), isFalse);
      await wi349TabTo(tester, find.byKey(_retry), max: 3);
      expect(wi349FocusIn(find.byKey(_retry)), isTrue);
    });

    testWidgets(
      'a Retry button with keyboard focus is filled surface4 and ringed inside its box',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        await _pump(tester, onRetry: () {});
        await wi349TabTo(tester, find.byKey(_retry), max: 3);
        await tester.pumpAndSettle();
        final retry = find.byKey(_retry);
        expect(_fill(tester, retry), OmColors.surface4);
        final ring = find
            .descendant(
              of: retry,
              matching: find.byType(DecoratedBox),
              matchRoot: true,
            )
            .evaluate()
            .map((e) => e.widget as DecoratedBox)
            .where((w) => w.position == DecorationPosition.foreground)
            .map((w) => w.decoration as BoxDecoration)
            .where((d) => d.border != null)
            .toList();
        expect(ring, hasLength(1));
        final b = ring.single.border! as Border;
        expect(b.top.color, OmColors.accent);
        expect(b.top.width, 2);
        expect(b.top.strokeAlign, BorderSide.strokeAlignInside);
      },
    );

    for (final (name, key) in [
      (
        'Enter on the focused Retry button calls onRetry once and onDismiss never',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on the focused Retry button calls onRetry once and onDismiss never',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final retry = _Calls();
        final dismiss = _Calls();
        await _pump(tester, onRetry: retry.call, onDismiss: dismiss.call);
        await wi349TabTo(tester, find.byKey(_retry), max: 3);
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(retry.count, 1);
        expect(dismiss.count, 0);
      });
    }

    testWidgets(
      'a held Enter on the focused Retry button runs onRetry once, not on each repeat',
      (tester) async {
        final retry = _Calls();
        await _pump(tester, onRetry: retry.call);
        await wi349TabTo(tester, find.byKey(_retry), max: 3);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(retry.count, 1);
      },
    );

    testWidgets(
      'a held Space on the focused Retry button runs onRetry once, not on each repeat',
      (tester) async {
        final retry = _Calls();
        await _pump(tester, onRetry: retry.call);
        await wi349TabTo(tester, find.byKey(_retry), max: 3);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(retry.count, 1);
      },
    );
  });
}
