// WI #83 (Spec #61 F3): helpers for the find highlight paint tests. Owned by
// #83; every name carries the wi83 prefix.
//
// D20: fills are checked through recorded paint calls only, never pixels
// under glyphs. A recorded fill or border is normalised to the area it
// paints (outer rect, and the inner hole of a ring), so a 1 px inside
// border passes whether it is drawn as a stroked rrect deflated by 0.5 or as
// a drawDRRect. Expected rects come from the measured field's own line boxes
// (`RenderEditableLineBoxes` / `RenderParagraphLineBoxes`), never constants:
// x and width are the run's rect on its line, the box is 17 px (times the
// field's text scale) tall and centred on its line box (pack 83: 3 px below
// the top of a 22.95 px body line).
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_sources.dart';

// ------------------------------------------------------------------ colours

/// Pack 83 colours, derived from the warn token (not from the new tokens,
/// so a wrong token value fails here too).
final Color wi83OtherFill = OmColors.warn.withAlpha(0x33);
final Color wi83Line = OmColors.warn.withAlpha(0x80);
const Color wi83Current = OmColors.warn;

/// The design box height on a 22.95 px body line at text scale 1.
const double wi83BoxHeight = 17;

/// The corner radius of an other match's fill and of every border ring
/// (pack 83: all boxes radius 2).
const double wi83Radius = 2;

/// The corner radius of the current match's solid fill: the box's radius 2
/// grown by its 1 px outward spread.
const double wi83CurrentRadius = 3;

// ------------------------------------------------------------------ record

/// One recorded paint of a find colour: the area it covers ([outer], and
/// the hole [inner] of a ring), its colour, its corner radius, and its
/// index among all recorded draws.
class Wi83Op {
  Wi83Op({
    required this.index,
    required this.outer,
    required this.inner,
    required this.color,
    required this.radius,
  });

  final int index;
  final Rect outer;
  final Rect? inner;
  final Color color;
  final double radius;

  bool get isFill => inner == null;

  @override
  String toString() =>
      'Wi83Op(#$index ${isFill ? 'fill' : 'ring'} $outer'
      '${inner == null ? '' : ' hole $inner'} $color r$radius)';
}

/// Every draw [root] makes when painted at the origin (its children
/// included, repaint boundaries painted inline), in order, in [root]'s
/// coordinates. Each entry: (index, member, colour or null, op or null).
class Wi83Recording {
  Wi83Recording(this.ops, this.colors);

  /// Normalised fills and rings, in draw order.
  final List<Wi83Op> ops;

  /// The colour of every recorded draw call in order (null for a draw with
  /// no paint, e.g. drawParagraph), for stacking-order checks.
  final List<Color?> colors;

  /// Ops in any of the three find colours.
  List<Wi83Op> get find => [
    for (final op in ops)
      if (wi83IsFindColor(op.color)) op,
  ];
}

bool wi83SameColor(Color a, Color b) => a.toARGB32() == b.toARGB32();

bool wi83IsFindColor(Color c) =>
    wi83SameColor(c, wi83OtherFill) ||
    wi83SameColor(c, wi83Line) ||
    wi83SameColor(c, wi83Current);

Wi83Recording wi83Record(RenderObject root) {
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  root.paint(context, Offset.zero);
  context.dispose();
  final stack = <Offset>[];
  var shift = Offset.zero;
  final ops = <Wi83Op>[];
  final colors = <Color?>[];
  void add(Rect outer, Rect? inner, Paint paint, double radius) {
    final stroke = paint.style == PaintingStyle.stroke;
    final w = paint.strokeWidth;
    ops.add(
      Wi83Op(
        index: colors.length,
        outer: (stroke ? outer.inflate(w / 2) : outer).shift(shift),
        inner: stroke ? outer.deflate(w / 2).shift(shift) : inner?.shift(shift),
        color: paint.color,
        radius: radius,
      ),
    );
  }

  for (final call in canvas.invocations) {
    final i = call.invocation;
    final args = i.positionalArguments;
    switch (i.memberName) {
      case #save || #saveLayer:
        stack.add(shift);
        continue;
      case #restore:
        shift = stack.isEmpty ? Offset.zero : stack.removeLast();
        continue;
      case #translate:
        shift += Offset(
          (args[0] as num).toDouble(),
          (args[1] as num).toDouble(),
        );
        continue;
      case #transform:
        final m = Matrix4.fromFloat64List(args[0] as Float64List);
        shift += Offset(m.storage[12], m.storage[13]);
        continue;
      case #drawRect:
        final paint = args[1] as Paint;
        add(args[0] as Rect, null, paint, 0);
        colors.add(paint.color);
      case #drawRRect:
        final rrect = args[0] as RRect;
        final paint = args[1] as Paint;
        add(rrect.outerRect, null, paint, rrect.tlRadiusX);
        colors.add(paint.color);
      case #drawDRRect:
        final outer = args[0] as RRect;
        final inner = args[1] as RRect;
        final paint = args[2] as Paint;
        add(outer.outerRect, inner.outerRect, paint, outer.tlRadiusX);
        colors.add(paint.color);
      case #drawPath:
        final path = args[0] as Path;
        final paint = args[1] as Paint;
        add(path.getBounds(), null, paint, 0);
        colors.add(paint.color);
      case #drawParagraph:
        colors.add(null);
      default:
        if (i.memberName.toString().contains('draw')) colors.add(null);
        continue;
    }
  }
  return Wi83Recording(ops, colors);
}

// ------------------------------------------------------------------ expect

/// One expected find box: its rect in the highlight layer's coordinates and
/// its style.
typedef Wi83Box = ({Rect rect, FindPaintStyle style});

/// The design box on a line-box rect [line] (a `boxesFor` rect: the run's x
/// extent, its line box's full height) at text scale [scale].
Rect wi83BoxOn(Rect line, double scale) {
  final h = wi83BoxHeight * scale;
  return Rect.fromLTWH(line.left, line.center.dy - h / 2, line.width, h);
}

bool _near(Rect a, Rect b, double x, double y) =>
    (a.left - b.left).abs() <= x &&
    (a.right - b.right).abs() <= x &&
    (a.top - b.top).abs() <= y &&
    (a.bottom - b.bottom).abs() <= y;

/// Expects [ops] (find colours only) to paint exactly [boxes]:
/// - other: a findMatch fill on the rect and a findMatchLine ring from the
///   rect to 1 px inside it;
/// - current: warn fill covering the rect, every warn op inside the rect
///   grown by 1 px, and their union exactly that grown rect;
/// - outline: a findMatchLine ring as other's, and no fill on the rect.
/// And no other find fill or ring than these. [x] and [y] are tolerances.
void wi83ExpectBoxes(
  List<Wi83Op> ops,
  List<Wi83Box> boxes, {
  double x = 0.05,
  double y = 0.3,
  String reason = '',
}) {
  final find = [
    for (final op in ops)
      if (wi83IsFindColor(op.color)) op,
  ];
  final used = <Wi83Op>{};
  for (final box in boxes) {
    final r = box.rect;
    switch (box.style) {
      case FindPaintStyle.other || FindPaintStyle.outline:
        final ring = find.where(
          (op) =>
              !used.contains(op) &&
              !op.isFill &&
              wi83SameColor(op.color, wi83Line) &&
              _near(op.outer, r, x, y) &&
              _near(op.inner!, r.deflate(1), x, y),
        );
        expect(
          ring,
          isNotEmpty,
          reason:
              '$reason: a 1 px inside findMatchLine border on $r '
              '(${box.style.name}); find ops: $find',
        );
        expect(
          ring.first.radius,
          moreOrLessEquals(wi83Radius),
          reason: '$reason: the border ring on $r has radius 2',
        );
        used.add(ring.first);
        final fills = find.where(
          (op) =>
              !used.contains(op) &&
              op.isFill &&
              wi83SameColor(op.color, wi83OtherFill) &&
              _near(op.outer, r, x, y),
        );
        if (box.style == FindPaintStyle.other) {
          expect(
            fills,
            isNotEmpty,
            reason: '$reason: a findMatch fill on $r; find ops: $find',
          );
          expect(
            fills.first.radius,
            moreOrLessEquals(wi83Radius),
            reason: '$reason: the fill on $r has radius 2',
          );
          used.add(fills.first);
        } else {
          expect(
            fills,
            isEmpty,
            reason: '$reason: an outline has no fill on $r; find ops: $find',
          );
        }
      case FindPaintStyle.current:
        final grown = r.inflate(1);
        final warn = find
            .where(
              (op) =>
                  !used.contains(op) &&
                  wi83SameColor(op.color, wi83Current) &&
                  op.outer.overlaps(r),
            )
            .toList();
        final solid = warn.where(
          (op) => op.isFill && _containsNear(op.outer, r, x, y),
        );
        expect(
          solid,
          isNotEmpty,
          reason: '$reason: a solid warn fill covering $r; find ops: $find',
        );
        expect(
          solid.first.radius,
          moreOrLessEquals(wi83CurrentRadius),
          reason: '$reason: the current box on $r has radius 2 plus its spread',
        );
        final union = warn
            .map((op) => op.outer)
            .fold<Rect?>(null, (a, b) => a?.expandToInclude(b) ?? b);
        expect(
          union != null && _near(union, grown, x, y),
          isTrue,
          reason:
              '$reason: the current box with its 1 px outward spread covers '
              '$grown exactly; got $union; find ops: $find',
        );
        used.addAll(warn);
    }
  }
  final extra = [
    for (final op in find)
      if (!used.contains(op)) op,
  ];
  expect(extra, isEmpty, reason: '$reason: no other find paint');
}

bool _containsNear(Rect outer, Rect r, double x, double y) =>
    outer.left <= r.left + x &&
    outer.right >= r.right - x &&
    outer.top <= r.top + y &&
    outer.bottom >= r.bottom - y;

// ------------------------------------------------------------------ geometry

/// The layer render box under [key] (a [FindHighlights] mount).
RenderBox wi83Layer(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  if (finder.evaluate().isEmpty) {
    throw TestFailure('no find highlights layer with Key $key is mounted');
  }
  final element = finder.evaluate().single;
  final object = element.renderObject;
  if (object is! RenderBox) {
    throw TestFailure('Key $key holds no render box');
  }
  return object;
}

/// The find ops the layer under [key] paints, in its coordinates.
List<Wi83Op> wi83LayerOps(WidgetTester tester, Key key) =>
    wi83Record(wi83Layer(tester, key)).find;

/// [range] (offsets of [source]'s text) as design boxes of [style] in
/// [layer]'s coordinates, one per line it touches; zero-width runs skipped.
List<Wi83Box> wi83BoxesOf(
  LineBoxSource source,
  TextRange range,
  FindPaintStyle style,
  RenderBox layer, {
  required double scale,
}) {
  final toLayer = source.box.getTransformTo(layer);
  return [
    for (final r in source.boxesFor(range))
      if (r.width > 0)
        (
          rect: wi83BoxOn(MatrixUtils.transformRect(toLayer, r), scale),
          style: style,
        ),
  ];
}

/// The text scale a laid-out editable or paragraph lays out at.
double wi83ScaleOf(RenderBox box) => switch (box) {
  RenderEditable e => e.textScaler.scale(1),
  RenderParagraph p => p.textScaler.scale(1),
  _ => 1,
};

// ------------------------------------------------------------------ state

/// A body source for segment [segment] of [text] (its hidden ranges from
/// F1's `livePreviewHiddenRanges`, or [hidden]).
FindSource wi83Body(int segment, String text, {List<FindRange>? hidden}) =>
    FindSource(
      segment: segment,
      kind: FindSourceKind.body,
      text: text,
      hidden: hidden ?? livePreviewHiddenRanges(text),
    );

/// Opens find in [container] on [sources] with [query] through F1's public
/// commands, then steps until the current match index is [current].
void wi83Open(
  ProviderContainer container,
  List<FindSource> sources,
  String query, {
  int current = 0,
}) {
  final n = container.read(findInNoteProvider.notifier);
  n.setSources(sources);
  n.useSelection(query);
  final total = container.read(findInNoteProvider).matches.length;
  for (var i = 0; i < total; i++) {
    if (container.read(findInNoteProvider).current == current) break;
    n.next();
  }
  final s = container.read(findInNoteProvider);
  if (s.query != query || s.current != current) {
    throw TestFailure(
      'fixture: could not open "$query" at match $current: $s '
      '(${s.matches})',
    );
  }
}

/// The [n]th (0-based) occurrence of [word] in [text].
TextRange wi83Find(String text, String word, [int n = 0]) {
  var at = -1;
  for (var i = 0; i <= n; i++) {
    at = text.indexOf(word, at + 1);
    if (at < 0) throw TestFailure('fixture: no "$word" #$n in "$text"');
  }
  return TextRange(start: at, end: at + word.length);
}
