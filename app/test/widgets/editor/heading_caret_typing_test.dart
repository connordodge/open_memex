// WI #64 (53-T, Spec #57 Req 1-4, TD 1-2, "Typing tests"): on a heading
// line that another line follows in the same prose row, the caret after a
// trailing space is drawn right after that space, not on the last letter.
//
// Everything here is measured in the real segmented editor (`wi171Pump`), so
// the theme's even leading and the controller strut apply (run 20261102-221
// lesson). The oracle is the focused field's own laid-out text: the caret
// rect `RenderEditable.getLocalRectForCaret` at the selection must sit on
// the trailing edge of the just-typed character's box from the same
// editable's `getBoxesForSelection`, never a hard-coded x.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/wi171_segment_harness.dart';

/// Heading levels with the line heights the design pins (row_geometry.dart
/// `lineHeight`: H1 40, H2 34, H3 28.5, H4-H6 22.95).
const List<(int, double)> _wi64Levels = [
  (1, 40),
  (2, 34),
  (3, 28.5),
  (4, 22.95),
  (5, 22.95),
  (6, 22.95),
];

/// The body line height (13.5 x 1.7).
const double _wi64BodyLine = 22.95;

/// How far the caret may sit from the oracle edge: the caret rect is snapped
/// to the device pixel grid (about 0.17 px off a body glyph edge in the test
/// font). The defect is a whole glyph (11 px or more).
const double _wi64CaretTolerance = 0.5;

/// Laid-out line heights round to within a few hundredths of a pixel.
const double _wi64HeightTolerance = 0.05;

/// The focused row field's render object.
RenderEditable _wi64Editable() {
  final context = FocusManager.instance.primaryFocus?.context;
  final editable = context == null
      ? null
      : context is StatefulElement && context.state is EditableTextState
      ? context.state as EditableTextState
      : context.findAncestorStateOfType<EditableTextState>();
  if (editable == null) throw TestFailure('no text field has focus');
  return editable.renderEditable;
}

/// The logical key that types [ch]: `#` is Shift+3 on a US layout, a space
/// is the space bar, a lowercase letter its own key.
LogicalKeyboardKey _wi64KeyFor(String ch) => switch (ch) {
  '#' => LogicalKeyboardKey.digit3,
  ' ' => LogicalKeyboardKey.space,
  _ =>
    LogicalKeyboardKey.findKeyByKeyId(ch.toLowerCase().codeUnitAt(0)) ??
        (throw ArgumentError('no key for $ch')),
};

/// Types [ch] as macOS delivers it (as `wi171TypeKey` does, plus Shift for
/// `#`): the key down event first, then the text input inserts [ch] at the
/// focused field's selection, then the key goes up.
Future<void> _wi64Type(WidgetTester tester, String ch) async {
  final shifted = ch == '#';
  final key = _wi64KeyFor(ch);
  if (shifted) {
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.shiftLeft,
      platform: 'macos',
    );
  }
  await tester.sendKeyDownEvent(key, platform: 'macos', character: ch);
  await tester.pump();
  final value = wi171FocusedController().value;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  await tester.macEditingValue(
    value.text.replaceRange(selection.start, selection.end, ch),
    selection: TextSelection.collapsed(offset: selection.start + ch.length),
  );
  await tester.sendKeyUpEvent(key, platform: 'macos');
  if (shifted) {
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.shiftLeft,
      platform: 'macos',
    );
  }
  await tester.pump();
}

/// The x of the caret the focused field draws for its selection.
double _wi64CaretX(RenderEditable editable) {
  final selection = editable.selection;
  if (selection == null || !selection.isValid || !selection.isCollapsed) {
    throw TestFailure('the field shows no caret ($selection)');
  }
  return editable.getLocalRectForCaret(selection.extent).left;
}

/// The trailing (right) edge of the glyph of the code unit just before
/// [offset], from [editable]'s own laid-out text.
double _wi64TrailingEdge(RenderEditable editable, int offset) {
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: offset - 1, extentOffset: offset),
  )..sort((a, b) => a.left.compareTo(b.left));
  if (boxes.isEmpty) throw TestFailure('no box for code unit ${offset - 1}');
  return boxes.first.right;
}

/// The leading (left) edge of the glyph of the code unit at [offset].
double _wi64LeadingEdge(RenderEditable editable, int offset) {
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: offset + 1),
  )..sort((a, b) => a.left.compareTo(b.left));
  if (boxes.isEmpty) throw TestFailure('no box for code unit $offset');
  return boxes.first.left;
}

/// The laid-out width of `[start, end)` (inside one line) in [editable]:
/// from the leading edge of its first glyph to the trailing edge of its
/// last.
double _wi64Width(RenderEditable editable, int start, int end) =>
    _wi64TrailingEdge(editable, end) - _wi64LeadingEdge(editable, start);

/// The width [chars] take as plain mono text at [size].
double _wi64NormalWidth(String chars, double size) {
  final painter = TextPainter(
    text: TextSpan(
      text: chars,
      style: OmType.mono(size: size),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Shows [text] for a printed reason (`\r` and `\n` spelled out).
String _wi64Show(String text) =>
    text.replaceAll('\r', r'\r').replaceAll('\n', r'\n');

/// The caret the focused field draws sits on the trailing edge of the
/// code unit just before it. Returns the caret x.
double _wi64ExpectCaretAfterTyped(String why) {
  final ctrl = wi171FocusedController();
  final editable = _wi64Editable();
  final offset = ctrl.selection.baseOffset;
  expect(offset, greaterThan(0), reason: '$why: a character was typed');
  final caret = _wi64CaretX(editable);
  final edge = _wi64TrailingEdge(editable, offset);
  expect(
    caret,
    closeTo(edge, _wi64CaretTolerance),
    reason:
        '$why: caret at $offset of "${_wi64Show(ctrl.text)}" is drawn on the '
        'trailing edge of "${_wi64Show(ctrl.text[offset - 1])}"',
  );
  return caret;
}

/// Pumps a fresh editor holding [text] (the previous tree torn down first,
/// so no row state carries over) and focuses its first row with the caret
/// at row-local [local].
Future<void> _wi64PumpFocused(
  WidgetTester tester,
  String text, {
  required int local,
}) async {
  await tester.pumpWidget(const SizedBox());
  await wi171Pump(tester, text);
  expect(wi171RowKeys(0), 1, reason: '"${_wi64Show(text)}" is one prose row');
  await wi171FocusRow(tester, 0, 0, local: local);
  expect(wi171Ctrl(tester, 0, 0).text, text, reason: 'the row holds the text');
}

/// Types [keys] one by one; after every keystroke the caret sits right after
/// the typed character. After every typed space the caret is strictly right
/// of the character before that space in the same layout, and, except for
/// the keystroke at [markerSpace] (the space that turns `#`s into a heading
/// marker and so resizes the line), strictly right of where it was drawn
/// before the space.
Future<void> _wi64TypeAndCheck(
  WidgetTester tester,
  List<String> keys,
  String why, {
  int? markerSpace,
}) async {
  var before = _wi64CaretX(_wi64Editable());
  for (final (i, ch) in keys.indexed) {
    await _wi64Type(tester, ch);
    final step = '$why, keystroke $i "${_wi64Show(ch)}"';
    final after = _wi64ExpectCaretAfterTyped(step);
    if (ch == ' ') {
      final offset = wi171FocusedController().selection.baseOffset;
      expect(
        after,
        greaterThan(_wi64TrailingEdge(_wi64Editable(), offset - 1) + 1),
        reason: '$step: the caret is right of the character before the space',
      );
      if (i != markerSpace) {
        expect(
          after,
          greaterThan(before),
          reason: '$step: the caret moves right across the typed space',
        );
      }
    }
    before = after;
  }
}

/// `#`×[level], a space, a word, a space, a second word, then two spaces
/// (Spec #57 "Typing tests").
List<String> _wi64HeadingKeys(int level) => [
  for (var i = 0; i < level; i++) '#',
  ' ',
  'h',
  'i',
  ' ',
  'y',
  'o',
  ' ',
  ' ',
];

/// The AC9 cases (`# `, `## Hello world `, `###### a b `) typed above an
/// existing line, for both terminators and from the row start and a row
/// middle. Used by the bundled-font test in
/// `heading_caret_typing_real_font_test.dart`, which lays the text out in
/// the shipped JetBrains Mono instead of the test font.
Future<void> wi64TypeAc9Cases(WidgetTester tester) async {
  for (final (hashes, rest) in [(1, ''), (2, 'Hello world '), (6, 'a b ')]) {
    for (final (before, after) in [
      ('', '\nbody'),
      ('', '\r\nbody'),
      ('top\n', '\nend'),
      ('top\r\n', '\r\nend'),
    ]) {
      final why = '${'#' * hashes} "$rest" in "${_wi64Show('$before|$after')}"';
      await _wi64PumpFocused(tester, '$before$after', local: before.length);
      await _wi64TypeAndCheck(
        tester,
        [for (var i = 0; i < hashes; i++) '#', ' ', ...rest.split('')],
        why,
        markerSpace: hashes,
      );
      expect(
        wi171FocusedController().text,
        '$before${'#' * hashes} $rest$after',
        reason: '$why: typed',
      );
    }
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'typing the hashes then a space on a heading line above another line draws the caret right after the space at every level',
    (tester) async {
      for (final (level, _) in _wi64Levels) {
        for (final terminator in ['\n', '\r\n']) {
          final why = 'H$level above a "${_wi64Show(terminator)}" terminator';
          await _wi64PumpFocused(tester, '${terminator}body', local: 0);
          for (var i = 0; i < level; i++) {
            await _wi64Type(tester, '#');
          }
          _wi64ExpectCaretAfterTyped('$why after the hashes');
          await _wi64Type(tester, ' ');
          final ctrl = wi171FocusedController();
          expect(
            ctrl.text,
            '${'#' * level} ${terminator}body',
            reason: '$why: typed',
          );
          expect(ctrl.selection, TextSelection.collapsed(offset: level + 1));
          final after = _wi64ExpectCaretAfterTyped('$why after the space');
          // The marker shows at the line's size (its normal width there), and
          // the caret is right of the last hash in that same layout.
          final editable = _wi64Editable();
          expect(
            after,
            greaterThan(_wi64TrailingEdge(editable, level) + 1),
            reason: '$why: the caret is right of the last hash',
          );
          final size = headingFontSize(level);
          expect(
            _wi64Width(editable, 0, level + 1),
            closeTo(
              _wi64NormalWidth('${'#' * level} ', size),
              _wi64CaretTolerance,
            ),
            reason: '$why: the revealed marker at the line size $size',
          );
          expect(
            after,
            closeTo(
              _wi64LeadingEdge(editable, 0) +
                  _wi64NormalWidth('${'#' * level} ', size),
              _wi64CaretTolerance,
            ),
            reason: '$why: the caret is one marker width from the line start',
          );
        }
      }
    },
  );

  testWidgets(
    'typing a heading word by word above another line draws the caret after every typed character and further right after each space at every level',
    (tester) async {
      for (final (level, _) in _wi64Levels) {
        // The heading line opens the row, then a line in the middle of it.
        for (final (before, after) in [('', '\nbody'), ('top\n', '\nend')]) {
          final why = 'H$level in "${_wi64Show('$before|$after')}"';
          await _wi64PumpFocused(tester, '$before$after', local: before.length);
          await _wi64TypeAndCheck(
            tester,
            _wi64HeadingKeys(level),
            why,
            markerSpace: level,
          );
          expect(
            wi171FocusedController().text,
            '$before${'#' * level} hi yo  $after',
            reason: '$why: typed',
          );
        }
      }
    },
  );

  testWidgets(
    'typing a heading word by word above a CRLF terminator draws the caret after every typed character and further right after each space at every level',
    (tester) async {
      for (final (level, _) in _wi64Levels) {
        for (final (before, after) in [
          ('', '\r\nbody'),
          ('top\r\n', '\r\nend'),
        ]) {
          final why = 'H$level in "${_wi64Show('$before|$after')}"';
          await _wi64PumpFocused(tester, '$before$after', local: before.length);
          await _wi64TypeAndCheck(
            tester,
            _wi64HeadingKeys(level),
            why,
            markerSpace: level,
          );
          expect(
            wi171FocusedController().text,
            '$before${'#' * level} hi yo  $after',
            reason: '$why: typed',
          );
        }
      }
    },
  );

  testWidgets(
    'a caret put after a heading lines trailing spaces by moving to the line end by Right or by setting the selection is drawn after the spaces',
    (tester) async {
      for (final (level, _) in _wi64Levels) {
        for (final terminator in ['\n', '\r\n']) {
          final head = '${'#' * level} hi  ';
          final text = '$head${terminator}body';
          final end = head.length;
          final why = 'H$level "${_wi64Show(text)}"';
          // Each way the caret can reach the offset after the spaces.
          for (final (way, move) in <(String, Future<void> Function())>[
            // Cmd+Right (macOS sends the line end selector). Flutter puts
            // that caret between `\r` and `\n` on a CRLF line (keyboard
            // movement is unchanged by Spec #57), so only after `\n`.
            if (terminator == '\n')
              (
                'the line end selector',
                () => tester.macSelector('moveToRightEndOfLine:'),
              ),
            (
              'Right from before the last space',
              () async {
                wi171FocusedController().selection = TextSelection.collapsed(
                  offset: end - 1,
                );
                await tester.pump();
                await tester.macSelector('moveRight:');
              },
            ),
            (
              'setting the selection',
              () async {
                wi171FocusedController().selection = TextSelection.collapsed(
                  offset: end,
                );
                await tester.pump();
              },
            ),
          ]) {
            final at = '$why by $way';
            // The caret starts on the heading line, so its marker shows.
            await _wi64PumpFocused(tester, text, local: level + 1);
            await move();
            expect(
              wi171FocusedController().selection.baseOffset,
              end,
              reason: '$at: the caret is after the spaces',
            );
            final editable = _wi64Editable();
            final caret = _wi64CaretX(editable);
            expect(
              caret,
              closeTo(_wi64TrailingEdge(editable, end), _wi64CaretTolerance),
              reason: '$at: drawn on the last space trailing edge',
            );
            expect(
              caret,
              greaterThan(_wi64TrailingEdge(editable, end - 1) + 1),
              reason: '$at: drawn right of the first trailing space',
            );
          }
        }
      }
    },
  );

  testWidgets(
    'a heading line that ends the field text draws the caret after every typed character and further right after each space at every level',
    (tester) async {
      for (final (level, _) in _wi64Levels) {
        for (final before in ['', 'top\n', 'top\r\n']) {
          final why = 'H$level at the end of "${_wi64Show(before)}"';
          await _wi64PumpFocused(tester, before, local: before.length);
          await _wi64TypeAndCheck(
            tester,
            _wi64HeadingKeys(level),
            why,
            markerSpace: level,
          );
          expect(
            wi171FocusedController().text,
            '$before${'#' * level} hi yo  ',
            reason: '$why: typed',
          );
        }
      }
    },
  );

  testWidgets(
    'a body line above another line draws the caret right after each typed trailing space',
    (tester) async {
      for (final (before, after) in [
        ('', '\nbody'),
        ('', '\r\nbody'),
        ('top\n', '\nend'),
        ('# top\n', '\nend'),
      ]) {
        final why = 'body line in "${_wi64Show('$before|$after')}"';
        await _wi64PumpFocused(tester, '$before$after', local: before.length);
        await _wi64TypeAndCheck(tester, [
          'h',
          'i',
          ' ',
          'y',
          'o',
          ' ',
          ' ',
        ], why);
        expect(
          wi171FocusedController().text,
          '${before}hi yo  $after',
          reason: '$why: typed',
        );
      }
    },
  );

  testWidgets(
    'heading lines with trailing spaces before a terminator keep their line heights revealed marker widths and zero width hidden markers',
    (tester) async {
      for (final (level, height) in _wi64Levels) {
        final hashes = '#' * level;
        final size = headingFontSize(level);
        // (text, heading marker start, heading line end,
        // expected line heights revealed, expected line heights hidden).
        for (final (text, start, end, revealed, hidden) in [
          (
            '$hashes hi  \nbody',
            0,
            level + 5,
            [height, _wi64BodyLine],
            [height, _wi64BodyLine],
          ),
          (
            '$hashes hi  \r\nbody',
            0,
            level + 5,
            [height, _wi64BodyLine],
            [height, _wi64BodyLine],
          ),
          // A blank line after the heading keeps the body line height.
          (
            '$hashes hi \n\nbody',
            0,
            level + 4,
            [height, _wi64BodyLine, _wi64BodyLine],
            [height, _wi64BodyLine, _wi64BodyLine],
          ),
          (
            'top\n$hashes hi \nend',
            4,
            4 + level + 4,
            [_wi64BodyLine, height, _wi64BodyLine],
            [_wi64BodyLine, height, _wi64BodyLine],
          ),
          // An empty heading: its line takes the heading height only while
          // its marker shows (as on main; a hidden marker is zero size).
          (
            '$hashes \nbody',
            0,
            level + 1,
            [height, _wi64BodyLine],
            [_wi64BodyLine, _wi64BodyLine],
          ),
          (
            '$hashes \r\nbody',
            0,
            level + 1,
            [height, _wi64BodyLine],
            [_wi64BodyLine, _wi64BodyLine],
          ),
        ]) {
          // Revealed: the caret after the heading's trailing spaces;
          // selected: a range from the marker across the terminator to the
          // text end (selected styling); hidden: the caret at the text end.
          for (final (state, selection) in [
            ('revealed', TextSelection.collapsed(offset: end)),
            (
              'selected',
              TextSelection(baseOffset: start, extentOffset: text.length),
            ),
            ('hidden', TextSelection.collapsed(offset: text.length)),
          ]) {
            final shown = state != 'hidden';
            final why = 'H$level "${_wi64Show(text)}" $state';
            await _wi64PumpFocused(tester, text, local: text.length);
            wi171FocusedController().selection = selection;
            await tester.pump();
            final editable = _wi64Editable();
            final heights = [
              for (final l in RenderEditableLineBoxes(editable).lines)
                l.bottom - l.top,
            ];
            final expected = shown ? revealed : hidden;
            expect(heights, hasLength(expected.length), reason: why);
            for (final (i, h) in heights.indexed) {
              expect(
                h,
                closeTo(expected[i], _wi64HeightTolerance),
                reason: '$why: line $i of $heights',
              );
            }
            final marker = (start, start + level + 1);
            if (shown) {
              expect(
                _wi64Width(editable, marker.$1, marker.$2),
                closeTo(
                  _wi64NormalWidth('$hashes ', size),
                  _wi64CaretTolerance,
                ),
                reason: '$why: the marker at the line size $size',
              );
            } else {
              // Hidden code units lay out no box wider than zero, and the
              // line's text starts at the line start like a body line's.
              final boxes = editable.getBoxesForSelection(
                TextSelection(baseOffset: marker.$1, extentOffset: marker.$2),
              );
              for (final b in boxes) {
                expect(
                  b.right - b.left,
                  lessThan(0.01),
                  reason: '$why: marker hidden',
                );
              }
              if (end > marker.$2) {
                final bodyStart = text.lastIndexOf('\n') + 1;
                expect(
                  _wi64LeadingEdge(editable, marker.$2),
                  closeTo(
                    _wi64LeadingEdge(editable, bodyStart),
                    _wi64CaretTolerance,
                  ),
                  reason: '$why: the hidden marker takes no width',
                );
              }
            }
          }
        }
      }
    },
  );
}
