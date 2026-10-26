import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle;

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

/// The line of [lines] (a [LineBoxSource.lines] list) holding [offset]: the
/// last line starting at or before it, so an offset at a wrap boundary
/// belongs to the line it starts, where the caret is drawn.
LineBox lineHolding(List<LineBox> lines, int offset) =>
    lines.lastWhere((line) => line.range.start <= offset);

/// The first [RenderEditable] at or under [root] (depth first), or null.
RenderEditable? findRenderEditable(RenderObject? root) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  return found;
}

/// RenderEditable's `_kCaretGap`: it lays its text out this much plus its
/// cursor width narrower than itself.
const double _caretGap = 1;

const int _newline = 0x0A;

/// [LineBoxSource] over a laid-out [RenderEditable] (a `TextField`'s or an
/// `EditableText`'s render object), in the editable's local coordinates.
///
/// Line boxes come from the editable's own text span laid out again as the
/// editable lays it out (strut, text scaler, width), reading each line's
/// max-height selection boxes. Not from `LineMetrics`: under a forced strut
/// they report a run's ascent and descent, not the height the line lays out
/// at. The caret's x and [offsetAt] come from the editable itself. Offsets
/// past the editable's text (typed, not laid out yet) are clamped to its
/// end.
class RenderEditableLineBoxes implements LineBoxSource {
  RenderEditableLineBoxes(this.editable);

  /// The measured field's render object.
  final RenderEditable editable;

  @override
  RenderBox get box => editable;

  @override
  List<LineBox> get lines => _measure(_linesOf);

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    return _measure(
      (painter, text) => [
        for (final line in _linesOf(painter, text))
          if (_overlap(range, line.range) case final part?)
            _spanOf(painter, part, line),
      ],
    );
  }

  @override
  Rect caretRect(int offset) {
    final at = offset.clamp(0, editable.plainText.length);
    final line = lineHolding(lines, at);
    final caret = editable.getLocalRectForCaret(TextPosition(offset: at));
    return Rect.fromLTRB(
      caret.left,
      line.top,
      caret.left + caret.width,
      line.bottom,
    );
  }

  @override
  int offsetAt(Offset point) =>
      editable.getPositionForPoint(editable.localToGlobal(point)).offset;

  /// Where the editable paints its text's origin (its scroll offset).
  Offset get _paintOffset {
    final pixels = editable.offset.pixels;
    return editable.maxLines == 1 ? Offset(-pixels, 0) : Offset(0, -pixels);
  }

  /// Runs [read] over a copy of the editable's text laid out as the
  /// editable lays it out, then disposes the copy.
  T _measure<T>(T Function(TextPainter painter, String text) read) {
    final constraints = editable.constraints;
    final available = math.max(
      0.0,
      constraints.maxWidth - _caretGap - editable.cursorWidth,
    );
    final multiline = editable.maxLines != 1;
    final painter = TextPainter(
      text: editable.text,
      textAlign: editable.textAlign,
      textDirection: editable.textDirection,
      textScaler: editable.textScaler,
      locale: editable.locale,
      maxLines: multiline ? null : 1,
      strutStyle: editable.strutStyle,
      textHeightBehavior: editable.textHeightBehavior,
      textWidthBasis: editable.textWidthBasis,
    );
    try {
      painter.layout(
        minWidth: editable.forceLine
            ? available
            : math.min(constraints.minWidth, available),
        maxWidth: multiline ? available : double.infinity,
      );
      return read(painter, painter.plainText);
    } finally {
      painter.dispose();
    }
  }

  /// Every line of [painter]'s laid-out [text], top to bottom.
  List<LineBox> _linesOf(TextPainter painter, String text) {
    final lines = <LineBox>[];
    var start = 0;
    while (true) {
      final end = _lineEnd(painter, text, start);
      final hasBreak = end < text.length && text.codeUnitAt(end) == _newline;
      // A line break has a zero-width box as tall as its line, so a blank
      // line measures too. Only a last line can have no box (an empty one,
      // or one of zero-width characters): it starts at the line above's
      // bottom and is as tall as a caret there (an empty paragraph's own
      // height is not its line's).
      final rect = _union(
        painter.getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: hasBreak ? end + 1 : end,
          ),
          boxHeightStyle: ui.BoxHeightStyle.max,
        ),
      );
      final top = rect?.top ?? (lines.isEmpty ? 0.0 : lines.last.bottom);
      lines.add(
        LineBox(
          range: TextRange(start: start, end: end),
          top: top,
          bottom:
              rect?.bottom ??
              top +
                  painter.getFullHeightForCaret(
                    TextPosition(offset: start),
                    Rect.zero,
                  ),
        ),
      );
      if (end >= text.length) break;
      start = hasBreak ? end + 1 : math.max(end, start + 1);
    }
    final shift = _paintOffset.dy;
    return [
      for (final line in lines)
        LineBox(
          range: line.range,
          top: line.top + shift,
          bottom: line.bottom + shift,
        ),
    ];
  }

  /// The end (before its line break) of the laid-out line starting at
  /// [start].
  static int _lineEnd(TextPainter painter, String text, int start) {
    if (start >= text.length) return start;
    final end = math.max(
      painter.getLineBoundary(TextPosition(offset: start)).end,
      start,
    );
    // The last line's boundary includes its line break; no other does.
    return end > start && text.codeUnitAt(end - 1) == _newline ? end - 1 : end;
  }

  /// The part of [range] on the line spanning [line], or null when none.
  static TextRange? _overlap(TextRange range, TextRange line) {
    final start = math.max(range.start, line.start);
    final end = math.min(range.end, line.end);
    return start < end ? TextRange(start: start, end: end) : null;
  }

  /// The rect of [part] of [line]: its characters' x extent (the caret's x
  /// when they all render zero-width) and the line box's full height.
  Rect _spanOf(TextPainter painter, TextRange part, LineBox line) {
    final dx = _paintOffset.dx;
    final rect =
        _union(
          painter.getBoxesForSelection(
            TextSelection(baseOffset: part.start, extentOffset: part.end),
          ),
        ) ??
        painter.getOffsetForCaret(TextPosition(offset: part.start), Rect.zero) &
            Size.zero;
    return Rect.fromLTRB(
      rect.left + dx,
      line.top,
      rect.right + dx,
      line.bottom,
    );
  }

  static Rect? _union(List<TextBox> boxes) => boxes.isEmpty
      ? null
      : boxes.map((box) => box.toRect()).reduce((a, b) => a.expandToInclude(b));
}
