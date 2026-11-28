import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/rendering.dart';

import 'line_boxes.dart';

const int _newline = 0x0A;

/// How far left or right of a line a hit test lands on its first or last
/// position.
const double _far = 1e7;

/// [LineBoxSource] over a laid-out [RenderParagraph] (a `RichText`'s render
/// object), in the paragraph's local coordinates (D6, WI #172): the read-only
/// counterpart of `RenderEditableLineBoxes`, with the same line box rules
/// (each line box spans its line's full height; a blank or empty last line
/// still measures; a caret is never zero-height).
///
/// Lazy and range-local (WI #126, Spec #122 TD1): every query reads the
/// paragraph's own laid-out text for the lines it touches only, and caches
/// each line under the [LineBoxEpoch] above the paragraph until it lays its
/// text out again. Only [lines] walks every line, once per layout. A line's
/// box is its max-height selection boxes; its range the positions its first
/// and last points hit; its baseline its bottom less its descent, as the
/// engine defines it ([IsolatedLine]). The caret's x and [offsetAt] come
/// from the paragraph itself. Offsets past the paragraph's text are clamped
/// to its end. A placeholder (`WidgetSpan`, test-only: no production row
/// holds one, D1) measures as its laid-out child.
///
/// In the editor's text styles every answer equals what laying out a
/// whole-text copy of the paragraph's span and walking every line answered
/// before WI #126. Outside them (another strut or leading) a baseline from
/// the line laid out on its own may differ from that copy's.
class RenderParagraphLineBoxes implements LineBoxSource {
  RenderParagraphLineBoxes(this.paragraph);

  /// The measured paragraph.
  final RenderParagraph paragraph;

  /// Test-only work counter: fresh `TextPainter` layouts of the whole
  /// paragraph text, summed over all instances. Line boxes are lazy (WI
  /// #126): no query lays one out, so it stays 0.
  @visibleForTesting
  static int debugMeasures = 0;

  /// Test-only work counter: whole-text line walks (a [lines] read that
  /// measures every line, once per layout), summed over all instances.
  @visibleForTesting
  static int debugLineWalks = 0;

  /// Test-only work counter: per-line measures, one for each line a
  /// [lineAt], [boxesFor] or [caretRect] read measures that was not cached
  /// yet, summed over all instances. A [lines] walk counts none.
  @visibleForTesting
  static int debugLineSpans = 0;

  @override
  RenderBox get box => paragraph;

  LineBoxLayoutKey _key() => (
    paragraph.constraints,
    paragraph.textScaler,
    paragraph.strutStyle,
    paragraph.textAlign,
    paragraph.textDirection,
    paragraph.locale,
    paragraph.textHeightBehavior,
    paragraph.textWidthBasis,
    paragraph.maxLines,
    paragraph.softWrap,
    paragraph.overflow,
  );

  /// The paragraph's per-line cache; none while it lays out placeholder
  /// children, whose sizes the cache cannot follow.
  LineBoxCache? _cache() =>
      paragraph.childCount > 0 ? null : lineBoxCacheOf(paragraph, key: _key);

  String _textOf(LineBoxCache? cache) {
    if (cache == null) return paragraph.text.toPlainText();
    return cache.plainText ??= paragraph.text.toPlainText();
  }

  @override
  List<LineBox> get lines {
    final cache = _cache();
    final cached = cache?.all;
    if (cached != null) return cached;
    debugLineWalks++;
    final text = _textOf(cache);
    final lines = <LineBox>[];
    var start = 0;
    while (true) {
      final line = _line(cache, text, start, counted: false);
      lines.add(line);
      final end = line.range.end;
      if (end >= text.length) break;
      final hasBreak = text.codeUnitAt(end) == _newline;
      start = hasBreak ? end + 1 : math.max(end, start + 1);
    }
    if (cache == null) return lines;
    return cache.all = List.unmodifiable(lines);
  }

  @override
  LineBox lineAt(int offset) {
    final cache = _cache();
    final text = _textOf(cache);
    final at = offset.clamp(0, text.length).toInt();
    return _line(cache, text, _lineStart(text, at), counted: true);
  }

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    final cache = _cache();
    final cached = cache?.boxes[range];
    if (cached != null) return cached;
    final text = _textOf(cache);
    final rects = <Rect>[];
    var start = _lineStart(text, range.start.clamp(0, text.length).toInt());
    while (true) {
      final line = _line(cache, text, start, counted: true);
      final end = line.range.end;
      if (overlapOfLine(range, line.range) case final part?) {
        rects.add(_spanOf(part, line));
      }
      if (end >= text.length || end >= range.end) break;
      start = text.codeUnitAt(end) == _newline
          ? end + 1
          : math.max(end, start + 1);
    }
    if (cache == null) return rects;
    return cache.remember(range, rects);
  }

  /// The caret rect at [offset]: zero-width at the caret's x, as tall as the
  /// line box holding [offset].
  @override
  Rect caretRect(int offset) {
    final cache = _cache();
    final at = offset.clamp(0, _textOf(cache).length).toInt();
    final line = lineAt(at);
    final x = paragraph
        .getOffsetForCaret(TextPosition(offset: at), Rect.zero)
        .dx;
    return Rect.fromLTRB(x, line.top, x, line.bottom);
  }

  /// The text offset nearest to the paragraph-local [point].
  @override
  int offsetAt(Offset point) => paragraph.getPositionForOffset(point).offset;

  /// The max-height box of the character at [i], or null for a character
  /// that renders zero-width (a hidden marker has none).
  TextBox? _boxAt(int i) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    return boxes.isEmpty ? null : boxes.first;
  }

  /// The middle of [box]'s line.
  static double _yOf(TextBox box) => (box.top + box.bottom) / 2;

  /// The first position a hit test far left on the line through [y] lands
  /// on: the same for every y inside one laid-out line, so it names it.
  int _markAt(double y) =>
      paragraph.getPositionForOffset(Offset(-_far, y)).offset;

  /// The start of the laid-out line holding [at] (in `0..text.length`):
  /// an empty last line (after a final line break) starts at the text's end.
  int _lineStart(String text, int at) {
    if (text.isEmpty) return 0;
    if (at == text.length && text.codeUnitAt(at - 1) == _newline) return at;
    return _lineAround(text, at).start;
  }

  /// The end (before its line break) of the laid-out line starting at
  /// [start].
  int _lineEnd(String text, int start) =>
      start >= text.length ? start : _lineAround(text, start).end;

  /// The laid-out line holding [at] (`at < text.length`, or the end of a
  /// text not ending in a line break), without its line break.
  ///
  /// The paragraph has no line boundary query: the line is the one a hit
  /// test far left of a character's box lands on, from its first to its
  /// last position, stepped out over zero-width characters (hidden markers
  /// have no box and all hit one place). A zero-width run between two
  /// lines of its source line belongs to the later one (a line wraps after
  /// a space, before the markers opening a word); one that is the whole
  /// source line is one line.
  TextRange _lineAround(String text, int at) {
    final hs = at == 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
    final next = text.indexOf('\n', at);
    final he = next < 0 ? text.length : next;
    // The y of a character with a box on the line holding [at].
    final atBox = at < text.length ? _boxAt(at) : null;
    final double y;
    if (atBox != null) {
      y = _yOf(atBox);
    } else {
      TextBox? before;
      for (var k = math.min(at, he) - 1; k >= hs && before == null; k--) {
        before = _boxAt(k);
      }
      TextBox? after;
      for (var k = at; k <= he && k < text.length && after == null; k++) {
        after = _boxAt(k);
      }
      if (before == null && after == null) {
        return TextRange(start: hs, end: he);
      }
      // At the text's end no box follows the zero-width run: the line after
      // it is the paragraph's last laid-out line, which a hit test far below
      // lands on.
      final afterY = after != null
          ? _yOf(after)
          : (he == text.length ? _far : null);
      y = before == null || afterY == null
          ? (before == null ? afterY! : _yOf(before))
          : (_markAt(_yOf(before)) == _markAt(afterY) ? _yOf(before) : afterY);
    }
    final mark = _markAt(y);
    // Out to the line's start: over zero-width characters and characters
    // on this line, never past the source line's start.
    var start = math.max(hs, math.min(mark, at));
    while (start > hs) {
      final k = _boxAt(start - 1);
      if (k != null && _markAt(_yOf(k)) != mark) break;
      start--;
    }
    // Out to its end: over characters on this line, and over a zero-width
    // run only when more of this line, or the source line's end on this
    // line, follows (a line can wrap after a space, before a zero-width run
    // that ends the source line: the run is then a line of its own).
    var end = paragraph
        .getPositionForOffset(Offset(_far, y))
        .offset
        .clamp(start, he)
        .toInt();
    end = math.max(end, math.min(at, he));
    var k = end;
    while (k < he) {
      final b = _boxAt(k);
      if (b == null) {
        k++;
        continue;
      }
      if (_markAt(_yOf(b)) != mark) break;
      end = ++k;
    }
    if (k >= he && (_breakMark(text, he) ?? mark) == mark) end = he;
    return TextRange(start: start, end: end);
  }

  /// The [_markAt] of the laid-out line holding the end of the source line
  /// at [he]: the line holding its line break (whose zero-width box is on
  /// that line), or at the text's end the paragraph's last laid-out line;
  /// null for a break without a box.
  int? _breakMark(String text, int he) {
    if (he >= text.length) return _markAt(_far);
    final b = _boxAt(he);
    return b == null ? null : _markAt(_yOf(b));
  }

  /// The line starting at [start], from [cache] or measured (a range-local
  /// measure counts one span when [counted]).
  LineBox _line(
    LineBoxCache? cache,
    String text,
    int start, {
    required bool counted,
  }) {
    final cached = cache?.lines[start];
    if (cached != null) return cached;
    if (counted) debugLineSpans++;
    final line = _measure(cache, text, start, counted: counted);
    cache?.lines[start] = line;
    return line;
  }

  IsolatedLine _isolated(
    int from,
    int to, {
    required bool first,
    required bool last,
  }) => isolatedLine(
    paragraph.text,
    from: from,
    to: to,
    first: first,
    last: last,
    style: (
      direction: paragraph.textDirection,
      scaler: paragraph.textScaler,
      locale: paragraph.locale,
      strut: paragraph.strutStyle,
      heightBehavior: paragraph.textHeightBehavior,
    ),
    placeholders: () => placeholderDimensionsOf(paragraph),
  );

  /// Measures the line starting at [start] (a line above it it needs is
  /// measured too, counting a span when [counted]).
  LineBox _measure(
    LineBoxCache? cache,
    String text,
    int start, {
    required bool counted,
  }) {
    final length = text.length;
    if (start < length) {
      final end = _lineEnd(text, start);
      final hasBreak = end < length && text.codeUnitAt(end) == _newline;
      final range = TextRange(start: start, end: end);
      // A line break has a zero-width box as tall as its line, so a blank
      // line measures too.
      final rect = unionOfBoxes(
        paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: hasBreak ? end + 1 : end,
          ),
          boxHeightStyle: ui.BoxHeightStyle.max,
        ),
      );
      if (rect != null) {
        final iso = _isolated(
          start,
          hasBreak ? end + 1 : end,
          first: start == 0,
          last: end >= length,
        );
        return LineBox(
          range: range,
          top: rect.top,
          bottom: rect.bottom,
          baseline: iso.baselineAt(0, rect.bottom) ?? rect.bottom,
        );
      }
      // A line of zero-width characters only (a hidden fence line) has no
      // box.
      final iso = _isolated(
        start,
        hasBreak ? end + 1 : end,
        first: start == 0,
        last: end >= length,
      );
      return _boxless(cache, text, range, iso, 0, counted: counted);
    }
    // An empty paragraph, or the empty last line after a final line break.
    final iso = length == 0
        ? _isolated(0, 0, first: true, last: true)
        : _isolated(length - 1, length, first: false, last: true);
    return _boxless(
      cache,
      text,
      TextRange.collapsed(start),
      iso,
      length == 0 ? 0 : 1,
      counted: counted,
    );
  }

  /// A line without a box: it starts at the line above's bottom (or the
  /// text's top) and is as tall as a caret there. Its baseline is the
  /// isolated text's line [index]'s placed at its top, or as far below its
  /// top as the line above's without metrics there.
  LineBox _boxless(
    LineBoxCache? cache,
    String text,
    TextRange range,
    IsolatedLine iso,
    int index, {
    required bool counted,
  }) {
    final previous = range.start == 0
        ? null
        : _line(
            cache,
            text,
            _lineStart(text, range.start - 1),
            counted: counted,
          );
    final top = previous?.bottom ?? 0.0;
    final bottom =
        top +
        paragraph.getFullHeightForCaret(TextPosition(offset: range.start));
    final metrics = index < iso.metrics.length ? iso.metrics[index] : null;
    final double baseline;
    if (metrics != null) {
      baseline = iso.baselineAt(index, float32(top + metrics.height))!;
    } else if (previous != null) {
      baseline = top + previous.baseline - previous.top;
    } else {
      baseline = top + iso.firstBaseline;
    }
    return LineBox(range: range, top: top, bottom: bottom, baseline: baseline);
  }

  /// The rect of [part] of [line]: its characters' x extent (the caret's x
  /// when they all render zero-width) and the line box's full height.
  Rect _spanOf(TextRange part, LineBox line) {
    final rect =
        unionOfBoxes(
          paragraph.getBoxesForSelection(
            TextSelection(baseOffset: part.start, extentOffset: part.end),
          ),
        ) ??
        paragraph.getOffsetForCaret(
              TextPosition(offset: part.start),
              Rect.zero,
            ) &
            Size.zero;
    return Rect.fromLTRB(rect.left, line.top, rect.right, line.bottom);
  }
}
