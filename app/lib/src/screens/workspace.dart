import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/canvas_state.dart';
import '../state/graph_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/canvas_view.dart';
import '../widgets/graph/graph_view.dart';
import '../widgets/note_editor.dart';
import '../widgets/right_panel.dart';
import '../widgets/sidebar.dart';
import '../widgets/vault_schema_banner.dart';

/// Top-level tabbed shell. Replaces the old single-pane `MainWindow`.
class Workspace extends ConsumerWidget {
  const Workspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rightOpen = ref.watch(rightPanelOpenProvider);
    return Scaffold(
      backgroundColor: OmColors.surface1,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Sidebar(onNewNote: () => _createNote(context, ref)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const VaultSchemaBanner(),
                const _WorkspaceTabBar(),
                Expanded(
                  child: _TabBody(
                    rightPanelOpen: rightOpen,
                    onToggleRightPanel: () =>
                        ref.read(rightPanelOpenProvider.notifier).state =
                            !rightOpen,
                  ),
                ),
              ],
            ),
          ),
          if (rightOpen)
            RightPanel(
              onClose: () =>
                  ref.read(rightPanelOpenProvider.notifier).state = false,
            ),
        ],
      ),
    );
  }

  Future<void> _createNote(BuildContext context, WidgetRef ref) async {
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider).localPath;
    if (cli == null || vaultPath == null) return;
    try {
      final id = await cli.addNote(
        vaultPath: vaultPath,
        title: 'Untitled',
        contentMd: '# Untitled\n\n',
      );
      ref.read(vaultRevisionProvider.notifier).state++;
      ref.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not create note: $e')));
      }
    }
  }
}

class _WorkspaceTabBar extends ConsumerWidget {
  const _WorkspaceTabBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(tabsProvider);
    if (state.tabs.isEmpty) {
      return const SizedBox(height: 32);
    }
    return Container(
      key: const Key('workspace-tab-bar'),
      height: 32,
      decoration: BoxDecoration(
        color: OmColors.surface1,
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: state.tabs.length,
        itemBuilder: (_, i) {
          final t = state.tabs[i];
          final active = i == state.activeIndex;
          return _TabChip(
            tab: t,
            active: active,
            onTap: () => ref.read(tabsProvider.notifier).setActive(i),
            onClose: () => ref.read(tabsProvider.notifier).close(t),
          );
        },
      ),
    );
  }
}

class _TabChip extends ConsumerWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
  });
  final WorkspaceTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = _titleFor(tab, ref);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: Key('tab-${tab.tabId}'),
          onTap: onTap,
          child: Stack(
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 200),
                padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
                decoration: BoxDecoration(
                  color: active ? OmColors.surface3 : Colors.transparent,
                  border: Border.all(
                    color: active ? OmColors.line2 : OmColors.line1,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      switch (tab) {
                        NoteTab() => LucideIcons.fileText,
                        CanvasTab() => LucideIcons.layoutDashboard,
                        GraphTab() => LucideIcons.network,
                      },
                      size: 11,
                      color: active ? OmColors.fg1 : OmColors.fg3,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.sans(
                          size: 12,
                          color: active ? OmColors.fg0 : OmColors.fg2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // GestureDetector with opaque hit-test, not InkWell — InkWell
                    // defers hits to its child so the outer tab GestureDetector
                    // still sees the tap on the X and "wins" the switch-tab tap.
                    GestureDetector(
                      key: Key('tab-close-${tab.tabId}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onClose,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          LucideIcons.x,
                          size: 11,
                          color: OmColors.fg3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Accent underline spanning the full width of the active tab,
              // flush with its rounded bottom corners.
              if (active)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: 2.5,
                    decoration: const BoxDecoration(
                      color: OmColors.accent,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
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

  String _titleFor(WorkspaceTab tab, WidgetRef ref) {
    if (tab is NoteTab) {
      // The virtual Today note has no row yet: its chip reads its ISO date,
      // like a real daily note's title.
      if (VirtualTodayTab.dateOf(tab.id) case final date?) return date;
      // Read through VaultAccess; `note` until it loads or when it's gone.
      return ref.watch(noteTitleProvider(tab.id)).valueOrNull ?? 'note';
    }
    if (tab is CanvasTab) {
      final summary = ref
          .watch(canvasesProvider)
          .where((c) => c.canvasId == tab.id)
          .toList();
      if (summary.isNotEmpty) return summary.first.title;
      return 'canvas';
    }
    if (tab is GraphTab) {
      return ref.watch(graphTabTitleProvider(tab.scope)).valueOrNull ?? 'Graph';
    }
    return tab.id;
  }
}

class _TabBody extends ConsumerWidget {
  const _TabBody({
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
  });
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeTabProvider);
    if (active == null) {
      return Container(
        key: const Key('empty-workspace'),
        alignment: Alignment.center,
        color: OmColors.surface1,
        child: Text(
          'Open a canvas or note from the left to get started.',
          style: OmType.mono(size: 12, color: OmColors.fg3),
        ),
      );
    }
    if (active is NoteTab) {
      return NoteEditor(
        rightPanelOpen: rightPanelOpen,
        onToggleRightPanel: onToggleRightPanel,
      );
    }
    if (active is GraphTab) {
      // Keyed by scope: another Graph tab gets a fresh view and layout.
      return GraphView(key: ValueKey(active), scope: active.scope);
    }
    if (active is CanvasTab) {
      return _CanvasTabContent(
        canvasId: active.id,
        rightPanelOpen: rightPanelOpen,
        onToggleRightPanel: onToggleRightPanel,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Renders a canvas tab. Switches between the canvas view and the embedded
/// NoteEditor (double-click zoom-in path) via an `AnimatedSwitcher`.
class _CanvasTabContent extends ConsumerWidget {
  const _CanvasTabContent({
    required this.canvasId,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
  });
  final String canvasId;
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(canvasZoomProvider(canvasId));
    final config = ref.watch(canvasAnimationConfigProvider);
    return AnimatedSwitcher(
      duration: config.zoomDuration,
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: zoom.isZoomed
          ? _ZoomedNoteView(
              key: Key('zoomed-${zoom.zoomedNoteId}'),
              canvasId: canvasId,
              noteId: zoom.zoomedNoteId!,
              rightPanelOpen: rightPanelOpen,
              onToggleRightPanel: onToggleRightPanel,
            )
          : CanvasView(key: Key('canvas-tab-$canvasId'), canvasId: canvasId),
    );
  }
}

/// While a canvas tab is "zoomed into" a note, this widget renders the
/// existing NoteEditor with a back-arrow chip overlaid in the top-left.
class _ZoomedNoteView extends ConsumerStatefulWidget {
  const _ZoomedNoteView({
    super.key,
    required this.canvasId,
    required this.noteId,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
  });

  final String canvasId;
  final String noteId;
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  @override
  ConsumerState<_ZoomedNoteView> createState() => _ZoomedNoteViewState();
}

class _ZoomedNoteViewState extends ConsumerState<_ZoomedNoteView> {
  @override
  void initState() {
    super.initState();
    // Force the editor to load this note even though the active tab is a
    // CanvasTab (so the legacy selectedNoteIdProvider isn't pointing at it).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(selectedNoteIdProvider.notifier).state = widget.noteId;
    });
  }

  void _zoomOut() {
    ref.read(canvasZoomProvider(widget.canvasId).notifier).state =
        CanvasZoomState.none;
    // Clear the legacy selection — the canvas tab is the source of truth now.
    ref.read(selectedNoteIdProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    // The "← back to canvas" affordance now lives inline in the editor toolbar
    // (passed via onBackToCanvas) instead of being overlaid, so it no longer
    // collides with the tab bar.
    return NoteEditor(
      rightPanelOpen: widget.rightPanelOpen,
      onToggleRightPanel: widget.onToggleRightPanel,
      onBackToCanvas: _zoomOut,
    );
  }
}
