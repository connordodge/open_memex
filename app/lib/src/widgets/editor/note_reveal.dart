import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart' show RowKind;
import '../../state/note_reveal.dart';
import 'echo_arrival_highlight.dart';
import 'line_boxes.dart';
import 'segmented_body.dart';

// The editor side of the note reveal seam (#66, D1, D3): row lookup, anchor
// maths and the placements for `NoteEditor._reveal`.

/// The anchor a Text reveal lands on, in [row]'s local coordinates (D3c,
/// D3h): for a prose row, the line boxes holding `[arrival.local, end)` at
/// their real `line.top` (only the line holding `arrival.local` when [end]
/// is null); [end] is a row-local UTF-16 offset into `arrival.rowText`,
/// exclusive. Any other row, or a card, anchors on the whole row.
Rect revealAnchorRect(RenderBox row, EchoArrival arrival, {int? end}) {
  final whole = Offset.zero & row.size;
  if (arrival.kind != RowKind.prose) return whole;
  final editable = findRenderEditable(row);
  if (editable == null ||
      !editable.hasSize ||
      editable.plainText != arrival.rowText) {
    return whole;
  }
  final lines = RenderEditableLineBoxes(editable).lines;
  if (lines.isEmpty) return whole;
  final first = lineHolding(lines, arrival.local);
  final last = end == null || end <= arrival.local
      ? first
      : lineHolding(lines, end - 1);
  double y(double editableY) =>
      row.globalToLocal(editable.localToGlobal(Offset(0, editableY))).dy;
  final top = y(first.top);
  return Rect.fromLTRB(0, top, row.size.width, math.max(top, y(last.bottom)));
}

/// How far from an exact Within edge an anchor still counts as on it: line
/// tops come from float32 text layout and reach the viewport through
/// transforms.
const double _edge = 1e-6;

/// The scroll offset [placement] puts an anchor of [height] at, or null for
/// no scroll (D3d). [reveal] is the offset that puts the anchor's top at the
/// viewport top, [pixels] the current offset and [viewport] the viewport's
/// height. Unclamped.
/// - [RevealThird]: the anchor's centre a third of the way down, its top at
///   the viewport top when it is taller than two thirds of the viewport.
/// - [RevealTop]: the anchor's top `inset` below the viewport top, always.
/// - [RevealWithin]: null when the anchor already lies in [top + `topInset`,
///   bottom]; else the smallest scroll that brings it there; an anchor
///   taller than that band lands at top + `topInset`.
double? revealScrollOffset(
  RevealPlacement placement, {
  required double reveal,
  required double pixels,
  required double viewport,
  required double height,
}) {
  switch (placement) {
    case RevealThird():
      return math.min(reveal, reveal - (viewport / 3 - height / 2));
    case RevealTop(:final inset):
      return reveal - inset;
    case RevealWithin(:final topInset):
      if (height > viewport - topInset) return reveal - topInset;
      final top = reveal - pixels;
      if (top < topInset - _edge) return reveal - topInset;
      if (top + height > viewport + _edge) return reveal - (viewport - height);
      return null;
  }
}

/// The laid-out widget holding [arrival] in the segmented body under
/// [context] that shows note [noteId] with text [content], and its text
/// segment; null until then.
({RenderBox row, RenderBox? column})? revealRow(
  BuildContext context,
  String noteId,
  String content,
  EchoArrival arrival,
) {
  Element? body;
  void findBody(Element e) {
    if (body != null) return;
    final w = e.widget;
    if (w is SegmentedBody && w.note.id == noteId) {
      body = e;
    } else {
      e.visitChildren(findBody);
    }
  }

  context.visitChildElements(findBody);
  final host = body;
  if (host == null || (host.widget as SegmentedBody).content != content) {
    return null;
  }
  final keys = {
    arrival.key,
    ?arrival.fallbackKey,
    ValueKey('text-segment-${arrival.segment}'),
  };
  final found = <Key, Element>{};
  void visit(Element e) {
    final key = e.widget.key;
    if (key != null && keys.contains(key)) found.putIfAbsent(key, () => e);
    e.visitChildren(visit);
  }

  host.visitChildren(visit);
  RenderBox? laidOut(Key? key) {
    final box = key == null ? null : found[key]?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  final row = laidOut(arrival.key) ?? laidOut(arrival.fallbackKey);
  if (row == null) return null;
  return (
    row: row,
    column: laidOut(ValueKey('text-segment-${arrival.segment}')),
  );
}
