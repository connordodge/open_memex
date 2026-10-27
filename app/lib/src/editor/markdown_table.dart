// Pure-Dart markdown table cells (Spec #197 R1, R2, R5, R6, WI #202).
//
// The ONE cell splitter (ruling D10): `classifyLines`, the grid, revealed
// styling, link hit-testing and excerpt cards all delegate here. No Flutter
// imports. Offsets are UTF-16 code units into the text passed in.

/// A column's alignment, from its delimiter cell (Spec #197 R5).
enum TableAlign { left, center, right }

/// One cell of a table line: the source range `[start, end)` of its text,
/// trimmed of surrounding spaces and tabs (empty for an empty cell).
final class TableCell {
  const TableCell(this.start, this.end);

  final int start;
  final int end;

  /// The cell's text in [source] (the text its offsets index).
  String text(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is TableCell && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TableCell($start..$end)';
}

/// One line split into cells.
final class TableLine {
  const TableLine({
    required this.start,
    required this.end,
    required this.cells,
    required this.pipes,
  });

  /// Offset of the line's first code unit.
  final int start;

  /// Offset just past the line's content (before any terminator).
  final int end;

  /// The line's cells in order. One leading and one trailing `|` make no
  /// extra cell.
  final List<TableCell> cells;

  /// Offsets of the cell-splitting `|`s, in order (never a `\|` or a `|`
  /// inside a wikilink token).
  final List<int> pipes;

  @override
  String toString() => 'TableLine($start..$end, $cells, pipes $pipes)';
}

/// Splits the line `[start, end)` of [text] (no terminator; [end] defaults
/// to `text.length`) into cells (Spec #197 R2, ruling D10).
TableLine splitTableLine(String text, {int start = 0, int? end}) =>
    throw UnimplementedError('WI #202');

/// One body line of a parsed table (Spec #197 R6).
final class TableBodyRow {
  const TableBodyRow({
    required this.line,
    required this.cells,
    required this.beyond,
  });

  /// The whole line, every cell included.
  final TableLine line;

  /// The cells inside the header's column count (fewer when the line has
  /// fewer cells).
  final List<TableCell> cells;

  /// The cells past the header's column count: not drawn in the grid, kept
  /// in the bytes.
  final List<TableCell> beyond;
}

/// A parsed table (Spec #197 R1, R5, R6).
final class ParsedTable {
  const ParsedTable({
    required this.header,
    required this.delimiter,
    required this.alignments,
    required this.body,
  });

  final TableLine header;
  final TableLine delimiter;

  /// One alignment per column, from the delimiter cells.
  final List<TableAlign> alignments;

  /// The body lines, in order (none for a header-only table).
  final List<TableBodyRow> body;

  /// The header's cell count.
  int get columnCount => header.cells.length;
}

/// Parses one table row's text [rowText]: a header line, a delimiter line
/// and zero or more body lines, joined by `\n` or `\r\n`. Offsets index
/// [rowText]. Null when [rowText] doesn't start with a header line and a
/// valid delimiter line.
ParsedTable? parseTable(String rowText) => throw UnimplementedError('WI #202');
