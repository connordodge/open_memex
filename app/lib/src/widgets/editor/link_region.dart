import 'package:flutter/widgets.dart';

import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// Link hit-testing over one field (D7): today a pass-through that renders
/// [child]. B3 owns its body (Cmd+hover cursor, Cmd+click), hit-testing the
/// field's text through [boxes].
class LinkRegion extends StatelessWidget {
  const LinkRegion({
    super.key,
    required this.controller,
    this.boxes,
    required this.child,
  });

  /// The field's controller.
  final LivePreviewController controller;

  /// The field's line boxes once laid out (null before layout).
  final LineBoxSource? Function()? boxes;

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
