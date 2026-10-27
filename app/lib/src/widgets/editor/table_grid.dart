import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// The rendered face of a table row (Spec #197 R12, R17; TD4; ruling D12,
/// API frozen): drawn in the row field's place while the table is not
/// revealed. The field stays mounted offstage.
///
/// - [text] is the table row's text (its field's text).
/// - [style] is the editor body style.
/// - [links] is the row's controller, whose link state (`isResolved`,
///   `cmdHover`) cells read; null in excerpt cards.
/// - [headerBand] is the header band's colour (`surface4` in cards).
///
/// T3's stub body is one `RichText(buildLivePreviewSpan(text, forceHidden:
/// true))` measured through `RenderParagraphLineBoxes`; T4 replaces only the
/// body.
class TableGrid extends StatefulWidget {
  const TableGrid({
    super.key,
    required this.text,
    required this.style,
    this.links,
    this.headerBand = OmColors.surface3,
  });

  final String text;
  final TextStyle style;
  final LivePreviewController? links;
  final Color headerBand;

  @override
  State<TableGrid> createState() => TableGridState();
}

/// The [TableGrid]'s state: its line-box seam in the table row's field text
/// offsets (TD5, ruling D13).
class TableGridState extends State<TableGrid> {
  /// The grid's line boxes once laid out, in the row's field text offsets
  /// (box = the grid's render box); null before layout.
  // TODO(#204): skeleton only; the implementer gives it behaviour.
  LineBoxSource? lineBoxes() => throw UnimplementedError('#204 lineBoxes');

  @override
  // TODO(#204): skeleton only; the implementer gives it behaviour.
  Widget build(BuildContext context) =>
      throw UnimplementedError('#204 TableGrid');
}
