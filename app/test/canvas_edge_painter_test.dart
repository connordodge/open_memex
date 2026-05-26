import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/widgets/canvas_edge_painter.dart';

CanvasEdgeRow _edge(
  String id,
  String from,
  String to, {
  String kind = 'references',
  String? label,
}) {
  return CanvasEdgeRow(
    linkId: id,
    fromNoteId: from,
    toNoteId: to,
    linkText: to,
    kind: kind,
    label: label,
    position: 0,
    source: 'inline_body',
  );
}

void main() {
  const nodeSize = Size(168, 44);

  group('CanvasEdgePainter.hitTestEdge', () {
    test(
      'returns the link id when pointer is within tolerance of the curve',
      () {
        final painter = CanvasEdgePainter(
          edges: [_edge('L1', 'A', 'B')],
          nodePositions: const {'A': Offset(0, 0), 'B': Offset(600, 0)},
          nodeSize: nodeSize,
          selectedEdgeId: null,
        );
        // Midpoint of a straight horizontal cubic between the two centers.
        final midX = (0 + 168 / 2 + 600 + 168 / 2) / 2;
        const midY = 44 / 2;
        final hit = painter.hitTestEdge(Offset(midX, midY));
        expect(hit, 'L1');
      },
    );

    test('returns null when pointer is far from any curve', () {
      final painter = CanvasEdgePainter(
        edges: [_edge('L1', 'A', 'B')],
        nodePositions: const {'A': Offset(0, 0), 'B': Offset(600, 0)},
        nodeSize: nodeSize,
        selectedEdgeId: null,
      );
      expect(painter.hitTestEdge(const Offset(50, 500)), isNull);
    });

    test('multiple edges between same pair produce distinct hit regions', () {
      final painter = CanvasEdgePainter(
        edges: [
          _edge('L1', 'A', 'B', kind: 'extends'),
          _edge('L2', 'A', 'B', kind: 'references'),
        ],
        nodePositions: const {'A': Offset(0, 0), 'B': Offset(600, 0)},
        nodeSize: nodeSize,
        selectedEdgeId: null,
      );
      // The two edges are offset perpendicularly: one up, one down. Tap above
      // the midline → upper edge; tap below → lower edge. They should resolve
      // to different link ids.
      final midX = (0 + 168 / 2 + 600 + 168 / 2) / 2;
      const midY = 44 / 2;
      final above = painter.hitTestEdge(Offset(midX, midY - 14));
      final below = painter.hitTestEdge(Offset(midX, midY + 14));
      expect(above, isNotNull);
      expect(below, isNotNull);
      expect(above, isNot(equals(below)));
    });

    test('hits beyond the 6px tolerance return null', () {
      final painter = CanvasEdgePainter(
        edges: [_edge('L1', 'A', 'B')],
        nodePositions: const {'A': Offset(0, 0), 'B': Offset(600, 0)},
        nodeSize: nodeSize,
        selectedEdgeId: null,
      );
      final midX = (0 + 168 / 2 + 600 + 168 / 2) / 2;
      // 20px below the midline — clearly outside the 6px corridor.
      expect(painter.hitTestEdge(Offset(midX, 44 / 2 + 20)), isNull);
    });

    test('ignores edges that reference a non-placed node', () {
      final painter = CanvasEdgePainter(
        edges: [
          _edge('L1', 'A', 'B'),
          // C isn't in nodePositions — should be silently skipped.
          _edge('L2', 'A', 'C'),
        ],
        nodePositions: const {'A': Offset(0, 0), 'B': Offset(600, 0)},
        nodeSize: nodeSize,
        selectedEdgeId: null,
      );
      // We can still hit-test L1 at the midpoint.
      final midX = (0 + 168 / 2 + 600 + 168 / 2) / 2;
      const midY = 44 / 2;
      expect(painter.hitTestEdge(Offset(midX, midY)), 'L1');
    });
  });
}
