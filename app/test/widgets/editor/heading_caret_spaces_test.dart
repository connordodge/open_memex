// WI #90 (53-T2, Spec #57 Req 1-4, TD 1-2, "Typing tests"): on a revealed
// heading line with two or more spaces after the hashes and no word yet
// (`#  `), the caret is drawn right after the last typed space. On the base
// the first space sits in the marker run and the following spaces in a
// whitespace-only text run, and their laid-out boxes overlap: the caret
// after the second space is drawn where the first space ends, one space too
// far left, even at the end of the text.
//
// Everything is measured in the real segmented editor (`wi171Pump`), so the
// theme's even leading and the controller strut apply (run 20261102-221
// lesson). Two oracles, both from the focused field's own layout:
// - the caret rect `RenderEditable.getLocalRectForCaret` at the selection
//   sits on the trailing edge of the just-typed code unit's leftmost box
//   (`getBoxesForSelection([offset-1, offset))`), as in #64's typing test;
// - because overlapping boxes fool that oracle (the second space's box is
//   reported where the first space's is), the caret also sits one normal
//   width of the line's text so far from the line's own leading edge, and
//   strictly right of the first space's trailing edge in the same layout.
//   The editor face is monospaced (the test font draws every glyph a full
//   em wide at any weight), so that width is the mono width at the line's
//   size.
// Helpers are copied from #64's `heading_caret_typing_test.dart` with a
// `_wi90` prefix (no shared test-support edits).
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
const List<(int, double)> _wi90Levels = [
  (1, 40),
  (2, 34),
  (3, 28.5),
  (4, 22.95),
  (5, 22.95),
  (6, 22.95),
];

/// The body line height (13.5 x 1.7).
const double _wi90BodyLine = 22.95;

/// How far the caret may sit from an oracle edge: the caret rect is snapped
/// to the device pixel grid. The defect is a whole space (11 px or more).
const double _wi90CaretTolerance = 0.5;

/// Laid-out line heights round to within a few hundredths of a pixel.
const double _wi90HeightTolerance = 0.05;

/// Where the heading line sits in its prose row: the text before it and
/// the text after it. `''` after = the heading line ends the field text.
const List<(String, String)> _wi90LfPlaces = [
  ('', ''),
  ('top\n', ''),
  ('', '\nbody'),
  ('top\n', '\nend'),
];

/// The same with a `\r\n` terminator around the heading line.
const List<(String, String)> _wi90CrlfPlaces = [
  ('top\r\n', ''),
  ('', '\r\nbody'),
  ('top\r\n', '\r\nend'),
];

/// The focused row field's render object.
RenderEditable _wi90Editable() {
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
LogicalKeyboardKey _wi90KeyFor(String ch) => switch (ch) {
  '#' => LogicalKeyboardKey.digit3,
  ' ' => LogicalKeyboardKey.space,
  _ =>
    LogicalKeyboardKey.findKeyByKeyId(ch.toLowerCase().codeUnitAt(0)) ??
        (throw ArgumentError('no key for $ch')),
};

/// Types [ch] as macOS delivers it (as `wi171TypeKey` does, plus Shift for
/// `#`): the key down event first, then the text input inserts [ch] at the
/// focused field's selection, then the key goes up.
Future<void> _wi90Type(WidgetTester tester, String ch) async {
  final shifted = ch == '#';
  final key = _wi90KeyFor(ch);
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
double _wi90CaretX(RenderEditable editable) {
  final selection = editable.selection;
  if (selection == null || !selection.isValid || !selection.isCollapsed) {
    throw TestFailure('the field shows no caret ($selection)');
  }
  return editable.getLocalRectForCaret(selection.extent).left;
}

/// The trailing (right) edge of the leftmost box of the code unit just
/// before [offset], from [editable]'s own laid-out text.
double _wi90TrailingEdge(RenderEditable editable, int offset) {
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: offset - 1, extentOffset: offset),
  )..sort((a, b) => a.left.compareTo(b.left));
  if (boxes.isEmpty) throw TestFailure('no box for code unit ${offset - 1}');
  return boxes.first.right;
}

/// The leading (left) edge of the glyph of the code unit at [offset].
double _wi90LeadingEdge(RenderEditable editable, int offset) {
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: offset + 1),
  )..sort((a, b) => a.left.compareTo(b.left));
  if (boxes.isEmpty) throw TestFailure('no box for code unit $offset');
  return boxes.first.left;
}

/// The laid-out width of `[start, end)` (inside one line) in [editable]:
/// from the leading edge of its first glyph to the trailing edge of its
/// last.
double _wi90Width(RenderEditable editable, int start, int end) =>
    _wi90TrailingEdge(editable, end) - _wi90LeadingEdge(editable, start);

/// The width [chars] take as plain mono text at [size].
double _wi90NormalWidth(String chars, double size) {
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
String _wi90Show(String text) =>
    text.replaceAll('\r', r'\r').replaceAll('\n', r'\n');

/// Pumps a fresh editor holding [text] (the previous tree torn down first,
/// so no row state carries over) and focuses its first row with the caret
/// at row-local [local].
Future<void> _wi90PumpFocused(
  WidgetTester tester,
  String text, {
  required int local,
}) async {
  await tester.pumpWidget(const SizedBox());
  await wi171Pump(tester, text);
  expect(wi171RowKeys(0), 1, reason: '"${_wi90Show(text)}" is one prose row');
  await wi171FocusRow(tester, 0, 0, local: local);
  expect(wi171Ctrl(tester, 0, 0).text, text, reason: 'the row holds the text');
}

/// Puts the focused field's caret at [offset] by setting the selection.
Future<void> _wi90SetCaret(WidgetTester tester, int offset) async {
  wi171FocusedController().selection = TextSelection.collapsed(offset: offset);
  await tester.pump();
}

/// The caret the focused field draws sits on the trailing edge of the
/// code unit just before it, and, on a heading line of [level] starting at
/// [lineStart] whose marker exists, one normal width of the line's text so
/// far (at the heading size) from the line's leading edge. Returns the
/// caret x.
double _wi90ExpectCaret(String why, {required int lineStart, int? level}) {
  final ctrl = wi171FocusedController();
  final editable = _wi90Editable();
  final offset = ctrl.selection.baseOffset;
  expect(offset, greaterThan(0), reason: '$why: a caret after a character');
  final caret = _wi90CaretX(editable);
  final shown = '"${_wi90Show(ctrl.text)}" at $offset';
  expect(
    caret,
    closeTo(_wi90TrailingEdge(editable, offset), _wi90CaretTolerance),
    reason:
        '$why: caret in $shown is drawn on the trailing edge of '
        '"${_wi90Show(ctrl.text[offset - 1])}"',
  );
  if (level != null) {
    final soFar = ctrl.text.substring(lineStart, offset);
    expect(
      caret,
      closeTo(
        _wi90LeadingEdge(editable, lineStart) +
            _wi90NormalWidth(soFar, headingFontSize(level)),
        _wi90CaretTolerance,
      ),
      reason:
          '$why: caret in $shown is one width of "$soFar" at the '
          'H$level size from the line start',
    );
  }
  return caret;
}

/// The [caret] at [offset] (just after a space) is strictly right of the
/// trailing edge of the code unit before that space in the same layout (on
/// the base, the second space's box overlaps the first's and the caret sits
/// on the first space's edge).
void _wi90ExpectRightOfPrevious(String why, double caret, int offset) {
  final before = _wi90TrailingEdge(_wi90Editable(), offset - 1);
  expect(
    caret,
    greaterThan(before + 1),
    reason:
        '$why: the caret at $offset is right of the code unit before the '
        'space (its trailing edge $before)',
  );
}

/// Types [keys] one by one on a heading line of [level] starting at
/// [lineStart]; after every keystroke the caret sits right after the typed
/// character. Once the marker exists (after the space at [level]), the
/// caret is one normal width of the line so far from the line start. After
/// every space past the first, the caret is strictly right of the code unit
/// before it and of where it was drawn before the space. The marker's own
/// space resizes an H4-H6 line, so it gets only the same-layout checks.
Future<void> _wi90TypeHeading(
  WidgetTester tester,
  List<String> keys,
  String why, {
  required int level,
  required int lineStart,
}) async {
  var before = _wi90CaretX(_wi90Editable());
  for (final (i, ch) in keys.indexed) {
    await _wi90Type(tester, ch);
    final step = '$why, keystroke $i "${_wi90Show(ch)}"';
    final marked = i >= level;
    final after = _wi90ExpectCaret(
      step,
      lineStart: lineStart,
      level: marked ? level : null,
    );
    if (ch == ' ') {
      final offset = wi171FocusedController().selection.baseOffset;
      _wi90ExpectRightOfPrevious(step, after, offset);
      if (i != level) {
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

/// `#`×[level] then [spaces] spaces.
List<String> _wi90HashesThenSpaces(int level, int spaces) => [
  for (var i = 0; i < level; i++) '#',
  for (var i = 0; i < spaces; i++) ' ',
];

/// For every offset from the end of the marker's space to [lineEnd], set
/// as the selection, the caret is one normal width of the line so far from
/// the line start and strictly right of the caret at the offset before.
Future<void> _wi90ExpectEveryOffset(
  WidgetTester tester,
  String why, {
  required int level,
  required int lineStart,
  required int lineEnd,
}) async {
  double? previous;
  for (var o = lineStart + level + 1; o <= lineEnd; o++) {
    await _wi90SetCaret(tester, o);
    final at = '$why, caret set to $o';
    final caret = _wi90ExpectCaret(at, lineStart: lineStart, level: level);
    if (previous != null) {
      _wi90ExpectRightOfPrevious(at, caret, o);
      expect(
        caret,
        greaterThan(previous),
        reason: '$at: right of the caret at ${o - 1}',
      );
    }
    previous = caret;
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'typing the hashes then two spaces on a heading line draws the caret right after the second space at every level at the end of the text and above another line',
    (tester) async {
      for (final (level, _) in _wi90Levels) {
        for (final (before, after) in _wi90LfPlaces) {
          final why = 'H$level in "${_wi90Show('$before|$after')}"';
          await _wi90PumpFocused(tester, '$before$after', local: before.length);
          await _wi90TypeHeading(
            tester,
            _wi90HashesThenSpaces(level, 2),
            why,
            level: level,
            lineStart: before.length,
          );
          final ctrl = wi171FocusedController();
          expect(ctrl.text, '$before${'#' * level}  $after', reason: why);
          expect(
            ctrl.selection,
            TextSelection.collapsed(offset: before.length + level + 2),
            reason: '$why: the caret is after the second space',
          );
        }
      }
    },
  );

  testWidgets(
    'a caret put after the hashes and two spaces of a heading line by the line end selector by Right or by setting the selection is drawn after the second space at every level',
    (tester) async {
      for (final (level, _) in _wi90Levels) {
        for (final (before, after) in _wi90LfPlaces) {
          final head = '${'#' * level}  ';
          final text = '$before$head$after';
          final start = before.length;
          final end = start + head.length;
          final why = 'H$level "${_wi90Show(text)}"';
          for (final (way, move) in <(String, Future<void> Function())>[
            (
              'the line end selector',
              () => tester.macSelector('moveToRightEndOfLine:'),
            ),
            (
              'Right from before the last space',
              () async {
                await _wi90SetCaret(tester, end - 1);
                await tester.macSelector('moveRight:');
              },
            ),
            ('setting the selection', () => _wi90SetCaret(tester, end)),
          ]) {
            final at = '$why by $way';
            // The caret starts on the heading line, so its marker shows.
            await _wi90PumpFocused(tester, text, local: start + level + 1);
            await move();
            expect(
              wi171FocusedController().selection.baseOffset,
              end,
              reason: '$at: the caret is after the spaces',
            );
            final caret = _wi90ExpectCaret(at, lineStart: start, level: level);
            _wi90ExpectRightOfPrevious(at, caret, end);
          }
        }
      }
    },
  );

  testWidgets(
    'typing a third space after the hashes draws the caret right after it and the caret moves right across every space after the first at every level',
    (tester) async {
      for (final (level, _) in _wi90Levels) {
        for (final (before, after) in _wi90LfPlaces) {
          final why = 'H$level in "${_wi90Show('$before|$after')}"';
          final start = before.length;
          await _wi90PumpFocused(tester, '$before$after', local: start);
          await _wi90TypeHeading(
            tester,
            _wi90HashesThenSpaces(level, 3),
            why,
            level: level,
            lineStart: start,
          );
          final end = start + level + 3;
          expect(
            wi171FocusedController().text,
            '$before${'#' * level}   $after',
            reason: why,
          );
          expect(
            wi171FocusedController().selection,
            TextSelection.collapsed(offset: end),
            reason: '$why: the caret is after the third space',
          );
          // The spaces lay out one after another: each starts where the code
          // unit before it ends, none on top of another.
          final editable = _wi90Editable();
          for (var o = start + level + 1; o < end; o++) {
            expect(
              _wi90LeadingEdge(editable, o),
              closeTo(_wi90TrailingEdge(editable, o), _wi90CaretTolerance),
              reason:
                  '$why: the space at $o starts where code unit ${o - 1} ends',
            );
          }
          await _wi90ExpectEveryOffset(
            tester,
            why,
            level: level,
            lineStart: start,
            lineEnd: end,
          );
        }
      }
    },
  );

  testWidgets(
    'on a heading line ending in a CRLF terminator the caret after the hashes and several spaces is drawn after the last space at every level',
    (tester) async {
      for (final (level, _) in _wi90Levels) {
        for (final (before, after) in _wi90CrlfPlaces) {
          final start = before.length;
          // Typed: the hashes then three spaces, above or after a CRLF line.
          final typed = 'H$level typed in "${_wi90Show('$before|$after')}"';
          await _wi90PumpFocused(tester, '$before$after', local: start);
          await _wi90TypeHeading(
            tester,
            _wi90HashesThenSpaces(level, 3),
            typed,
            level: level,
            lineStart: start,
          );
          expect(
            wi171FocusedController().text,
            '$before${'#' * level}   $after',
            reason: typed,
          );
          // Placed: the caret set after two and after three spaces.
          for (final spaces in [2, 3]) {
            final head = '${'#' * level}${' ' * spaces}';
            final text = '$before$head$after';
            final why = 'H$level "${_wi90Show(text)}" caret set';
            await _wi90PumpFocused(tester, text, local: start + level + 1);
            await _wi90ExpectEveryOffset(
              tester,
              why,
              level: level,
              lineStart: start,
              lineEnd: start + head.length,
            );
          }
        }
      }
    },
  );

  testWidgets(
    'typing a word after the hashes and several spaces draws the caret right after every typed character at every level',
    (tester) async {
      for (final (level, _) in _wi90Levels) {
        for (final (before, after) in [..._wi90LfPlaces, ..._wi90CrlfPlaces]) {
          final why = 'H$level in "${_wi90Show('$before|$after')}"';
          await _wi90PumpFocused(tester, '$before$after', local: before.length);
          await _wi90TypeHeading(
            tester,
            [..._wi90HashesThenSpaces(level, 2), 'h', 'i', ' ', ' ', 'y', 'o'],
            why,
            level: level,
            lineStart: before.length,
          );
          expect(
            wi171FocusedController().text,
            '$before${'#' * level}  hi  yo$after',
            reason: why,
          );
        }
      }
    },
  );

  testWidgets(
    'heading lines of hashes and several spaces keep their line heights revealed marker widths and zero width hidden markers',
    (tester) async {
      for (final (level, height) in _wi90Levels) {
        final hashes = '#' * level;
        final size = headingFontSize(level);
        // (text, heading line start, heading line content end, expected
        // line heights revealed, expected line heights hidden). The spaces
        // after the marker stay shown at the heading size when the marker
        // hides, so the line keeps the heading height (as on the base).
        for (final (text, start, end, revealed, hidden) in [
          (
            '$hashes  \nbody',
            0,
            level + 2,
            [height, _wi90BodyLine],
            [height, _wi90BodyLine],
          ),
          (
            '$hashes   \r\nbody',
            0,
            level + 3,
            [height, _wi90BodyLine],
            [height, _wi90BodyLine],
          ),
          (
            'top\n$hashes  \nend',
            4,
            4 + level + 2,
            [_wi90BodyLine, height, _wi90BodyLine],
            [_wi90BodyLine, height, _wi90BodyLine],
          ),
          (
            'top\n$hashes   ',
            4,
            4 + level + 3,
            [_wi90BodyLine, height],
            [_wi90BodyLine, height],
          ),
          // A blank line after the heading keeps the body line height.
          (
            '$hashes  \n\nbody',
            0,
            level + 2,
            [height, _wi90BodyLine, _wi90BodyLine],
            [height, _wi90BodyLine, _wi90BodyLine],
          ),
        ]) {
          // Revealed: the caret after the spaces; selected: a range from the
          // marker to the text end; hidden: the caret on another line.
          final elsewhere = start == 0 ? text.length : 0;
          for (final (state, selection) in [
            ('revealed', TextSelection.collapsed(offset: end)),
            (
              'selected',
              TextSelection(baseOffset: start, extentOffset: text.length),
            ),
            ('hidden', TextSelection.collapsed(offset: elsewhere)),
          ]) {
            final shown = state != 'hidden';
            final why = 'H$level "${_wi90Show(text)}" $state';
            await _wi90PumpFocused(tester, text, local: elsewhere);
            wi171FocusedController().selection = selection;
            await tester.pump();
            final editable = _wi90Editable();
            final heights = [
              for (final l in RenderEditableLineBoxes(editable).lines)
                l.bottom - l.top,
            ];
            final expected = shown ? revealed : hidden;
            expect(heights, hasLength(expected.length), reason: why);
            for (final (i, h) in heights.indexed) {
              expect(
                h,
                closeTo(expected[i], _wi90HeightTolerance),
                reason: '$why: line $i of $heights',
              );
            }
            final marker = (start, start + level + 1);
            if (shown) {
              expect(
                _wi90Width(editable, marker.$1, marker.$2),
                closeTo(
                  _wi90NormalWidth('$hashes ', size),
                  _wi90CaretTolerance,
                ),
                reason: '$why: the marker at the line size $size',
              );
            } else {
              // Hidden code units lay out no box wider than zero, and the
              // spaces after them start at the line start like a body line.
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
              final otherLine = start == 0 ? text.lastIndexOf('\n') + 1 : 0;
              expect(
                _wi90LeadingEdge(editable, marker.$2),
                closeTo(
                  _wi90LeadingEdge(editable, otherLine),
                  _wi90CaretTolerance,
                ),
                reason: '$why: the hidden marker takes no width',
              );
              expect(
                _wi90Width(editable, marker.$2, end),
                closeTo(
                  _wi90NormalWidth(' ' * (end - marker.$2), size),
                  _wi90CaretTolerance,
                ),
                reason: '$why: the spaces after the hidden marker stay shown',
              );
            }
          }
        }
      }
    },
  );
}
