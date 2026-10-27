// WI #203 (T2): a rendered table's geometry as pure numbers (Spec #197 R18,
// R19, R21 mapping, TD5; rulings D13, D21). The design pack
// `design/192-md-tables/packs/203.md` defines every rule here and wins over
// numbers copied elsewhere.
//
// Numbers in, numbers out: callers (the rendered grid, T4) measure cell text
// and pass the scaled metrics; nothing here measures text or paints, and no
// design number is a constant in this file (D21). No Flutter imports; only
// `dart:math` and `dart:ui`'s plain value types. Pixels are logical pixels.

import 'dart:ui' show Offset, Rect, TextAlign, TextRange;

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
  throw UnimplementedError();
}

/// How much a table grows when it reveals (revealed height minus rendered
/// height) when its header and body cells are one line each: `L - H`
/// (14.95 at text scale 1), the same for any number of body rows.
double tableRevealDelta(TableMetrics metrics) {
  throw UnimplementedError();
}

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
  double get width => throw UnimplementedError();

  /// The header band's height: the header's tallest cell's lines times L,
  /// plus H.
  double get bandHeight => throw UnimplementedError();

  /// The table's rendered height: the band plus every body row.
  double get height => throw UnimplementedError();

  /// The top of grid row [row] (0 = header band at 0; body rows follow
  /// cumulatively with no gaps).
  double rowTop(int row) => throw UnimplementedError();

  /// The height of grid row [row]: the band for 0, else the row's tallest
  /// cell's lines times L.
  double rowHeight(int row) => throw UnimplementedError();

  /// The left x of [column].
  double columnLeft(int column) => throw UnimplementedError();

  /// The rules between body rows, top to bottom: one rect
  /// `(0, rowBottom - t, width, t)` in the last pixel inside every body row
  /// except the last. None under the header band or the last row.
  List<Rect> get rules => throw UnimplementedError();

  /// Cell ([row], [column])'s rect: its column's x-range and its row's
  /// y-range.
  Rect cellRect(int row, int column) => throw UnimplementedError();

  /// Cell ([row], [column])'s content rect: [cellRect] inset by c left and
  /// right, and in the header band by H / 2 top and bottom. Body cells have
  /// no vertical inset.
  Rect contentRect(int row, int column) => throw UnimplementedError();

  /// The left x of a laid-out line [lineWidth] wide in [column]: left
  /// `x + c`, right `x + w - c - lineWidth`, centre `x + (w - lineWidth) / 2`.
  /// `start` and `justify` lay out as left, `end` as right.
  double lineLeft(
    int column, {
    required double lineWidth,
    required TextAlign align,
  }) => throw UnimplementedError();

  /// Where the caret shows for an offset in the hidden delimiter line: the
  /// first header cell's content rect (never zero-height).
  Rect get delimiterCaretRect => throw UnimplementedError();

  /// The cell [point] falls in (R21). A point left of the grid or right of
  /// it clamps to the first or last column, above the band to the header,
  /// below the table to the last body row (the header if none).
  ///
  /// [TableCellTarget.atTextEnd] is false only when the point is inside the
  /// cell's content x-range and inside that cell's own text block (its
  /// lines times L from the content top), off the rule pixel, in a
  /// non-empty cell.
  TableCellTarget hitTest(Offset point) => throw UnimplementedError();
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
  throw UnimplementedError();
}
