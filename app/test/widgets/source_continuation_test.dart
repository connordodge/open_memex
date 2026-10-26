// WI #162 (A3): list continuation in Source mode (Spec #157 R8, R14, R15
// IME rule, R30, R31; rulings D15, D17). Source mode is the plain mono
// `editor-source-surface`; continuation is an ancestor key handler around
// its body field, so the `[[` popover and the IME keep their keys.
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

TextEditingController _ctrl(SegmentedEditorRobot r) =>
    r.tester.widget<EditableText>(r.sourceBody).controller;

/// Presses Enter (Shift+Enter with [shift]) as macOS delivers it: the key
/// event reaches Flutter first; when nothing handles it, the text input
/// system inserts a plain newline over the selection. Returns whether
/// Flutter handled the key.
Future<bool> _pressEnter(
  SegmentedEditorRobot r, {
  bool shift = false,
  bool platformNewline = true,
}) async {
  final tester = r.tester;
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  if (!handled && platformNewline) {
    final value = _ctrl(r).value;
    final sel = value.selection;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(sel.start, sel.end, '\n'),
        selection: TextSelection.collapsed(offset: sel.start + 1),
      ),
    );
    await tester.pump();
  }
  return handled;
}

void main() {
  testWidgets(
    'Source mode Enter at the end of a bullet continues it then Enter again ends the list and Shift Enter is a plain newline',
    (tester) async {
      final r = await _openSource(tester, '- a');

      await _pressEnter(r);
      expect(r.sourceText, '- a\n- ');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 6));

      await _pressEnter(r);
      expect(r.sourceText, '- a\n');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 4));

      // Shift+Enter after `- a`: a plain newline, no marker.
      await tester.enterText(r.sourceBody, '- a');
      await tester.pump();
      _ctrl(r).selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await _pressEnter(r, shift: true);
      expect(r.sourceText, '- a\n');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 4));
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode continuation splits at the caret numbers tasks and keeps CRLF',
    (tester) async {
      final r = await _openSource(tester, 'x\r\n  9. ab\r\n- [x] t', caret: 9);
      await _pressEnter(r);
      expect(r.sourceText, 'x\r\n  9. a\r\n  10. b\r\n- [x] t');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 17));

      _ctrl(r).selection = TextSelection.collapsed(offset: r.sourceText.length);
      await tester.pump();
      await _pressEnter(r);
      expect(r.sourceText, 'x\r\n  9. a\r\n  10. b\r\n- [x] t\n- [ ] ');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Enter on quote and fenced lines is a plain newline',
    (tester) async {
      final r = await _openSource(tester, '> q\n```\n- c\n```');
      _ctrl(r).selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await _pressEnter(r);
      expect(r.sourceText, '> q\n\n```\n- c\n```');

      _ctrl(r).selection = const TextSelection.collapsed(offset: 12);
      await tester.pump();
      await _pressEnter(r);
      expect(r.sourceText, '> q\n\n```\n- c\n\n```');
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Enter replaces a selection with the newline then continues and saves the result',
    (tester) async {
      final r = await _openSource(tester, '- abcd');
      _ctrl(r).selection = const TextSelection(baseOffset: 3, extentOffset: 5);
      await tester.pump();
      await _pressEnter(r);
      expect(r.sourceText, '- a\n- d');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 6));
      await r.waitForSave();
      expect(
        r.updates.last.stdinBody,
        '- a\n- d',
        reason: 'the continuation is reported through onContentChanged',
      );
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode continuation is one controller value change and one undo step',
    (tester) async {
      final r = await _openSource(tester, '- a');
      // Let the undo history record the opening value.
      await tester.pump(const Duration(milliseconds: 600));

      final values = <TextEditingValue>[];
      final ctrl = _ctrl(r);
      void record() => values.add(ctrl.value);
      ctrl.addListener(record);
      final handled = await _pressEnter(r);
      ctrl.removeListener(record);
      expect(handled, isTrue, reason: 'the continuation handles Enter');
      expect(values, hasLength(1), reason: 'one value change: $values');
      expect(values.single.text, '- a\n- ');
      expect(values.single.selection, const TextSelection.collapsed(offset: 6));

      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(r.sourceText, '- a', reason: 'one Cmd+Z undoes the continuation');
      expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 3));
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets(
    'Source mode Enter with the wikilink popover open accepts the suggestion without continuing the list',
    (tester) async {
      final r = await _openSource(tester, '- a');
      await tester.enterText(r.sourceBody, '- see [[Zet');
      await pumpFrames(tester);
      expect(r.popover, findsOneWidget, reason: 'the popover is open');

      final handled = await _pressEnter(r, platformNewline: false);
      await pumpFrames(tester);
      expect(handled, isTrue);
      expect(r.sourceText, '- see [[Zeta Game]]');
      expect(r.popover, findsNothing);
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets('Source mode Enter while composing makes no continuation edit', (
    tester,
  ) async {
    final r = await _openSource(tester, '- a');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '- ak',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 3, end: 4),
      ),
    );
    await tester.pump();
    expect(_ctrl(r).value.composing, const TextRange(start: 3, end: 4));

    final handled = await _pressEnter(r, platformNewline: false);
    expect(handled, isFalse, reason: 'Enter goes to the IME');
    expect(r.sourceText, '- ak');

    final shifted = await _pressEnter(r, shift: true, platformNewline: false);
    expect(shifted, isFalse, reason: 'Shift+Enter goes to the IME');
    expect(r.sourceText, '- ak');
    await r.waitForSave();
  }, variant: _mac);

  testWidgets('Source mode NumpadEnter continues a list line like Enter', (
    tester,
  ) async {
    final r = await _openSource(tester, '- a');
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(handled, isTrue);
    expect(r.sourceText, '- a\n- ');
    expect(_ctrl(r).selection, const TextSelection.collapsed(offset: 6));
    await r.waitForSave();
  }, variant: _mac);

  testWidgets(
    'Source mode Enter with Cmd Ctrl or Alt held makes no continuation edit',
    (tester) async {
      final r = await _openSource(tester, '- a');
      for (final modifier in const [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ]) {
        _ctrl(r).selection = const TextSelection.collapsed(offset: 3);
        await tester.pump();
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(r.sourceText, '- a', reason: '${modifier.keyLabel}+Enter');
      }
      await r.waitForSave();
    },
    variant: _mac,
  );

  testWidgets('Source mode keys other than Enter make no continuation edit', (
    tester,
  ) async {
    final r = await _openSource(tester, '- a');
    for (final key in const [
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.f5,
    ]) {
      _ctrl(r).selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(r.sourceText, '- a', reason: key.keyLabel);
    }
    await r.waitForSave();
  }, variant: _mac);

  testWidgets(
    'Source mode renders the body as one plain mono field with every span in the same style',
    (tester) async {
      const body =
          '# Head\n- [x] **done** [[Zeta Game]]\n> q\n1. `c` [l](https://x.y)\n';
      final r = await _openSource(tester, body);
      final editable = tester.widget<EditableText>(r.sourceBody);
      final span = editable.controller.buildTextSpan(
        context: tester.element(r.sourceBody),
        style: editable.style,
        withComposing: false,
      );
      expect(span.toPlainText(), body, reason: 'no hidden or added text');
      final rootStyle = span.style;
      expect(rootStyle, editable.style, reason: 'the field mono style');
      var spans = 0;
      span.visitChildren((child) {
        spans++;
        expect(child, isA<TextSpan>(), reason: 'no WidgetSpan in Source');
        final style = child.style;
        expect(
          style == null || style == rootStyle,
          isTrue,
          reason: 'span ${child.toPlainText()} has style $style',
        );
        return true;
      });
      expect(spans, greaterThan(0));
      await r.waitForSave();
    },
    variant: _mac,
  );
}
