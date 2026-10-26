import 'package:flutter/widgets.dart';

import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// Live preview's painted decorations around one field (D7): today a
/// pass-through that renders [child]. B2 owns its body (code box, quote
/// band, rule, pill), drawn from [boxes] and never left of [textLeft].
class LivePreviewDecorations extends StatelessWidget {
  const LivePreviewDecorations({
    super.key,
    required this.controller,
    this.boxes,
    this.textLeft = 0,
    required this.child,
  });

  /// The decorated field's controller.
  final LivePreviewController controller;

  /// The field's line boxes once laid out (null before layout).
  final LineBoxSource? Function()? boxes;

  /// Where the field's text column starts, in this widget's coordinates.
  final double textLeft;

  final Widget child;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
