// Pure-Dart line grammar for live preview (Spec #157 R36, WI #160).
//
// No Flutter imports (ruling D2). Fences mirror `blocks.rs` (`FENCE`, trim
// start + starts_with "```"), leading frontmatter mirrors `split_frontmatter`
// in `link_extractor.rs` (ruling D3). Offsets are UTF-16 code units into the
// classified segment text; a line boundary never falls inside a surrogate
// pair (ruling D4). Table cells come from the one cell splitter in
// `markdown_table.dart` (ruling D10).

import 'markdown_table.dart';

/// The kind of one source line (Spec R36).
enum MdLineKind {
  /// An empty line, or one holding only spaces and tabs (as `blocks.rs`
  /// treats a whitespace-only line as blank). Never used inside a fence or
  /// frontmatter.
  blank,

  /// Any other line: paragraph text, `#tag`, `1)`, `~~~`, indented code.
  plain,

  /// `#`..`######` then exactly one space, at line start ([MdLine.level]).
  heading,

  /// Indent + `-`, `*` or `+` + one space + text.
  bullet,

  /// Indent + 1–9 digits + `.` + one space + text ([MdLine.number]).
  numbered,

  /// A bullet marker + one space + `[ ]`, `[x]` or `[X]` + one space or end
  /// of line ([MdLine.done]).
  task,

  /// `> ` or `>` at end of line, at line start.
  quote,

  /// Only 3 or more of the same `-`, `*` or `_`.
  rule,

  /// The line that opens a fenced code block: ```` ``` ```` after any leading
  /// whitespace.
  fenceOpen,

  /// A line between a fence's opening and closing lines (or after an
  /// unclosed opening line), blank lines included.
  fenceInside,

  /// The next line after [fenceOpen] that starts with ```` ``` ```` after any
  /// leading whitespace.
  fenceClose,

  /// A line of leading frontmatter (`---` … `---`, both delimiter lines
  /// included). Only when classified with `atSegmentStart: true`.
  frontmatter,

  /// A table's header line (Spec #197 R1): a line that would otherwise be
  /// [plain], directly followed by a valid [tableDelimiter] line.
  tableHeader,

  /// A table's delimiter line (Spec #197 R1, R5), such as `|---|:-:|`.
  tableDelimiter,

  /// A table body line (Spec #197 R4).
  tableBody,
}

/// One classified source line of a segment.
///
/// Every offset is a UTF-16 code-unit offset into the segment text passed to
/// [classifyLines]. For [MdLineKind.heading], the item kinds
/// ([MdLineKind.bullet], [MdLineKind.numbered], [MdLineKind.task]) and
/// [MdLineKind.quote], `[markerStart, markerEnd)` is the marker (`##`, `-`,
/// `12.`, `- [ ]`, `>`) and `[separatorStart, separatorEnd)` is the one
/// separating space (empty when the marker ends the line, as for `>` or
/// `- [x]` at end of line). For every other kind all four equal [start].
class MdLine {
  const MdLine({
    required this.kind,
    required this.start,
    required this.contentEnd,
    required this.end,
    required this.terminator,
    required this.indent,
    required this.markerStart,
    required this.markerEnd,
    required this.separatorStart,
    required this.separatorEnd,
    this.level = 0,
    this.number,
    this.done = false,
  });

  final MdLineKind kind;

  /// Offset of the line's first code unit.
  final int start;

  /// Offset just past the line's content, before its terminator.
  final int contentEnd;

  /// Offset just past the terminator (`contentEnd + terminator.length`).
  final int end;

  /// `'\n'`, `'\r\n'` or `''` (last line without one), kept verbatim. A lone
  /// `\r` is content, not a terminator.
  final String terminator;

  /// Leading indentation in columns: a space counts 1, a tab counts 4.
  final int indent;

  final int markerStart;
  final int markerEnd;
  final int separatorStart;
  final int separatorEnd;

  /// Heading level 1–6 for [MdLineKind.heading], else 0.
  final int level;

  /// The number as written (`'007'` for `007. x`) for [MdLineKind.numbered],
  /// else null.
  final String? number;

  /// Whether a [MdLineKind.task] is done (`[x]` or `[X]`).
  final bool done;

  /// Offset where the line's text starts: [separatorEnd] for marker lines,
  /// [start] for every other kind.
  int get textStart => separatorEnd;

  /// Whether this is a bullet, numbered, task or quote line (an item row,
  /// Spec R9).
  bool get isItem =>
      kind == MdLineKind.bullet ||
      kind == MdLineKind.numbered ||
      kind == MdLineKind.task ||
      kind == MdLineKind.quote;

  @override
  String toString() =>
      'MdLine($kind, $start..$contentEnd..$end, indent $indent, '
      'marker $markerStart..$markerEnd, separator $separatorStart..'
      '$separatorEnd, level $level, number $number, done $done)';
}

/// Classifies every line of [segmentText] (Spec R36).
///
/// Lines split at `\n` and `\r\n` only. The result always covers the whole
/// text in order: the first line starts at 0, each line starts where the
/// previous one ends, and the last line ends at `segmentText.length`. There
/// is one more line than terminators, so `''` gives one empty
/// [MdLineKind.blank] line and a text ending in a terminator ends with an
/// empty line.
///
/// Fences follow `blocks.rs`: a line whose text after any leading whitespace
/// starts with ```` ``` ```` opens; the next such line closes; an unclosed
/// fence runs to the end of the text, its last empty line included. Lines
/// inside are [MdLineKind.fenceInside] and never items, headings or rules.
///
/// When [atSegmentStart] is true and the text's first line is exactly `---`
/// (its terminator aside) and a later line trims to `---`, those lines and
/// every line between are [MdLineKind.frontmatter], as `split_frontmatter`
/// in `link_extractor.rs` decides. A text shorter than 4 code units never
/// has frontmatter. With [atSegmentStart] false, frontmatter is never
/// recognised.
///
/// Tables (Spec #197 R1-R4, R7) form only from lines that would otherwise be
/// [MdLineKind.plain], each with at most 3 leading spaces (a tab counts 4
/// columns) and a cell-splitting `|` ([splitTableLine]). Such a line is a
/// [MdLineKind.tableHeader] when the next line is a delimiter line with as
/// many cells as it ([delimiterAlignments]); that next line is the
/// [MdLineKind.tableDelimiter]. The [MdLineKind.tableBody] lines follow it
/// until a line that is not such a line; a header and delimiter pair inside
/// a body starts a new table (ruling D23). Fence and frontmatter lines are
/// never table lines.
List<MdLine> classifyLines(String segmentText, {required bool atSegmentStart}) {
  final ranges = _scanLines(segmentText);
  final lines = <MdLine>[];
  var next = 0;
  if (atSegmentStart) {
    final close = _frontmatterClose(segmentText, ranges);
    if (close != null) {
      for (; next <= close; next++) {
        lines.add(
          _plainLine(segmentText, ranges[next], MdLineKind.frontmatter),
        );
      }
    }
  }
  var inFence = false;
  // Whether the previous line is a table header, and whether it is a
  // delimiter or body line (a line a body line may follow).
  var afterHeader = false;
  var inTable = false;
  for (; next < ranges.length; next++) {
    final range = ranges[next];
    final content = segmentText.substring(range.start, range.contentEnd);
    final isFence = content.trimLeft().startsWith(_fence);
    if (inFence) {
      inFence = !isFence;
      lines.add(
        _plainLine(
          segmentText,
          range,
          isFence ? MdLineKind.fenceClose : MdLineKind.fenceInside,
        ),
      );
    } else if (isFence) {
      inFence = true;
      lines.add(_plainLine(segmentText, range, MdLineKind.fenceOpen));
    } else {
      final line = _classify(segmentText, range, content);
      final table = line.kind == MdLineKind.plain
          ? _tableKind(segmentText, ranges, next, afterHeader, inTable)
          : null;
      lines.add(table == null ? line : _plainLine(segmentText, range, table));
    }
    final kind = lines.last.kind;
    afterHeader = kind == MdLineKind.tableHeader;
    inTable = kind == MdLineKind.tableDelimiter || kind == MdLineKind.tableBody;
  }
  return lines;
}

/// At most this many leading columns on a table line (Spec #197 R3).
const _maxTableIndent = 3;

/// The table kind of line [i], which [_classify] gives [MdLineKind.plain],
/// or null when it is no table line (Spec #197 R1, R4, ruling D23).
/// [afterHeader] says whether the previous line is a table header, and
/// [inTable] whether it is a delimiter or body line.
MdLineKind? _tableKind(
  String text,
  List<_LineRange> ranges,
  int i,
  bool afterHeader,
  bool inTable,
) {
  // The header's lookahead already checked this delimiter line.
  if (afterHeader) return MdLineKind.tableDelimiter;
  final line = _tableLine(text, ranges[i]);
  if (line == null) return null;
  if (_delimiterBelow(text, ranges, i, line.cells.length)) {
    return MdLineKind.tableHeader;
  }
  return inTable ? MdLineKind.tableBody : null;
}

/// The cells of the line [range] when it can be a table line: at most
/// [_maxTableIndent] columns of indentation and a cell-splitting `|`.
TableLine? _tableLine(String text, _LineRange range) {
  final content = text.substring(range.start, range.contentEnd);
  if (_indent(content).$1 > _maxTableIndent) return null;
  final line = splitTableLine(text, start: range.start, end: range.contentEnd);
  return line.pipes.isEmpty ? null : line;
}

/// Whether the line after line [i] is a delimiter line with [columns] cells
/// that would otherwise be plain (so `- | -` stays a bullet).
bool _delimiterBelow(String text, List<_LineRange> ranges, int i, int columns) {
  if (i + 1 == ranges.length) return false;
  final range = ranges[i + 1];
  final content = text.substring(range.start, range.contentEnd);
  if (_classify(text, range, content).kind != MdLineKind.plain) return false;
  final line = _tableLine(text, range);
  return line != null && delimiterAlignments(text, line)?.length == columns;
}

/// A fenced code block opens and closes on a line starting with this after
/// any leading whitespace (`FENCE` in `blocks.rs`).
const _fence = '```';

/// One line's offsets before classification.
typedef _LineRange = ({int start, int contentEnd, int end});

/// Splits [text] at `\n` and `\r\n`; one more range than terminators.
List<_LineRange> _scanLines(String text) {
  final ranges = <_LineRange>[];
  var start = 0;
  while (true) {
    final newline = text.indexOf('\n', start);
    if (newline < 0) {
      ranges.add((start: start, contentEnd: text.length, end: text.length));
      return ranges;
    }
    final contentEnd = newline > start && text.codeUnitAt(newline - 1) == _cr
        ? newline - 1
        : newline;
    ranges.add((start: start, contentEnd: contentEnd, end: newline + 1));
    start = newline + 1;
  }
}

const _cr = 0x0D;
const _space = 0x20;
const _tab = 0x09;

/// Index of the line closing leading frontmatter, or null when [text] has
/// none (`split_frontmatter` in `link_extractor.rs`): at least 4 code units,
/// a first line that is exactly `---`, and a later line that trims to `---`.
int? _frontmatterClose(String text, List<_LineRange> ranges) {
  if (text.length < 4) return null;
  final first = ranges.first;
  if (text.substring(first.start, first.contentEnd) != '---') return null;
  for (var i = 1; i < ranges.length; i++) {
    final r = ranges[i];
    if (text.substring(r.start, r.contentEnd).trim() == '---') return i;
  }
  return null;
}

/// Leading indentation of [content] in columns (space 1, tab 4) and its
/// length in code units.
(int columns, int length) _indent(String content) {
  var columns = 0;
  var i = 0;
  for (; i < content.length; i++) {
    final c = content.codeUnitAt(i);
    if (c == _space) {
      columns += 1;
    } else if (c == _tab) {
      columns += 4;
    } else {
      break;
    }
  }
  return (columns, i);
}

/// A line without marker or separator.
MdLine _plainLine(String text, _LineRange range, MdLineKind kind) {
  final content = text.substring(range.start, range.contentEnd);
  return MdLine(
    kind: kind,
    start: range.start,
    contentEnd: range.contentEnd,
    end: range.end,
    terminator: text.substring(range.contentEnd, range.end),
    indent: _indent(content).$1,
    markerStart: range.start,
    markerEnd: range.start,
    separatorStart: range.start,
    separatorEnd: range.start,
  );
}

/// A line with a marker at `[markerStart, markerEnd)` (offsets into
/// [content]) followed by one separating space, or none at end of line.
MdLine _markerLine(
  String text,
  _LineRange range,
  String content,
  MdLineKind kind,
  int markerStart,
  int markerEnd, {
  int level = 0,
  String? number,
  bool done = false,
}) {
  final separatorEnd = markerEnd < content.length ? markerEnd + 1 : markerEnd;
  return MdLine(
    kind: kind,
    start: range.start,
    contentEnd: range.contentEnd,
    end: range.end,
    terminator: text.substring(range.contentEnd, range.end),
    indent: _indent(content).$1,
    markerStart: range.start + markerStart,
    markerEnd: range.start + markerEnd,
    separatorStart: range.start + markerEnd,
    separatorEnd: range.start + separatorEnd,
    level: level,
    number: number,
    done: done,
  );
}

/// Whether [content] has a space at [index].
bool _spaceAt(String content, int index) =>
    index < content.length && content.codeUnitAt(index) == _space;

/// Classifies one line outside fences and frontmatter (Spec R36).
MdLine _classify(String text, _LineRange range, String content) {
  if (content.trimLeft().isEmpty) {
    return _plainLine(text, range, MdLineKind.blank);
  }
  if (_isRule(content)) return _plainLine(text, range, MdLineKind.rule);

  final level = _countWhile(content, 0, (c) => c == 0x23 /* # */);
  if (level >= 1 && level <= 6 && _spaceAt(content, level)) {
    return _markerLine(
      text,
      range,
      content,
      MdLineKind.heading,
      0,
      level,
      level: level,
    );
  }

  if (content.codeUnitAt(0) == 0x3E /* > */ &&
      (content.length == 1 || _spaceAt(content, 1))) {
    return _markerLine(text, range, content, MdLineKind.quote, 0, 1);
  }

  final at = _indent(content).$2;
  if (at < content.length && '-*+'.contains(content[at])) {
    if (!_spaceAt(content, at + 1)) {
      return _plainLine(text, range, MdLineKind.plain);
    }
    final box = content.length >= at + 5
        ? content.substring(at + 2, at + 5)
        : '';
    if ((box == '[ ]' || box == '[x]' || box == '[X]') &&
        (content.length == at + 5 || _spaceAt(content, at + 5))) {
      return _markerLine(
        text,
        range,
        content,
        MdLineKind.task,
        at,
        at + 5,
        done: box != '[ ]',
      );
    }
    return _markerLine(text, range, content, MdLineKind.bullet, at, at + 1);
  }

  final digits = _countWhile(content, at, (c) => c >= 0x30 && c <= 0x39);
  final dot = at + digits;
  if (digits >= 1 &&
      digits <= 9 &&
      dot < content.length &&
      content.codeUnitAt(dot) == 0x2E /* . */ &&
      _spaceAt(content, dot + 1)) {
    return _markerLine(
      text,
      range,
      content,
      MdLineKind.numbered,
      at,
      dot + 1,
      number: content.substring(at, dot),
    );
  }
  return _plainLine(text, range, MdLineKind.plain);
}

/// How many code units of [content] from [from] satisfy [test].
int _countWhile(String content, int from, bool Function(int) test) {
  var i = from;
  while (i < content.length && test(content.codeUnitAt(i))) {
    i++;
  }
  return i - from;
}

/// Only 3 or more of the same `-`, `*` or `_` (Spec R36).
bool _isRule(String content) {
  if (content.length < 3 || !'-*_'.contains(content[0])) return false;
  final c = content.codeUnitAt(0);
  return _countWhile(content, 0, (u) => u == c) == content.length;
}
