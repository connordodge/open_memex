import 'dart:math' as math;
import 'dart:typed_data' show Float32List, Uint32List;
import 'dart:ui' as ui show BoxHeightStyle, BoxWidthStyle, LineMetrics;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart'
    show BuildContext, SingleChildRenderObjectWidget, SizedBox, WidgetSpan;

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

  /// The line box holding [offset] (WI #126): the [lines] entry
  /// `lineHolding(lines, offset)` returns, the last line starting at or
  /// before [offset] (clamped to the text), so an offset at a wrap boundary
  /// belongs to the line it starts. Costs only that line, never a walk of
  /// every line.
  LineBox lineAt(int offset);
}

/// The layout epoch of the field or paragraph directly below it (WI #126,
/// Spec #122 TD1): a thin proxy that holds the per-line cache of the text
/// render object under it. Its [RenderLineBoxEpoch.epoch] moves when that
/// render object's text layout changes (a font load, a width, a text or a
/// layout-changing style), never on a paint-only change, and the cache is
/// dropped when it moves.
class LineBoxEpoch extends SingleChildRenderObjectWidget {
  const LineBoxEpoch({super.key, super.child});

  @override
  RenderLineBoxEpoch createRenderObject(BuildContext context) =>
      RenderLineBoxEpoch();
}

/// [LineBoxEpoch]'s render object.
///
/// The epoch moves on every system fonts change (a font load relays the text
/// out; `RelayoutWhenSystemFontsChangeMixin`) and in [performLayout] when the
/// cached render object's layout inputs (constraints, a layout-level
/// span change, strut, scaler, alignment, direction, locale, height
/// behaviour, width basis, box styles) differ from the cache's. A field
/// relays out on every span change, also a paint-only one, so a layout alone
/// does not move it.
class RenderLineBoxEpoch extends RenderProxyBox
    with RelayoutWhenSystemFontsChangeMixin {
  RenderLineBoxEpoch([super.child]);

  int _epoch = 0;

  /// How many times the text layout under this proxy has changed.
  int get epoch => _epoch;

  final LineBoxCache _cache = LineBoxCache._();

  @override
  void systemFontsDidChange() {
    _epoch++;
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_cache._layoutChanged()) _epoch++;
  }
}

/// The inputs a text render object lays its text out from, besides its span
/// (compared with `InlineSpan.compareTo`). Two equal keys lay out the same
/// span the same way.
typedef LineBoxLayoutKey = Object;

/// The per-line cache of one text render object under a [LineBoxEpoch]
/// (WI #126): the lines measured so far by their start offset, the range
/// reads by range, and the whole-text [lines] once walked. Valid for one
/// layout epoch, one layout key and one paint offset; dropped when any
/// moves. Used by [RenderEditableLineBoxes] and `RenderParagraphLineBoxes`.
final class LineBoxCache {
  LineBoxCache._();

  RenderBox? _owner;
  int _epoch = -1;
  Object? _key;
  InlineSpan? _span;
  Offset? _paintOffset;
  LineBoxLayoutKey Function()? _keyOf;

  /// Measured lines by their start offset.
  final Map<int, LineBox> lines = {};

  /// Range reads ([LineBoxSource.boxesFor]) by range.
  final Map<TextRange, List<Rect>> boxes = {};

  /// How many range reads [boxes] keeps (a drag reads a new range every
  /// frame without a relayout).
  static const int _maxRanges = 512;

  /// Keeps [rects] as [range]'s read and returns them (unmodifiable).
  List<Rect> remember(TextRange range, List<Rect> rects) {
    if (boxes.length >= _maxRanges) boxes.clear();
    return boxes[range] = List.unmodifiable(rects);
  }

  /// Every line, once walked.
  List<LineBox>? all;

  /// The plain text of the cached span, once read.
  String? plainText;

  void _clear() {
    lines.clear();
    boxes.clear();
    all = null;
    plainText = null;
  }

  /// Whether the owner's layout inputs no longer match the cache's (read
  /// after the owner laid out).
  bool _layoutChanged() {
    final owner = _owner;
    final keyOf = _keyOf;
    if (owner == null || keyOf == null || !owner.attached || !owner.hasSize) {
      return false;
    }
    final span = _textOf(owner);
    return keyOf() != _key || _spanChanged(span);
  }

  /// Whether [span] lays out differently from the cached span; a paint-only
  /// or identical span is kept as the cached one.
  bool _spanChanged(InlineSpan? span) {
    final old = _span;
    if (identical(old, span)) return false;
    _span = span;
    plainText = null;
    if (old == null || span == null) return true;
    return old.compareTo(span) == RenderComparison.layout;
  }

  static InlineSpan? _textOf(RenderBox owner) => switch (owner) {
    final RenderEditable e => e.text,
    final RenderParagraph p => p.text,
    _ => null,
  };
}

/// How far above a measured text render object [lineBoxCacheOf] looks for
/// its [LineBoxEpoch] (a `TextField`'s editable sits a few dozen render
/// objects below it).
const int _epochSearchDepth = 64;

/// The per-line cache of [measured] (a laid-out `RenderEditable` or
/// `RenderParagraph`) under the nearest [LineBoxEpoch] above it, cleared
/// first when the epoch, [key], the text span's layout or [paintOffset]
/// moved since it was filled; null without an epoch above.
LineBoxCache? lineBoxCacheOf(
  RenderBox measured, {
  required LineBoxLayoutKey Function() key,
  Offset paintOffset = Offset.zero,
}) {
  var node = measured.parent;
  for (var i = 0; node != null && i < _epochSearchDepth; i++) {
    if (node is RenderLineBoxEpoch) {
      final cache = node._cache;
      final now = key();
      final spanChanged = cache._spanChanged(LineBoxCache._textOf(measured));
      if (!identical(cache._owner, measured) ||
          cache._epoch != node.epoch ||
          cache._key != now ||
          cache._paintOffset != paintOffset ||
          spanChanged) {
        cache
          .._clear()
          .._owner = measured
          .._epoch = node.epoch
          .._key = now
          .._paintOffset = paintOffset
          .._keyOf = key;
      }
      return cache;
    }
    node = node.parent;
  }
  return null;
}

/// One laid-out line of a [LineBoxSource].
@immutable
class LineBox {
  const LineBox({
    required this.range,
    required this.top,
    required this.bottom,
    double? baseline,
  }) : baseline = baseline ?? bottom;

  /// The offsets of the line's characters, without its line break.
  final TextRange range;

  /// The line box's top.
  final double top;

  /// The line box's bottom.
  final double bottom;

  /// The line's alphabetic baseline, in the same coordinates as [top] and
  /// [bottom] (WI #437, ruling D23). Defaults to [bottom] when the source
  /// does not measure it.
  final double baseline;
}

/// The baseline of line [index] of a laid-out painter whose line metrics are
/// [metrics], the line's box starting at [top]; [previous] is the line above,
/// if any. A line without metrics (an empty field's, or an empty last line)
/// sits as far below its top as the line above does, or at the painter's
/// first baseline.
double measuredBaseline(
  TextPainter painter,
  List<ui.LineMetrics> metrics,
  int index,
  double top,
  LineBox? previous,
) {
  if (index < metrics.length) return metrics[index].baseline;
  if (previous != null) return top + previous.baseline - previous.top;
  return top + painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
}

/// The line of [lines] (a [LineBoxSource.lines] list) holding [offset]: the
/// last line starting at or before it, so an offset at a wrap boundary
/// belongs to the line it starts, where the caret is drawn.
LineBox lineHolding(List<LineBox> lines, int offset) =>
    lines.lastWhere((line) => line.range.start <= offset);

/// The rect of each line of [boxes] that [range] touches, with the line it
/// spans (WI #126): what `boxesFor(range)` answers, each paired with its
/// [LineBox], from one [LineBoxSource.lineAt] and one range read per line,
/// never a walk of every line. [text] is the source's text.
Iterable<(Rect, LineBox)> lineRectsOf(
  LineBoxSource boxes,
  TextRange range,
  String text,
) sync* {
  if (range.isCollapsed) return;
  var line = boxes.lineAt(range.start);
  while (true) {
    if (overlapOfLine(range, line.range) case final part?) {
      for (final rect in boxes.boxesFor(part)) {
        yield (rect, line);
      }
    }
    final end = line.range.end;
    if (end >= range.end || end >= text.length) return;
    final next = boxes.lineAt(text.codeUnitAt(end) == _newline ? end + 1 : end);
    if (next.range.start <= line.range.start) return;
    line = next;
  }
}

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

const int _newline = 0x0A;

// ------------------------------------------------------- float32 helpers

final Float32List _f32 = Float32List(1);
final Uint32List _u32 = Uint32List.view(_f32.buffer);

/// [value] rounded to the nearest float32: the text engine measures in
/// float32, so a sum it computes is the float32 rounding of the exact sum
/// of its two float32 terms.
double float32(double value) {
  _f32[0] = value;
  return _f32[0];
}

int _bitsOf(double value) {
  _f32[0] = value;
  return _u32[0];
}

double _floatOf(int bits) {
  _u32[0] = bits;
  return _f32[0];
}

// --------------------------------------------------------- isolated lines

/// The layout facts of one line laid out on its own (WI #126): the line's
/// [InlineSpan] slice in a painter configured as the measured text's, with
/// its first ascent and last descent applied as the line has them in place.
/// A line's height, its max-height box offset and its descent depend only on
/// the line's own runs and the paragraph style, so they equal the line's in
/// place; its offset down the text does not, and is never read from here.
@immutable
class IsolatedLine {
  const IsolatedLine({
    required this.metrics,
    required this.top,
    required this.bottom,
    required this.fullHeightAtStart,
    required this.fullHeightAtEnd,
    required this.firstBaseline,
  });

  /// The isolated text's line metrics: the line's first, then (after a
  /// line break) the empty line that follows it.
  final List<ui.LineMetrics> metrics;

  /// The top and bottom of the line's own max-height boxes, or null when it
  /// has none. The line starts 0 down the isolated text, so these are its
  /// box's offset from the line's top and its height.
  final double? top;
  final double? bottom;

  /// The caret's full height at the isolated text's start and end.
  final double fullHeightAtStart;
  final double fullHeightAtEnd;

  /// The isolated painter's first baseline.
  final double firstBaseline;

  /// The baseline of the isolated text's line [index] placed with its box
  /// ending at [bottom]: the engine's own definition (bottom less the line's
  /// descent, in float32); null without metrics there.
  double? baselineAt(int index, double bottom) {
    if (index >= metrics.length) return null;
    // Where the engine put the line's bottom down the isolated text.
    var own = 0.0;
    for (var i = 0; i < index; i++) {
      own = float32(own + metrics[i].height);
    }
    own = float32(own + metrics[index].height);
    final m = metrics[index];
    // The metrics' descent is the line's runs' (no strut). When a strut sets
    // the line's descent instead, it is read back from the baseline.
    final descent = float32(own - m.descent) == m.baseline
        ? m.descent
        : own - m.baseline;
    return float32(bottom - descent);
  }
}

/// The paragraph style a measured text render object lays its text out
/// with (the inputs an [IsolatedLine] copies).
typedef IsolatedStyle = ({
  TextDirection direction,
  TextScaler scaler,
  Locale? locale,
  StrutStyle? strut,
  TextHeightBehavior? heightBehavior,
});

/// Lays out `[from, to)` of [root] on its own (see [IsolatedLine]); [first]
/// and [last] say whether the line is the measured text's first and last.
/// [placeholders] gives each placeholder of [root] (in text order) its
/// laid-out dimensions.
IsolatedLine isolatedLine(
  InlineSpan root, {
  required int from,
  required int to,
  required bool first,
  required bool last,
  required IsolatedStyle style,
  required List<PlaceholderDimensions> Function() placeholders,
}) {
  final dims = <PlaceholderDimensions>[];
  List<PlaceholderDimensions>? all;
  var at = 0;
  var placeholder = 0;
  InlineSpan? slice(InlineSpan span) {
    switch (span) {
      case final TextSpan s:
        final text = s.text ?? '';
        final start = at;
        at += text.length;
        final own =
            math.max(from - start, 0) < math.min(to - start, text.length)
            ? text.substring(
                math.max(from - start, 0),
                math.min(to - start, text.length),
              )
            : null;
        final children = <InlineSpan>[];
        for (final child in s.children ?? const <InlineSpan>[]) {
          if (at >= to) break;
          final part = slice(child);
          if (part != null) children.add(part);
        }
        if (own == null && children.isEmpty) return null;
        return TextSpan(
          text: own,
          style: s.style,
          locale: s.locale,
          spellOut: s.spellOut,
          children: children.isEmpty ? null : children,
        );
      case final PlaceholderSpan p:
        final index = placeholder++;
        final start = at;
        at += 1;
        if (start < from || start >= to) return null;
        all ??= placeholders();
        dims.add(
          index < all!.length ? all![index] : PlaceholderDimensions.empty,
        );
        return WidgetSpan(
          alignment: p.alignment,
          baseline: p.baseline,
          style: p.style,
          // An isolated painter never builds its child.
          child: const SizedBox.shrink(),
        );
      default:
        return null;
    }
  }

  final text = slice(root) ?? TextSpan(text: '', style: root.style);
  final behavior = style.heightBehavior;
  final painter = TextPainter(
    text: text,
    textDirection: style.direction,
    textScaler: style.scaler,
    locale: style.locale,
    strutStyle: style.strut,
    textHeightBehavior: behavior == null
        ? null
        : TextHeightBehavior(
            applyHeightToFirstAscent:
                !first || behavior.applyHeightToFirstAscent,
            applyHeightToLastDescent:
                !last || behavior.applyHeightToLastDescent,
            leadingDistribution: behavior.leadingDistribution,
          ),
  );
  try {
    if (dims.isNotEmpty) painter.setPlaceholderDimensions(dims);
    painter.layout();
    final length = painter.plainText.length;
    final boxes = length == 0
        ? const <TextBox>[]
        : painter.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: length),
            boxHeightStyle: ui.BoxHeightStyle.max,
          );
    // Only the line's own boxes: a line break's trailing empty line has none.
    final own = boxes.isEmpty
        ? null
        : boxes.where((b) => b.top == boxes.first.top).toList();
    return IsolatedLine(
      metrics: painter.computeLineMetrics(),
      top: own?.map((b) => b.top).reduce(math.min),
      bottom: own?.map((b) => b.bottom).reduce(math.max),
      fullHeightAtStart: painter.getFullHeightForCaret(
        const TextPosition(offset: 0),
        Rect.zero,
      ),
      fullHeightAtEnd: painter.getFullHeightForCaret(
        TextPosition(offset: length),
        Rect.zero,
      ),
      firstBaseline: painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      ),
    );
  } finally {
    painter.dispose();
  }
}

/// The laid-out dimensions of each placeholder child of [box] (a
/// `RenderEditable` or `RenderParagraph`), in text order. A
/// baseline-aligned child sits its bottom on the baseline: its own baseline
/// can only be read while its parent lays out or paints.
List<PlaceholderDimensions> placeholderDimensionsOf(RenderBox box) {
  final dims = <PlaceholderDimensions>[];
  box.visitChildren((child) {
    if (child is! RenderBox) return;
    final data = child.parentData;
    final span = data is TextParentData ? data.span : null;
    if (span == null || !child.hasSize) {
      dims.add(PlaceholderDimensions.empty);
      return;
    }
    dims.add(
      PlaceholderDimensions(
        size: child.size,
        alignment: span.alignment,
        baseline: span.baseline,
        baselineOffset: span.alignment == PlaceholderAlignment.baseline
            ? child.size.height
            : null,
      ),
    );
  });
  return dims;
}

/// The union of [boxes] as a rect, or null when there are none.
Rect? unionOfBoxes(Iterable<TextBox> boxes) => boxes.isEmpty
    ? null
    : boxes.map((box) => box.toRect()).reduce((a, b) => a.expandToInclude(b));

/// The part of [range] on the line spanning [line], or null when none.
TextRange? overlapOfLine(TextRange range, TextRange line) {
  final start = math.max(range.start, line.start);
  final end = math.min(range.end, line.end);
  return start < end ? TextRange(start: start, end: end) : null;
}

/// [LineBoxSource] over a laid-out [RenderEditable] (a `TextField`'s or an
/// `EditableText`'s render object), in the editable's local coordinates.
///
/// Lazy and range-local (WI #126, Spec #122 TD1): every query reads the
/// editable's own laid-out text for the lines it touches only, and caches
/// each line under the [LineBoxEpoch] above the field, until the field lays
/// its text out again or scrolls. Only [lines] walks every line, once per
/// layout.
///
/// A line's box is its max-height selection boxes when the field selects
/// with [ui.BoxHeightStyle.max] (an editor row's field). Otherwise (the
/// Source field keeps the platform's selection boxes) its top is found where
/// the field's own hit test leaves the line above, and its height from the
/// line laid out on its own ([IsolatedLine]). Its baseline is its bottom less
/// its descent, as the engine defines it. Not from `LineMetrics` in place:
/// the editable does not expose its painter's. The caret's x, a range's x
/// extent and [offsetAt] come from the editable itself. Offsets past the
/// editable's text (typed, not laid out yet) are clamped to its end.
///
/// In the editor's text styles every answer equals what laying out a
/// whole-text copy of the field's span and walking every line answered
/// before WI #126. Outside them (another strut or leading) a baseline from
/// the line laid out on its own may differ from that copy's.
class RenderEditableLineBoxes implements LineBoxSource {
  RenderEditableLineBoxes(this.editable);

  /// The measured field's render object.
  final RenderEditable editable;

  /// Test-only work counter: fresh `TextPainter` layouts of the whole field
  /// text, summed over all instances. Line boxes are lazy (WI #126): no
  /// query lays one out, so it stays 0.
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
  RenderBox get box => editable;

  /// Where the editable paints its text's origin (its scroll offset).
  Offset get _paintOffset {
    final pixels = editable.offset.pixels;
    return editable.maxLines == 1 ? Offset(-pixels, 0) : Offset(0, -pixels);
  }

  LineBoxLayoutKey _key() => (
    editable.constraints,
    editable.textScaler,
    editable.strutStyle,
    editable.textAlign,
    editable.textDirection,
    editable.locale,
    editable.textHeightBehavior,
    editable.textWidthBasis,
    editable.maxLines,
    editable.forceLine,
    editable.cursorWidth,
    editable.obscureText,
    editable.selectionHeightStyle,
    editable.selectionWidthStyle,
  );

  /// The field's per-line cache; none while it lays out placeholder
  /// children, whose sizes the cache cannot follow.
  LineBoxCache? _cache() => editable.childCount > 0
      ? null
      : lineBoxCacheOf(editable, key: _key, paintOffset: _paintOffset);

  @override
  List<LineBox> get lines {
    final cache = _cache();
    final cached = cache?.all;
    if (cached != null) return cached;
    debugLineWalks++;
    final text = editable.plainText;
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
    final text = editable.plainText;
    final at = offset.clamp(0, text.length).toInt();
    return _line(_cache(), text, _lineStart(text, at), counted: true);
  }

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    final cache = _cache();
    final cached = cache?.boxes[range];
    if (cached != null) return cached;
    final text = editable.plainText;
    final rects = <Rect>[];
    var start = _lineStart(text, range.start.clamp(0, text.length).toInt());
    while (true) {
      final line = _line(cache, text, start, counted: true);
      final end = line.range.end;
      final last = end >= text.length;
      if (overlapOfLine(range, line.range) case final part?) {
        rects.add(_spanOf(part, line, lastLine: last));
      }
      if (last || end >= range.end) break;
      start = text.codeUnitAt(end) == _newline
          ? end + 1
          : math.max(end, start + 1);
    }
    if (cache == null) return rects;
    return cache.remember(range, rects);
  }

  @override
  Rect caretRect(int offset) {
    final at = offset.clamp(0, editable.plainText.length).toInt();
    final line = lineAt(at);
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

  /// The start of the laid-out line holding [at] (in `0..text.length`):
  /// an empty last line (after a final line break) starts at the text's end.
  int _lineStart(String text, int at) {
    if (text.isEmpty) return 0;
    if (at == text.length && text.codeUnitAt(at - 1) == _newline) return at;
    return math.max(
      0,
      editable.getLineAtOffset(TextPosition(offset: at)).start,
    );
  }

  /// The end (before its line break) of the laid-out line starting at
  /// [start].
  int _lineEnd(String text, int start) {
    if (start >= text.length) return start;
    final end = math.max(
      editable.getLineAtOffset(TextPosition(offset: start)).end,
      start,
    );
    // The last line's boundary includes its line break; no other does.
    return end > start && text.codeUnitAt(end - 1) == _newline ? end - 1 : end;
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
    editable.text ?? const TextSpan(),
    from: from,
    to: to,
    first: first,
    last: last,
    style: (
      direction: editable.textDirection,
      scaler: editable.textScaler,
      locale: editable.locale,
      strut: editable.strutStyle,
      heightBehavior: editable.textHeightBehavior,
    ),
    placeholders: () => placeholderDimensionsOf(editable),
  );

  /// Measures the line starting at [start] (a line above it it needs is
  /// measured too, counting a span when [counted]).
  LineBox _measure(
    LineBoxCache? cache,
    String text,
    int start, {
    required bool counted,
  }) {
    final shift = _paintOffset.dy;
    final length = text.length;
    if (start < length) {
      final end = _lineEnd(text, start);
      final hasBreak = end < length && text.codeUnitAt(end) == _newline;
      final range = TextRange(start: start, end: end);
      final rect = unionOfBoxes(
        editable.getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: hasBreak ? end + 1 : end,
          ),
        ),
      );
      final first = start == 0;
      final last = end >= length;
      if (rect != null) {
        final iso = _isolated(
          start,
          hasBreak ? end + 1 : end,
          first: first,
          last: last,
        );
        if (editable.selectionHeightStyle == ui.BoxHeightStyle.max) {
          // The field's own max-height boxes span the line box.
          final bottom = rect.bottom - shift;
          return LineBox(
            range: range,
            top: rect.top,
            bottom: rect.bottom,
            baseline: (iso.baselineAt(0, bottom) ?? bottom) + shift,
          );
        }
        final y = _lineTopOffset(start, rect, iso, shift);
        final top = float32((iso.top ?? 0) + y);
        final bottom = float32(y + (iso.bottom ?? iso.fullHeightAtStart));
        return LineBox(
          range: range,
          top: top + shift,
          bottom: bottom + shift,
          baseline: (iso.baselineAt(0, bottom) ?? bottom) + shift,
        );
      }
      // A line of zero-width characters only (a hidden fence line) has no
      // box.
      final iso = _isolated(
        start,
        hasBreak ? end + 1 : end,
        first: first,
        last: last,
      );
      return _boxless(
        cache,
        text,
        range,
        iso,
        index: 0,
        height: iso.fullHeightAtStart,
        shift: shift,
        counted: counted,
      );
    }
    // An empty field, or the empty last line after a final line break.
    final iso = length == 0
        ? _isolated(0, 0, first: true, last: true)
        : _isolated(length - 1, length, first: false, last: true);
    return _boxless(
      cache,
      text,
      TextRange.collapsed(start),
      iso,
      index: length == 0 ? 0 : 1,
      height: iso.fullHeightAtEnd,
      shift: shift,
      counted: counted,
    );
  }

  /// A line without a box: it starts at the line above's bottom (or the
  /// text's top) and is as tall as a caret there ([height]). Its baseline
  /// is the isolated text's line [index]'s, placed at its top, or as far
  /// below its top as the line above's without metrics there.
  LineBox _boxless(
    LineBoxCache? cache,
    String text,
    TextRange range,
    IsolatedLine iso, {
    required int index,
    required double height,
    required double shift,
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
    final top = previous == null ? 0.0 : previous.bottom - shift;
    final bottom = top + height;
    final metrics = index < iso.metrics.length ? iso.metrics[index] : null;
    final double baseline;
    if (metrics != null) {
      baseline = iso.baselineAt(index, float32(top + metrics.height))!;
    } else if (previous != null) {
      baseline = top + (previous.baseline - shift) - (previous.top - shift);
    } else {
      baseline = top + iso.firstBaseline;
    }
    return LineBox(
      range: range,
      top: top + shift,
      bottom: bottom + shift,
      baseline: baseline + shift,
    );
  }

  /// The text-space offset down the text of the line starting at [start]
  /// (whose own boxes span [rect], in local coordinates): where the field's
  /// hit test moves from the line above onto it, as a float32. 0 for the
  /// first line.
  double _lineTopOffset(int start, Rect rect, IsolatedLine iso, double shift) {
    if (start == 0) return 0;
    bool onOrBelow(double y) =>
        editable
            .getPositionForPoint(editable.localToGlobal(Offset(0, y + shift)))
            .offset >=
        start;
    final step = math.max(iso.bottom ?? iso.fullHeightAtStart, 1.0);
    var hi = float32(math.max((rect.top + rect.bottom) / 2 - shift, 0));
    if (!onOrBelow(hi)) return math.max(rect.top - shift, 0);
    var lo = math.max(hi - step, 0.0);
    for (var i = 0; lo > 0 && onOrBelow(lo) && i < 8; i++) {
      lo = math.max(lo - step, 0.0);
    }
    if (onOrBelow(lo)) return float32(lo);
    var loBits = _bitsOf(float32(lo));
    var hiBits = _bitsOf(hi);
    while (hiBits - loBits > 1) {
      final mid = loBits + (hiBits - loBits) ~/ 2;
      if (onOrBelow(_floatOf(mid))) {
        hiBits = mid;
      } else {
        loBits = mid;
      }
    }
    return _floatOf(hiBits);
  }

  /// The rect of [part] of [line]: its characters' x extent (the caret's x
  /// when they all render zero-width) and the line box's full height.
  Rect _spanOf(TextRange part, LineBox line, {required bool lastLine}) {
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: part.start, extentOffset: part.end),
    );
    final rect =
        unionOfBoxes(_withoutWidthPadding(boxes, lastLine: lastLine)) ??
        editable
                .getEndpointsForSelection(
                  TextSelection.collapsed(offset: part.start),
                )
                .first
                .point &
            Size.zero;
    return Rect.fromLTRB(rect.left, line.top, rect.right, line.bottom);
  }

  /// [boxes] without the boxes a [ui.BoxWidthStyle.max] field adds to pad a
  /// selection reaching a line's end out to the widest line (each starts
  /// where the box before it ends and reaches the rightmost edge); a last
  /// line gets none.
  List<TextBox> _withoutWidthPadding(
    List<TextBox> boxes, {
    required bool lastLine,
  }) {
    if (editable.selectionWidthStyle != ui.BoxWidthStyle.max ||
        lastLine ||
        boxes.length < 2) {
      return boxes;
    }
    final right = boxes.map((b) => b.right).reduce(math.max);
    return [
      for (final (i, b) in boxes.indexed)
        if (i == 0 ||
            b.direction != TextDirection.ltr ||
            b.left != boxes[i - 1].right ||
            b.right != right)
          b,
    ];
  }
}
