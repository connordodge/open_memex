import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'live_preview_frame.dart';
import 'marker_column.dart';

/// The marker column kind of an item row of [kind]; null for prose and code
/// rows.
MarkerColumnKind? markerColumnKind(RowKind kind) => switch (kind) {
  RowKind.bullet => MarkerColumnKind.bullet,
  RowKind.numbered => MarkerColumnKind.numbered,
  RowKind.task => MarkerColumnKind.task,
  RowKind.quote => MarkerColumnKind.quote,
  RowKind.prose || RowKind.code => null,
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
///
/// The field sits under Key `editor-row-<segment>-<index>` (D10) and paints
/// its selection in `OmColors.selection` also while it doesn't have focus.
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

  @override
  Widget build(BuildContext context) {
    final keyed = KeyedSubtree(
      key: ValueKey('editor-row-$segment-$index'),
      child: _UnfocusedSelection(
        controller: controller,
        focusNode: focusNode,
        child: field,
      ),
    );
    final item = geometry;
    final Widget row = switch (kind) {
      RowKind.prose => keyed,
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

/// Paints [controller]'s selection behind its field in `OmColors.selection`
/// while [focusNode] doesn't have focus (a focused field paints its own), so
/// every row shows its slice of a segment selection (TD5).
class _UnfocusedSelection extends SingleChildRenderObjectWidget {
  const _UnfocusedSelection({
    required this.controller,
    required this.focusNode,
    required super.child,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderUnfocusedSelection(controller, focusNode);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderUnfocusedSelection renderObject,
  ) => renderObject.watch(controller, focusNode);
}

class _RenderUnfocusedSelection extends RenderProxyBox {
  _RenderUnfocusedSelection(this._controller, this._focusNode);

  TextEditingController _controller;
  FocusNode _focusNode;

  Listenable get _changes => Listenable.merge([_controller, _focusNode]);

  void watch(TextEditingController controller, FocusNode focusNode) {
    if (identical(controller, _controller) &&
        identical(focusNode, _focusNode)) {
      return;
    }
    if (attached) _changes.removeListener(markNeedsPaint);
    _controller = controller;
    _focusNode = focusNode;
    if (attached) _changes.addListener(markNeedsPaint);
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
    final selection = _controller.selection;
    final editable = findRenderEditable(child);
    if (!_focusNode.hasFocus &&
        !selection.isCollapsed &&
        selection.isValid &&
        editable != null) {
      final at =
          offset +
          MatrixUtils.transformPoint(
            editable.getTransformTo(this),
            Offset.zero,
          );
      final paint = Paint()..color = OmColors.selection;
      for (final box in editable.getBoxesForSelection(selection)) {
        context.canvas.drawRect(box.toRect().shift(at), paint);
      }
    }
    super.paint(context, offset);
  }
}
