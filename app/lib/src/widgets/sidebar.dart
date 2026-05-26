import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import '../state/settings.dart';
import '../state/tabs_state.dart';
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
    final activeTab = ref.watch(activeTabProvider);
    final canvases = ref.watch(canvasesProvider);
    final vaultName = currentVault == null ? '' : p.basename(currentVault);

    final activeNoteId = activeTab is NoteTab ? activeTab.id : null;
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
            onAction: () => _switchVault(ref),
          ),
          _VaultPillsRow(currentVault: currentVault),
          const OmHairline(),
          PanelHeader(
            eyebrow: 'canvases',
            count: canvases.length,
            action: '+ new',
            onAction: () => _newCanvas(context, ref),
          ),
          _CanvasesRail(canvases: canvases, activeCanvasId: activeCanvasId),
          const OmHairline(),
          PanelHeader(
            eyebrow: '$vaultName · tree',
            action: switch (ref.watch(sidebarSortProvider)) {
              NoteSortMode.lastEdited => 'sort: edited',
              NoteSortMode.alphabetical => 'sort: a–z',
            },
            onAction: () {
              final n = ref.read(sidebarSortProvider.notifier);
              n.state = n.state == NoteSortMode.lastEdited
                  ? NoteSortMode.alphabetical
                  : NoteSortMode.lastEdited;
            },
          ),
          Expanded(
            child: notes.isEmpty
                ? _EmptyTree(onCreate: onNewNote)
                : ListView.builder(
                    key: const Key('notes-rail'),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    itemCount: notes.length,
                    itemBuilder: (_, i) {
                      final n = notes[i];
                      return _TreeItem(
                        note: n,
                        active: n.id == activeNoteId,
                        onTap: () => ref
                            .read(tabsProvider.notifier)
                            .openOrFocus(NoteTab(n.id)),
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

  Future<void> _newCanvas(BuildContext context, WidgetRef ref) async {
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider);
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
    final row = Container(
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
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Draggable<String>(
        data: widget.note.id,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 200,
            child: Opacity(opacity: 0.85, child: row),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: GestureDetector(onTap: widget.onTap, child: row),
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

class _CanvasesRail extends ConsumerWidget {
  const _CanvasesRail({required this.canvases, required this.activeCanvasId});
  final List<CanvasRow> canvases;
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
            onTap: () => ref
                .read(tabsProvider.notifier)
                .openOrFocus(CanvasTab(c.canvasId)),
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
