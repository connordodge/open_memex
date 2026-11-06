import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db.dart';
import '../state/tabs_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/vault_async_view.dart';
import '../vault_access/vault_scoped.dart';
import 'activity_tab.dart';
import 'atoms.dart';
import 'panel_placeholder_tab.dart';

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
      RightPanelTab.echoes => const PanelPlaceholderTab(
        eyebrow: 'echoes · forgotten threads',
        subtitle:
            'past notes the indexer thinks you\'d want now. all from your own writing — never an outside source.',
        empty:
            'nothing surfaced yet.\nsemantic recall lights this up once embeddings are populated.',
      ),
      RightPanelTab.activity => const ActivityTab(),
    };
  }
}

/// The Connections tab's two reads, composed so they render together.
class _Connections {
  const _Connections(this.outgoing, this.backlinksByKind);
  final List<LinkRow> outgoing;
  final Map<String, List<BacklinkEntry>> backlinksByKind;
}

class _ConnectionsTab extends ConsumerWidget {
  const _ConnectionsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = watchVaultValue(ref, selectedNoteAsyncProvider, null);
    if (selected == null) {
      return const PanelPlaceholderTab(
        eyebrow: 'knowledge graph · this note',
        subtitle: '',
        empty: 'select a note to see its connections.',
      );
    }

    // Both reads must have current-vault data before rows render, so the
    // hosted loading state covers either one still loading (WI #90 ruling).
    final current = ref.watch(currentVaultProvider);
    final outAsync = ref.watch(linksOutAsyncProvider(selected.id));
    final inAsync = ref.watch(backlinksAsyncProvider(selected.id));
    final outData = currentVaultData(outAsync, current);
    final inData = currentVaultData(inAsync, current);
    final AsyncValue<VaultScoped<_Connections>> combined =
        outData != null && inData != null
        ? AsyncData(
            VaultScoped(current, _Connections(outData.value, inData.value)),
          )
        : outAsync.hasError || inAsync.hasError
        ? AsyncError(
            (outAsync.error ?? inAsync.error)!,
            outAsync.stackTrace ?? inAsync.stackTrace ?? StackTrace.current,
          )
        : const AsyncLoading();

    return VaultAsyncView<_Connections>(
      value: combined,
      empty: const _Connections([], {}),
      builder: (context, data) => _connectionsList(
        selected.tags.length,
        data.outgoing,
        data.backlinksByKind,
      ),
    );
  }

  Widget _connectionsList(
    int tagCount,
    List<LinkRow> outgoing,
    Map<String, List<BacklinkEntry>> backlinksByKind,
  ) {
    final outCount = outgoing.length;
    final inCount = backlinksByKind.values.fold<int>(
      0,
      (sum, list) => sum + list.length,
    );

    return ListView(
      key: const Key('backlinks-panel'),
      children: [
        PanelHeader(
          eyebrow: 'knowledge graph · this note',
          action: 'open graph ↗',
          onAction: () {},
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '$outCount outgoing · $inCount backlinks · $tagCount tags',
            style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
          ),
        ),
        const OmHairline(),
        if (outgoing.isEmpty && backlinksByKind.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: Text(
              'no links yet.\ntype `[[` in the editor to start linking notes.',
              style: OmType.mono(size: 11, color: OmColors.fg3, height: 1.6),
            ),
          )
        else ...[
          if (outgoing.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Eyebrow('outgoing'),
            const SizedBox(height: 4),
            for (final kind in orderedLinkKinds(
              outgoing.map((l) => l.kind),
            )) ...[
              _OutgoingKindGroup(
                kind: kind,
                links: outgoing.where((l) => l.kind == kind).toList(),
              ),
            ],
            const SizedBox(height: 16),
          ],
          if (backlinksByKind.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Eyebrow('backlinks'),
            ),
            const SizedBox(height: 4),
            for (final kind in orderedLinkKinds(backlinksByKind.keys)) ...[
              _BacklinkKindGroup(kind: kind, entries: backlinksByKind[kind]!),
            ],
            const SizedBox(height: 16),
          ],
        ],
      ],
    );
  }
}

class _OutgoingKindGroup extends ConsumerWidget {
  const _OutgoingKindGroup({required this.kind, required this.links});
  final String kind;
  final List<LinkRow> links;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            kind.toUpperCase(),
            style: OmType.mono(
              size: 10.5,
              color: kind == 'references' ? OmColors.fg2 : OmColors.accentSoft,
              letterSpacing: 0.8,
            ),
          ),
        ),
        for (final l in links)
          _LinkRowItem(
            key: Key('outgoing-link-${l.id}'),
            title: l.toNoteId == null ? l.linkText : null,
            ghostTitle: l.toNoteId == null ? l.linkText : null,
            resolvedTitle: l.toNoteId != null ? l.linkText : null,
            label: l.label,
            onTap: l.toNoteId == null
                ? null
                : () => ref
                      .read(tabsProvider.notifier)
                      .follow(NoteTab(l.toNoteId!)),
          ),
      ],
    );
  }
}

class _BacklinkKindGroup extends ConsumerWidget {
  const _BacklinkKindGroup({required this.kind, required this.entries});
  final String kind;
  final List<BacklinkEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            backlinkLabelForKind(kind).toUpperCase(),
            style: OmType.mono(
              size: 10.5,
              color: kind == 'contradicts'
                  ? OmColors.danger
                  : kind == 'extends'
                  ? OmColors.accent
                  : OmColors.fg2,
              letterSpacing: 0.8,
            ),
          ),
        ),
        for (final e in entries)
          _LinkRowItem(
            key: Key('backlink-item-${e.fromNoteId}-${e.linkId}'),
            title: e.fromTitle,
            resolvedTitle: e.fromTitle,
            label: e.label,
            onTap: () => ref
                .read(tabsProvider.notifier)
                .follow(NoteTab(e.fromNoteId)),
          ),
      ],
    );
  }
}

class _LinkRowItem extends StatefulWidget {
  const _LinkRowItem({
    super.key,
    this.title,
    this.ghostTitle,
    this.resolvedTitle,
    this.label,
    this.onTap,
  });
  final String? title;
  final String? ghostTitle;
  final String? resolvedTitle;
  final String? label;
  final VoidCallback? onTap;

  @override
  State<_LinkRowItem> createState() => _LinkRowItemState();
}

class _LinkRowItemState extends State<_LinkRowItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final isGhost = widget.resolvedTitle == null && widget.ghostTitle != null;
    final display = widget.resolvedTitle ?? widget.ghostTitle ?? '?';
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? OmColors.surface3 : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                isGhost ? LucideIcons.fileX : LucideIcons.fileText,
                size: 12,
                color: isGhost ? OmColors.fg3 : OmColors.fg2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(
                    size: 13,
                    color: isGhost ? OmColors.fg3 : OmColors.fg0,
                  ),
                ),
              ),
              if (widget.label != null && widget.label!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  widget.label!,
                  style: OmType.mono(size: 10.5, color: OmColors.fg3),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (isGhost) ...[
                const SizedBox(width: 6),
                Text(
                  'GHOST',
                  style: OmType.mono(
                    size: 9.5,
                    color: OmColors.fg4,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
