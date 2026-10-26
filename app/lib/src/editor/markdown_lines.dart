// Pure-Dart line grammar for live preview (Spec #157 R36, WI #160).
//
// No Flutter imports (ruling D2). Fences mirror `blocks.rs` (`FENCE`, trim
// start + starts_with "```"), leading frontmatter mirrors `split_frontmatter`
// in `link_extractor.rs` (ruling D3). Offsets are UTF-16 code units into the
// classified segment text; a line boundary never falls inside a surrogate
// pair (ruling D4).

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
List<MdLine> classifyLines(String segmentText, {required bool atSegmentStart}) {
  throw UnimplementedError();
}
