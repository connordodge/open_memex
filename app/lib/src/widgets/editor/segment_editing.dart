import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart' show SegmentEdit;

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

  /// Applies [edit] (segment offsets) to the segment's text as one edit
  /// (frozen, WI #124 ruling D12): the rows re-derive, the segment's undo
  /// recorder records it once, and the note's joined body is reported once
  /// through the segmented body's `onContentChanged`. [SegmentEdit.selection]
  /// becomes the segment's selection; without one the selection is kept,
  /// clamped to the new text. Focus does not change.
  void applyEdit(SegmentEdit edit);

  /// The segment offset under global [position] (frozen, WI #124 ruling
  /// D12): the offset nearest to it in the segment's line boxes, as a press
  /// there resolves it. Null while the segment has no line boxes (before its
  /// rows are laid out).
  int? offsetAtGlobal(Offset position);
}
