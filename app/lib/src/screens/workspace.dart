import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/tabs_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/note_editor.dart';
import '../widgets/right_panel.dart';
import '../widgets/sidebar.dart';

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
    final vaultPath = ref.read(currentVaultProvider);
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
    final isCanvas = tab is CanvasTab;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: Key('tab-${tab.tabId}'),
          onTap: onTap,
          child: Container(
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
                  isCanvas ? LucideIcons.layoutDashboard : LucideIcons.fileText,
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
                InkWell(
                  key: Key('tab-close-${tab.tabId}'),
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(2),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(LucideIcons.x, size: 11, color: OmColors.fg3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _titleFor(WorkspaceTab tab, WidgetRef ref) {
    if (tab is NoteTab) {
      final db = ref.watch(vaultDbProvider);
      // No reactive title yet — read once. The rail update on bump will
      // re-render the chip.
      final note = db?.getNote(tab.id);
      return note?.title ?? 'note';
    }
    if (tab is CanvasTab) {
      final summary = ref
          .watch(canvasesProvider)
          .where((c) => c.canvasId == tab.id)
          .toList();
      if (summary.isNotEmpty) return summary.first.title;
      return 'canvas';
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
    if (active is CanvasTab) {
      return _CanvasTabPlaceholder(canvasId: active.id);
    }
    return const SizedBox.shrink();
  }
}

/// Placeholder for the Phase 4 canvas view. Shows the canvas title and a
/// hint that the canvas view is not yet wired.
class _CanvasTabPlaceholder extends ConsumerWidget {
  const _CanvasTabPlaceholder({required this.canvasId});
  final String canvasId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(canvasDetailProvider(canvasId));
    return Container(
      key: Key('canvas-tab-$canvasId'),
      alignment: Alignment.center,
      color: OmColors.surface1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            detail?.title ?? 'canvas',
            style: OmType.mono(size: 14, color: OmColors.fg1),
          ),
          const SizedBox(height: 8),
          Text(
            'canvas view coming in Phase 4',
            style: OmType.mono(size: 11, color: OmColors.fg3),
          ),
          if (detail != null) ...[
            const SizedBox(height: 12),
            Text(
              '${detail.nodes.length} nodes · ${detail.edges.length} edges',
              style: OmType.mono(size: 11, color: OmColors.fg3),
            ),
          ],
        ],
      ),
    );
  }
}
