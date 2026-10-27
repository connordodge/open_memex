// WI #196 (Spec #193 R6-R8, R26 Source undo, R29, R30; L7, L10): Tab and
// Shift+Tab on Source-mode list lines. Source mode is the plain mono
// `editor-source-surface`; the Tab branch is an ancestor key handler around
// its body field (next to the Enter continuation), so the `[[` popover and
// the IME keep their keys. `sendKeyEvent` returns whether Flutter handled
// the key: true for a list-line Tab and an R5 edge, false when the default
// Tab applies.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Opens the fixture topic note holding [body] and switches to Source mode,
/// with the body focused and the caret at [caret] (default: the end).
Future<SegmentedEditorRobot> _openSource(
  WidgetTester tester,
  String body, {
  int? caret,
}) async {
  final r = await launchSegmented(
    tester,
    vault: seedSegmentedVault(topicBody: body),
  );
  await r.open(fixtureTopicId);
  await r.toggleSource();
  expect(r.sourceSurface, findsOneWidget);
  expect(r.sourceText, body, reason: 'Source mode shows the saved bytes');
  await tester.showKeyboard(r.sourceBody);
  await tester.pump();
  _ctrl(r).selection = TextSelection.collapsed(offset: caret ?? body.length);
  await tester.pump();
  return r;
}

Finder _sourceEditable(SegmentedEditorRobot r) => find.descendant(
  of: r.sourceBody,
  matching: find.byType(EditableText),
  matchRoot: true,
);

TextEditingController _ctrl(SegmentedEditorRobot r) =>
    r.tester.widget<EditableText>(_sourceEditable(r)).controller;

bool _bodyHasFocus(SegmentedEditorRobot r) =>
    r.tester.widget<EditableText>(_sourceEditable(r)).focusNode.hasFocus;

/// Presses Tab (Shift+Tab with [shift]); returns whether Flutter handled it.
Future<bool> _pressTab(SegmentedEditorRobot r, {bool shift = false}) async {
  final tester = r.tester;
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  return handled;
}

void main() {
  testWidgets(
    'Source mode Tab indents the bullet line from any caret on it in one value change and Shift Tab restores it',
    (tester) async {
      const body = '- a\n- b';
      final r = await _openSource(tester, body);
      // Line `- b` spans offsets 4..7: the line start, the `-`, the text and
      // the line end. The caret stays on the same character.
      for (final caret in const [4, 5, 6, 7]) {
        _ctrl(r).selection = TextSelection.collapsed(offset: caret);
        await tester.pump();

        final values = <TextEditingValue>[];
        final ctrl = _ctrl(r);
        void record() => values.add(ctrl.value);
        ctrl.addListener(record);
        final handled = await _pressTab(r);
        ctrl.removeListener(record);
        expect(handled, isTrue, reason: 'a list-line Tab is handled ($caret)');
        expect(values, hasLength(1), reason: 'one value change at $caret');
        expect(values.single.text, '- a\n  - b', reason: 'indent at $caret');
        expect(
          values.single.selection,
          TextSelection.collapsed(offset: caret + 2),
          reason: 'caret $caret follows its character',
        );

        final outdented = await _pressTab(r, shift: true);
        expect(outdented, isTrue, reason: 'Shift+Tab is handled ($caret)');
        expect(r.sourceText, body, reason: 'Shift+Tab restores ($caret)');
        expect(_ctrl(r).selection, TextSelection.collapsed(offset: caret));
      }
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on a numbered item renumbers the run and saves the result',
    (tester) async {
      final r = await _openSource(tester, '1. a\n2. b\n3. c\n4. d', caret: 14);
      final handled = await _pressTab(r);
      expect(handled, isTrue);
      expect(r.sourceText, '1. a\n2. b\n   1. c\n3. d');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 17));
      await r.waitForSave();
      expect(
        r.updates.last.stdinBody,
        '1. a\n2. b\n   1. c\n3. d',
        reason: 'the indent is reported through onContentChanged',
      );
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on a multi line selection moves every touched item with its subtree',
    (tester) async {
      final r = await _openSource(tester, '- a\n- b\n  - b1\n- c');
      // From inside line `- b` (offset 5) into line `- c` (offset 16).
      _ctrl(r).selection = const TextSelection(baseOffset: 5, extentOffset: 16);
      await tester.pump();
      final handled = await _pressTab(r);
      expect(handled, isTrue);
      expect(r.sourceText, '- a\n  - b\n    - b1\n  - c');
      // The same characters stay selected: `- b`'s space after the dash and
      // `- c`'s space after the dash.
      expect(
        _ctrl(r).selection,
        const TextSelection(baseOffset: 7, extentOffset: 22),
      );
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on the first list item changes no text consumes the key and keeps focus in the body',
    (tester) async {
      final r = await _openSource(tester, '- a\n- b', caret: 3);
      final handled = await _pressTab(r);
      expect(handled, isTrue, reason: 'the R5 edge consumes the key');
      expect(r.sourceText, '- a\n- b');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 3));
      expect(_bodyHasFocus(r), isTrue, reason: 'focus stays in the body');

      final outdented = await _pressTab(r, shift: true);
      expect(outdented, isTrue, reason: 'Shift+Tab at the root is consumed');
      expect(r.sourceText, '- a\n- b');
      expect(_bodyHasFocus(r), isTrue);
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on prose quote and fenced lines is not handled and changes no text',
    (tester) async {
      const body = 'prose\n> quote\n```\n- fenced\n- more\n```\n- a\n- b';
      final r = await _openSource(tester, body);
      // prose line, quote line, both fenced list-looking lines.
      for (final caret in const [2, 8, 22, 31]) {
        _ctrl(r).selection = TextSelection.collapsed(offset: caret);
        await tester.pump();
        final handled = await _pressTab(r);
        expect(handled, isFalse, reason: 'Tab at $caret keeps its default');
        expect(r.sourceText, body, reason: 'no text change at $caret');
        final shifted = await _pressTab(r, shift: true);
        expect(shifted, isFalse, reason: 'Shift+Tab at $caret keeps default');
        expect(r.sourceText, body);
      }
      // Control: the real list after the fence does take Tab.
      _ctrl(r).selection = TextSelection.collapsed(offset: body.length);
      await tester.pump();
      expect(await _pressTab(r), isTrue);
      expect(r.sourceText, '${body.substring(0, body.length - 3)}  - b');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on a list looking line inside frontmatter is not handled and changes no text',
    (tester) async {
      const body = '---\n- a\n- b\n---\n- c\n- d';
      final r = await _openSource(tester, body, caret: 11);
      final handled = await _pressTab(r);
      expect(handled, isFalse, reason: 'frontmatter lines are not list items');
      expect(r.sourceText, body);
      final shifted = await _pressTab(r, shift: true);
      expect(shifted, isFalse);
      expect(r.sourceText, body);
      // Control: the real list after the frontmatter does take Tab.
      _ctrl(r).selection = const TextSelection.collapsed(offset: body.length);
      await tester.pump();
      expect(await _pressTab(r), isTrue);
      expect(r.sourceText, '---\n- a\n- b\n---\n- c\n  - d');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab is one undo step and Cmd Z restores the prior text',
    (tester) async {
      final r = await _openSource(tester, '- a\n- b');
      // Let the undo history record the opening value.
      await tester.pump(const Duration(milliseconds: 600));
      final handled = await _pressTab(r);
      expect(handled, isTrue);
      expect(r.sourceText, '- a\n  - b');

      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(r.sourceText, '- a\n- b', reason: 'one Cmd+Z undoes the indent');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets('Source mode Tab key repeat indents again by one more level', (
    tester,
  ) async {
    final r = await _openSource(tester, '- a\n  - x\n- b');
    final down = await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(down, isTrue);
    expect(r.sourceText, '- a\n  - x\n  - b');

    final repeat = await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(repeat, isTrue, reason: 'a repeat is handled like a key down');
    expect(r.sourceText, '- a\n  - x\n    - b');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await r.waitForSave();
  }, variant: _mac);

  testWidgets('Source mode Tab while composing makes no indentation change', (
    tester,
  ) async {
    final r = await _openSource(tester, '- a\n- b');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '- a\n- bk',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 7, end: 8),
      ),
    );
    await tester.pump();
    expect(_ctrl(r).value.composing, const TextRange(start: 7, end: 8));

    final handled = await _pressTab(r);
    expect(handled, isFalse, reason: 'Tab goes to the IME');
    expect(r.sourceText, '- a\n- bk');
    final shifted = await _pressTab(r, shift: true);
    expect(shifted, isFalse, reason: 'Shift+Tab goes to the IME');
    expect(r.sourceText, '- a\n- bk');
    // Control: once the composing range ends, the same Tab indents, so the
    // checks above pass because of the IME rule and not for lack of a handler.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '- a\n- bk',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump();
    expect(await _pressTab(r), isTrue);
    expect(r.sourceText, '- a\n  - bk');
    await r.waitForSave();
  }, variant: _mac);

  testWidgets(
    'Source mode Tab with the wikilink popover open accepts the suggestion and leaves the indentation',
    (tester) async {
      final r = await _openSource(tester, '- a\n- b');
      await tester.enterText(r.sourceBody, '- a\n- see [[Zet');
      await pumpFrames(tester);
      expect(r.popover, findsOneWidget, reason: 'the popover is open');

      final handled = await _pressTab(r);
      await pumpFrames(tester);
      expect(handled, isTrue);
      expect(r.sourceText, '- a\n- see [[Zeta Game]]');
      expect(r.popover, findsNothing);

      // With the popover closed, the same Tab now indents the line.
      final indented = await _pressTab(r);
      expect(indented, isTrue);
      expect(r.sourceText, '- a\n  - see [[Zeta Game]]');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Cmd Ctrl or Alt held with Tab is not handled and changes no text',
    (tester) async {
      final r = await _openSource(tester, '- a\n- b');
      for (final modifier in const [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(handled, isFalse, reason: '${modifier.keyLabel}+Tab ignored');
        expect(r.sourceText, '- a\n- b', reason: '${modifier.keyLabel}+Tab');
      }
      // The same Tab with no modifier does indent: the lines above only
      // pass because the modifier suppressed it.
      expect(await _pressTab(r), isTrue);
      expect(r.sourceText, '- a\n  - b');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Tab on a task line indents it and keeps the checkbox',
    (tester) async {
      final r = await _openSource(tester, '- [ ] a\n- [x] b');
      final handled = await _pressTab(r);
      expect(handled, isTrue);
      expect(r.sourceText, '- [ ] a\n  - [x] b');
      await r.waitForSave();
    },
    variant: _mac,
  );
}
