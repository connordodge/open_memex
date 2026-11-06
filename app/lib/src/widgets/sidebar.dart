import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart' show CanvasRow;
import '../state/canvas_state.dart';
import '../state/hosted_connection_state.dart';
import '../state/settings.dart';
import '../state/sidebar_mode_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_access_state.dart';
import '../state/vault_open_controller.dart';
import '../state/vault_open_hosted.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_async_view.dart';
import 'atoms.dart';
import 'sidebar/canvases_rail.dart';
import 'sidebar/days_pane.dart';
import 'sidebar/tags_pane.dart';
import 'sidebar/topics_pane.dart';
import 'vault_open_refusal.dart';

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
    final canvasesRead = ref.watch(canvasesAsyncProvider);
    final canvases = watchVaultValue(
      ref,
      canvasesAsyncProvider,
      const <CanvasRow>[],
    );

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
            count: _vaultPillCount(settings),
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
          VaultAsyncView<List<CanvasRow>>(
            value: canvasesRead,
            empty: const <CanvasRow>[],
            builder: (_, canvases) => CanvasesRail(
              canvases: canvases,
              activeCanvasId: activeCanvasId,
            ),
          ),
          const OmHairline(),
          const _SidebarModeSwitch(),
          Expanded(
            child: switch (ref.watch(sidebarModeProvider)) {
              SidebarMode.days => const DaysPane(),
              SidebarMode.topics => const TopicsPane(),
              SidebarMode.tags => const TagsPane(),
            },
          ),
          const OmHairline(),
          const _AgentFooter(),
        ],
      ),
    );
  }

  Future<void> _newCanvas(BuildContext context, WidgetRef ref) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    final title = await _promptCanvasTitle(context);
    if (title == null || title.isEmpty || !context.mounted) return;
    try {
      final c = await guardVaultWrite(
        context,
        () => access.canvas.createCanvas(title: title),
      );
      if (c == null) return;
      ref.read(vaultRevisionProvider.notifier).state++;
      ref.read(tabsProvider.notifier).navigate(CanvasTab(c.canvasId));
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

/// The number of pills [_VaultPillsRow] renders (board A10): every local
/// recent, and every hosted recent whose server is saved.
int _vaultPillCount(AppSettings settings) {
  var count = 0;
  for (final r in settings.recentRefs) {
    switch (r) {
      case LocalVaultRef():
        count++;
      case HostedVaultRef(:final serverId):
        for (final s in settings.savedServers) {
          if (s.id == serverId) count++;
        }
    }
  }
  return count;
}

class _VaultPillsRow extends ConsumerWidget {
  const _VaultPillsRow({required this.currentVault});
  final String? currentVault;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final current = ref.watch(currentVaultProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final r in settings.recentRefs)
            if (r case LocalVaultRef(:final path))
              _VaultPill(path: path, active: path == currentVault)
            else if (r case HostedVaultRef(:final serverId))
              for (final s in settings.savedServers)
                if (s.id == serverId)
                  _HostedVaultPill(
                    key: Key('vault-pill-$serverId-${r.vaultName}'),
                    vault: r,
                    serverName: s.name,
                    active: r == current,
                  ),
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
    return _PillFrame(
      active: active,
      onTap: () => _openFromPill(context, LocalVaultRef(path)),
      children: [
        OmDot(color: _vaultColorFor(name), size: 6),
        const SizedBox(width: 7),
        _PillLabel(name, active: active),
      ],
    );
  }
}

/// A hosted recent (board A10): the server icon in the vault colour,
/// `<vault> · <server>`, and a trailing [StatusDot] for that server's entry
/// in `hostedConnectionStatusProvider` (checking until one exists).
class _HostedVaultPill extends ConsumerWidget {
  const _HostedVaultPill({
    super.key,
    required this.vault,
    required this.serverName,
    required this.active,
  });
  final HostedVaultRef vault;
  final String serverName;
  final bool active;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = hostedVaultLabel(vault.vaultName, serverName);
    final status = ref.watch(hostedConnectionStatusProvider(vault.serverId));
    final state = switch (status) {
      null => StatusDotState.checking,
      HostedConnectionStatus.connected => StatusDotState.connected,
      HostedConnectionStatus.unreachable => StatusDotState.cantReach,
      // Lead ruling (as #97): an incompatible server shows the danger dot.
      HostedConnectionStatus.tokenRejected ||
      HostedConnectionStatus.incompatible => StatusDotState.tokenRejected,
    };
    return _PillFrame(
      active: active,
      onTap: () => _openFromPill(context, vault),
      children: [
        Icon(LucideIcons.server, size: 11, color: _vaultColorFor(label)),
        const SizedBox(width: 7),
        _PillLabel(label, active: active),
        const SizedBox(width: 8),
        Semantics(
          container: true,
          label: switch (state) {
            StatusDotState.connected => 'connected',
            StatusDotState.checking => 'checking',
            StatusDotState.cantReach => hostedUnreachableMessage(serverName),
            StatusDotState.tokenRejected => hostedTokenRejectedMessage(
              serverName,
            ),
          },
          child: StatusDot(
            key: Key('vault-pill-dot-${vault.serverId}-${vault.vaultName}'),
            state: state,
          ),
        ),
      ],
    );
  }
}

/// A vault pill's outline: 26 px high, fully rounded, filled when [active].
class _PillFrame extends StatelessWidget {
  const _PillFrame({
    required this.active,
    required this.onTap,
    required this.children,
  });
  final bool active;
  final VoidCallback onTap;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
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
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

class _PillLabel extends StatelessWidget {
  const _PillLabel(this.text, {required this.active});
  final String text;
  final bool active;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: OmType.mono(size: 11.5, color: active ? OmColors.fg0 : OmColors.fg2),
  );
}

/// A pill's vault colour, hashed from its full label (pack 96).
Color _vaultColorFor(String label) {
  final h = label.hashCode;
  const palette = [
    OmColors.accent,
    OmColors.info,
    OmColors.warn,
    OmColors.agent,
    OmColors.fg2,
  ];
  return palette[h.abs() % palette.length];
}

/// Opens [vault] from its pill: asks the leave guard, then opens it. A
/// refused local folder shows #92's refusal dialog (eyebrow "OPEN LOCAL
/// VAULT"); a failed hosted open keeps the current vault and shows the
/// `pill-open-failed-snackbar` with the recent row's copy and action; any
/// other failure shows its message, as the picker does.
Future<void> _openFromPill(BuildContext context, VaultRef vault) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await container
      .read(vaultOpenControllerProvider)
      .switchToVault(context, vault);
  if (outcome is! VaultOpenFailure) return;
  if (outcome is HostedVaultOpenFailure) {
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        key: const Key('pill-open-failed-snackbar'),
        content: Text(outcome.message),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        action: _hostedFailureAction(context, container, outcome),
      ),
    );
    return;
  }
  if (!context.mounted) return;
  final refused = await showVaultOpenRefusal(
    context,
    outcome,
    eyebrow: 'OPEN LOCAL VAULT',
  );
  if (refused) return;
  messenger?.showSnackBar(SnackBar(content: Text(outcome.message)));
}

/// The recent row's action for a failed hosted open (Req 47): "retry"
/// re-runs the open, "update token" calls the update-token seam, "remove
/// from recents" drops the entry; none for the other outcomes.
SnackBarAction? _hostedFailureAction(
  BuildContext context,
  ProviderContainer container,
  HostedVaultOpenFailure failure,
) {
  SnackBarAction action(String label, VoidCallback onPressed) => SnackBarAction(
    label: label,
    textColor: OmColors.info,
    onPressed: onPressed,
  );
  return switch (failure) {
    HostedServerUnreachable() => action('retry', () {
      if (context.mounted) _openFromPill(context, failure.vault);
    }),
    HostedTokenRejected() => action(
      'update token',
      () => container.read(updateTokenSeamProvider)(failure.vault.serverId),
    ),
    HostedVaultGone() => action(
      'remove from recents',
      () => container.read(settingsProvider.notifier).forgetRef(failure.vault),
    ),
    _ => null,
  };
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
