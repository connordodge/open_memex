// WI #82 (Spec #61 F2; Reqs 12-13, 19-20, 31-34; rulings D12, D14): the Find
// bar's finer contracts that find_bar_test.dart does not pin: the paste
// rewrite (line breaks as spaces, over a selection, mid-query, empty
// clipboard), a mouse click on the bar keeping focus where it was, the
// field's caret and selection look, the tooltip's look and place, the mouse
// cursor, text scaling the counter slot, and the buttons' semantic tap
// action.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import 'find_bar_harness.dart';

/// A RichText anywhere on screen whose plain text, no-break spaces read as
/// spaces, is [text].
Finder _wi82TipText(String text) => find.byWidgetPredicate(
  (w) =>
      w is RichText &&
      w.text.toPlainText().replaceAll('\u00A0', ' ').trim() == text,
  description: 'text "$text"',
);

/// Pastes [clipboard] over [selection] of a field seeded with [query] and
/// returns the rig.
Future<Wi82Rig> _wi82Paste(
  WidgetTester tester, {
  required String? clipboard,
  String query = 'hydration',
  TextSelection? selection,
}) async {
  MacClipboard.install(tester, initial: clipboard);
  final rig = await wi82Pump(tester, query: query);
  await wi82FocusField(tester);
  if (selection != null) {
    wi82Editable(tester).controller.selection = selection;
    await tester.pump();
  }
  await tester.macCmdChord(LogicalKeyboardKey.keyV);
  await tester.pump();
  return rig;
}

void main() {
  holdFontFetches();
  wi82LoadFonts();

  group('paste', () {
    final breaks = <(String, String, String)>[
      (
        'pasting a CRLF break into the field makes it one space',
        'a\r\nb',
        'a b',
      ),
      (
        'pasting a lone CR break into the field makes it one space',
        'a\rb',
        'a b',
      ),
      (
        'pasting a lone LF break into the field makes it one space',
        'a\nb',
        'a b',
      ),
      (
        'pasting a trailing line break into the field keeps it as a space',
        'ab\n',
        'ab ',
      ),
      (
        'pasting three breaks into the field makes three spaces',
        'a\n\r\n\rb',
        'a   b',
      ),
    ];
    for (final (name, clip, expected) in breaks) {
      testWidgets(name, (tester) async {
        final rig = await _wi82Paste(tester, clipboard: clip, query: '');
        expect(rig.find.state.query, expected);
        expect(wi82Editable(tester).controller.text, expected);
      }, variant: macOnly);
    }

    testWidgets(
      'pasting over a selection replaces just the selection and puts the caret after the pasted text',
      (tester) async {
        final rig = await _wi82Paste(
          tester,
          clipboard: 'XY',
          selection: const TextSelection(baseOffset: 2, extentOffset: 5),
        );
        expect(rig.find.state.query, 'hyXYtion');
        expect(wi82Editable(tester).controller.text, 'hyXYtion');
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection.collapsed(offset: 4),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'pasting at a caret in the middle inserts there and puts the caret after the pasted text',
      (tester) async {
        final rig = await _wi82Paste(
          tester,
          clipboard: 'a\nb',
          selection: const TextSelection.collapsed(offset: 3),
        );
        expect(rig.find.state.query, 'hyda bration');
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection.collapsed(offset: 6),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'pasting at a caret at the end appends and puts the caret at the new end',
      (tester) async {
        final rig = await _wi82Paste(
          tester,
          clipboard: 'Z',
          query: 'abc',
          selection: const TextSelection.collapsed(offset: 3),
        );
        expect(rig.find.state.query, 'abcZ');
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection.collapsed(offset: 4),
        );
      },
      variant: macOnly,
    );

    testWidgets('pasting an empty clipboard over a selection changes nothing', (
      tester,
    ) async {
      final rig = await _wi82Paste(
        tester,
        clipboard: '',
        selection: const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      expect(rig.find.state.query, 'hydration');
      expect(wi82Editable(tester).controller.text, 'hydration');
      expect(
        wi82Editable(tester).controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
    }, variant: macOnly);

    testWidgets('pasting with nothing on the clipboard changes nothing', (
      tester,
    ) async {
      final rig = await _wi82Paste(
        tester,
        clipboard: null,
        selection: const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      expect(rig.find.state.query, 'hydration');
      expect(wi82Editable(tester).controller.text, 'hydration');
    }, variant: macOnly);
  });

  group('the context menu', () {
    /// Right-clicks 45 px into the field (on its first letters) and returns
    /// the open menu's item finder for [label].
    Future<Finder> openMenu(WidgetTester tester, String label) async {
      final g = await tester.startGesture(
        tester.getTopLeft(wi82Field) + const Offset(45, 15),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();
      return find.text(label);
    }

    testWidgets(
      'right-click Paste of two lines sets the query two lines and closes the menu',
      (tester) async {
        MacClipboard.install(tester, initial: 'two\nlines');
        final rig = await wi82Pump(tester, query: '');
        await wi82FocusField(tester);
        final paste = await openMenu(tester, 'Paste');
        expect(paste, findsOneWidget);
        await tester.tap(paste, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(rig.find.state.query, 'two lines');
        expect(wi82Editable(tester).controller.text, 'two lines');
        expect(find.text('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'right-click Paste over a selection replaces just the selection with a CRLF break as one space',
      (tester) async {
        MacClipboard.install(tester, initial: 'a\r\nb');
        final rig = await wi82Pump(tester, query: 'hydration');
        await wi82FocusField(tester);
        wi82Editable(tester).controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        final paste = await openMenu(tester, 'Paste');
        await tester.tap(paste, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(rig.find.state.query, 'a btion');
        expect(wi82Editable(tester).controller.text, 'a btion');
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection.collapsed(offset: 3),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the other menu items stay: Copy puts the selected letters on the clipboard and does not paste',
      (tester) async {
        final clip = MacClipboard.install(tester, initial: 'two\nlines');
        final rig = await wi82Pump(tester, query: 'hydration');
        await wi82FocusField(tester);
        wi82Editable(tester).controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        final copy = await openMenu(tester, 'Copy');
        expect(copy, findsOneWidget);
        await tester.tap(copy, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(clip.writes, ['hydra']);
        expect(rig.find.state.query, 'hydration');
        expect(wi82Editable(tester).controller.text, 'hydration');
      },
      variant: macOnly,
    );
  });

  group('a mouse click on the bar', () {
    testWidgets(
      'a mouse click on the down button keeps focus in the find field',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);

        await tester.tap(wi82Next, kind: PointerDeviceKind.mouse);
        await tester.pump();

        expect(rig.find.state.current, 3);
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);
      },
      variant: macOnly,
    );

    testWidgets(
      'a mouse click on the bar chrome keeps focus in the find field',
      (tester) async {
        await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);

        final box = tester.getRect(wi82Box);
        await tester.tapAt(
          Offset(box.left + 3, box.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);
      },
      variant: macOnly,
    );

    testWidgets(
      'a mouse click on the up button keeps focus in the editor field',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusEditor(tester, rig);
        expect(wi82EditorEditable(tester).focusNode.hasFocus, isTrue);

        await tester.tap(wi82Previous, kind: PointerDeviceKind.mouse);
        await tester.pump();

        expect(rig.find.state.current, 1);
        expect(wi82EditorEditable(tester).focusNode.hasFocus, isTrue);
        expect(rig.editor.selection, wi82EditorSelection);
      },
      variant: macOnly,
    );

    testWidgets(
      'a mouse click outside the bar still takes focus out of the find field',
      (tester) async {
        await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);

        final host = wi82Host(tester);
        await tester.tapAt(
          Offset(host.center.dx, host.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        expect(wi82Editable(tester).focusNode.hasFocus, isFalse);
      },
      variant: macOnly,
    );
  });

  group('the field look', () {
    testWidgets(
      'the caret is a 2 by 14 accent bar and the selection fills with the selection colour',
      (tester) async {
        await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);
        final field = wi82Editable(tester);
        expect(field.cursorColor, OmColors.accent);
        expect(field.cursorWidth, 2);
        expect(field.cursorHeight, 14);
        expect(field.selectionColor, OmColors.selection);
        expect(field.maxLines, 1);
        expect(field.style.fontSize, 12);
      },
      variant: macOnly,
    );
  });

  group('tooltips', () {
    final tips = <(String, Finder Function())>[
      ('up', () => wi82Previous),
      ('down', () => wi82Next),
      ('close', () => wi82Close),
    ];
    for (final (which, button) in tips) {
      testWidgets(
        'the $which button tooltip is a surface4 box with a line2 border, 4 px corners, 7 px side padding, 22 px tall at least, 6 px below the box',
        (tester) async {
          await wi82Pump(tester, current: 2);
          final tooltip = tester.widget<Tooltip>(
            find.descendant(of: button(), matching: find.byType(Tooltip)),
          );
          final decoration = tooltip.decoration! as BoxDecoration;
          expect(decoration.color, OmColors.surface4);
          expect(decoration.border, Border.all(color: OmColors.line2));
          expect(decoration.borderRadius, BorderRadius.circular(4));
          expect(tooltip.padding, const EdgeInsets.symmetric(horizontal: 7));
          expect(tooltip.constraints, const BoxConstraints(minHeight: 22));
          expect(tooltip.verticalOffset, 25);
          expect(tooltip.preferBelow, isTrue);
        },
        variant: macOnly,
      );
    }

    testWidgets(
      'the down button tooltip shows 6 px below the box, shortcut in mono fg2 after the label in fg0',
      (tester) async {
        await wi82Pump(tester, current: 2);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: wi82Host(tester).center);
        addTearDown(mouse.removePointer);
        await tester.pump();
        await mouse.moveTo(tester.getCenter(wi82Next));
        await wi82Settle(tester);

        final tip = _wi82TipText('Next match ⌘G');
        expect(tip, findsOneWidget);
        final rich = tester.widget<RichText>(tip);
        final spans = <TextSpan>[];
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) spans.add(span);
          return true;
        });
        expect(spans.first.text, 'Next match');
        expect(spans.first.style?.color, OmColors.fg0);
        expect(spans.last.text, '\u00A0⌘G');
        expect(spans.last.style?.color, OmColors.fg2);
        expect(spans.last.style?.fontSize, 11);

        final box = tester.getRect(wi82Box);
        final bubble = tester.getRect(
          find.ancestor(of: tip, matching: find.byType(ConstrainedBox)).first,
        );
        expect(bubble.top, moreOrLessEquals(box.bottom + 6, epsilon: 0.5));
        expect(bubble.height, greaterThanOrEqualTo(22));

        await mouse.moveTo(wi82Host(tester).center);
        await wi82Settle(tester);
        await wi82Settle(tester);
      },
      variant: macOnly,
    );
  });

  group('mouse cursor', () {
    testWidgets('an enabled button shows the click cursor', (tester) async {
      await wi82Pump(tester, current: 2);
      for (final button in [wi82Previous, wi82Next, wi82Close]) {
        expect(
          await tester.macCursorAt(tester.getCenter(button)),
          SystemMouseCursors.click,
        );
      }
    }, variant: macOnly);

    testWidgets(
      'a disabled button shows the basic cursor and close the click cursor',
      (tester) async {
        await wi82Pump(tester, query: 'zzz');
        expect(
          await tester.macCursorAt(tester.getCenter(wi82Previous)),
          SystemMouseCursors.basic,
        );
        expect(
          await tester.macCursorAt(tester.getCenter(wi82Next)),
          SystemMouseCursors.basic,
        );
        expect(
          await tester.macCursorAt(tester.getCenter(wi82Close)),
          SystemMouseCursors.click,
        );
      },
      variant: macOnly,
    );
  });

  group('text scale', () {
    testWidgets(
      'at 2x text the counter slot measures the scaled counter text and never clips it',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await wi82Pump(tester, current: 2);

        expect(wi82CounterText(tester), '3 of 12');
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: wi82Counter,
            matching: find.byType(RichText),
            matchRoot: true,
          ),
        );
        final slot = tester.getSize(wi82Counter).width;
        expect(slot, greaterThan(64));
        expect(
          slot,
          moreOrLessEquals(
            text.getMaxIntrinsicWidth(double.infinity),
            epsilon: 1,
          ),
        );
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );
  });

  group('button semantics', () {
    testWidgets(
      'an enabled button has a tap action that steps once and a disabled one has none',
      (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await wi82Pump(tester, current: 2);

        for (final label in ['Previous match', 'Next match', 'Close find']) {
          final node = find.semantics.byLabel(label).evaluate().single;
          expect(node, isSemantics(hasTapAction: true), reason: label);
        }
        tester.semantics.tap(find.semantics.byLabel('Next match'));
        await tester.pump();
        expect(rig.find.state.current, 3);
        expect(rig.calls.steps, [rig.find.state.matches[3]]);

        await wi82Pump(tester, query: 'zzz');
        for (final label in ['Previous match', 'Next match']) {
          final node = find.semantics.byLabel(label).evaluate().single;
          expect(node, isSemantics(hasTapAction: false), reason: label);
        }
        final close = find.semantics.byLabel('Close find').evaluate().single;
        expect(close, isSemantics(hasTapAction: true));
        handle.dispose();
      },
      variant: macOnly,
    );
  });

  group('box and field look', () {
    testWidgets(
      'the box has 6 px corners and an 0 8 24 menu shadow and the field 4 px corners',
      (tester) async {
        await wi82Pump(tester, current: 2);
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(of: wi82Box, matching: find.byType(DecoratedBox))
              .first,
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(6));
        expect(decoration.boxShadow, hasLength(1));
        expect(decoration.boxShadow!.single.color, OmColors.menuShadow);
        expect(decoration.boxShadow!.single.offset, const Offset(0, 8));
        expect(decoration.boxShadow!.single.blurRadius, 24);

        final field = tester.widget<Container>(wi82Field);
        final fieldDecoration = field.decoration! as BoxDecoration;
        expect(fieldDecoration.borderRadius, BorderRadius.circular(4));
        expect(fieldDecoration.color, OmColors.surface0);
      },
      variant: macOnly,
    );

    testWidgets(
      'an empty query draws the field border in line3 unfocused and accentSoft focused, never danger',
      (tester) async {
        final rig = await wi82Pump(tester, query: '');
        await wi82FocusEditor(tester, rig);
        await wi82Settle(tester);
        final danger = wi82Argb(OmColors.danger);
        expect(wi82PaintColours(tester, wi82Box), isNot(contains(danger)));
        expect(
          wi82PaintColours(tester, wi82Box),
          contains(wi82Argb(OmColors.line3)),
        );

        await wi82FocusField(tester);
        await wi82Settle(tester);
        final colours = wi82PaintColours(tester, wi82Box);
        expect(colours, isNot(contains(danger)));
        expect(colours, contains(wi82Argb(OmColors.accentSoft)));
      },
      variant: macOnly,
    );

    testWidgets(
      'the query text starts 6 px after the magnifier, or 9 px inside the field without one',
      (tester) async {
        await wi82Pump(tester, current: 2);
        final text = tester.getRect(
          find.descendant(of: wi82Field, matching: find.byType(EditableText)),
        );
        expect(
          text.left - tester.getRect(wi82Magnifier).right,
          moreOrLessEquals(6, epsilon: 0.5),
        );

        await wi82Pump(tester, current: 2, bodyWidth: 192);
        expect(wi82Magnifier, findsNothing);
        final bare = tester.getRect(
          find.descendant(of: wi82Field, matching: find.byType(EditableText)),
        );
        expect(
          bare.left - tester.getRect(wi82Field).left,
          moreOrLessEquals(9, epsilon: 0.5),
        );
      },
      variant: macOnly,
    );

    testWidgets('the counter is mono 11 px and right aligned in its slot', (
      tester,
    ) async {
      await wi82Pump(tester, current: 2);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: wi82Counter,
          matching: find.byType(RichText),
          matchRoot: true,
        ),
      );
      expect(paragraph.text.style?.fontSize, 11);
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
      final right = boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b);
      expect(right, moreOrLessEquals(paragraph.size.width, epsilon: 0.5));
      expect(boxes.first.left, greaterThan(8));
    }, variant: macOnly);
  });
}
