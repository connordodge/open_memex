import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'live_preview_frame.dart';
import 'marker_column.dart';
import 'row_kinds.dart';
import 'segment_pointer_layer.dart'
    show NewlineMarkLine, newlineMarkWidth, newlineMarks;
import 'segment_view.dart';
import 'spell_squiggles.dart';
import 'table_grid.dart';

/// The marker column kind of an item row of [kind]; null for prose and code
/// rows.
MarkerColumnKind? markerColumnKind(RowKind kind) => switch (kind) {
  RowKind.bullet => MarkerColumnKind.bullet,
  RowKind.numbered => MarkerColumnKind.numbered,
  RowKind.task => MarkerColumnKind.task,
  RowKind.quote => MarkerColumnKind.quote,
  RowKind.prose || RowKind.code => null,
  RowKind.table || RowKind.attachment => null,
};

/// The horizontal geometry of each of [rows] (A2, Spec R11, R12), x relative
/// to the text column: an item row's marker column starts at 0, or at its
/// parent's unrevealed text x for a nested child; null for prose and code
/// rows.
List<ItemGeometry?> rowGeometries(List<RowSpec> rows) {
  final out = <ItemGeometry?>[];
  for (final row in rows) {
    final kind = markerColumnKind(row.kind);
    out.add(
      kind == null
          ? null
          : itemGeometry(
              markerX: switch (row.parent) {
                final parent? => out[parent]!.childMarkerX,
                null => 0,
              },
              kind: kind,
              numberDigits: row.runDigits,
            ),
    );
  }
  return out;
}

/// One editor row of text segment [segment] (Spec R9, R10): the body the
/// presenter of its [kind] builds (`presenterFor`, WI #124 ruling D2) around
/// the row's text slot (its [field]), wrapped in a `LivePreviewFrame` of its
/// [controller]. The built-in presenters lay rows out as follows.
///
/// - An item row (bullet, numbered, task, quote) puts a [MarkerColumn]
///   (Key `editor-row-marker-<segment>-<index>`) of [geometry]'s width at its
///   marker x, then the field from the item's text x to the text column's
///   right edge (a quote keeps one column of right padding), so every
///   wrapped line of the item starts at its text x (hanging indent).
/// - A prose row's field spans the text column.
/// - A code row's field is inset 16.2 px left and 10 px right (A2).
/// - A table row (Spec #197 R12, TD4, ruling D12) spans the text column.
///   While its controller is not `tableRevealed` it shows a [TableGrid]
///   (Key `editor-table-<segment>-<index>`, under [gridKey]) and keeps its
///   field mounted under its key inside an `Offstage`, so the field's
///   controller, focus node and text input connection survive, it is not
///   painted, hit or read by semantics (R26); revealed, the field shows and
///   the grid is gone.
///
/// The field sits under Key `editor-row-<segment>-<index>` (D10). Inside a
/// segment that Key names the row's index in the segment now (Spec #122
/// R19): a row the rows host moves to another index keeps its field
/// subtree, which the Key's thin wrapper ([_IndexKeyed]) does not recreate.
/// The row paints its part of the segment selection as one block behind
/// the field, focused or not ([_RowSelection]), and its spelling squiggles
/// and hint over it ([SpellSquiggles], WI #437).
class EditorRow extends StatelessWidget {
  /// Test-only work counter: how many times any editor row built.
  @visibleForTesting
  static int debugBuilds = 0;

  const EditorRow({
    super.key,
    required this.segment,
    required this.index,
    required this.kind,
    required this.geometry,
    required this.marker,
    required this.controller,
    required this.focusNode,
    required this.boxes,
    required this.field,
    this.gridKey,
  });

  /// The text segment's index (`<s>` of `text-segment-<s>`).
  final int segment;

  /// The row's index in its segment.
  final int index;

  final RowKind kind;

  /// The item row's marker column geometry; null for prose and code rows.
  final ItemGeometry? geometry;

  /// The item row's marker source text.
  final String marker;

  /// The row field's controller.
  final LivePreviewController controller;

  /// The row field's focus node.
  final FocusNode focusNode;

  /// The row field's line boxes once laid out.
  final LineBoxSource? Function() boxes;

  /// The row's field.
  final Widget field;

  /// The key of the subtree holding the row's block while it shows (a table
  /// row's [TableGrid], an attachment's image or card), the presenter's
  /// `PresentedRow.blockKey`, so the host finds it; null for a row pumped
  /// alone.
  final GlobalKey? gridKey;

  @override
  Widget build(BuildContext context) {
    debugBuilds++;
    final host = context.findAncestorStateOfType<SegmentViewState>();
    Widget keyedField(Widget child) => _IndexKeyed(
      segment: segment,
      index: index,
      controller: controller,
      host: host,
      child: _RowSelection(
        controller: controller,
        index: index,
        host: host,
        child: SpellSquiggles(
          controller: controller,
          host: host,
          index: index,
          child: child,
        ),
      ),
    );
    final presenter = presenterFor(kind);
    // A row whose presenter may hide its text keeps its field under an
    // Offstage, so hiding or showing the text never reparents the field.
    final hides = presenter is! TextRowPresenter;
    final row = presenter.build(
      context,
      PresentedRow(
        segment: segment,
        index: index,
        kind: kind,
        controller: controller,
        geometry: geometry,
        marker: marker,
        blockKey: gridKey,
      ),
      ({required bool offstage}) => keyedField(
        offstage || hides ? Offstage(offstage: offstage, child: field) : field,
      ),
    );
    return LivePreviewFrame(controller: controller, boxes: boxes, child: row);
  }
}

/// The row field's index Key `editor-row-<segment>-<index>` (D10) over
/// [child]. Inside a segment the Key is read from [host] whenever it is
/// asked for, so it names the row's segment and index now: the old and the
/// new wrapper of a row that moved to another index carry equal Keys, and
/// the row's field subtree below is updated in place, never recreated or
/// reparented. A row pumped alone keeps [segment] and [index].
class _IndexKeyed extends StatelessWidget {
  const _IndexKeyed({
    required this.segment,
    required this.index,
    required this.controller,
    required this.host,
    required this.child,
  });

  final int segment;
  final int index;
  final TextEditingController controller;
  final SegmentViewState? host;
  final Widget child;

  @override
  Key get key {
    final host = this.host;
    final now = host != null && host.mounted
        ? host.rowIndexOf(controller)
        : null;
    return ValueKey<String>(
      now == null
          ? 'editor-row-$segment-$index'
          : 'editor-row-${host!.widget.index}-$now',
    );
  }

  @override
  Widget build(BuildContext context) => child;
}

/// Paints the row's part of the segment selection behind its field in
/// `OmColors.selection`, as one block: each selected line is one rect from
/// its first to its last selected character, the line box's full height,
/// plus one mono column where the line's line break is selected (a selected
/// blank line is that column). Lines of one selection touch, also across
/// rows, and no two rects overlap, so the fill never doubles up. The field
/// itself paints no selection (`TextSegmentField`).
///
/// It repaints when its row's controller notifies, when where the segment
/// selection meets the row's edges changes (the host's `rowEdgesOf`), and
/// on a reveal gate change only while it has a selection to fill (Spec #122
/// R17a): another row's selection change repaints nothing here.
class _RowSelection extends SingleChildRenderObjectWidget {
  const _RowSelection({
    required this.controller,
    required this.index,
    required this.host,
    required super.child,
  });

  final TextEditingController controller;
  final int index;

  /// The segment the row belongs to; null outside one (a row pumped alone).
  final SegmentViewState? host;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRowSelection(controller, index, host);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRowSelection renderObject,
  ) => renderObject.watch(controller, index, host);
}

/// Test-only work counter: how many times any editor row painted its
/// selection block.
@visibleForTesting
int debugEditorRowSelectionPaints = 0;

class _RenderRowSelection extends RenderProxyBox {
  _RenderRowSelection(this._controller, this._index, this._host)
    : _edges = _host?.rowEdgesOf(_controller),
      _gate = _host?.widget.revealGate;

  TextEditingController _controller;
  int _index;
  SegmentViewState? _host;

  /// Where the segment selection meets the row's edges.
  Listenable? _edges;

  /// Revealing or hiding markers moves line ends.
  Listenable? _gate;

  void watch(
    TextEditingController controller,
    int index,
    SegmentViewState? host,
  ) {
    final edges = host?.rowEdgesOf(controller);
    final gate = host?.widget.revealGate;
    if (identical(controller, _controller) &&
        index == _index &&
        identical(host, _host) &&
        identical(edges, _edges) &&
        identical(gate, _gate)) {
      return;
    }
    if (attached) _unlisten();
    _controller = controller;
    _index = index;
    _host = host;
    _edges = edges;
    _gate = gate;
    if (attached) _listen();
    markNeedsPaint();
  }

  void _listen() {
    _controller.addListener(markNeedsPaint);
    _edges?.addListener(markNeedsPaint);
    _gate?.addListener(_gateChanged);
  }

  void _unlisten() {
    _controller.removeListener(markNeedsPaint);
    _edges?.removeListener(markNeedsPaint);
    _gate?.removeListener(_gateChanged);
  }

  /// A reveal gate change moves line ends; only a row with a selection to
  /// fill (its own slice, or the line break after it) shows that.
  void _gateChanged() {
    final local = _controller.selection;
    final host = _host;
    final spec = host?.rowSpec(_index);
    final segment = host?.selection;
    final rowBreak =
        spec != null &&
        segment != null &&
        segment.isValid &&
        !segment.isCollapsed &&
        segment.start <= spec.textEnd &&
        spec.textEnd < segment.end;
    if ((local.isValid && !local.isCollapsed) || rowBreak) markNeedsPaint();
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
    debugEditorRowSelectionPaints++;
    // One rect per line; lines never overlap, so the fill never doubles.
    final paint = Paint()..color = OmColors.selection;
    for (final rect in _selectionRects()) {
      context.canvas.drawRect(rect.shift(offset), paint);
    }
    super.paint(context, offset);
  }

  /// The row's selection fill in this box's coordinates.
  List<Rect> _selectionRects() {
    // A rendered table's grid shows no selection (Spec #197 R16).
    final controller = _controller;
    if (controller is LivePreviewController && controller.textHidden) {
      return const [];
    }
    // The row's text through the row-geometry accessor (WI #127): its
    // field's or a RichText's standing in for it; a row pumped alone
    // measures the text under it.
    final host = _host;
    final boxes = host?.rowBoxes(_index) ?? textSlotBoxes(child);
    if (boxes == null) return const [];
    final rowText = controller.text;
    // A field still laid out with another text than its row's (main's
    // check); a RichText slot's laid-out length is checked below.
    if (boxes is RenderEditableLineBoxes &&
        boxes.editable.plainText != rowText) {
      return const [];
    }
    final length = rowText.length;

    // Where the segment selection meets the row's edges.
    final spec = host?.rowSpec(_index);
    var breakAfter = false; // a line break follows the row
    var rowBreak = false; // ... and the selection holds it
    var fromAbove = false; // the selection holds the line break above
    if (host != null && spec != null) {
      final segment = host.selection;
      final text = host.text;
      final end = spec.textEnd;
      breakAfter = end < text.length && _isTerminator(text.codeUnitAt(end));
      if (segment.isValid && !segment.isCollapsed) {
        rowBreak = breakAfter && segment.start <= end && end < segment.end;
        fromAbove = segment.start < spec.start && spec.start <= segment.end;
      }
    }

    // The selected range in row offsets; past the text's end when the row's
    // line break is selected.
    final local = controller.selection;
    var start = -1;
    var end = -1;
    if (local.isValid && !local.isCollapsed) {
      start = local.start.clamp(0, length);
      end = local.end.clamp(0, length);
    }
    if (rowBreak) {
      if (start < 0) start = length;
      end = length + 1;
    }
    if (start < 0 || start >= end) return const [];

    // Only the row's own text as laid out now (a field's text was compared
    // above): the last line ends at the text's end and none starts after
    // it. Read line by line, never a walk of every line (WI #126).
    if (boxes is! RenderEditableLineBoxes &&
        (boxes.lineAt(length).range.end != length ||
            boxes.lineAt(length + 1).range.start > length)) {
      return const [];
    }
    final chars = start < math.min(end, length)
        ? boxes.boxesFor(TextRange(start: start, end: math.min(end, length)))
        : const <Rect>[];
    final mdLines = controller is LivePreviewController && controller.itemText
        ? const <MdLine>[]
        : host?.rowLinesOf(controller) ??
              classifyLines(rowText, atSegmentStart: spec?.textStart == 0);

    final out = <Rect>[];
    var firstLine = false;
    var lastLine = false;
    // The row's first line, where a selection from above closes its seam.
    final first = fromAbove ? boxes.lineAt(0) : null;
    // Only the lines the selection reaches: from the one holding its start
    // to the last one starting before its end.
    LineBox? next = boxes.lineAt(start);
    while (next != null && next.range.start < end) {
      final line = next;
      next = _nextLine(boxes, line, length);
      final last = next == null;
      Rect? rect;
      for (final c in chars) {
        // Two measurements of one line may differ by a fraction of a pixel.
        final y = c.center.dy;
        if (y >= line.top && y < line.bottom) {
          rect = rect?.expandToInclude(c) ?? c;
        }
      }
      final lineEnd = line.range.end;
      final breaks = last
          ? breakAfter
          : lineEnd < length && _isTerminator(rowText.codeUnitAt(lineEnd));
      if (breaks && start <= lineEnd && lineEnd < end) {
        final endX = switch (rect) {
          final r? => r.right,
          null when line.range.isCollapsed => 0.0,
          null => boxes.boxesFor(line.range).last.right,
        };
        final mark = newlineMarks([
          NewlineMarkLine(
            end: lineEnd,
            breaks: true,
            top: line.top,
            bottom: line.bottom,
            endX: endX,
            columnWidth: newlineMarkWidth(
              _headingLevel(mdLines, line.range.start),
            ),
          ),
        ], TextRange(start: start, end: end));
        for (final m in mark) {
          rect = rect?.expandToInclude(m) ?? m;
        }
      }
      if (rect == null) continue;
      // Each line runs to the next line's top: measured line boxes can
      // leave a pixel between lines of different heights (a blank line
      // above a heading), which would show as a seam.
      final bottom = next?.top ?? line.bottom;
      out.add(Rect.fromLTRB(rect.left, line.top, rect.right, bottom));
      if (line.range.start == first?.range.start) firstLine = true;
      if (last) lastLine = true;
    }
    if (out.isEmpty) return const [];

    // Into this box's coordinates; close the seams to the rows above and
    // below the selection runs on into.
    final at = MatrixUtils.transformPoint(
      boxes.box.getTransformTo(this),
      Offset.zero,
    );
    final shifted = [for (final r in out) r.shift(at)];
    if (fromAbove && firstLine) {
      final r = shifted.first;
      shifted.first = Rect.fromLTRB(r.left, 0, r.right, r.bottom);
    }
    if (rowBreak && lastLine) {
      final r = shifted.last;
      shifted.last = Rect.fromLTRB(r.left, r.top, r.right, size.height);
    }
    return shifted;
  }

  /// The line after [line] in [boxes], a row of [length] characters: the
  /// first one starting after [line]'s start, at its end (a wrap) or after
  /// its line break; null for the last line.
  static LineBox? _nextLine(LineBoxSource boxes, LineBox line, int length) {
    for (var offset = line.range.end; offset <= length; offset++) {
      final next = boxes.lineAt(offset);
      if (next.range.start > line.range.start) return next;
    }
    return null;
  }

  /// The heading level of the source line holding row-local [offset], null
  /// when it isn't a heading.
  static int? _headingLevel(List<MdLine> lines, int offset) {
    for (final line in lines) {
      if (offset < line.end || line.terminator.isEmpty) {
        return line.kind == MdLineKind.heading ? line.level : null;
      }
    }
    return null;
  }

  static bool _isTerminator(int unit) => unit == 0x0A || unit == 0x0D;
}
