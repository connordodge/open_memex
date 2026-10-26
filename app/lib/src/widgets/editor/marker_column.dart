import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'editor_row.dart';
import 'segment_view.dart';

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

/// The task circle's diameter (pack #168).
const double _taskCircleSize = 14;

/// The check's box inside the task circle: 9 px, inset 2.5 px (pack #168).
const double _checkBoxSize = 9;
const double _checkInset = 2.5;

/// Lucide's `check` polyline in its 24 px viewBox: M20 6 9 17 l-5-5.
const _lucideCheck = [Offset(20, 6), Offset(9, 17), Offset(4, 12)];
const double _lucideViewBox = 24;

/// The painted dot of a bullet at nesting [level] (1 for a top-level item,
/// 2 for its child, ...): pack #168's filled disc (diameter 3.5) at level 1,
/// a hollow ring (outer diameter 4, stroke 1) at level 2 and deeper, both
/// centred half a column in and half an item line down.
MarkerDot markerBulletDot({required int level}) {
  final center = Offset(
    monoColumnWidth / 2,
    lineHeight(LineHeightKind.item) / 2,
  );
  return level > 1
      ? (center: center, radius: 1.5, strokeWidth: 1.0, filled: false)
      : (center: center, radius: 1.75, strokeWidth: 0.0, filled: true);
}

/// A task's painted circle (pack #168): 14 px at the column's left edge,
/// centred on the task line, with a 1.5 px ring.
MarkerTaskCircle markerTaskCircle() => (
  bounds: Rect.fromLTWH(
    0,
    (lineHeight(LineHeightKind.task) - _taskCircleSize) / 2,
    _taskCircleSize,
    _taskCircleSize,
  ),
  ringWidth: 1.5,
);

/// A done task's check (pack #168): Lucide's `check` scaled into a 9 px box
/// 2.5 px inside the task circle, stroked 1.5 px.
MarkerTaskCheck markerTaskCheck() {
  final box =
      markerTaskCircle().bounds.topLeft +
      const Offset(_checkInset, _checkInset);
  return (
    points: [
      for (final p in _lucideCheck) box + p * (_checkBoxSize / _lucideViewBox),
    ],
    strokeWidth: 1.5,
  );
}

/// The marker column of one item row (Spec R2, R4, R11, R22, R24): [width]
/// (A2's unrevealed marker column width) wide and one item line tall.
///
/// - Hidden: a painted marker (TD10): a filled dot for a level-1 bullet, a
///   hollow dot deeper; the number as written, right-aligned with a 1-column
///   right padding; nothing for a quote; a task's 14 px circle, filled
///   `accentSoft` with an `accentFg` check when done.
/// - Revealed, while the row's segment has focus and its caret or selection
///   touches the row: the marker source text [marker] in `fg2`. A revealed
///   task's column is 6 columns wide instead of 4.
/// - While the segment selection spans the row (from at or before its
///   marker to at or past its text end), the column is filled
///   `OmColors.selection` and revealed marker text is `fg1`.
/// - A task row's column is its checkbox (Key `task-checkbox-<s>-<r>`):
///   a click applies `toggleTask` through the segment's `applyEdit` as one
///   edit, without moving focus or caret.
///
/// It reads the row, its segment and its selection from the enclosing
/// `EditorRow` and `SegmentView`. It joins the row fields'
/// `TextFieldTapRegion` group (D11), so a click on it does not unfocus the
/// row's field. Outside an editor row, or when [readOnly], it only paints
/// the marker of [marker] as a level-1 item.
class MarkerColumn extends StatefulWidget {
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
  State<MarkerColumn> createState() => _MarkerColumnState();
}

/// The rows last derived per segment, so a segment's columns split its text
/// once per change.
final _rowsCache = Expando<(String, List<RowSpec>)>('marker-column-rows');

List<RowSpec> _rowsOf(SegmentViewState host) {
  final text = host.text;
  final cached = _rowsCache[host];
  if (cached != null && cached.$1 == text) return cached.$2;
  final rows = splitRows(text, atSegmentStart: true);
  _rowsCache[host] = (text, rows);
  return rows;
}

/// An interactive column's editor row, segment and row spec.
typedef _Place = ({EditorRow row, SegmentViewState host, RowSpec spec});

class _MarkerColumnState extends State<MarkerColumn> {
  List<Listenable> _watched = const [];

  @override
  void dispose() {
    _watch(const []);
    super.dispose();
  }

  /// The editor row and segment this column belongs to, or null when it is
  /// read-only or outside a segment's rows.
  _Place? _place() {
    if (widget.readOnly) return null;
    final row = context.findAncestorWidgetOfExactType<EditorRow>();
    final host = context.findAncestorStateOfType<SegmentViewState>();
    if (row == null || host == null) return null;
    final rows = _rowsOf(host);
    if (row.index >= rows.length) return null;
    return (row: row, host: host, spec: rows[row.index]);
  }

  /// Rebuilds on every change of [next] (and stops listening to the
  /// previous ones).
  void _watch(List<Listenable> next) {
    var same = next.length == _watched.length;
    for (var i = 0; same && i < next.length; i++) {
      same = identical(next[i], _watched[i]);
    }
    if (same) return;
    for (final l in _watched) {
      l.removeListener(_changed);
    }
    for (final l in next) {
      l.addListener(_changed);
    }
    _watched = next;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toggle() {
    final place = _place();
    if (place == null) return;
    final edit = toggleTask(place.host.text, place.spec);
    if (edit != null) place.host.applyEdit(edit);
  }

  @override
  Widget build(BuildContext context) {
    final place = _place();
    _watch([
      if (place != null) ...[
        place.row.controller,
        place.host.widget.revealGate,
        place.host.widget.controller,
      ],
    ]);
    final RowSpec? spec;
    if (place != null) {
      spec = place.spec;
    } else {
      final rows = splitRows(widget.marker, atSegmentStart: true);
      spec = rows.isEmpty ? null : rows.first;
    }
    final kind = spec == null ? null : markerColumnKind(spec.kind);

    final revealed =
        place != null &&
        place.host.widget.revealGate.value &&
        place.row.controller.selection.isValid;
    final selection = place?.host.selection;
    final selected =
        selection != null &&
        selection.isValid &&
        !selection.isCollapsed &&
        selection.start <= spec!.start &&
        selection.end >= spec.textEnd;

    final line = lineHeight(LineHeightKind.item);
    final width = revealed && kind == MarkerColumnKind.task
        ? markerColumnWidth(MarkerColumnKind.task, revealed: true)
        : widget.width;
    TextStyle style(Color color) => OmType.mono(
      size: monoFontSize,
      color: color,
      height: line / monoFontSize,
    );

    final Widget? content = switch (kind) {
      _ when revealed => Text(
        widget.marker,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: style(selected ? OmColors.fg1 : OmColors.fg2),
      ),
      MarkerColumnKind.numbered => CustomSingleChildLayout(
        delegate: const _NumberLayout(),
        child: Text(
          widget.marker.trimRight(),
          softWrap: false,
          style: style(OmColors.fg2),
        ),
      ),
      _ => null,
    };

    Widget column = SizedBox(
      width: width,
      height: line,
      child: CustomPaint(
        painter: _MarkerPainter(
          fill: selected ? OmColors.selection : null,
          dot: !revealed && kind == MarkerColumnKind.bullet
              ? markerBulletDot(level: spec!.depth + 1)
              : null,
          task: !revealed && kind == MarkerColumnKind.task ? spec!.done : null,
        ),
        child: content,
      ),
    );
    if (place != null && kind == MarkerColumnKind.task) {
      column = GestureDetector(
        key: ValueKey('task-checkbox-${place.row.segment}-${place.row.index}'),
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: column,
      );
    }
    return TextFieldTapRegion(child: column);
  }
}

/// Places a painted number right-aligned in its column (TD10:
/// `numberedMarkerLeft`), at its natural width even when that is wider
/// than the column.
class _NumberLayout extends SingleChildLayoutDelegate {
  const _NumberLayout();

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxHeight: constraints.maxHeight);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    numberedMarkerLeft(
      columnLeft: 0,
      columnWidth: size.width,
      textWidth: childSize.width,
    ),
    0,
  );

  @override
  bool shouldRelayout(_NumberLayout oldDelegate) => false;
}

/// Paints a marker column's selection [fill], bullet [dot] and task circle
/// ([task]: whether the task is done; null for no circle).
class _MarkerPainter extends CustomPainter {
  const _MarkerPainter({
    required this.fill,
    required this.dot,
    required this.task,
  });

  final Color? fill;
  final MarkerDot? dot;
  final bool? task;

  @override
  void paint(Canvas canvas, Size size) {
    if (fill case final fill?) {
      canvas.drawRect(Offset.zero & size, Paint()..color = fill);
    }
    if (dot case final dot?) {
      canvas.drawCircle(
        dot.center,
        dot.radius,
        Paint()
          ..color = OmColors.fg2
          ..style = dot.filled ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = dot.strokeWidth,
      );
    }
    switch (task) {
      case true:
        canvas.drawOval(
          markerTaskCircle().bounds,
          Paint()..color = OmColors.accentSoft,
        );
        final check = markerTaskCheck();
        canvas.drawPath(
          Path()..addPolygon(check.points, false),
          Paint()
            ..color = OmColors.accentFg
            ..style = PaintingStyle.stroke
            ..strokeWidth = check.strokeWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      case false:
        final circle = markerTaskCircle();
        canvas.drawCircle(
          circle.bounds.center,
          (circle.bounds.width - circle.ringWidth) / 2,
          Paint()
            ..color = OmColors.fg2
            ..style = PaintingStyle.stroke
            ..strokeWidth = circle.ringWidth,
        );
      case null:
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.dot != dot ||
      oldDelegate.task != task;
}
