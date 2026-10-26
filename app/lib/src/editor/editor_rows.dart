// Pure-Dart editor-row model for live preview (Spec #157 R9, R11, R12, R14,
// R39, R40, WI #160).
//
// An editor row is a UI unit, never a vault Block (TD8). No Flutter imports
// (ruling D2): selections are [SegmentSelection]s in segment offsets, and
// every widget edit is a [SegmentEdit]. Offsets are UTF-16 code units into
// one text segment's text; no boundary falls inside a surrogate pair (D4).

/// The kind of an editor row (Spec R9).
enum RowKind {
  /// A maximal run of lines that are not items and not inside a fence
  /// (paragraphs, headings, blank lines, rules, frontmatter). Keeps its
  /// interior terminators.
  prose,

  /// A fenced code block, from its opening fence line through its closing
  /// fence line, or to the segment end when unclosed. Keeps its interior
  /// terminators.
  code,

  /// A `-`, `*` or `+` item line.
  bullet,

  /// An `N.` item line.
  numbered,

  /// A `- [ ]` / `- [x]` / `- [X]` item line.
  task,

  /// A `> ` (or bare `>`) line.
  quote,
}

/// A selection inside one text segment, in segment offsets.
///
/// [baseOffset] is where the selection started and [extentOffset] where it
/// ends (the caret side); either may be the larger.
class SegmentSelection {
  const SegmentSelection({
    required this.baseOffset,
    required this.extentOffset,
  });

  /// A caret at [offset].
  const SegmentSelection.collapsed(int offset)
    : baseOffset = offset,
      extentOffset = offset;

  final int baseOffset;
  final int extentOffset;

  /// The smaller of [baseOffset] and [extentOffset].
  int get start => baseOffset < extentOffset ? baseOffset : extentOffset;

  /// The larger of [baseOffset] and [extentOffset].
  int get end => baseOffset < extentOffset ? extentOffset : baseOffset;

  bool get isCollapsed => baseOffset == extentOffset;

  @override
  bool operator ==(Object other) =>
      other is SegmentSelection &&
      other.baseOffset == baseOffset &&
      other.extentOffset == extentOffset;

  @override
  int get hashCode => Object.hash(baseOffset, extentOffset);

  @override
  String toString() => 'SegmentSelection($baseOffset, $extentOffset)';
}

/// One row's part of a segment selection, in row-local offsets
/// (`0..row.textLength`).
class RowSlice {
  const RowSlice({required this.row, required this.start, required this.end});

  /// The row's index in the row list.
  final int row;

  /// Local start, `0 <= start <= end`.
  final int start;

  /// Local end, `<= textLength` of the row.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is RowSlice &&
      other.row == row &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(row, start, end);

  @override
  String toString() => 'RowSlice(row $row, $start..$end)';
}

/// One editor row: a view over `[start, end)` of the segment text.
///
/// `start <= textStart <= textEnd <= end`. `[start, textStart)` is an item
/// row's indentation, marker and separator (empty for prose and code rows).
/// `[textStart, textEnd)` is the text the row's field holds: an item's text
/// never holds a terminator; prose and code text keep interior terminators
/// verbatim. `[textEnd, end)` is the row's own line terminator (`'\n'`,
/// `'\r\n'` or empty for the segment's last row).
class RowSpec {
  const RowSpec({
    required this.kind,
    required this.start,
    required this.textStart,
    required this.textEnd,
    required this.end,
    this.indent = 0,
    this.depth = 0,
    this.parent,
    this.done = false,
    this.number,
    this.numberedRun,
    this.runDigits = 0,
  });

  final RowKind kind;
  final int start;
  final int textStart;
  final int textEnd;
  final int end;

  /// An item row's leading indentation in columns (tab = 4), else 0.
  final int indent;

  /// Nesting depth (Spec R12): the parent's depth + 1, or 0 without a parent.
  final int depth;

  /// Index of the parent row (Spec R12): the nearest earlier item row with a
  /// smaller [indent], searching back until the first prose row. Null for
  /// depth 0 and for prose and code rows.
  final int? parent;

  /// Whether a [RowKind.task] row is done (`[x]` or `[X]`).
  final bool done;

  /// The number as written, for a [RowKind.numbered] row.
  final String? number;

  /// For a [RowKind.numbered] row, the index of the first row of its numbered
  /// run (Spec R11): a maximal sequence of numbered rows at the same depth,
  /// ended by a prose row (a blank line included) or a shallower item. Rows
  /// of one run share this value. Null for every other kind.
  final int? numberedRun;

  /// For a [RowKind.numbered] row, the digit count of the widest number in
  /// its run as written (a run `8.`, `9.`, `10.` gives 2). 0 otherwise.
  final int runDigits;

  /// Whether this is a bullet, numbered, task or quote row.
  bool get isItem => kind != RowKind.prose && kind != RowKind.code;

  /// Length of the row's text (`textEnd - textStart`).
  int get textLength => textEnd - textStart;

  /// Converts a segment offset to a row-local text offset, clamped into
  /// `0..textLength` (an offset in the marker maps to 0, one in the
  /// terminator or past the row to [textLength]).
  int toLocal(int segmentOffset) {
    throw UnimplementedError();
  }

  /// Converts a row-local text offset (`0..textLength`) to a segment offset.
  int toSegment(int localOffset) {
    throw UnimplementedError();
  }

  @override
  String toString() =>
      'RowSpec($kind, $start..$textStart..$textEnd..$end, indent $indent, '
      'depth $depth, parent $parent, done $done, number $number, '
      'run $numberedRun/$runDigits)';
}

/// Splits one text segment into editor rows (Spec R9, R39).
///
/// Each item line (bullet, numbered, task, quote; [classifyLines]) is its own
/// row whose text excludes indentation, marker, separator and terminator. A
/// fenced code block, opening fence line through closing fence line, is one
/// [RowKind.code] row; an unclosed fence runs to the segment end. Every
/// maximal run of other lines is one [RowKind.prose] row. Rows tile the
/// text: the first starts at 0, each starts where the previous ends, and the
/// last ends at `text.length`. A segment ending in a terminator ends in a
/// prose row whose last line is empty (an empty prose row after an item or
/// a closed fence); `''` is one empty prose row. [atSegmentStart] is passed
/// to [classifyLines] (leading frontmatter is prose).
List<RowSpec> splitRows(String text, {required bool atSegmentStart}) {
  throw UnimplementedError();
}

/// Joins [rows] of [text] back into the segment text: each row's
/// indentation, marker and separator, its text and its terminator, in
/// order. `joinRows(t, splitRows(t, …)) == t` byte for byte (Spec R14).
String joinRows(String text, List<RowSpec> rows) {
  throw UnimplementedError();
}

/// Each row's local slice of [selection] (Spec R26), one entry per row in
/// [rows]: null for a row the selection doesn't reach, otherwise the part of
/// the row's text inside `[selection.start, selection.end]` in local
/// offsets.
List<RowSlice?> rowSlices(List<RowSpec> rows, SegmentSelection selection) {
  throw UnimplementedError();
}

/// Matches the rows derived before an edit to the rows derived after it
/// (Spec R40), by kind and order.
///
/// Returns one entry per row of [before]: the index in [after] of the row
/// that continues it, or null when it has no continuation. The mapping is
/// injective and keeps order. [edit] is the splice that turned the old text
/// into the new one (for an external write, [SegmentEdit.diff]). The
/// [focused] row's continuation is the row holding the edit's selection
/// when it has one, so the focused row keeps its identity when its text,
/// range or kind changes (a bullet becoming a task, a prose line becoming a
/// bullet once `- ` is typed, a polled append) and when rows before it are
/// inserted or removed.
List<int?> matchRows(
  List<RowSpec> before,
  List<RowSpec> after, {
  required SegmentEdit edit,
  int? focused,
}) {
  throw UnimplementedError();
}

/// A splice of one segment's text: the only way a widget edits it (D2).
///
/// Replaces `[start, end)` with [replacement]. [selection] is the segment
/// selection after the edit, in offsets of the new text; null means the
/// edit doesn't move the selection.
class SegmentEdit {
  const SegmentEdit({
    required this.start,
    required this.end,
    required this.replacement,
    this.selection,
  });

  /// The smallest edit turning [before] into [after]: their common prefix
  /// and suffix are left out, never splitting a surrogate pair. Its
  /// [selection] is null.
  factory SegmentEdit.diff(String before, String after) {
    throw UnimplementedError();
  }

  final int start;
  final int end;
  final String replacement;
  final SegmentSelection? selection;

  /// [text] with `[start, end)` replaced by [replacement]. Throws a
  /// [RangeError] when the range doesn't fit [text].
  String apply(String text) {
    throw UnimplementedError();
  }

  @override
  bool operator ==(Object other) =>
      other is SegmentEdit &&
      other.start == start &&
      other.end == end &&
      other.replacement == replacement &&
      other.selection == selection;

  @override
  int get hashCode => Object.hash(start, end, replacement, selection);

  @override
  String toString() =>
      'SegmentEdit($start..$end -> ${replacement.codeUnits}, $selection)';
}

/// The edit that toggles a task row's checkbox (Spec R24, D12): `[ ]`
/// becomes `[x]`; `[x]` and `[X]` become `[ ]`. Only the box character
/// changes, so indentation, bullet character, text and terminator keep their
/// bytes. The edit carries [selection] unchanged (lengths don't change).
/// Null when [row] isn't a [RowKind.task] row.
SegmentEdit? toggleTask(
  String text,
  RowSpec row, {
  SegmentSelection? selection,
}) {
  throw UnimplementedError();
}
