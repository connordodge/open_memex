// WI #126 (Spec #122 R14, R15, TD1): main's whole-text line-box measurement,
// kept as a test oracle. Before #126, `RenderEditableLineBoxes` and
// `RenderParagraphLineBoxes` laid out a fresh `TextPainter` copy of the whole
// text on every call and walked every line; the lazy, range-local seam must
// give exactly the same lines, rects and carets. This file is that old
// algorithm, verbatim in its rules, except that it lays the copy out once and
// answers every query from it (it is test code: it touches no counter).
//
// Rules it keeps (line_boxes.dart and paragraph_line_boxes.dart doc
// comments): a line box spans its line's full height (max-height selection
// boxes); a blank or empty last line still measures; a caret is never
// zero-height; a field's text is laid out `1 + cursorWidth` px narrower than
// its box; a field's rects shift by its paint (scroll) offset.
import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/rendering.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';

const int _newline = 0x0A;

/// RenderEditable's `_kCaretGap`.
const double _caretGap = 1;

/// Main's measurement of one laid-out field or paragraph. Call [dispose].
class LineBoxOracle {
  LineBoxOracle._(this._painter, this._shift, this._caret, this._length) {
    _text = _painter.plainText;
    lines = _linesOf();
  }

  /// Main's measurement of [editable], as `RenderEditableLineBoxes` did it.
  factory LineBoxOracle.editable(RenderEditable editable) {
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
    painter.layout(
      minWidth: editable.forceLine
          ? available
          : math.min(constraints.minWidth, available),
      maxWidth: multiline ? available : double.infinity,
    );
    final pixels = editable.offset.pixels;
    final shift = editable.maxLines == 1
        ? Offset(-pixels, 0)
        : Offset(0, -pixels);
    return LineBoxOracle._(
      painter,
      shift,
      (at) => editable.getLocalRectForCaret(TextPosition(offset: at)),
      editable.plainText.length,
    );
  }

  /// Main's measurement of [paragraph], as `RenderParagraphLineBoxes` did
  /// it. Its caret rects are zero-width.
  factory LineBoxOracle.paragraph(RenderParagraph paragraph) {
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
    painter.layout(
      minWidth: constraints.minWidth,
      maxWidth: wraps ? constraints.maxWidth : double.infinity,
    );
    return LineBoxOracle._(painter, Offset.zero, (at) {
      final x = paragraph
          .getOffsetForCaret(TextPosition(offset: at), Rect.zero)
          .dx;
      return Rect.fromLTWH(x, 0, 0, 0);
    }, paragraph.text.toPlainText().length);
  }

  final TextPainter _painter;
  final Offset _shift;
  final Rect Function(int offset) _caret;
  final int _length;
  late final String _text;

  /// Every line, top to bottom, as main's `lines` returned them.
  late final List<LineBox> lines;

  /// Main's `boxesFor(range)`.
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    return [
      for (final line in lines)
        if (_overlap(range, line.range) case final part?) _spanOf(part, line),
    ];
  }

  /// Main's `lineHolding(lines, offset)` with the offset clamped as main's
  /// `caretRect` clamped it.
  LineBox lineAt(int offset) =>
      lineHolding(lines, offset.clamp(0, _length).toInt());

  /// Main's `caretRect(offset)`: the caret's x (and width, for a field) and
  /// the holding line box's top and bottom.
  Rect caretRect(int offset) {
    final at = offset.clamp(0, _length).toInt();
    final line = lineHolding(lines, at);
    final caret = _caret(at);
    return Rect.fromLTRB(
      caret.left,
      line.top,
      caret.left + caret.width,
      line.bottom,
    );
  }

  void dispose() => _painter.dispose();

  List<LineBox> _linesOf() {
    final out = <LineBox>[];
    final metrics = _painter.computeLineMetrics();
    var start = 0;
    while (true) {
      final end = _lineEnd(start);
      final hasBreak = end < _text.length && _text.codeUnitAt(end) == _newline;
      final rect = _union(
        _painter.getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: hasBreak ? end + 1 : end,
          ),
          boxHeightStyle: ui.BoxHeightStyle.max,
        ),
      );
      final top = rect?.top ?? (out.isEmpty ? 0.0 : out.last.bottom);
      out.add(
        LineBox(
          range: TextRange(start: start, end: end),
          top: top,
          bottom:
              rect?.bottom ??
              top +
                  _painter.getFullHeightForCaret(
                    TextPosition(offset: start),
                    Rect.zero,
                  ),
          baseline: measuredBaseline(
            _painter,
            metrics,
            out.length,
            top,
            out.lastOrNull,
          ),
        ),
      );
      if (end >= _text.length) break;
      start = hasBreak ? end + 1 : math.max(end, start + 1);
    }
    final dy = _shift.dy;
    return [
      for (final line in out)
        LineBox(
          range: line.range,
          top: line.top + dy,
          bottom: line.bottom + dy,
          baseline: line.baseline + dy,
        ),
    ];
  }

  int _lineEnd(int start) {
    if (start >= _text.length) return start;
    final end = math.max(
      _painter.getLineBoundary(TextPosition(offset: start)).end,
      start,
    );
    return end > start && _text.codeUnitAt(end - 1) == _newline ? end - 1 : end;
  }

  static TextRange? _overlap(TextRange range, TextRange line) {
    final start = math.max(range.start, line.start);
    final end = math.min(range.end, line.end);
    return start < end ? TextRange(start: start, end: end) : null;
  }

  Rect _spanOf(TextRange part, LineBox line) {
    final rect =
        _union(
          _painter.getBoxesForSelection(
            TextSelection(baseOffset: part.start, extentOffset: part.end),
          ),
        ) ??
        _painter.getOffsetForCaret(
              TextPosition(offset: part.start),
              Rect.zero,
            ) &
            Size.zero;
    return Rect.fromLTRB(
      rect.left + _shift.dx,
      line.top,
      rect.right + _shift.dx,
      line.bottom,
    );
  }

  static Rect? _union(List<TextBox> boxes) => boxes.isEmpty
      ? null
      : boxes.map((box) => box.toRect()).reduce((a, b) => a.expandToInclude(b));
}

/// [line] as a comparable record: its range, top, bottom and baseline.
({int start, int end, double top, double bottom, double baseline}) lineKey(
  LineBox line,
) => (
  start: line.range.start,
  end: line.range.end,
  top: line.top,
  bottom: line.bottom,
  baseline: line.baseline,
);

/// Every line of [lines] as [lineKey] records.
List<({int start, int end, double top, double bottom, double baseline})>
lineKeys(List<LineBox> lines) => [for (final l in lines) lineKey(l)];
