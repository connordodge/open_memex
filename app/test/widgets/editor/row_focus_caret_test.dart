// WI #128 post-merge fix (ruling D24, postmerge finding 1 of PR #163): when
// a row an activation asked focus for (`SegmentViewState.activateRow`, the
// pointer layer's click) takes it, the host re-slices the segment selection
// into every row, as it did before #128 for any row taking focus.
//
// The regression: the click sets the segment selection while the row the
// caret leaves still has focus, so that row's field gets no slice (an
// invalid selection) while focused, and `EditableText` puts its caret back
// at its text end. `_onRowFocus` skipped the re-slice for the activating row,
// so that stale end-of-text caret stayed in the row the caret left: a
// revealed table stays revealed with a caret at its end, and a prose row
// keeps a caret it no longer holds.
//
// Every press point comes from the segment's `LineBoxSource`
// (`segmentBoxes()`, D18). Text is synthetic (public repo). Helpers carry the
// `_d24` prefix. Every test runs under macOS.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/table_harness.dart';

/// Row 0: the prose line above the table.
const _d24Intro = 'Intro line';

const _d24Header = '| Step | Notes |';
const _d24Delim = '| --- | --- |';
const _d24Body = '| parser work | see here |';

/// Row 1: the table.
const _d24Table = '$_d24Header\n$_d24Delim\n$_d24Body';

/// Row 2: the prose line below the table.
const _d24Below = 'Below line';

const _d24Text = '$_d24Intro\n$_d24Table\n$_d24Below';

/// The table row's first segment offset.
const _d24TableStart = _d24Intro.length + 1;

/// The segment offset of [needle] in [_d24Text], plus [plus].
int _d24At(String needle, {int plus = 0}) {
  final i = _d24Text.indexOf(needle);
  if (i < 0) throw ArgumentError('$needle is not in the fixture');
  return i + plus;
}

/// Pumps [_d24Text]: rows prose, table, prose, the table rendered.
Future<TableBody> _d24Pump(WidgetTester tester) async {
  final b = await pumpTable(tester, _d24Text);
  expect(
    [for (final r in b.rows()) r.kind],
    const [RowKind.prose, RowKind.table, RowKind.prose],
    reason: 'fixture rows',
  );
  expectTableRendered(0, 1, reason: 'the table starts rendered');
  return b;
}

/// A global point in the left quarter of the glyph at segment [offset], on
/// the layout shown now, so the nearest offset is [offset].
Offset _d24Glyph(TableBody b, int offset) {
  final boxes = b.segmentBoxes();
  final rects = boxes.boxesFor(TextRange(start: offset, end: offset + 1));
  if (rects.isEmpty) throw TestFailure('no glyph rect at $offset');
  final r = rects.first;
  return boxes.box.localToGlobal(
    Offset(r.left + math.min(2.0, r.width / 4), r.center.dy),
  );
}

/// A mouse click at [at], then a pump.
Future<void> _d24Click(WidgetTester tester, Offset at) async {
  final mouse = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await mouse.up();
  await tester.pump();
}

/// Lets the double-click window pass, so the next click is a single click.
Future<void> _d24PastDoubleClick(WidgetTester tester) =>
    tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));

/// Row [r]'s field selection, in field offsets.
TextSelection _d24RowSelection(WidgetTester tester, int r) =>
    tableRowController(tester, 0, r).selection;

/// Clicks the `e` of `see` in the rendered table: the table reveals with the
/// caret there and its row focused.
Future<void> _d24CaretInTable(TableBody b) async {
  final offset = _d24At('see', plus: 1);
  await _d24Click(b.tester, _d24Glyph(b, offset));
  expectTableRevealed(0, 1, reason: 'the click reveals the table');
  expect(b.selection(), TextSelection.collapsed(offset: offset));
  expect(b.view().focusedRow, 1, reason: 'the table row has focus');
  expect(
    _d24RowSelection(b.tester, 1),
    TextSelection.collapsed(offset: offset - _d24TableStart),
    reason: 'the table field holds the caret',
  );
  await _d24PastDoubleClick(b.tester);
}

/// The caret is at segment [offset] in row [r] (a prose row), and the table
/// the caret left is rendered again with no selection in its field.
void _d24ExpectLeftTable(TableBody b, int r, int offset, String reason) {
  expect(
    b.selection(),
    TextSelection.collapsed(offset: offset),
    reason: '$reason: segment caret',
  );
  expect(b.view().focusedRow, r, reason: '$reason: row $r has focus');
  expect(
    _d24RowSelection(b.tester, 1).isValid,
    isFalse,
    reason:
        '$reason: the table field keeps no caret (a stale one sits at its '
        'text end, ${_d24Table.length})',
  );
  expectTableRendered(0, 1, reason: '$reason: the table renders again');
}

void main() {
  holdFontFetches();

  testWidgets(
    'a click on the prose row below a revealed table renders the table again with no caret left in its field',
    (tester) async {
      final b = await _d24Pump(tester);
      await _d24CaretInTable(b);
      final below = _d24At('Below', plus: 2);

      await _d24Click(tester, _d24Glyph(b, below));

      _d24ExpectLeftTable(b, 2, below, 'after the click');
      expect(
        _d24RowSelection(tester, 2),
        TextSelection.collapsed(offset: below - _d24At('Below')),
        reason: 'the clicked row holds the caret',
      );
      await _d24PastDoubleClick(tester);
      _d24ExpectLeftTable(b, 2, below, 'after the click settles');
    },
    variant: macOnly,
  );

  testWidgets(
    'a click on the prose row above a revealed table renders the table again with no caret left in its field',
    (tester) async {
      final b = await _d24Pump(tester);
      await _d24CaretInTable(b);
      const above = 3;

      await _d24Click(tester, _d24Glyph(b, above));

      _d24ExpectLeftTable(b, 0, above, 'after the click');
      expect(
        _d24RowSelection(tester, 0),
        const TextSelection.collapsed(offset: above),
        reason: 'the clicked row holds the caret',
      );
      await _d24PastDoubleClick(tester);
      _d24ExpectLeftTable(b, 0, above, 'after the click settles');
    },
    variant: macOnly,
  );

  testWidgets(
    'activating a prose row from a focused revealed table renders the table again with no caret left in its field',
    (tester) async {
      final b = await _d24Pump(tester);
      await _d24CaretInTable(b);
      final below = _d24At('Below', plus: 4);

      // The seam the row menus and Check Document Now use.
      b.view().activateRow(2, TextSelection.collapsed(offset: below));
      await tester.pump();
      await tester.pump();

      _d24ExpectLeftTable(b, 2, below, 'after the activation');
      expect(
        _d24RowSelection(tester, 2),
        TextSelection.collapsed(offset: below - _d24At('Below')),
        reason: 'the activated row holds the caret',
      );
    },
    variant: macOnly,
  );

  testWidgets(
    'a click on a rendered table from a focused prose row puts the caret at the pressed character and leaves no caret in the prose row',
    (tester) async {
      final b = await _d24Pump(tester);
      await _d24Click(tester, _d24Glyph(b, 3));
      expect(b.view().focusedRow, 0, reason: 'the prose row has focus');
      await _d24PastDoubleClick(tester);
      final offset = _d24At('parser', plus: 3);

      await _d24Click(tester, _d24Glyph(b, offset));

      expectTableRevealed(0, 1, reason: 'the click reveals the table');
      expect(b.selection(), TextSelection.collapsed(offset: offset));
      expect(b.view().focusedRow, 1, reason: 'the table row has focus');
      expect(
        _d24RowSelection(tester, 1),
        TextSelection.collapsed(offset: offset - _d24TableStart),
        reason: 'the table field holds the pressed caret, not its text end',
      );
      expect(
        _d24RowSelection(tester, 0).isValid,
        isFalse,
        reason:
            'the prose row the caret left keeps none (a stale one sits at '
            'its text end, ${_d24Intro.length})',
      );
    },
    variant: macOnly,
  );
}
