import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart' show RowKind, splitRows;
import '../../state/note_reveal.dart';
import 'card_rows.dart';
import 'echo_arrival_highlight.dart';
import 'line_boxes.dart';
import 'paragraph_line_boxes.dart';
import 'segmented_body.dart';
import 'table_grid.dart';

// The editor side of the note reveal seam (#66, D1, D3): row lookup, anchor
// maths and the placements for `NoteEditor._reveal`.

/// The anchor a Text reveal lands on, in [row]'s local coordinates (D3c,
/// D3h): for a prose row, the line boxes holding `[arrival.local, end)` at
/// their real `line.top` (only the line holding `arrival.local` when [end]
/// is null); [end] is a row-local UTF-16 offset into `arrival.rowText`,
/// exclusive. Any other row, or a card, anchors on the whole row.
///
/// With [element], the element [row] belongs to (#61 F6, D2):
/// - a table row with [end] anchors on its grid's line boxes holding
///   `[arrival.local, end)`;
/// - a card with [cardStart] anchors on the card row lines holding
///   `[cardStart, cardEnd)`, UTF-16 offsets into its text
///   (`RenderedExcerpt.text`), [cardEnd] exclusive.
/// Either falls back to the whole row until those lines are laid out.
Rect revealAnchorRect(
  RenderBox row,
  EchoArrival arrival, {
  int? end,
  Element? element,
  int? cardStart,
  int? cardEnd,
}) {
  final whole = Offset.zero & row.size;
  if (element != null) {
    final Rect? inner = switch (arrival.kind) {
      RowKind.table when end != null => _tableAnchor(
        row,
        element,
        arrival,
        end,
      ),
      null when cardStart != null => _cardAnchor(
        row,
        element,
        cardStart,
        cardEnd,
      ),
      _ => null,
    };
    if (inner != null) return inner;
  }
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

/// The rows of [source] holding `[start, end)` (end exclusive; only the line
/// holding [start] when the range is empty), spanning [row]'s width, in
/// [row]'s local coordinates; null when [source] has no such boxes.
Rect? _rangeAnchor(RenderBox row, LineBoxSource source, int start, int? end) {
  final box = source.box;
  if (!box.attached || !box.hasSize) return null;
  final to = end == null ? start : math.max(start, end);
  final rects = to > start
      ? source.boxesFor(TextRange(start: start, end: to))
      : [source.caretRect(start)];
  if (rects.isEmpty) return null;
  final transform = box.getTransformTo(row);
  var top = double.infinity;
  var bottom = double.negativeInfinity;
  for (final rect in rects) {
    final r = MatrixUtils.transformRect(transform, rect);
    top = math.min(top, r.top);
    bottom = math.max(bottom, r.bottom);
  }
  return Rect.fromLTRB(0, top, row.size.width, math.max(top, bottom));
}

/// A table row's anchor: its grid's line boxes holding `[arrival.local,
/// end)`, or its field's lines while the row is revealed; null until laid
/// out.
Rect? _tableAnchor(
  RenderBox row,
  Element element,
  EchoArrival arrival,
  int end,
) {
  final grid = _stateUnder<TableGridState>(element);
  if (grid != null) {
    final source = grid.lineBoxes();
    return source == null
        ? null
        : _rangeAnchor(row, source, arrival.local, end);
  }
  final editable = findRenderEditable(row);
  if (editable == null ||
      !editable.hasSize ||
      editable.plainText != arrival.rowText) {
    return null;
  }
  return _rangeAnchor(
    row,
    RenderEditableLineBoxes(editable),
    arrival.local,
    end,
  );
}

/// A card's anchor: the lines of the card row holding [start] (a card text
/// offset) through [end], clipped to that row; null until its rows are laid
/// out.
Rect? _cardAnchor(RenderBox row, Element element, int start, int? end) {
  CardRows? rows;
  Element? rowsElement;
  void findRows(Element e) {
    if (rowsElement != null) return;
    if (e.widget case final CardRows w) {
      rows = w;
      rowsElement = e;
    } else {
      e.visitChildren(findRows);
    }
  }

  findRows(element);
  final cardRows = rows;
  final host = rowsElement;
  if (cardRows == null || host == null) return null;
  final specs = splitRows(cardRows.text, atSegmentStart: true);
  final r = specs.lastIndexWhere((spec) => spec.start <= start);
  if (r < 0) return null;
  final spec = specs[r];
  final length = spec.textEnd - spec.textStart;
  final local = (start - spec.textStart).clamp(0, length);
  final to = end == null ? null : (end - spec.textStart).clamp(local, length);
  final textKey = ValueKey('card-row-text-$r');
  final tableKey = ValueKey('card-table-$r');
  LineBoxSource? source;
  void findRow(Element e) {
    if (source != null) return;
    final key = e.widget.key;
    if (key == tableKey && e is StatefulElement) {
      if (e.state case final TableGridState grid) source = grid.lineBoxes();
      return;
    }
    if (key == textKey) {
      if (_paragraphUnder(e.renderObject) case final paragraph?) {
        source = RenderParagraphLineBoxes(paragraph);
      }
      return;
    }
    e.visitChildren(findRow);
  }

  findRow(host);
  final found = source;
  return found == null ? null : _rangeAnchor(row, found, local, to);
}

/// The state of type [T] at or under [root] (depth first), or null.
T? _stateUnder<T extends State>(Element root) {
  T? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is T) {
      found = e.state as T;
    } else {
      e.visitChildren(visit);
    }
  }

  visit(root);
  return found;
}

/// The first laid-out [RenderParagraph] at or under [root], or null.
RenderParagraph? _paragraphUnder(RenderObject? root) {
  RenderParagraph? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderParagraph) {
      if (node.hasSize) found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  return found;
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
({RenderBox row, RenderBox? column, Element element})? revealRow(
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

  final rowKey = laidOut(arrival.key) != null
      ? arrival.key
      : arrival.fallbackKey;
  final row = laidOut(rowKey);
  if (row == null) return null;
  return (
    row: row,
    column: laidOut(ValueKey('text-segment-${arrival.segment}')),
    element: found[rowKey]!,
  );
}
