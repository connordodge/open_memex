import 'package:flutter/widgets.dart';

import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// A painted bullet dot (TD10) in the marker column's coordinates (origin at
/// the column's top-left, the column one item line tall).
///
/// - [filled]: a level-1 bullet's disc of [radius], no stroke
///   ([strokeWidth] 0);
/// - not [filled]: a level-2+ bullet's ring, stroked [strokeWidth] wide
///   around [radius] (the stroke's centre line).
typedef MarkerDot = ({
  Offset center,
  double radius,
  double strokeWidth,
  bool filled,
});

/// A task's painted circle (TD10) in the marker column's coordinates:
/// [bounds] is the 14 px circle's box; its ring is [ringWidth] wide, drawn
/// inside [bounds].
typedef MarkerTaskCircle = ({Rect bounds, double ringWidth});

/// A done task's check (TD10) in the marker column's coordinates: a
/// polyline through [points], stroked [strokeWidth] wide with round caps and
/// joins.
typedef MarkerTaskCheck = ({List<Offset> points, double strokeWidth});

/// The painted dot of a bullet at nesting [level] (1 for a top-level item,
/// 2 for its child, ...): pack #168's filled dot at level 1, hollow ring at
/// level 2 and deeper.
MarkerDot markerBulletDot({required int level}) =>
    throw UnimplementedError('C1b #168');

/// A task's painted circle (pack #168).
MarkerTaskCircle markerTaskCircle() => throw UnimplementedError('C1b #168');

/// A done task's check (pack #168).
MarkerTaskCheck markerTaskCheck() => throw UnimplementedError('C1b #168');

/// The marker column of one item row (Spec R11): a fixed [width] (A2's
/// marker column width) one item line tall, showing the row's marker source
/// text [marker] (`- `, `12. `, `- [ ] `, `> `) in `fg2`.
///
/// It joins the row fields' `TextFieldTapRegion` group (D11), so a click on
/// it does not unfocus the row's field. C1b owns its body (painted glyphs,
/// reveal, checkbox).
class MarkerColumn extends StatelessWidget {
  const MarkerColumn({
    super.key,
    required this.marker,
    required this.width,
    this.readOnly = false,
  });

  /// The marker's source text, without the row's indentation.
  final String marker;

  /// The column's width in px.
  final double width;

  /// Read-only mode (B4's excerpt cards): markers never reveal and the task
  /// checkbox never toggles. Default false (interactive).
  final bool readOnly;

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
