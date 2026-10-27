// WI #204 (Tables 3, Spec #197 R8, R10-R12, R14-R16, R23, R24, R26, TD4,
// TD5; rulings D3, D11, D12, D17, D20): the table row seam.
// - A table row shows its grid (`TableGrid`, Key `editor-table-<s>-<r>`)
//   while it is not revealed; its field stays mounted offstage with the
//   same controller, focus node and field state (TD4).
// - `LivePreviewController.tableRevealed` (`tableRow && revealGate.value &&
//   selection.isValid`) is the only reveal predicate: a caret or selection
//   touching a table line, with the segment focused, reveals the field.
// - Revealing and re-rendering never report content or record an undo step
//   (R15, D20); typing in a revealed table is one edit.
// - Typing or breaking a delimiter line changes the focused row's kind
//   keeping its controller, focus node and text input connection (R10).
// - The segment line boxes answer a rendered table from the grid and a
//   revealed one from its field (D12 d), the grid paints no selection (R16)
//   and the hidden field is not in the semantics tree (R26).
//
// Tests assert behaviour, not pixels (D18): rects come from the seam and
// the widgets' own render boxes.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/capture_gutter.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_pointer_layer.dart'
    show newlineMarkWidth;
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/table_harness.dart';

/// The prose line above the table (row 0).
const _intro = 'Intro line';

/// A header, a delimiter and two body lines (row 1).
const _table = '| Step | Notes |\n|:--|--:|\n| Alpha | one |\n| Beta | two |';

/// The prose line below the table (row 2).
const _below = 'Below line';

const _text = '$_intro\n$_table\n$_below';

/// The table row's first offset (its header line's start).
const _tableStart = _intro.length + 1;

/// The table row's text end (its last line's content end).
const _tableEnd = _tableStart + _table.length;

/// The start of the line after the table.
const _belowStart = _tableEnd + 1;

/// The segment offset of [needle]'s first character in [_text], plus [plus].
int _at(String needle, [int plus = 0]) {
  final i = _text.indexOf(needle);
  if (i < 0) throw ArgumentError('$needle is not in the fixture');
  return i + plus;
}

/// A second, different table for segments holding two.
const _table2 = '| K | V |\n|---|---|\n| x | 1 |';

/// Two tables with a prose row between them: rows prose, table, prose,
/// table, prose.
const _twoTables = '$_intro\n$_table\n\nMiddle line\n\n$_table2\n$_below';

/// Fails unless [text] derives the row kinds [kinds] (a fixture guard).
void _expectRows(String text, List<RowKind> kinds) {
  expect(
    [for (final r in splitRows(text, atSegmentStart: true)) r.kind],
    kinds,
    reason: 'fixture rows of ${text.replaceAll('\n', r'\n')}',
  );
}

/// The Offstage ancestors of row [r]'s field that hide it.
Finder _hidingOffstage(int s, int r) => find.ancestor(
  of: tableRowField(s, r),
  matching: find.byWidgetPredicate(
    (w) => w is Offstage && w.offstage,
    description: 'Offstage(offstage: true)',
    skipOffstage: false,
  ),
);

/// Every rect painted in `OmColors.selection` when [root] paints, in global
/// coordinates. Follows the canvas's save, restore and translate calls; a
/// scale or matrix transform fails the test (not expected in the editor).
List<Rect> _selectionRects(RenderBox root) {
  final canvas = TestRecordingCanvas();
  root.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final origin = root.localToGlobal(Offset.zero);
  final stack = <Offset>[];
  var shift = Offset.zero;
  final out = <Rect>[];
  for (final call in canvas.invocations) {
    final i = call.invocation;
    switch (i.memberName) {
      case #save || #saveLayer:
        stack.add(shift);
      case #restore:
        shift = stack.isEmpty ? Offset.zero : stack.removeLast();
      case #translate:
        shift += Offset(
          (i.positionalArguments[0] as num).toDouble(),
          (i.positionalArguments[1] as num).toDouble(),
        );
      case #scale || #transform || #rotate || #skew:
        throw TestFailure('unexpected canvas ${i.memberName}');
      case #drawRect:
        final paint = i.positionalArguments[1] as Paint;
        // Paint keeps its colour in 32-bit floats: compare as ARGB.
        if (paint.color.toARGB32() == OmColors.selection.toARGB32()) {
          out.add((i.positionalArguments[0] as Rect).shift(origin + shift));
        }
    }
  }
  return out;
}

/// The semantics nodes of text fields whose value is [value].
List<SemanticsNode> _textFieldNodes(String value) => [
  for (final n in find.semantics.byFlag(SemanticsFlag.isTextField).evaluate())
    if (n.value == value) n,
];

void main() {
  holdFontFetches();

  setUpAll(() {
    _expectRows(_text, const [RowKind.prose, RowKind.table, RowKind.prose]);
    _expectRows(_twoTables, const [
      RowKind.prose,
      RowKind.table,
      RowKind.prose,
      RowKind.table,
      RowKind.prose,
    ]);
  });

  // -------------------------------------------------------------------------
  // D12 (a): the reveal predicate
  // -------------------------------------------------------------------------
  group('the reveal predicate (D12 a)', () {
    LivePreviewController ctrl({
      required bool table,
      required bool gate,
      required bool valid,
    }) {
      final c = LivePreviewController(text: '| a |\n|---|');
      addTearDown(c.dispose);
      final g = ValueNotifier(gate);
      addTearDown(g.dispose);
      c
        ..tableRow = table
        ..revealGate = g
        ..selection = TextSelection.collapsed(offset: valid ? 2 : -1);
      return c;
    }

    for (final (name, table, gate, valid, revealed) in [
      (
        'tableRevealed is true for a table row with the gate open and a valid selection',
        true,
        true,
        true,
        true,
      ),
      (
        'tableRevealed is false when the row is not a table row',
        false,
        true,
        true,
        false,
      ),
      (
        'tableRevealed is false while the reveal gate is closed',
        true,
        false,
        true,
        false,
      ),
      (
        'tableRevealed is false while the selection is invalid',
        true,
        true,
        false,
        false,
      ),
    ]) {
      test(name, () {
        expect(
          ctrl(table: table, gate: gate, valid: valid).tableRevealed,
          revealed,
        );
      });
    }

    test(
      'tableRevealed reads the reveal gate and selection as they change',
      () {
        final c = LivePreviewController(text: '| a |\n|---|');
        addTearDown(c.dispose);
        final gate = ValueNotifier(false);
        addTearDown(gate.dispose);
        c
          ..tableRow = true
          ..revealGate = gate
          ..selection = const TextSelection.collapsed(offset: 1);
        expect(c.tableRevealed, isFalse);
        gate.value = true;
        expect(c.tableRevealed, isTrue);
        c.selection = const TextSelection.collapsed(offset: -1);
        expect(c.tableRevealed, isFalse);
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
        expect(c.tableRevealed, isTrue);
        c.tableRow = false;
        expect(c.tableRevealed, isFalse);
      },
    );

    test('tableRow defaults to false and notifies listeners when set', () {
      final c = LivePreviewController(text: 'x');
      addTearDown(c.dispose);
      var notified = 0;
      c.addListener(() => notified++);
      expect(c.tableRow, isFalse);
      expect(c.tableRevealed, isFalse);
      c.tableRow = true;
      expect(c.tableRow, isTrue);
      expect(notified, 1);
      c.tableRow = false;
      expect(c.tableRow, isFalse);
      expect(notified, 2);
    });
  });

  // -------------------------------------------------------------------------
  // AC1: rendered by default (R12, TD4)
  // -------------------------------------------------------------------------
  group('rendered by default (AC1)', () {
    for (final (name, width, scale) in [
      (
        'a table with the caret in another row shows its grid and keeps its field mounted offstage at desktop width',
        tableDesktopWidth,
        1.0,
      ),
      (
        'a table with the caret in another row shows its grid and keeps its field mounted offstage at 720 width',
        tableNarrowWidth,
        1.0,
      ),
      (
        'a table with the caret in another row shows its grid and keeps its field mounted offstage at text scale 1.2',
        tableDesktopWidth,
        1.2,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(
          tester,
          _text,
          width: width,
          textScale: scale,
        );
        await body.placeCaret(_intro.length);
        expect(body.segment().focusedRow, 0);

        expectTableRendered(0, 1);
        expect(_hidingOffstage(0, 1), findsOneWidget);
        expect(tableRowController(tester, 0, 1).text, _table);
        expect(tableRowController(tester, 0, 1).tableRevealed, isFalse);
        // The prose rows around it are plain fields.
        expect(tableRowFieldOnstage(0, 0), findsOneWidget);
        expect(tableRowFieldOnstage(0, 2), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: macOnly);
    }

    testWidgets('a segment without focus shows the grid of its table', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text);
      await body.focusOutside();
      expectTableRendered(0, 1);
      expect(tableRowController(tester, 0, 1).tableRevealed, isFalse);
    }, variant: macOnly);

    testWidgets('only the table row controller has tableRow set', (
      tester,
    ) async {
      await pumpTable(tester, _text);
      expect(tableRowController(tester, 0, 0).tableRow, isFalse);
      expect(tableRowController(tester, 0, 1).tableRow, isTrue);
      expect(tableRowController(tester, 0, 2).tableRow, isFalse);
    }, variant: macOnly);

    testWidgets(
      'a table at the segment start renders and reveals like any other',
      (tester) async {
        const text = '$_table\n$_below';
        _expectRows(text, const [RowKind.table, RowKind.prose]);
        final body = await pumpTable(tester, text);
        await body.placeCaret(text.length);
        expectTableRendered(0, 0);

        await body.placeCaret(3);
        expectTableRevealed(0, 0);
        expect(body.selection(), const TextSelection.collapsed(offset: 3));
      },
      variant: macOnly,
    );

    testWidgets(
      'the hidden table field keeps the same controller focus node and field state across reveal and re-render',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        final ctrl = tableRowController(tester, 0, 1);
        final node = tableRowFocusNode(tester, 0, 1);
        final state = tableRowFieldState(tester, 0, 1);

        await body.placeCaret(_at('Alpha', 2));
        expectTableRevealed(0, 1);
        expect(_hidingOffstage(0, 1), findsNothing);
        expect(tableRowController(tester, 0, 1), same(ctrl));
        expect(tableRowFocusNode(tester, 0, 1), same(node));
        expect(tableRowFieldState(tester, 0, 1), same(state));
        expect(node.hasFocus, isTrue);

        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        expect(_hidingOffstage(0, 1), findsOneWidget);
        expect(tableRowController(tester, 0, 1), same(ctrl));
        expect(tableRowFocusNode(tester, 0, 1), same(node));
        expect(tableRowFieldState(tester, 0, 1), same(state));
      },
      variant: macOnly,
    );

    testWidgets(
      'moving the caret within another row does not notify the table row controller',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        final ctrl = tableRowController(tester, 0, 1);
        expect(ctrl.tableRow, isTrue);
        var notified = 0;
        void count() => notified++;
        ctrl.addListener(count);
        addTearDown(() => ctrl.removeListener(count));

        await body.placeCaret(5);
        await body.placeCaret(_intro.length);

        expect(notified, 0);
        expectTableRendered(0, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: reveal (R12, R14)
  // -------------------------------------------------------------------------
  group('reveal (AC2)', () {
    for (final (name, offset) in [
      ('a caret at the table header line start reveals the table', _tableStart),
      ('a caret inside a table body line reveals the table', _at('Alpha', 2)),
      ('a caret on the table delimiter line reveals the table', _at(':--', 1)),
      (
        'a caret at a table line content end reveals the table',
        _at('| Step | Notes |', '| Step | Notes |'.length),
      ),
      (
        'a caret at the last table line content end reveals the table',
        _tableEnd,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);

        await body.placeCaret(offset);

        expectTableRevealed(0, 1);
        expect(tableRowController(tester, 0, 1).tableRevealed, isTrue);
        expect(body.selection(), TextSelection.collapsed(offset: offset));
        expect(body.segment().focusedRow, 1);
      }, variant: macOnly);
    }

    for (final (name, offset) in [
      (
        'a caret at the start of the line after the table keeps the grid',
        _belowStart,
      ),
      (
        'a caret at the end of the line above the table keeps the grid',
        _intro.length,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(offset);

        expectTableRendered(0, 1);
        expect(tableRowController(tester, 0, 1).tableRevealed, isFalse);
        expect(body.selection(), TextSelection.collapsed(offset: offset));
      }, variant: macOnly);
    }

    testWidgets(
      'a selection from the line above into the header line reveals the whole table',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        expectTableRendered(0, 1);
        final selection = TextSelection(
          baseOffset: 3,
          extentOffset: _at('Notes', 2),
        );

        await body.select(selection);

        expectTableRevealed(0, 1);
        expect(body.selection(), selection);
        // The table field holds every table line, header to last body line.
        expect(tableRowController(tester, 0, 1).text, _table);
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection from below ending inside the last body line reveals the table',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        final selection = TextSelection(
          baseOffset: _belowStart + 4,
          extentOffset: _at('Beta', 1),
        );

        await body.select(selection);

        expectTableRevealed(0, 1);
        expect(body.selection(), selection);
      },
      variant: macOnly,
    );

    testWidgets('Cmd+A in the segment reveals every table in it', (
      tester,
    ) async {
      final body = await pumpTable(tester, _twoTables);
      await body.placeCaret(2);
      expectTableRendered(0, 1);
      expectTableRendered(0, 3);

      await body.selectAll();

      expect(
        body.selection(),
        const TextSelection(baseOffset: 0, extentOffset: _twoTables.length),
      );
      expectTableRevealed(0, 1);
      expectTableRevealed(0, 3);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC3: re-render (R12, R16)
  // -------------------------------------------------------------------------
  group('re-render (AC3)', () {
    testWidgets('moving the caret out of the table shows the grid again', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text);
      await body.placeCaret(_intro.length);
      expectTableRendered(0, 1);
      await body.placeCaret(_at('Beta'));
      expectTableRevealed(0, 1);

      await body.placeCaret(_belowStart + 3);

      expectTableRendered(0, 1);
      expect(tableRowController(tester, 0, 1).tableRevealed, isFalse);
    }, variant: macOnly);

    testWidgets('focus leaving the segment shows the grid again', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text);
      await body.placeCaret(_intro.length);
      expectTableRendered(0, 1);
      await body.placeCaret(_at('Beta'));
      expectTableRevealed(0, 1);

      await body.focusOutside();

      expectTableRendered(0, 1);
      expect(tableRowController(tester, 0, 1).tableRevealed, isFalse);
      expect(body.selection(), TextSelection.collapsed(offset: _at('Beta')));
    }, variant: macOnly);

    testWidgets(
      'with focus gone a selection touching the table paints no selection on the grid and is kept',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        expectTableRendered(0, 1);
        // From inside the intro line into the first body line: the
        // header and delimiter line ends are selected too.
        final selection = TextSelection(
          baseOffset: 3,
          extentOffset: _at('Alpha', 3),
        );
        await body.select(selection);
        expectTableRevealed(0, 1);

        await body.focusOutside();

        expectTableRendered(0, 1);
        expect(body.selection(), selection);
        final grid = tester.getRect(tableGrid(0, 1));
        final painted = _selectionRects(
          tester.renderObject<RenderBox>(find.byKey(textSegmentKey(0))),
        );
        expect(
          painted.where((r) => !r.overlaps(grid.deflate(1))),
          isNotEmpty,
          reason: 'the intro row still shows its slice of the selection',
        );
        expect(
          painted.where((r) => r.overlaps(grid.deflate(1))),
          isEmpty,
          reason: 'the grid paints no selection (R16)',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection across a revealed table paints a newline mark at the end of each selected table line',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        await body.select(
          TextSelection(baseOffset: 3, extentOffset: _at('Alpha', 3)),
        );
        expectTableRevealed(0, 1);

        final seg = body.segmentBoxes();
        final painted = _selectionRects(
          tester.renderObject<RenderBox>(find.byKey(textSegmentKey(0))),
        );
        // The header and delimiter line ends are inside the selection.
        for (final start in [_tableStart, _at('|:--|--:|')]) {
          final line = seg.lines.singleWhere((l) => l.range.start == start);
          final top = seg.box.localToGlobal(Offset(0, line.top)).dy;
          final bottom = seg.box.localToGlobal(Offset(0, line.bottom)).dy;
          expect(
            painted.where(
              (r) =>
                  (r.width - newlineMarkWidth(null)).abs() < 0.01 &&
                  (r.top - top).abs() < 0.5 &&
                  (r.bottom - bottom).abs() < 0.5,
            ),
            hasLength(1),
            reason: 'newline mark of the table line starting at $start',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'refocusing the segment reveals the table with its kept selection',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        expectTableRendered(0, 1);
        final selection = TextSelection(
          baseOffset: _at('Alpha'),
          extentOffset: _at('Alpha', 'Alpha'.length),
        );
        await body.select(selection);
        await body.focusOutside();
        expectTableRendered(0, 1);
        expect(body.selection(), selection);

        await body.refocus();

        expectTableRevealed(0, 1);
        expect(body.selection(), selection);
        expect(
          tableRowController(tester, 0, 1).selection,
          TextSelection(
            baseOffset: selection.baseOffset - _tableStart,
            extentOffset: selection.extentOffset - _tableStart,
          ),
        );
        expect(tableRowFocusNode(tester, 0, 1).hasFocus, isTrue);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: D20 call counts (R15)
  // -------------------------------------------------------------------------
  group('reveal and re-render call counts (AC4, D20)', () {
    testWidgets(
      'revealing a table by caret gives 0 content reports and 0 undo records',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        body.resetCounts();

        await body.placeCaret(_at('Alpha', 1));

        expectTableRevealed(0, 1);
        expect(body.reportCount, 0);
        expect(body.undoRecordCount, 0);
        expect(body.text(), _text);
      },
      variant: macOnly,
    );

    testWidgets(
      're-rendering a table on caret leave gives 0 content reports and 0 undo records',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        await body.placeCaret(_at('Alpha', 1));
        expectTableRevealed(0, 1);
        body.resetCounts();

        await body.placeCaret(_belowStart);

        expectTableRendered(0, 1);
        expect(body.reportCount, 0);
        expect(body.undoRecordCount, 0);
        expect(body.text(), _text);
      },
      variant: macOnly,
    );

    testWidgets(
      're-rendering a table on segment focus loss gives 0 content reports and 0 undo records',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        await body.placeCaret(_at('Alpha', 1));
        expectTableRevealed(0, 1);
        body.resetCounts();

        await body.focusOutside();

        expectTableRendered(0, 1);
        expect(body.reportCount, 0);
        expect(body.undoRecordCount, 0);
        expect(body.text(), _text);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+A revealing the tables gives 0 content reports and 0 undo records',
      (tester) async {
        final body = await pumpTable(tester, _twoTables);
        await body.placeCaret(2);
        expectTableRendered(0, 1);
        expectTableRendered(0, 3);
        body.resetCounts();

        await body.selectAll();

        expectTableRevealed(0, 1);
        expectTableRevealed(0, 3);
        expect(body.reportCount, 0);
        expect(body.undoRecordCount, 0);
        expect(body.text(), _twoTables);
      },
      variant: macOnly,
    );

    testWidgets(
      'one character typed in a revealed table gives exactly 1 content report and 1 undo record',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        final at = _at('Alpha', 2);
        await body.placeCaret(at);
        expectTableRevealed(0, 1);
        final ctrl = tableRowController(tester, 0, 1);
        body.resetCounts();

        await body.typeChar('x');

        final typed = _text.replaceRange(at, at, 'x');
        expect(body.text(), typed);
        expect(body.reportCount, 1);
        expect(body.reports.last, typed);
        expect(body.undoRecordCount, 1);
        expect(body.selection(), TextSelection.collapsed(offset: at + 1));
        expectTableRevealed(0, 1);
        expect(tableRowController(tester, 0, 1), same(ctrl));
        await body.settleTyping();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: R10 kind change keeps the focused field
  // -------------------------------------------------------------------------
  group('typing and breaking a delimiter line (AC5, R10)', () {
    // A header line and a delimiter line missing its middle pipe: prose.
    const before = '$_intro\n| a | b |\n| --- --- |';
    // The caret after `| --- ` on the delimiter line.
    final gap = before.lastIndexOf('--- |');

    testWidgets(
      'typing the last missing pipe of a delimiter line under a header turns the lines into a table row keeping the focused field',
      (tester) async {
        _expectRows(before, const [RowKind.prose]);
        final after = before.replaceRange(gap, gap, '|');
        _expectRows(after, const [RowKind.prose, RowKind.table]);
        final body = await pumpTable(tester, before);
        await body.placeCaret(gap);
        expect(body.segment().focusedRow, 0);
        final ctrl = tableRowController(tester, 0, 0);
        final node = tableRowFocusNode(tester, 0, 0);
        final state = tableRowFieldState(tester, 0, 0);
        expect(ctrl.tableRow, isFalse);
        tester.testTextInput.log.clear();
        body.resetCounts();

        await body.typeChar('|');

        expect(body.text(), after);
        expect(body.reportCount, 1);
        expect(body.segment().rowCount, 2);
        expect(body.segment().focusedRow, 1);
        expect(tableRowController(tester, 0, 1), same(ctrl));
        expect(tableRowFocusNode(tester, 0, 1), same(node));
        expect(tableRowFieldState(tester, 0, 1), same(state));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(ctrl.tableRow, isTrue);
        expect(body.selection(), TextSelection.collapsed(offset: gap + 1));
        expect(
          ctrl.selection,
          TextSelection.collapsed(offset: gap + 1 - (_intro.length + 1)),
        );
        expect(
          tester.testTextInput.log.where(
            (c) =>
                c.method == 'TextInput.setClient' ||
                c.method == 'TextInput.clearClient',
          ),
          isEmpty,
          reason: 'the text input connection survives the kind change',
        );
        // The caret is in the new table: it shows revealed.
        expectTableRevealed(0, 1);
        await body.settleTyping();
      },
      variant: macOnly,
    );

    testWidgets(
      'deleting a delimiter character turns the table back into prose keeping the focused field',
      (tester) async {
        final table = before.replaceRange(gap, gap, '|');
        _expectRows(table, const [RowKind.prose, RowKind.table]);
        final broken = before.replaceRange(gap, gap, '');
        _expectRows(broken, const [RowKind.prose]);
        final body = await pumpTable(tester, table);
        // The caret right after the delimiter line middle pipe.
        await body.placeCaret(gap + 1);
        expectTableRevealed(0, 1);
        final ctrl = tableRowController(tester, 0, 1);
        final node = tableRowFocusNode(tester, 0, 1);
        final state = tableRowFieldState(tester, 0, 1);
        expect(ctrl.tableRow, isTrue);
        tester.testTextInput.log.clear();
        body.resetCounts();

        await body.press(LogicalKeyboardKey.backspace);

        expect(body.text(), broken);
        expect(body.reportCount, 1);
        expect(body.segment().rowCount, 1);
        expect(body.segment().focusedRow, 0);
        expect(tableRowController(tester, 0, 0), same(ctrl));
        expect(tableRowFocusNode(tester, 0, 0), same(node));
        expect(tableRowFieldState(tester, 0, 0), same(state));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(ctrl.tableRow, isFalse);
        expect(body.selection(), TextSelection.collapsed(offset: gap));
        expect(
          tester.testTextInput.log.where(
            (c) =>
                c.method == 'TextInput.setClient' ||
                c.method == 'TextInput.clearClient',
          ),
          isEmpty,
          reason: 'the text input connection survives the kind change',
        );
        expect(tableGrid(0, 0), findsNothing);
        await body.settleTyping();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: matchRows keeps the focused row when a table lands above it
  // -------------------------------------------------------------------------
  testWidgets(
    'a polled write inserting a table above the focused row keeps focus and caret in the focused row',
    (tester) async {
      const para =
          'Paragraph words that keep going long enough to hold the caret '
          'after a table lands above them';
      const start = '$_intro\n\n$para';
      const polled = '$_intro\n$_table\n\n$para';
      _expectRows(start, const [RowKind.prose]);
      _expectRows(polled, const [RowKind.prose, RowKind.table, RowKind.prose]);
      final body = await pumpTable(tester, start);
      await body.placeCaret(start.length);
      expect(body.segment().focusedRow, 0);
      final ctrl = tableRowController(tester, 0, 0);
      final node = tableRowFocusNode(tester, 0, 0);
      final state = tableRowFieldState(tester, 0, 0);
      body.resetCounts();

      await body.serverWrite(polled);

      expect(body.text(), polled);
      expect(body.reportCount, 0);
      expect(body.segment().rowCount, 3);
      expect(body.segment().focusedRow, 2);
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(tableRowController(tester, 0, 2), same(ctrl));
      expect(tableRowFieldState(tester, 0, 2), same(state));
      // The host keeps the selection's offsets (clamped) on a server write.
      expect(
        body.selection(),
        const TextSelection.collapsed(offset: start.length),
      );
      expect(ctrl.selection.isValid, isTrue);
      // The new table is not touched: it renders.
      expectTableRendered(0, 1);
    },
    variant: macOnly,
  );

  // -------------------------------------------------------------------------
  // AC7: D11 Tab and Shift+Tab in a revealed table row do nothing
  // -------------------------------------------------------------------------
  group('Tab in a revealed table row (AC7, D11)', () {
    for (final (name, shift) in [
      (
        'Tab in a revealed table row leaves the bytes unchanged with no report or undo record and keeps focus',
        false,
      ),
      (
        'Shift+Tab in a revealed table row leaves the bytes unchanged with no report or undo record and keeps focus',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);
        final at = _at('Alpha', 2);
        await body.placeCaret(at);
        expectTableRevealed(0, 1);
        final node = tableRowFocusNode(tester, 0, 1);
        body.resetCounts();

        await body.pressTab(shift: shift);

        expect(body.text(), _text);
        expect(tableRowController(tester, 0, 1).text, _table);
        expect(body.reportCount, 0);
        expect(body.undoRecordCount, 0);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(body.segment().focusedRow, 1);
        expect(body.selection(), TextSelection.collapsed(offset: at));
        expectTableRevealed(0, 1);
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC8: the line-box seam (D12 d, TD5)
  // -------------------------------------------------------------------------
  group('the line-box seam (AC8, D12 d)', () {
    testWidgets(
      'a rendered table answers the segment line boxes and its row boxes from the grid',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        final grid = tester.getRect(tableGrid(0, 1));
        final gridBoxes = tableGridState(tester, 0, 1).lineBoxes()!;
        expect(
          tableRenderUnder(gridBoxes.box, tester.renderObject(tableGrid(0, 1))),
          isTrue,
          reason: 'the grid answers in its own render box',
        );
        final rowBoxes = tableEditorRowWidget(tester, 0, 1).boxes()!;
        expect(rowBoxes.box, same(gridBoxes.box));

        final seg = body.segmentBoxes();
        for (var at = _tableStart; at <= _tableEnd; at++) {
          final rect = body.toGlobal(seg, seg.caretRect(at));
          expect(rect.height, greaterThan(0), reason: 'caret at $at');
          expect(
            grid.inflate(1).contains(rect.center),
            isTrue,
            reason: 'caret at $at: $rect in grid $grid',
          );
          final viaRow = body.toGlobal(
            rowBoxes,
            rowBoxes.caretRect(at - _tableStart),
          );
          expect(rect.left, moreOrLessEquals(viaRow.left, epsilon: 0.01));
          expect(rect.top, moreOrLessEquals(viaRow.top, epsilon: 0.01));
          expect(rect.bottom, moreOrLessEquals(viaRow.bottom, epsilon: 0.01));
          final back = seg.offsetAt(seg.caretRect(at).center);
          expect(
            back,
            inInclusiveRange(_tableStart, _tableEnd),
            reason: 'offsetAt at the caret of $at',
          );
        }
        final tableLines = [
          for (final l in seg.lines)
            if (l.range.start >= _tableStart && l.range.start < _belowStart) l,
        ];
        expect(tableLines, isNotEmpty);
        for (final l in tableLines) {
          final top = seg.box.localToGlobal(Offset(0, l.top)).dy;
          final bottom = seg.box.localToGlobal(Offset(0, l.bottom)).dy;
          expect(top, greaterThanOrEqualTo(grid.top - 0.5));
          expect(bottom, lessThanOrEqualTo(grid.bottom + 0.5));
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a revealed table answers the segment line boxes and its row boxes from its field',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        await body.placeCaret(_at('Alpha'));
        expectTableRevealed(0, 1);
        final editable = findRenderEditable(
          tester.renderObject(tableRowFieldOnstage(0, 1)),
        )!;
        final field = tester.getRect(tableRowFieldOnstage(0, 1));
        final rowBoxes = tableEditorRowWidget(tester, 0, 1).boxes()!;
        expect(rowBoxes.box, same(editable));

        final seg = body.segmentBoxes();
        for (final at in [_tableStart, _at('Alpha'), _tableEnd]) {
          final rect = body.toGlobal(seg, seg.caretRect(at));
          expect(rect.height, greaterThan(0));
          expect(
            field.inflate(1).contains(rect.center),
            isTrue,
            reason: 'caret at $at: $rect in field $field',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets('the capture gutter answers a rendered table from the grid', (
      tester,
    ) async {
      final body = await pumpTable(tester, '$_text\n', daily: true);
      await body.placeCaret(_belowStart);
      expectTableRendered(0, 1);
      final grid = tester.getRect(tableGrid(0, 1));
      final gutterBoxes = tester
          .widget<CaptureGutter>(find.byType(CaptureGutter))
          .boxes!
          .call()!;
      final seg = body.segmentBoxes();
      for (final at in [_tableStart, _at(':--'), _at('Beta'), _tableEnd]) {
        final viaGutter = body.toGlobal(gutterBoxes, gutterBoxes.caretRect(at));
        final viaSegment = body.toGlobal(seg, seg.caretRect(at));
        expect(viaGutter.height, greaterThan(0));
        expect(grid.inflate(1).contains(viaGutter.center), isTrue);
        expect(viaGutter.top, moreOrLessEquals(viaSegment.top, epsilon: 0.01));
        expect(
          viaGutter.left,
          moreOrLessEquals(viaSegment.left, epsilon: 0.01),
        );
      }
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC9: arrows into a rendered table (R23 Left/Right)
  // -------------------------------------------------------------------------
  group('arrows into a rendered table (AC9, R23)', () {
    testWidgets(
      'Right at the end of the row above a rendered table puts the caret at its first character and reveals it',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);

        await body.press(LogicalKeyboardKey.arrowRight);

        expect(
          body.selection(),
          const TextSelection.collapsed(offset: _tableStart),
        );
        expect(body.segment().focusedRow, 1);
        expect(tableRowFocusNode(tester, 0, 1).hasFocus, isTrue);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Left at the start of the row below a rendered table puts the caret at its last character and reveals it',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);

        await body.press(LogicalKeyboardKey.arrowLeft);

        expect(
          body.selection(),
          const TextSelection.collapsed(offset: _tableEnd),
        );
        expect(body.segment().focusedRow, 1);
        expect(tableRowFocusNode(tester, 0, 1).hasFocus, isTrue);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC10: Enter in a revealed table (R8)
  // -------------------------------------------------------------------------
  testWidgets(
    'Enter in a revealed table inserts a plain newline with one report and one undo record',
    (tester) async {
      final body = await pumpTable(tester, _text);
      await body.placeCaret(_intro.length);
      expectTableRendered(0, 1);
      final at = _at('| Alpha | one |', '| Alpha | one |'.length);
      await body.placeCaret(at);
      expectTableRevealed(0, 1);
      body.resetCounts();

      await body.press(LogicalKeyboardKey.enter);

      final split = _text.replaceRange(at, at, '\n');
      expect(body.text(), split);
      expect(body.reportCount, 1);
      expect(body.reports.last, split);
      expect(body.undoRecordCount, 1);
      expect(body.selection(), TextSelection.collapsed(offset: at + 1));
      await body.settleTyping();
    },
    variant: macOnly,
  );

  // -------------------------------------------------------------------------
  // AC11: semantics (R26)
  // -------------------------------------------------------------------------
  testWidgets(
    'the hidden table field is not in the semantics tree while the grid shows',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_intro.length);
        expectTableRendered(0, 1);

        expect(
          _textFieldNodes(_table),
          isEmpty,
          reason: 'the hidden field is not read (R26)',
        );
        expect(_textFieldNodes(_intro), hasLength(1));
        expect(
          find.semantics.byLabel(RegExp('Alpha')),
          findsAtLeast(1),
          reason: 'the grid exposes the cell text',
        );

        await body.placeCaret(_at('Alpha'));
        expectTableRevealed(0, 1);
        expect(
          _textFieldNodes(_table),
          hasLength(1),
          reason: 'a revealed table reads as its field',
        );
      } finally {
        semantics.dispose();
      }
    },
    variant: macOnly,
  );

  // -------------------------------------------------------------------------
  // Seam contracts the gate's mutants pinned (verify round 1)
  // -------------------------------------------------------------------------
  group('the seam contracts of the row and the grid (verify round 1)', () {
    testWidgets(
      'an unfocused selection inside a prose row still paints its slice next to a table',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(2);
        // Inside the intro line only: no line end, so no newline mark.
        await body.select(const TextSelection(baseOffset: 2, extentOffset: 6));
        await body.focusOutside();
        expectTableRendered(0, 1);
        expect(
          body.selection(),
          const TextSelection(baseOffset: 2, extentOffset: 6),
        );

        final painted = _selectionRects(
          tester.renderObject<RenderBox>(find.byKey(textSegmentKey(0))),
        );
        final intro = tester.getRect(tableEditorRow(0, 0));
        expect(
          painted.where((r) => r.overlaps(intro.deflate(1))),
          isNotEmpty,
          reason: 'R16 hides a rendered table selection only, not a prose one',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a table that was just revealed answers its row boxes from its field before the grid leaves the tree',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        final controller = tableRowController(tester, 0, 1);
        final rowBoxes = tableEditorRowWidget(tester, 0, 1).boxes;

        // Reveal without a frame: the grid is still mounted and laid out.
        controller.selection = const TextSelection.collapsed(offset: 3);
        expect(controller.tableRevealed, isTrue);
        expect(tableGrid(0, 1), findsOneWidget);

        final editable = findRenderEditable(
          tester.renderObject(tableRowField(0, 1)),
        )!;
        expect(rowBoxes()!.box, same(editable));
        await tester.pump();
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a rendered table row answers its row boxes from the grid and a prose row from its field',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        expectTableRendered(0, 1);
        final grid = tableGridState(tester, 0, 1).lineBoxes()!;
        expect(tableEditorRowWidget(tester, 0, 1).boxes()!.box, same(grid.box));
        final prose = findRenderEditable(
          tester.renderObject(tableRowField(0, 0)),
        )!;
        expect(tableEditorRowWidget(tester, 0, 0).boxes()!.box, same(prose));
      },
      variant: macOnly,
    );

    testWidgets(
      'a grid reports line boxes while mounted and none while deactivated',
      (tester) async {
        final body = await pumpTable(tester, _text);
        await body.placeCaret(_belowStart);
        final state = tableGridState(tester, 0, 1);
        expect(state.lineBoxes(), isNotNull);

        // The frame that reveals a table deactivates its grid before the
        // grid's render object is gone (D12 c).
        // ignore: invalid_use_of_protected_member
        state.deactivate();
        expect(state.lineBoxes(), isNull, reason: 'deactivated');
        // ignore: invalid_use_of_protected_member
        state.activate();
        expect(state.lineBoxes(), isNotNull, reason: 'reactivated');
      },
      variant: macOnly,
    );

    testWidgets(
      'a grid has no line boxes before its first layout and has them after',
      (tester) async {
        final key = GlobalKey<TableGridState>();
        LineBoxSource? whileBuilding;
        var probed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: [
                TableGrid(
                  key: key,
                  text: '| a |\n|---|',
                  style: const TextStyle(),
                ),
                // Built after the grid mounted and before any layout.
                Builder(
                  builder: (_) {
                    probed = key.currentState != null;
                    whileBuilding = key.currentState?.lineBoxes();
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        );

        expect(probed, isTrue, reason: 'the probe saw the mounted grid');
        expect(whileBuilding, isNull, reason: 'not laid out yet');
        final after = key.currentState!.lineBoxes();
        expect(after, isNotNull);
        expect(after!.lines, isNotEmpty);
      },
      variant: macOnly,
    );

    testWidgets('a grid hides the markers of its text', (tester) async {
      const table = '| **b** | [[Link]] |\n|---|---|\n| `c` | d |';
      const text = '$_intro\n$table';
      final body = await pumpTable(tester, text);
      await body.placeCaret(2);
      expect(body.text(), text);
      expectTableRendered(0, 1);
      final paragraph = tester.widget<RichText>(
        find.descendant(of: tableGrid(0, 1), matching: find.byType(RichText)),
      );
      final markers = <String>[];
      var at = 0;
      paragraph.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          final t = span.text!;
          if (span.style?.fontSize == 0) markers.add(t);
          at += t.length;
        }
        return true;
      });
      expect(at, table.length);
      for (final m in ['**', '[[', ']]', '`']) {
        expect(
          markers.any((t) => t.contains(m)),
          isTrue,
          reason: '$m is hidden in the grid',
        );
      }
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC12: the shared harness (D17)
  // -------------------------------------------------------------------------
  testWidgets(
    'the table harness pumps by text width and text scale with zeroed counters and finds the grid',
    (tester) async {
      final body = await pumpTable(
        tester,
        _text,
        width: tableNarrowWidth,
        textScale: 1.2,
      );

      expect(tester.view.physicalSize.width, tableNarrowWidth);
      expect(body.text(), _text);
      expect(body.reportCount, 0);
      expect(body.undoRecordCount, 0);
      expect(tableGrid(0, 1), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(tester.element(tableGrid(0, 1))).scale(10),
        moreOrLessEquals(12),
      );
      expect(body.segmentBoxes().lines, isNotEmpty);
      expect(
        tester.getRect(tableGrid(0, 1)).right,
        lessThanOrEqualTo(tableNarrowWidth),
      );
    },
    variant: macOnly,
  );
}
