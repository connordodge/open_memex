import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../state/settings.dart';
import '../state/sidebar_mode_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_open_controller.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';
import 'sidebar/canvases_rail.dart';
import 'sidebar/days_pane.dart';
import 'sidebar/topics_pane.dart';

/// Left sidebar: brand header → command/search button → vault pills →
/// canvases rail → the Days/Topics switch over the Days list or the note
/// tree → agent activity footer (placeholder).
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.onNewNote});
  final VoidCallback onNewNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final currentVault = ref.watch(currentVaultProvider).localPath;
    final activeTab = ref.watch(activeTabProvider);
    final canvases = ref.watch(canvasesProvider);

    final activeCanvasId = activeTab is CanvasTab ? activeTab.id : null;

    return Container(
      width: 268,
      decoration: BoxDecoration(
        color: OmColors.surface1,
        border: Border(right: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BrandRow(),
          const OmHairline(),
          _CommandRow(onTap: () {}),
          PanelHeader(
            eyebrow: 'vaults',
            count: settings.recentVaults.length,
            action: '+ new',
            onAction: () => _switchVault(context, ref),
          ),
          _VaultPillsRow(currentVault: currentVault),
          const OmHairline(),
          PanelHeader(
            eyebrow: 'canvases',
            count: canvases.length,
            action: '+ new',
            onAction: () => _newCanvas(context, ref),
          ),
          CanvasesRail(canvases: canvases, activeCanvasId: activeCanvasId),
          const OmHairline(),
          const _SidebarModeSwitch(),
          Expanded(
            child: switch (ref.watch(sidebarModeProvider)) {
              SidebarMode.days => const DaysPane(),
              SidebarMode.topics => const TopicsPane(),
            },
          ),
          const OmHairline(),
          const _AgentFooter(),
        ],
      ),
    );
  }

  Future<void> _newCanvas(BuildContext context, WidgetRef ref) async {
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider).localPath;
    if (cli == null || vaultPath == null) return;
    final title = await _promptCanvasTitle(context);
    if (title == null || title.isEmpty) return;
    try {
      final c = await cli.createCanvas(vaultPath: vaultPath, title: title);
      ref.read(vaultRevisionProvider.notifier).state++;
      ref.read(tabsProvider.notifier).openOrFocus(CanvasTab(c.canvasId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not create canvas: $e')));
      }
    }
  }

  Future<String?> _promptCanvasTitle(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('New canvas'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Title'),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('new-canvas-confirm'),
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _switchVault(BuildContext context, WidgetRef ref) =>
      ref.read(vaultOpenControllerProvider).leaveVault(context);
}

/// The sidebar's `Days` / `Topics` switch (Req 50; Keys `sidebar-mode-days`,
/// `sidebar-mode-topics`). The choice is saved per vault.
class _SidebarModeSwitch extends ConsumerWidget {
  const _SidebarModeSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sidebarModeProvider);
    void select(SidebarMode next) =>
        ref.read(sidebarModeProvider.notifier).select(next).ignore();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        height: 28,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: OmColors.surface2,
          border: Border.all(color: OmColors.line2, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: _ModeSegment(
                key: const Key('sidebar-mode-days'),
                label: 'Days',
                selected: mode == SidebarMode.days,
                onTap: () => select(SidebarMode.days),
              ),
            ),
            Expanded(
              child: _ModeSegment(
                key: const Key('sidebar-mode-topics'),
                label: 'Topics',
                selected: mode == SidebarMode.topics,
                onTap: () => select(SidebarMode.topics),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? OmColors.surface4 : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: OmType.mono(
                size: 11.5,
                color: selected ? OmColors.fg0 : OmColors.fg2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: OmColors.fg2, width: 1.4),
            ),
            child: Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: OmColors.fg2,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            'open memex',
            style: OmType.mono(
              size: 12.5,
              weight: FontWeight.w500,
              color: OmColors.fg0,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          Text(
            'v0.4',
            style: OmType.mono(
              size: 10,
              color: OmColors.fg3,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: OmColors.surface2,
          border: Border.all(color: OmColors.line2, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.search, size: 13, color: OmColors.fg3),
            const SizedBox(width: 8),
            Text(
              'search · ask · run',
              style: OmType.sans(size: 13, color: OmColors.fg3),
            ),
            const Spacer(),
            const OmKbd('⌘K'),
          ],
        ),
      ),
    );
  }
}

class _VaultPillsRow extends ConsumerWidget {
  const _VaultPillsRow({required this.currentVault});
  final String? currentVault;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(settingsProvider).recentVaults;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final v in recents)
            _VaultPill(path: v, active: v == currentVault),
        ],
      ),
    );
  }
}

class _VaultPill extends ConsumerWidget {
  const _VaultPill({required this.path, required this.active});
  final String path;
  final bool active;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = p.basename(path);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref
            .read(vaultOpenControllerProvider)
            .switchToVault(context, LocalVaultRef(path)),
        child: Container(
          height: 26,
          padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
          decoration: BoxDecoration(
            color: active ? OmColors.surface4 : Colors.transparent,
            border: Border.all(
              color: active ? OmColors.line3 : OmColors.line1,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OmDot(color: _colorFor(name), size: 6),
              const SizedBox(width: 7),
              Text(
                name,
                style: OmType.mono(
                  size: 11.5,
                  color: active ? OmColors.fg0 : OmColors.fg2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _colorFor(String name) {
    final h = name.hashCode;
    const palette = [
      OmColors.accent,
      OmColors.info,
      OmColors.warn,
      OmColors.agent,
      OmColors.fg2,
    ];
    return palette[h.abs() % palette.length];
  }
}

class _AgentFooter extends StatelessWidget {
  const _AgentFooter();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Eyebrow('agents · live'),
              const SizedBox(width: 8),
              const OmDot(color: OmColors.agent, size: 5, pulse: true),
              const Spacer(),
              Text(
                'OPEN API ↗',
                style: OmType.mono(
                  size: 10.5,
                  color: OmColors.fg2,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'no agents connected',
            style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
          ),
          const SizedBox(height: 2),
          Text(
            'wire memex serve into Claude Desktop\nto see live activity here',
            style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
          ),
        ],
      ),
    );
  }
}
