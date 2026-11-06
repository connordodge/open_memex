import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The sidebar's canvas list (Key `canvases-rail`, one `canvas-row-<id>` row
/// per canvas, 26 px a row, at most six rows tall before it scrolls), or a
/// "no canvases yet." line when [canvases] is empty. Tapping a row opens or
/// focuses that canvas's tab.
class CanvasesRail extends ConsumerWidget {
  const CanvasesRail({super.key, required this.canvases, this.activeCanvasId});
  final List<CanvasRow> canvases;

  /// The canvas whose row is highlighted, if any.
  final String? activeCanvasId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (canvases.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
        child: Text(
          'no canvases yet.',
          style: OmType.mono(size: 11, color: OmColors.fg3),
        ),
      );
    }
    return SizedBox(
      key: const Key('canvases-rail'),
      height: (canvases.length * 26.0).clamp(26.0, 156.0),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        itemCount: canvases.length,
        itemBuilder: (_, i) {
          final c = canvases[i];
          final active = c.canvasId == activeCanvasId;
          return _CanvasRow(
            canvas: c,
            active: active,
            onTap: () =>
                ref.read(tabsProvider.notifier).follow(CanvasTab(c.canvasId)),
          );
        },
      ),
    );
  }
}

class _CanvasRow extends StatefulWidget {
  const _CanvasRow({
    required this.canvas,
    required this.active,
    required this.onTap,
  });
  final CanvasRow canvas;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_CanvasRow> createState() => _CanvasRowState();
}

class _CanvasRowState extends State<_CanvasRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          key: Key('canvas-row-${widget.canvas.canvasId}'),
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          decoration: BoxDecoration(
            color: widget.active
                ? OmColors.surface4
                : (_hover ? OmColors.surface3 : Colors.transparent),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              const SizedBox(width: 11),
              const Icon(
                LucideIcons.layoutDashboard,
                size: 13,
                color: OmColors.fg1,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.canvas.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(
                    size: 13,
                    color: widget.active ? OmColors.fg0 : OmColors.fg1,
                  ),
                ),
              ),
              if (widget.canvas.nodeCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '${widget.canvas.nodeCount}',
                    style: OmType.mono(size: 10.5, color: OmColors.fg3),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
