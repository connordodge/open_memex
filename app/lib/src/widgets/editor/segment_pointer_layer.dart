import 'package:flutter/widgets.dart';

/// Pointer selection over one text segment's editor rows (D8): a
/// pass-through around the segment that C1 creates and C3 fills (drag,
/// Shift+click and `SelectAll` across rows).
class SegmentPointerLayer extends StatelessWidget {
  const SegmentPointerLayer({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// One laid-out line, as [newlineMarks] reads it (TD10, pack #170).
///
/// Offsets and the selection [newlineMarks] gets are in the same coordinate
/// space (e.g. segment offsets); x and y are in the painter's coordinates.
@immutable
class NewlineMarkLine {
  const NewlineMarkLine({
    required this.end,
    required this.breaks,
    required this.top,
    required this.bottom,
    required this.endX,
    required this.columnWidth,
  });

  /// Where the line's characters end: its line terminator starts here when
  /// [breaks].
  final int end;

  /// True when a line terminator follows the line at [end] (the end of a
  /// logical line); false at a soft wrap and on a text's last line.
  final bool breaks;

  /// The line box's top.
  final double top;

  /// The line box's bottom.
  final double bottom;

  /// The right end of the line's last glyph; the text's left x on a blank
  /// line.
  final double endX;

  /// One mono column at the line's font size ([newlineMarkWidth]).
  final double columnWidth;
}

/// The newline marks of [selection] over [lines], in line order (Spec R26,
/// TD10, pack #170 board A4 cells H and K): one rect per line whose line
/// terminator is inside [selection], starting at the line's [NewlineMarkLine.endX],
/// one [NewlineMarkLine.columnWidth] wide and the line box's full height. A
/// selected blank line's mark is its fill.
List<Rect> newlineMarks(List<NewlineMarkLine> lines, TextRange selection) =>
    throw UnimplementedError();

/// The newline mark's width on a line: one mono column at the line's font
/// size (8.1 on a body line; H1 20, H2 17, H3 15, H4 to H6 13.5 px fonts).
/// [headingLevel] is the line's heading level, null for every other line.
///
/// Throws [ArgumentError] when [headingLevel] is outside 1..6.
double newlineMarkWidth(int? headingLevel) => throw UnimplementedError();
