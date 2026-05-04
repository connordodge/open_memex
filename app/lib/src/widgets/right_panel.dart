import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

enum RightPanelTab { connections, echoes, activity }

final rightPanelTabProvider = StateProvider<RightPanelTab>(
  (_) => RightPanelTab.connections,
);

class RightPanel extends ConsumerWidget {
  const RightPanel({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(rightPanelTabProvider);
    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: OmColors.surface1,
        border: Border(left: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabRow(
            active: tab,
            onChange: (t) => ref.read(rightPanelTabProvider.notifier).state = t,
            onClose: onClose,
          ),
          const OmHairline(),
          Expanded(child: _TabBody(tab: tab)),
        ],
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({
    required this.active,
    required this.onChange,
    required this.onClose,
  });
  final RightPanelTab active;
  final ValueChanged<RightPanelTab> onChange;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _TabButton(
            label: 'connections',
            icon: LucideIcons.workflow,
            active: active == RightPanelTab.connections,
            onTap: () => onChange(RightPanelTab.connections),
          ),
          _TabButton(
            label: 'echoes',
            icon: LucideIcons.history,
            active: active == RightPanelTab.echoes,
            onTap: () => onChange(RightPanelTab.echoes),
          ),
          _TabButton(
            label: 'activity',
            icon: LucideIcons.activity,
            active: active == RightPanelTab.activity,
            onTap: () => onChange(RightPanelTab.activity),
            tone: ChipTone.agent,
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onClose,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(LucideIcons.x, size: 12, color: OmColors.fg3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.tone,
  });
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final ChipTone? tone;

  @override
  Widget build(BuildContext context) {
    final fg = active ? OmColors.fg0 : OmColors.fg2;
    final iconColor = active && tone == ChipTone.agent
        ? OmColors.agent
        : (active ? OmColors.fg0 : OmColors.fg3);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: active ? OmColors.surface3 : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 11, color: iconColor),
              const SizedBox(width: 5),
              Text(label, style: OmType.sans(size: 12, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBody extends ConsumerWidget {
  const _TabBody({required this.tab});
  final RightPanelTab tab;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (tab) {
      RightPanelTab.connections => const _ConnectionsTab(),
      RightPanelTab.echoes => const _PlaceholderTab(
        eyebrow: 'echoes · forgotten threads',
        subtitle:
            'past notes the indexer thinks you\'d want now. all from your own writing — never an outside source.',
        empty:
            'nothing surfaced yet.\nsemantic recall lights this up once embeddings are populated.',
      ),
      RightPanelTab.activity => const _PlaceholderTab(
        eyebrow: 'agent activity · this note',
        subtitle:
            'every read and write by every connected agent. attaches to the audit log when a vault is shared with claude desktop.',
        empty:
            'no activity yet.\nconnect an agent via the MCP server to see what they touch.',
      ),
    };
  }
}

class _ConnectionsTab extends ConsumerWidget {
  const _ConnectionsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedNoteProvider);
    final db = ref.watch(vaultDbProvider);
    if (selected == null || db == null) {
      return const _PlaceholderTab(
        eyebrow: 'knowledge graph · this note',
        subtitle: '',
        empty: 'select a note to see its connections.',
      );
    }
    // Outgoing + incoming links from the new v3 links table.
    // VaultDb may not yet expose these; we render empty state for now and
    // wire it up when Phase 4 lands.
    return ListView(
      children: [
        PanelHeader(
          eyebrow: 'knowledge graph · this note',
          action: 'open graph ↗',
          onAction: () {},
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '${selected.tags.length} tags · ${selected.contentMd.split(RegExp(r"\[\[")).length - 1} wikilinks in body',
            style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
          ),
        ),
        const OmHairline(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Text(
            'connections light up once Phase 4 wires the links table\ninto the editor.',
            textAlign: TextAlign.left,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: OmColors.fg3,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({
    required this.eyebrow,
    required this.subtitle,
    required this.empty,
  });
  final String eyebrow;
  final String subtitle;
  final String empty;
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PanelHeader(eyebrow: eyebrow),
        if (subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              subtitle,
              style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
            ),
          ),
        const OmHairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Text(
            empty,
            textAlign: TextAlign.left,
            style: OmType.mono(size: 11, color: OmColors.fg3, height: 1.6),
          ),
        ),
      ],
    );
  }
}
