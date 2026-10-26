// WI #171 (C4, Spec #157 R27, R29; rulings D2, D8, D9, D17; TS2, TS5, TS7,
// TS8): copy, cut, paste, type-over, the context menu and IME composition
// over a selection that spans a text segment's editor rows.
// - Cmd+C copies the range's raw markdown (markers, indentation, the
//   newlines between rows) and leaves the text alone; Cmd+X copies then
//   deletes; Cmd+V replaces the range with the pasted text. Rows re-derive
//   and the caret lands at the end of the inserted text, or the range start
//   for a delete.
// - Type-over: the key handler deletes the range into the focused row's
//   controller, keeps focus there and leaves the key unhandled, so the field
//   inserts it. Every key handler leaves keys alone while composing.
// - The right-click menu offers Copy, Cut, Paste and Select All, each with
//   its shortcut's result.
// - IME (R29): composition that starts over a cross-row selection deletes
//   the range into the focused row without moving focus (no text input
//   client change) and commits at the range start.
// Every test runs on macOS (mac_editing.dart, TS7).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi171_segment_harness.dart';

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: Cmd+C
  // -------------------------------------------------------------------------
  group('copy (AC1)', () {
    testWidgets(
      'Cmd+C on a cross row selection copies the raw markdown of the range and leaves the text unchanged',
      (tester) async {
        final clip = MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await tester.macCmdChord(LogicalKeyboardKey.keyC);

        expect(clip.text, 'b\n- c');
        expect(clip.writes, ['b\n- c']);
        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, wi171Text);
        expect(handle.selection, wi171Across);
        expect(body.changes, isEmpty);
        expect(wi171Texts(tester, 0), ['para', 'ab', 'cd']);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+C on a backward cross row selection copies the same range',
      (tester) async {
        final clip = MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(
          tester,
          focus: 1,
          selection: wi171AcrossBackward,
        );

        await tester.macCmdChord(LogicalKeyboardKey.keyC);

        expect(clip.text, 'b\n- c');
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171AcrossBackward);
        expect(body.changes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+C copies nested markers indentation and CRLF terminators verbatim',
      (tester) async {
        const text = 'p\r\n  - b\r\n    - [ ] c\r\n> q';
        final clip = MacClipboard.install(tester);
        await wi171Pump(tester, text);
        // From after `p` to after `q`'s marker, `- [ ] c` and `> ` included.
        final selection = TextSelection(
          baseOffset: 1,
          extentOffset: text.length,
        );
        final rows = segmentEditingAt(tester, 0).rowCount;
        await wi171SelectAcross(tester, focus: rows - 1, selection: selection);

        await tester.macCmdChord(LogicalKeyboardKey.keyC);

        expect(clip.text, text.substring(1));
        expect(segmentEditingAt(tester, 0).text, text);
      },
      variant: macOnly,
    );

    testWidgets('Cmd+C on a selection within one row copies that text', (
      tester,
    ) async {
      final clip = MacClipboard.install(tester);
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(
        tester,
        focus: 1,
        selection: const TextSelection(baseOffset: 7, extentOffset: 9),
      );

      await tester.macCmdChord(LogicalKeyboardKey.keyC);

      expect(clip.text, 'ab');
      expect(segmentEditingAt(tester, 0).text, wi171Text);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC2: Cmd+X
  // -------------------------------------------------------------------------
  group('cut (AC2)', () {
    testWidgets(
      'Cmd+X on a cross row selection copies the range then deletes it with the caret at the range start',
      (tester) async {
        final clip = MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        final node = FocusManager.instance.primaryFocus;

        await tester.macCmdChord(LogicalKeyboardKey.keyX);

        expect(clip.text, 'b\n- c');
        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- ad');
        expect(handle.selection, const TextSelection.collapsed(offset: 8));
        expect(body.changes, ['para\n- ad']);
        expect(wi171Texts(tester, 0), ['para', 'ad']);
        // The cross-row delete merges into the focused row (R40).
        expect(handle.focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+X on a backward cross row selection leaves the same text and caret',
      (tester) async {
        final clip = MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(
          tester,
          focus: 1,
          selection: wi171AcrossBackward,
        );

        await tester.macCmdChord(LogicalKeyboardKey.keyX);

        expect(clip.text, 'b\n- c');
        expect(body.changes, ['para\n- ad']);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 8),
        );
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: Cmd+V
  // -------------------------------------------------------------------------
  group('paste (AC3)', () {
    testWidgets(
      'Cmd+V replaces a cross row selection with the pasted text and puts the caret after it',
      (tester) async {
        final clip = MacClipboard.install(tester, initial: 'X\nY');
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        final node = FocusManager.instance.primaryFocus;

        await tester.macCmdChord(LogicalKeyboardKey.keyV);
        await tester.pump();

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- aX\nYd');
        expect(handle.selection, const TextSelection.collapsed(offset: 11));
        expect(body.changes, ['para\n- aX\nYd']);
        // Rows re-derive: `Yd` is a plain line now, a prose row.
        expect(wi171Texts(tester, 0), ['para', 'aX', 'Yd']);
        expect(handle.rowCount, 3);
        expect(handle.focusedRow, 2);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(clip.text, 'X\nY');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+V of list lines over a cross row selection re-derives item rows from the result',
      (tester) async {
        MacClipboard.install(tester, initial: 'X\n- Y\n- Z');
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await tester.macCmdChord(LogicalKeyboardKey.keyV);
        await tester.pump();

        const result = 'para\n- aX\n- Y\n- Zd';
        expect(segmentEditingAt(tester, 0).text, result);
        expect(body.changes, [result]);
        expect(wi171Texts(tester, 0), ['para', 'aX', 'Y', 'Zd']);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: result.length - 1),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+V with an empty clipboard leaves a cross row selection and the text unchanged',
      (tester) async {
        MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await tester.macCmdChord(LogicalKeyboardKey.keyV);
        await tester.pump();

        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(body.changes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('Cmd+V at a caret inserts the pasted lines into the segment', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X\nY');
      final body = await wi171Pump(tester, wi171Text);
      await wi171FocusRow(tester, 0, 1, local: 1);

      await tester.macCmdChord(LogicalKeyboardKey.keyV);
      await tester.pump();

      expect(segmentEditingAt(tester, 0).text, 'para\n- aX\nYb\n- cd');
      expect(body.changes.last, 'para\n- aX\nYb\n- cd');
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 11),
      );
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC4: type-over (TS8: keeps focus)
  // -------------------------------------------------------------------------
  group('type over (AC4)', () {
    testWidgets(
      'typing z over a cross row selection replaces the range and keeps focus in the row that held the caret',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        final node = FocusManager.instance.primaryFocus;
        final ctrl = wi171Ctrl(tester, 0, 2);
        final state = tester.state<EditableTextState>(wi171FieldOf(0, 2));
        tester.testTextInput.log.clear();

        await wi171TypeKey(tester, 'z');

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- azd');
        expect(handle.selection, const TextSelection.collapsed(offset: 9));
        expect(body.changes.last, 'para\n- azd');
        expect(wi171Texts(tester, 0), ['para', 'azd']);
        expect(handle.focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(wi171Ctrl(tester, 0, 1), same(ctrl));
        expect(
          tester.state<EditableTextState>(wi171FieldOf(0, 1)),
          same(state),
        );
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'typing z over a backward cross row selection keeps focus in the first row',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(
          tester,
          focus: 1,
          selection: wi171AcrossBackward,
        );
        final node = FocusManager.instance.primaryFocus;
        final ctrl = wi171Ctrl(tester, 0, 1);
        tester.testTextInput.log.clear();

        await wi171TypeKey(tester, 'z');

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- azd');
        expect(handle.selection, const TextSelection.collapsed(offset: 9));
        expect(body.changes.last, 'para\n- azd');
        expect(handle.focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(wi171Ctrl(tester, 0, 1), same(ctrl));
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'the type over key deletes the range before the field inserts the key and leaves the key unhandled',
      (tester) async {
        await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        final handled = await tester.sendKeyDownEvent(
          LogicalKeyboardKey.keyZ,
          platform: 'macos',
          character: 'z',
        );
        await tester.pump();

        // The key reached the field unhandled; the range is already gone and
        // the focused row holds the caret at the range start.
        expect(handled, isFalse);
        expect(segmentEditingAt(tester, 0).text, 'para\n- ad');
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 8),
        );
        final focused = wi171FocusedController().value;
        expect(focused.text, 'ad');
        expect(focused.selection, const TextSelection.collapsed(offset: 1));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ, platform: 'macos');
      },
      variant: macOnly,
    );

    testWidgets(
      'a key while the focused row is composing never deletes a cross row selection',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171FocusRow(tester, 0, 2);
        // The IME marks text inside row 2 (no cross-row selection yet).
        await tester.macCompose('cd´', const TextRange(start: 2, end: 3));
        expect(segmentEditingAt(tester, 0).text, 'para\n- ab\n- cd´');
        final changes = body.changes.length;
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 8, extentOffset: 14));
        await tester.pump();
        expect(wi171FocusedController().value.composing.isValid, isTrue);

        final handled = await tester.sendKeyDownEvent(
          LogicalKeyboardKey.keyE,
          platform: 'macos',
          character: 'e',
        );
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE, platform: 'macos');
        await tester.pump();

        expect(handled, isFalse);
        expect(segmentEditingAt(tester, 0).text, 'para\n- ab\n- cd´');
        expect(body.changes, hasLength(changes));
      },
      variant: macOnly,
    );

    testWidgets(
      'modifier keys over a cross row selection leave the range in place',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        for (final key in [
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.controlLeft,
        ]) {
          await tester.sendKeyDownEvent(key, platform: 'macos');
          await tester.pump();
          await tester.sendKeyUpEvent(key, platform: 'macos');
          await tester.pump();
        }

        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(body.changes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('typing over a selection within one row is left to the field', (
      tester,
    ) async {
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(
        tester,
        focus: 1,
        selection: const TextSelection(baseOffset: 7, extentOffset: 9),
      );

      await wi171TypeKey(tester, 'z');

      expect(segmentEditingAt(tester, 0).text, 'para\n- z\n- cd');
      expect(body.changes, ['para\n- z\n- cd']);
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 8),
      );
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC5: the right-click context menu
  // -------------------------------------------------------------------------
  group('context menu (AC5)', () {
    /// Right-clicks the selected `c` (segment offset 12) in the focused row.
    Future<void> openMenu(WidgetTester tester) async {
      await wi171RightClick(tester, wi171GlyphCenter(tester, 0, 12));
    }

    testWidgets(
      'the right click menu on a cross row selection offers Copy Cut Paste and Select All and keeps the selection',
      (tester) async {
        MacClipboard.install(tester, initial: 'X\nY');
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await openMenu(tester);

        for (final label in ['Copy', 'Cut', 'Paste', 'Select All']) {
          expect(wi171MenuButton(label), findsOneWidget, reason: label);
        }
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('the context menu Copy gives the same result as Cmd+C', (
      tester,
    ) async {
      final clip = MacClipboard.install(tester, initial: 'old');
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      await tester.tap(wi171MenuButton('Copy'));
      await tester.pumpAndSettle();

      expect(clip.text, 'b\n- c');
      expect(segmentEditingAt(tester, 0).text, wi171Text);
      expect(body.changes, isEmpty);
      expect(wi171MenuButton('Copy'), findsNothing);
    }, variant: macOnly);

    testWidgets('the context menu Cut gives the same result as Cmd+X', (
      tester,
    ) async {
      final clip = MacClipboard.install(tester, initial: 'old');
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      await tester.tap(wi171MenuButton('Cut'));
      await tester.pumpAndSettle();

      expect(clip.text, 'b\n- c');
      expect(segmentEditingAt(tester, 0).text, 'para\n- ad');
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 8),
      );
      expect(body.changes, ['para\n- ad']);
      expect(wi171Texts(tester, 0), ['para', 'ad']);
    }, variant: macOnly);

    testWidgets('the context menu Paste gives the same result as Cmd+V', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X\nY');
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      await tester.tap(wi171MenuButton('Paste'));
      await tester.pumpAndSettle();

      expect(segmentEditingAt(tester, 0).text, 'para\n- aX\nYd');
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 11),
      );
      expect(body.changes, ['para\n- aX\nYd']);
      expect(wi171Texts(tester, 0), ['para', 'aX', 'Yd']);
    }, variant: macOnly);

    testWidgets('the context menu Select All gives the same result as Cmd+A', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X\nY');
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await tester.macCmdChord(LogicalKeyboardKey.keyA);
      final viaShortcut = segmentEditingAt(tester, 0).selection;
      final rowViaShortcut = segmentEditingAt(tester, 0).focusedRow;

      // The same note and selection again, then the menu's Select All.
      await wi171Pump(tester, 'other');
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);
      await tester.tap(wi171MenuButton('Select All'));
      await tester.pumpAndSettle();

      expect(segmentEditingAt(tester, 0).selection, viaShortcut);
      expect(segmentEditingAt(tester, 0).focusedRow, rowViaShortcut);
      expect(segmentEditingAt(tester, 0).text, wi171Text);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC6: IME composition over a cross-row selection (R29, TS5, TS8)
  // -------------------------------------------------------------------------
  group('IME over a cross row selection (AC6)', () {
    testWidgets(
      'an updateEditingValue that starts composing over a cross row selection deletes the range into the focused row without moving focus',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        final node = FocusManager.instance.primaryFocus;
        final ctrl = wi171Ctrl(tester, 0, 2);
        final state = tester.state<EditableTextState>(wi171FieldOf(0, 2));
        tester.testTextInput.log.clear();

        // Option+E: the IME marks an acute accent over the row slice `c`.
        await tester.macCompose('´d', const TextRange(start: 0, end: 1));

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- a´d');
        expect(body.changes.last, 'para\n- a´d');
        expect(wi171Texts(tester, 0), ['para', 'a´d']);
        expect(handle.focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(wi171Ctrl(tester, 0, 1), same(ctrl));
        expect(
          tester.state<EditableTextState>(wi171FieldOf(0, 1)),
          same(state),
        );
        expect(ctrl.value.composing, const TextRange(start: 1, end: 2));
        expect(ctrl.value.selection, const TextSelection.collapsed(offset: 2));
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);

        // E: the IME commits the composed character at the range start.
        await tester.macEditingValue(
          'aéd',
          selection: const TextSelection.collapsed(offset: 2),
        );

        expect(handle.text, 'para\n- aéd');
        expect(body.changes.last, 'para\n- aéd');
        expect(handle.selection, const TextSelection.collapsed(offset: 9));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'composing over a backward cross row selection deletes the range into the first row and commits at the range start',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(
          tester,
          focus: 1,
          selection: wi171AcrossBackward,
        );
        final node = FocusManager.instance.primaryFocus;
        tester.testTextInput.log.clear();

        // The row slice `b` (local 1..2) is replaced by the marked accent.
        await tester.macCompose('a´', const TextRange(start: 1, end: 2));

        expect(segmentEditingAt(tester, 0).text, 'para\n- a´d');
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));

        await tester.macEditingValue(
          'aéd',
          selection: const TextSelection.collapsed(offset: 2),
        );

        expect(segmentEditingAt(tester, 0).text, 'para\n- aéd');
        expect(body.changes.last, 'para\n- aéd');
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Japanese composition over a cross row selection continues in the focused row and commits at the range start',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        final node = FocusManager.instance.primaryFocus;
        tester.testTextInput.log.clear();

        await tester.macCompose('にd', const TextRange(start: 0, end: 1));
        expect(segmentEditingAt(tester, 0).text, 'para\n- aにd');

        await tester.macCompose('aにほd', const TextRange(start: 1, end: 3));
        expect(segmentEditingAt(tester, 0).text, 'para\n- aにほd');
        expect(
          wi171FocusedController().value.composing,
          const TextRange(start: 1, end: 3),
        );

        await tester.macEditingValue(
          'a日本d',
          selection: const TextSelection.collapsed(offset: 3),
        );

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, 'para\n- a日本d');
        expect(body.changes.last, 'para\n- a日本d');
        expect(handle.selection, const TextSelection.collapsed(offset: 10));
        expect(handle.focusedRow, 1);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(wi171ClientChanges(tester.testTextInput.log), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('composing within one row is left to the field', (
      tester,
    ) async {
      final body = await wi171Pump(tester, wi171Text);
      await wi171FocusRow(tester, 0, 2);

      await tester.macCompose('cd´', const TextRange(start: 2, end: 3));

      expect(segmentEditingAt(tester, 0).text, 'para\n- ab\n- cd´');
      expect(body.changes, ['para\n- ab\n- cd´']);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // Contracts the ops widget documents (verify-mode pins) and ruling D20:
  // one user action = one SegmentEdit = one onContentChanged report.
  // -------------------------------------------------------------------------
  group('ops contracts (D20, documented behaviour)', () {
    testWidgets(
      'typing z over a cross row selection reports one content change',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await wi171TypeKey(tester, 'z');

        expect(segmentEditingAt(tester, 0).text, 'para\n- azd');
        expect(body.changes, ['para\n- azd']);
      },
      variant: macOnly,
    );

    // Which key characters type text (and so type over a cross-row
    // selection): printable characters only, not control characters, DEL
    // or the macOS function-key range U+F700 to U+F8FF.
    final characters = <(String, String, bool)>[
      (
        'a key typing a space over a cross row selection deletes the range',
        ' ',
        true,
      ),
      (
        'a key typing a tilde over a cross row selection deletes the range',
        '~',
        true,
      ),
      (
        'a key typing U+0080 over a cross row selection deletes the range',
        '\u0080',
        true,
      ),
      (
        'a key typing U+F6FF over a cross row selection deletes the range',
        '',
        true,
      ),
      (
        'a key typing U+F900 over a cross row selection deletes the range',
        '豈',
        true,
      ),
      (
        'a key typing an accented letter over a cross row selection deletes the range',
        'é',
        true,
      ),
      (
        'a key typing U+001F over a cross row selection leaves the range',
        '\u001F',
        false,
      ),
      (
        'a key typing DEL over a cross row selection leaves the range',
        '\u007F',
        false,
      ),
      (
        'a key typing U+F700 over a cross row selection leaves the range',
        '',
        false,
      ),
      (
        'a key typing an arrow function key over a cross row selection leaves the range',
        '',
        false,
      ),
      (
        'a key typing U+F8FF over a cross row selection leaves the range',
        '',
        false,
      ),
      (
        'a key typing a letter then DEL over a cross row selection leaves the range',
        'q\u007F',
        false,
      ),
      (
        'a key typing DEL then a letter over a cross row selection leaves the range',
        '\u007Fq',
        false,
      ),
    ];
    for (final (name, character, types) in characters) {
      testWidgets(name, (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        final handled = await tester.sendKeyDownEvent(
          LogicalKeyboardKey.keyQ,
          platform: 'macos',
          character: character,
        );
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ, platform: 'macos');
        await tester.pump();

        expect(handled, isFalse);
        if (types) {
          expect(segmentEditingAt(tester, 0).text, 'para\n- ad');
          expect(body.changes, ['para\n- ad']);
        } else {
          expect(segmentEditingAt(tester, 0).text, wi171Text);
          expect(segmentEditingAt(tester, 0).selection, wi171Across);
          expect(body.changes, isEmpty);
        }
      }, variant: macOnly);
    }

    final chords = <(String, LogicalKeyboardKey)>[
      (
        'Control with a letter over a cross row selection leaves the range',
        LogicalKeyboardKey.controlLeft,
      ),
      (
        'Cmd with a letter over a cross row selection leaves the range',
        LogicalKeyboardKey.metaLeft,
      ),
    ];
    for (final (name, modifier) in chords) {
      testWidgets(name, (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);

        await tester.macHolding([modifier], () async {
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyQ,
            platform: 'macos',
            character: 'q',
          );
          await tester.pump();
          await tester.sendKeyUpEvent(
            LogicalKeyboardKey.keyQ,
            platform: 'macos',
          );
        });

        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(body.changes, isEmpty);
      }, variant: macOnly);
    }

    testWidgets('Cmd+X on a selection within one row is left to the field', (
      tester,
    ) async {
      final clip = MacClipboard.install(tester, initial: 'old');
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(
        tester,
        focus: 1,
        selection: const TextSelection(baseOffset: 7, extentOffset: 9),
      );

      await tester.macCmdChord(LogicalKeyboardKey.keyX);
      await tester.pump();

      expect(clip.text, 'ab');
      expect(segmentEditingAt(tester, 0).text, 'para\n- \n- cd');
      expect(body.changes, ['para\n- \n- cd']);
      expect(segmentEditingAt(tester, 0).focusedRow, 1);
    }, variant: macOnly);

    testWidgets('Cmd+V on a selection within one row is left to the field', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'Q');
      final body = await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(
        tester,
        focus: 1,
        selection: const TextSelection(baseOffset: 7, extentOffset: 9),
      );

      await tester.macCmdChord(LogicalKeyboardKey.keyV);
      await tester.pump();

      expect(segmentEditingAt(tester, 0).text, 'para\n- Q\n- cd');
      expect(body.changes, ['para\n- Q\n- cd']);
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 8),
      );
    }, variant: macOnly);

    Future<void> openMenu(WidgetTester tester) async {
      await wi171RightClick(tester, wi171GlyphCenter(tester, 0, 12));
      expect(wi171MenuButton('Cut'), findsOneWidget);
    }

    testWidgets('the cross row menu closes when the segment text changes', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X');
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      wi171View(tester, 0).applyEdit(
        const SegmentEdit(
          start: 0,
          end: 0,
          replacement: 'w',
          selection: SegmentSelection.collapsed(1),
        ),
      );
      await tester.pumpAndSettle();

      expect(segmentEditingAt(tester, 0).text, 'w$wi171Text');
      expect(wi171MenuButton('Cut'), findsNothing);
      expect(wi171MenuButton('Select All'), findsNothing);
    }, variant: macOnly);

    testWidgets('the cross row menu closes when focus leaves the segment', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X');
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();

      expect(wi171MenuButton('Cut'), findsNothing);
      expect(wi171MenuButton('Select All'), findsNothing);
    }, variant: macOnly);

    testWidgets('the cross row menu closes when the segment goes away', (
      tester,
    ) async {
      MacClipboard.install(tester, initial: 'X');
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await openMenu(tester);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();

      expect(wi171MenuButton('Cut'), findsNothing);
      expect(wi171MenuButton('Select All'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: macOnly);
  });
}
