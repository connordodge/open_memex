// WI #205 (Tables 4, Spec #197 R5, R6, R16-R20, R23, R26, R27; TD4, TD5,
// TD8; rulings D13, D15, D16, D18, D19a, D21): the rendered table grid,
// design B "Ruled rows".
// - Heights on the line grid: header band = header lines x L + H, body row
//   = tallest cell lines x L (L 22.95, H 8, c 8.1 at text scale 1, all
//   scaled by the text scale; design packs #203 and #205).
// - The grid spans the text column, wraps cell text inside its column and
//   never overflows; alignment per column; uneven rows (R6).
// - Paint (D15): band, then code pills, then rules, then text; no
//   selection paint (R16). Pixel probes only in each cell's left/right
//   padding strip, the band's bottom 4 px and the 1 px rule rows with x in a
//   padding strip (D19a).
// - Cell spans (D16): buildLivePreviewSpan(cellText, itemText: true,
//   forceHidden: true, isResolved, cmdHover shifted to cell-local).
// - The line-box seam (D13) in the table row's field-text offsets, and
//   Up/Down through it (R23).
// - Semantics in reading order (R26).
//
// Design numbers are asserted here and in T2 only (D18). Cells are found by
// the harness's `tableCell` Key finder (TD8); each cell's text is one
// RichText at or under that Key.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/markdown_table.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/table_harness.dart';

// ------------------------------------------------------------ design numbers

/// L: one body line at text scale 1 (13.5 x 1.7, pack #203).
const double _l = 22.95;

/// H: the hidden delimiter line the header band takes in (pack #203).
const double _h = 8;

/// c: a cell's left and right padding, one mono column (0.6 x 13.5).
const double _c = 8.1;

/// The header band of a one-line header at text scale 1: L + H.
const double _band = _l + _h;

const double _eps = 0.01;

// ------------------------------------------------------------------ fixtures

const _intro = 'Intro line';
const _below = 'Below line';

/// A note body with [table] as row 1 of segment 0, between two prose rows.
String _doc(String table) => '$_intro\n$table\n$_below';

/// One-line header, three one-line body rows.
const _heightTable = '| H1 | H2 |\n|---|---|\n| a | b |\n| c | d |\n| e | f |';

/// Eight 9-letter words: wraps to two lines in a column of the editor
/// width (a fixture guard checks it).
const _longCell =
    'aaaaaaaaa bbbbbbbbb ccccccccc ddddddddd '
    'eeeeeeeee fffffffff ggggggggg hhhhhhhhh';

/// A table whose first body row wraps (its second cell) and whose second
/// body row does not.
const _wrapTable =
    '| Topic | Notes |\n|---|---|\n| x | $_longCell |\n| y | z |';

/// Three columns of equal natural width (5 glyphs each): left, center and
/// right aligned, so each column is a third of the grid.
const _alignTable =
    '| Lefty | Midst | Right |\n|:--|:-:|--:|\n| ab | cd | ef |\n| a | bcd | e |';

/// Two columns of equal natural width and three body rows (two rules).
const _ruledTable =
    '| Alpha | Bravo |\n|---|---|\n| a | b |\n| c | d |\n| e | f |';

/// A short body row (missing cells) and a long one (a dropped cell).
const _unevenTable =
    '| A | B | C |\n|---|---|---|\n| one |\n| p | q | r | extra |';

/// A header-only table.
const _headerOnly = '| A | B |\n|---|---|';

/// A table wider than the 720 px text column: six columns of long cell
/// text and a word longer than its column.
const _wideTable =
    '| Source | Origin | Topic | Takeaway | Pages | Read |\n'
    '|---|---|---|---|--:|:-:|\n'
    '| Obsidian live preview notes | Obsidian forum | how markers hide per line | reveal only the caret line | 12 | yes |\n'
    '| Flutter TextSpan docs | Antidisestablishmentarianism | buildTextSpan override | styling never moves offsets | 4 | yes |';

/// Inline formatting, links and block-looking markers in cells (R20).
const _inlineTable =
    '| Kind | Sample |\n'
    '|---|---|\n'
    '| fmt | **bold** *it* ~~s~~ `code` |\n'
    '| links | [t](https://x) [[Note]] [[Missing]] |\n'
    '| task | [ ] x |\n'
    '| list | - y |\n'
    '| head | # z |\n'
    '| num | 1. w |';

/// One code span in a body cell, two body rows (one rule).
const _pillTable =
    '| Kind | Sample |\n|---|---|\n| a | x `code` y |\n| b | c |';

/// The line-box seam fixture: hidden markup, a dropped cell, three
/// alignments.
const _seamTable =
    '| Name | Qty | Note |\n'
    '|:--|:-:|--:|\n'
    '| **Alpha** | 1 | ok |\n'
    '| Beta | 2 | fine | dropped |\n'
    '| Gamma | 3 | yes |';

/// Reading order fixture: the last body row has an empty cell.
const _semanticsTable =
    '| Step | Notes |\n|---|---|\n| Alpha | one |\n| Beta | |';

/// Up/Down fixture: two columns of equal natural width.
const _arrowTable = '| aaaa | bbbb |\n|---|---|\n| cc | dd |\n| ee | ff |';
const _arrowAbove = 'Above line with enough characters to reach two columns';
const _arrowBelow = 'Below line with enough characters to reach two columns';

// ------------------------------------------------------------------- helpers

/// The parsed table of [table] (T1's one splitter).
ParsedTable _parsed(String table) =>
    parseTable(table) ?? (throw TestFailure('fixture is not a table'));

/// Grid row [g]'s source line (0: the header, 1 + i: body row i).
TableLine _sourceLine(ParsedTable t, int g) =>
    g == 0 ? t.header : t.body[g - 1].line;

/// The finder of cell ([row], [col])'s RichText in table row 1 of segment 0
/// (Key `editor-table-cell-0-1-<row>-<col>`, TD8).
Finder _cellText(int row, int col) => find.descendant(
  of: tableCell(0, 1, row, col),
  matching: find.byType(RichText),
  matchRoot: true,
);

/// Cell ([row], [col])'s laid-out paragraph.
RenderParagraph _cellParagraph(WidgetTester tester, int row, int col) =>
    tester.renderObject<RenderParagraph>(_cellText(row, col));

/// The global rect of [p]'s glyphs in `[start, end)` (all of it by
/// default), each line's boxes at its full line height.
Rect _glyphs(RenderParagraph p, {int start = 0, int? end}) {
  final len = p.text.toPlainText().length;
  final boxes = p.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end ?? len),
  );
  if (boxes.isEmpty) throw TestFailure('no glyph boxes in $start..$end');
  final r = boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
  return Rect.fromPoints(
    p.localToGlobal(r.topLeft),
    p.localToGlobal(r.bottomRight),
  );
}

/// How many visual lines [p] laid its text out on.
int _lineCount(RenderParagraph p) {
  final len = p.text.toPlainText().length;
  if (len == 0) return 1;
  final tops = <int>{
    for (final b in p.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: len),
      boxHeightStyle: ui.BoxHeightStyle.max,
    ))
      (b.top * 2).round(),
  };
  return tops.length;
}

/// Every non-empty RichText text under the grid of table row 1.
List<String> _gridTexts(WidgetTester tester) => [
  for (final e
      in find
          .descendant(of: tableGrid(0, 1), matching: find.byType(RichText))
          .evaluate())
    if ((e.widget as RichText).text.toPlainText().isNotEmpty)
      (e.widget as RichText).text.toPlainText(),
];

/// The grid's line boxes (field-text offsets of the table row).
LineBoxSource _gridBoxes(WidgetTester tester) =>
    tableGridState(tester, 0, 1).lineBoxes() ??
    (throw TestFailure('the grid is not laid out'));

/// [local] (in [boxes]' box coordinates) relative to the grid's top-left.
Rect _gridRel(WidgetTester tester, LineBoxSource boxes, Rect local) {
  final origin = tester.getTopLeft(tableGrid(0, 1));
  return Rect.fromPoints(
    boxes.box.localToGlobal(local.topLeft) - origin,
    boxes.box.localToGlobal(local.bottomRight) - origin,
  );
}

/// The grid-relative [point] in [boxes]' box coordinates.
Offset _boxPoint(WidgetTester tester, LineBoxSource boxes, Offset point) =>
    boxes.box.globalToLocal(tester.getTopLeft(tableGrid(0, 1)) + point);

/// The leaves (text and own style) of a span tree, in order.
List<(String, TextStyle?)> _leaves(InlineSpan span) {
  final out = <(String, TextStyle?)>[];
  span.visitChildren((s) {
    if (s is TextSpan && (s.children == null || s.children!.isEmpty)) {
      out.add((s.text ?? '', s.style));
    }
    return true;
  });
  return out;
}

/// The effective style (every ancestor's style merged) of the first leaf
/// of [root] whose text is [text].
TextStyle _styleOf(InlineSpan root, String text) {
  TextStyle? found;
  void walk(InlineSpan s, TextStyle inherited) {
    if (found != null) return;
    final style = inherited.merge(s.style);
    if (s is TextSpan) {
      final kids = s.children;
      if ((kids == null || kids.isEmpty) && s.text == text) {
        found = style;
        return;
      }
      for (final k in kids ?? const <InlineSpan>[]) {
        walk(k, style);
      }
    }
  }

  walk(root, const TextStyle());
  return found ?? (throw TestFailure('no leaf "$text" in the cell span'));
}

/// The span cell ([row], [col]) shows.
InlineSpan _cellSpan(WidgetTester tester, int row, int col) =>
    tester.widget<RichText>(_cellText(row, col)).text;

/// The cell text of cell [col] of grid row [g] of [t] in [table].
String _cellString(String table, ParsedTable t, int g, int col) {
  final cells = g == 0 ? t.header.cells : t.body[g - 1].cells;
  return cells[col].text(table);
}

// Pixels -------------------------------------------------------------------

/// Captured pixels of a region, read by global point. Pixels are
/// premultiplied RGBA (`rawRgba`); the editor paints no background under
/// the grid in tests, so an unpainted pixel is transparent.
class _Wi205Pixels {
  _Wi205Pixels(this._bytes, this.width, this.height, this.rect, this.ratio);

  final ByteData _bytes;
  final int width;
  final int height;
  final Rect rect;
  final double ratio;

  /// The pixel at global [point].
  Color at(Offset point) {
    final x = ((point.dx - rect.left) * ratio).floor();
    final y = ((point.dy - rect.top) * ratio).floor();
    expect(x, inInclusiveRange(0, width - 1), reason: 'x of $point');
    expect(y, inInclusiveRange(0, height - 1), reason: 'y of $point');
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _bytes.getUint8(i + 3),
      _bytes.getUint8(i),
      _bytes.getUint8(i + 1),
      _bytes.getUint8(i + 2),
    );
  }
}

/// Captures the pixels of [of]'s global rect from its nearest repaint
/// boundary (it included) at [ratio] pixels per logical pixel.
Future<_Wi205Pixels> _wi205Capture(
  WidgetTester tester,
  Finder of, {
  double ratio = 4,
}) async {
  RenderObject? node = tester.renderObject(of);
  while (node != null && !(node is RenderBox && node.isRepaintBoundary)) {
    node = node.parent;
  }
  final boundary = node! as RenderBox;
  final region = tester.getRect(of);
  final origin = boundary.localToGlobal(Offset.zero);
  final layer = boundary.debugLayer! as OffsetLayer;
  final image = (await tester.runAsync(
    () => layer.toImage(region.shift(-origin), pixelRatio: ratio),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final pixels = _Wi205Pixels(bytes, image.width, image.height, region, ratio);
  image.dispose();
  return pixels;
}

int _channel(double c) => (c * 255).round();

/// Matches a captured (premultiplied) pixel whose RGBA channels are each
/// within 3 of [expected]; a straight-alpha [expected] (a token colour) is
/// premultiplied first.
class _Wi205Near extends Matcher {
  const _Wi205Near(this.expected, {required this.straight});

  final Color expected;
  final bool straight;

  Color get _target {
    if (!straight) return expected;
    final a = expected.a;
    return Color.from(
      alpha: a,
      red: expected.r * a,
      green: expected.g * a,
      blue: expected.b * a,
    );
  }

  static List<int> _channels(Color c) => [
    _channel(c.r),
    _channel(c.g),
    _channel(c.b),
    _channel(c.a),
  ];

  static String _hex(Color c) =>
      '0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! Color) return false;
    final a = _channels(item);
    final b = _channels(_target);
    for (var i = 0; i < 4; i++) {
      if ((a[i] - b[i]).abs() > 3) return false;
    }
    return true;
  }

  @override
  Description describe(Description description) =>
      description.add('a pixel near ${_hex(_target)} (+-3)');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) => item is Color
      ? mismatchDescription.add('was ${_hex(item)}')
      : mismatchDescription.add('was not a Color');
}

/// A captured pixel showing the straight-alpha token colour [c].
Matcher _isColor(Color c) => _Wi205Near(c, straight: true);

/// A captured pixel equal to the captured pixel [p].
Matcher _isPixel(Color p) => _Wi205Near(p, straight: false);

/// A captured pixel showing a `line2` rule over the captured background
/// [bg] (transparent or opaque, so it reads the same premultiplied).
Matcher _isRuleOver(Color bg) {
  expect(bg.a == 0 || bg.a == 1, isTrue, reason: 'background $bg');
  return _isColor(Color.alphaBlend(OmColors.line2, bg));
}

// Paint recording -------------------------------------------------------------

/// One recorded fill or text draw of the grid, grid-local.
typedef _Wi205Op = ({int index, Symbol kind, Color? color, Rect? rect});

/// Every fill (drawRect, drawRRect, drawPath, drawLine) and drawParagraph
/// the grid makes when it paints, in order, in grid-local coordinates.
List<_Wi205Op> _recordGrid(WidgetTester tester) {
  final root = tester.renderObject<RenderBox>(tableGrid(0, 1));
  final canvas = TestRecordingCanvas();
  root.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final stack = <Offset>[];
  var shift = Offset.zero;
  final out = <_Wi205Op>[];
  var index = 0;
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
      case #drawRect:
        out.add((
          index: index++,
          kind: #drawRect,
          color: (i.positionalArguments[1] as Paint).color,
          rect: (i.positionalArguments[0] as Rect).shift(shift),
        ));
      case #drawRRect:
        out.add((
          index: index++,
          kind: #drawRRect,
          color: (i.positionalArguments[1] as Paint).color,
          rect: (i.positionalArguments[0] as RRect).outerRect.shift(shift),
        ));
      case #drawPath:
        out.add((
          index: index++,
          kind: #drawPath,
          color: (i.positionalArguments[1] as Paint).color,
          rect: (i.positionalArguments[0] as Path).getBounds().shift(shift),
        ));
      case #drawLine:
        out.add((
          index: index++,
          kind: #drawLine,
          color: (i.positionalArguments[2] as Paint).color,
          rect: Rect.fromPoints(
            i.positionalArguments[0] as Offset,
            i.positionalArguments[1] as Offset,
          ).shift(shift),
        ));
      case #drawParagraph:
        out.add((
          index: index++,
          kind: #drawParagraph,
          color: null,
          rect: null,
        ));
    }
  }
  return out;
}

/// The recorded fills of [ops] in [color] (compared as ARGB: Paint keeps
/// colours in 32-bit floats).
List<_Wi205Op> _fills(List<_Wi205Op> ops, Color color) => [
  for (final op in ops)
    if (op.color != null && op.color!.toARGB32() == color.toARGB32()) op,
];

// Semantics -------------------------------------------------------------------

/// Every semantics label of a node overlapping global [area] (the grid's
/// cells may merge into an enclosing node), in traversal order, each split
/// at line breaks, empty ones dropped.
List<String> _labelsInside(WidgetTester tester, Rect area) {
  final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
  final out = <String>[];
  void visit(SemanticsNode node, Matrix4 parent) {
    final m = node.transform == null
        ? parent
        : parent.multiplied(node.transform!);
    final rect = MatrixUtils.transformRect(m, node.rect);
    if (node.label.isNotEmpty && area.deflate(1).overlaps(rect)) {
      out.addAll(node.label.split('\n'));
    }
    for (final child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    )) {
      visit(child, m);
    }
  }

  visit(owner.rootSemanticsNode!, Matrix4.identity());
  return [
    for (final l in out)
      if (l.trim().isNotEmpty) l.trim(),
  ];
}

// Bare grid ---------------------------------------------------------------------

const _bareKey = Key('wi205-bare-grid');

/// Pumps a [TableGrid] of [text] on its own, 600 px wide, with
/// [headerBand].
Future<void> _pumpBareGrid(
  WidgetTester tester,
  String text, {
  required Color headerBand,
}) async {
  tester.view
    ..physicalSize = const Size(800, 600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Material(
        color: OmColors.surface2,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 600,
              child: RepaintBoundary(
                child: TableGrid(
                  key: _bareKey,
                  text: text,
                  style: editorBodyStyle(),
                  headerBand: headerBand,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  holdFontFetches();

  setUpAll(() {
    for (final t in [
      _heightTable,
      _wrapTable,
      _alignTable,
      _ruledTable,
      _unevenTable,
      _headerOnly,
      _wideTable,
      _inlineTable,
      _pillTable,
      _seamTable,
      _semanticsTable,
      _arrowTable,
    ]) {
      _parsed(t);
    }
  });

  // -------------------------------------------------------------------------
  // AC1: heights (R18)
  // -------------------------------------------------------------------------
  group('heights (AC1, R18)', () {
    testWidgets(
      'a one-line header and three one-line body rows are 30.95 plus 3 x 22.95 high at text scale 1',
      (tester) async {
        await pumpTable(tester, _doc(_heightTable));
        expectTableRendered(0, 1);

        expect(
          tester.getSize(tableGrid(0, 1)).height,
          moreOrLessEquals(_band + 3 * _l, epsilon: _eps),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a body row whose longest cell wraps to two lines is 45.9 high and its shorter cell starts at the row top',
      (tester) async {
        await pumpTable(tester, _doc(_wrapTable));
        final long = _cellParagraph(tester, 1, 1);
        expect(_lineCount(long), 2, reason: 'fixture: the long cell wraps');
        expect(_lineCount(_cellParagraph(tester, 2, 1)), 1);

        final grid = tester.getRect(tableGrid(0, 1));
        expect(
          grid.height,
          moreOrLessEquals(_band + 2 * _l + _l, epsilon: _eps),
          reason: 'band 30.95, wrapped row 45.9, last row 22.95',
        );
        // Vertical-align top: the one-line cell of the wrapped row sits on
        // the row's first line.
        final short = _glyphs(_cellParagraph(tester, 1, 0));
        expect(short.top, greaterThanOrEqualTo(grid.top + _band - _eps));
        expect(short.bottom, lessThanOrEqualTo(grid.top + _band + _l + _eps));
        // The wrapped cell spans both lines of its row and starts each line
        // at the content left (no hanging indent), wrapping at a space.
        final both = _glyphs(long);
        expect(both.top, greaterThanOrEqualTo(grid.top + _band - _eps));
        expect(
          both.bottom,
          lessThanOrEqualTo(grid.top + _band + 2 * _l + _eps),
        );
        final text = long.text.toPlainText();
        final lastBox = long
            .getBoxesForSelection(
              TextSelection(
                baseOffset: text.length - 1,
                extentOffset: text.length,
              ),
            )
            .single;
        final second = long.getPositionForOffset(
          Offset(0, (lastBox.top + lastBox.bottom) / 2),
        );
        expect(second.offset, greaterThan(0), reason: 'second line start');
        expect(text[second.offset - 1], ' ', reason: 'wraps at a space');
        final firstLine = _glyphs(long, end: 1);
        final secondLine = _glyphs(
          long,
          start: second.offset,
          end: second.offset + 1,
        );
        expect(secondLine.left, moreOrLessEquals(firstLine.left, epsilon: 0.5));

        // One line box per visual line of the wrapped row (TD5, D13).
        final boxes = _gridBoxes(tester);
        final t = _parsed(_wrapTable);
        final wrapped = [
          for (final l in boxes.lines)
            if (l.range.start >= t.body[0].line.start &&
                l.range.start < t.body[1].line.start)
              _gridRel(tester, boxes, Rect.fromLTRB(0, l.top, 0, l.bottom)),
        ];
        expect(wrapped, hasLength(2), reason: 'two visual lines');
        expect(wrapped[0].top, moreOrLessEquals(_band, epsilon: _eps));
        expect(wrapped[0].bottom, moreOrLessEquals(_band + _l, epsilon: _eps));
        expect(wrapped[1].top, moreOrLessEquals(_band + _l, epsilon: _eps));
        expect(
          wrapped[1].bottom,
          moreOrLessEquals(_band + 2 * _l, epsilon: _eps),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the grid lays out again with a new row and rule when the table text changes',
      (tester) async {
        final body = await pumpTable(tester, _doc(_heightTable));
        expectTableRendered(0, 1);
        expect(
          tester.getSize(tableGrid(0, 1)).height,
          moreOrLessEquals(_band + 3 * _l, epsilon: _eps),
        );

        await body.serverWrite(_doc('$_heightTable\n| g | h |'));
        expectTableRendered(0, 1);

        final grid = tester.getRect(tableGrid(0, 1));
        expect(grid.height, moreOrLessEquals(_band + 4 * _l, epsilon: _eps));
        expect(_cellParagraph(tester, 4, 0).text.toPlainText(), 'g');
        expect(_cellParagraph(tester, 4, 1).text.toPlainText(), 'h');
        // Body row 3 is no longer the last: it gets its rule.
        final px = await _wi205Capture(tester, tableGrid(0, 1));
        final y = _band + 3 * _l - 0.5;
        final bg = px.at(grid.topLeft + Offset(_c / 2, y - 3));
        expect(px.at(grid.topLeft + Offset(_c / 2, y)), _isRuleOver(bg));
      },
      variant: macOnly,
    );

    testWidgets(
      'at text scale 1.5 the band, body rows and cell padding grow from the scaled metrics',
      (tester) async {
        await pumpTable(tester, _doc(_heightTable), textScale: 1.5);
        expectTableRendered(0, 1);
        const scale = 1.5;

        final grid = tester.getRect(tableGrid(0, 1));
        expect(
          grid.height,
          moreOrLessEquals(scale * (_l + _h) + 3 * scale * _l, epsilon: _eps),
        );
        // Left-aligned text starts one scaled mono column in.
        expect(
          _glyphs(_cellParagraph(tester, 1, 0)).left,
          moreOrLessEquals(grid.left + scale * _c, epsilon: 0.5),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: width and wrap (R19, R27)
  // -------------------------------------------------------------------------
  group('width and wrap (AC2, R19, R27)', () {
    for (final (name, width, expected) in [
      (
        'the grid spans the full text column with its header band at desktop width',
        tableDesktopWidth,
        746.0,
      ),
      (
        'the grid spans the full text column with its header band at 720 px',
        tableNarrowWidth,
        650.0,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await pumpTable(tester, _doc(_ruledTable), width: width, daily: true);
        expectTableRendered(0, 1);
        final grid = tester.getRect(tableGrid(0, 1));
        final prose = tester.getRect(
          find.descendant(
            of: find.byKey(const Key('editor-row-0-0')),
            matching: find.byType(EditableText),
          ),
        );
        expect(grid.left, moreOrLessEquals(prose.left, epsilon: _eps));
        expect(grid.right, moreOrLessEquals(prose.right, epsilon: _eps));
        expect(grid.width, moreOrLessEquals(expected, epsilon: _eps));

        final px = await _wi205Capture(tester, tableGrid(0, 1));
        for (final x in [0.5, grid.width / 2, grid.width - 0.5]) {
          expect(
            px.at(grid.topLeft + Offset(x, _band - 2)),
            _isColor(OmColors.surface3),
            reason: 'band at x $x',
          );
        }
      }, variant: macOnly);
    }

    testWidgets(
      'a table wider than the column wraps cell text inside its columns at 720 px with no overflow or clipping',
      (tester) async {
        await pumpTable(
          tester,
          _doc(_wideTable),
          width: tableNarrowWidth,
          daily: true,
        );
        expect(tester.takeException(), isNull);
        expectTableRendered(0, 1);
        final grid = tester.getRect(tableGrid(0, 1));
        expect(grid.width, moreOrLessEquals(650, epsilon: _eps));
        expect(
          find.descendant(
            of: tableGrid(0, 1),
            matching: find.byType(Scrollable),
          ),
          findsNothing,
          reason: 'nothing scrolls sideways',
        );

        final t = _parsed(_wideTable);
        // The header may wrap too: band = its tallest cell's lines x L + H.
        var headerLines = 1;
        for (var col = 0; col < t.columnCount; col++) {
          final p = _cellParagraph(tester, 0, col);
          headerLines = math.max(headerLines, _lineCount(p));
          final glyphs = _glyphs(p);
          expect(glyphs.left, greaterThanOrEqualTo(grid.left - 0.5));
          expect(glyphs.right, lessThanOrEqualTo(grid.right + 0.5));
          expect(
            glyphs.bottom,
            lessThanOrEqualTo(grid.top + headerLines * _l + _h + 0.5),
          );
        }
        final band = headerLines * _l + _h;
        var expectedHeight = band;
        var top = grid.top + band;
        for (var g = 1; g <= t.body.length; g++) {
          var tallest = 1;
          Rect? previous;
          for (var col = 0; col < t.columnCount; col++) {
            final p = _cellParagraph(tester, g, col);
            expect(p.didExceedMaxLines, isFalse);
            tallest = math.max(tallest, _lineCount(p));
            final glyphs = _glyphs(p);
            expect(glyphs.left, greaterThanOrEqualTo(grid.left - 0.5));
            expect(glyphs.right, lessThanOrEqualTo(grid.right + 0.5));
            expect(glyphs.top, greaterThanOrEqualTo(top - 0.5));
            if (previous != null) {
              expect(
                glyphs.left,
                greaterThanOrEqualTo(previous.right - 0.5),
                reason: 'row $g cell $col overlaps the cell to its left',
              );
            }
            previous = glyphs;
          }
          expect(tallest, greaterThan(1), reason: 'fixture: row $g wraps');
          top += tallest * _l;
          expectedHeight += tallest * _l;
          for (var col = 0; col < t.columnCount; col++) {
            expect(
              _glyphs(_cellParagraph(tester, g, col)).bottom,
              lessThanOrEqualTo(top + 0.5),
              reason: 'row $g cell $col fits its row',
            );
          }
        }
        expect(grid.height, moreOrLessEquals(expectedHeight, epsilon: _eps));
        // The word longer than its column breaks between characters.
        final word = _cellParagraph(tester, 2, 1);
        expect(word.text.toPlainText(), 'Antidisestablishmentarianism');
        expect(_lineCount(word), greaterThan(1));
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: alignment (R5)
  // -------------------------------------------------------------------------
  testWidgets(
    'left center and right columns place cell text at the left padding edge centered and at the right padding edge',
    (tester) async {
      await pumpTable(tester, _doc(_alignTable));
      expectTableRendered(0, 1);
      final grid = tester.getRect(tableGrid(0, 1));
      final w = grid.width / 3;
      for (var row = 0; row <= 2; row++) {
        final left = _glyphs(_cellParagraph(tester, row, 0));
        expect(
          left.left,
          moreOrLessEquals(grid.left + _c, epsilon: 0.5),
          reason: 'row $row left column',
        );
        final mid = _glyphs(_cellParagraph(tester, row, 1));
        expect(
          mid.center.dx,
          moreOrLessEquals(grid.left + 1.5 * w, epsilon: 0.5),
          reason: 'row $row center column',
        );
        final right = _glyphs(_cellParagraph(tester, row, 2));
        expect(
          right.right,
          moreOrLessEquals(grid.right - _c, epsilon: 0.5),
          reason: 'row $row right column',
        );
      }
    },
    variant: macOnly,
  );

  // -------------------------------------------------------------------------
  // AC4: uneven rows (R6)
  // -------------------------------------------------------------------------
  group('uneven rows (AC4, R6)', () {
    testWidgets(
      'a row with fewer cells draws the missing cells empty and cells past the header count are not drawn',
      (tester) async {
        await pumpTable(tester, _doc(_unevenTable));
        expectTableRendered(0, 1);
        final grid = tester.getRect(tableGrid(0, 1));
        expect(grid.height, moreOrLessEquals(_band + 2 * _l, epsilon: _eps));

        expect(
          _gridTexts(tester),
          unorderedEquals(['A', 'B', 'C', 'one', 'p', 'q', 'r']),
        );
        expect(_cellParagraph(tester, 1, 0).text.toPlainText(), 'one');
        for (final col in [1, 2]) {
          final missing = _cellText(1, col);
          if (missing.evaluate().isNotEmpty) {
            expect(
              tester.widget<RichText>(missing).text.toPlainText(),
              isEmpty,
              reason: 'missing cell $col is empty',
            );
          }
        }
        expect(_cellParagraph(tester, 2, 2).text.toPlainText(), 'r');
        expect(tableCell(0, 1, 2, 3), findsNothing);

        // The rule under the short row still crosses the full width.
        final px = await _wi205Capture(tester, tableGrid(0, 1));
        final ruleY = _band + _l - 0.5;
        final bg = px.at(grid.topLeft + Offset(grid.width - _c / 2, ruleY - 3));
        expect(
          px.at(grid.topLeft + Offset(grid.width - _c / 2, ruleY)),
          _isRuleOver(bg),
        );
      },
      variant: macOnly,
    );

    testWidgets('a header-only table draws its band alone', (tester) async {
      await pumpTable(tester, _doc(_headerOnly));
      expectTableRendered(0, 1);
      final grid = tester.getRect(tableGrid(0, 1));
      expect(grid.height, moreOrLessEquals(_band, epsilon: _eps));
      expect(_gridTexts(tester), unorderedEquals(['A', 'B']));
      final px = await _wi205Capture(tester, tableGrid(0, 1));
      for (final x in [_c / 2, grid.width / 2, grid.width - _c / 2]) {
        expect(
          px.at(grid.topLeft + Offset(x, _band - 1)),
          _isColor(OmColors.surface3),
        );
      }
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC5: band and rules (R17, D19a)
  // -------------------------------------------------------------------------
  group('band and rules (AC5, R17, D19a)', () {
    testWidgets(
      'the band bottom strip is surface3 and a 1 px line2 rule lies between body rows with no vertical rules',
      (tester) async {
        await pumpTable(tester, _doc(_ruledTable));
        expectTableRendered(0, 1);
        final grid = tester.getRect(tableGrid(0, 1));
        final w = grid.width;
        final px = await _wi205Capture(tester, tableGrid(0, 1));
        Color at(double x, double y) => px.at(grid.topLeft + Offset(x, y));

        // The band's bottom 4 px at any x, and its padding strips.
        for (final x in [0.5, w / 4, w / 2, 3 * w / 4, w - 0.5]) {
          expect(at(x, _band - 2), _isColor(OmColors.surface3), reason: '$x');
        }
        for (final x in [_c / 2, w / 2 - _c / 2, w / 2 + _c / 2, w - _c / 2]) {
          expect(at(x, _band / 2), _isColor(OmColors.surface3), reason: '$x');
        }
        // No rule under the band.
        expect(at(_c / 2, _band - 0.5), _isColor(OmColors.surface3));

        for (var i = 0; i < 3; i++) {
          final rowTop = _band + i * _l;
          final rowBottom = rowTop + _l;
          final bg = at(_c / 2, rowTop + _l / 2);
          expect(
            bg,
            isNot(_isColor(OmColors.surface3)),
            reason: 'body row $i is not banded',
          );
          // No vertical rule at the column boundary.
          expect(at(w / 2, rowTop + _l / 2), _isPixel(bg), reason: 'row $i');
          expect(
            at(w / 2, rowTop + _l / 2),
            isNot(_isRuleOver(bg)),
          );
          for (final x in [_c / 2, w / 2 + _c / 2, w - _c / 2]) {
            final last = at(x, rowBottom - 0.5);
            if (i < 2) {
              expect(
                last,
                _isRuleOver(bg),
                reason: 'rule in the last pixel of body row $i at x $x',
              );
            } else {
              expect(last, _isPixel(bg), reason: 'no rule under the last row');
            }
            expect(
              at(x, rowBottom - 1.5),
              _isPixel(bg),
              reason: 'the rule of row $i is 1 px',
            );
          }
        }
      },
      variant: macOnly,
    );

    testWidgets('the header band takes the passed headerBand colour', (
      tester,
    ) async {
      await _pumpBareGrid(
        tester,
        '| A | B |\n|---|---|\n| x | y |',
        headerBand: OmColors.surface5,
      );
      final grid = tester.getRect(find.byKey(_bareKey));
      final px = await _wi205Capture(tester, find.byKey(_bareKey));
      for (final x in [0.5, _c / 2, grid.width / 2, grid.width - _c / 2]) {
        expect(
          px.at(grid.topLeft + Offset(x, _band - 2)),
          _isColor(OmColors.surface5),
          reason: 'band at x $x',
        );
      }

      // A new colour repaints the band.
      await _pumpBareGrid(
        tester,
        '| A | B |\n|---|---|\n| x | y |',
        headerBand: OmColors.surface4,
      );
      final again = await _wi205Capture(tester, find.byKey(_bareKey));
      expect(
        again.at(grid.topLeft + Offset(grid.width / 2, _band - 2)),
        _isColor(OmColors.surface4),
      );
    });

    testWidgets(
      'the grid paints the band then code pills then rules then cell text and never the selection',
      (tester) async {
        await pumpTable(tester, _doc(_pillTable));
        expectTableRendered(0, 1);
        final ops = _recordGrid(tester);
        final band = _fills(ops, OmColors.surface3);
        final pills = _fills(ops, OmColors.surface4);
        final rules = _fills(ops, OmColors.line2);
        final text = [
          for (final op in ops)
            if (op.kind == #drawParagraph) op,
        ];
        expect(band, isNotEmpty, reason: 'band');
        expect(pills, hasLength(1), reason: 'one pill');
        expect(rules, hasLength(1), reason: 'one rule between two body rows');
        expect(text, isNotEmpty, reason: 'cell text');
        expect(_fills(ops, OmColors.selection), isEmpty);

        int maxOf(List<_Wi205Op> l) => l.map((o) => o.index).reduce(math.max);
        int minOf(List<_Wi205Op> l) => l.map((o) => o.index).reduce(math.min);
        expect(maxOf(band), lessThan(minOf(pills)), reason: 'band, pills');
        expect(maxOf(pills), lessThan(minOf(rules)), reason: 'pills, rules');
        expect(maxOf(rules), lessThan(minOf(text)), reason: 'rules, text');

        final w = tester.getSize(tableGrid(0, 1)).width;
        final rule = rules.single.rect!;
        expect(rule.left, moreOrLessEquals(0, epsilon: _eps));
        expect(rule.right, moreOrLessEquals(w, epsilon: _eps));
        expect(rule.top, moreOrLessEquals(_band + _l - 1, epsilon: _eps));
        expect(rule.height, moreOrLessEquals(1, epsilon: _eps));
        final bandRect = band
            .map((o) => o.rect!)
            .reduce((a, b) => a.expandToInclude(b));
        expect(bandRect.top, moreOrLessEquals(0, epsilon: _eps));
        expect(bandRect.bottom, moreOrLessEquals(_band, epsilon: _eps));
        expect(bandRect.left, moreOrLessEquals(0, epsilon: _eps));
        expect(bandRect.right, moreOrLessEquals(w, epsilon: _eps));
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: cell text (R20, D16)
  // -------------------------------------------------------------------------
  group('cell text (AC6, R20, D16)', () {
    List<NoteTitle> noteTitles() => [
      NoteTitle(id: 'topic-note', title: 'Note', updatedAt: 0),
    ];

    testWidgets(
      'cells show inline formatting with markup hidden in the live preview styles and a bold header',
      (tester) async {
        await pumpTable(tester, _doc(_inlineTable), titles: noteTitles());
        await tester.pump();
        expectTableRendered(0, 1);
        final controller = tableRowController(tester, 0, 1);
        final resolved = controller.isResolved;
        expect(resolved?.call('Note'), isTrue, reason: 'fixture: Note exists');
        expect(resolved?.call('Missing'), isFalse);

        final t = _parsed(_inlineTable);
        for (var g = 0; g <= t.body.length; g++) {
          for (var col = 0; col < t.columnCount; col++) {
            final cell = _cellString(_inlineTable, t, g, col);
            final span = _cellSpan(tester, g, col);
            expect(span.toPlainText(), cell, reason: 'cell $g/$col keeps text');
            expect(
              _leaves(span),
              _leaves(
                buildLivePreviewSpan(
                  cell,
                  itemText: true,
                  forceHidden: true,
                  isResolved: resolved,
                ),
              ),
              reason: 'cell $g/$col spans are live preview spans',
            );
          }
        }

        // Header text bold through the base style; body text regular.
        for (final col in [0, 1]) {
          expect(
            _styleOf(
              _cellSpan(tester, 0, col),
              col == 0 ? 'Kind' : 'Sample',
            ).fontWeight,
            FontWeight.w700,
          );
        }
        expect(
          _styleOf(_cellSpan(tester, 1, 0), 'fmt').fontWeight,
          isNot(FontWeight.w700),
        );

        final fmt = _cellSpan(tester, 1, 1);
        expect(_styleOf(fmt, '**').fontSize, 0, reason: 'markers hidden');
        expect(_styleOf(fmt, 'bold').fontWeight, FontWeight.w700);
        expect(_styleOf(fmt, 'it').fontStyle, FontStyle.italic);
        final strike = _styleOf(fmt, 's');
        expect(strike.color, OmColors.fg2);
        expect(strike.decoration?.contains(TextDecoration.lineThrough), isTrue);
        expect(_styleOf(fmt, 'code').color, OmColors.fg1);

        final links = _cellSpan(tester, 2, 1);
        final link = _styleOf(links, 't');
        expect(link.color, OmColors.info);
        expect(link.decoration?.contains(TextDecoration.underline), isTrue);
        expect(_styleOf(links, 'Note').color, OmColors.accent);
        expect(_styleOf(links, 'Missing').color, OmColors.fg2);
        expect(_styleOf(links, '[[').fontSize, 0, reason: 'markers hidden');
      },
      variant: macOnly,
    );

    testWidgets(
      'task list and heading markers in a cell stay plain cell text',
      (tester) async {
        await pumpTable(tester, _doc(_inlineTable));
        expectTableRendered(0, 1);
        for (final (row, text) in [
          (3, '[ ] x'),
          (4, '- y'),
          (5, '# z'),
          (6, '1. w'),
        ]) {
          final span = _cellSpan(tester, row, 1);
          expect(span.toPlainText(), text);
          for (final (leaf, style) in _leaves(span)) {
            expect(
              style?.fontSize,
              isNot(0),
              reason: '$text: "$leaf" is not hidden',
            );
            expect(style?.fontWeight, isNot(FontWeight.w700));
            expect(style?.color, isNull, reason: '$text: "$leaf" is body');
            expect(
              style?.fontSize ?? 0,
              lessThanOrEqualTo(13.5),
              reason: '$text: no heading size',
            );
          }
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd-hovered wikilink in a cell takes the hover style at its cell-local offsets',
      (tester) async {
        await pumpTable(tester, _doc(_inlineTable), titles: noteTitles());
        await tester.pump();
        final controller = tableRowController(tester, 0, 1);
        final t = _parsed(_inlineTable);
        final cell = t.body[1].cells[1];
        final cellText = cell.text(_inlineTable);
        final at = _inlineTable.indexOf('[[Note]]');
        controller.cmdHover = TextRange(start: at, end: at + '[[Note]]'.length);
        await tester.pump();
        expectTableRendered(0, 1);

        final span = _cellSpan(tester, 2, 1);
        expect(
          _leaves(span),
          _leaves(
            buildLivePreviewSpan(
              cellText,
              itemText: true,
              forceHidden: true,
              isResolved: controller.isResolved,
              cmdHover: TextRange(
                start: at - cell.start,
                end: at - cell.start + '[[Note]]'.length,
              ),
            ),
          ),
        );
        expect(
          _styleOf(span, 'Note').decoration?.contains(TextDecoration.underline),
          isTrue,
          reason: 'hovered wikilink underlined',
        );
        expect(
          _styleOf(span, 't').decoration?.contains(TextDecoration.underline),
          isTrue,
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'an inline code span in a cell gets one pill painted behind its text',
      (tester) async {
        await pumpTable(tester, _doc(_pillTable));
        expectTableRendered(0, 1);
        final ops = _recordGrid(tester);
        final pills = _fills(ops, OmColors.surface4);
        expect(pills, hasLength(1), reason: 'painted once');

        final p = _cellParagraph(tester, 1, 1);
        final cellText = p.text.toPlainText();
        expect(cellText, 'x `code` y');
        final start = cellText.indexOf('code');
        final code = _glyphs(
          p,
          start: start,
          end: start + 4,
        ).shift(-tester.getTopLeft(tableGrid(0, 1)));
        final pill = pills.single.rect!;
        expect(pill.left, moreOrLessEquals(code.left - 3, epsilon: 0.5));
        expect(pill.right, moreOrLessEquals(code.right + 3, epsilon: 0.5));
        expect(pill.top, moreOrLessEquals(_band + 2, epsilon: 0.5));
        expect(pill.height, moreOrLessEquals(17, epsilon: 0.5));
        final paragraphs = [
          for (final op in ops)
            if (op.kind == #drawParagraph) op.index,
        ];
        expect(
          pills.single.index,
          lessThan(paragraphs.reduce(math.min)),
          reason: 'behind the text',
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: no selection paint (R16, D19a)
  // -------------------------------------------------------------------------
  testWidgets(
    'a segment selection covering a rendered table paints nothing in the grid probe regions',
    (tester) async {
      final text = _doc(_ruledTable);
      final body = await pumpTable(tester, text);
      expectTableRendered(0, 1);
      final grid = tester.getRect(tableGrid(0, 1));
      final w = grid.width;
      final probes = <Offset>[
        for (final x in [0.5, w / 4, w / 2, 3 * w / 4, w - 0.5])
          Offset(x, _band - 2),
        for (var g = 0; g < 4; g++)
          for (final x in [_c / 2, w / 2 - _c / 2, w / 2 + _c / 2, w - _c / 2])
            Offset(x, g == 0 ? _band / 2 : _band + (g - 1) * _l + _l / 2),
        for (var i = 0; i < 2; i++)
          for (final x in [_c / 2, w - _c / 2])
            Offset(x, _band + (i + 1) * _l - 0.5),
      ];
      final before = await _wi205Capture(tester, tableGrid(0, 1));
      final unselected = [for (final p in probes) before.at(grid.topLeft + p)];

      await body.select(
        TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      await body.focusOutside();
      expectTableRendered(0, 1);
      expect(
        body.selection(),
        TextSelection(baseOffset: 0, extentOffset: text.length),
        reason: 'the selection is kept',
      );

      final grid2 = tester.getRect(tableGrid(0, 1));
      final after = await _wi205Capture(tester, tableGrid(0, 1));
      for (var i = 0; i < probes.length; i++) {
        final pixel = after.at(grid2.topLeft + probes[i]);
        expect(pixel, _isPixel(unselected[i]), reason: 'probe ${probes[i]}');
      }
      for (var i = 0; i < 5; i++) {
        expect(
          after.at(grid2.topLeft + probes[i]),
          _isColor(OmColors.surface3),
          reason: 'band probe ${probes[i]}',
        );
      }
    },
    variant: macOnly,
  );

  // -------------------------------------------------------------------------
  // AC8: the line-box seam (D13)
  // -------------------------------------------------------------------------
  group('the line-box seam (AC8, D13)', () {
    /// Grid-relative top and bottom of grid row [g] of [_seamTable] (every
    /// row one line).
    (double, double) rowSpan(int g) =>
        g == 0 ? (0.0, _band) : (_band + (g - 1) * _l, _band + g * _l);

    testWidgets(
      'grid line boxes tile the grid top to bottom and each grid row starts at its source line start',
      (tester) async {
        await pumpTable(tester, _doc(_seamTable));
        expectTableRendered(0, 1);
        final t = _parsed(_seamTable);
        final boxes = _gridBoxes(tester);
        final lines = boxes.lines;
        final height = tester.getSize(tableGrid(0, 1)).height;
        expect(height, moreOrLessEquals(_band + 3 * _l, epsilon: _eps));
        expect(lines, isNotEmpty);
        Rect rel(LineBox l) =>
            _gridRel(tester, boxes, Rect.fromLTRB(0, l.top, 0, l.bottom));

        expect(rel(lines.first).top, moreOrLessEquals(0, epsilon: _eps));
        expect(rel(lines.last).bottom, moreOrLessEquals(height, epsilon: _eps));
        for (var i = 1; i < lines.length; i++) {
          expect(
            lines[i].range.start,
            greaterThanOrEqualTo(lines[i - 1].range.start),
            reason: 'line $i start',
          );
          expect(
            rel(lines[i]).top,
            moreOrLessEquals(rel(lines[i - 1]).bottom, epsilon: _eps),
            reason: 'line $i follows line ${i - 1}',
          );
        }

        for (var g = 0; g <= t.body.length; g++) {
          final source = _sourceLine(t, g);
          final next = g < t.body.length
              ? _sourceLine(t, g + 1).start
              : _seamTable.length + 1;
          final group = [
            for (final l in lines)
              if (l.range.start >= source.start && l.range.start < next) l,
          ];
          expect(group, isNotEmpty, reason: 'grid row $g has a line');
          expect(
            group.first.range.start,
            source.start,
            reason: 'grid row $g starts at its source line start',
          );
          final (top, bottom) = rowSpan(g);
          expect(rel(group.first).top, moreOrLessEquals(top, epsilon: _eps));
          expect(
            rel(group.last).bottom,
            moreOrLessEquals(bottom, epsilon: _eps),
            reason: 'grid row $g ends at its row bottom',
          );
          expect(
            lineHolding(lines, source.end - 1).range.start,
            group.last.range.start,
            reason: 'grid row $g last char is in its last visual line',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'delimiter offsets map into the header band and dropped cell offsets to the end of the last drawn cell',
      (tester) async {
        await pumpTable(tester, _doc(_seamTable));
        expectTableRendered(0, 1);
        final t = _parsed(_seamTable);
        final boxes = _gridBoxes(tester);
        final width = tester.getSize(tableGrid(0, 1)).width;

        for (var at = t.delimiter.start; at <= t.delimiter.end; at++) {
          final caret = _gridRel(tester, boxes, boxes.caretRect(at));
          expect(caret.top, moreOrLessEquals(_h / 2, epsilon: _eps));
          expect(caret.bottom, moreOrLessEquals(_band - _h / 2, epsilon: _eps));
          expect(caret.left, inInclusiveRange(_c - _eps, width));
        }

        final row = t.body[1];
        final dropped = row.beyond.single;
        expect(dropped.text(_seamTable), 'dropped');
        final end = boxes.caretRect(row.cells.last.end);
        for (var at = dropped.start; at <= dropped.end; at++) {
          final caret = boxes.caretRect(at);
          expect(caret.left, moreOrLessEquals(end.left, epsilon: _eps));
          expect(caret.top, moreOrLessEquals(end.top, epsilon: _eps));
          expect(caret.bottom, moreOrLessEquals(end.bottom, epsilon: _eps));
        }
        final fine = _glyphs(_cellParagraph(tester, 2, 2));
        expect(
          boxes.box.localToGlobal(end.topLeft).dx,
          moreOrLessEquals(fine.right, epsilon: 0.5),
          reason: 'at the end of fine',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'caretRect has non-zero height inside its grid row at every offset including hidden markup offsets',
      (tester) async {
        await pumpTable(tester, _doc(_seamTable));
        expectTableRendered(0, 1);
        final t = _parsed(_seamTable);
        final boxes = _gridBoxes(tester);
        final width = tester.getSize(tableGrid(0, 1)).width;
        expect(
          _seamTable.substring(
            t.body[0].cells[0].start,
            t.body[0].cells[0].start + 2,
          ),
          '**',
        );

        for (var at = 0; at <= _seamTable.length; at++) {
          var g = 0;
          for (var i = 0; i < t.body.length; i++) {
            if (t.body[i].line.start <= at) g = i + 1;
          }
          final caret = _gridRel(tester, boxes, boxes.caretRect(at));
          expect(caret.height, greaterThan(0), reason: 'caret at $at');
          final (top, bottom) = rowSpan(g);
          expect(
            caret.top,
            greaterThanOrEqualTo(top - _eps),
            reason: 'caret at $at in grid row $g',
          );
          expect(
            caret.bottom,
            lessThanOrEqualTo(bottom + _eps),
            reason: 'caret at $at in grid row $g',
          );
          expect(caret.left, inInclusiveRange(-_eps, width + _eps));
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'offsetAt maps padding and outside points to the nearest cell text end and a glyph point to its offset',
      (tester) async {
        await pumpTable(tester, _doc(_seamTable));
        expectTableRendered(0, 1);
        final t = _parsed(_seamTable);
        final boxes = _gridBoxes(tester);
        final size = tester.getSize(tableGrid(0, 1));
        int at(double x, double y) =>
            boxes.offsetAt(_boxPoint(tester, boxes, Offset(x, y)));

        expect(
          at(_c / 2, _band + _l / 2),
          t.body[0].cells[0].end,
          reason: 'left padding of a body cell',
        );
        expect(
          at(size.width - _c / 2, _band / 2),
          t.header.cells[2].end,
          reason: 'right padding of the last header cell',
        );
        expect(
          at(size.width / 2, 1),
          isIn([for (final c in t.header.cells) c.end]),
          reason: 'the band top 4 px is blank: a header cell text end',
        );
        expect(
          at(_c / 2, size.height + 40),
          t.body.last.cells[0].end,
          reason: 'below the grid: the last body row',
        );
        expect(
          at(size.width - _c / 2, -20),
          t.header.cells[2].end,
          reason: 'above the grid: the header',
        );

        final m = _seamTable.indexOf('mma');
        final glyph = boxes.boxesFor(TextRange(start: m, end: m + 1)).single;
        expect(
          boxes.offsetAt(Offset(glyph.left + glyph.width / 4, glyph.center.dy)),
          m,
          reason: 'a point on a glyph maps to it',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'boxesFor a cell text range returns rects inside that cell around its glyphs',
      (tester) async {
        await pumpTable(tester, _doc(_seamTable));
        expectTableRendered(0, 1);
        final t = _parsed(_seamTable);
        final boxes = _gridBoxes(tester);
        final gridTop = tester.getTopLeft(tableGrid(0, 1)).dy;
        Rect global(Rect r) => Rect.fromPoints(
          boxes.box.localToGlobal(r.topLeft),
          boxes.box.localToGlobal(r.bottomRight),
        );

        for (var col = 0; col < 3; col++) {
          final cell = t.body[0].cells[col];
          final glyphs = _glyphs(_cellParagraph(tester, 1, col));
          final rects = boxes
              .boxesFor(TextRange(start: cell.start, end: cell.end))
              .map(global)
              .toList();
          expect(rects, hasLength(1), reason: 'cell $col is one line');
          final r = rects.single;
          expect(r.left, moreOrLessEquals(glyphs.left, epsilon: 0.5));
          expect(r.right, moreOrLessEquals(glyphs.right, epsilon: 0.5));
          expect(r.top, greaterThanOrEqualTo(gridTop + _band - _eps));
          expect(r.bottom, lessThanOrEqualTo(gridTop + _band + _l + _eps));
        }

        // A whole body line: one rect per drawn cell, around its glyphs.
        final line = t.body[0].line;
        final all = boxes
            .boxesFor(TextRange(start: line.start, end: line.end))
            .map(global)
            .toList();
        for (var col = 0; col < 3; col++) {
          final glyphs = _glyphs(_cellParagraph(tester, 1, col));
          expect(
            all.where(
              (r) =>
                  (r.left - glyphs.left).abs() <= 0.5 &&
                  (r.right - glyphs.right).abs() <= 0.5,
            ),
            hasLength(1),
            reason: 'one rect around cell $col in $all',
          );
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC9: Up/Down through the seam (R23)
  // -------------------------------------------------------------------------
  group('Up and Down into a rendered table (AC9, R23)', () {
    const text = '$_arrowAbove\n$_arrowTable\n$_arrowBelow';
    const tableStart = _arrowAbove.length + 1;
    const belowStart = tableStart + _arrowTable.length + 1;

    /// The segment offset whose caret lies nearest the grid-relative x [x]
    /// on segment line [line].
    int offsetAtGridX(TableBody body, WidgetTester tester, double x, int line) {
      final seg = body.segmentBoxes();
      final l = seg.lines[line];
      final gx = tester.getTopLeft(tableGrid(0, 1)).dx + x;
      final local = seg.box.globalToLocal(Offset(gx, 0));
      return seg.offsetAt(Offset(local.dx, (l.top + l.bottom) / 2));
    }

    testWidgets(
      'Down from the row above a rendered table lands on the header row at the cell text end under the caret x',
      (tester) async {
        final body = await pumpTable(tester, text);
        final w = tester.getSize(tableGrid(0, 1)).width;
        final from = offsetAtGridX(body, tester, w / 4, 0);
        expect(from, lessThan(_arrowAbove.length), reason: 'fixture');
        await body.placeCaret(from);
        expectTableRendered(0, 1);

        await body.press(LogicalKeyboardKey.arrowDown);

        final t = _parsed(_arrowTable);
        expect(
          body.selection(),
          TextSelection.collapsed(offset: tableStart + t.header.cells[0].end),
        );
        expect(body.segment().focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Up from the row below a rendered table lands on the last body row at the cell text end under the caret x',
      (tester) async {
        final body = await pumpTable(tester, text);
        final w = tester.getSize(tableGrid(0, 1)).width;
        final lines = body.segmentBoxes().lines;
        final belowLine = lines.lastIndexWhere(
          (l) => l.range.start <= belowStart,
        );
        final from = offsetAtGridX(body, tester, 3 * w / 4, belowLine);
        expect(from, greaterThan(belowStart), reason: 'fixture');
        await body.placeCaret(from);
        expectTableRendered(0, 1);

        await body.press(LogicalKeyboardKey.arrowUp);

        final t = _parsed(_arrowTable);
        expect(
          body.selection(),
          TextSelection.collapsed(
            offset: tableStart + t.body.last.cells[1].end,
          ),
        );
        expect(body.segment().focusedRow, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC10: semantics (R26)
  // -------------------------------------------------------------------------
  testWidgets(
    'the grid semantics list the header cells then each body row left to right',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpTable(tester, _doc(_semanticsTable));
        expectTableRendered(0, 1);
        expect(_labelsInside(tester, tester.getRect(tableGrid(0, 1))), [
          'Step',
          'Notes',
          'Alpha',
          'one',
          'Beta',
        ]);
      } finally {
        semantics.dispose();
      }
    },
    variant: macOnly,
  );
}
