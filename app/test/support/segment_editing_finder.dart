// Shared test seam (#159, D5, TS6): find a text segment's [SegmentEditing]
// handle from its Key. Robots, journeys and widget tests read and drive text
// segments only through the handle, never through the field widgets inside
// them, so a segment can be one field or several editor rows.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
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
