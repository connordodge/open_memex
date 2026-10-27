// Pure-Dart list indent and outdent (Spec #193 R2-R27, WI #194).
//
// No Flutter imports (ruling D2 of #157). Live preview calls these with one
// segment's text and selection; Source mode with the whole body and its
// selection. Structure comes from `splitRows(text, atSegmentStart: true)`.

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
  throw UnimplementedError('indentListItems (WI #194)');
}

/// Whether [selection] touches a list item (bullet, numbered or task) of
/// [text], by the same rule as [indentListItems].
bool touchesListItem(
  String text,
  SegmentSelection selection, {
  bool source = false,
}) {
  throw UnimplementedError('touchesListItem (WI #194)');
}
