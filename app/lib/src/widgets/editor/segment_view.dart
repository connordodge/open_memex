import 'package:flutter/widgets.dart';

import 'line_boxes.dart';
import 'segment_editing.dart';

/// Builds a text segment's field; [boxes] reports the field's line boxes
/// once it is laid out (null before).
typedef SegmentFieldBuilder =
    Widget Function(BuildContext context, LineBoxSource? Function() boxes);

/// One text segment of the segmented editor (D5, TD12): today a single
/// field editing [controller] with [focusNode], built by [builder]. Its
/// State is the segment's [SegmentEditing] handle, found under the
/// segment's Key `text-segment-<i>`.
///
/// Text changes are reported by the field (its controller listener), so
/// [SegmentEditing.replaceText] reports through the same path as typing.
class SegmentView extends StatefulWidget {
  const SegmentView({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.builder,
  });

  /// The segment field's controller.
  final TextEditingController controller;

  /// The segment field's focus node.
  final FocusNode focusNode;

  final SegmentFieldBuilder builder;

  @override
  State<SegmentView> createState() => SegmentViewState();
}

/// The [SegmentEditing] handle over a [SegmentView]'s single field.
class SegmentViewState extends State<SegmentView> implements SegmentEditing {
  /// The field's line boxes, or null before it is laid out.
  LineBoxSource? lineBoxes() {
    final editable = findRenderEditable(context.findRenderObject());
    return editable != null && editable.hasSize
        ? RenderEditableLineBoxes(editable)
        : null;
  }

  @override
  String get text => widget.controller.text;

  @override
  TextSelection get selection => widget.controller.selection;

  @override
  int? get focusedRow => widget.focusNode.hasFocus ? 0 : null;

  @override
  int get rowCount => 1;

  @override
  Rect rectForOffset(int offset) {
    final boxes = lineBoxes()!;
    final local = boxes.caretRect(offset);
    return Rect.fromPoints(
      boxes.box.localToGlobal(local.topLeft),
      boxes.box.localToGlobal(local.bottomRight),
    );
  }

  @override
  void select(TextSelection selection) =>
      widget.controller.selection = selection;

  @override
  void replaceText(String text) => widget.controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  @override
  Widget build(BuildContext context) => widget.builder(context, lineBoxes);
}
