import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db.dart';
import '../state/canvas_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_async_view.dart';
import 'canvas_edge_painter.dart';

/// Approximate width / height of a node card. Used for laying out and for
/// hit-testing edges that anchor at the card center.
const Size kCanvasNodeSize = Size(168.0, 44.0);

/// Public widget for a single canvas tab. Hosts the InteractiveViewer, the
/// stack of placed nodes, the edge painter, and the floating link popover +
/// edge inspector.
class CanvasView extends ConsumerStatefulWidget {
  const CanvasView({super.key, required this.canvasId});

  final String canvasId;

  @override
  ConsumerState<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends ConsumerState<CanvasView> {
  final _transformController = TransformationController();
  Timer? _moveDebounce;
  final Map<String, Offset> _localOverrides = <String, Offset>{};

  // Drag-to-link state.
  String? _edgeDragSourceId;
  Offset? _edgeDragPointer;
  String? _edgeDragHoverTargetId;

  @override
  void initState() {
    super.initState();
    // Hydrate the InteractiveViewer transform from the saved viewport on the
    // next frame (the provider isn't readable yet during initState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final vp = ref.read(canvasViewportProvider(widget.canvasId));
      _setControllerFromViewport(vp);
    });
  }

  void _setControllerFromViewport(CanvasViewport vp) {
    _transformController.value = Matrix4.identity()
      ..translateByDouble(vp.offset.dx, vp.offset.dy, 0, 1)
      ..scaleByDouble(vp.zoom, vp.zoom, 1, 1);
  }

  void _persistViewportFromController() {
    final m = _transformController.value;
    // Reading translate + uniform scale from the matrix.
    final dx = m.getTranslation().x;
    final dy = m.getTranslation().y;
    final zoom = m.getMaxScaleOnAxis();
    ref.read(canvasViewportProvider(widget.canvasId).notifier).state =
        CanvasViewport(offset: Offset(dx, dy), zoom: zoom);
  }

  @override
  void dispose() {
    _moveDebounce?.cancel();
    _transformController.dispose();
    super.dispose();
  }

  Offset _nodePosition(CanvasNodeRow n) {
    return _localOverrides[n.noteId] ?? Offset(n.x, n.y);
  }

  void _scheduleMovePersist(String noteId, Offset position) {
    final config = ref.read(canvasAnimationConfigProvider);
    _moveDebounce?.cancel();
    _moveDebounce = Timer(config.persistDebounce, () async {
      final access = ref.read(vaultAccessProvider);
      if (access == null || !access.canWrite) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final revision = ref.read(vaultRevisionProvider.notifier);
      try {
        final moved = await guardVaultWrite(
          context,
          () => access.canvas.moveNode(
            canvasId: widget.canvasId,
            noteId: noteId,
            x: position.dx,
            y: position.dy,
          ),
        );
        if (moved == null) return;
        revision.state++;
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text('Move failed: $e')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return VaultAsyncView<CanvasDetailRow?>(
      value: ref.watch(canvasDetailAsyncProvider(widget.canvasId)),
      empty: null,
      builder: _buildDetail,
    );
  }

  Widget _buildDetail(BuildContext context, CanvasDetailRow? detail) {
    final selection = ref.watch(canvasSelectionProvider(widget.canvasId));
    if (detail == null) {
      return Container(
        key: Key('canvas-view-${widget.canvasId}'),
        color: OmColors.surface1,
        alignment: Alignment.center,
        child: Text(
          'Loading canvas…',
          style: OmType.mono(size: 12, color: OmColors.fg3),
        ),
      );
    }
    final nodes = detail.nodes;
    final positions = <String, Offset>{
      for (final n in nodes) n.noteId: _nodePosition(n),
    };

    return Container(
      key: Key('canvas-view-${widget.canvasId}'),
      color: OmColors.surface1,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          // Reject if the dragged note is already placed.
          return !positions.containsKey(details.data);
        },
        onAcceptWithDetails: (details) async {
          final noteId = details.data;
          final localBox = context.findRenderObject() as RenderBox?;
          if (localBox == null) return;
          final local = localBox.globalToLocal(details.offset);
          final canvasCoord = _localToCanvas(local);
          final access = ref.read(vaultAccessProvider);
          if (access == null || !access.canWrite) return;
          final messenger = ScaffoldMessenger.maybeOf(context);
          final revision = ref.read(vaultRevisionProvider.notifier);
          try {
            final placed = await guardVaultWrite(
              context,
              () => access.canvas.addToCanvas(
                canvasId: widget.canvasId,
                noteId: noteId,
                x: canvasCoord.dx,
                y: canvasCoord.dy,
              ),
            );
            if (placed == null) return;
            revision.state++;
          } catch (e) {
            messenger?.showSnackBar(
              SnackBar(content: Text('Could not place note: $e')),
            );
          }
        },
        builder: (context, candidate, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _transformController,
                minScale: 0.1,
                maxScale: 4.0,
                boundaryMargin: const EdgeInsets.all(8000),
                onInteractionEnd: (_) => _persistViewportFromController(),
                child: SizedBox(
                  width: 6000,
                  height: 6000,
                  child: Stack(
                    children: [
                      // Edge layer.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (d) =>
                                _handleCanvasTap(d.localPosition, detail),
                            child: CustomPaint(
                              painter: CanvasEdgePainter(
                                edges: detail.edges,
                                nodePositions: positions,
                                nodeSize: kCanvasNodeSize,
                                selectedEdgeId: selection.selectedEdgeId,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Node layer.
                      ...nodes.map(
                        (n) => _NodeCard(
                          node: n,
                          position: positions[n.noteId]!,
                          canvasId: widget.canvasId,
                          isEdgeDragSource: _edgeDragSourceId == n.noteId,
                          isEdgeDragTarget: _edgeDragHoverTargetId == n.noteId,
                          onDragUpdate: (delta) {
                            setState(() {
                              final existing = positions[n.noteId]!;
                              _localOverrides[n.noteId] = existing + delta;
                            });
                          },
                          onDragEnd: () {
                            final pos = _localOverrides[n.noteId];
                            if (pos != null) {
                              _scheduleMovePersist(n.noteId, pos);
                            }
                          },
                          onDoubleTap: () {
                            ref
                                .read(tabsProvider.notifier)
                                .navigate(
                                  CanvasTab(
                                    widget.canvasId,
                                    zoomedNoteId: n.noteId,
                                  ),
                                );
                          },
                          onEdgeDragStart: () {
                            setState(() {
                              _edgeDragSourceId = n.noteId;
                            });
                          },
                          onEdgeDragUpdate: (global) {
                            final localBox =
                                context.findRenderObject() as RenderBox?;
                            if (localBox == null) return;
                            final local = localBox.globalToLocal(global);
                            final canvas = _localToCanvas(local);
                            // Re-detect hovered node based on canvas coords.
                            String? hovered;
                            for (final entry in positions.entries) {
                              final rect = Rect.fromLTWH(
                                entry.value.dx,
                                entry.value.dy,
                                kCanvasNodeSize.width,
                                kCanvasNodeSize.height,
                              );
                              if (rect.contains(canvas)) {
                                hovered = entry.key;
                                break;
                              }
                            }
                            setState(() {
                              _edgeDragPointer = canvas;
                              _edgeDragHoverTargetId = hovered;
                            });
                          },
                          onEdgeDragEnd: (global) async {
                            final src = _edgeDragSourceId;
                            final tgt = _edgeDragHoverTargetId;
                            setState(() {
                              _edgeDragSourceId = null;
                              _edgeDragPointer = null;
                              _edgeDragHoverTargetId = null;
                            });
                            if (src == null) return;
                            if (tgt == null) return;
                            if (tgt == src) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Can\'t link a note to itself.',
                                  ),
                                ),
                              );
                              return;
                            }
                            await _openLinkPopover(src, tgt);
                          },
                        ),
                      ),
                      // Ghost line during drag-to-link.
                      if (_edgeDragSourceId != null &&
                          _edgeDragPointer != null &&
                          positions.containsKey(_edgeDragSourceId))
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _GhostLinePainter(
                                from:
                                    positions[_edgeDragSourceId]! +
                                    Offset(
                                      kCanvasNodeSize.width / 2,
                                      kCanvasNodeSize.height / 2,
                                    ),
                                to: _edgeDragPointer!,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Empty-state hint.
              if (nodes.isEmpty)
                Center(
                  key: const Key('canvas-empty-state'),
                  child: Text(
                    'Drag a note from the left to get started.',
                    style: OmType.mono(size: 12, color: OmColors.fg3),
                  ),
                ),
              // Edge inspector floats over the canvas when an edge is selected.
              if (selection.selectedEdgeId != null)
                _EdgeInspector(
                  canvasId: widget.canvasId,
                  edge: detail.edges.firstWhere(
                    (e) => e.linkId == selection.selectedEdgeId,
                    orElse: () => detail.edges.first,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Convert a pointer position in the widget's local coordinate space into
  /// the unbounded canvas coordinate space. The InteractiveViewer applies a
  /// uniform-scale + translation transform, so the inverse is just
  /// `(local - translation) / scale`.
  Offset _localToCanvas(Offset local) {
    final m = _transformController.value;
    final tx = m.getTranslation().x;
    final ty = m.getTranslation().y;
    final scale = m.getMaxScaleOnAxis();
    if (scale == 0) return local;
    return Offset((local.dx - tx) / scale, (local.dy - ty) / scale);
  }

  void _handleCanvasTap(Offset localPosition, CanvasDetailRow detail) {
    final positions = <String, Offset>{
      for (final n in detail.nodes) n.noteId: _nodePosition(n),
    };
    final painter = CanvasEdgePainter(
      edges: detail.edges,
      nodePositions: positions,
      nodeSize: kCanvasNodeSize,
      selectedEdgeId: null,
    );
    final hit = painter.hitTestEdge(localPosition);
    final notifier = ref.read(
      canvasSelectionProvider(widget.canvasId).notifier,
    );
    notifier.state = (hit != null)
        ? notifier.state.withEdge(hit)
        : CanvasSelection.empty;
  }

  Future<void> _openLinkPopover(String sourceId, String targetId) async {
    final result = await showDialog<_LinkPopoverResult>(
      context: context,
      builder: (ctx) => const _LinkPopover(),
    );
    if (result == null) return;
    if (!mounted) return;
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final revision = ref.read(vaultRevisionProvider.notifier);
    try {
      final added = await guardVaultWrite(
        context,
        () => access.notes.addLink(
          fromNoteId: sourceId,
          toNoteId: targetId,
          kind: result.kind,
          label: result.label,
        ),
      );
      if (added == null) return;
      revision.state++;
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not add link: $e')),
      );
    }
  }
}

class _NodeCard extends ConsumerWidget {
  const _NodeCard({
    required this.node,
    required this.position,
    required this.canvasId,
    required this.isEdgeDragSource,
    required this.isEdgeDragTarget,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDoubleTap,
    required this.onEdgeDragStart,
    required this.onEdgeDragUpdate,
    required this.onEdgeDragEnd,
  });

  final CanvasNodeRow node;
  final Offset position;
  final String canvasId;
  final bool isEdgeDragSource;
  final bool isEdgeDragTarget;
  final void Function(Offset delta) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDoubleTap;
  final VoidCallback onEdgeDragStart;
  final void Function(Offset globalPosition) onEdgeDragUpdate;
  final void Function(Offset globalPosition) onEdgeDragEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        key: Key('canvas-node-${node.noteId}'),
        onDoubleTap: onDoubleTap,
        onPanUpdate: (d) => onDragUpdate(d.delta),
        onPanEnd: (_) => onDragEnd(),
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: kCanvasNodeSize.width,
                height: kCanvasNodeSize.height,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: OmColors.surface3,
                  border: Border.all(
                    color: isEdgeDragTarget
                        ? OmColors.accent
                        : (isEdgeDragSource ? OmColors.accent : OmColors.line2),
                    width: isEdgeDragTarget ? 1.5 : 1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.fileText,
                      size: 13,
                      color: OmColors.fg2,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.noteTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.sans(size: 12, color: OmColors.fg0),
                      ),
                    ),
                  ],
                ),
              ),
              // Edge handle pip on the right border. Lives just inside the
              // card so hit-testing always succeeds; opaque hit behavior
              // claims the pointer before the outer card's pan recognizer
              // gets a chance to win the gesture arena (otherwise dragging
              // from the pip just moves the whole node).
              Positioned(
                right: 0,
                top: kCanvasNodeSize.height / 2 - 9,
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: GestureDetector(
                    key: Key('edge-handle-${node.noteId}'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => onEdgeDragStart(),
                    onPanUpdate: (d) => onEdgeDragUpdate(d.globalPosition),
                    onPanEnd: (d) => onEdgeDragEnd(d.globalPosition),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: OmColors.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: OmColors.surface1, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostLinePainter extends CustomPainter {
  _GhostLinePainter({required this.from, required this.to});
  final Offset from;
  final Offset to;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = OmColors.accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(from, to, paint);
  }

  @override
  bool shouldRepaint(covariant _GhostLinePainter old) =>
      old.from != from || old.to != to;
}

class _LinkPopoverResult {
  _LinkPopoverResult({required this.kind, required this.label});
  final String kind;
  final String? label;
}

class _LinkPopover extends StatefulWidget {
  const _LinkPopover();

  @override
  State<_LinkPopover> createState() => _LinkPopoverState();
}

class _LinkPopoverState extends State<_LinkPopover> {
  static const builtIns = [
    'references',
    'extends',
    'contradicts',
    'example-of',
  ];
  String _kind = 'references';
  final TextEditingController _labelCtrl = TextEditingController();

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('link-popover'),
      title: const Text('New link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in builtIns)
                FilterChip(
                  key: Key('edge-kind-chip-$k'),
                  selected: _kind == k,
                  label: Text(k),
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('edge-label-input'),
            controller: _labelCtrl,
            decoration: const InputDecoration(labelText: 'Label (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('link-popover-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('link-popover-confirm'),
          onPressed: () => Navigator.of(context).pop(
            _LinkPopoverResult(
              kind: _kind,
              label: _labelCtrl.text.trim().isEmpty
                  ? null
                  : _labelCtrl.text.trim(),
            ),
          ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _EdgeInspector extends ConsumerStatefulWidget {
  const _EdgeInspector({required this.canvasId, required this.edge});
  final String canvasId;
  final CanvasEdgeRow edge;

  @override
  ConsumerState<_EdgeInspector> createState() => _EdgeInspectorState();
}

class _EdgeInspectorState extends ConsumerState<_EdgeInspector> {
  late TextEditingController _labelCtrl;
  late String _kind;
  String? _hydratedFor;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController();
    _hydrate();
  }

  void _hydrate() {
    if (_hydratedFor == widget.edge.linkId) return;
    _hydratedFor = widget.edge.linkId;
    _kind = widget.edge.kind;
    _labelCtrl.text = widget.edge.label ?? '';
  }

  @override
  void didUpdateWidget(covariant _EdgeInspector old) {
    super.didUpdateWidget(old);
    _hydrate();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final revision = ref.read(vaultRevisionProvider.notifier);
    final selection = ref.read(
      canvasSelectionProvider(widget.canvasId).notifier,
    );
    try {
      final updated = await guardVaultWrite(
        context,
        () => access.notes.updateLink(
          linkId: widget.edge.linkId,
          kind: _kind != widget.edge.kind ? _kind : null,
          label: _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim(),
          clearLabel:
              _labelCtrl.text.trim().isEmpty &&
              (widget.edge.label?.isNotEmpty ?? false),
        ),
      );
      if (updated == null) return;
      revision.state++;
      selection.state = CanvasSelection.empty;
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const builtIns = ['references', 'extends', 'contradicts', 'example-of'];
    return Positioned(
      key: const Key('edge-inspector'),
      right: 16,
      top: 16,
      child: Material(
        elevation: 6,
        color: OmColors.surface2,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 260,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'Edit link',
                    style: OmType.mono(size: 11, color: OmColors.fg2),
                  ),
                  const Spacer(),
                  IconButton(
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(LucideIcons.x),
                    onPressed: () {
                      ref
                          .read(
                            canvasSelectionProvider(widget.canvasId).notifier,
                          )
                          .state = CanvasSelection
                          .empty;
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final k in builtIns)
                    FilterChip(
                      key: Key('edge-kind-chip-$k'),
                      selected: _kind == k,
                      label: Text(k),
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('edge-label-input'),
                controller: _labelCtrl,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
