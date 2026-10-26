import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// The kind of one painted live preview decoration (WI #165, Spec R4).
enum DecorationKind {
  /// The box around a fenced code block.
  codeBox,

  /// The band behind a run of quote lines (or a quote row).
  quoteBand,

  /// The pill behind an inline code span's content.
  codePill,

  /// The painted horizontal rule on a rule line.
  rule,
}

/// One decoration the painter draws: a [rect] filled with [fill], rounded
/// by [radius], with a 1 px [border] drawn inside the rect when non-null.
///
/// The rect is in the measuring [LineBoxSource]'s coordinates.
@immutable
class PaintedDecoration {
  const PaintedDecoration({
    required this.kind,
    required this.rect,
    required this.fill,
    this.radius = 0,
    this.border,
  });

  final DecorationKind kind;
  final Rect rect;
  final Color fill;
  final double radius;
  final Color? border;

  @override
  String toString() =>
      'PaintedDecoration($kind, $rect, fill $fill, radius $radius, '
      'border $border)';
}

/// The code box's corner radius (pack #165).
const double _boxRadius = 4;

/// How far a revealed code box reaches above its first and below its last
/// fence line: the hidden fence line's padding (packs #161, #165).
const double _boxRevealOutset = 8;

/// The code pill's corner radius (pack #165).
const double _pillRadius = 3;

/// The code pill's height (pack #165).
const double _pillHeight = 17;

/// How far below its line box's top the code pill starts (pack #165).
const double _pillTop = 2;

/// The code pill's horizontal padding at the span's outer ends (pack #165).
const double _pillPad = 3;

/// The painted rule's thickness (pack #165).
const double _ruleHeight = 1;

/// How far below the rule line's top the painted rule sits (pack #165).
const double _ruleTop = 11;

/// The top of the highest and the bottom of the lowest of [rects], or null
/// when there are none.
(double, double)? _verticalExtent(List<Rect> rects) {
  if (rects.isEmpty) return null;
  var top = rects.first.top;
  var bottom = rects.first.bottom;
  for (final r in rects) {
    top = math.min(top, r.top);
    bottom = math.max(bottom, r.bottom);
  }
  return (top, bottom);
}

/// The code box of the fenced block [block] (from its opening fence line's
/// start to its last line's content end): the full text column
/// ([columnLeft]..[columnRight]) from the top of the first line box [block]
/// touches to the bottom of the last, every wrapped visual line included.
/// While [revealed] (caret inside the block), outset 8 px above and below.
/// Null for an empty range.
Rect? codeBoxRect(
  LineBoxSource boxes,
  TextRange block, {
  required double columnLeft,
  required double columnRight,
  bool revealed = false,
}) {
  final extent = _verticalExtent(boxes.boxesFor(block));
  if (extent == null) return null;
  final outset = revealed ? _boxRevealOutset : 0.0;
  return Rect.fromLTRB(
    columnLeft,
    extent.$1 - outset,
    columnRight,
    extent.$2 + outset,
  );
}

/// The quote band behind [range] (one quote line, or a run of consecutive
/// quote lines): one rect across the text column ([columnLeft]..
/// [columnRight]) from the top of the first line box [range] touches to the
/// bottom of the last, so consecutive lines and wrapped visual lines form
/// one band with no gap. Null for an empty range.
Rect? quoteBandRect(
  LineBoxSource boxes,
  TextRange range, {
  required double columnLeft,
  required double columnRight,
}) {
  final extent = _verticalExtent(boxes.boxesFor(range));
  if (extent == null) return null;
  return Rect.fromLTRB(columnLeft, extent.$1, columnRight, extent.$2);
}

/// The pill behind the code span content [content]: one rect per visual
/// line it touches, the content's x extent widened by 3 px at the span's
/// outer ends only (left of its first part, right of its last), 17 px tall
/// from its line box's top + 2. A pill that would start left of
/// [columnLeft] (a code span at a line's start) gets no left widening;
/// no pill starts left of [columnLeft]. Empty for an empty range.
List<Rect> codePillRects(
  LineBoxSource boxes,
  TextRange content, {
  required double columnLeft,
}) {
  final parts = boxes.boxesFor(content);
  return [
    for (var i = 0; i < parts.length; i++)
      Rect.fromLTRB(
        math.max(columnLeft, _pillLeft(parts[i].left, i == 0, columnLeft)),
        parts[i].top + _pillTop,
        i == parts.length - 1 ? parts[i].right + _pillPad : parts[i].right,
        parts[i].top + _pillTop + _pillHeight,
      ),
  ];
}

/// A pill part's left edge from its content's [left]: padded on the span's
/// [first] part, unless the padding would cross [columnLeft].
double _pillLeft(double left, bool first, double columnLeft) {
  if (!first || left - _pillPad < columnLeft) return left;
  return left - _pillPad;
}

/// The painted rule of the rule line [line]: 1 px tall, 11 px below the
/// line box's top, across the text column ([columnLeft]..[columnRight]).
/// Null for an empty range.
Rect? ruleRect(
  LineBoxSource boxes,
  TextRange line, {
  required double columnLeft,
  required double columnRight,
}) {
  final extent = _verticalExtent(boxes.boxesFor(line));
  if (extent == null) return null;
  final top = extent.$1 + _ruleTop;
  return Rect.fromLTRB(columnLeft, top, columnRight, top + _ruleHeight);
}

/// Whether [selection] touches [range], both ends included: a caret at the
/// block's start or at its last line's end touches it, a caret at the end
/// of the line before or at the start of the line after does not.
bool _touches(TextSelection? selection, TextRange range) =>
    selection != null &&
    selection.start <= range.end &&
    selection.end >= range.start;

/// Every decoration of a field showing [text] measured by [boxes], in
/// paint order (backgrounds first: code boxes and quote bands, then pills,
/// then rules), all inside the text column [columnLeft]..[columnRight]
/// (in [boxes]' coordinates).
///
/// Line kinds come from `classifyLines` (with [atSegmentStart]); code spans
/// from `tokenizeInline` (never inside a fence). [quote]: the field is one
/// quote row's text, so all of it is banded. [reveal]: the field's
/// selection while its segment has focus (null otherwise); a fenced block
/// it touches is revealed. Quote bands fill with [quoteBandColor].
List<PaintedDecoration> layoutDecorations({
  required String text,
  required LineBoxSource boxes,
  required double columnLeft,
  required double columnRight,
  bool atSegmentStart = true,
  bool quote = false,
  TextSelection? reveal,
  Color quoteBandColor = OmColors.surface3,
}) {
  final backgrounds = <PaintedDecoration>[];
  final pills = <PaintedDecoration>[];
  final rules = <PaintedDecoration>[];

  void band(Rect? rect) {
    if (rect == null) return;
    backgrounds.add(
      PaintedDecoration(
        kind: DecorationKind.quoteBand,
        rect: rect,
        fill: quoteBandColor,
      ),
    );
  }

  // A quote row: every line of the field, an empty one included.
  if (quote) {
    final all = boxes.lines;
    if (all.isNotEmpty) {
      band(
        Rect.fromLTRB(columnLeft, all.first.top, columnRight, all.last.bottom),
      );
    }
  }

  final lines = classifyLines(text, atSegmentStart: atSegmentStart);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    switch (line.kind) {
      case MdLineKind.fenceOpen:
        // The block runs to its closing fence line, or to the text's end.
        var last = i;
        while (last + 1 < lines.length &&
            lines[last].kind != MdLineKind.fenceClose &&
            (lines[last + 1].kind == MdLineKind.fenceInside ||
                lines[last + 1].kind == MdLineKind.fenceClose)) {
          last++;
        }
        final block = TextRange(start: line.start, end: lines[last].contentEnd);
        final rect = codeBoxRect(
          boxes,
          block,
          columnLeft: columnLeft,
          columnRight: columnRight,
          revealed: _touches(reveal, block),
        );
        if (rect != null) {
          backgrounds.add(
            PaintedDecoration(
              kind: DecorationKind.codeBox,
              rect: rect,
              fill: OmColors.surface1,
              radius: _boxRadius,
              border: OmColors.line1,
            ),
          );
        }
        i = last;
      case MdLineKind.quote:
        // Consecutive quote lines form one band.
        var last = i;
        while (last + 1 < lines.length &&
            lines[last + 1].kind == MdLineKind.quote) {
          last++;
        }
        if (!quote) {
          band(
            quoteBandRect(
              boxes,
              TextRange(start: line.start, end: lines[last].contentEnd),
              columnLeft: columnLeft,
              columnRight: columnRight,
            ),
          );
        }
        for (var q = i; q <= last; q++) {
          _addPills(text, lines[q], boxes, columnLeft, pills);
        }
        i = last;
      case MdLineKind.rule:
        final rect = ruleRect(
          boxes,
          TextRange(start: line.start, end: line.contentEnd),
          columnLeft: columnLeft,
          columnRight: columnRight,
        );
        if (rect != null) {
          rules.add(
            PaintedDecoration(
              kind: DecorationKind.rule,
              rect: rect,
              fill: OmColors.line2,
            ),
          );
        }
      case MdLineKind.frontmatter:
      case MdLineKind.fenceInside:
      case MdLineKind.fenceClose:
        break;
      case MdLineKind.blank:
      case MdLineKind.plain:
      case MdLineKind.heading:
      case MdLineKind.bullet:
      case MdLineKind.numbered:
      case MdLineKind.task:
        _addPills(text, line, boxes, columnLeft, pills);
    }
  }
  return [...backgrounds, ...pills, ...rules];
}

/// Adds the pills of every code span on [line] (a line outside fences and
/// frontmatter) to [pills].
void _addPills(
  String text,
  MdLine line,
  LineBoxSource boxes,
  double columnLeft,
  List<PaintedDecoration> pills,
) {
  final tokens = tokenizeInline(text.substring(line.start, line.contentEnd));
  for (final token in tokens) {
    if (token.kind != InlineTokenKind.codeSpan) continue;
    final content = TextRange(
      start: line.start + token.content.start,
      end: line.start + token.content.end,
    );
    for (final rect in codePillRects(boxes, content, columnLeft: columnLeft)) {
      pills.add(
        PaintedDecoration(
          kind: DecorationKind.codePill,
          rect: rect,
          fill: OmColors.surface4,
          radius: _pillRadius,
        ),
      );
    }
  }
}

/// Live preview's painted decorations around one field (D7): code box,
/// quote band, code pill and rule, drawn from [boxes] behind [child] and
/// never left of [textLeft]. The text column runs from [textLeft] to this
/// widget's right edge.
class LivePreviewDecorations extends SingleChildRenderObjectWidget {
  const LivePreviewDecorations({
    super.key,
    required this.controller,
    this.boxes,
    this.textLeft = 0,
    this.quoteBandColor = OmColors.surface3,
    required Widget super.child,
  });

  /// The decorated field's controller.
  final LivePreviewController controller;

  /// The field's line boxes once laid out (null before layout).
  final LineBoxSource? Function()? boxes;

  /// Where the field's text column starts, in this widget's coordinates.
  final double textLeft;

  /// The quote band's fill: `surface3` in a note body, `surface4` inside
  /// an excerpt card (L14).
  final Color quoteBandColor;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDecorations(
    controller: controller,
    boxes: boxes,
    textLeft: textLeft,
    quoteBandColor: quoteBandColor,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderDecorations)
      ..controller = controller
      ..boxes = boxes
      ..textLeft = textLeft
      ..quoteBandColor = quoteBandColor;
  }
}

/// Paints [layoutDecorations] of its controller's text behind its child,
/// repainting when the controller or its reveal gate changes.
class _RenderDecorations extends RenderProxyBox {
  _RenderDecorations({
    required LivePreviewController controller,
    required LineBoxSource? Function()? boxes,
    required double textLeft,
    required Color quoteBandColor,
  }) : _controller = controller,
       _boxes = boxes,
       _textLeft = textLeft,
       _quoteBandColor = quoteBandColor;

  LivePreviewController _controller;
  set controller(LivePreviewController value) {
    if (identical(value, _controller)) return;
    if (attached) _unlisten();
    _controller = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  LineBoxSource? Function()? _boxes;
  set boxes(LineBoxSource? Function()? value) {
    if (identical(value, _boxes)) return;
    _boxes = value;
    markNeedsPaint();
  }

  double _textLeft;
  set textLeft(double value) {
    if (value == _textLeft) return;
    _textLeft = value;
    markNeedsPaint();
  }

  Color _quoteBandColor;
  set quoteBandColor(Color value) {
    if (value == _quoteBandColor) return;
    _quoteBandColor = value;
    markNeedsPaint();
  }

  /// The reveal gate listened to: the controller's, which a host may swap.
  ValueListenable<bool>? _gate;

  void _listen() {
    _controller.addListener(_changed);
    _syncGate();
  }

  void _unlisten() {
    _controller.removeListener(_changed);
    _gate?.removeListener(markNeedsPaint);
    _gate = null;
  }

  void _syncGate() {
    final gate = _controller.revealGate;
    if (identical(gate, _gate)) return;
    _gate?.removeListener(markNeedsPaint);
    _gate = gate..addListener(markNeedsPaint);
  }

  void _changed() {
    _syncGate();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintDecorations(context.canvas, offset);
    super.paint(context, offset);
  }

  void _paintDecorations(Canvas canvas, Offset offset) {
    _syncGate();
    final source = _boxes?.call();
    if (source == null) return;
    final box = source.box;
    if (!box.attached || !box.hasSize) return;
    // The line boxes' origin in this render box's coordinates.
    final origin = MatrixUtils.transformPoint(
      box.getTransformTo(this),
      Offset.zero,
    );
    final controller = _controller;
    final decorations = layoutDecorations(
      text: controller.text,
      boxes: source,
      columnLeft: _textLeft - origin.dx,
      columnRight: size.width - origin.dx,
      atSegmentStart: controller.atSegmentStart,
      quote: controller.quote,
      reveal: controller.revealGate.value ? controller.selection : null,
      quoteBandColor: _quoteBandColor,
    );
    final shift = offset + origin;
    for (final d in decorations) {
      final rrect = RRect.fromRectAndRadius(
        d.rect.shift(shift),
        Radius.circular(d.radius),
      );
      canvas.drawRRect(rrect, Paint()..color = d.fill);
      if (d.border case final border?) {
        // 1 px inside the rect.
        canvas.drawRRect(
          rrect.deflate(0.5),
          Paint()
            ..color = border
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }
}
