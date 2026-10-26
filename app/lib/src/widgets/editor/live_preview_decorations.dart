import 'package:flutter/widgets.dart';

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
}) => throw UnimplementedError();

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
}) => throw UnimplementedError();

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
}) => throw UnimplementedError();

/// The painted rule of the rule line [line]: 1 px tall, 11 px below the
/// line box's top, across the text column ([columnLeft]..[columnRight]).
/// Null for an empty range.
Rect? ruleRect(
  LineBoxSource boxes,
  TextRange line, {
  required double columnLeft,
  required double columnRight,
}) => throw UnimplementedError();

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
}) => throw UnimplementedError();

/// Live preview's painted decorations around one field (D7): code box,
/// quote band, code pill and rule, drawn from [boxes] behind [child] and
/// never left of [textLeft]. The text column runs from [textLeft] to this
/// widget's right edge.
class LivePreviewDecorations extends StatelessWidget {
  const LivePreviewDecorations({
    super.key,
    required this.controller,
    this.boxes,
    this.textLeft = 0,
    this.quoteBandColor = OmColors.surface3,
    required this.child,
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

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
