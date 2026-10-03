import 'dart:ui';

/// The most simulation ticks a layout runs before it stops, counted from
/// creation or from the last reheat ([GraphLayout.moveNode] /
/// [GraphLayout.release]).
const int kGraphMaxTicks = 300;

/// A deterministic force-directed layout (repulsion, link springs, centring
/// on [Offset.zero]). Pure Dart: the Graph view drives [tick] from a
/// `Ticker` and keeps the positions only in widget state (nothing is stored).
class GraphLayout {
  /// Initial positions are seeded from each node id alone, so the same id
  /// starts at the same place whatever the list order.
  GraphLayout({
    required List<String> nodeIds,
    required List<(String, String)> links,
  }) {
    throw UnimplementedError();
  }

  /// Node id → centre, in layout coordinates.
  Map<String, Offset> get positions => throw UnimplementedError();

  /// True once the simulation has cooled (or hit [kGraphMaxTicks]); [tick]
  /// is then a no-op until the next reheat.
  bool get isSettled => throw UnimplementedError();

  /// Advances the simulation one step.
  void tick() => throw UnimplementedError();

  /// Drag: holds node [id] at [position] (ticks don't move it) and reheats.
  void moveNode(String id, Offset position) => throw UnimplementedError();

  /// Ends a drag of node [id]: it is free again and the simulation reheats
  /// briefly.
  void release(String id) => throw UnimplementedError();
}
