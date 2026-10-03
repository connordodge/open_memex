import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../graph/graph_scope.dart';
import '../../theme/colors.dart';

/// Gap between a node's centre and the end of a line, so lines and their
/// arrowheads stop at the node's edge instead of under it.
const double kGraphEdgeInset = 10;

/// Perpendicular spacing between lines that join the same pair of nodes
/// (e.g. a topic's `from-day` link and the day's `about` link back).
const double kGraphParallelSpacing = 10;

/// One edge as drawn: a straight segment in view coordinates.
class GraphEdgeLine {
  const GraphEdgeLine({
    required this.edge,
    required this.start,
    required this.end,
  });

  final GraphEdge edge;
  final Offset start;
  final Offset end;
}

/// Lays [edges] out as straight segments between the node centres given by
/// [centreOf], each pulled back from both nodes by [kGraphEdgeInset]. Edges
/// that join the same pair (in either direction) are spread apart
/// perpendicularly, centred on the line between the two nodes.
List<GraphEdgeLine> layoutEdgeLines(
  List<GraphEdge> edges,
  Offset Function(String nodeId) centreOf,
) {
  final groups = <String, List<GraphEdge>>{};
  for (final e in edges) {
    final pair = ([e.from, e.to]..sort()).join('\u0000');
    groups.putIfAbsent(pair, () => []).add(e);
  }
  final lines = <GraphEdgeLine>[];
  for (final group in groups.values) {
    // The perpendicular comes from the pair's sorted order, so a link and
    // its reverse are pushed to opposite sides.
    final ends = [group.first.from, group.first.to]..sort();
    final axis = _unit(centreOf(ends.last) - centreOf(ends.first));
    final normal = Offset(-axis.dy, axis.dx);
    for (final (i, e) in group.indexed) {
      final shift =
          normal * (kGraphParallelSpacing * (i - (group.length - 1) / 2));
      final from = centreOf(e.from) + shift;
      final to = centreOf(e.to) + shift;
      final dir = _unit(to - from);
      lines.add(
        GraphEdgeLine(
          edge: e,
          start: from + dir * kGraphEdgeInset,
          end: to - dir * kGraphEdgeInset,
        ),
      );
    }
  }
  return lines;
}

/// The top-most line within [tolerance] of [point], or null. Each line's
/// hit area is the rectangle of half-width [tolerance] along its segment.
GraphEdgeLine? hitEdgeLine(
  List<GraphEdgeLine> lines,
  Offset point, {
  double tolerance = 6,
}) {
  for (final line in lines.reversed) {
    final along = line.end - line.start;
    final u = _unit(along);
    final rel = point - line.start;
    // [point] in the line's own frame: x along the segment, y across it.
    final local = Offset(
      rel.dx * u.dx + rel.dy * u.dy,
      rel.dy * u.dx - rel.dx * u.dy,
    );
    final area = Rect.fromLTRB(0, -tolerance, along.distance, tolerance);
    if (area.contains(local)) return line;
  }
  return null;
}

Offset _unit(Offset v) => v / math.max(v.distance, 1e-6);

/// Paints the Graph view's edges: straight lines with an arrowhead at the
/// target, in the canvas edge colours (`fg2`, `accent` when hovered).
class GraphEdgePainter extends CustomPainter {
  GraphEdgePainter({required this.lines, required this.hovered});

  final List<GraphEdgeLine> lines;

  /// The edge under the pointer, drawn in the accent colour.
  final GraphEdge? hovered;

  @override
  void paint(Canvas canvas, Size size) {
    for (final line in lines) {
      final color = identical(line.edge, hovered)
          ? OmColors.accent
          : OmColors.fg2;
      canvas.drawLine(
        line.start,
        line.end,
        Paint()
          ..color = color
          ..strokeWidth = 1.2,
      );
      _paintArrowHead(canvas, line, Paint()..color = color);
    }
  }

  void _paintArrowHead(Canvas canvas, GraphEdgeLine line, Paint paint) {
    const arrowLength = 7.0;
    const arrowWidth = 3.5;
    final u = _unit(line.end - line.start);
    final perp = Offset(-u.dy, u.dx);
    final back = line.end - u * arrowLength;
    canvas.drawPath(
      Path()
        ..moveTo(line.end.dx, line.end.dy)
        ..lineTo(back.dx + perp.dx * arrowWidth, back.dy + perp.dy * arrowWidth)
        ..lineTo(back.dx - perp.dx * arrowWidth, back.dy - perp.dy * arrowWidth)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant GraphEdgePainter old) =>
      old.lines != lines || old.hovered != hovered;
}
