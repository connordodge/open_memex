import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/rendering.dart';

import 'line_boxes.dart';

const int _newline = 0x0A;

/// [LineBoxSource] over a laid-out [RenderParagraph] (a `RichText`'s render
/// object), in the paragraph's local coordinates (D6, WI #172): the read-only
/// counterpart of `RenderEditableLineBoxes`, with the same line box rules
/// (each line box spans its line's full height; a blank or empty last line
/// still measures; a caret is never zero-height).
///
/// Line boxes come from the paragraph's own text span laid out again as the
/// paragraph lays it out (strut, text scaler, constraints), reading each
/// line's max-height selection boxes; each line's baseline from its line
/// metrics (WI #437). The caret's x and [offsetAt] come from
/// the paragraph itself. Offsets past the paragraph's text are clamped to
/// its end. The paragraph holds only `TextSpan`s (TD4): a placeholder
/// (`WidgetSpan`) is not measured.
class RenderParagraphLineBoxes implements LineBoxSource {
  RenderParagraphLineBoxes(this.paragraph);

  /// The measured paragraph.
  final RenderParagraph paragraph;

  /// Test-only work counter: fresh `TextPainter` layouts of the whole
  /// paragraph text (every `_measure` call), summed over all instances.
  @visibleForTesting
  static int debugMeasures = 0;

  /// Test-only work counter: whole-text line walks (`_linesOf` over every
  /// line of a measured text), summed over all instances. Every `_measure`
  /// of today's [lines], [boxesFor] and [caretRect] walks once, so it moves
  /// with [debugMeasures]; a range-local measure that skips the walk raises
  /// [debugMeasures] or [debugLineSpans] only.
  @visibleForTesting
  static int debugLineWalks = 0;

  /// Test-only work counter: per-line measures (`_spanOf`), one for each line
  /// a [boxesFor] range read touches, summed over all instances. Differs from
  /// [debugLineWalks]: a range over 2 lines is 1 walk and 2 spans.
  @visibleForTesting
  static int debugLineSpans = 0;

  @override
  RenderBox get box => paragraph;

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

  /// The caret rect at [offset]: zero-width at the caret's x, as tall as the
  /// line box holding [offset].
  @override
  Rect caretRect(int offset) {
    final at = offset.clamp(0, paragraph.text.toPlainText().length);
    final line = lineHolding(lines, at);
    final x = paragraph
        .getOffsetForCaret(TextPosition(offset: at), Rect.zero)
        .dx;
    return Rect.fromLTRB(x, line.top, x, line.bottom);
  }

  /// The text offset nearest to the paragraph-local [point].
  @override
  int offsetAt(Offset point) => paragraph.getPositionForOffset(point).offset;

  @override
  LineBox lineAt(int offset) =>
      const LineBox(range: TextRange.collapsed(0), top: 0, bottom: 0);

  /// Runs [read] over a copy of the paragraph's text laid out as the
  /// paragraph lays it out, then disposes the copy.
  T _measure<T>(T Function(TextPainter painter, String text) read) {
    debugMeasures++;
    final constraints = paragraph.constraints;
    final wraps =
        paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      locale: paragraph.locale,
      maxLines: paragraph.maxLines,
      ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
      strutStyle: paragraph.strutStyle,
      textHeightBehavior: paragraph.textHeightBehavior,
      textWidthBasis: paragraph.textWidthBasis,
    );
    try {
      painter.layout(
        minWidth: constraints.minWidth,
        maxWidth: wraps ? constraints.maxWidth : double.infinity,
      );
      return read(painter, painter.plainText);
    } finally {
      painter.dispose();
    }
  }

  /// Every line of [painter]'s laid-out [text], top to bottom.
  static List<LineBox> _linesOf(TextPainter painter, String text) {
    debugLineWalks++;
    final lines = <LineBox>[];
    final metrics = painter.computeLineMetrics();
    var start = 0;
    while (true) {
      final end = _lineEnd(painter, text, start);
      final hasBreak = end < text.length && text.codeUnitAt(end) == _newline;
      // A line break has a zero-width box as tall as its line, so a blank
      // line measures too. Only a last line can have no box (an empty one,
      // or one of zero-width characters): it starts at the line above's
      // bottom and is as tall as a caret there.
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
          baseline: measuredBaseline(
            painter,
            metrics,
            lines.length,
            top,
            lines.lastOrNull,
          ),
        ),
      );
      if (end >= text.length) break;
      start = hasBreak ? end + 1 : math.max(end, start + 1);
    }
    return lines;
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
  static Rect _spanOf(TextPainter painter, TextRange part, LineBox line) {
    debugLineSpans++;
    final rect =
        _union(
          painter.getBoxesForSelection(
            TextSelection(baseOffset: part.start, extentOffset: part.end),
          ),
        ) ??
        painter.getOffsetForCaret(TextPosition(offset: part.start), Rect.zero) &
            Size.zero;
    return Rect.fromLTRB(rect.left, line.top, rect.right, line.bottom);
  }

  static Rect? _union(List<TextBox> boxes) => boxes.isEmpty
      ? null
      : boxes.map((box) => box.toRect()).reduce((a, b) => a.expandToInclude(b));
}
