// WI #83 (Spec #61 F3): the Find in note match highlights, painted as an
// overlay over a field's line boxes (TD2), and the mapping from F1's
// FindInNoteState to one field's paint ranges.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/find_in_note.dart';
import '../../state/find_in_note_state.dart';
import '../../theme/colors.dart';
import '../editor/line_boxes.dart';
import '../editor/paragraph_line_boxes.dart';

/// Test-only work counter: incremented once each time any find highlight
/// layer paints. Tests read deltas to prove a rebuild with unchanged ranges
/// does not repaint the layer.
@visibleForTesting
int debugFindHighlightPaints = 0;

/// How one [FindPaintRange] paints (Reqs 24-26, pack 83).
enum FindPaintStyle {
  /// Every match but the current one: `OmColors.findMatch` fill, a 1 px
  /// inside border in `OmColors.findMatchLine`, radius 2.
  other,

  /// The current match: a solid `OmColors.warn` fill, radius 2, plus a 1 px
  /// outward spread in the same colour.
  current,

  /// A hidden match's outline around the visible text that hides it: the
  /// other-match border only, no fill.
  outline,
}

/// A half-open field-local UTF-16 range `[start, end)` and its paint style.
@immutable
final class FindPaintRange {
  const FindPaintRange(this.start, this.end, this.style);

  /// First code unit, field-local.
  final int start;

  /// One past the last code unit, field-local.
  final int end;

  final FindPaintStyle style;

  @override
  bool operator ==(Object other) =>
      other is FindPaintRange &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'FindPaintRange($start, $end, ${style.name})';
}

/// The paint ranges of one field: the matches of [state] in source
/// ([segment], [kind]) that touch the field's `[start, end)` of that
/// source's text, clipped to the field and made field-local (minus
/// [start]). Nothing while the bar is closed or the query is empty
/// (Req 29).
///
/// - A visible match: [FindPaintStyle.current] when it is the current
///   match, else [FindPaintStyle.other], on its own range.
/// - A hidden non-current body match: [FindPaintStyle.outline] on its
///   `outline` range (nothing when it has none). Hidden matches sharing one
///   outline paint it once.
/// - A hidden current body match, where the field [reveals] (F4 reveals its
///   line): [FindPaintStyle.current] on its own range; a hidden non-current
///   match on that same source line then paints [FindPaintStyle.other] on
///   its own range (pack 83, B3.12).
/// - Where the field does not [reveals] (a table grid cell, D8): every
///   hidden match paints its outline, the current one too.
/// - [revealed]: the field-local ranges of the field's lines that render
///   their markup now (the caret or selection reveals them). Where the
///   field [reveals], a hidden match wholly inside one of them is visible
///   as rendered, so it paints as a visible match on its own range (lead
///   ruling Q1: hidden means hidden as rendered).
List<FindPaintRange> findPaintRanges(
  FindInNoteState state, {
  required int segment,
  required FindSourceKind kind,
  required int start,
  required int end,
  bool reveals = true,
  List<TextRange> revealed = const [],
}) {
  if (!state.open || state.query.isEmpty) return const [];
  final current = state.currentMatch;
  // The source line of a hidden current match, which F4 reveals.
  var lineStart = -1;
  var lineEnd = -1;
  if (reveals &&
      current != null &&
      current.hidden &&
      current.segment == segment &&
      current.kind == kind) {
    final text = _sourceText(state, segment, kind);
    if (text != null) {
      lineStart = current.start == 0
          ? 0
          : text.lastIndexOf('\n', current.start - 1) + 1;
      lineEnd = text.indexOf('\n', current.end);
      if (lineEnd < 0) lineEnd = text.length;
    }
  }
  bool shown(int i, FindMatch m) {
    if (!reveals) return false;
    if (i == state.current) return true;
    if (lineStart >= 0 && m.start >= lineStart && m.end <= lineEnd) {
      return true;
    }
    for (final line in revealed) {
      if (m.start - start >= line.start && m.end - start <= line.end) {
        return true;
      }
    }
    return false;
  }

  final out = <FindPaintRange>{};
  for (final (i, m) in state.matches.indexed) {
    if (m.segment != segment || m.kind != kind) continue;
    final int from;
    final int to;
    final FindPaintStyle style;
    if (!m.hidden || shown(i, m)) {
      (from, to) = (m.start, m.end);
      style = i == state.current
          ? FindPaintStyle.current
          : FindPaintStyle.other;
    } else if (m.outline case final outline?) {
      (from, to) = (outline.start, outline.end);
      style = FindPaintStyle.outline;
    } else {
      continue;
    }
    final a = math.max(from, start);
    final b = math.min(to, end);
    if (a < b) out.add(FindPaintRange(a - start, b - start, style));
  }
  return out.toList();
}

/// The text of source ([segment], [kind]) in [state], or null.
String? _sourceText(FindInNoteState state, int segment, FindSourceKind kind) {
  for (final source in state.sources) {
    if (source.segment == segment && source.kind == kind) return source.text;
  }
  return null;
}

/// The match highlights of one field (Reqs 24-26, 28; TD2; D14, D20): an
/// `IgnorePointer` leaf over the line boxes [boxes] reports, painting one
/// box per line box each of [ranges] touches, in this box's coordinates.
///
/// A box is the range's run on that line (its advance width) and 17 px
/// (scaled with the text) tall, centred on its line box: 3 px below the top
/// of a 22.95 px body line (pack 83). Paints no glyphs. Repaints when
/// [ranges] change (by value) or [repaint] notifies (the field's text or
/// reveal), never on an unrelated rebuild.
class FindHighlights extends LeafRenderObjectWidget {
  const FindHighlights({
    super.key,
    required this.ranges,
    required this.boxes,
    this.repaint,
  });

  /// Field-local ranges and styles, from [findPaintRanges].
  final List<FindPaintRange> ranges;

  /// The measured field's line boxes once laid out, else null.
  final LineBoxSource? Function() boxes;

  /// Notifies when the measured field's layout may have changed.
  final Listenable? repaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFindHighlights(ranges, boxes, repaint);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderFindHighlights).update(ranges, boxes, repaint);
}

/// The box height on a body line at text scale 1 (pack 83).
const double _boxHeight = 17;

/// Every box's corner radius (pack 83).
const Radius _radius = Radius.circular(2);

/// The current box's outward spread (pack 83: Sketch spread 1).
const double _spread = 1;

/// The other box's inside border width (pack 83).
const double _border = 1;

class _RenderFindHighlights extends RenderBox {
  _RenderFindHighlights(this._ranges, this._boxes, this._repaint);

  List<FindPaintRange> _ranges;
  LineBoxSource? Function() _boxes;
  Listenable? _repaint;

  /// The measured editable's scroll offset, listened to while painting.
  ViewportOffset? _scroll;

  void update(
    List<FindPaintRange> ranges,
    LineBoxSource? Function() boxes,
    Listenable? repaint,
  ) {
    _boxes = boxes;
    if (!identical(repaint, _repaint)) {
      if (attached) _repaint?.removeListener(markNeedsPaint);
      _repaint = repaint;
      if (attached) _repaint?.addListener(markNeedsPaint);
    }
    if (listEquals(ranges, _ranges)) return;
    _ranges = ranges;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint?.removeListener(markNeedsPaint);
    _scroll?.removeListener(markNeedsPaint);
    _scroll = null;
    super.detach();
  }

  /// Its own layer, so a repaint of the field beside it does not repaint
  /// the highlights.
  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  /// D14: the layer never takes a pointer.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    debugFindHighlightPaints++;
    if (_ranges.isEmpty) return;
    final source = _boxes();
    if (source == null) return;
    final field = source.box;
    if (!field.attached || !field.hasSize) return;
    final scale = switch (field) {
      RenderEditable e => _follow(e).textScaler.scale(1),
      RenderParagraph p => p.textScaler.scale(1),
      _ => 1.0,
    };
    final height = _boxHeight * scale;
    final toHere = field.getTransformTo(this);
    final canvas = context.canvas;
    for (final range in _ranges) {
      final rects = source.boxesFor(
        TextRange(start: range.start, end: range.end),
      );
      for (final rect in rects) {
        if (rect.width <= 0) continue;
        final line = MatrixUtils.transformRect(toHere, rect);
        final box = Rect.fromLTWH(
          line.left,
          line.center.dy - height / 2,
          line.width,
          height,
        ).shift(offset);
        _paintBox(canvas, box, range.style);
      }
    }
  }

  /// Repaints when [editable] scrolls its text.
  RenderEditable _follow(RenderEditable editable) {
    final scroll = editable.offset;
    if (!identical(scroll, _scroll)) {
      _scroll?.removeListener(markNeedsPaint);
      _scroll = scroll..addListener(markNeedsPaint);
    }
    return editable;
  }

  static void _paintBox(Canvas canvas, Rect box, FindPaintStyle style) {
    final rrect = RRect.fromRectAndRadius(box, _radius);
    switch (style) {
      case FindPaintStyle.current:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            box.inflate(_spread),
            _radius + const Radius.circular(_spread),
          ),
          Paint()..color = OmColors.warn,
        );
      case FindPaintStyle.other:
        canvas.drawRRect(rrect, Paint()..color = OmColors.findMatch);
        _paintBorder(canvas, rrect);
      case FindPaintStyle.outline:
        _paintBorder(canvas, rrect);
    }
  }

  /// The 1 px border inside [rrect].
  static void _paintBorder(Canvas canvas, RRect rrect) => canvas.drawDRRect(
    rrect,
    rrect.deflate(_border),
    Paint()..color = OmColors.findMatchLine,
  );
}

/// A [FindHighlights] (Key [layerKey]) under the `RichText` in [child], over
/// that paragraph's line boxes (card rows, table grid cells): the layer
/// fills the stack [child] sizes, and paints [ranges] of the current Find
/// in note state.
///
/// [child]'s first `RenderParagraph` (depth first) is the measured text.
/// The stack passes its constraints through, so [child] lays out as it
/// would alone.
class FindParagraphHighlights extends StatefulWidget {
  const FindParagraphHighlights({
    super.key,
    required this.layerKey,
    required this.ranges,
    required this.child,
  });

  /// The layer's Key (`find_keys.dart`).
  final Key layerKey;

  /// The field's ranges in [state] (usually [findPaintRanges]).
  final List<FindPaintRange> Function(FindInNoteState state) ranges;

  final Widget child;

  @override
  State<FindParagraphHighlights> createState() =>
      _FindParagraphHighlightsState();
}

class _FindParagraphHighlightsState extends State<FindParagraphHighlights> {
  final _textKey = GlobalKey(debugLabel: 'find-highlights-text');

  LineBoxSource? _boxes() {
    final paragraph = _firstParagraph(
      _textKey.currentContext?.findRenderObject(),
    );
    return paragraph != null && paragraph.hasSize
        ? RenderParagraphLineBoxes(paragraph)
        : null;
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      Positioned.fill(
        child: Consumer(
          builder: (context, ref, _) => FindHighlights(
            key: widget.layerKey,
            ranges: widget.ranges(ref.watch(findInNoteProvider)),
            boxes: _boxes,
          ),
        ),
      ),
      KeyedSubtree(key: _textKey, child: widget.child),
    ],
  );
}

/// The first [RenderParagraph] at or under [root] (depth first), or null.
RenderParagraph? _firstParagraph(RenderObject? root) {
  RenderParagraph? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderParagraph) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  return found;
}

/// What a body row's table grid cells need to mount their find highlights
/// (Keys `find-highlights-grid-<segment>-<row>-<cell>`): the text segment,
/// where the row's text starts in it, and whether the segment is active.
/// The segment's rows host puts one above each row; a grid without one (an
/// excerpt card's) mounts none.
class FindGridScope extends InheritedWidget {
  const FindGridScope({
    super.key,
    required this.segment,
    required this.textStart,
    required this.active,
    required super.child,
  });

  /// The text segment's index.
  final int segment;

  /// Where the row's field text starts in the segment text.
  final int textStart;

  /// Whether the segment belongs to the active editor.
  final bool active;

  static FindGridScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FindGridScope>();

  @override
  bool updateShouldNotify(FindGridScope oldWidget) =>
      segment != oldWidget.segment ||
      textStart != oldWidget.textStart ||
      active != oldWidget.active;
}
