// Pure-Dart structural edits for editor rows and Source-mode list
// continuation (Spec #157 R14-R20, R31, WI #162).
//
// No Flutter imports (ruling D2). Every function returns the [SegmentEdit]
// a widget applies as one edit, with the segment selection after it, or
// null when the key does nothing structural (the field keeps its default
// behaviour). Offsets are UTF-16 code units into one text segment's text.
// A line created by an edit uses the terminator of the line it was split
// from (`\r\n` stays `\r\n`, R14); a line without a terminator (the
// segment's last) is split with `\n`. Output bytes are exact (D17).

import 'editor_rows.dart';
import 'markdown_lines.dart';

/// Enter in item row [row] of [rows] (from `splitRows(text, ...)`), whose
/// text isn't empty, with the caret at segment offset [caret] (inside the
/// row's text) (Spec R15).
///
/// Splits the item at the caret: the new item below gets the same
/// indentation and marker and takes the text after the caret; the selection
/// after the edit is a caret at offset 0 of its text. Bullets repeat their
/// character, `N.` becomes `N+1.` (later items keep their numbers) and a
/// task continues as an unchecked `[ ] ` with the same bullet character.
/// A quote doesn't continue (R22): its new line is a plain line.
/// Null when [row] is a prose or code row.
SegmentEdit? splitItem(String text, List<RowSpec> rows, int row, int caret) {
  final spec = rows[row];
  if (!spec.isItem) return null;
  return _insertLine(
    caret.clamp(spec.textStart, spec.textEnd),
    _terminator(text, spec.textEnd, spec.end),
    _nextPrefix(text, spec.start, spec.textStart, spec.kind, spec.number),
  );
}

/// Enter in item row [row] whose text is empty (Spec R16): removes its
/// indentation and marker, leaving an empty plain line with the caret on
/// it. Every other line keeps its bytes. Null when the row has text or is a
/// prose or code row.
SegmentEdit? enterOnEmpty(String text, List<RowSpec> rows, int row) {
  final spec = rows[row];
  if (!spec.isItem || spec.textLength != 0) return null;
  return _removePrefix(spec.start, spec.textStart);
}

/// Shift+Enter in item row [row] with the caret at segment offset [caret]
/// (Spec R17): inserts a plain line below the item, with no marker, that
/// takes the text after the caret; the caret goes to its start. Null when
/// [row] is a prose or code row.
SegmentEdit? shiftEnter(String text, List<RowSpec> rows, int row, int caret) {
  final spec = rows[row];
  if (!spec.isItem) return null;
  return _insertLine(
    caret.clamp(spec.textStart, spec.textEnd),
    _terminator(text, spec.textEnd, spec.end),
    '',
  );
}

/// Backspace at offset 0 of item row [row]'s text (Spec R18): removes its
/// indentation and marker (a done task loses `[x]`), so the line becomes a
/// plain line with the same text, and the caret stays before the text. Null
/// when [row] is a prose or code row.
SegmentEdit? backspaceAtStart(String text, List<RowSpec> rows, int row) {
  final spec = rows[row];
  if (!spec.isItem) return null;
  return _removePrefix(spec.start, spec.textStart);
}

/// Backspace with the caret at segment offset [caret], the start of a plain
/// line in row [row] (Spec R19): joins that line onto the end of the line
/// above, whether the line above is prose or an item, by removing the
/// terminator between them; the caret goes to the join point. Null on the
/// segment's first line, in an item row and when [caret] isn't at a line
/// start.
SegmentEdit? joinPrevious(String text, List<RowSpec> rows, int row, int caret) {
  if (rows[row].isItem || caret <= 0) return null;
  if (text.codeUnitAt(caret - 1) != _lf) return null;
  final join = caret >= 2 && text.codeUnitAt(caret - 2) == _cr
      ? caret - 2
      : caret - 1;
  return SegmentEdit(
    start: join,
    end: caret,
    replacement: '',
    selection: SegmentSelection.collapsed(join),
  );
}

/// Forward Delete at the end of row [row]'s text (Spec R20): joins the next
/// line's text onto it. When the next line is an item, its indentation and
/// marker are dropped; any other line (a heading's `#` included) joins as
/// it is. The caret stays at the join point. Null at the segment end.
SegmentEdit? deleteForwardAtEnd(String text, List<RowSpec> rows, int row) {
  final spec = rows[row];
  if (spec.end >= text.length) return null;
  final next = rows[row + 1];
  return SegmentEdit(
    start: spec.textEnd,
    end: next.isItem ? next.textStart : next.start,
    replacement: '',
    selection: SegmentSelection.collapsed(spec.textEnd),
  );
}

/// Enter ([shift] false) or Shift+Enter ([shift] true) in Source mode, on
/// the whole body [text] with [selection] (Spec R31).
///
/// A non-collapsed selection is replaced by the newline first, then
/// continuation applies at its start. A line that starts (after leading
/// spaces) with a list prefix (bullet, numbered or task, by the A1 line
/// grammar with `atSegmentStart: true`) continues as in R15; a line holding
/// only a prefix loses it, leaving an empty line with the caret on it.
/// Null, meaning a plain newline, for Shift+Enter, quote lines, lines inside
/// a fence or frontmatter, lines without a list prefix and a caret before
/// the line's text.
SegmentEdit? sourceEnter(
  String text,
  SegmentSelection selection, {
  bool shift = false,
}) {
  if (shift) return null;
  final start = selection.start;
  final removed = selection.end - start;
  final body = text.replaceRange(start, selection.end, '');
  final edit = _continueLine(body, start);
  if (edit == null) return null;
  // One edit of [text] for "delete the selection, then [edit] of [body]":
  // a [body] offset at or after [start] sits [removed] units later in
  // [text].
  final from = edit.start < start ? edit.start : start;
  final to = edit.end > start ? edit.end : start;
  return SegmentEdit(
    start: from,
    end: to + removed,
    replacement:
        body.substring(from, edit.start) +
        edit.replacement +
        body.substring(edit.end, to),
    selection: edit.selection,
  );
}

/// One edit equal to applying [first] and then [second] (ruling D20: one
/// user action is one [SegmentEdit], one content report and one undo
/// record). [second] is expressed on the text after [first] is applied; the
/// result is one splice on the text before [first], and applying it gives
/// the same bytes as applying [first] then [second].
///
/// The result's selection is [second]'s when it has one; otherwise
/// [first]'s mapped through [second] (an offset before [second]'s range
/// keeps its place, one at or after its end shifts by [second]'s length
/// change, one inside it goes to the end of [second]'s replacement); null
/// when neither edit has a selection.
///
/// When [second]'s range neither overlaps nor touches the text [first]
/// wrote, the splice must also carry the original text between them, so
/// [text] (the text before [first]) is required and an [ArgumentError] is
/// thrown without it. Touching or overlapping edits never read [text].
SegmentEdit composeEdits(
  SegmentEdit first,
  SegmentEdit second, {
  String? text,
}) {
  final written = first.start + first.replacement.length;
  final firstDelta = first.replacement.length - (first.end - first.start);
  final touching = second.start <= written && second.end >= first.start;
  if (!touching && text == null) {
    throw ArgumentError.value(
      text,
      'text',
      'needed to compose edits that do not touch: $first then $second',
    );
  }
  // `[lo, hi)` in the text after [first]; `lo` is the same offset before it.
  final lo = first.start < second.start ? first.start : second.start;
  final hi = written > second.end ? written : second.end;

  // The text after [first] in `[a, b)`.
  String between(int a, int b) {
    if (a >= b) return '';
    final out = StringBuffer();
    if (a < first.start) {
      out.write(text!.substring(a, b < first.start ? b : first.start));
    }
    final ra = a > first.start ? a : first.start;
    final rb = b < written ? b : written;
    if (ra < rb) {
      out.write(
        first.replacement.substring(ra - first.start, rb - first.start),
      );
    }
    if (b > written) {
      final from = a > written ? a : written;
      out.write(text!.substring(from - firstDelta, b - firstDelta));
    }
    return out.toString();
  }

  final secondDelta = second.replacement.length - (second.end - second.start);
  int map(int offset) {
    if (offset < second.start) return offset;
    if (offset >= second.end) return offset + secondDelta;
    return second.start + second.replacement.length;
  }

  final carried = first.selection;
  return SegmentEdit(
    start: lo,
    end: hi - firstDelta,
    replacement:
        between(lo, second.start) +
        second.replacement +
        between(second.end, hi),
    selection:
        second.selection ??
        (carried == null
            ? null
            : SegmentSelection(
                baseOffset: map(carried.baseOffset),
                extentOffset: map(carried.extentOffset),
              )),
  );
}

/// Enter at [caret] of the whole Source body [body] with no selection: the
/// R15 continuation of a bullet, numbered or task line, or the R16 prefix
/// removal of a line holding only its prefix. Null for every other line and
/// for a caret before the line's text.
SegmentEdit? _continueLine(String body, int caret) {
  for (final line in classifyLines(body, atSegmentStart: true)) {
    if (caret < line.start || caret > line.contentEnd) continue;
    final kind = _continuedKinds[line.kind];
    if (kind == null || caret < line.textStart) return null;
    if (line.textStart == line.contentEnd) {
      return _removePrefix(line.start, line.textStart);
    }
    return _insertLine(
      caret,
      _terminator(body, line.contentEnd, line.end),
      _nextPrefix(body, line.start, line.textStart, kind, line.number),
    );
  }
  return null;
}

/// The line kinds Source mode continues (quotes don't, R31).
const _continuedKinds = {
  MdLineKind.bullet: RowKind.bullet,
  MdLineKind.numbered: RowKind.numbered,
  MdLineKind.task: RowKind.task,
};

const _lf = 0x0A;
const _cr = 0x0D;
const _space = 0x20;
const _tab = 0x09;

/// Inserts [terminator] + [prefix] at [at]: the text after [at] moves to
/// the new line, and the caret goes to the start of its text.
SegmentEdit _insertLine(int at, String terminator, String prefix) {
  final replacement = terminator + prefix;
  return SegmentEdit(
    start: at,
    end: at,
    replacement: replacement,
    selection: SegmentSelection.collapsed(at + replacement.length),
  );
}

/// Removes an item line's indentation, marker and separator
/// `[start, textStart)`; the caret stays before the text.
SegmentEdit _removePrefix(int start, int textStart) => SegmentEdit(
  start: start,
  end: textStart,
  replacement: '',
  selection: SegmentSelection.collapsed(start),
);

/// The terminator `[contentEnd, end)` of a line, or `\n` for the segment's
/// last line, which has none (R14).
String _terminator(String text, int contentEnd, int end) =>
    end > contentEnd ? text.substring(contentEnd, end) : '\n';

/// The indentation, marker and separator of the item that continues the
/// item line `[start, textStart)` of [kind] (R15): a bullet repeats its
/// prefix, `N.` becomes `N+1.`, a task continues as an unchecked `[ ] `
/// with the same bullet character, and a quote doesn't continue (R22), so
/// its new line is plain.
String _nextPrefix(
  String text,
  int start,
  int textStart,
  RowKind kind,
  String? number,
) {
  var marker = start;
  while (text.codeUnitAt(marker) == _space || text.codeUnitAt(marker) == _tab) {
    marker++;
  }
  final indent = text.substring(start, marker);
  return switch (kind) {
    RowKind.numbered => '$indent${_increment(number!)}. ',
    RowKind.task => '$indent${text[marker]} [ ] ',
    RowKind.bullet => text.substring(start, textStart),
    _ => '',
  };
}

/// [number] + 1, zero-padded to the digits of [number] as written (`9`
/// gives `10`, `007` gives `008`).
String _increment(String number) =>
    '${int.parse(number) + 1}'.padLeft(number.length, '0');
