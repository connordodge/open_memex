import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/canvas_state.dart';
import '../state/pending_saves.dart';
import '../state/revision_poller.dart';
import '../state/tab_not_loaded.dart';
import '../state/tabs_state.dart';
import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/atoms.dart';
import '../vault_access/errors.dart';
import '../widgets/canvas_view.dart';
import '../widgets/graph/graph_view.dart';
import '../widgets/hosted/not_loaded_state.dart';
import '../widgets/note_editor.dart';
import '../widgets/right_panel.dart';
import '../widgets/sidebar.dart';
import '../widgets/vault_schema_banner.dart';

/// Top-level tabbed shell. Replaces the old single-pane `MainWindow`.
class Workspace extends ConsumerWidget {
  const Workspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The vault-wide revision poller (WI #79) runs while the workspace is up.
    ref.watch(revisionPollerProvider);
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
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    try {
      final id = await guardVaultWrite(
        context,
        () => access.notes.addNote(
          title: 'Untitled',
          contentMd: '# Untitled\n\n',
        ),
      );
      if (id == null) return;
      ref.read(vaultRevisionProvider.notifier).state++;
      ref.read(tabsProvider.notifier).navigate(NoteTab(id));
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
            onClose: () => ref.read(tabsProvider.notifier).closeAt(i),
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
    // A hosted save of this note waits for the vault server (#102).
    final pending =
        tab is NoteTab && ref.watch(notePendingSaveProvider(tab.id));
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
                    if (pending) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'not saved yet',
                        child: StatusDot(
                          key: Key('tab-pending-${tab.tabId}'),
                          state: StatusDotState.cantReach,
                        ),
                      ),
                    ],
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

  String _titleFor(WorkspaceTab tab, WidgetRef ref) =>
      workspaceTabTitle(ref, tab);
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
    final notLoadedServer = ref.watch(tabNotLoadedProvider(active));
    if (notLoadedServer != null) {
      return NotLoadedState(
        title: workspaceTabTitle(ref, active),
        serverName: notLoadedServer,
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
        zoomedNoteId: active.zoomedNoteId,
        rightPanelOpen: rightPanelOpen,
        onToggleRightPanel: onToggleRightPanel,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Renders a canvas tab. Switches between the canvas view and the embedded
/// NoteEditor (double-click zoom-in path) via an `AnimatedSwitcher`. The zoom
/// is the tab's own current history entry ([zoomedNoteId]), so Back and
/// Forward move it and two tabs on one canvas zoom independently. The editor
/// loads the zoomed note because the tabs notifier selects it; this widget
/// writes no selection.
class _CanvasTabContent extends ConsumerWidget {
  const _CanvasTabContent({
    required this.canvasId,
    required this.zoomedNoteId,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
  });
  final String canvasId;
  final String? zoomedNoteId;
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noteId = zoomedNoteId;
    final config = ref.watch(canvasAnimationConfigProvider);
    return AnimatedSwitcher(
      duration: config.zoomDuration,
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: noteId != null
          ? NoteEditor(
              key: Key('zoomed-$noteId'),
              rightPanelOpen: rightPanelOpen,
              onToggleRightPanel: onToggleRightPanel,
            )
          : CanvasView(key: Key('canvas-tab-$canvasId'), canvasId: canvasId),
    );
  }
}
