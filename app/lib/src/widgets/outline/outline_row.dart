// One row of the Outline list (Spec #58 R12-R14, R24, R29, R36, R40; WI #68),
// design pack 68 "Row states".
import 'package:flutter/material.dart';

import '../../editor/outline.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The row's horizontal padding, each side.
const double _padX = 16;

/// The row's vertical padding, each side; it does not scale with the text.
const double _padY = 4;

/// The indent per depth step; it does not scale with the text.
const double _indent = 14;

/// The x of an indent guide from the text column's start at depth 0.
const double _guideInset = 4;

/// The x of a depth 0 row's current bar, left of the text column.
const double _rootBarInset = 6;

/// The tooltip's gap below the row.
const double _tooltipGap = 6;

/// One Outline entry: a level tag, indent guides and the entry's plain text
/// on one line. The whole row is one tap target and one semantics button.
///
/// [current] draws the current-section marks (accent text, accentSoft tag,
/// a 2 px accent bar), [focused] a 2 px accent ring inside the row, and a
/// hovering mouse a surface3 fill. A text too long for the row ellipsizes
/// and shows its full text in a tooltip on hover.
class OutlineRow extends StatefulWidget {
  const OutlineRow({
    super.key,
    required this.entry,
    required this.current,
    required this.focused,
    required this.onActivate,
  });

  final OutlineEntry entry;
  final bool current;
  final bool focused;
  final void Function(OutlineEntry entry)? onActivate;

  /// A row's height at [scaler]: one line of text plus the vertical padding.
  static double heightFor(TextScaler scaler) => scaler.scale(18) + 2 * _padY;

  @override
  State<OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<OutlineRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final current = widget.current;
    final scaler = MediaQuery.textScalerOf(context);
    final tagWidth = scaler.scale(22).roundToDouble();
    final height = OutlineRow.heightFor(scaler);
    final indent = _indent * entry.depth;
    final textStyle = OmType.mono(
      size: 12,
      height: 1.5,
      color: current
          ? OmColors.accent
          : (entry.depth == 0 ? OmColors.fg0 : OmColors.fg1),
      weight: current
          ? FontWeight.w500
          : (entry.depth == 0 ? FontWeight.w700 : FontWeight.w400),
    );
    final tagStyle = OmType.mono(
      size: 10,
      height: 1.8,
      color: current ? OmColors.accentSoft : OmColors.fg2,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        Widget content = CustomPaint(
          painter: _RowPainter(
            hover: _hover,
            current: current,
            depth: entry.depth,
            tagWidth: tagWidth,
          ),
          foregroundPainter: widget.focused ? const _RingPainter() : null,
          child: SizedBox(
            width: width,
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _padX,
                vertical: _padY,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: tagWidth,
                    child: Text(
                      'h${entry.level}',
                      maxLines: 1,
                      softWrap: false,
                      style: tagStyle,
                    ),
                  ),
                  SizedBox(width: indent),
                  Expanded(
                    child: Text(
                      entry.text,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final available = width - 2 * _padX - tagWidth - indent;
        if (_overflows(entry.text, textStyle, scaler, available)) {
          content = Tooltip(
            message: entry.text,
            excludeFromSemantics: true,
            constraints: BoxConstraints.tightFor(width: width - 2 * _padX),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            verticalOffset: height / 2 + _tooltipGap,
            preferBelow: true,
            textAlign: TextAlign.start,
            decoration: BoxDecoration(
              color: OmColors.surface4,
              borderRadius: BorderRadius.circular(4),
            ),
            textStyle: OmType.mono(size: 11, color: OmColors.fg0),
            child: content,
          );
        }
        return Semantics(
          container: true,
          excludeSemantics: true,
          button: true,
          selected: current,
          label: entry.text,
          onTap: _activate,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _activate,
              child: content,
            ),
          ),
        );
      },
    );
  }

  void _activate() => widget.onActivate?.call(widget.entry);
}

/// Whether [text] in [style] is wider than [width] on one line.
bool _overflows(String text, TextStyle style, TextScaler scaler, double width) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout(maxWidth: width < 0 ? 0 : width);
  final overflows = painter.didExceedMaxLines;
  painter.dispose();
  return overflows;
}

/// The row's layers under its text: the hover fill, then the indent guides
/// and the current bar.
class _RowPainter extends CustomPainter {
  const _RowPainter({
    required this.hover,
    required this.current,
    required this.depth,
    required this.tagWidth,
  });

  final bool hover;
  final bool current;
  final int depth;
  final double tagWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (hover) {
      canvas.drawRect(Offset.zero & size, Paint()..color = OmColors.surface3);
    }
    final column = _padX + tagWidth;
    final guide = Paint()..color = OmColors.line2;
    // The current bar replaces the nearest guide (k = depth - 1).
    final guides = current ? depth - 1 : depth;
    for (var k = 0; k < guides; k++) {
      canvas.drawRect(
        Rect.fromLTWH(column + _indent * k + _guideInset, 0, 1, size.height),
        guide,
      );
    }
    if (current) {
      final x = depth == 0
          ? column - _rootBarInset
          : column + _indent * (depth - 1) + _guideInset;
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 2, size.height),
        Paint()..color = OmColors.accent,
      );
    }
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.hover != hover ||
      old.current != current ||
      old.depth != depth ||
      old.tagWidth != tagWidth;
}

/// The keyboard focus ring: 2 px accent, square, inside the row's bounds,
/// over everything else. It changes no layout.
class _RingPainter extends CustomPainter {
  const _RingPainter();

  static const double _width = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = OmColors.accent;
    final w = size.width;
    final h = size.height;
    canvas
      ..drawRect(Rect.fromLTWH(0, 0, w, _width), paint)
      ..drawRect(Rect.fromLTWH(0, h - _width, w, _width), paint)
      ..drawRect(Rect.fromLTWH(0, 0, _width, h), paint)
      ..drawRect(Rect.fromLTWH(w - _width, 0, _width, h), paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => false;
}
