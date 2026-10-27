// Pure-Dart markdown table cells (Spec #197 R1, R2, R5, R6, WI #202).
//
// The ONE cell splitter (ruling D10): `classifyLines`, the grid, revealed
// styling, link hit-testing and excerpt cards all delegate here. No Flutter
// imports. Offsets are UTF-16 code units into the text passed in.

import 'markdown_inline.dart';
import 'markdown_lines.dart';

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
///
/// A `|` splits cells unless a backslash escapes it (`\|` stays in its
/// cell, backslash included; `\\` escapes the backslash, as GFM scans a
/// row) or it lies inside a wikilink token of [tokenizeInline]
/// (`[[Title~kind|alias]]` stays whole, L6; an unclosed `[[` is no token).
/// The empty stretch before a leading `|` and after a trailing `|` makes no
/// cell. A line without a cell-splitting `|` is one cell.
TableLine splitTableLine(String text, {int start = 0, int? end}) {
  final stop = end ?? text.length;
  final links = [
    for (final token in tokenizeInline(text.substring(start, stop)))
      if (token.kind == InlineTokenKind.wikilink) token.span,
  ];
  final pipes = <int>[];
  var link = 0;
  var i = start;
  while (i < stop) {
    while (link < links.length && start + links[link].end <= i) {
      link++;
    }
    if (link < links.length && start + links[link].start <= i) {
      i = start + links[link].end;
    } else if (text.codeUnitAt(i) == _backslash) {
      i += 2;
    } else {
      if (text.codeUnitAt(i) == _pipe) pipes.add(i);
      i++;
    }
  }
  final bounds = [start - 1, ...pipes, stop];
  final cells = <TableCell>[];
  for (var k = 1; k < bounds.length; k++) {
    final cell = _trimmed(text, bounds[k - 1] + 1, bounds[k]);
    final outer = k == 1 || k == bounds.length - 1;
    if (!(outer && pipes.isNotEmpty && cell.start == cell.end)) {
      cells.add(cell);
    }
  }
  return TableLine(start: start, end: stop, cells: cells, pipes: pipes);
}

const _backslash = 0x5C;
const _pipe = 0x7C;

/// `[start, end)` of [text] without its leading and trailing spaces and
/// tabs; an empty range at [end] when nothing else is left.
TableCell _trimmed(String text, int start, int end) {
  var from = start;
  while (from < end && _isSpace(text.codeUnitAt(from))) {
    from++;
  }
  var to = end;
  while (to > from && _isSpace(text.codeUnitAt(to - 1))) {
    to--;
  }
  return TableCell(from, to);
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

/// A delimiter cell's text: dashes with an optional colon at either end
/// (Spec #197 R5).
final _delimiterCell = RegExp(r'^:?-+:?$');

/// The alignment of each cell of [line] in [text] when every cell is a
/// delimiter cell (`---`, `:--`, `--:`, `:-:`), else null (Spec #197 R1,
/// R5). A cell with a colon at both ends is centered, one ending in a colon
/// is right aligned, any other is left aligned.
List<TableAlign>? delimiterAlignments(String text, TableLine line) {
  final alignments = <TableAlign>[];
  for (final cell in line.cells) {
    final t = cell.text(text);
    if (!_delimiterCell.hasMatch(t)) return null;
    alignments.add(
      t.endsWith(':')
          ? (t.startsWith(':') ? TableAlign.center : TableAlign.right)
          : TableAlign.left,
    );
  }
  return alignments;
}

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
///
/// The lines are classified as [classifyLines] does away from a segment
/// start, so a table here is exactly a table there; the body is the run of
/// [MdLineKind.tableBody] lines after the delimiter line.
ParsedTable? parseTable(String rowText) {
  final lines = classifyLines(rowText, atSegmentStart: false);
  if (lines.first.kind != MdLineKind.tableHeader) return null;
  TableLine split(MdLine line) =>
      splitTableLine(rowText, start: line.start, end: line.contentEnd);
  final header = split(lines[0]);
  final delimiter = split(lines[1]);
  final columns = header.cells.length;
  return ParsedTable(
    header: header,
    delimiter: delimiter,
    alignments: delimiterAlignments(rowText, delimiter)!,
    body: [
      for (final line
          in lines
              .skip(2)
              .takeWhile((line) => line.kind == MdLineKind.tableBody))
        _bodyRow(split(line), columns),
    ],
  );
}

/// [line] as a body row of a table with [columns] columns (Spec #197 R6).
TableBodyRow _bodyRow(TableLine line, int columns) => TableBodyRow(
  line: line,
  cells: line.cells.take(columns).toList(),
  beyond: line.cells.skip(columns).toList(),
);
