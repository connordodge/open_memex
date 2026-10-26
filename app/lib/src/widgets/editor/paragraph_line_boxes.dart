import 'package:flutter/rendering.dart';

import 'line_boxes.dart';

/// [LineBoxSource] over a laid-out [RenderParagraph] (a `RichText`'s render
/// object), in the paragraph's local coordinates (D6, WI #172): the read-only
/// counterpart of `RenderEditableLineBoxes`, with the same line box rules
/// (each line box spans its line's full height; a blank or empty last line
/// still measures; a caret is never zero-height).
class RenderParagraphLineBoxes implements LineBoxSource {
  RenderParagraphLineBoxes(this.paragraph);

  /// The measured paragraph.
  final RenderParagraph paragraph;

  @override
  RenderBox get box => throw UnimplementedError();

  @override
  List<LineBox> get lines => throw UnimplementedError();

  @override
  List<Rect> boxesFor(TextRange range) => throw UnimplementedError();

  @override
  Rect caretRect(int offset) => throw UnimplementedError();

  @override
  int offsetAt(Offset point) => throw UnimplementedError();
}
