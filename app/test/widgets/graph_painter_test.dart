// WI #30 (A12): edge geometry and hover hit test of the Graph view's
// painter (implementer tests for behaviour beyond the ACs).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/widgets/graph/graph_painter.dart';

const _ab = GraphEdge(from: 'a', to: 'b', kind: 'extends', label: 'x');
const _ba = GraphEdge(from: 'b', to: 'a', kind: 'about', label: null);

const _centres = {'a': Offset(0, 0), 'b': Offset(100, 0)};
Offset _centreOf(String id) => _centres[id]!;

void main() {
  test('a lone edge runs along the line between its node centres', () {
    final [line] = layoutEdgeLines(const [_ab], _centreOf);
    expect(line.edge, same(_ab));
    expect(line.start, const Offset(kGraphEdgeInset, 0));
    expect(line.end, const Offset(100 - kGraphEdgeInset, 0));
  });

  test('a link and its reverse are drawn on opposite sides of the line', () {
    final [ab, ba] = layoutEdgeLines(const [_ab, _ba], _centreOf);
    expect(ab.start.dy, -ba.start.dy);
    expect((ab.start.dy - ba.start.dy).abs(), kGraphParallelSpacing);
    expect(ab.start.dx, kGraphEdgeInset, reason: 'a to b starts at a');
    expect(ba.start.dx, 100 - kGraphEdgeInset, reason: 'b to a starts at b');
  });

  test('hovering hits a line within the tolerance and only along it', () {
    final lines = layoutEdgeLines(const [_ab], _centreOf);
    expect(hitEdgeLine(lines, const Offset(50, 0))?.edge, same(_ab));
    expect(hitEdgeLine(lines, const Offset(50, 5))?.edge, same(_ab));
    expect(hitEdgeLine(lines, const Offset(50, -5))?.edge, same(_ab));
    expect(hitEdgeLine(lines, const Offset(50, 7)), isNull);
    expect(hitEdgeLine(lines, const Offset(50, -7)), isNull);
    expect(hitEdgeLine(lines, const Offset(5, 0)), isNull, reason: 'inset');
    expect(hitEdgeLine(lines, const Offset(95, 0)), isNull, reason: 'inset');
  });

  test('hovering two parallel lines hits the one under the pointer', () {
    final [ab, ba] = layoutEdgeLines(const [_ab, _ba], _centreOf);
    final lines = [ab, ba];
    expect(hitEdgeLine(lines, Offset(50, ab.start.dy))?.edge, same(_ab));
    expect(hitEdgeLine(lines, Offset(50, ba.start.dy))?.edge, same(_ba));
  });

  test(
    'the edge painter repaints when the lines or the hovered edge change',
    () {
      final lines = layoutEdgeLines(const [_ab], _centreOf);
      final painter = GraphEdgePainter(lines: lines, hovered: null);
      expect(
        painter.shouldRepaint(GraphEdgePainter(lines: lines, hovered: null)),
        isFalse,
      );
      expect(
        painter.shouldRepaint(GraphEdgePainter(lines: lines, hovered: _ab)),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          GraphEdgePainter(
            lines: layoutEdgeLines(const [_ab], _centreOf),
            hovered: null,
          ),
        ),
        isTrue,
      );
    },
  );
}
