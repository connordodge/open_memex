import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';

/// The line-box seam (D6, TD10): the real geometry of a laid-out field's
/// text, measured from what the field renders (styled spans, hidden
/// markers, taller heading lines, its strut), never from a separately
/// styled `TextPainter`.
///
/// Every rect, point and line is in [box]'s local coordinates. Offsets are
/// UTF-16 offsets into the field's text. A line box spans its line's full
/// height: from the bottom of the line above (or the text's top) to the top
/// of the line below (or the text's bottom).
///
/// Consumers: the capture gutter, the autocomplete anchor, live preview
/// decorations (B2), link hit-testing (B3), rows (C1), Up/Down x (C2) and
/// drag (C3).
abstract interface class LineBoxSource {
  /// The render box whose local coordinates this source reports in.
  RenderBox get box;

  /// Every laid-out line, top to bottom (a wrapped source line gives one
  /// per visual line).
  List<LineBox> get lines;

  /// One rect per line that [range] touches, from the range's first to its
  /// last character on that line, each spanning its line box's full height.
  /// Empty for an empty range.
  List<Rect> boxesFor(TextRange range);

  /// The caret rect at [offset]: the caret's x, and the top and bottom of
  /// the line box holding [offset]. Never zero-height, also at an offset
  /// whose character renders zero-width (a hidden marker).
  Rect caretRect(int offset);

  /// The text offset nearest to [point].
  int offsetAt(Offset point);
}

/// One laid-out line of a [LineBoxSource].
@immutable
class LineBox {
  const LineBox({required this.range, required this.top, required this.bottom});

  /// The offsets of the line's characters, without its line break.
  final TextRange range;

  /// The line box's top.
  final double top;

  /// The line box's bottom.
  final double bottom;
}

/// [LineBoxSource] over a laid-out [RenderEditable] (a `TextField`'s or an
/// `EditableText`'s render object), in the editable's local coordinates.
class RenderEditableLineBoxes implements LineBoxSource {
  RenderEditableLineBoxes(this.editable);

  /// The measured field's render object.
  final RenderEditable editable;

  @override
  RenderBox get box => editable;

  @override
  List<LineBox> get lines => throw UnimplementedError();

  @override
  List<Rect> boxesFor(TextRange range) => throw UnimplementedError();

  @override
  Rect caretRect(int offset) => throw UnimplementedError();

  @override
  int offsetAt(Offset point) => throw UnimplementedError();
}
