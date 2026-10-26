// Pure-Dart selection math over one text segment's text and editor rows
// (Spec #157 R23, R26, R27, R28, WI #163).
//
// No Flutter imports (ruling D2): selections are [SegmentSelection]s in
// segment offsets (UTF-16 code units), and every edit is a [SegmentEdit].
// No result offset falls inside a surrogate pair (D4). Copied text is the
// exact raw markdown of the range (D17).

import 'editor_rows.dart';

/// The raw markdown of [selection]'s range in [text], markers, indentation
/// and the terminators between rows included (Spec R27):
/// always `text.substring(selection.start, selection.end)` (D17).
String copyText(String text, SegmentSelection selection) {
  return text.substring(selection.start, selection.end);
}

/// The edit that deletes [selection]'s range from [text] (Spec R27
/// Backspace, Delete and Cut): plain removal of
/// `[selection.start, selection.end)`, markers included, with the caret
/// collapsed at the range start. The host re-derives [rows] from the result.
/// A collapsed selection gives a no-op edit with the caret where it was.
SegmentEdit deleteRange(
  String text,
  List<RowSpec> rows,
  SegmentSelection selection,
) {
  return SegmentEdit(
    start: selection.start,
    end: selection.end,
    replacement: '',
    selection: SegmentSelection.collapsed(selection.start),
  );
}

/// The edit that replaces [selection]'s range in [text] with [inserted]
/// (Spec R27 type-over and paste), with the caret collapsed after the last
/// code unit of [inserted].
SegmentEdit replaceRange(
  String text,
  List<RowSpec> rows,
  SegmentSelection selection,
  String inserted,
) {
  return SegmentEdit(
    start: selection.start,
    end: selection.end,
    replacement: inserted,
    selection: SegmentSelection.collapsed(selection.start + inserted.length),
  );
}

/// [selection] with both ends clamped into `0..text.length` (Spec R28),
/// keeping its direction (which end is the base and which the extent).
/// No end falls inside a surrogate pair.
SegmentSelection clampToSegment(SegmentSelection selection, String text) {
  return SegmentSelection(
    baseOffset: _clampOffset(selection.baseOffset, text),
    extentOffset: _clampOffset(selection.extentOffset, text),
  );
}

/// One character step right from [offset] (Spec R23, R26).
///
/// Inside a row's text, moves past the next character, never into a
/// surrogate pair or between `\r` and `\n`. From a row's text end, lands at
/// the next row's text start (its marker isn't selectable text). At the last
/// row's text end, returns [offset].
int nextCharacterOffset(String text, List<RowSpec> rows, int offset) {
  final i = _rowIndex(rows, offset);
  if (i < 0) return offset;
  final row = rows[i];
  if (offset < row.textStart) return row.textStart;
  if (offset >= row.textEnd) {
    return i + 1 < rows.length ? rows[i + 1].textStart : offset;
  }
  return offset + _unitsAfter(text, offset);
}

/// One character step left from [offset] (Spec R23, R26).
///
/// Inside a row's text, moves before the previous character, never into a
/// surrogate pair or between `\r` and `\n`. From a row's text start, lands at
/// the previous row's text end. At the first row's text start, returns
/// [offset].
int previousCharacterOffset(String text, List<RowSpec> rows, int offset) {
  final i = _rowIndex(rows, offset);
  if (i < 0) return offset;
  final row = rows[i];
  if (offset > row.textEnd) return row.textEnd;
  if (offset <= row.textStart) return i > 0 ? rows[i - 1].textEnd : offset;
  return offset - _unitsBefore(text, offset);
}

/// One word step right from [offset] (Spec R23 Option+Right, R26).
///
/// Inside a row's text, moves to the end of the next word of the row text
/// (`foo bar`: from 0 to 3, then to 7), never past the row's text end. From
/// a row's text end, lands at the next row's text start. At the last row's
/// text end, returns [offset].
int nextWordOffset(String text, List<RowSpec> rows, int offset) {
  final i = _rowIndex(rows, offset);
  if (i < 0) return offset;
  final row = rows[i];
  if (offset < row.textStart) return row.textStart;
  if (offset >= row.textEnd) {
    return i + 1 < rows.length ? rows[i + 1].textStart : offset;
  }
  var o = offset;
  while (o < row.textEnd && _isSpace(text.codeUnitAt(o))) {
    o++;
  }
  while (o < row.textEnd && !_isSpace(text.codeUnitAt(o))) {
    o++;
  }
  return o;
}

/// One word step left from [offset] (Spec R23 Option+Left, R26).
///
/// Inside a row's text, moves to the start of the previous word of the row
/// text (`foo bar`: from 7 to 4, then to 0), never before the row's text
/// start. From a row's text start, lands at the previous row's text end. At
/// the first row's text start, returns [offset].
int previousWordOffset(String text, List<RowSpec> rows, int offset) {
  final i = _rowIndex(rows, offset);
  if (i < 0) return offset;
  final row = rows[i];
  if (offset > row.textEnd) return row.textEnd;
  if (offset <= row.textStart) return i > 0 ? rows[i - 1].textEnd : offset;
  var o = offset;
  while (o > row.textStart && _isSpace(text.codeUnitAt(o - 1))) {
    o--;
  }
  while (o > row.textStart && !_isSpace(text.codeUnitAt(o - 1))) {
    o--;
  }
  return o;
}

/// Index of the row whose text `[textStart, textEnd]` holds [offset], or of
/// the first row after it when [offset] is in a marker or a terminator: the
/// first row with `offset <= textEnd`, else the last row. -1 for no rows.
int _rowIndex(List<RowSpec> rows, int offset) {
  for (var i = 0; i < rows.length; i++) {
    if (offset <= rows[i].textEnd) return i;
  }
  return rows.length - 1;
}

/// [offset] clamped into `0..text.length` and moved to the start of a
/// surrogate pair it would split.
int _clampOffset(int offset, String text) {
  final o = offset.clamp(0, text.length);
  return _isPairAt(text, o - 1) ? o - 1 : o;
}

/// Code units of the character starting at [offset]: 2 for a surrogate pair
/// or a CRLF, else 1.
int _unitsAfter(String text, int offset) =>
    _isPairAt(text, offset) || _isCrlfAt(text, offset) ? 2 : 1;

/// Code units of the character ending at [offset]: 2 for a surrogate pair or
/// a CRLF, else 1.
int _unitsBefore(String text, int offset) =>
    _isPairAt(text, offset - 2) || _isCrlfAt(text, offset - 2) ? 2 : 1;

/// Whether a surrogate pair starts at [i].
bool _isPairAt(String text, int i) =>
    i >= 0 &&
    i + 1 < text.length &&
    _isHighSurrogate(text.codeUnitAt(i)) &&
    _isLowSurrogate(text.codeUnitAt(i + 1));

/// Whether a CRLF starts at [i].
bool _isCrlfAt(String text, int i) =>
    i >= 0 &&
    i + 1 < text.length &&
    text.codeUnitAt(i) == 0x0D &&
    text.codeUnitAt(i + 1) == 0x0A;

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Whether [unit] separates words: a space, a tab or a line terminator.
bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
