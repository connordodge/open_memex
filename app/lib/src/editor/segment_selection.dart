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
  throw UnimplementedError();
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
  throw UnimplementedError();
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
  throw UnimplementedError();
}

/// [selection] with both ends clamped into `0..text.length` (Spec R28),
/// keeping its direction (which end is the base and which the extent).
/// No end falls inside a surrogate pair.
SegmentSelection clampToSegment(SegmentSelection selection, String text) {
  throw UnimplementedError();
}

/// One character step right from [offset] (Spec R23, R26).
///
/// Inside a row's text, moves past the next character, never into a
/// surrogate pair or between `\r` and `\n`. From a row's text end, lands at
/// the next row's text start (its marker isn't selectable text). At the last
/// row's text end, returns [offset].
int nextCharacterOffset(String text, List<RowSpec> rows, int offset) {
  throw UnimplementedError();
}

/// One character step left from [offset] (Spec R23, R26).
///
/// Inside a row's text, moves before the previous character, never into a
/// surrogate pair or between `\r` and `\n`. From a row's text start, lands at
/// the previous row's text end. At the first row's text start, returns
/// [offset].
int previousCharacterOffset(String text, List<RowSpec> rows, int offset) {
  throw UnimplementedError();
}

/// One word step right from [offset] (Spec R23 Option+Right, R26).
///
/// Inside a row's text, moves to the end of the next word of the row text
/// (`foo bar`: from 0 to 3, then to 7), never past the row's text end. From
/// a row's text end, lands at the next row's text start. At the last row's
/// text end, returns [offset].
int nextWordOffset(String text, List<RowSpec> rows, int offset) {
  throw UnimplementedError();
}

/// One word step left from [offset] (Spec R23 Option+Left, R26).
///
/// Inside a row's text, moves to the start of the previous word of the row
/// text (`foo bar`: from 7 to 4, then to 0), never before the row's text
/// start. From a row's text start, lands at the previous row's text end. At
/// the first row's text start, returns [offset].
int previousWordOffset(String text, List<RowSpec> rows, int offset) {
  throw UnimplementedError();
}
