import 'package:flutter/widgets.dart';

import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// Wraps every live preview field (D7): composes `LivePreviewDecorations`
/// and `LinkRegion` around [child], handing both the field's [controller]
/// and its line [boxes], and decorations [textLeft].
class LivePreviewFrame extends StatelessWidget {
  const LivePreviewFrame({
    super.key,
    required this.controller,
    this.boxes,
    this.textLeft = 0,
    required this.child,
  });

  /// The wrapped field's controller.
  final LivePreviewController controller;

  /// The wrapped field's line boxes once laid out (null before layout).
  final LineBoxSource? Function()? boxes;

  /// Where the field's text column starts, in this frame's coordinates.
  final double textLeft;

  /// The field.
  final Widget child;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
