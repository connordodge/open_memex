// WI #203 (T2): a rendered table's geometry as pure numbers (Spec #197 R18,
// R19, R21 mapping, TD5; rulings D13, D21). The design pack
// `design/192-md-tables/packs/203.md` defines every rule here and wins over
// numbers copied elsewhere.
//
// Numbers in, numbers out: callers (the rendered grid, T4) measure cell text
// and pass the scaled metrics; nothing here measures text or paints, and no
// design number is a constant in this file (D21). No Flutter imports; only
// `dart:math` and `dart:ui`'s plain value types. Pixels are logical pixels.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, TextAlign, TextRange;

double _sum(Iterable<double> values) => values.fold(0.0, (a, b) => a + b);

/// The scaled metrics a [TableLayout] is built from (D21). Every value is
/// passed in by the caller at the editor's text scale.
final class TableMetrics {
  const TableMetrics({
    required this.lineHeight,
    required this.hiddenLineHeight,
    required this.cellPadding,
    required this.ruleThickness,
  });

  /// L: one body line's height (22.95 at text scale 1).
  final double lineHeight;

  /// H: the hidden delimiter line's height, as a hidden fence line (8 at
  /// text scale 1). The header band takes it in.
  final double hiddenLineHeight;

  /// c: a cell's left and right padding, one mono column (8.1 at text
  /// scale 1).
  final double cellPadding;

  /// t: the thickness of the rule between body rows (1, not scaled).
  final double ruleThickness;
}

/// One column's measured text widths, text only, without padding (pack 203).
final class TableColumnMeasure {
  const TableColumnMeasure({
    required this.naturalWidth,
    required this.minWidth,
    this.noWrap = false,
  });

  /// n: the column's widest cell laid out on one line. 0 for an empty
  /// column.
  final double naturalWidth;

  /// m: the column's widest unbreakable word (split on spaces). 0 for an
  /// empty column.
  final double minWidth;

  /// Whether the column is right- or centre-aligned, so it keeps its cells
  /// on one line while the table can afford it.
  final bool noWrap;
}

/// The widths of a table's columns (R19, pack 203's column-width rule),
/// left to right, always summing to [availableWidth] (W).
///
/// With `N = n + 2c`, `M = m + 2c`, `B = min(3c, N)` per column, where c is
/// [cellPadding]:
/// 1. Spread: if `sum(N) <= W`, `w = N * W / sum(N)`.
/// 2. Floors: `F = noWrap ? N : M`; if `sum(F) >= W`, `F = M` for every
///    column.
/// 3. Hopeless: if still `sum(F) >= W`: when `sum(B) >= W`,
///    `w = B * W / sum(B)`; else `w = B + (M - B) * g` with
///    `g = (W - sum(B)) / (sum(M) - sum(B))`. Words then break between
///    characters.
/// 4. Shrink: `w = max(F, B + (N - B) * f)` for the `f` in [0, 1) that
///    makes the widths sum to W, found by freezing columns at their floor.
///
/// No column is below its floor F unless step 3 applies.
List<double> tableColumnWidths(
  List<TableColumnMeasure> columns, {
  required double availableWidth,
  required double cellPadding,
}) {
  final w = availableWidth;
  final pad = 2 * cellPadding;
  final natural = [for (final col in columns) col.naturalWidth + pad];
  final mins = [for (final col in columns) col.minWidth + pad];
  final breakFloor = [for (final n in natural) math.min(3 * cellPadding, n)];

  // 1. Spread: everything fits.
  final sumNatural = _sum(natural);
  if (sumNatural <= w) {
    return [for (final n in natural) n * w / sumNatural];
  }

  // 2. Floors: no-wrap columns keep their natural width while they can.
  var floors = [
    for (var i = 0; i < columns.length; i++)
      columns[i].noWrap ? natural[i] : mins[i],
  ];
  if (_sum(floors) >= w) floors = mins;

  // 3. Hopeless: even the widest words don't fit; words break anywhere.
  if (_sum(floors) >= w) {
    final sumBreak = _sum(breakFloor);
    if (sumBreak >= w) {
      return [for (final b in breakFloor) b * w / sumBreak];
    }
    final g = (w - sumBreak) / (_sum(mins) - sumBreak);
    return [
      for (var i = 0; i < columns.length; i++)
        breakFloor[i] + (mins[i] - breakFloor[i]) * g,
    ];
  }

  // 4. Shrink: every free column takes B + (N - B) f; a column that would
  // fall under its floor freezes there. Each pass freezes at least one
  // column or ends the loop.
  final frozen = List<bool>.filled(columns.length, false);
  var f = 0.0;
  while (true) {
    var fixed = 0.0;
    var span = 0.0;
    for (var i = 0; i < columns.length; i++) {
      if (frozen[i]) {
        fixed += floors[i];
      } else {
        fixed += breakFloor[i];
        span += natural[i] - breakFloor[i];
      }
    }
    f = (w - fixed) / span;
    var froze = false;
    for (var i = 0; i < columns.length; i++) {
      if (!frozen[i] &&
          breakFloor[i] + (natural[i] - breakFloor[i]) * f < floors[i]) {
        frozen[i] = true;
        froze = true;
      }
    }
    if (!froze) break;
  }
  return [
    for (var i = 0; i < columns.length; i++)
      frozen[i] ? floors[i] : breakFloor[i] + (natural[i] - breakFloor[i]) * f,
  ];
}

/// How much a table grows when it reveals (revealed height minus rendered
/// height) when its header and body cells are one line each: `L - H`
/// (14.95 at text scale 1), the same for any number of body rows.
double tableRevealDelta(TableMetrics metrics) =>
    metrics.lineHeight - metrics.hiddenLineHeight;

/// A cell of a rendered table that a point or a field offset maps to
/// (R21, D13).
final class TableCellTarget {
  const TableCellTarget({
    required this.row,
    required this.column,
    this.atTextEnd = false,
    this.headerBand = false,
  });

  /// The grid row: 0 is the header, `1 + i` is body row i.
  final int row;

  /// The drawn column, 0 to the header's column count - 1.
  final int column;

  /// The caller puts the caret at the end of this cell's text (the point is
  /// in the cell's padding, on a rule, in the header band's blank area,
  /// below the cell's own text, in an empty cell or outside the grid; or the
  /// offset is in a dropped cell).
  final bool atTextEnd;

  /// The offset is in the hidden delimiter line: the caret shows in the
  /// header band ([TableLayout.delimiterCaretRect]).
  final bool headerBand;

  @override
  bool operator ==(Object other) =>
      other is TableCellTarget &&
      other.row == row &&
      other.column == column &&
      other.atTextEnd == atTextEnd &&
      other.headerBand == headerBand;

  @override
  int get hashCode => Object.hash(row, column, atTextEnd, headerBand);

  @override
  String toString() =>
      'TableCellTarget(row: $row, column: $column, atTextEnd: $atTextEnd, '
      'headerBand: $headerBand)';
}

/// A rendered table's vertical and horizontal layout, grid-local (origin at
/// the grid's top-left, x from 0 to [width]).
///
/// Built from the column widths ([tableColumnWidths]) and every cell's line
/// count as the grid wrapped it. A line count of 0 marks an empty cell; it
/// takes one line's height like a one-line cell.
class TableLayout {
  /// [headerLines] holds one line count per column; [bodyLines] one list
  /// per body row, each with one line count per column.
  TableLayout({
    required this.columnWidths,
    required this.headerLines,
    required this.bodyLines,
    required this.metrics,
  });

  /// The column widths, left to right.
  final List<double> columnWidths;

  /// The header cells' line counts (0 = empty cell).
  final List<int> headerLines;

  /// The body cells' line counts per body row (0 = empty cell).
  final List<List<int>> bodyLines;

  /// The scaled metrics.
  final TableMetrics metrics;

  /// The grid's width: the sum of [columnWidths].
  double get width => _lefts.last;

  /// The header band's height: the header's tallest cell's lines times L,
  /// plus H.
  double get bandHeight => _heights.first;

  /// The table's rendered height: the band plus every body row.
  double get height => _tops.last;

  /// The top of grid row [row] (0 = header band at 0; body rows follow
  /// cumulatively with no gaps).
  double rowTop(int row) => _tops[row];

  /// The height of grid row [row]: the band for 0, else the row's tallest
  /// cell's lines times L.
  double rowHeight(int row) => _heights[row];

  /// The left x of [column].
  double columnLeft(int column) => _lefts[column];

  /// The rules between body rows, top to bottom: one rect
  /// `(0, rowBottom - t, width, t)` in the last pixel inside every body row
  /// except the last. None under the header band or the last row.
  List<Rect> get rules => [
    for (var row = 1; row < _heights.length - 1; row++)
      Rect.fromLTWH(
        0,
        _rowBottom(row) - metrics.ruleThickness,
        width,
        metrics.ruleThickness,
      ),
  ];

  /// Cell ([row], [column])'s rect: its column's x-range and its row's
  /// y-range.
  Rect cellRect(int row, int column) => Rect.fromLTRB(
    _lefts[column],
    _tops[row],
    _lefts[column] + columnWidths[column],
    _rowBottom(row),
  );

  /// Cell ([row], [column])'s content rect: [cellRect] inset by c left and
  /// right, and in the header band by H / 2 top and bottom. Body cells have
  /// no vertical inset.
  Rect contentRect(int row, int column) {
    final inset = row == 0 ? metrics.hiddenLineHeight / 2 : 0.0;
    final left = _lefts[column];
    final c = metrics.cellPadding;
    return Rect.fromLTRB(
      left + c,
      _tops[row] + inset,
      left + columnWidths[column] - c,
      _rowBottom(row) - inset,
    );
  }

  /// The left x of a laid-out line [lineWidth] wide in [column]: left
  /// `x + c`, right `x + w - c - lineWidth`, centre `x + (w - lineWidth) / 2`.
  /// `start` and `justify` lay out as left, `end` as right.
  double lineLeft(
    int column, {
    required double lineWidth,
    required TextAlign align,
  }) {
    final left = _lefts[column];
    final w = columnWidths[column];
    return switch (align) {
      TextAlign.left ||
      TextAlign.start ||
      TextAlign.justify => left + metrics.cellPadding,
      TextAlign.right ||
      TextAlign.end => left + w - metrics.cellPadding - lineWidth,
      TextAlign.center => left + (w - lineWidth) / 2,
    };
  }

  /// Where the caret shows for an offset in the hidden delimiter line: the
  /// first header cell's content rect (never zero-height).
  Rect get delimiterCaretRect => contentRect(0, 0);

  /// The cell [point] falls in (R21). A point left of the grid or right of
  /// it clamps to the first or last column, above the band to the header,
  /// below the table to the last body row (the header if none).
  ///
  /// [TableCellTarget.atTextEnd] is false only when the point is inside the
  /// cell's content x-range and inside that cell's own text block (its
  /// lines times L from the content top), off the rule pixel, in a
  /// non-empty cell.
  TableCellTarget hitTest(Offset point) {
    // Points outside the grid fall in the first or last column or row here,
    // and then outside its content rect, so they get the text end flag.
    var column = 0;
    for (var j = 1; j < columnWidths.length; j++) {
      if (_lefts[j] <= point.dx) column = j;
    }
    var row = 0;
    for (var r = 1; r < _heights.length; r++) {
      if (_tops[r] <= point.dy) row = r;
    }
    final content = contentRect(row, column);
    var textBottom = content.top + _lineCount(row, column) * metrics.lineHeight;
    if (row > 0 && row < _heights.length - 1) {
      // The rule pixel at the bottom of every body row but the last.
      textBottom = math.min(
        textBottom,
        _rowBottom(row) - metrics.ruleThickness,
      );
    }
    final inText =
        point.dx >= content.left &&
        point.dx < content.right &&
        point.dy >= content.top &&
        point.dy < textBottom;
    return TableCellTarget(row: row, column: column, atTextEnd: !inText);
  }

  /// Every grid row's height: the band, then each body row.
  late final List<double> _heights = [
    _tallest(headerLines) * metrics.lineHeight + metrics.hiddenLineHeight,
    for (final row in bodyLines) _tallest(row) * metrics.lineHeight,
  ];

  /// Every grid row's top, then the table's bottom.
  late final List<double> _tops = _cumulative(_heights);

  /// Every column's left, then the grid's right.
  late final List<double> _lefts = _cumulative(columnWidths);

  double _rowBottom(int row) => _tops[row] + _heights[row];

  /// Cell ([row], [column])'s line count as passed (0 = empty cell).
  int _lineCount(int row, int column) =>
      row == 0 ? headerLines[column] : bodyLines[row - 1][column];

  /// A row's tallest cell's line count; an empty cell takes one line.
  static int _tallest(List<int> lines) => lines.fold(1, math.max);

  static List<double> _cumulative(List<double> sizes) {
    final out = [0.0];
    for (final size in sizes) {
      out.add(out.last + size);
    }
    return out;
  }
}

/// The cell a field offset of a rendered table maps to (D13).
///
/// [rowLines] are the grid rows' source lines (header line first, then each
/// body line, without line terminators), [delimiterLine] the delimiter
/// line's, and [rowCells] every grid row's trimmed cell ranges, dropped
/// cells (index >= [headerCount], R6) included.
///
/// The line holding [offset] is the last of the header, delimiter and body
/// lines starting at or before it. An offset in the delimiter line maps to
/// the header band ([TableCellTarget.headerBand]); in a grid row, to the
/// last cell starting at or before it (cell 0 before the first cell); in a
/// dropped cell, to the text end of that row's last drawn cell (column
/// [headerCount] - 1).
TableCellTarget tableOffsetTarget(
  int offset, {
  required List<TextRange> rowLines,
  required TextRange delimiterLine,
  required List<List<TextRange>> rowCells,
  required int headerCount,
}) {
  // Lines are in source order: header, delimiter, then body lines.
  var row = 0;
  for (var r = 1; r < rowLines.length; r++) {
    if (rowLines[r].start <= offset) row = r;
  }
  if (row == 0 && delimiterLine.start <= offset) {
    return const TableCellTarget(row: 0, column: 0, headerBand: true);
  }
  final cells = rowCells[row];
  var column = 0;
  for (var j = 1; j < cells.length; j++) {
    if (cells[j].start <= offset) column = j;
  }
  if (column >= headerCount) {
    return TableCellTarget(row: row, column: headerCount - 1, atTextEnd: true);
  }
  return TableCellTarget(row: row, column: column);
}
