// Shared test seam (#159, D5, TS6): find a text segment's [SegmentEditing]
// handle from its Key. Robots, journeys and widget tests read and drive text
// segments only through the handle, never through the field widgets inside
// them, so a segment can be one field or several editor rows.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';

/// Key of text segment [i] (`text-segment-<i>`).
Key textSegmentKey(int i) => Key('text-segment-$i');

/// The editor body field's Key (`editor-body`): the first text segment in
/// the segmented view, the whole body in Source mode.
const editorBodyKey = Key('editor-body');

bool _isHandle(Element e) => e is StatefulElement && e.state is SegmentEditing;

/// Every element whose State is a [SegmentEditing] handle.
final Finder segmentEditingElements = find.byElementPredicate(
  _isHandle,
  description: 'SegmentEditing handle',
);

/// The [SegmentEditing] handle at, under or (nearest) above [finder], or
/// null when there is none (e.g. the Source surface's body field).
SegmentEditing? maybeSegmentEditingOf(WidgetTester tester, Finder finder) {
  final below = find
      .descendant(of: finder, matching: segmentEditingElements, matchRoot: true)
      .evaluate();
  if (below.isNotEmpty) {
    return (below.first as StatefulElement).state as SegmentEditing;
  }
  final above = find
      .ancestor(of: finder, matching: segmentEditingElements)
      .evaluate();
  if (above.isNotEmpty) {
    return (above.first as StatefulElement).state as SegmentEditing;
  }
  return null;
}

/// The [SegmentEditing] handle at, under or (nearest) above [finder].
SegmentEditing segmentEditingOf(WidgetTester tester, Finder finder) {
  final handle = maybeSegmentEditingOf(tester, finder);
  if (handle == null) {
    throw TestFailure('No SegmentEditing handle at, under or above $finder');
  }
  return handle;
}

/// The handle of text segment [i] (Key `text-segment-<i>`).
SegmentEditing segmentEditingAt(WidgetTester tester, int i) =>
    segmentEditingOf(tester, find.byKey(textSegmentKey(i)));

/// The handle of the editor body field (Key `editor-body`, the first text
/// segment).
SegmentEditing editorBodySegment(WidgetTester tester) =>
    segmentEditingOf(tester, find.byKey(editorBodyKey));

/// Every text segment handle on screen, in tree (segment) order.
List<SegmentEditing> allSegmentEditings(WidgetTester tester) => [
  for (final e in segmentEditingElements.evaluate())
    (e as StatefulElement).state as SegmentEditing,
];

/// The text of the editor body (Key `editor-body`): the first text
/// segment's text through its handle in the segmented view, the Source
/// field's text in Source mode.
String editorBodyText(WidgetTester tester) {
  final body = find.byKey(editorBodyKey);
  final handle = maybeSegmentEditingOf(tester, body);
  if (handle != null) return handle.text;
  return renderedEditableTexts(tester, under: body).single;
}

/// Every element that renders editable text (one per field: the element
/// whose own render object is a [RenderEditable]), optionally only those
/// under [under].
Finder editableTextFields({Finder? under}) {
  final fields = find.byElementPredicate(
    (e) => e is RenderObjectElement && e.renderObject is RenderEditable,
    description: 'editable text field',
  );
  return under == null
      ? fields
      : find.descendant(of: under, matching: fields, matchRoot: true);
}

/// The plain text every editable field on screen (optionally only under
/// [under]) renders right now.
List<String> renderedEditableTexts(WidgetTester tester, {Finder? under}) => [
  for (final e in editableTextFields(under: under).evaluate())
    (e.renderObject! as RenderEditable).text?.toPlainText() ?? '',
];

/// The index of the editor row of [handle]'s segment holding segment
/// [offset]: the row whose range `[start, end)` holds it, or the last row at
/// the segment end (A1's rows, as the host derives them, #167). 0 while the
/// segment shows a single field.
int segmentRowHolding(SegmentEditing handle, int offset) {
  if (handle.rowCount == 1) return 0;
  final rows = splitRows(handle.text, atSegmentStart: true);
  for (var i = 0; i < rows.length; i++) {
    if (offset < rows[i].end) return i;
  }
  return rows.length - 1;
}

/// The editable fields under [finder] (a text segment's root or its
/// `editor-body`), in row order: one per editor row.
Finder segmentRowFields(Finder finder) =>
    find.descendant(of: finder, matching: find.byType(EditableText));

/// Focuses the field of the text segment at, under or above [finder] that
/// holds segment [offset] (default: the segment's end), then puts the caret
/// at [offset] through the segment's handle. Works whether the segment is one
/// field or several editor rows (#167).
Future<void> focusSegmentAt(
  WidgetTester tester,
  Finder finder, {
  int? offset,
}) async {
  final handle = segmentEditingOf(tester, finder);
  final at = offset ?? handle.text.length;
  final fields = segmentRowFields(finder);
  final count = fields.evaluate().length;
  if (count != handle.rowCount) {
    throw TestFailure(
      '$finder shows $count fields for ${handle.rowCount} editor rows',
    );
  }
  await tester.showKeyboard(fields.at(segmentRowHolding(handle, at)));
  await tester.pump();
  segmentEditingOf(tester, finder).select(TextSelection.collapsed(offset: at));
  await tester.pump();
}

/// Replaces the whole text of the text segment at, under or above [finder]
/// with [text] as the person typing would: focuses the field holding the
/// segment's end, then replaces the text through the segment's handle (caret
/// at its end). A field with no handle (the Source surface's body) gets
/// [WidgetTester.enterText].
Future<void> typeSegmentText(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  if (maybeSegmentEditingOf(tester, finder) == null) {
    await tester.enterText(finder, text);
    await tester.pump();
    return;
  }
  await focusSegmentAt(tester, finder);
  segmentEditingOf(tester, finder).replaceText(text);
  await tester.pump();
}
