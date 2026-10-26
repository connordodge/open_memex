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

/// Enter in item row [row] of [rows] (from `splitRows(text, ...)`), whose
/// text isn't empty, with the caret at segment offset [caret] (inside the
/// row's text) (Spec R15).
///
/// Splits the item at the caret: the new item below gets the same
/// indentation and marker and takes the text after the caret; the selection
/// after the edit is a caret at offset 0 of its text. Bullets repeat their
/// character, `N.` becomes `N+1.` (later items keep their numbers) and a
/// task continues as an unchecked `[ ] ` with the same bullet character.
/// Null when [row] is a prose or code row.
SegmentEdit? splitItem(String text, List<RowSpec> rows, int row, int caret) {
  throw UnimplementedError();
}

/// Enter in item row [row] whose text is empty (Spec R16): removes its
/// indentation and marker, leaving an empty plain line with the caret on
/// it. Every other line keeps its bytes. Null when the row has text or is a
/// prose or code row.
SegmentEdit? enterOnEmpty(String text, List<RowSpec> rows, int row) {
  throw UnimplementedError();
}

/// Shift+Enter in item row [row] with the caret at segment offset [caret]
/// (Spec R17): inserts a plain line below the item, with no marker, that
/// takes the text after the caret; the caret goes to its start. Null when
/// [row] is a prose or code row.
SegmentEdit? shiftEnter(String text, List<RowSpec> rows, int row, int caret) {
  throw UnimplementedError();
}

/// Backspace at offset 0 of item row [row]'s text (Spec R18): removes its
/// indentation and marker (a done task loses `[x]`), so the line becomes a
/// plain line with the same text, and the caret stays before the text. Null
/// when [row] is a prose or code row.
SegmentEdit? backspaceAtStart(String text, List<RowSpec> rows, int row) {
  throw UnimplementedError();
}

/// Backspace with the caret at segment offset [caret], the start of a plain
/// line in row [row] (Spec R19): joins that line onto the end of the line
/// above, whether the line above is prose or an item, by removing the
/// terminator between them; the caret goes to the join point. Null on the
/// segment's first line.
SegmentEdit? joinPrevious(String text, List<RowSpec> rows, int row, int caret) {
  throw UnimplementedError();
}

/// Forward Delete at the end of row [row]'s text (Spec R20): joins the next
/// line's text onto it. When the next line is an item, its indentation and
/// marker are dropped; any other line (a heading's `#` included) joins as
/// it is. The caret stays at the join point. Null at the segment end.
SegmentEdit? deleteForwardAtEnd(String text, List<RowSpec> rows, int row) {
  throw UnimplementedError();
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
/// a fence or frontmatter, and lines without a list prefix.
SegmentEdit? sourceEnter(
  String text,
  SegmentSelection selection, {
  bool shift = false,
}) {
  throw UnimplementedError();
}
