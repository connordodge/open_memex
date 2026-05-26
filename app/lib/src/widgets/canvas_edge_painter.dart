import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../db.dart';
import '../theme/colors.dart';

/// Renders cubic-Bézier edges between placed canvas nodes. Multiple edges
/// between the same pair are offset perpendicularly so each is visible and
/// independently hit-testable.
class CanvasEdgePainter extends CustomPainter {
  CanvasEdgePainter({
    required this.edges,
    required this.nodePositions,
    required this.nodeSize,
    required this.selectedEdgeId,
  });

  /// Edges to draw, in deterministic order. Multiple rows with the same
  /// (from, to) pair are split apart via perpendicular offsets.
  final List<CanvasEdgeRow> edges;

  /// `note_id` → top-left position of the node in canvas coords.
  final Map<String, Offset> nodePositions;

  /// Size of a node card (used so curves anchor near the edge of the card,
  /// not its top-left corner).
  final Size nodeSize;

  final String? selectedEdgeId;

  /// Cached curves with their (link_id, control points) so `hitTestEdge`
  /// can use the same geometry as the painter.
  late final List<_EdgeGeometry> _geometry = _computeGeometry();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = OmColors.fg2;
    final paintSelected = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = OmColors.accent;

    for (final g in _geometry) {
      final path = Path()
        ..moveTo(g.start.dx, g.start.dy)
        ..cubicTo(
          g.control1.dx,
          g.control1.dy,
          g.control2.dx,
          g.control2.dy,
          g.end.dx,
          g.end.dy,
        );
      canvas.drawPath(path, g.linkId == selectedEdgeId ? paintSelected : paint);
      _paintArrowHead(canvas, g, paint, paintSelected);
      _paintMidLabel(canvas, g);
    }
  }

  void _paintArrowHead(Canvas canvas, _EdgeGeometry g, Paint base, Paint sel) {
    // Direction at the end point: derivative of the cubic at t=1 = 3*(end-c2).
    final dir = g.end - g.control2;
    final len = dir.distance;
    if (len < 0.001) return;
    final unit = dir / len;
    final perp = Offset(-unit.dy, unit.dx);
    const arrowLen = 8.0;
    const arrowWidth = 4.0;
    final tip = g.end;
    final base1 = tip - unit * arrowLen + perp * arrowWidth;
    final base2 = tip - unit * arrowLen - perp * arrowWidth;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base1.dx, base1.dy)
      ..lineTo(base2.dx, base2.dy)
      ..close();
    canvas.drawPath(
      path,
      g.linkId == selectedEdgeId
          ? (Paint()..color = OmColors.accent)
          : (Paint()..color = OmColors.fg2),
    );
    // Silence unused warnings for now.
    base.style;
    sel.style;
  }

  void _paintMidLabel(Canvas canvas, _EdgeGeometry g) {
    final text = g.label ?? (g.kind == 'references' ? null : g.kind);
    if (text == null) return;
    final mid = _cubicAt(g, 0.5);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: g.linkId == selectedEdgeId ? OmColors.accent : OmColors.fg2,
          fontSize: 10.5,
          backgroundColor: OmColors.surface1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 160);
    final bg = Rect.fromCenter(
      center: mid,
      width: tp.width + 8,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(3)),
      Paint()..color = OmColors.surface2,
    );
    tp.paint(canvas, Offset(bg.left + 4, bg.top + 2));
  }

  Offset _cubicAt(_EdgeGeometry g, double t) {
    final u = 1 - t;
    return g.start * (u * u * u) +
        g.control1 * (3 * u * u * t) +
        g.control2 * (3 * u * t * t) +
        g.end * (t * t * t);
  }

  /// 6px-tolerant hit test against the cubic curves. Returns the link id of
  /// the closest hit edge, or null. Walks the cubic at 32 samples per curve.
  String? hitTestEdge(Offset localPosition, {double tolerancePx = 6.0}) {
    String? best;
    double bestDist = tolerancePx;
    for (final g in _geometry) {
      for (var i = 0; i <= 32; i++) {
        final t = i / 32.0;
        final p = _cubicAt(g, t);
        final d = (p - localPosition).distance;
        if (d < bestDist) {
          bestDist = d;
          best = g.linkId;
        }
      }
    }
    return best;
  }

  List<_EdgeGeometry> _computeGeometry() {
    // Bucket edges by (sorted) pair so we can compute perpendicular offsets
    // for multiple edges in the same bucket.
    final groups = <String, List<CanvasEdgeRow>>{};
    for (final e in edges) {
      final key = _pairKey(e.fromNoteId, e.toNoteId);
      (groups[key] ??= <CanvasEdgeRow>[]).add(e);
    }
    final out = <_EdgeGeometry>[];
    for (final g in groups.values) {
      final n = g.length;
      for (var i = 0; i < n; i++) {
        final e = g[i];
        final from = nodePositions[e.fromNoteId];
        final to = nodePositions[e.toNoteId];
        if (from == null || to == null) continue;
        final start = from + Offset(nodeSize.width / 2, nodeSize.height / 2);
        final end = to + Offset(nodeSize.width / 2, nodeSize.height / 2);
        final dx = end.dx - start.dx;
        final dy = end.dy - start.dy;
        final lenSq = dx * dx + dy * dy;
        // Perpendicular unit vector. Falls back to a small upward kick when
        // the two node centers coincide.
        final magnitude = lenSq <= 0 ? 1.0 : math.sqrt(lenSq);
        final perp = Offset(-dy, dx) / magnitude;
        // Center the offsets around zero: positions (-(n-1)/2 .. (n-1)/2).
        final offsetIndex = i - (n - 1) / 2.0;
        const perpAmplitude = 28.0;
        final off = perp * (perpAmplitude * offsetIndex);
        final mid = (start + end) / 2;
        // Convex curve: pull control points perpendicular to the segment.
        final c1 = start + (mid - start) / 2 + off;
        final c2 = end + (mid - end) / 2 + off;
        out.add(
          _EdgeGeometry(
            linkId: e.linkId,
            kind: e.kind,
            label: e.label,
            start: start,
            control1: c1,
            control2: c2,
            end: end,
          ),
        );
      }
    }
    return out;
  }

  static String _pairKey(String a, String b) {
    return a.compareTo(b) <= 0 ? '$a→$b/$a→$b' : '$a→$b/$b→$a';
  }

  @override
  bool shouldRepaint(covariant CanvasEdgePainter old) {
    return edges != old.edges ||
        nodePositions != old.nodePositions ||
        selectedEdgeId != old.selectedEdgeId ||
        nodeSize != old.nodeSize;
  }
}

class _EdgeGeometry {
  _EdgeGeometry({
    required this.linkId,
    required this.kind,
    required this.label,
    required this.start,
    required this.control1,
    required this.control2,
    required this.end,
  });
  final String linkId;
  final String kind;
  final String? label;
  final Offset start;
  final Offset control1;
  final Offset control2;
  final Offset end;
}
