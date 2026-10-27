// Pure-Dart list indent and outdent (Spec #193 R2-R27, WI #194).
//
// No Flutter imports (ruling D2 of #157). Live preview calls these with one
// segment's text and selection; Source mode with the whole body and its
// selection. Structure comes from `splitRows(text, atSegmentStart: true)`.
//
// A move rewrites only the leading whitespace of item lines and the number
// text of numbered items; it never adds, removes or reorders lines, so row
// indices stay valid across every intermediate step.

import 'dart:math';

import 'editor_rows.dart';

/// Indent ([outdent] false) or outdent the list items [selection] touches in
/// [text]: one edit, or null when nothing moves (Spec #193 R2-R27).
/// [source] picks R21/R25's Source-mode touch rule (whole lines) over the
/// live-preview one (item text).
SegmentEdit? indentListItems(
  String text,
  SegmentSelection selection, {
  bool outdent = false,
  bool source = false,
}) {
  final rows = splitRows(text, atSegmentStart: true);
  final touched = _touched(rows, selection, source: source);
  if (touched.isEmpty) return null;
  final layout = _Layout(text, rows);
  // R21: an item inside a touched item's subtree moves once, with it. R24:
  // the group moves top to bottom, each item against the structure the
  // items above it left (R22: all or nothing).
  var subtreeEnd = 0;
  for (final item in touched) {
    if (item < subtreeEnd) continue;
    subtreeEnd = _subtreeEnd(rows, item);
    if (!(outdent ? layout.outdent(item) : layout.indent(item))) return null;
  }
  layout.renumber();
  final edit = SegmentEdit.diff(text, layout.render());
  return SegmentEdit(
    start: edit.start,
    end: edit.end,
    replacement: edit.replacement,
    selection: SegmentSelection(
      baseOffset: layout.map(selection.baseOffset),
      extentOffset: layout.map(selection.extentOffset),
    ),
  );
}

/// Whether [selection] touches a list item (bullet, numbered or task) of
/// [text], by the same rule as [indentListItems].
bool touchesListItem(
  String text,
  SegmentSelection selection, {
  bool source = false,
}) => _touched(
  splitRows(text, atSegmentStart: true),
  selection,
  source: source,
).isNotEmpty;

/// The row kinds that are list items for indent and outdent (Spec #193 R2,
/// ruling D3): positive membership, so quotes and any later kind are not.
const _listKinds = {RowKind.bullet, RowKind.numbered, RowKind.task};

bool _isListItem(RowSpec row) => _listKinds.contains(row.kind);

/// Indices of the list items [selection] touches, top to bottom (R21, R25,
/// R29). A caret touches the item line it sits on, from the line start to
/// its content end. A range touches an item when it overlaps the item's text
/// (live preview) or line ([source]), but not when it only reaches the
/// item text's offset 0 (live preview) or the line's first character.
List<int> _touched(
  List<RowSpec> rows,
  SegmentSelection selection, {
  required bool source,
}) {
  final start = selection.start;
  final end = selection.end;
  return [
    for (final (i, row) in rows.indexed)
      if (_isListItem(row) &&
          (selection.isCollapsed
              ? row.start <= start && start <= row.textEnd
              : start <= row.textEnd &&
                    end > (source ? row.start : row.textStart)))
        i,
  ];
}

/// The index just past the subtree of item [item] (R2): the following list
/// items deeper than it.
int _subtreeEnd(List<RowSpec> rows, int item) {
  var end = item + 1;
  while (end < rows.length &&
      _isListItem(rows[end]) &&
      rows[end].depth > rows[item].depth) {
    end++;
  }
  return end;
}

/// The previous sibling of item [item] (R2): the nearest earlier list item
/// at its depth, searching back only over deeper list items. Null when a
/// shallower item, a quote, a prose row or a code row comes first.
int? _previousSibling(List<RowSpec> rows, int item) {
  final depth = rows[item].depth;
  for (var i = item - 1; i >= 0; i--) {
    final row = rows[i];
    if (!_isListItem(row) || row.depth < depth) return null;
    if (row.depth == depth) return i;
  }
  return null;
}

/// Width in columns of [indent] (space 1, tab 4, as Spec #157 R12).
int _columns(String indent) =>
    indent.codeUnits.fold(0, (sum, unit) => sum + (unit == _tab ? 4 : 1));

const _space = 0x20;
const _tab = 0x09;

/// The text of every row of one text while a move rewrites the indentation
/// and numbers of its item lines.
class _Layout {
  _Layout(this.text, this.rows)
    : _markerStart = [for (final row in rows) _markerOf(text, row)],
      _numbers = [for (final row in rows) row.number],
      _starts = List.filled(rows.length, 0),
      _textStarts = List.filled(rows.length, 0) {
    _indents.addAll([
      for (final (i, row) in rows.indexed)
        text.substring(row.start, _markerStart[i]),
    ]);
    _current = rows;
  }

  /// The text before the move and its rows.
  final String text;
  final List<RowSpec> rows;

  /// Where each row's marker starts in [text]: after a list item's leading
  /// whitespace, else the row start.
  final List<int> _markerStart;

  /// Each row's indentation string now ('' for rows that are not list
  /// items) and number text now (null for rows that are not numbered).
  final List<String> _indents = [];
  final List<String?> _numbers;

  /// Each row's start and text start in the last [render].
  final List<int> _starts;
  final List<int> _textStarts;

  late List<RowSpec> _current;
  var _stale = false;

  static int _markerOf(String text, RowSpec row) {
    if (!_isListItem(row)) return row.start;
    var at = row.start;
    while (text.codeUnitAt(at) == _space || text.codeUnitAt(at) == _tab) {
      at++;
    }
    return at;
  }

  /// The rows of the text as it is now.
  List<RowSpec> get _now {
    if (_stale) {
      _current = splitRows(render(), atSegmentStart: true);
      _stale = false;
    }
    return _current;
  }

  /// Makes [item] the last child of its previous sibling (R10), with its
  /// subtree (R12). False when it has no previous sibling (R5).
  bool indent(int item) {
    final rows = _now;
    final sibling = _previousSibling(rows, item);
    if (sibling == null) return false;
    // R10: the indentation of the sibling's last child, else the sibling's
    // own indentation plus spaces to its content column.
    var target = '${_indents[sibling]}${' ' * _contentWidth(rows[sibling])}';
    for (var i = item - 1; i > sibling; i--) {
      if (rows[i].parent == sibling) {
        target = _indents[i];
        break;
      }
    }
    _shift(item, target, _subtreeEnd(rows, item));
    return true;
  }

  /// Makes [item] its parent's next sibling with the parent's indentation
  /// (R11), with its subtree (R12); its following siblings become its
  /// children (R13). False for a top-level item (R5).
  bool outdent(int item) {
    final rows = _now;
    final parent = rows[item].parent;
    if (parent == null) return false;
    final depth = rows[item].depth;
    final end = _subtreeEnd(rows, item);
    final siblings = <(int, int)>[];
    var next = end;
    while (next < rows.length &&
        _isListItem(rows[next]) &&
        rows[next].depth >= depth) {
      final siblingEnd = _subtreeEnd(rows, next);
      siblings.add((next, siblingEnd));
      next = siblingEnd;
    }
    _shift(item, _indents[parent], end);
    // R13: a former sibling keeps its bytes while they make it a child of
    // [item]; otherwise it takes the indentation of [item]'s last child
    // above it (R10's copy rule), with its subtree.
    for (final (sibling, siblingEnd) in siblings) {
      final now = _now;
      if (now[sibling].parent == item) continue;
      var child = sibling - 1;
      while (now[child].parent != item) {
        child--;
      }
      _shift(sibling, _indents[child], siblingEnd);
    }
    return true;
  }

  /// Gives [item] the indentation [target] and shifts the rest of its
  /// subtree, up to [end], by the same change (R12): a line whose
  /// indentation starts with the item's old indentation has that prefix
  /// replaced; any other line (mixed tabs and spaces) becomes spaces at its
  /// old column count plus the change. That count always stays above the
  /// item's new one, because a subtree line is indented deeper than its
  /// root.
  void _shift(int item, String target, int end) {
    final old = _indents[item];
    final change = _columns(target) - _columns(old);
    _indents[item] = target;
    for (var i = item + 1; i < end; i++) {
      final indent = _indents[i];
      _indents[i] = indent.startsWith(old)
          ? '$target${indent.substring(old.length)}'
          : ' ' * (_columns(indent) + change);
    }
    _stale = true;
  }

  /// Renumbers every numbered run the moves touched (R16-R19): a run with a
  /// row whose parent or run changed. It counts up from 1 when its first
  /// row's parent changed, else from the number the first row of that row's
  /// old run had, as written (R17). Other runs keep their numbers.
  void renumber() {
    final after = _now;
    final before = _runs(rows);
    for (final members in _runs(after).values) {
      final touched = members.any(
        (i) =>
            after[i].parent != rows[i].parent ||
            !_sameRows(before[rows[i].numberedRun]!, members),
      );
      if (!touched) continue;
      final first = members.first;
      final start = after[first].parent != rows[first].parent
          ? 1
          : int.parse(rows[rows[first].numberedRun!].number!);
      for (final (k, i) in members.indexed) {
        _numbers[i] = _padded(start + k, rows[i].number!);
      }
    }
  }

  /// The text as it is now; records each row's start and text start.
  String render() {
    final out = StringBuffer();
    for (final (i, row) in rows.indexed) {
      _starts[i] = out.length;
      var from = row.start;
      if (_isListItem(row)) {
        out.write(_indents[i]);
        from = _markerStart[i];
        if (_numbers[i] case final number?) {
          out.write(number);
          from += row.number!.length;
        }
      }
      _textStarts[i] = out.length + row.textStart - from;
      out.write(text.substring(from, row.end));
    }
    return out.toString();
  }

  /// Where [offset] of [text] lands in the last [render] (R27): an offset in
  /// a row's text, terminator or prose keeps its place relative to the text
  /// start; one in an item's indentation or marker keeps its distance from
  /// the text start, but not before the row start.
  int map(int offset) {
    var i = 0;
    while (i < rows.length - 1 && offset >= rows[i].end) {
      i++;
    }
    final row = rows[i];
    if (offset >= row.textStart) {
      return _textStarts[i] + offset - row.textStart;
    }
    return max(_starts[i], _textStarts[i] - (row.textStart - offset));
  }
}

/// The content column of list item [row] relative to its marker (R10): the
/// marker width plus its one space (a task's checkbox is content).
int _contentWidth(RowSpec row) =>
    row.kind == RowKind.numbered ? row.number!.length + 2 : 2;

/// The rows of each numbered run of [rows], keyed by the run's first row.
Map<int, List<int>> _runs(List<RowSpec> rows) {
  final runs = <int, List<int>>{};
  for (final (i, row) in rows.indexed) {
    if (row.numberedRun case final run?) (runs[run] ??= []).add(i);
  }
  return runs;
}

bool _sameRows(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [value] written for a number that was [written]: zero-padded to the
/// written width when the written number has a leading zero (R18, `08`
/// gives `01`), else plain (`11` gives `1`, `9` gives `10`).
String _padded(int value, String written) =>
    written.startsWith('0') ? '$value'.padLeft(written.length, '0') : '$value';
