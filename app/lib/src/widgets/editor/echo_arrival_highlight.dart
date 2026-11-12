import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/byte_offsets.dart';
import '../../editor/editor_rows.dart';
import '../../editor/segments.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';

// Open-at-passage (Spec #391 req 27, WI #428): where an opened echo lands in
// the segmented editor, and the brief background highlight shown there.
// Its own widget (ruling D23): no hook in the #392 editor files, whose row
// keys and line boxes it only reads.

/// Where an echo's passage sits in the segmented editor: the widget holding
/// it and, for a text row, the row's text and the passage's offset in it.
class EchoArrival {
  const EchoArrival._({
    required this.key,
    required this.segment,
    this.fallbackKey,
    this.kind,
    this.rowText = '',
    this.local = 0,
  });

  /// The key of the editor widget holding the passage (see
  /// [echoArrivalRowKey]).
  final Key key;

  /// A table row's field key (`editor-row-<s>-<r>`), shown instead of its
  /// grid while the caret is inside the table. Null for other rows.
  final Key? fallbackKey;

  /// The segment index (`<s>` of the key).
  final int segment;

  /// The row's kind; null for an excerpt card.
  final RowKind? kind;

  /// The text the row's field holds.
  final String rowText;

  /// The passage's UTF-16 offset in [rowText].
  final int local;
}

/// The key of the segmented editor's widget holding [startByte] (a UTF-8
/// byte offset into [contentMd], the note's stored body) for a note of
/// [role]:
/// - a row: `ValueKey('editor-row-<segment>-<row>')`;
/// - a table row: `ValueKey('editor-table-<segment>-<row>')`;
/// - an excerpt card: `Key('excerpt-card-<segment>')`.
///
/// Segments and rows are the ones the editor builds (`split`, `splitRows`).
/// Null when [startByte] is null, fails `utf8ToUtf16` against [contentMd], or
/// lies past the editor's last row (the Note footer, or the body's end).
Key? echoArrivalRowKey(String contentMd, int? startByte, {String? role}) =>
    locateEchoArrival(contentMd, startByte, role: role)?.key;

/// [echoArrivalRowKey] with the row's text and the passage's offset in it.
EchoArrival? locateEchoArrival(
  String contentMd,
  int? startByte, {
  String? role,
}) {
  if (startByte == null) return null;
  final int offset;
  try {
    offset = utf8ToUtf16(contentMd, startByte);
  } on ArgumentError {
    return null;
  }
  final daily = role == 'daily';
  final segments = split(
    contentMd,
    isDaily: daily,
    noteFooter: role != 'guide',
  );
  var at = 0;
  for (var s = 0; s < segments.length; s++) {
    switch (segments[s]) {
      case TextSegment(:final text):
        // A daily person section can end in stray text moved from below the
        // marker: only its prefix shared with the body is at body offsets.
        final limit = daily ? _sharedPrefix(text, contentMd) : text.length;
        if (offset < at + limit) return _inText(text, s, offset - at);
        at += text.length;
      case TransclusionSegment(:final raw):
        if (offset < at + raw.length) {
          return EchoArrival._(key: Key('excerpt-card-$s'), segment: s);
        }
        at += raw.length;
      case FooterSegment():
        return null;
    }
  }
  return null;
}

EchoArrival? _inText(String text, int segment, int offset) {
  final rows = splitRows(text, atSegmentStart: true);
  for (var r = 0; r < rows.length; r++) {
    final spec = rows[r];
    if (spec.start > offset || offset >= spec.end) continue;
    final rowKey = ValueKey('editor-row-$segment-$r');
    final table = spec.kind == RowKind.table;
    return EchoArrival._(
      key: table ? ValueKey('editor-table-$segment-$r') : rowKey,
      fallbackKey: table ? rowKey : null,
      segment: segment,
      kind: spec.kind,
      rowText: text.substring(spec.textStart, spec.textEnd),
      local: spec.toLocal(offset),
    );
  }
  return null;
}

int _sharedPrefix(String a, String b) {
  final n = math.min(a.length, b.length);
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

/// Where the arrival lands in [row]'s local coordinates (the render box of
/// the widget keyed [EchoArrival.key]):
/// - [band] is what the highlight covers: the whole row, card or table row,
///   or, inside a prose row, the passage: from the visual line holding the
///   offset to the end of its blank-line-delimited block (lead ruling Q1);
/// - [anchor] is what scrolls to a third of the viewport: the band, or the
///   visual line holding the offset inside a prose row.
///
/// The band spans [column] horizontally when given (the row's text segment,
/// so an item row's marker is covered too).
({Rect band, Rect anchor}) echoArrivalRects(
  RenderBox row,
  EchoArrival arrival, {
  RenderBox? column,
}) {
  final size = row.size;
  var left = 0.0;
  var right = size.width;
  if (column != null && column.attached && column.hasSize) {
    final origin = row.globalToLocal(column.localToGlobal(Offset.zero));
    left = math.min(left, origin.dx);
    right = math.max(right, origin.dx + column.size.width);
  }
  final whole = Rect.fromLTRB(left, 0, right, size.height);
  if (arrival.kind != RowKind.prose) return (band: whole, anchor: whole);
  final editable = findRenderEditable(row);
  if (editable == null ||
      !editable.hasSize ||
      editable.plainText != arrival.rowText) {
    return (band: whole, anchor: whole);
  }
  final lines = RenderEditableLineBoxes(editable).lines;
  if (lines.isEmpty) return (band: whole, anchor: whole);
  final block = _passageBlock(arrival.rowText, arrival.local);
  final first = lineHolding(lines, block.start);
  final last = lineHolding(lines, block.end);
  double y(double editableY) =>
      row.globalToLocal(editable.localToGlobal(Offset(0, editableY))).dy;
  final top = identical(first, lines.first) ? 0.0 : y(first.top);
  final bottom = identical(last, lines.last) ? size.height : y(last.bottom);
  final firstBottom = identical(first, lines.last)
      ? size.height
      : y(first.bottom);
  return (
    band: Rect.fromLTRB(left, top, right, math.max(top, bottom)),
    anchor: Rect.fromLTRB(left, top, right, math.max(top, firstBottom)),
  );
}

/// The passage in [text] holding [offset]: from the start of [offset]'s
/// source line (the next non-blank line when that one is blank) to the end
/// of the last line before the next blank line or the text's end.
TextRange _passageBlock(String text, int offset) {
  int lineStart(int at) => at <= 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
  int lineEnd(int start) {
    final newline = text.indexOf('\n', start);
    return newline < 0 ? text.length : newline;
  }

  bool blank(int start) => text.substring(start, lineEnd(start)).trim().isEmpty;

  var start = lineStart(math.min(offset, text.length));
  final from = start;
  while (blank(start) && lineEnd(start) < text.length) {
    start = lineEnd(start) + 1;
  }
  if (blank(start)) start = from;
  var end = lineEnd(start);
  while (end < text.length && !blank(end + 1)) {
    end = lineEnd(end + 1);
  }
  return TextRange(start: start, end: end);
}

/// The arrival highlight over [band] of [target]: `OmColors.accent` at 12%
/// opacity, fading out linearly over [duration], then [onDone] (the owner
/// removes it from the tree). It follows [target] as it scrolls, clipped to
/// [clip] (the editor's viewport), and takes no pointer events.
class EchoArrivalHighlight extends StatefulWidget {
  const EchoArrivalHighlight({
    super.key,
    required this.target,
    required this.band,
    this.clip,
    this.repaint,
    required this.onDone,
  });

  /// How long the highlight fades out for.
  static const duration = Duration(milliseconds: 1200);

  /// The highlight's opacity when it appears.
  static const opacity = 0.12;

  /// The row, card or table row the highlight covers part of.
  final RenderBox target;

  /// The highlighted rect in [target]'s local coordinates.
  final Rect band;

  /// The box the highlight is clipped to; null for no clip.
  final RenderBox? clip;

  /// Repaints the highlight when it fires (the editor's scroll).
  final Listenable? repaint;

  final VoidCallback onDone;

  @override
  State<EchoArrivalHighlight> createState() => _EchoArrivalHighlightState();
}

class _EchoArrivalHighlightState extends State<EchoArrivalHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: EchoArrivalHighlight.duration,
  );

  @override
  void initState() {
    super.initState();
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
    _fade.forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _fade,
      builder: (context, _) => _HighlightPaint(
        target: widget.target,
        band: widget.band,
        clip: widget.clip,
        repaint: widget.repaint,
        color: OmColors.accent.withValues(
          alpha: EchoArrivalHighlight.opacity * (1 - _fade.value),
        ),
      ),
    ),
  );
}

class _HighlightPaint extends LeafRenderObjectWidget {
  const _HighlightPaint({
    required this.target,
    required this.band,
    required this.clip,
    required this.repaint,
    required this.color,
  });

  final RenderBox target;
  final Rect band;
  final RenderBox? clip;
  final Listenable? repaint;
  final Color color;

  @override
  _RenderHighlight createRenderObject(BuildContext context) =>
      _RenderHighlight(target, band, clip, repaint, color);

  @override
  void updateRenderObject(BuildContext context, _RenderHighlight render) =>
      render
        ..target = target
        ..band = band
        ..clip = clip
        ..repaint = repaint
        ..color = color;
}

class _RenderHighlight extends RenderBox {
  _RenderHighlight(
    this._target,
    this._band,
    this._clip,
    this._repaint,
    this._color,
  );

  RenderBox _target;
  set target(RenderBox value) {
    if (identical(value, _target)) return;
    _target = value;
    markNeedsPaint();
  }

  Rect _band;
  set band(Rect value) {
    if (value == _band) return;
    _band = value;
    markNeedsPaint();
  }

  RenderBox? _clip;
  set clip(RenderBox? value) {
    if (identical(value, _clip)) return;
    _clip = value;
    markNeedsPaint();
  }

  Listenable? _repaint;
  set repaint(Listenable? value) {
    if (identical(value, _repaint)) return;
    if (attached) _repaint?.removeListener(markNeedsPaint);
    _repaint = value;
    if (attached) _repaint?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  /// [box]'s [rect] in this box's local coordinates.
  Rect _local(RenderBox box, Rect rect) => MatrixUtils.transformRect(
    box.getTransformTo(null),
    rect,
  ).shift(-localToGlobal(Offset.zero));

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = _target;
    if (!target.attached || !target.hasSize || _color.a == 0) return;
    var rect = _local(target, _band);
    final clip = _clip;
    if (clip != null) {
      if (!clip.attached || !clip.hasSize) return;
      rect = rect.intersect(_local(clip, Offset.zero & clip.size));
    }
    if (rect.isEmpty) return;
    context.canvas.drawRect(rect.shift(offset), Paint()..color = _color);
  }
}
