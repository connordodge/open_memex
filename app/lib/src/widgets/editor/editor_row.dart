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
import 'segment_pointer_layer.dart'
    show NewlineMarkLine, newlineMarkWidth, newlineMarks;
import 'segment_view.dart';
import 'table_grid.dart';
import 'text_segment.dart';

/// The marker column kind of an item row of [kind]; null for prose and code
/// rows.
MarkerColumnKind? markerColumnKind(RowKind kind) => switch (kind) {
  RowKind.bullet => MarkerColumnKind.bullet,
  RowKind.numbered => MarkerColumnKind.numbered,
  RowKind.task => MarkerColumnKind.task,
  RowKind.quote => MarkerColumnKind.quote,
  RowKind.prose || RowKind.code => null,
  RowKind.table => null,
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

/// One editor row of text segment [segment] (Spec R9, R10): the row's
/// [field] wrapped in a `LivePreviewFrame` of its [controller].
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
/// The field sits under Key `editor-row-<segment>-<index>` (D10). The row
/// paints its part of the segment selection as one block behind the field,
/// focused or not ([_RowSelection]).
class EditorRow extends StatelessWidget {
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

  /// The key of the subtree holding a table row's [TableGrid] while it
  /// shows, so the host finds the grid's state; null for other rows.
  final GlobalKey? gridKey;

  @override
  Widget build(BuildContext context) {
    Widget keyedField(Widget child) => KeyedSubtree(
      key: ValueKey('editor-row-$segment-$index'),
      child: _RowSelection(
        controller: controller,
        index: index,
        host: context.findAncestorStateOfType<SegmentViewState>(),
        child: child,
      ),
    );
    final keyed = keyedField(field);
    final item = geometry;
    final Widget row = switch (kind) {
      RowKind.prose => keyed,
      RowKind.table => ListenableBuilder(
        listenable: Listenable.merge([controller, controller.revealGate]),
        builder: (context, _) {
          final revealed = controller.tableRevealed;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              keyedField(Offstage(offstage: !revealed, child: field)),
              if (!revealed)
                KeyedSubtree(
                  key: gridKey,
                  child: TableGrid(
                    key: ValueKey('editor-table-$segment-$index'),
                    text: controller.text,
                    style: editorBodyStyle(),
                    links: controller,
                  ),
                ),
            ],
          );
        },
      ),
      RowKind.code => Padding(
        padding: EdgeInsets.only(
          left: codeTextInsetLeft,
          right: codeTextInsetRight,
        ),
        child: keyed,
      ),
      _ => Padding(
        padding: EdgeInsets.only(left: item!.markerX),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyedSubtree(
              key: ValueKey('editor-row-marker-$segment-$index'),
              child: MarkerColumn(marker: marker, width: item.columnWidth),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: itemTextRightInset(markerColumnKind(kind)!),
                ),
                child: keyed,
              ),
            ),
          ],
        ),
      ),
    };
    return LivePreviewFrame(controller: controller, boxes: boxes, child: row);
  }
}

/// Paints the row's part of the segment selection behind its field in
/// `OmColors.selection`, as one block: each selected line is one rect from
/// its first to its last selected character, the line box's full height,
/// plus one mono column where the line's line break is selected (a selected
/// blank line is that column). Lines of one selection touch, also across
/// rows, and no two rects overlap, so the fill never doubles up. The field
/// itself paints no selection (`TextSegmentField`).
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

class _RenderRowSelection extends RenderProxyBox {
  _RenderRowSelection(this._controller, this._index, this._host)
    : _segment = _host?.widget.controller,
      _gate = _host?.widget.revealGate;

  TextEditingController _controller;
  int _index;
  SegmentViewState? _host;
  TextEditingController? _segment;

  /// Revealing or hiding markers moves line ends.
  Listenable? _gate;

  Listenable get _changes => Listenable.merge([
    _controller,
    if (_segment != null) _segment,
    if (_gate != null) _gate,
  ]);

  void watch(
    TextEditingController controller,
    int index,
    SegmentViewState? host,
  ) {
    if (attached) _changes.removeListener(markNeedsPaint);
    _controller = controller;
    _index = index;
    _host = host;
    _segment = host?.widget.controller;
    _gate = host?.widget.revealGate;
    if (attached) _changes.addListener(markNeedsPaint);
    // The rows were rebuilt: their line ends may have moved.
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _changes.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _changes.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
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
    if (controller is LivePreviewController &&
        controller.tableRow &&
        !controller.tableRevealed) {
      return const [];
    }
    final editable = findRenderEditable(child);
    if (editable == null || !editable.hasSize) return const [];
    final rowText = controller.text;
    if (editable.plainText != rowText) return const [];
    final length = rowText.length;

    // Where the segment selection meets the row's edges.
    final host = _host;
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

    final boxes = RenderEditableLineBoxes(editable);
    final lines = boxes.lines;
    if (lines.isEmpty) return const [];
    final chars = start < math.min(end, length)
        ? boxes.boxesFor(TextRange(start: start, end: math.min(end, length)))
        : const <Rect>[];
    final mdLines = controller is LivePreviewController && controller.itemText
        ? const <MdLine>[]
        : classifyLines(rowText, atSegmentStart: spec?.textStart == 0);

    final out = <Rect>[];
    var firstLine = false;
    var lastLine = false;
    for (final (i, line) in lines.indexed) {
      Rect? rect;
      for (final c in chars) {
        // Two measurements of one line may differ by a fraction of a pixel.
        final y = c.center.dy;
        if (y >= line.top && y < line.bottom) {
          rect = rect?.expandToInclude(c) ?? c;
        }
      }
      final last = i == lines.length - 1;
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
      final bottom = last ? line.bottom : lines[i + 1].top;
      out.add(Rect.fromLTRB(rect.left, line.top, rect.right, bottom));
      if (i == 0) firstLine = true;
      if (last) lastLine = true;
    }
    if (out.isEmpty) return const [];

    // Into this box's coordinates; close the seams to the rows above and
    // below the selection runs on into.
    final at = MatrixUtils.transformPoint(
      editable.getTransformTo(this),
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
