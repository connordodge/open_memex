// Pure-Dart editor-row model for live preview (Spec #157 R9, R11, R12, R14,
// R39, R40, WI #160).
//
// An editor row is a UI unit, never a vault Block (TD8). No Flutter imports
// (ruling D2): selections are [SegmentSelection]s in segment offsets, and
// every widget edit is a [SegmentEdit]. Offsets are UTF-16 code units into
// one text segment's text; no boundary falls inside a surrogate pair (D4).

import 'markdown_lines.dart';

/// The kind of an editor row (Spec R9).
enum RowKind {
  /// A maximal run of lines that are not items, not inside a fence and not
  /// table lines (paragraphs, headings, blank lines, rules, frontmatter).
  /// Keeps its interior terminators.
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

  /// A markdown table (Spec #197 R8), from its header line through its last
  /// body line. Keeps its interior terminators.
  table,
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
  /// smaller [indent], searching back until the first prose, code or table
  /// row. Null for depth 0 and for prose, code and table rows.
  final int? parent;

  /// Whether a [RowKind.task] row is done (`[x]` or `[X]`).
  final bool done;

  /// The number as written, for a [RowKind.numbered] row.
  final String? number;

  /// For a [RowKind.numbered] row, the index of the first row of its numbered
  /// run (Spec R11): a maximal sequence of numbered rows at the same depth,
  /// ended by a prose row (a blank line included), a code or table row, or
  /// a shallower item. Rows
  /// of one run share this value. Null for every other kind.
  final int? numberedRun;

  /// For a [RowKind.numbered] row, the digit count of the widest number in
  /// its run as written (a run `8.`, `9.`, `10.` gives 2). 0 otherwise.
  final int runDigits;

  /// Whether this is a bullet, numbered, task or quote row (Spec #197 TD3:
  /// never a prose, code or table row).
  bool get isItem =>
      kind == RowKind.bullet ||
      kind == RowKind.numbered ||
      kind == RowKind.task ||
      kind == RowKind.quote;

  /// Length of the row's text (`textEnd - textStart`).
  int get textLength => textEnd - textStart;

  /// Converts a segment offset to a row-local text offset, clamped into
  /// `0..textLength` (an offset in the marker maps to 0, one in the
  /// terminator or past the row to [textLength]).
  int toLocal(int segmentOffset) =>
      (segmentOffset - textStart).clamp(0, textLength);

  /// Converts a row-local text offset (`0..textLength`) to a segment offset.
  int toSegment(int localOffset) =>
      textStart + localOffset.clamp(0, textLength);

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
/// [RowKind.code] row; an unclosed fence runs to the segment end. A table,
/// header line through last body line, is one [RowKind.table] row (Spec
/// #197 R8) whose text starts at its line start and keeps its interior
/// terminators, like a code row. Every maximal run of other lines is one
/// [RowKind.prose] row. Rows tile the
/// text: the first starts at 0, each starts where the previous ends, and the
/// last ends at `text.length`. A segment ending in a terminator ends in a
/// prose row whose last line is empty (an empty prose row after an item or
/// a closed fence); `''` is one empty prose row. [atSegmentStart] is passed
/// to [classifyLines] (leading frontmatter is prose).
List<RowSpec> splitRows(String text, {required bool atSegmentStart}) {
  final lines = classifyLines(text, atSegmentStart: atSegmentStart);
  final rows = <RowSpec>[];
  // Indices of the open numbered runs by depth (R11).
  final runs = <int, int>{};
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final kind = _itemKinds[line.kind];
    if (kind == null) {
      // A code row runs from its opening fence line through its closing one
      // (or the segment end); a table row from its header line through its
      // last body line; a prose row is a maximal run of the rest.
      final block = _blockKinds[line.kind] ?? RowKind.prose;
      var last = i;
      while (last + 1 < lines.length &&
          _continues(block, lines[last].kind, lines[last + 1].kind)) {
        last++;
      }
      rows.add(
        RowSpec(
          kind: block,
          start: line.start,
          textStart: line.start,
          textEnd: lines[last].contentEnd,
          end: lines[last].end,
        ),
      );
      runs.clear();
      i = last + 1;
      continue;
    }
    final parent = _parent(rows, line.indent);
    final depth = parent == null ? 0 : rows[parent].depth + 1;
    runs.removeWhere((runDepth, _) => runDepth > depth);
    int? run;
    if (kind == RowKind.numbered) {
      run = runs.putIfAbsent(depth, () => rows.length);
    } else {
      runs.remove(depth);
    }
    rows.add(
      RowSpec(
        kind: kind,
        start: line.start,
        textStart: line.textStart,
        textEnd: line.contentEnd,
        end: line.end,
        indent: line.indent,
        depth: depth,
        parent: parent,
        done: line.done,
        number: line.number,
        numberedRun: run,
      ),
    );
    i++;
  }
  return _withRunDigits(rows);
}

/// The row kind of each item line kind.
const _itemKinds = {
  MdLineKind.bullet: RowKind.bullet,
  MdLineKind.numbered: RowKind.numbered,
  MdLineKind.task: RowKind.task,
  MdLineKind.quote: RowKind.quote,
};

/// The row kind of each line kind that opens a code or table row.
const _blockKinds = {
  MdLineKind.fenceOpen: RowKind.code,
  MdLineKind.tableHeader: RowKind.table,
};

/// Whether a row of kind [block] whose last line so far has kind [last]
/// takes the next line, of kind [next].
bool _continues(RowKind block, MdLineKind last, MdLineKind next) =>
    switch (block) {
      RowKind.code => last != MdLineKind.fenceClose,
      RowKind.table =>
        next == MdLineKind.tableDelimiter || next == MdLineKind.tableBody,
      RowKind.prose ||
      RowKind.bullet ||
      RowKind.numbered ||
      RowKind.task ||
      RowKind.quote => _proseKinds.contains(next),
    };

/// The line kinds a prose row is made of: neither items, fence lines nor
/// table lines.
const _proseKinds = {
  MdLineKind.blank,
  MdLineKind.plain,
  MdLineKind.heading,
  MdLineKind.rule,
  MdLineKind.frontmatter,
};

/// The parent of a new item row with [indent] (Spec R12): the nearest
/// earlier item row with a smaller indent, searching back until the first
/// prose, code or table row.
int? _parent(List<RowSpec> rows, int indent) {
  for (var i = rows.length - 1; i >= 0; i--) {
    final row = rows[i];
    if (!row.isItem) return null;
    if (row.indent < indent) return i;
  }
  return null;
}

/// [rows] with each numbered row's [RowSpec.runDigits] set to the widest
/// number of its run, as written (Spec R11).
List<RowSpec> _withRunDigits(List<RowSpec> rows) {
  final widest = <int, int>{};
  for (final row in rows) {
    final run = row.numberedRun;
    if (run == null) continue;
    final digits = row.number!.length;
    if (digits > (widest[run] ?? 0)) widest[run] = digits;
  }
  return [
    for (final row in rows)
      if (row.numberedRun case final run?)
        RowSpec(
          kind: row.kind,
          start: row.start,
          textStart: row.textStart,
          textEnd: row.textEnd,
          end: row.end,
          indent: row.indent,
          depth: row.depth,
          parent: row.parent,
          number: row.number,
          numberedRun: run,
          runDigits: widest[run]!,
        )
      else
        row,
  ];
}

/// Joins [rows] of [text] back into the segment text: each row's
/// indentation, marker and separator, its text and its terminator, in
/// order. `joinRows(t, splitRows(t, …)) == t` byte for byte (Spec R14).
String joinRows(String text, List<RowSpec> rows) {
  final out = StringBuffer();
  for (final row in rows) {
    out
      ..write(text.substring(row.start, row.textStart))
      ..write(text.substring(row.textStart, row.textEnd))
      ..write(text.substring(row.textEnd, row.end));
  }
  return out.toString();
}

/// Each row's local slice of [selection] (Spec R26), one entry per row in
/// [rows]: null for a row the selection doesn't reach, otherwise the part of
/// the row's text inside `[selection.start, selection.end]` in local
/// offsets.
List<RowSlice?> rowSlices(List<RowSpec> rows, SegmentSelection selection) {
  final start = selection.start;
  final end = selection.end;
  final caretRow = selection.isCollapsed ? _rowAt(rows, start) : null;
  return [
    for (final (i, row) in rows.indexed)
      if (selection.isCollapsed
          ? i == caretRow
          : start < row.end && end > row.start)
        RowSlice(row: i, start: row.toLocal(start), end: row.toLocal(end))
      else
        null,
  ];
}

/// Index of the row holding segment [offset]: the row with
/// `start <= offset < end`, or the last row for an offset at or past the
/// segment end. -1 for no rows.
int _rowAt(List<RowSpec> rows, int offset) {
  for (var i = 0; i < rows.length; i++) {
    if (offset < rows[i].end) return i;
  }
  return rows.length - 1;
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
/// inserted or removed. Any other row whose kind changed has no
/// continuation.
List<int?> matchRows(
  List<RowSpec> before,
  List<RowSpec> after, {
  required SegmentEdit edit,
  int? focused,
}) {
  final result = List<int?>.filled(before.length, null);
  if (after.isEmpty) return result;
  final selection = edit.selection;
  final target =
      focused != null &&
          focused >= 0 &&
          focused < before.length &&
          selection != null
      ? _rowAt(after, selection.extentOffset)
      : null;
  final inserted = edit.replacement.length;
  final delta = inserted - (edit.end - edit.start);
  var last = -1;
  for (final (k, old) in before.indexed) {
    if (k == focused && target != null) {
      result[k] = last = target;
      continue;
    }
    // A non-empty row the edit replaced entirely has no continuation.
    if (edit.start <= old.start && old.end <= edit.end && old.start < old.end) {
      continue;
    }
    // Where the row's start lands in the new text: unchanged before the
    // edit, shifted after it, at the end of the replacement inside it.
    final int anchor;
    if (old.start < edit.start) {
      anchor = old.start;
    } else if (old.start >= edit.end) {
      anchor = old.start + delta;
    } else {
      anchor = edit.start + inserted;
    }
    final j = _rowAt(after, anchor);
    if (j <= last) continue;
    // Rows match by kind: only the focused row may change kind.
    if (k != focused && after[j].kind != old.kind) continue;
    if (target != null && k < focused! && j >= target) continue;
    result[k] = last = j;
  }
  return result;
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
    final shorter = before.length < after.length ? before.length : after.length;
    var prefix = 0;
    while (prefix < shorter &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    if (_splitsPair(before, prefix) || _splitsPair(after, prefix)) prefix--;
    var suffix = 0;
    while (suffix < shorter - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    if (_splitsPair(before, before.length - suffix) ||
        _splitsPair(after, after.length - suffix)) {
      suffix--;
    }
    return SegmentEdit(
      start: prefix,
      end: before.length - suffix,
      replacement: after.substring(prefix, after.length - suffix),
    );
  }

  final int start;
  final int end;
  final String replacement;
  final SegmentSelection? selection;

  /// [text] with `[start, end)` replaced by [replacement]. Throws a
  /// [RangeError] when the range doesn't fit [text].
  String apply(String text) => text.replaceRange(start, end, replacement);

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
  if (row.kind != RowKind.task) return null;
  // The box character: after the indentation, the bullet, its space and `[`.
  var box = row.start;
  while (text.codeUnitAt(box) == 0x20 || text.codeUnitAt(box) == 0x09) {
    box++;
  }
  box += 3;
  return SegmentEdit(
    start: box,
    end: box + 1,
    replacement: text.codeUnitAt(box) == 0x20 ? 'x' : ' ',
    selection: selection,
  );
}

/// Whether [offset] falls between the two halves of a surrogate pair.
bool _splitsPair(String text, int offset) =>
    offset > 0 &&
    offset < text.length &&
    _isHighSurrogate(text.codeUnitAt(offset - 1)) &&
    _isLowSurrogate(text.codeUnitAt(offset));

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
