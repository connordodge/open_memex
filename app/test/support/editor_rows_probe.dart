// Shared test seam (WI #124, ruling D17): probe one editor row of a text
// segment through the rows host's row-geometry accessor
// (`SegmentViewState.rowBoxes`) and its handle, never through the row's
// field widgets: no text field finder and no render-editable lookup.
//
// #123's editor tests use it from day one. When rows stop mounting a field
// each (#132, idle rows), #132 updates this helper, not their tests. Owned
// by #122 (overlap table); #123 only uses it.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import 'segment_editing_finder.dart';

/// The rows host of text segment [segment] (Key `text-segment-<segment>`).
SegmentViewState rowsHostOf(WidgetTester tester, [int segment = 0]) =>
    tester.state<SegmentViewState>(
      find.descendant(
        of: find.byKey(textSegmentKey(segment)),
        matching: find.byType(SegmentView, skipOffstage: false),
        matchRoot: true,
        skipOffstage: false,
      ),
    );

RowSpec _rowSpecOf(SegmentViewState host, int segment, int row) =>
    host.rowSpec(row) ??
    (throw TestFailure(
      'text segment $segment has no editor row $row '
      '(${host.rowCount} rows)',
    ));

/// Row [row] of text segment [segment]'s geometry through the accessor
/// (`SegmentViewState.rowBoxes`): a block's (a rendered table's grid, an
/// attachment's image or card) or the row's text, in the row's text offsets
/// and the source's own box coordinates. Fails when the row is missing or
/// not laid out.
LineBoxSource rowBoxesOf(WidgetTester tester, int segment, int row) {
  final host = rowsHostOf(tester, segment);
  _rowSpecOf(host, segment, row);
  return host.rowBoxes(row) ??
      (throw TestFailure(
        'editor row $segment-$row reports no geometry (not laid out?)',
      ));
}

/// The global rect row [row] of text segment [segment] occupies, from its
/// geometry ([rowBoxesOf]).
Rect rowRectOf(WidgetTester tester, int segment, int row) {
  final boxes = rowBoxesOf(tester, segment, row);
  final lines = boxes.lines;
  if (lines.isEmpty) {
    throw TestFailure('editor row $segment-$row has no lines');
  }
  final local = Rect.fromLTRB(
    0,
    lines.first.top,
    boxes.box.size.width,
    lines.last.bottom,
  );
  return Rect.fromPoints(
    boxes.box.localToGlobal(local.topLeft),
    boxes.box.localToGlobal(local.bottomRight),
  );
}

/// Row [row] of text segment [segment]'s text as the rows host holds it
/// (the row's field text: an item row's without its marker).
String rowTextOf(WidgetTester tester, int segment, int row) {
  final host = rowsHostOf(tester, segment);
  final spec = _rowSpecOf(host, segment, row);
  return host.text.substring(spec.textStart, spec.textEnd);
}

/// Makes row [row] of text segment [segment] the row being edited: the
/// caret goes to row offset [offset] (default its text start) through the
/// segment's handle, then the segment's focus goes to the row holding it,
/// as tabbing into the segment does. Fails unless the row then has focus.
Future<void> activateRow(
  WidgetTester tester,
  int segment,
  int row, {
  int offset = 0,
}) async {
  final host = rowsHostOf(tester, segment);
  final spec = _rowSpecOf(host, segment, row);
  // The row is laid out (the accessor answers) before it is activated.
  rowBoxesOf(tester, segment, row);
  host.select(TextSelection.collapsed(offset: spec.textStart + offset));
  host.widget.focusNode.requestFocus();
  await tester.pump();
  await tester.pump();
  final focused = rowsHostOf(tester, segment).focusedRow;
  if (focused != row) {
    throw TestFailure(
      'activateRow($segment, $row): row $focused has focus instead',
    );
  }
}
