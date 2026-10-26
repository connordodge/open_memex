import 'package:flutter/widgets.dart';

/// The editing handle of one text segment of the segmented editor (D5,
/// TD12), implemented by the State under Key `text-segment-<i>`.
///
/// Tests, robots and journeys read and drive a text segment only through
/// this handle, never through the field widgets inside it: the segment
/// shows editor rows (#167), one field per row. Frozen after #159: later
/// changes are additive and optional only.
///
/// Offsets are UTF-16 offsets into the segment's whole text ([text]).
abstract interface class SegmentEditing {
  /// The segment's whole markdown text.
  String get text;

  /// The segment's selection, in segment offsets.
  TextSelection get selection;

  /// The index of the editor row whose field has focus, null while no row
  /// of the segment has focus.
  int? get focusedRow;

  /// How many editor rows the segment shows.
  int get rowCount;

  /// The caret rect at segment [offset], in global coordinates. Its height
  /// is never zero.
  Rect rectForOffset(int offset);

  /// Moves the segment's selection to [selection] (segment offsets) without
  /// changing focus.
  void select(TextSelection selection);

  /// Replaces the segment's whole text with [text], caret at its end,
  /// without changing focus. When the text changed, reports the note's
  /// joined body once through the segmented body's `onContentChanged`.
  void replaceText(String text);
}
