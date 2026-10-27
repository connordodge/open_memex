// WI #206 (Tables 5, Spec #197 R13, R20, TD4, TD5; rulings D10, D12, D15,
// D18; design pack design/192-md-tables/packs/206.md): the revealed table's
// look in its own field.
// - Every line of a revealed table (header, delimiter, body) is one body
//   line, as tall as a prose line at the same text scale.
// - The header line's cell text is bold; body cell text is not.
// - Every cell-splitting `|` (from the one cell splitter, D10) and the whole
//   delimiter line render in `fg2`; a `\|` and the `|` inside
//   `[[Title|alias]]` keep their cell style.
// - A touch on any line of a table reveals every line's inline markup, as a
//   caret in a code block reveals both fences.
// - `layoutDecorations` paints one pill per inline code span of a revealed
//   table from the field's own line boxes, and nothing for a rendered
//   table row (the grid paints its own pills, D15).
// - Typing, the `[[` popover and undo behave as in a prose row.
// - Prose and code rows next to a table keep their spans and decorations.
//
// Face-agnostic (D18): rects come from the seam (`segmentBoxes()`), colours
// and weights from the field's laid-out spans and the decorations it paints.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/editor/markdown_table.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/table_harness.dart';

/// The prose line above the table (row 0).
const _intro = 'Intro line';

/// A header, a delimiter and two body lines (row 1). Line 2 holds an
/// escaped pipe and an aliased wikilink; line 3 (three lines below the
/// header) holds bold, inline code and a wikilink.
const _table =
    '| Step | Notes | Ref |\n'
    '|:--|--:|:-:|\n'
    '| Alpha | a \\| b | [[Known|alias]] |\n'
    '| **Beta** | run `fmt` | [[Known]] |';

/// The prose line below the table (row 2).
const _below = 'Below line';

const _text = '$_intro\n$_table\n$_below';

/// The table row's first offset (its header line's start), in the segment.
const _tableStart = _intro.length + 1;

/// The table row's text end (its last line's content end), in the segment.
const _tableEnd = _tableStart + _table.length;

/// The start of the line after the table, in the segment.
const _belowStart = _tableEnd + 1;

/// The table field's index in the segment.
const _tableRow = 1;

/// A note title the wikilinks resolve to.
final _titles = [NoteTitle(id: 'known', title: 'Known', updatedAt: 1)];

/// The offset of [needle]'s first (or with [last], last) occurrence in
/// [_table] (table field offsets), plus [plus].
int _rowAt(String needle, {int plus = 0, bool last = false}) {
  final i = last ? _table.lastIndexOf(needle) : _table.indexOf(needle);
  if (i < 0) throw ArgumentError('$needle is not in the table fixture');
  return i + plus;
}

/// [_rowAt] as a segment offset.
int _segAt(String needle, {int plus = 0, bool last = false}) =>
    _tableStart + _rowAt(needle, plus: plus, last: last);

/// The table's lines as the one cell splitter (D10) splits them.
final ParsedTable _parsed = parseTable(_table)!;

/// The start and content end of table line [i] (field offsets).
(int, int) _lineRange(int i) {
  var start = 0;
  for (var k = 0; k < i; k++) {
    start = _table.indexOf('\n', start) + 1;
  }
  final nl = _table.indexOf('\n', start);
  return (start, nl < 0 ? _table.length : nl);
}

/// Fails unless [text] derives the row kinds [kinds] (a fixture guard).
void _expectRows(String text, List<RowKind> kinds) {
  expect(
    [for (final r in splitRows(text, atSegmentStart: true)) r.kind],
    kinds,
    reason: 'fixture rows of ${text.replaceAll('\n', r'\n')}',
  );
}

// ---------------------------------------------------------------------------
// Spans: what the field lays out
// ---------------------------------------------------------------------------

/// The span field row [r] of segment 0 lays out (its render editable's).
InlineSpan _fieldSpan(WidgetTester tester, int r) =>
    tableRowFieldState(tester, 0, r).renderEditable.text!;

/// The effective style of the code unit at [offset] of [root]: every
/// ancestor's style merged down to the leaf holding it.
TextStyle _styleAt(InlineSpan root, int offset) {
  var at = 0;
  TextStyle? found;
  bool visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (offset >= at && offset < at + text.length) {
        found = style;
        return false;
      }
      at += text.length;
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (!visit(child, style)) return false;
      }
    }
    return true;
  }

  visit(root, const TextStyle());
  return found ?? (throw TestFailure('no span holds offset $offset'));
}

int? _argb(Color? c) => c?.toARGB32();

/// Field offset [offset] of row [r] renders in [colour].
void _expectColour(
  WidgetTester tester,
  int r,
  int offset,
  Color colour,
  String what,
) {
  final style = _styleAt(_fieldSpan(tester, r), offset);
  expect(
    _argb(style.color),
    colour.toARGB32(),
    reason:
        '$what (offset $offset, ${_charOf(tester, r, offset)}) renders in '
        '$colour, got ${style.color}',
  );
}

String _charOf(WidgetTester tester, int r, int offset) {
  final text = tableRowController(tester, 0, r).text;
  return offset < text.length ? '"${text[offset]}"' : 'end';
}

/// A marker at field offset [offset] of row [r] shows (revealed, dimmed):
/// at a non-zero size in `fg2`.
void _expectRevealedMarker(WidgetTester tester, int r, int offset, String w) {
  final style = _styleAt(_fieldSpan(tester, r), offset);
  expect(
    style.fontSize,
    isNot(0),
    reason: '$w (offset $offset) shows at its normal width, not hidden',
  );
  expect(
    _argb(style.color),
    OmColors.fg2.toARGB32(),
    reason: '$w (offset $offset) shows dimmed in fg2',
  );
}

/// A marker at field offset [offset] of row [r] is hidden (zero size).
void _expectHiddenMarker(WidgetTester tester, int r, int offset, String w) {
  final style = _styleAt(_fieldSpan(tester, r), offset);
  expect(
    style.fontSize,
    0,
    reason: '$w (offset $offset) is not styled as revealed',
  );
}

/// The inline markers of the table's body lines, field offsets, by name.
final Map<String, List<int>> _bodyMarkers = {
  'line 2 [[ of [[Known|alias]]': [
    _rowAt('[[Known|alias'),
    _rowAt('[[Known|alias', plus: 1),
  ],
  'line 2 | inside [[Known|alias]]': [_rowAt('Known|alias', plus: 5)],
  'line 2 ]] of [[Known|alias]]': [
    _rowAt('alias]]', plus: 5),
    _rowAt('alias]]', plus: 6),
  ],
  'line 3 opening **': [_rowAt('**Beta'), _rowAt('**Beta', plus: 1)],
  'line 3 closing **': [_rowAt('Beta**', plus: 4), _rowAt('Beta**', plus: 5)],
  'line 3 opening backtick': [_rowAt('`fmt')],
  'line 3 closing backtick': [_rowAt('fmt`', plus: 3)],
  'line 3 [[ of [[Known]]': [
    _rowAt('[[Known]]', last: true),
    _rowAt('[[Known]]', last: true, plus: 1),
  ],
  'line 3 ]] of [[Known]]': [
    _rowAt('[[Known]]', last: true, plus: 7),
    _rowAt('[[Known]]', last: true, plus: 8),
  ],
};

// ---------------------------------------------------------------------------
// Decorations: what a row's LivePreviewDecorations paints itself
// ---------------------------------------------------------------------------

/// Records only the painting of the object it is handed, not its children's
/// (a rendered grid paints its own pills, D15; the field paints its text).
class _OwnPaintContext extends TestRecordingPaintingContext {
  _OwnPaintContext(super.canvas);

  @override
  void paintChild(RenderObject child, Offset offset) {}
}

/// One filled rounded rect a decorations box painted itself, global.
typedef _Painted = ({Rect rect, Color fill});

/// The live preview decorations box around editor row [r] of segment 0.
RenderBox _decorationsBox(WidgetTester tester, int r) {
  final finder = find.ancestor(
    of: tableEditorRow(0, r),
    matching: find.byType(LivePreviewDecorations, skipOffstage: false),
  );
  expect(finder, findsWidgets, reason: 'row $r has live preview decorations');
  return tester.renderObject<RenderBox>(finder.first);
}

/// Every filled rounded rect row [r]'s decorations box paints itself (its
/// decorations; its child not included), in global coordinates.
List<_Painted> _ownDecorations(WidgetTester tester, int r) {
  final box = _decorationsBox(tester, r);
  final canvas = TestRecordingCanvas();
  box.paint(_OwnPaintContext(canvas), Offset.zero);
  final origin = box.localToGlobal(Offset.zero);
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRRect &&
          (call.invocation.positionalArguments[1] as Paint).style ==
              PaintingStyle.fill)
        (
          rect: (call.invocation.positionalArguments[0] as RRect).outerRect
              .shift(origin),
          fill: (call.invocation.positionalArguments[1] as Paint).color,
        ),
  ];
}

/// The painted decorations of row [r] filled with [fill].
List<_Painted> _filled(WidgetTester tester, int r, Color fill) => [
  for (final d in _ownDecorations(tester, r))
    if (d.fill.toARGB32() == fill.toARGB32()) d,
];

/// The global rect of segment range [start, end) from the seam (D18).
Rect _seamRect(TableBody body, int start, int end) {
  final boxes = body.segmentBoxes();
  final parts = boxes.boxesFor(TextRange(start: start, end: end));
  expect(parts, isNotEmpty, reason: 'the seam measures [$start, $end)');
  final union = parts.reduce((a, b) => a.expandToInclude(b));
  return body.toGlobal(boxes, union);
}

void main() {
  holdFontFetches();
  _contractTests();

  setUpAll(() {
    _expectRows(_text, const [RowKind.prose, RowKind.table, RowKind.prose]);
    _expectRows(_mixed, const [RowKind.prose, RowKind.code, RowKind.table]);
    expect(_parsed.body, hasLength(2), reason: 'fixture: two body lines');
    expect(_parsed.columnCount, 3, reason: 'fixture: three columns');
    expect(
      _parsed.body[0].line.pipes,
      hasLength(4),
      reason: 'fixture: the escaped and wikilink pipes split no cell',
    );
  });

  // -------------------------------------------------------------------------
  // AC1: line height (R13)
  // -------------------------------------------------------------------------
  group('line height (AC1)', () {
    for (final (name, scale) in [
      (
        'every line of a revealed table lays out as one body line as tall as a prose line at text scale 1',
        1.0,
      ),
      (
        'every line of a revealed table lays out as one body line as tall as a prose line at text scale 1.5',
        1.5,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(
          tester,
          _text,
          textScale: scale,
          titles: _titles,
        );
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);

        final lines = body.segmentBoxes().lines;
        final prose = lineHolding(lines, 0);
        final proseHeight = prose.bottom - prose.top;
        expect(proseHeight, greaterThan(20 * scale));
        final seen = <LineBox>{};
        for (final (i, what) in [
          (0, 'header'),
          (1, 'delimiter'),
          (2, 'first body'),
          (3, 'last body'),
        ]) {
          final (start, end) = _lineRange(i);
          final line = lineHolding(lines, _tableStart + start);
          expect(
            line.range.start,
            _tableStart + start,
            reason: 'the $what line starts its own line box',
          );
          expect(
            lineHolding(lines, _tableStart + end - 1),
            same(line),
            reason: 'the $what line lays out as one line',
          );
          expect(
            line.bottom - line.top,
            moreOrLessEquals(proseHeight, epsilon: 0.01),
            reason: 'the $what line is one body line tall',
          );
          seen.add(line);
        }
        expect(seen, hasLength(4));
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC2: header bold (R13)
  // -------------------------------------------------------------------------
  group('header (AC2)', () {
    testWidgets(
      'in a revealed table the header cell text spans are bold and body cell text is not',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_segAt('Alpha'));
        expectTableRevealed(0, _tableRow);
        final span = _fieldSpan(tester, _tableRow);

        for (final cell in _parsed.header.cells) {
          for (var at = cell.start; at < cell.end; at++) {
            final style = _styleAt(span, at);
            expect(
              style.fontWeight,
              FontWeight.w700,
              reason: 'header cell text "${_table[at]}" at $at is bold',
            );
            expect(
              _argb(style.color),
              OmColors.fg0.toARGB32(),
              reason: 'header cell text at $at is fg0',
            );
          }
        }
        for (final (needle, length) in [
          ('Alpha', 5),
          ('a \\| b', 1),
          ('run ', 3),
        ]) {
          for (var k = 0; k < length; k++) {
            final at = _rowAt(needle, plus: k);
            expect(
              _styleAt(span, at).fontWeight,
              isNot(FontWeight.w700),
              reason: 'body cell text "${_table[at]}" at $at is not bold',
            );
          }
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'the pipes and inline markers of a revealed header line stay regular weight in fg2',
      (tester) async {
        const table = '| **H** | `c` |\n|---|---|\n| 1 | 2 |';
        const text = '$_intro\n$table';
        final body = await pumpTable(tester, text);
        await body.placeCaret(_tableStart + table.indexOf('H'));
        expectTableRevealed(0, 1);
        final span = _fieldSpan(tester, 1);
        final header = splitTableLine(table, end: table.indexOf('\n'));

        expect(
          _styleAt(span, table.indexOf('H')).fontWeight,
          FontWeight.w700,
          reason: 'the header text is bold',
        );
        for (final pipe in header.pipes) {
          final style = _styleAt(span, pipe);
          expect(
            style.fontWeight,
            isNot(FontWeight.w700),
            reason: 'pipe $pipe',
          );
          expect(_argb(style.color), OmColors.fg2.toARGB32(), reason: '$pipe');
        }
        for (final marker in [2, 3, 5, 6, 10, 12]) {
          final style = _styleAt(span, marker);
          expect(
            table[marker],
            anyOf('*', '`'),
            reason: 'fixture: $marker is a marker',
          );
          expect(
            style.fontWeight,
            isNot(FontWeight.w700),
            reason: 'marker ${table[marker]} at $marker is regular weight',
          );
          expect(
            _argb(style.color),
            OmColors.fg2.toARGB32(),
            reason: 'marker ${table[marker]} at $marker shows in fg2',
          );
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: pipes and delimiter (R13, D10)
  // -------------------------------------------------------------------------
  group('pipes and delimiter (AC3)', () {
    testWidgets(
      'every cell splitting pipe of a revealed table renders in fg2',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);

        for (final (what, line) in [
          ('header', _parsed.header),
          for (final (i, row) in _parsed.body.indexed) ('body $i', row.line),
        ]) {
          expect(line.pipes, isNotEmpty);
          for (final pipe in line.pipes) {
            _expectColour(tester, _tableRow, pipe, OmColors.fg2, '$what pipe');
            expect(
              _styleAt(_fieldSpan(tester, _tableRow), pipe).fontSize,
              isNot(0),
              reason: '$what pipe $pipe is shown',
            );
          }
        }
      },
      variant: macOnly,
    );

    testWidgets('the whole delimiter line of a revealed table renders in fg2', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text, titles: _titles);
      await body.placeCaret(_segAt('Alpha'));
      expectTableRevealed(0, _tableRow);

      final (start, end) = _lineRange(1);
      expect(_table.substring(start, end), '|:--|--:|:-:|');
      for (var at = start; at < end; at++) {
        _expectColour(tester, _tableRow, at, OmColors.fg2, 'delimiter');
      }
    }, variant: macOnly);

    testWidgets(
      'an escaped pipe and a pipe inside a wikilink keep the cell style while the cell splitting pipes on their line are fg2',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);
        final span = _fieldSpan(tester, _tableRow);

        for (final pipe in _parsed.body[0].line.pipes) {
          _expectColour(tester, _tableRow, pipe, OmColors.fg2, 'line 2 pipe');
        }
        // `\|`: an escape stays plain cell text (fg0), backslash included.
        final escape = _rowAt('\\|');
        for (final at in [escape, escape + 1]) {
          final style = _styleAt(span, at);
          expect(
            _argb(style.color),
            OmColors.fg0.toARGB32(),
            reason:
                '"${_table[at]}" of the escaped pipe keeps the cell text '
                'style, not the fg2 pipe style',
          );
          expect(style.fontSize, isNot(0));
        }
        expect(
          _styleAt(span, escape + 1),
          _styleAt(span, _rowAt('a \\|')),
          reason: 'the escaped pipe renders as the cell text before it',
        );
        // `[[Known|alias]]`: the `|` renders as the rest of its marker run
        // (`[[Known|`), and the wikilink stays whole: its alias is a link.
        final inner = _rowAt('Known|alias', plus: 5);
        expect(_table[inner], '|');
        expect(
          _styleAt(span, inner),
          _styleAt(span, _rowAt('Known|alias')),
          reason: 'the wikilink pipe renders as its own marker run',
        );
        _expectColour(
          tester,
          _tableRow,
          _rowAt('alias]]'),
          OmColors.accent,
          'the wikilink alias (the link is not split at its pipe)',
        );
      },
      variant: macOnly,
    );

    testWidgets('a selected pipe renders in fg1 as a selected marker does', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text, titles: _titles);
      final (start, end) = _lineRange(2);
      await body.select(
        TextSelection(
          baseOffset: _tableStart + start,
          extentOffset: _tableStart + end,
        ),
      );
      expectTableRevealed(0, _tableRow);

      for (final pipe in _parsed.body[0].line.pipes) {
        _expectColour(tester, _tableRow, pipe, OmColors.fg1, 'selected pipe');
      }
      // The unselected header's pipes stay fg2.
      _expectColour(
        tester,
        _tableRow,
        _parsed.header.pipes.first,
        OmColors.fg2,
        'unselected header pipe',
      );
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC4: whole-table reveal (R13, R20)
  // -------------------------------------------------------------------------
  group('whole-table reveal (AC4)', () {
    testWidgets(
      'with the caret on the header line inline markup in a body cell three lines down shows dimmed',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);

        for (final MapEntry(key: what, value: offsets)
            in _bodyMarkers.entries) {
          if (!what.startsWith('line 3')) continue;
          for (final at in offsets) {
            _expectRevealedMarker(tester, _tableRow, at, what);
          }
        }
      },
      variant: macOnly,
    );

    for (final (name, selection) in [
      (
        'a caret at the start of the header line reveals the inline markup of every body line',
        const TextSelection.collapsed(offset: _tableStart),
      ),
      (
        'a caret on the delimiter line reveals the inline markup of every body line',
        TextSelection.collapsed(offset: _tableStart + _lineRange(1).$1 + 2),
      ),
      (
        'a caret at the end of the last body line reveals the inline markup of the first body line',
        const TextSelection.collapsed(offset: _tableEnd),
      ),
      (
        'a selection from the line above ending on the header line reveals the inline markup of every body line',
        TextSelection(baseOffset: 2, extentOffset: _segAt('Notes')),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.select(selection);
        expectTableRevealed(0, _tableRow);

        for (final MapEntry(key: what, value: offsets)
            in _bodyMarkers.entries) {
          for (final at in offsets) {
            _expectRevealedMarker(tester, _tableRow, at, what);
          }
        }
      }, variant: macOnly);
    }

    for (final (name, offset, leave) in [
      (
        'with the caret on the line above the table nothing in its field is styled as revealed',
        _intro.length,
        false,
      ),
      (
        'with the caret on the line below the table nothing in its field is styled as revealed',
        _belowStart,
        false,
      ),
      (
        'with focus outside the segment nothing in the table field is styled as revealed',
        _segAt('Beta'),
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        // Revealed first, so the field had revealed markup to drop.
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);
        if (leave) {
          await body.focusOutside();
        } else {
          await body.placeCaret(offset);
        }
        expectTableRendered(0, _tableRow);

        for (final MapEntry(key: what, value: offsets)
            in _bodyMarkers.entries) {
          for (final at in offsets) {
            _expectHiddenMarker(tester, _tableRow, at, what);
          }
        }
        for (final at in [
          _rowAt('**Beta'),
          _rowAt('`fmt'),
          _rowAt('[[Known]]', last: true),
        ]) {
          expect(
            _styleAt(_fieldSpan(tester, _tableRow), at).color,
            isNot(OmColors.fg2),
            reason: 'marker at $at is not shown dimmed',
          );
        }
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC5: pills (D15)
  // -------------------------------------------------------------------------
  group('pills (AC5)', () {
    testWidgets(
      'a revealed table with an inline code span in a cell paints exactly one pill inside that cell text rect from the seam',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        // The caret on the header line: the code span is three lines down.
        await body.placeCaret(_segAt('Step'));
        expectTableRevealed(0, _tableRow);

        final pills = _filled(tester, _tableRow, OmColors.surface4);
        expect(pills, hasLength(1), reason: 'one pill for the one code span');
        final cell = _parsed.body[1].cells[1];
        expect(cell.text(_table), 'run `fmt`');
        final cellRect = _seamRect(
          body,
          _tableStart + cell.start,
          _tableStart + cell.end,
        );
        final contentRect = _seamRect(
          body,
          _segAt('fmt`'),
          _segAt('fmt`', plus: 3),
        );
        final pill = pills.single.rect;
        expect(
          pill.left,
          greaterThanOrEqualTo(cellRect.left - 0.01),
          reason: 'pill $pill starts inside cell $cellRect',
        );
        expect(pill.right, lessThanOrEqualTo(cellRect.right + 0.01));
        expect(pill.top, greaterThanOrEqualTo(cellRect.top - 0.01));
        expect(pill.bottom, lessThanOrEqualTo(cellRect.bottom + 0.01));
        expect(
          pill.left,
          lessThan(contentRect.left),
          reason: 'the pill sits under the code content',
        );
        expect(pill.right, greaterThan(contentRect.right));
      },
      variant: macOnly,
    );

    testWidgets('a rendered table row field contributes no decorations', (
      tester,
    ) async {
      final body = await pumpTable(tester, _text, titles: _titles);
      await body.placeCaret(_segAt('fmt'));
      expectTableRevealed(0, _tableRow);
      expect(_filled(tester, _tableRow, OmColors.surface4), hasLength(1));

      await body.placeCaret(_intro.length);

      expectTableRendered(0, _tableRow);
      expect(
        _ownDecorations(tester, _tableRow),
        isEmpty,
        reason: 'the grid paints its own pills (D15): none from the field',
      );
    }, variant: macOnly);

    testWidgets(
      'a table row field with focus outside the segment contributes no decorations',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_segAt('fmt'));
        expectTableRevealed(0, _tableRow);

        await body.focusOutside();

        expectTableRendered(0, _tableRow);
        expect(_ownDecorations(tester, _tableRow), isEmpty);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: editing (R13)
  // -------------------------------------------------------------------------
  group('editing (AC6)', () {
    testWidgets(
      'typing a character in a revealed cell gives one content report and one undo record and Cmd Z restores the bytes',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        await body.placeCaret(_intro.length);
        final at = _segAt('Alpha', plus: 2);
        await body.placeCaret(at);
        expectTableRevealed(0, _tableRow);
        body.resetCounts();

        await body.typeChar('x');

        final typed = _text.replaceRange(at, at, 'x');
        expect(body.text(), typed);
        expect(body.reportCount, 1);
        expect(body.reports.last, typed);
        expect(body.undoRecordCount, 1);
        expectTableRevealed(0, _tableRow);
        await body.settleTyping();

        await tester.macCmdChord(LogicalKeyboardKey.keyZ);
        await tester.pump();

        expect(body.text(), _text, reason: 'Cmd+Z restores the bytes');
        expect(body.reports.last, _text);
        await body.settleTyping();
      },
      variant: macOnly,
    );

    testWidgets(
      'typing two brackets in a revealed cell opens the wikilink popover anchored at the caret rect from the seam',
      (tester) async {
        final body = await pumpTable(tester, _text, titles: _titles);
        final at = _segAt('Alpha', plus: 5);
        await body.placeCaret(at);
        expectTableRevealed(0, _tableRow);

        await body.typeChar('[');
        await body.typeChar('[');
        await tester.pump();

        expect(body.text(), _text.replaceRange(at, at, '[['));
        expectTableRevealed(0, _tableRow);
        final popover = find.byKey(const Key('wikilink-popover'));
        expect(popover, findsOneWidget);
        final boxes = body.segmentBoxes();
        final caret = body.toGlobal(boxes, boxes.caretRect(at + 2));
        final topLeft = tester.getTopLeft(popover);
        expect(topLeft.dx, moreOrLessEquals(caret.left, epsilon: 0.5));
        // The popover sits its fixed 6 px gap below its anchor.
        expect(topLeft.dy, moreOrLessEquals(caret.bottom + 6, epsilon: 0.5));
        await body.settleTyping();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: prose and code rows keep their spans and decorations (regression)
  // -------------------------------------------------------------------------
  group('prose and code rows next to a table (AC7)', () {
    testWidgets(
      'a paragraph next to a revealed table keeps its spans and its one code pill',
      (tester) async {
        final body = await pumpTable(tester, _mixed);
        await body.placeCaret(_mixed.indexOf('| A'));
        expectTableRevealed(0, 2);
        final span = _fieldSpan(tester, 0);

        for (final at in [
          _para.indexOf('**'),
          _para.indexOf('**') + 1,
          _para.lastIndexOf('**'),
          _para.indexOf('`'),
          _para.lastIndexOf('`'),
        ]) {
          expect(
            _styleAt(span, at).fontSize,
            0,
            reason: 'paragraph marker at $at stays hidden',
          );
        }
        expect(
          _styleAt(span, _para.indexOf('bold')).fontWeight,
          FontWeight.w700,
        );
        expect(
          _argb(_styleAt(span, _para.indexOf('tick')).color),
          OmColors.fg1.toARGB32(),
          reason: 'inline code text is fg1',
        );
        expect(
          _argb(_styleAt(span, _para.indexOf('with')).color),
          OmColors.fg0.toARGB32(),
          reason: 'plain paragraph text is fg0, not a table pipe colour',
        );
        expect(_styleAt(span, 0).fontWeight, isNot(FontWeight.w700));
        expect(_filled(tester, 0, OmColors.surface4), hasLength(1));
        expect(_ownDecorations(tester, 0), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'a code block next to a revealed table keeps its code box and hidden fences',
      (tester) async {
        final body = await pumpTable(tester, _mixed);
        await body.placeCaret(_mixed.indexOf('| A'));
        expectTableRevealed(0, 2);
        final code = tableRowController(tester, 0, 1);
        expect(code.text, _code);
        expect(code.codeRow, isTrue);
        expect(code.strutStyle?.fontSize, 8, reason: 'the code-row strut');
        final span = _fieldSpan(tester, 1);

        expect(_styleAt(span, 0).fontSize, 0, reason: 'opening fence hidden');
        expect(
          _styleAt(span, _code.lastIndexOf('```')).fontSize,
          0,
          reason: 'closing fence hidden',
        );
        expect(
          _argb(_styleAt(span, _code.indexOf('code line')).color),
          OmColors.fg1.toARGB32(),
        );
        final boxes = _filled(tester, 1, OmColors.surface1);
        expect(boxes, hasLength(1), reason: 'one code box');
        expect(_filled(tester, 1, OmColors.surface4), isEmpty);
        expect(_ownDecorations(tester, 1), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'a pipe in a prose line above a table keeps the prose text style',
      (tester) async {
        // A `|` in a prose row is no table pipe: it keeps the text style.
        const text = 'a | b\n$_table';
        final body = await pumpTable(tester, text, titles: _titles);
        await body.placeCaret(2);
        _expectColour(tester, 0, 2, OmColors.fg0, 'a prose pipe');
        expectTableRendered(0, 1);
      },
      variant: macOnly,
    );
  });
}

/// The span `buildLivePreviewSpan` gives [text] with the base style.
TextSpan _span(String text, {TextSelection? selection, bool hidden = false}) =>
    buildLivePreviewSpan(
      text,
      style: const TextStyle(color: OmColors.fg0, fontSize: 15),
      selection: selection,
      forceHidden: hidden,
    );

/// Contracts the doc comments promise, pinned at the span builder, the
/// shared grouping rule and the pills (verify round).
void _contractTests() {
  group('table contracts (verify)', () {
    const table = '| Head | `c` |\n|:-|-:|\n| a | b |';
    const intro = 'x\n$table';
    final headerPipe = intro.indexOf('|');

    for (final (name, selection, hidden) in [
      (
        'a table the caret is not on shows no pipe or header styling at the span level',
        const TextSelection.collapsed(offset: 0),
        false,
      ),
      (
        'a table built with forceHidden shows no pipe or header styling at the span level',
        const TextSelection.collapsed(offset: 4),
        true,
      ),
    ]) {
      test(name, () {
        final span = _span(intro, selection: selection, hidden: hidden);
        final delimiter = intro.indexOf('|:');
        expect(_styleAt(span, headerPipe).color, OmColors.fg0);
        expect(
          _styleAt(span, headerPipe).fontSize,
          15,
          reason: 'an unrevealed pipe is shown, never hidden as a marker',
        );
        expect(
          _styleAt(span, intro.indexOf('H')).fontWeight,
          isNot(FontWeight.w700),
          reason: 'header cell text is bold only while revealed',
        );
        for (var at = delimiter; at < delimiter + 6; at++) {
          expect(
            _styleAt(span, at).color,
            OmColors.fg0,
            reason: 'delimiter char $at is a marker only while revealed',
          );
          expect(
            _styleAt(span, at).fontSize,
            15,
            reason: 'delimiter char $at stays shown while not revealed',
          );
        }
        expect(_styleAt(span, intro.indexOf('b')).color, OmColors.fg0);
      });
    }

    test(
      'a revealed table at the span level styles pipes delimiter and header',
      () {
        final span = _span(
          intro,
          selection: const TextSelection.collapsed(offset: 4),
        );
        expect(_styleAt(span, headerPipe).color, OmColors.fg2);
        expect(_styleAt(span, intro.indexOf('H')).fontWeight, FontWeight.w700);
        final delimiter = intro.indexOf('|:');
        for (var at = delimiter; at < delimiter + 6; at++) {
          expect(_styleAt(span, at).color, OmColors.fg2, reason: 'char $at');
        }
        expect(
          _styleAt(span, intro.indexOf('a |')).fontWeight,
          isNot(FontWeight.w700),
        );
      },
    );

    test(
      'a code span across a pipe forms no code token in a revealed or a hidden table',
      () {
        const t = '| `a | b` | c |\n|---|---|---|\n| 1 | 2 | 3 |';
        for (final (selection, hidden) in [
          (const TextSelection.collapsed(offset: 0), false),
          (const TextSelection.collapsed(offset: 40), false),
          (const TextSelection.collapsed(offset: 0), true),
        ]) {
          final span = _span(t, selection: selection, hidden: hidden);
          final tick = t.indexOf('`');
          final closing = t.lastIndexOf('`');
          for (final at in [tick, closing]) {
            expect(
              _styleAt(span, at).fontSize,
              15,
              reason:
                  'the backtick at $at is plain text, never a hidden marker',
            );
            expect(
              _styleAt(span, at).color,
              OmColors.fg0,
              reason: 'the backtick at $at is cell text, not a code marker',
            );
          }
          expect(
            _styleAt(span, t.indexOf('a ')).color,
            isNot(OmColors.fg1),
            reason: 'no code content style across the pipe',
          );
        }
      },
    );

    test(
      'the table grouping rule ends a table at its last delimiter or body line',
      () {
        MdLineKind kindOf(String t, int i) =>
            classifyLines(t, atSegmentStart: true)[i].kind;
        expect(kindOf('p\n| a |\n|---|', 1), MdLineKind.tableHeader);

        List<MdLine> lines(String t) => classifyLines(t, atSegmentStart: true);
        // Header and delimiter only.
        expect(tableLastLine(lines('p\n| a |\n|---|'), 1), 2);
        // Header, delimiter and two body lines, then prose.
        expect(tableLastLine(lines('p\n| a |\n|---|\n| 1 |\n| 2 |\nq'), 1), 4);
        // The table at the top of the text.
        expect(tableLastLine(lines('| a |\n|---|\n| 1 |'), 0), 2);
      },
    );

    testWidgets(
      'revealed header and body cells each paint a pill for their own code span and a code span across a pipe paints none',
      (tester) async {
        const t =
            '| `h` | `p | q` |\n'
            '|---|---|---|\n'
            '| `b` | y | z |';
        const text = '$_intro\n$t';
        final body = await pumpTable(tester, text);
        await body.placeCaret(_tableStart + t.indexOf('y'));
        expectTableRevealed(0, 1);

        final pills = _filled(tester, 1, OmColors.surface4);
        expect(pills, hasLength(2), reason: 'h and b only; `p | q` is no span');
        for (final content in ['h', 'b']) {
          final at = _tableStart + t.indexOf('`$content`') + 1;
          final rect = _seamRect(body, at, at + 1);
          expect(
            pills.where((p) => p.rect.overlaps(rect)),
            hasLength(1),
            reason: 'one pill under the code content $content',
          );
        }
      },
      variant: macOnly,
    );
  });
}

/// A paragraph (row 0), a fenced code block (row 1) and a table (row 2).
const _para = 'Para with **bold** and `tick`';
const _code = '```\ncode line\n```';
const _mixed = '$_para\n$_code\n| A | B |\n|---|---|\n| 1 | 2 |';
