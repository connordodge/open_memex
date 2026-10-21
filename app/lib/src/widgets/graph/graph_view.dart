import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../graph/graph_layout.dart';
import '../../graph/graph_scope.dart';
import '../../state/graph_state.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/vault_async_view.dart';
import 'graph_painter.dart';

/// Each node widget's box, centred on the node. The shape sits in the
/// middle, the pinned glyph to its right and the label below.
const Size _nodeBox = Size(160, 56);

/// Half-size of the square around a node centre that a tap, drag or hover
/// hits. Labels are not part of it, so a line between two close nodes stays
/// hoverable.
const double _nodeHitRadius = 12;

/// Room around a hull's member centres: sides, top (folder name) and bottom
/// (node labels).
const EdgeInsets _hullPadding = EdgeInsets.fromLTRB(36, 40, 36, 44);

/// Space kept around the layout when the view fits it.
const double _fitMargin = 80;

const double _minZoom = 0.1;
const double _maxZoom = 4;

/// Mouse-wheel zoom: every 400 logical pixels of scroll doubles or halves
/// the zoom.
const double _wheelPixelsPerDoubling = 400;

/// The read-only Graph view for [scope] (Req 63). Its root carries
/// Key `graph-view`; nodes are `graph-node-<noteId>`, hulls
/// `graph-hull-<folderId>`, the edge hover tooltip `graph-edge-tooltip`.
///
/// Positions live only in this widget's state: dragging, panning and
/// zooming are never persisted. Until the person pans, zooms or drags, the
/// view keeps the whole layout in sight. The host keys the view by its
/// scope, so a different scope gets a fresh view.
///
/// The graph comes from `graphDataAsyncProvider` through `VaultAsyncView`
/// (D14a): a reload keeps the previous graph and its layout on screen until
/// new data arrives, and a vault switch never shows the previous vault's
/// nodes.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key, required this.scope});

  final GraphScope scope;

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _onTick());
  late GraphData _data;
  late GraphLayout _layout;

  /// View transform: a layout point `p` is drawn at `p * _scale +
  /// _translation`.
  double _scale = 1;
  Offset _translation = Offset.zero;

  /// True until the person pans, zooms or drags: the view then follows the
  /// layout so all of it stays visible.
  bool _fit = true;

  /// The node being dragged, and where on it the pointer grabbed it.
  String? _dragging;
  Offset _grab = Offset.zero;

  /// Hover state: the node or edge under the mouse, and where the mouse is.
  String? _hoverNode;
  GraphEdge? _hoverEdge;
  Offset _hoverAt = Offset.zero;

  /// The last zoom factor of an ongoing trackpad pinch.
  double _pinchScale = 1;

  /// The edges as last laid out, for hover hit tests.
  List<GraphEdgeLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _reset(GraphData.empty);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _reset(GraphData data) {
    _data = data;
    _layout = GraphLayout(
      nodeIds: [for (final n in data.nodes) n.id],
      links: [for (final e in data.edges) (e.from, e.to)],
    );
    _dragging = null;
    _hoverNode = null;
    _hoverEdge = null;
    _syncTicker();
  }

  /// Runs the ticker while the layout is hot; stops it once it settles, so
  /// the view goes idle by itself.
  void _syncTicker() {
    if (_layout.isSettled) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _onTick() {
    setState(_layout.tick);
    _syncTicker();
  }

  Offset _toView(Offset layoutPoint) => layoutPoint * _scale + _translation;

  Offset _toLayout(Offset viewPoint) => (viewPoint - _translation) / _scale;

  Offset _centreOf(String nodeId) => _toView(_layout.positions[nodeId]!);

  /// The top-most node whose hit square contains [viewPoint], or null.
  String? _hitNode(Offset viewPoint) {
    for (final n in _data.nodes.reversed) {
      final square = Rect.fromCircle(
        center: _centreOf(n.id),
        radius: _nodeHitRadius,
      );
      if (square.contains(viewPoint)) return n.id;
    }
    return null;
  }

  /// Scales and centres the view on the whole layout (never past zoom 1).
  void _fitTo(Size size) {
    final bounds = _layout.positions.values
        .fold(Rect.zero, (r, p) => r.expandToInclude(Rect.fromPoints(p, p)))
        .inflate(_fitMargin);
    _scale = math
        .min(size.width / bounds.width, size.height / bounds.height)
        .clamp(_minZoom, 1.0);
    _translation = size.center(Offset.zero) - bounds.center * _scale;
  }

  /// Zooms by [factor] about [focal] (view coordinates), within the zoom
  /// limits.
  void _zoomAt(Offset focal, double factor) {
    final next = (_scale * factor).clamp(_minZoom, _maxZoom);
    setState(() {
      _fit = false;
      _translation = focal - (focal - _translation) * (next / _scale);
      _scale = next;
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (e) => _zoomAt(
          e.localPosition,
          math
              .pow(
                2,
                -(e as PointerScrollEvent).scrollDelta.dy /
                    _wheelPixelsPerDoubling,
              )
              .toDouble(),
        ),
      );
    }
  }

  void _onPinchUpdate(PointerPanZoomUpdateEvent event) {
    _zoomAt(event.localPosition, event.scale / _pinchScale);
    _pinchScale = event.scale;
  }

  void _onPanStart(DragStartDetails details) {
    _fit = false;
    _dragging = _hitNode(details.localPosition);
    if (_dragging case final id?) {
      _grab = _toLayout(details.localPosition) - _layout.positions[id]!;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      switch (_dragging) {
        case final id?:
          _layout.moveNode(id, _toLayout(details.localPosition) - _grab);
          _syncTicker();
        case null:
          _translation += details.delta;
      }
    });
  }

  void _onPanEnd() {
    if (_dragging case final id?) {
      _layout.release(id);
      _syncTicker();
    }
    _dragging = null;
  }

  void _onTapUp(TapUpDetails details) {
    if (_hitNode(details.localPosition) case final id?) {
      ref.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
    }
  }

  void _onHover(PointerHoverEvent event) {
    final at = event.localPosition;
    final node = _hitNode(at);
    setState(() {
      _hoverNode = node;
      _hoverEdge = switch (node) {
        null => hitEdgeLine(_lines, at)?.edge,
        _ => null,
      };
      _hoverAt = at;
    });
  }

  void _onExit(PointerExitEvent _) => setState(() {
    _hoverNode = null;
    _hoverEdge = null;
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: const Key('graph-view'),
      onPointerSignal: _onPointerSignal,
      onPointerPanZoomStart: (_) => _pinchScale = 1,
      onPointerPanZoomUpdate: _onPinchUpdate,
      child: MouseRegion(
        onHover: _onHover,
        onExit: _onExit,
        cursor: switch (_hoverNode) {
          null => MouseCursor.defer,
          _ => SystemMouseCursors.click,
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: _onTapUp,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: (_) => _onPanEnd(),
          onPanCancel: _onPanEnd,
          child: ClipRect(
            child: ColoredBox(
              color: OmColors.surface1,
              // A same-vault reload (or a failed one) hands back the same
              // GraphData, so the layout keeps running undisturbed; only new
              // data, or another vault's empty state, lays out afresh.
              child: VaultAsyncView<GraphData>(
                value: ref.watch(graphDataAsyncProvider(widget.scope)),
                empty: GraphData.empty,
                builder: (context, data) {
                  if (!identical(data, _data)) _reset(data);
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      if (_fit) _fitTo(constraints.biggest);
                      return _buildScene();
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScene() {
    _lines = layoutEdgeLines(_data.edges, _centreOf);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Hulls first: they paint behind the edges and nodes.
        for (final hull in _data.hulls) _hull(hull),
        Positioned.fill(
          child: CustomPaint(
            painter: GraphEdgePainter(lines: _lines, hovered: _hoverEdge),
          ),
        ),
        for (final node in _data.nodes) _node(node),
        if (_data.nodes.isEmpty)
          Center(
            child: Text(
              'Nothing to show in this graph yet.',
              style: OmType.mono(size: 12, color: OmColors.fg3),
            ),
          ),
        if (_hoverEdge case final edge?) _tooltip(edge),
      ],
    );
  }

  Widget _hull(GraphHull hull) {
    final centres = [for (final id in hull.memberIds) _centreOf(id)];
    final bounds = centres.fold(
      Rect.fromPoints(centres.first, centres.first),
      (r, p) => r.expandToInclude(Rect.fromPoints(p, p)),
    );
    return Positioned.fromRect(
      rect: _hullPadding.inflateRect(bounds),
      child: Container(
        key: Key('graph-hull-${hull.folderId}'),
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        decoration: BoxDecoration(
          color: OmColors.line1,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: hull.pinned ? OmColors.accentGlow : OmColors.line2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                hull.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(size: 10, color: OmColors.fg3),
              ),
            ),
            if (hull.pinned) ...[
              const SizedBox(width: 4),
              const Icon(LucideIcons.pin, size: 10, color: OmColors.accent),
            ],
          ],
        ),
      ),
    );
  }

  Widget _node(GraphNode node) {
    final centre = _centreOf(node.id);
    final middle = _nodeBox.center(Offset.zero);
    return Positioned(
      left: centre.dx - middle.dx,
      top: centre.dy - middle.dy,
      width: _nodeBox.width,
      height: _nodeBox.height,
      child: Stack(
        key: Key('graph-node-${node.id}'),
        children: [
          Center(child: _shape(node.kind)),
          if (node.pinned)
            Positioned(
              left: middle.dx + 9,
              top: middle.dy - 5,
              child: const Icon(
                LucideIcons.pin,
                size: 10,
                color: OmColors.accent,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: middle.dy + 10,
            child: Text(
              node.label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: switch (node.kind) {
                GraphNodeKind.daily => OmType.mono(
                  size: 10,
                  color: OmColors.fg2,
                ),
                _ => OmType.sans(size: 11, color: OmColors.fg1, height: 1.3),
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Daily notes are small squares, topic notes circles, other notes
  /// smaller, dimmer circles.
  Widget _shape(GraphNodeKind kind) {
    final (size, color, shape) = switch (kind) {
      GraphNodeKind.daily => (10.0, OmColors.info, BoxShape.rectangle),
      GraphNodeKind.topic => (14.0, OmColors.accentSoft, BoxShape.circle),
      GraphNodeKind.note => (10.0, OmColors.fg2, BoxShape.circle),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: shape,
        border: Border.all(color: OmColors.surface1, width: 1.5),
      ),
    );
  }

  Widget _tooltip(GraphEdge edge) {
    return Positioned(
      left: _hoverAt.dx + 12,
      top: _hoverAt.dy + 12,
      child: IgnorePointer(
        child: Container(
          key: const Key('graph-edge-tooltip'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: OmColors.surface3,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: OmColors.line3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                edge.kind,
                style: OmType.mono(size: 10.5, color: OmColors.accent),
              ),
              if (edge.label case final label?) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: OmType.sans(size: 11.5, color: OmColors.fg0),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
