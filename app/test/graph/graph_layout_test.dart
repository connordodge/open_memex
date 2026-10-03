// WI #30 (A12): the automatic layout as a pure function. Positions are never
// pinned to values (TS5); the tests check determinism, settling, drag and
// relational properties of the force simulation.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_layout.dart';

List<String> _ids(int n) => [
  for (var i = 0; i < n; i++) 'n${i.toString().padLeft(2, '0')}',
];

/// A ring over [ids] plus a chord every third node.
List<(String, String)> _ringLinks(List<String> ids) => [
  for (var i = 0; i < ids.length; i++) (ids[i], ids[(i + 1) % ids.length]),
  for (var i = 0; i < ids.length; i += 3) (ids[i], ids[(i + 5) % ids.length]),
];

/// Ticks [layout] until it settles; returns the number of ticks taken.
/// Gives up (and fails) well past [kGraphMaxTicks].
int _runToRest(GraphLayout layout) {
  var ticks = 0;
  while (!layout.isSettled) {
    layout.tick();
    ticks++;
    if (ticks > kGraphMaxTicks * 10) {
      fail('layout did not settle after $ticks ticks');
    }
  }
  return ticks;
}

void _expectFinite(Map<String, Offset> positions) {
  for (final e in positions.entries) {
    expect(
      e.value.dx.isFinite && e.value.dy.isFinite,
      isTrue,
      reason: '${e.key} at ${e.value}',
    );
  }
}

double _minPairDistance(Map<String, Offset> p) {
  final pts = p.values.toList();
  var best = double.infinity;
  for (var i = 0; i < pts.length; i++) {
    for (var j = i + 1; j < pts.length; j++) {
      best = math.min(best, (pts[i] - pts[j]).distance);
    }
  }
  return best;
}

void main() {
  test('the layout is deterministic for the same nodes and links', () {
    final ids = _ids(12);
    final a = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    final b = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    expect(a.positions, b.positions, reason: 'same seed positions');
    _runToRest(a);
    _runToRest(b);
    expect(a.positions, b.positions, reason: 'same settled positions');
  });

  test('seed positions depend on the node id and not on list order', () {
    final ids = _ids(8);
    final forward = GraphLayout(nodeIds: ids, links: const []);
    final reversed = GraphLayout(
      nodeIds: ids.reversed.toList(),
      links: const [],
    );
    for (final id in ids) {
      expect(forward.positions[id], reversed.positions[id], reason: id);
    }
  });

  test('every node gets a distinct finite seed position', () {
    final ids = _ids(30);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    expect(layout.positions.keys.toSet(), ids.toSet());
    _expectFinite(layout.positions);
    expect(_minPairDistance(layout.positions), greaterThan(0.5));
  });

  test('a 30-node layout settles within kGraphMaxTicks and then stops', () {
    final ids = _ids(30);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    expect(layout.isSettled, isFalse, reason: 'a new layout is hot');
    final ticks = _runToRest(layout);
    expect(ticks, lessThanOrEqualTo(kGraphMaxTicks));
    expect(ticks, greaterThan(0));
    _expectFinite(layout.positions);

    final settled = Map.of(layout.positions);
    layout.tick();
    layout.tick();
    expect(layout.positions, settled, reason: 'a settled layout is frozen');
    expect(layout.isSettled, isTrue);
  });

  test('the simulation moves nodes before it settles', () {
    final ids = _ids(6);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    final seeded = Map.of(layout.positions);
    _runToRest(layout);
    final moved = ids.where((id) => layout.positions[id] != seeded[id]);
    expect(moved, isNotEmpty);
  });

  test('an empty layout is settled at once and a single node is finite', () {
    final empty = GraphLayout(nodeIds: const [], links: const []);
    expect(empty.positions, isEmpty);
    expect(_runToRest(empty), lessThanOrEqualTo(kGraphMaxTicks));

    final single = GraphLayout(nodeIds: const ['only'], links: const []);
    _runToRest(single);
    _expectFinite(single.positions);
  });

  test('settled nodes never sit on top of each other', () {
    final ids = _ids(20);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    expect(_minPairDistance(layout.positions), greaterThan(10));
  });

  test('linked nodes settle closer together than unlinked nodes', () {
    // a-b linked; c and d isolated. Repulsion pushes every pair apart, the
    // spring pulls only a and b together.
    final layout = GraphLayout(
      nodeIds: const ['a', 'b', 'c', 'd'],
      links: const [('a', 'b')],
    );
    _runToRest(layout);
    final p = layout.positions;
    final linked = (p['a']! - p['b']!).distance;
    final unlinked = (p['c']! - p['d']!).distance;
    expect(linked, lessThan(unlinked));
  });

  test('the centring force keeps the settled layout around the origin', () {
    final ids = _ids(10);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    final pts = layout.positions.values;
    final centroid =
        pts.fold(Offset.zero, (sum, o) => sum + o) / pts.length.toDouble();
    var spread = 0.0;
    for (final o in pts) {
      spread = math.max(spread, (o - centroid).distance);
    }
    expect(spread, greaterThan(0));
    expect(
      centroid.distance,
      lessThan(spread),
      reason: 'the centroid lies within the layout, near the origin',
    );
  });

  test('moving a node holds it at the drag position and reheats', () {
    final ids = _ids(6);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    expect(layout.isSettled, isTrue);

    const target = Offset(400, -250);
    layout.moveNode('n02', target);
    expect(layout.positions['n02'], target);
    expect(layout.isSettled, isFalse, reason: 'dragging reheats');

    final before = Map.of(layout.positions);
    for (var i = 0; i < 5; i++) {
      layout.tick();
    }
    expect(layout.positions['n02'], target, reason: 'held while dragged');
    expect(
      ids.where((id) => id != 'n02' && layout.positions[id] != before[id]),
      isNotEmpty,
      reason: 'the other nodes react to the moved node',
    );
  });

  test('releasing a dragged node lets the layout settle again', () {
    final ids = _ids(6);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    layout.moveNode('n02', const Offset(400, -250));
    layout.release('n02');
    expect(layout.isSettled, isFalse, reason: 'release reheats briefly');
    expect(_runToRest(layout), lessThanOrEqualTo(kGraphMaxTicks));
    _expectFinite(layout.positions);
  });
  test('an empty layout needs no ticks', () {
    final empty = GraphLayout(nodeIds: const [], links: const []);
    expect(empty.isSettled, isTrue);
  });

  test('links to nodes outside the layout are ignored', () {
    final ids = _ids(6);
    final plain = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    final extra = GraphLayout(
      nodeIds: ids,
      links: [..._ringLinks(ids), ('n00', 'elsewhere'), ('nowhere', 'n01')],
    );
    _runToRest(plain);
    _runToRest(extra);
    expect(extra.positions, plain.positions);
  });

  test('moving an unknown node is ignored', () {
    final ids = _ids(4);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    final settled = Map.of(layout.positions);
    layout.moveNode('ghost', const Offset(10, 10));
    expect(layout.isSettled, isTrue);
    expect(layout.positions, settled);
  });

  test('releasing a node that is not being dragged changes nothing', () {
    final ids = _ids(4);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    layout.release('n01');
    expect(layout.isSettled, isTrue);
  });

  test('a released node settles within the brief reheat budget', () {
    final ids = _ids(6);
    final layout = GraphLayout(nodeIds: ids, links: _ringLinks(ids));
    _runToRest(layout);
    layout.moveNode('n02', const Offset(400, -250));
    for (var i = 0; i < 50; i++) {
      layout.tick();
    }
    layout.release('n02');
    final ticks = _runToRest(layout);
    expect(ticks, greaterThan(0));
    expect(
      ticks,
      lessThan(kGraphMaxTicks),
      reason: 'a release reheats briefly',
    );
  });
}
