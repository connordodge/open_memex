import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

/// The most simulation ticks a layout runs before it stops, counted from
/// creation or from the last reheat ([GraphLayout.moveNode] /
/// [GraphLayout.release]).
const int kGraphMaxTicks = 300;

/// Ticks a layout keeps running after a dragged node is released: a brief
/// reheat, shorter than a fresh layout.
const int _releaseTicks = 120;

/// Simulation temperature after a drag or a release. Forces scale with it.
const double _dragAlpha = 0.3;
const double _releaseAlpha = 0.2;

/// Alpha falls from 1 to about 0.001 over [kGraphMaxTicks] ticks.
const double _alphaDecay = 0.977;

/// Fraction of a node's velocity kept from one tick to the next.
const double _velocityRetention = 0.6;

/// Rest length of a link spring, in layout units (logical pixels at zoom 1).
const double _linkDistance = 100;

/// Many-body repulsion strength.
const double _repulsion = 400;

/// Pull of every node toward the origin.
const double _centring = 0.04;

/// Repulsion never divides by less than this squared distance, so two
/// nodes that start close don't fling each other across the canvas.
const double _minDistanceSquared = 100;

/// Seed positions fill a disc whose radius grows with the square root of
/// the node count (constant density).
const double _seedSpacing = 40;

/// A deterministic force-directed layout (repulsion, link springs, centring
/// on [Offset.zero]). Pure Dart: the Graph view drives [tick] from a
/// `Ticker` and keeps the positions only in widget state (nothing is stored).
class GraphLayout {
  /// Initial positions are seeded from each node id alone, so the same id
  /// starts at the same place whatever the list order. Links whose ends are
  /// not both in [nodeIds] are ignored.
  GraphLayout({
    required List<String> nodeIds,
    required List<(String, String)> links,
  }) : _ids = nodeIds.toSet().toList()..sort() {
    final spread = _seedSpacing * math.sqrt(_ids.length);
    for (final (i, id) in _ids.indexed) {
      _index[id] = i;
      _pos[id] = _seed(id, spread);
      _vel[id] = Offset.zero;
    }
    final degree = List<int>.filled(_ids.length, 0);
    final ends = <(int, int)>[];
    for (final (a, b) in links) {
      if ((_index[a], _index[b]) case (final int ia, final int ib)) {
        ends.add((ia, ib));
        degree[ia]++;
        degree[ib]++;
      }
    }
    for (final (a, b) in ends) {
      final (da, db) = (degree[a], degree[b]);
      _springs.add(
        _Spring(a, b, strength: 1 / math.min(da, db), bias: da / (da + db)),
      );
    }
    // Nothing to simulate: an empty layout is settled from the start.
    if (_ids.isEmpty) _ticks = kGraphMaxTicks;
  }

  final List<String> _ids;
  final Map<String, int> _index = {};
  final Map<String, Offset> _pos = {};
  final Map<String, Offset> _vel = {};
  final List<_Spring> _springs = [];
  final Set<String> _held = {};
  double _alpha = 1;
  int _ticks = 0;

  /// Node id → centre, in layout coordinates.
  Map<String, Offset> get positions => UnmodifiableMapView(_pos);

  /// True once the simulation has cooled (or hit [kGraphMaxTicks]); [tick]
  /// is then a no-op until the next reheat.
  bool get isSettled => _ticks >= kGraphMaxTicks;

  /// Advances the simulation one step.
  void tick() {
    if (isSettled) return;
    final n = _ids.length;
    final p = [for (final id in _ids) _pos[id]!];
    final v = [for (final id in _ids) _vel[id]!];

    // Many-body repulsion: every pair pushes apart, weaker with distance.
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final d = p[j] - p[i];
        final f =
            _repulsion *
            _alpha /
            math.max(d.distanceSquared, _minDistanceSquared);
        v[i] -= d * f;
        v[j] += d * f;
      }
    }

    // Link springs toward [_linkDistance], split by degree so a hub moves
    // less than a leaf.
    for (final s in _springs) {
      final d = p[s.b] + v[s.b] - p[s.a] - v[s.a];
      final length = math.max(d.distance, 1e-6);
      final k = (length - _linkDistance) / length * _alpha * s.strength;
      v[s.b] -= d * (k * s.bias);
      v[s.a] += d * (k * (1 - s.bias));
    }

    // Centring: a gentle pull of every node toward the origin.
    for (var i = 0; i < n; i++) {
      v[i] -= p[i] * (_centring * _alpha);
    }

    for (final (i, id) in _ids.indexed) {
      if (_held.contains(id)) {
        _vel[id] = Offset.zero;
        continue;
      }
      final velocity = v[i] * _velocityRetention;
      _vel[id] = velocity;
      _pos[id] = p[i] + velocity;
    }
    _alpha *= _alphaDecay;
    _ticks++;
  }

  /// Drag: holds node [id] at [position] (ticks don't move it) and reheats.
  /// An unknown id is ignored.
  void moveNode(String id, Offset position) {
    if (!_pos.containsKey(id)) return;
    _pos[id] = position;
    _vel[id] = Offset.zero;
    _held.add(id);
    _alpha = math.max(_alpha, _dragAlpha);
    _ticks = 0;
  }

  /// Ends a drag of node [id]: it is free again and the simulation reheats
  /// briefly.
  void release(String id) {
    if (!_held.remove(id)) return;
    _alpha = math.max(_alpha, _releaseAlpha);
    _ticks = kGraphMaxTicks - _releaseTicks;
  }

  /// A point in a disc of radius [spread], from two independent FNV-1a
  /// hashes of [id] (angle and radius).
  static Offset _seed(String id, double spread) {
    final angle = _fnv1a(id, 0x811c9dc5) / 0x100000000 * 2 * math.pi;
    final radius = spread * math.sqrt(_fnv1a(id, 0x050c5d1f) / 0x100000000);
    return Offset(radius * math.cos(angle), radius * math.sin(angle));
  }

  /// 32-bit FNV-1a with a murmur3 finalizer, so ids that differ only in
  /// their last character still land far apart.
  static int _fnv1a(String s, int basis) {
    var h = basis;
    for (final unit in s.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    h ^= h >> 16;
    h = (h * 0x85ebca6b) & 0xffffffff;
    h ^= h >> 13;
    h = (h * 0xc2b2ae35) & 0xffffffff;
    return h ^ (h >> 16);
  }
}

class _Spring {
  _Spring(this.a, this.b, {required this.strength, required this.bias});

  final int a;
  final int b;
  final double strength;

  /// Share of the correction applied to [b] (the rest goes to [a]).
  final double bias;
}
