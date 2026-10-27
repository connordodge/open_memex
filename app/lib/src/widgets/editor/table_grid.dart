import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'live_preview_styles.dart';
import 'paragraph_line_boxes.dart';

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
  final _textKey = GlobalKey(debugLabel: 'table-grid-text');

  /// False while the grid is out of the tree (its row was revealed and the
  /// frame has not finished): it has no line boxes then.
  bool _active = true;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  /// The grid's line boxes once laid out, in the row's field text offsets
  /// (box = the grid's render box); null before layout.
  LineBoxSource? lineBoxes() =>
      switch (_active ? _textKey.currentContext?.findRenderObject() : null) {
        final RenderParagraph p when p.attached && p.hasSize =>
          RenderParagraphLineBoxes(p),
        _ => null,
      };

  @override
  Widget build(BuildContext context) => RichText(
    key: _textKey,
    textScaler: MediaQuery.textScalerOf(context),
    // As the row field's EditableText does with its strut.
    strutStyle: livePreviewStrut().inheritFromTextStyle(widget.style),
    text: buildLivePreviewSpan(
      widget.text,
      style: widget.style,
      forceHidden: true,
      isResolved: widget.links?.isResolved,
    ),
  );
}
