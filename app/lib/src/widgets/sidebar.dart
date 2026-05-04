import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import '../state/settings.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

/// Left sidebar: brand header → command/search button → vault pills →
/// note tree → agent activity footer (placeholder).
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.onNewNote});
  final VoidCallback onNewNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final currentVault = ref.watch(currentVaultProvider);
    final notes = ref.watch(notesListProvider);
    final selectedId = ref.watch(selectedNoteIdProvider);
    final vaultName = currentVault == null ? '' : p.basename(currentVault);

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
            onAction: () => _switchVault(ref),
          ),
          _VaultPillsRow(currentVault: currentVault),
          const OmHairline(),
          PanelHeader(eyebrow: '$vaultName · tree', action: 'filter'),
          Expanded(
            child: notes.isEmpty
                ? _EmptyTree(onCreate: onNewNote)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    itemCount: notes.length,
                    itemBuilder: (_, i) {
                      final n = notes[i];
                      return _TreeItem(
                        note: n,
                        active: n.id == selectedId,
                        onTap: () =>
                            ref.read(selectedNoteIdProvider.notifier).state =
                                n.id,
                      );
                    },
                  ),
          ),
          const OmHairline(),
          const _AgentFooter(),
        ],
      ),
    );
  }

  Future<void> _switchVault(WidgetRef ref) async {
    await ref.read(settingsProvider.notifier).clearLastVault();
    ref.read(currentVaultProvider.notifier).state = null;
    ref.read(selectedNoteIdProvider.notifier).state = null;
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
        onTap: () async {
          await ref.read(settingsProvider.notifier).rememberVault(path);
          ref.read(currentVaultProvider.notifier).state = path;
          ref.read(selectedNoteIdProvider.notifier).state = null;
        },
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

class _TreeItem extends StatefulWidget {
  const _TreeItem({
    required this.note,
    required this.active,
    required this.onTap,
  });
  final NoteListItem note;
  final bool active;
  final VoidCallback onTap;
  @override
  State<_TreeItem> createState() => _TreeItemState();
}

class _TreeItemState extends State<_TreeItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    const tint = OmColors.fg1;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          key: Key('note-list-item-${widget.note.id}'),
          padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
          decoration: BoxDecoration(
            color: widget.active
                ? OmColors.surface4
                : (_hover ? OmColors.surface3 : Colors.transparent),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              const SizedBox(width: 11),
              const Icon(LucideIcons.fileText, size: 13, color: tint),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(
                    size: 13,
                    color: widget.active ? OmColors.fg0 : OmColors.fg1,
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

class _EmptyTree extends StatelessWidget {
  const _EmptyTree({required this.onCreate});
  final VoidCallback onCreate;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'no notes yet.',
            style: OmType.mono(size: 11.5, color: OmColors.fg3),
          ),
          const SizedBox(height: 12),
          OmButton(
            kind: OmButtonKind.secondary,
            icon: LucideIcons.plus,
            label: 'new note',
            kbd: '⌘N',
            onPressed: onCreate,
          ),
        ],
      ),
    );
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
