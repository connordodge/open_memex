import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/markdown_inline.dart';
import '../../editor/markdown_table.dart'
    show ParsedTable, TableAlign, parseTable;
import '../../editor/row_geometry.dart';
import '../../editor/table_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'live_preview_decorations.dart';
import 'live_preview_styles.dart';
import 'paragraph_line_boxes.dart';

/// The rendered face of a table row (Spec #197 R12, R17; TD4; ruling D12,
/// API frozen): drawn in the row field's place while the table is not
/// revealed. The field stays mounted offstage.
///
/// - [text] is the table row's text (its field's text).
/// - [style] is the editor body style.
/// - [links] is the row's controller, whose link state (`isResolved`,
///   `cmdHover`) cells read; null in excerpt cards.
/// - [headerBand] is the header band's colour (`surface4` in cards).
///
/// Design B "Ruled rows" (WI #205, packs #203 and #205): one `RichText` per
/// drawn cell laid out by T2's `table_geometry.dart` from scaled metrics
/// (D21), a header band, a 1 px rule inside every body row but the last, no
/// vertical rules. When the grid's key is `editor-table-<s>-<r>`, cell
/// (`row`, `col`) has the key `editor-table-cell-<s>-<r>-<row>-<col>` (TD8;
/// row 0 is the header): a box spanning the drawn cell, its padding
/// included (its column's x range, its grid row's y range), holding the
/// cell's `RichText` at the cell's content rect.
class TableGrid extends StatefulWidget {
  const TableGrid({
    super.key,
    required this.text,
    required this.style,
    this.links,
    this.headerBand = OmColors.surface3,
  });

  final String text;
  final TextStyle style;
  final LivePreviewController? links;
  final Color headerBand;

  @override
  State<TableGrid> createState() => TableGridState();
}

/// The [TableGrid]'s state: its line-box seam in the table row's field text
/// offsets (TD5, ruling D13).
class TableGridState extends State<TableGrid> {
  final _gridKey = GlobalKey(debugLabel: 'table-grid');

  /// False while the grid is out of the tree (its row was revealed and the
  /// frame has not finished): it has no line boxes then.
  bool _active = true;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  /// The grid's line boxes once laid out, in the row's field text offsets
  /// (box = the grid's render box); null before layout, while a layout is
  /// pending, and when [TableGrid.text] is not a table.
  LineBoxSource? lineBoxes() =>
      switch (_active ? _gridKey.currentContext?.findRenderObject() : null) {
        final _RenderTableGrid grid when grid.attached => grid._geometry,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final table = parseTable(text);
    if (table == null) return const SizedBox.shrink();
    final scaler = MediaQuery.textScalerOf(context);
    // As the row field's EditableText does with its strut: a line of hidden
    // markers keeps its height.
    final strut = livePreviewStrut().inheritFromTextStyle(widget.style);
    final headerStyle = _headerStyle(widget.style);
    final keyPrefix = _cellKeyPrefix(widget.key);
    final hover = widget.links?.cmdHover;
    final metrics = _metrics(scaler);
    final rows = [table.header.cells, for (final row in table.body) row.cells];
    return _GridLayout(
      key: _gridKey,
      text: text,
      table: table,
      textScaler: scaler,
      headerBand: widget.headerBand,
      children: [
        for (final (g, cells) in rows.indexed)
          for (var j = 0; j < table.columnCount; j++)
            _Cell(
              key: keyPrefix == null ? null : ValueKey('$keyPrefix-$g-$j'),
              padding: metrics.cellPadding,
              inset: g == 0 ? metrics.hiddenLineHeight / 2 : 0,
              child: RichText(
                textAlign: _textAlign(table.alignments[j]),
                textScaler: scaler,
                strutStyle: strut,
                text: buildLivePreviewSpan(
                  j < cells.length ? cells[j].text(text) : '',
                  style: g == 0 ? headerStyle : widget.style,
                  itemText: true,
                  forceHidden: true,
                  isResolved: widget.links?.isResolved,
                  cmdHover: j < cells.length
                      ? _cellHover(hover, cells[j].start, cells[j].end)
                      : null,
                ),
              ),
            ),
      ],
    );
  }
}

const _gridKeyPrefix = 'editor-table-';
const _cellKeyStart = 'editor-table-cell-';

/// The cell key prefix `editor-table-cell-<s>-<r>` of a grid keyed
/// `editor-table-<s>-<r>` (TD8); null for any other key.
String? _cellKeyPrefix(Key? key) => switch (key) {
  ValueKey<String>(:final value) when value.startsWith(_gridKeyPrefix) =>
    '$_cellKeyStart${value.substring(_gridKeyPrefix.length)}',
  _ => null,
};

/// [hover] (field-text offsets) in the cell `[start, end)`'s own offsets
/// (D16); null when the cell doesn't hold all of it.
TextRange? _cellHover(TextRange? hover, int start, int end) =>
    hover != null && hover.start >= start && hover.end <= end
    ? TextRange(start: hover.start - start, end: hover.end - start)
    : null;

/// The header cells' base style: [base] in the bold mono face (R17, as
/// live preview's bold runs take it).
TextStyle _headerStyle(TextStyle base) {
  final bold = OmType.mono(weight: FontWeight.w700);
  return base.copyWith(
    fontFamily: bold.fontFamily,
    fontFamilyFallback: bold.fontFamilyFallback,
    fontWeight: bold.fontWeight,
  );
}

TextAlign _textAlign(TableAlign align) => switch (align) {
  TableAlign.left => TextAlign.left,
  TableAlign.center => TextAlign.center,
  TableAlign.right => TextAlign.right,
};

/// The grid's metrics at the editor's text scale (D21): L the body line,
/// H the hidden delimiter line, c one mono column; the rule is never
/// scaled.
TableMetrics _metrics(TextScaler scaler) => TableMetrics(
  lineHeight: scaler.scale(minimumStrutHeight),
  hiddenLineHeight: scaler.scale(lineHeight(LineHeightKind.fenceHidden)),
  cellPadding: scaler.scale(monoColumnWidth),
  ruleThickness: ruleThickness,
);

/// Added to a cell's text area when it is laid out, so a line that exactly
/// fits never wraps on float error (pack #203).
const double _wrapSlack = 0.01;

/// The code pill's corner radius (pack #205, as live preview's pill).
const double _pillRadius = 3;

/// A drawn cell (TD8): a box as big as the grid lays it out (the cell's
/// rect, padding included) holding the cell's [RichText] [padding] (c) in
/// from its left and [inset] (H / 2 in the header band, else 0) down from
/// its top, as wide as the box less c on each side (plus the wrap slack).
class _Cell extends SingleChildRenderObjectWidget {
  const _Cell({
    super.key,
    required this.padding,
    required this.inset,
    required RichText super.child,
  });

  final double padding;
  final double inset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCell(padding: padding, inset: inset);

  @override
  void updateRenderObject(BuildContext context, _RenderCell renderObject) {
    renderObject
      ..padding = padding
      ..inset = inset;
  }
}

/// [_Cell]'s render box. Its size is its constraints' max width (the
/// grid's column width, or the cell's natural width while the grid
/// measures) by their min height (the grid's row height once the grid
/// places it, else 0).
class _RenderCell extends RenderShiftedBox {
  _RenderCell({required double padding, required double inset})
    : _padding = padding,
      _inset = inset,
      super(null);

  double _padding;
  set padding(double value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  double _inset;
  set inset(double value) {
    if (value == _inset) return;
    _inset = value;
    markNeedsLayout();
  }

  /// The cell's paragraph.
  RenderParagraph get paragraph => child! as RenderParagraph;

  /// The paragraph's offset in the cell: (c, inset).
  Offset get textOffset => (paragraph.parentData! as BoxParentData).offset;

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final text = paragraph;
    text.layout(
      BoxConstraints.tightFor(
        width: math.max(0.0, width - 2 * _padding) + _wrapSlack,
      ),
      parentUsesSize: true,
    );
    (text.parentData! as BoxParentData).offset = Offset(_padding, _inset);
    size = Size(width, constraints.minHeight);
  }
}

/// Lays out and paints the cells (its children, row-major: the header's
/// cells, then each body row's, one per column).
class _GridLayout extends MultiChildRenderObjectWidget {
  const _GridLayout({
    super.key,
    required this.text,
    required this.table,
    required this.textScaler,
    required this.headerBand,
    required super.children,
  });

  final String text;
  final ParsedTable table;
  final TextScaler textScaler;
  final Color headerBand;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableGrid(
    text: text,
    table: table,
    textScaler: textScaler,
    headerBand: headerBand,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderTableGrid renderObject) {
    renderObject
      ..setTable(text, table)
      ..textScaler = textScaler
      ..headerBand = headerBand;
  }
}

class _CellParentData extends ContainerBoxParentData<RenderBox> {}

/// The grid's render box: column widths and row heights from
/// `table_geometry.dart`, then paints band, code pills, rules and cell text
/// in that order (D15). It paints no selection (R16).
class _RenderTableGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CellParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CellParentData> {
  _RenderTableGrid({
    required String text,
    required ParsedTable table,
    required TextScaler textScaler,
    required Color headerBand,
  }) : _text = text,
       _table = table,
       _textScaler = textScaler,
       _headerBand = headerBand;

  String _text;
  ParsedTable _table;

  /// Sets the table and the text it was parsed from; a new text lays out
  /// again.
  void setTable(String text, ParsedTable table) {
    if (text == _text) return;
    _text = text;
    _table = table;
    markNeedsLayout();
  }

  /// The editor's text scale, which scales the grid's metrics (D21).
  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    markNeedsLayout();
  }

  Color _headerBand;
  set headerBand(Color value) {
    if (value == _headerBand) return;
    _headerBand = value;
    markNeedsPaint();
  }

  /// The last layout's geometry; null while a layout is pending.
  _GridGeometry? _geometry;

  @override
  void markNeedsLayout() {
    _geometry = null;
    super.markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CellParentData) {
      child.parentData = _CellParentData();
    }
  }

  @override
  void performLayout() {
    final table = _table;
    final columns = table.columnCount;
    final metrics = _metrics(_textScaler);
    final c = metrics.cellPadding;
    final cells = <_RenderCell>[];
    for (var child = firstChild; child != null; child = childAfter(child)) {
      cells.add(child as _RenderCell);
    }

    // Measure each column's text on one line: n is its widest cell, m its
    // widest word (pack #203).
    final natural = List<double>.filled(columns, 0);
    final words = List<double>.filled(columns, 0);
    for (final (i, cell) in cells.indexed) {
      final j = i % columns;
      final n = cell.paragraph.getMaxIntrinsicWidth(double.infinity);
      cell.layout(BoxConstraints(maxWidth: n + 2 * c), parentUsesSize: true);
      natural[j] = math.max(natural[j], n);
      words[j] = math.max(words[j], _widestWord(cell.paragraph));
    }
    final available = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : natural.fold(0.0, (a, b) => a + b) + 2 * c * columns;
    final widths = tableColumnWidths(
      [
        for (var j = 0; j < columns; j++)
          TableColumnMeasure(
            naturalWidth: natural[j],
            minWidth: words[j],
            noWrap: table.alignments[j] != TableAlign.left,
          ),
      ],
      availableWidth: available,
      cellPadding: c,
    );

    // Wrap each cell inside its column's text area.
    final cellLines = <List<LineBox>>[];
    final counts = <List<int>>[];
    for (final (i, cell) in cells.indexed) {
      final j = i % columns;
      cell.layout(
        BoxConstraints.tightFor(width: widths[j]),
        parentUsesSize: true,
      );
      final lines = RenderParagraphLineBoxes(cell.paragraph).lines;
      cellLines.add(lines);
      if (j == 0) counts.add([]);
      // An empty cell passes its one empty line, not 0: [TableLayout] sizes
      // both alike, and offsetAt maps a point in it to its text end either
      // way.
      counts.last.add(lines.length);
    }

    final layout = TableLayout(
      columnWidths: widths,
      headerLines: counts.first,
      bodyLines: counts.sublist(1),
      metrics: metrics,
    );
    // Each cell spans its drawn cell; its paragraph sits at the content
    // rect. The height is a min, not tight, and the grid uses the size: a
    // cell is never a relayout boundary, so a change to its paragraph lays
    // the grid out again (it measures every cell).
    for (final (i, cell) in cells.indexed) {
      final rect = layout.cellRect(i ~/ columns, i % columns);
      cell.layout(
        BoxConstraints(
          minWidth: rect.width,
          maxWidth: rect.width,
          minHeight: rect.height,
        ),
        parentUsesSize: true,
      );
      (cell.parentData! as _CellParentData).offset = rect.topLeft;
    }
    size = constraints.constrain(Size(layout.width, layout.height));
    _geometry = _GridGeometry(
      box: this,
      text: _text,
      table: table,
      layout: layout,
      cells: cells,
      cellLines: cellLines,
    );
  }

  /// The widest run of non-space characters of [cell] (laid out on one
  /// line).
  static double _widestWord(RenderParagraph cell) {
    var widest = 0.0;
    for (final word in _word.allMatches(cell.text.toPlainText())) {
      final boxes = cell.getBoxesForSelection(
        TextSelection(baseOffset: word.start, extentOffset: word.end),
      );
      // A word of hidden markers alone may have no box.
      if (boxes.isEmpty) continue;
      final left = boxes.map((b) => b.left).reduce(math.min);
      final right = boxes.map((b) => b.right).reduce(math.max);
      widest = math.max(widest, right - left);
    }
    return widest;
  }

  /// A word: a run of non-space characters (pack #203 splits on spaces).
  static final _word = RegExp('[^ ]+');

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    final geometry = _geometry!;
    final layout = geometry.layout;
    final canvas = context.canvas;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, layout.bandHeight).shift(offset),
      Paint()..color = _headerBand,
    );
    final pill = Paint()..color = OmColors.surface4;
    for (final (g, j, content) in geometry.codeSpans) {
      for (final rect in codePillRects(
        geometry,
        content,
        columnLeft: layout.contentRect(g, j).left,
      )) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.shift(offset),
            const Radius.circular(_pillRadius),
          ),
          pill,
        );
      }
    }
    final rule = Paint()..color = OmColors.line2;
    for (final rect in layout.rules) {
      canvas.drawRect(rect.shift(offset), rule);
    }
    defaultPaint(context, offset);
  }
}

/// A laid-out grid's line boxes (D13), in the table row's field text offsets
/// and the grid's coordinates.
///
/// Grid row g (0: the header) has as many visual lines as its tallest cell.
/// Visual line i of a row starts at the row's source line start for i = 0,
/// else at the earliest start of any cell's own line i; line boxes tile the
/// grid (the header's take in the band's top and bottom H / 2). Carets and
/// [boxesFor] rects span a cell text line (L tall, from the cell's content
/// top).
final class _GridGeometry implements LineBoxSource {
  _GridGeometry({
    required this.box,
    required String text,
    required this.table,
    required this.layout,
    required List<_RenderCell> cells,
    required List<List<LineBox>> cellLines,
  }) : _cells = cells,
       _cellLines = cellLines,
       codeSpans = _codeSpans(text, table);

  @override
  final RenderBox box;

  final ParsedTable table;
  final TableLayout layout;

  /// The cells, row-major.
  final List<_RenderCell> _cells;

  /// Each cell's own lines (cell text offsets, paragraph coordinates).
  final List<List<LineBox>> _cellLines;

  /// Every inline code span's content in a drawn cell: (grid row, column,
  /// field-text range).
  final List<(int, int, TextRange)> codeSpans;

  int get _columns => table.columnCount;

  /// The grid rows' source lines: the header line, then each body line.
  late final List<TextRange> _rowLines = [
    TextRange(start: table.header.start, end: table.header.end),
    for (final row in table.body)
      TextRange(start: row.line.start, end: row.line.end),
  ];

  /// Every grid row's cells, dropped ones (past the header's count)
  /// included.
  late final List<List<TextRange>> _rowCells = [
    for (final line in [table.header, for (final row in table.body) row.line])
      [
        for (final cell in line.cells)
          TextRange(start: cell.start, end: cell.end),
      ],
  ];

  static List<(int, int, TextRange)> _codeSpans(
    String text,
    ParsedTable table,
  ) => [
    for (final (g, cells) in [
      table.header.cells,
      for (final row in table.body) row.cells,
    ].indexed)
      for (final (j, cell) in cells.indexed)
        for (final token in tokenizeInline(cell.text(text)))
          if (token.kind == InlineTokenKind.codeSpan)
            (
              g,
              j,
              TextRange(
                start: cell.start + token.content.start,
                end: cell.start + token.content.end,
              ),
            ),
  ];

  /// Drawn cell ([g], [j])'s source range, or null for a missing cell.
  TextRange? _source(int g, int j) {
    final cells = _rowCells[g];
    return j < cells.length ? cells[j] : null;
  }

  /// The top of cell text line [i] of grid row [g].
  double _textTop(int g, int i) =>
      layout.contentRect(g, 0).top + i * layout.metrics.lineHeight;

  /// Cell [index]'s paragraph.
  RenderParagraph _paragraph(int index) => _cells[index].paragraph;

  /// Cell [index]'s paragraph's offset in the grid.
  Offset _offsetOf(int index) {
    final cell = _cells[index];
    return (cell.parentData! as _CellParentData).offset + cell.textOffset;
  }

  @override
  late final List<LineBox> lines = [
    for (var g = 0; g < _rowLines.length; g++) ..._gridRowLines(g),
  ];

  List<LineBox> _gridRowLines(int g) {
    final source = _rowLines[g];
    final count = [
      for (var j = 0; j < _columns; j++) _cellLines[g * _columns + j].length,
    ].reduce(math.max);
    final starts = [source.start];
    for (var i = 1; i < count; i++) {
      var start = source.end;
      for (var j = 0; j < _columns; j++) {
        final own = _cellLines[g * _columns + j];
        if (_source(g, j) case final cell? when own.length > i) {
          start = math.min(start, cell.start + own[i].range.start);
        }
      }
      starts.add(start);
    }
    final rowTop = layout.rowTop(g);
    final rowBottom = rowTop + layout.rowHeight(g);
    final l = layout.metrics.lineHeight;
    return [
      for (var i = 0; i < count; i++)
        LineBox(
          range: TextRange(
            start: starts[i],
            end: i + 1 < count ? starts[i + 1] : source.end,
          ),
          top: i == 0 ? rowTop : _textTop(g, i),
          bottom: i == count - 1 ? rowBottom : _textTop(g, i) + l,
        ),
    ];
  }

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    final l = layout.metrics.lineHeight;
    final out = <Rect>[];
    for (var g = 0; g < _rowLines.length; g++) {
      for (var j = 0; j < _columns; j++) {
        final cell = _source(g, j);
        if (cell == null) continue;
        final start = math.max(range.start, cell.start) - cell.start;
        final end = math.min(range.end, cell.end) - cell.start;
        if (start >= end) continue;
        final index = g * _columns + j;
        final paragraph = _paragraph(index);
        final dx = _offsetOf(index).dx;
        for (final (i, line) in _cellLines[index].indexed) {
          final from = math.max(start, line.range.start);
          final to = math.min(end, line.range.end);
          if (from >= to) continue;
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: from, extentOffset: to),
          );
          final (left, right) = boxes.isEmpty
              ? _caretX(paragraph, from)
              : (
                  boxes.map((b) => b.left).reduce(math.min),
                  boxes.map((b) => b.right).reduce(math.max),
                );
          final top = _textTop(g, i);
          out.add(Rect.fromLTRB(left + dx, top, right + dx, top + l));
        }
      }
    }
    return out;
  }

  static (double, double) _caretX(RenderParagraph paragraph, int offset) {
    final x = paragraph
        .getOffsetForCaret(TextPosition(offset: offset), Rect.zero)
        .dx;
    return (x, x);
  }

  /// The caret rect at [offset]: zero-width at the caret's x in the cell
  /// [offset] maps to (T2's `tableOffsetTarget`), as tall as that cell's
  /// text line. An offset in the delimiter line shows at the left of the
  /// first header cell's content rect.
  @override
  Rect caretRect(int offset) {
    final target = tableOffsetTarget(
      offset,
      rowLines: _rowLines,
      delimiterLine: TextRange(
        start: table.delimiter.start,
        end: table.delimiter.end,
      ),
      rowCells: _rowCells,
      headerCount: _columns,
    );
    if (target.headerBand) {
      final band = layout.delimiterCaretRect;
      return Rect.fromLTRB(band.left, band.top, band.left, band.bottom);
    }
    final g = target.row;
    final j = target.column;
    final cell = _source(g, j);
    final local = cell == null
        ? 0
        : (target.atTextEnd ? cell.end : offset).clamp(cell.start, cell.end) -
              cell.start;
    final index = g * _columns + j;
    final x = _caretX(_paragraph(index), local).$1 + _offsetOf(index).dx;
    final i = _cellLines[index].lastIndexWhere(
      (line) => line.range.start <= local,
    );
    // Every cell's first line starts at 0, so i >= 0.
    final top = _textTop(g, i);
    return Rect.fromLTRB(x, top, x, top + layout.metrics.lineHeight);
  }

  /// The offset nearest [point] (T2's `TableLayout.hitTest`): the glyph
  /// offset inside a cell's text, else the end of that cell's text.
  @override
  int offsetAt(Offset point) {
    final target = layout.hitTest(point);
    final g = target.row;
    final j = target.column;
    final cell = target.atTextEnd ? null : _source(g, j);
    if (cell == null) return _textEnd(g, j);
    final index = g * _columns + j;
    final local = _paragraph(
      index,
    ).getPositionForOffset(point - _offsetOf(index)).offset;
    return cell.start + math.min(local, cell.end - cell.start);
  }

  /// The end of cell ([g], [j])'s text; for a missing cell, of the row's
  /// last cell; for a row without cells, its line start.
  int _textEnd(int g, int j) {
    final cells = _rowCells[g];
    if (cells.isEmpty) return _rowLines[g].start;
    return cells[math.min(j, cells.length - 1)].end;
  }
}
