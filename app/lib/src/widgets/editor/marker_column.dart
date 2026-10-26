import 'package:flutter/widgets.dart';

import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The marker column of one item row (Spec R11): a fixed [width] (A2's
/// marker column width) one item line tall, showing the row's marker source
/// text [marker] (`- `, `12. `, `- [ ] `, `> `) in `fg2`.
///
/// It joins the row fields' `TextFieldTapRegion` group (D11), so a click on
/// it does not unfocus the row's field. C1b owns its body (painted glyphs,
/// reveal, checkbox).
class MarkerColumn extends StatelessWidget {
  const MarkerColumn({super.key, required this.marker, required this.width});

  /// The marker's source text, without the row's indentation.
  final String marker;

  /// The column's width in px.
  final double width;

  @override
  Widget build(BuildContext context) {
    final line = lineHeight(LineHeightKind.item);
    return TextFieldTapRegion(
      child: SizedBox(
        width: width,
        height: line,
        child: Text(
          marker,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: OmType.mono(
            size: monoFontSize,
            color: OmColors.fg2,
            height: line / monoFontSize,
          ),
        ),
      ),
    );
  }
}
