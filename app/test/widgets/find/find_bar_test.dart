// WI #82 (Spec #61 F2; Reqs 12-13, 19-20, 22, 29-34, 40-41; rulings D12,
// D13, D14; design pack design/55-find-in-note/packs/82.md): the Find bar's
// behaviour. Shown/hidden, the field (placeholder, typing, paste, focus
// requests), its keyboard (Enter, Shift+Enter, Esc, key repeats, Cmd chords
// left to the native menu), the buttons (step, close, disabled, hover and
// tooltips), states and colours, the opaque box, semantics and the editor
// selection staying put.
//
// Geometry by body width (B4) is in find_bar_layout_test.dart; goldens in
// find_bar_golden_test.dart.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import 'find_bar_harness.dart';

/// A plain (no modifier) key down, repeat or up as macOS sends it.
Future<void> _wi82Up(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyUpEvent(key, platform: 'macos');

/// One press of [key] (down then up) with Shift held when [shift]; returns
/// whether the key down was handled.
Future<bool> _wi82Press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  if (shift) {
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.shiftLeft,
      platform: 'macos',
    );
  }
  final handled = await wi82KeyDown(tester, key);
  await _wi82Up(tester, key);
  if (shift) await _wi82Up(tester, LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  return handled;
}

/// A RichText anywhere on screen (overlays included) whose plain text,
/// with no-break spaces read as spaces, is [text].
Finder _wi82TextAnywhere(String text) => find.byWidgetPredicate(
  (w) =>
      w is RichText && w.text.toPlainText().replaceAll(' ', ' ').trim() == text,
  description: 'text "$text"',
);

/// The one semantics node labelled exactly [label].
SemanticsNode _wi82Node(String label) {
  final nodes = find.semantics.byLabel(label).evaluate().toList();
  expect(nodes, hasLength(1), reason: 'one semantics node labelled "$label"');
  return nodes.single;
}

void main() {
  holdFontFetches();
  wi82LoadFonts();

  final m = wi82TwelveMatches;

  group('shown only while open', () {
    testWidgets(
      'the find bar is absent while closed and shows 10 px below the body top and 12 px from its right edge, 38 px tall, while open',
      (tester) async {
        final rig = await wi82Pump(tester, open: false);
        expect(wi82Box, findsNothing);

        rig.find.notifier.show();
        await tester.pump();
        await tester.pump();
        expect(wi82Box, findsOneWidget);
        final host = wi82Host(tester);
        final box = tester.getRect(wi82Box);
        expect(box.top - host.top, moreOrLessEquals(10, epsilon: 0.01));
        expect(host.right - box.right, moreOrLessEquals(12, epsilon: 0.01));
        expect(box.height, moreOrLessEquals(38, epsilon: 0.01));

        rig.find.notifier.close();
        await tester.pump();
        expect(wi82Box, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'the box draws a surface3 fill, a line2 border and the menu shadow, and the field a surface0 fill',
      (tester) async {
        await wi82Pump(tester, current: 2);
        await wi82Settle(tester);
        final colours = wi82PaintColours(tester, wi82Box);
        expect(colours, contains(wi82Argb(OmColors.surface3)));
        expect(colours, contains(wi82Argb(OmColors.line2)));
        expect(colours, contains(wi82Argb(OmColors.menuShadow)));
        expect(colours, contains(wi82Argb(OmColors.surface0)));
      },
      variant: macOnly,
    );
  });

  group('the field', () {
    testWidgets(
      'the field shows the placeholder Find in note for an empty query and the query otherwise',
      (tester) async {
        final rig = await wi82Pump(tester, query: '');
        final hint = find.descendant(
          of: wi82Box,
          matching: find.text('Find in note'),
        );
        expect(hint, findsOneWidget);
        expect(wi82Editable(tester).controller.text, '');
        final hintStyle = tester
            .widget<RichText>(
              find.descendant(of: hint, matching: find.byType(RichText)),
            )
            .text
            .style;
        expect(hintStyle?.color, OmColors.fg2);

        // The field follows the query, whoever sets it.
        rig.find.notifier.setQuery(wi82Word);
        await tester.pump();
        expect(wi82Editable(tester).controller.text, wi82Word);
      },
      variant: macOnly,
    );

    testWidgets('the field opens holding the seeded query', (tester) async {
      await wi82Pump(tester, current: 2);
      expect(wi82Editable(tester).controller.text, wi82Word);
    }, variant: macOnly);

    testWidgets(
      'typing in the field sets the query and the counter reads 3 of 12 with the third match current',
      (tester) async {
        final rig = await wi82Pump(
          tester,
          query: '',
          caret: FindCaret(0, m[2].start),
        );
        expect(wi82CounterHidden(tester), isTrue);

        await tester.enterText(wi82Field, wi82Word);
        await tester.pump();

        expect(rig.find.state.query, wi82Word);
        expect(rig.find.state.lastQuery, wi82Word);
        expect(rig.find.state.current, 2);
        expect(wi82CounterText(tester), '3 of 12');
      },
      variant: macOnly,
    );

    testWidgets(
      'typing in the middle of the query keeps the caret where it was typed',
      (tester) async {
        final rig = await wi82Pump(tester);
        await wi82FocusField(tester);
        await tester.macEditingValue(
          'hyxdration',
          selection: const TextSelection.collapsed(offset: 3),
        );
        await tester.pump();

        expect(rig.find.state.query, 'hyxdration');
        expect(wi82Editable(tester).controller.text, 'hyxdration');
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection.collapsed(offset: 3),
        );
      },
      variant: macOnly,
    );

    testWidgets('pasting two lines into the field sets the query two lines', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'two\nlines');
      final rig = await wi82Pump(tester, query: '');
      await wi82FocusField(tester);

      await tester.macCmdChord(LogicalKeyboardKey.keyV);
      await tester.pump();

      expect(rig.find.state.query, 'two lines');
      expect(wi82Editable(tester).controller.text, 'two lines');
    }, variant: macOnly);

    testWidgets(
      'a focusRequest change focuses the field and selects its whole text',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusEditor(tester, rig);
        expect(wi82Editable(tester).focusNode.hasFocus, isFalse);

        rig.find.notifier.show();
        await tester.pump();
        await tester.pump();
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi82Word.length),
        );

        // Already focused, the caret moved: the next request selects all
        // again.
        wi82Editable(tester).controller.selection =
            const TextSelection.collapsed(offset: 4);
        await tester.pump();
        rig.find.notifier.show();
        await tester.pump();
        await tester.pump();
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);
        expect(
          wi82Editable(tester).controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi82Word.length),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'show on a closed bar opens it with the field focused and the last query selected',
      (tester) async {
        final rig = await wi82Pump(tester, open: false);
        await wi82FocusEditor(tester, rig);

        rig.find.notifier.show();
        await tester.pump();
        await tester.pump();

        final field = wi82Editable(tester);
        expect(field.controller.text, wi82Word);
        expect(field.focusNode.hasFocus, isTrue);
        expect(
          field.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi82Word.length),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'useSelection while open replaces the field text and leaves focus in the editor',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusEditor(tester, rig);

        rig.find.notifier.useSelection('raise');
        await tester.pump();
        await tester.pump();

        expect(wi82Editable(tester).controller.text, 'raise');
        expect(wi82Editable(tester).focusNode.hasFocus, isFalse);
        expect(wi82EditorEditable(tester).focusNode.hasFocus, isTrue);
        expect(rig.editor.selection, wi82EditorSelection);
      },
      variant: macOnly,
    );
  });

  group('keyboard in the field', () {
    testWidgets(
      'Enter in the field steps to the next match and Shift+Enter to the previous, each calling onStep',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);

        expect(await _wi82Press(tester, LogicalKeyboardKey.enter), isTrue);
        expect(rig.find.state.current, 3);
        expect(rig.calls.steps, [m[3]]);

        expect(
          await _wi82Press(tester, LogicalKeyboardKey.enter, shift: true),
          isTrue,
        );
        expect(rig.find.state.current, 2);
        expect(rig.calls.steps, [m[3], m[2]]);

        // No line break and no query change.
        expect(rig.find.state.query, wi82Word);
        expect(wi82Editable(tester).controller.text, wi82Word);
        expect(rig.calls.closes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Enter on the last match wraps to the first and Shift+Enter on the first wraps to the last',
      (tester) async {
        final rig = await wi82Pump(tester, current: 11);
        await wi82FocusField(tester);

        await _wi82Press(tester, LogicalKeyboardKey.enter);
        expect(rig.find.state.current, 0);
        await _wi82Press(tester, LogicalKeyboardKey.enter, shift: true);
        expect(rig.find.state.current, 11);
        expect(rig.calls.steps, [m[0], m[11]]);
      },
      variant: macOnly,
    );

    testWidgets('Enter with no matches calls no onStep', (tester) async {
      final rig = await wi82Pump(tester, query: 'zzz');
      await wi82FocusField(tester);

      await _wi82Press(tester, LogicalKeyboardKey.enter);
      await _wi82Press(tester, LogicalKeyboardKey.enter, shift: true);

      expect(rig.calls.steps, isEmpty);
      expect(rig.find.state.open, isTrue);
      expect(rig.find.state.current, isNull);
    }, variant: macOnly);

    testWidgets('a held Enter steps once per key repeat event', (tester) async {
      final rig = await wi82Pump(tester, current: 0);
      await wi82FocusField(tester);

      expect(await wi82KeyDown(tester, LogicalKeyboardKey.enter), isTrue);
      expect(
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.enter,
          platform: 'macos',
        ),
        isTrue,
      );
      await tester.sendKeyRepeatEvent(
        LogicalKeyboardKey.enter,
        platform: 'macos',
      );
      await _wi82Up(tester, LogicalKeyboardKey.enter);
      await tester.pump();

      expect(rig.find.state.current, 3);
      expect(rig.calls.steps, [m[1], m[2], m[3]]);
    }, variant: macOnly);

    testWidgets('a held Shift+Enter steps back once per key repeat event', (
      tester,
    ) async {
      final rig = await wi82Pump(tester, current: 5);
      await wi82FocusField(tester);

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
      await wi82KeyDown(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(
        LogicalKeyboardKey.enter,
        platform: 'macos',
      );
      await _wi82Up(tester, LogicalKeyboardKey.enter);
      await _wi82Up(tester, LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(rig.find.state.current, 3);
      expect(rig.calls.steps, [m[4], m[3]]);
    }, variant: macOnly);

    testWidgets('two Enter presses in one frame step twice', (tester) async {
      final rig = await wi82Pump(tester, current: 0);
      await wi82FocusField(tester);

      await wi82KeyDown(tester, LogicalKeyboardKey.enter);
      await _wi82Up(tester, LogicalKeyboardKey.enter);
      await wi82KeyDown(tester, LogicalKeyboardKey.enter);
      await _wi82Up(tester, LogicalKeyboardKey.enter);
      await tester.pump();

      expect(rig.find.state.current, 2);
      expect(rig.calls.steps, [m[1], m[2]]);
    }, variant: macOnly);

    testWidgets(
      'Esc in the field closes the bar and calls onClose with the current match',
      (tester) async {
        final rig = await wi82Pump(tester, current: 4);
        await wi82FocusField(tester);

        expect(await _wi82Press(tester, LogicalKeyboardKey.escape), isTrue);

        expect(rig.find.state.open, isFalse);
        expect(rig.calls.closes, [m[4]]);
        expect(rig.calls.steps, isEmpty);
        expect(wi82Box, findsNothing);
        // The last query stays (Req 40).
        expect(rig.find.state.lastQuery, wi82Word);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc in the field with no matches closes the bar and calls onClose with null',
      (tester) async {
        final rig = await wi82Pump(tester, query: 'zzz');
        await wi82FocusField(tester);

        expect(await _wi82Press(tester, LogicalKeyboardKey.escape), isTrue);

        expect(rig.find.state.open, isFalse);
        expect(rig.calls.closes, [null]);
      },
      variant: macOnly,
    );

    testWidgets('Esc while the editor field has focus does not close the bar', (
      tester,
    ) async {
      final rig = await wi82Pump(tester, current: 2);
      await wi82FocusEditor(tester, rig);

      await _wi82Press(tester, LogicalKeyboardKey.escape);
      // Enter outside the field does not step either: the keys are the
      // field's own.
      await _wi82Press(tester, LogicalKeyboardKey.enter);

      expect(rig.find.state.open, isTrue);
      expect(rig.find.state.current, 2);
      expect(rig.calls.closes, isEmpty);
      expect(rig.calls.steps, isEmpty);
      expect(wi82Box, findsOneWidget);
    }, variant: macOnly);

    testWidgets(
      'Cmd+F, Cmd+G, Shift+Cmd+G and Cmd+E in the find field are not handled',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);

        final chords = <(LogicalKeyboardKey, bool)>[
          (LogicalKeyboardKey.keyF, false),
          (LogicalKeyboardKey.keyG, false),
          (LogicalKeyboardKey.keyG, true),
          (LogicalKeyboardKey.keyE, false),
        ];
        for (final (key, shift) in chords) {
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.metaLeft,
            platform: 'macos',
          );
          if (shift) {
            await tester.sendKeyDownEvent(
              LogicalKeyboardKey.shiftLeft,
              platform: 'macos',
            );
          }
          final handled = await wi82KeyDown(tester, key);
          await _wi82Up(tester, key);
          if (shift) await _wi82Up(tester, LogicalKeyboardKey.shiftLeft);
          await _wi82Up(tester, LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(
            handled,
            isFalse,
            reason: '${shift ? 'Shift+' : ''}Cmd+${key.keyLabel}',
          );
        }

        expect(rig.find.state.open, isTrue);
        expect(rig.find.state.current, 2);
        expect(rig.find.state.query, wi82Word);
        expect(rig.calls.steps, isEmpty);
        expect(rig.calls.closes, isEmpty);
        expect(wi82Editable(tester).focusNode.hasFocus, isTrue);
      },
      variant: macOnly,
    );
  });

  group('buttons', () {
    testWidgets(
      'clicking the down button steps next and the up button steps previous, once per click, each calling onStep',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);

        await tester.tap(wi82Next);
        await tester.pump();
        expect(rig.find.state.current, 3);
        expect(rig.calls.steps, [m[3]]);

        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.find.state.current, 2);
        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.find.state.current, 1);
        expect(rig.calls.steps, [m[3], m[2], m[1]]);
        expect(rig.calls.closes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'the down button on the last match wraps to the first and the up button wraps back to the last',
      (tester) async {
        final rig = await wi82Pump(tester, current: 11);

        await tester.tap(wi82Next);
        await tester.pump();
        expect(rig.find.state.current, 0);
        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.find.state.current, 11);
        expect(rig.calls.steps, [m[0], m[11]]);
      },
      variant: macOnly,
    );

    testWidgets('two clicks on the down button in one frame step twice', (
      tester,
    ) async {
      final rig = await wi82Pump(tester, current: 2);

      await tester.tap(wi82Next);
      await tester.tap(wi82Next);
      await tester.pump();

      expect(rig.find.state.current, 4);
      expect(rig.calls.steps, [m[3], m[4]]);
    }, variant: macOnly);

    testWidgets(
      'clicking the close button closes the bar and calls onClose with the current match',
      (tester) async {
        final rig = await wi82Pump(tester, current: 5);

        await tester.tap(wi82Close);
        await tester.pump();

        expect(rig.find.state.open, isFalse);
        expect(rig.calls.closes, [m[5]]);
        expect(rig.calls.steps, isEmpty);
        expect(wi82Box, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'the up and down buttons are disabled in fg3 with no action while there are no matches, and close stays enabled',
      (tester) async {
        final rig = await wi82Pump(tester, query: 'zzz');

        expect(wi82IconColour(tester, wi82Previous), OmColors.fg3);
        expect(wi82IconColour(tester, wi82Next), OmColors.fg3);
        expect(wi82IconColour(tester, wi82Close), OmColors.fg1);

        await tester.tap(wi82Next);
        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.calls.steps, isEmpty);
        expect(rig.find.state.current, isNull);
        expect(rig.find.state.open, isTrue);

        await tester.tap(wi82Close);
        await tester.pump();
        expect(rig.find.state.open, isFalse);
        expect(rig.calls.closes, [null]);
      },
      variant: macOnly,
    );

    testWidgets('the up and down buttons are disabled for an empty query', (
      tester,
    ) async {
      final rig = await wi82Pump(tester, query: '');

      expect(wi82IconColour(tester, wi82Previous), OmColors.fg3);
      expect(wi82IconColour(tester, wi82Next), OmColors.fg3);
      await tester.tap(wi82Next);
      await tester.tap(wi82Previous);
      await tester.pump();
      expect(rig.calls.steps, isEmpty);
    }, variant: macOnly);

    testWidgets(
      'the up and down buttons are enabled in fg1 with a single match and step onto it',
      (tester) async {
        final rig = await wi82Pump(
          tester,
          sources: const [
            FindSource(
              segment: 0,
              kind: FindSourceKind.body,
              text: 'one hydration only',
            ),
          ],
        );
        final only = rig.find.state.matches.single;

        expect(wi82IconColour(tester, wi82Previous), OmColors.fg1);
        expect(wi82IconColour(tester, wi82Next), OmColors.fg1);
        await tester.tap(wi82Next);
        await tester.pump();
        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.calls.steps, [only, only]);
        expect(rig.find.state.current, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'the disabled up and down buttons announce disabled and enabled ones enabled',
      (tester) async {
        final handle = tester.ensureSemantics();
        await wi82Pump(tester, query: 'zzz');
        for (final label in ['Previous match', 'Next match']) {
          expect(
            _wi82Node(label),
            isSemantics(hasEnabledState: true, isEnabled: false),
            reason: label,
          );
        }
        expect(
          _wi82Node('Close find'),
          isSemantics(hasEnabledState: true, isEnabled: true),
        );

        await wi82Pump(tester, current: 2);
        for (final label in ['Previous match', 'Next match']) {
          expect(
            _wi82Node(label),
            isSemantics(hasEnabledState: true, isEnabled: true),
            reason: label,
          );
        }
        handle.dispose();
      },
      variant: macOnly,
    );

    final hovers = <(String, Finder Function(), String)>[
      (
        'hovering the up button shows the surface4 fill and the tooltip Previous match, and moving out removes the fill',
        () => wi82Previous,
        'Previous match ⇧⌘G',
      ),
      (
        'hovering the down button shows the surface4 fill and the tooltip Next match, and moving out removes the fill',
        () => wi82Next,
        'Next match ⌘G',
      ),
      (
        'hovering the close button shows the surface4 fill and the tooltip Close Esc, and moving out removes the fill',
        () => wi82Close,
        'Close Esc',
      ),
    ];
    for (final (name, button, tip) in hovers) {
      testWidgets(name, (tester) async {
        await wi82Pump(tester, current: 2);
        final surface4 = wi82Argb(OmColors.surface4);
        expect(wi82PaintColours(tester, button()), isNot(contains(surface4)));
        expect(_wi82TextAnywhere(tip), findsNothing);

        final away = wi82Host(tester).center;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: away);
        addTearDown(mouse.removePointer);
        await tester.pump();

        await mouse.moveTo(tester.getCenter(button()));
        await wi82Settle(tester);
        expect(wi82PaintColours(tester, button()), contains(surface4));
        expect(_wi82TextAnywhere(tip), findsOneWidget);

        await mouse.moveTo(away);
        await wi82Settle(tester);
        expect(wi82PaintColours(tester, button()), isNot(contains(surface4)));
        await wi82Settle(tester);
      }, variant: macOnly);
    }

    testWidgets('hovering a disabled down button shows no hover fill', (
      tester,
    ) async {
      await wi82Pump(tester, query: 'zzz');
      final surface4 = wi82Argb(OmColors.surface4);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: wi82Host(tester).center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(wi82Next));
      await wi82Settle(tester);

      expect(wi82PaintColours(tester, wi82Next), isNot(contains(surface4)));
      await mouse.moveTo(wi82Host(tester).center);
      await wi82Settle(tester);
      await wi82Settle(tester);
    }, variant: macOnly);
  });

  group('states and colours', () {
    testWidgets(
      'a non-empty query with no matches reads No matches in danger and draws the field border in danger',
      (tester) async {
        await wi82Pump(tester, query: 'zzz');
        await wi82FocusField(tester);
        await wi82Settle(tester);

        expect(wi82CounterText(tester), 'No matches');
        expect(wi82CounterColour(tester), OmColors.danger);
        final colours = wi82PaintColours(tester, wi82Box);
        expect(colours, contains(wi82Argb(OmColors.danger)));
        expect(colours, isNot(contains(wi82Argb(OmColors.accentSoft))));
      },
      variant: macOnly,
    );

    testWidgets(
      'at a 240 px box a query with no matches reads None in danger and draws the field border in danger',
      (tester) async {
        await wi82Pump(tester, query: 'zzz', bodyWidth: 264);
        await wi82FocusField(tester);
        await wi82Settle(tester);

        expect(wi82CounterText(tester), 'None');
        expect(wi82CounterColour(tester), OmColors.danger);
        expect(
          wi82PaintColours(tester, wi82Box),
          contains(wi82Argb(OmColors.danger)),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'at a 168 px box a query with no matches shows no counter and draws the field border in danger',
      (tester) async {
        await wi82Pump(tester, query: 'zzz', bodyWidth: 192);
        await wi82FocusField(tester);
        await wi82Settle(tester);

        expect(wi82CounterHidden(tester), isTrue);
        expect(
          wi82PaintColours(tester, wi82Box),
          contains(wi82Argb(OmColors.danger)),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a query with matches reads the counter in fg2 and draws the focused field border in accentSoft and the query in fg0',
      (tester) async {
        await wi82Pump(tester, current: 2);
        await wi82FocusField(tester);
        await wi82Settle(tester);

        expect(wi82CounterText(tester), '3 of 12');
        expect(wi82CounterColour(tester), OmColors.fg2);
        final colours = wi82PaintColours(tester, wi82Box);
        expect(colours, contains(wi82Argb(OmColors.accentSoft)));
        expect(colours, isNot(contains(wi82Argb(OmColors.danger))));
        expect(wi82Editable(tester).style.color, OmColors.fg0);
      },
      variant: macOnly,
    );

    testWidgets(
      'the unfocused field draws a line3 border with no accentSoft ring and its query in fg1',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusEditor(tester, rig);
        await wi82Settle(tester);

        final colours = wi82PaintColours(tester, wi82Box);
        expect(colours, contains(wi82Argb(OmColors.line3)));
        expect(colours, isNot(contains(wi82Argb(OmColors.accentSoft))));
        expect(wi82Editable(tester).style.color, OmColors.fg1);

        await wi82FocusField(tester);
        await wi82Settle(tester);
        expect(
          wi82PaintColours(tester, wi82Box),
          contains(wi82Argb(OmColors.accentSoft)),
        );
        expect(wi82Editable(tester).style.color, OmColors.fg0);
      },
      variant: macOnly,
    );

    testWidgets(
      'the magnifier is a 12 px glyph in fg3 and the button icons are 14 px',
      (tester) async {
        await wi82Pump(tester, current: 2);
        final magnifier = tester.widget<Icon>(wi82Magnifier);
        expect(magnifier.size, 12);
        expect(magnifier.color, OmColors.fg3);
        for (final button in [wi82Previous, wi82Next, wi82Close]) {
          expect(
            tester
                .widget<Icon>(
                  find.descendant(of: button, matching: find.byType(Icon)),
                )
                .size,
            14,
          );
        }
      },
      variant: macOnly,
    );
  });

  group('pointer', () {
    testWidgets(
      'a press anywhere inside the find bar box does not reach the layer under it',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        final box = tester.getRect(wi82Box);
        final points = <Offset>[
          box.topLeft + const Offset(0.5, 0.5),
          box.topRight + const Offset(-0.5, 0.5),
          box.bottomLeft + const Offset(0.5, -0.5),
          box.bottomRight + const Offset(-0.5, -0.5),
          Offset(box.left + 3, box.center.dy),
          Offset(box.center.dx, box.top + 2),
          Offset(tester.getRect(wi82Previous).left - 2, box.center.dy),
          tester.getCenter(wi82Counter),
          tester.getCenter(wi82Field),
        ];
        for (final p in points) {
          await tester.tapAt(p);
          await tester.pump();
        }
        expect(rig.calls.downs, 0);
        expect(rig.find.state.open, isTrue);

        // Just outside the box the layer under it gets the press.
        await tester.tapAt(Offset(box.left - 3, box.bottom + 3));
        await tester.pump();
        expect(rig.calls.downs, 1);
        await wi82Settle(tester);
        await wi82Settle(tester);
      },
      variant: macOnly,
    );
  });

  group('semantics', () {
    final forms = <(String, double, String?)>[
      (
        'the field is labelled Find in note with value 3 of 12 beside the full counter',
        532,
        '3 of 12',
      ),
      (
        'the field is labelled Find in note with value 3 of 12 beside the short counter',
        264,
        '3/12',
      ),
      (
        'the field is labelled Find in note with value 3 of 12 with the counter hidden',
        192,
        null,
      ),
    ];
    for (final (name, body, shown) in forms) {
      testWidgets(name, (tester) async {
        final handle = tester.ensureSemantics();
        await wi82Pump(tester, current: 2, bodyWidth: body);

        if (shown == null) {
          expect(wi82CounterHidden(tester), isTrue);
        } else {
          expect(wi82CounterText(tester), shown);
        }
        final field = find.semantics
            .byLabel('Find in note')
            .evaluate()
            .where((n) => n.value == '3 of 12')
            .toList();
        expect(field, hasLength(1));
        expect(field.single, isSemantics(isTextField: true));
        handle.dispose();
      }, variant: macOnly);
    }

    testWidgets(
      'the up, down and close buttons are labelled Previous match, Next match and Close find',
      (tester) async {
        final handle = tester.ensureSemantics();
        await wi82Pump(tester, current: 2);
        for (final label in ['Previous match', 'Next match', 'Close find']) {
          final node = _wi82Node(label);
          expect(node, isSemantics(isButton: true), reason: label);
          expect(node.childrenCount, 0, reason: '$label is a leaf');
        }
        handle.dispose();
      },
      variant: macOnly,
    );
  });

  group('editor selection', () {
    testWidgets(
      'stepping from the bar with Enter, up and down leaves the editor selection unchanged',
      (tester) async {
        final rig = await wi82Pump(tester, current: 2);
        await wi82FocusEditor(tester, rig);

        await tester.tap(wi82Next);
        await tester.pump();
        expect(rig.editor.selection, wi82EditorSelection);
        await tester.tap(wi82Previous);
        await tester.pump();
        expect(rig.editor.selection, wi82EditorSelection);

        await wi82FocusField(tester);
        await _wi82Press(tester, LogicalKeyboardKey.enter);
        await _wi82Press(tester, LogicalKeyboardKey.enter, shift: true);

        expect(rig.editor.selection, wi82EditorSelection);
        expect(rig.editor.text, wi82EditorText);
        expect(rig.calls.steps, [m[3], m[2], m[3], m[2]]);
      },
      variant: macOnly,
    );
  });
}
