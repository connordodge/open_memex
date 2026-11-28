import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart' show CanvasRow;
import '../state/app_version.dart';
import '../state/backup_controller.dart';
import '../state/canvas_state.dart';
import '../state/hosted_connection_state.dart';
import '../state/settings.dart';
import '../state/sidebar_mode_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_open_controller.dart';
import '../state/vault_open_hosted.dart';
import '../state/vault_paths.dart';
import '../state/vault_state.dart';
import '../state/workspace_actions.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../updater/update_controller.dart';
import '../updater/update_modal.dart';
import '../updater/update_state.dart';
import '../vault_access/vault_async_view.dart';
import 'agents/agent_footer.dart';
import 'atoms.dart';
import 'backups/backup_entry.dart';
import 'command_palette/command_palette.dart';
import 'command_palette/palette_row.dart' show PaletteKeys;
import 'dialog_button.dart' show keyboardButtonShortcuts;
import 'picker/vault_picker_modal.dart';
import 'sidebar/canvases_rail.dart';
import 'sidebar/days_pane.dart';
import 'sidebar/tags_pane.dart';
import 'sidebar/topics_pane.dart';
import 'vault_color.dart';
import 'vault_menu.dart';
import 'vault_open_refusal.dart';

/// Left sidebar: brand header → command/search button → vault pills →
/// canvases rail → the Days/Topics switch over the Days list or the note
/// tree → agent activity footer (placeholder).
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.onNewNote, this.onCommandBar});
  final VoidCallback onNewNote;

  /// The Command bar's press. Null opens the Command palette over the
  /// sidebar's context.
  final VoidCallback? onCommandBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // D23: keeps the app-wide backup controller (schedule, hosted status)
    // alive; Sidebar is always mounted.
    ref.watch(backupControllerProvider);
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
          _CommandBar(
            onPressed: onCommandBar ?? () => showCommandPalette(context),
          ),
          PanelHeader(
            eyebrow: 'vaults',
            count: _vaultPillCount(settings),
            padding: _vaultsHeaderPadding,
            trailing: const _ManageButton(),
          ),
          _VaultPillsRow(currentVault: currentVault),
          const BackupEntry(),
          const OmHairline(),
          PanelHeader(
            eyebrow: 'canvases',
            count: canvases.length,
            action: '+ new',
            onAction: () => newCanvas(context),
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
          const AgentFooter(),
        ],
      ),
    );
  }
}

/// The VAULTS header's padding (pack 363, S1): R8.5 so MANAGE's text lines
/// up 16 from the edge, and the top and bottom each taken in by half of what
/// the 22-high button adds over the 16.5-high eyebrow, so the header stays
/// 41 high with the eyebrow where it was.
const _vaultsHeaderPadding = EdgeInsets.fromLTRB(16, 11.25, 8.5, 7.25);

/// The VAULTS header's MANAGE button (key `sidebar-vaults-manage`, pack
/// 363, S1): 57x22 at text scale 1, growing with a larger text scale so the
/// label stays inside its outline; radius 4. It opens the vault picker modal over the open
/// vault and draws pressed (`surface4` fill and border, `fg0` text) until
/// that modal closes; a press while it shows opens nothing more. It takes
/// the keyboard focus with a 1px `accentSoft` ring; Enter or Space press it
/// once per key press (repeats are ignored).
class _ManageButton extends StatefulWidget {
  const _ManageButton();

  @override
  State<_ManageButton> createState() => _ManageButtonState();
}

class _ManageButtonState extends State<_ManageButton> {
  /// True from a press until the modal it opened closes.
  bool _pressed = false;
  bool _highlight = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _press()),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: (_) => _press(),
    ),
  };

  void _press() {
    if (_pressed) return;
    setState(() => _pressed = true);
    unawaited(
      showVaultPickerModal(context).whenComplete(() {
        if (mounted) setState(() => _pressed = false);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final border = _pressed
        ? OmColors.surface4
        : _highlight
        ? OmColors.accentSoft
        : Colors.transparent;
    return ConstrainedBox(
      key: const Key('sidebar-vaults-manage'),
      constraints: const BoxConstraints(minWidth: 57, minHeight: 22),
      child: FocusableActionDetector(
        shortcuts: keyboardButtonShortcuts,
        actions: _actions,
        onShowFocusHighlight: (v) => setState(() => _highlight = v),
        child: Semantics(
          button: true,
          label: 'manage vaults: open the vault picker',
          onTap: _press,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _press,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _pressed ? OmColors.surface4 : null,
                  border: Border.all(color: border, width: 1),
                  borderRadius: BorderRadius.circular(4),
                ),
                // Sized by its label (at least 57x22), the label centred.
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 3,
                      horizontal: 6,
                    ),
                    child: Text(
                      'manage'.toUpperCase(),
                      maxLines: 1,
                      softWrap: false,
                      style: OmType.mono(
                        size: 10.5,
                        color: _pressed ? OmColors.fg0 : OmColors.fg2,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sidebar's `Days` / `Topics` / `Tags` switch (Req 50; Keys
/// `sidebar-mode-days`, `sidebar-mode-topics`, `sidebar-mode-tags`). The choice is saved per vault.
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
            Expanded(
              child: _ModeSegment(
                key: const Key('sidebar-mode-tags'),
                label: 'Tags',
                selected: mode == SidebarMode.tags,
                onTap: () => select(SidebarMode.tags),
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

/// The sidebar's brand row: the ring logo, `open memex` and the version
/// label (D15). While an update is Ready the logo-to-title gap and the end
/// padding narrow by [_readyGapSaving] and [_readyPaddingSaving], so the
/// whole `v<current> · update ready` fits at text scale 1.0 (lead ruling Q1,
/// #38); every other state keeps the row's geometry.
class _BrandRow extends ConsumerWidget {
  static const _padding = 14.0;
  static const _gap = 9.0;
  static const _readyGapSaving = 3.0;
  static const _readyPaddingSaving = 5.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    final ready = ref.watch(
      updateControllerProvider.select((s) => s is UpdateReady),
    );
    return Container(
      height: 44,
      padding: EdgeInsetsDirectional.only(
        start: _padding,
        end: ready ? _padding - _readyPaddingSaving : _padding,
      ),
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
          SizedBox(width: ready ? _gap - _readyGapSaving : _gap),
          Text(
            'open memex',
            style: OmType.mono(
              size: 12.5,
              weight: FontWeight.w500,
              color: OmColors.fg0,
              letterSpacing: 0.2,
            ),
          ),
          if (version.isNotEmpty)
            // Expanded + Align, not a Spacer: the label sits at the row end
            // and, at a larger text scale, ellipsizes instead of overflowing.
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: UpdateVersionLabel(
                  textKey: const Key('sidebar-version-label'),
                  version: version,
                  // The row's own height: the Ready label's click target
                  // spans it without growing the row.
                  hitHeight: 44,
                  style: OmType.mono(
                    size: 10,
                    color: OmColors.fg3,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The Command bar (board C3, pack 77; key `command-bar`): a 244x32 button
/// under the brand block that opens the Command palette on a click, or on
/// Enter or Space while it has the keyboard focus (once per key press).
/// Label `search · ask · run` and the `⌘K` chip. Rest: `surface2` fill,
/// `line2` border, `fg3` icon, `fg2` label; hover: `surface3`, `line3`,
/// `fg2` icon, `fg1` label; open (while the palette shows): `surface4`,
/// `line3`, `fg2`, `fg1`; keyboard focus: the rest look with an
/// `accentSoft` border.
class _CommandBar extends ConsumerStatefulWidget {
  const _CommandBar({required this.onPressed});
  final VoidCallback onPressed;

  @override
  ConsumerState<_CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends ConsumerState<_CommandBar> {
  bool _hover = false;
  bool _focus = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) => widget.onPressed(),
    ),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: (_) => widget.onPressed(),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(commandPaletteOpenProvider);
    final lit = open || _hover;
    final fill = open
        ? OmColors.surface4
        : _hover
        ? OmColors.surface3
        : OmColors.surface2;
    final border = lit
        ? OmColors.line3
        : _focus
        ? OmColors.accentSoft
        : OmColors.line2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Semantics(
        key: PaletteKeys.commandBar,
        container: true,
        button: true,
        label: 'Command bar: search, ask, run. Command K.',
        onTap: widget.onPressed,
        child: FocusableActionDetector(
          shortcuts: keyboardButtonShortcuts,
          actions: _actions,
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) => setState(() => _focus = v),
          child: ExcludeSemantics(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onPressed,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    border: Border.all(color: border, width: 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 32),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.search,
                            size: 14,
                            color: lit ? OmColors.fg2 : OmColors.fg3,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'search · ask · run',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: OmType.sans(
                                size: 13,
                                height: 16 / 13,
                                color: lit ? OmColors.fg1 : OmColors.fg2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const _CommandKChip(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Command bar's `⌘K` chip: at least 30x18, padding 5, 1 px `line3`
/// border, radius 4; `⌘` in sans and `K` in mono, both 10.5 in `fg2`.
class _CommandKChip extends StatelessWidget {
  const _CommandKChip();

  @override
  Widget build(BuildContext context) {
    final sans = OmType.sans(
      size: 10.5,
      color: OmColors.fg2,
      height: 1.2,
      letterSpacing: 0.2,
    );
    final mono = OmType.mono(
      size: 10.5,
      color: OmColors.fg2,
      height: 1.2,
      letterSpacing: 0.2,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 30, minHeight: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: OmColors.line3),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '⌘', style: sans),
                  TextSpan(text: 'K', style: mono),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
          ),
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
              _localPill(r, path)
            else if (r case HostedVaultRef(:final serverId))
              for (final s in settings.savedServers)
                if (s.id == serverId)
                  _PillMenu(
                    key: Key('vault-pill-$serverId-${r.vaultName}'),
                    vault: r,
                    isOpen: r == current,
                    builder: (menuOpen) => _HostedVaultPill(
                      vault: r,
                      serverName: s.name,
                      active: r == current,
                      menuOpen: menuOpen,
                    ),
                  ),
        ],
      ),
    );
  }

  /// The pill for the local recent [r] at [path]. It is the open (and
  /// active) pill when [path] names the open vault's folder in any spelling
  /// ([isSameVaultFolder]): recents keep a vault's path as it was opened.
  Widget _localPill(LocalVaultRef r, String path) {
    final open = currentVault;
    final isOpen = open != null && isSameVaultFolder(path, open);
    // Keyed by vault so an open menu stays with its own vault when a switch
    // reorders the recents.
    return _PillMenu(
      key: ValueKey<VaultRef>(r),
      vault: r,
      isOpen: isOpen,
      builder: (menuOpen) =>
          _VaultPill(path: path, active: isOpen, menuOpen: menuOpen),
    );
  }
}

/// A pill's vault menu (#361's [VaultMenuRegion], Spec #357 Req 19, 26): a
/// secondary click opens [vault]'s items then `manage…`, which opens the
/// vault picker modal. [builder] draws the pill, told whether its menu is
/// open (pack 363, S2: `surface3` / `line3`).
class _PillMenu extends StatefulWidget {
  const _PillMenu({
    super.key,
    required this.vault,
    required this.isOpen,
    required this.builder,
  });
  final VaultRef vault;
  final bool isOpen;
  final Widget Function(bool menuOpen) builder;

  @override
  State<_PillMenu> createState() => _PillMenuState();
}

class _PillMenuState extends State<_PillMenu> {
  bool _menuOpen = false;

  void _onOpenChanged(bool open) {
    void apply() {
      if (mounted && _menuOpen != open) setState(() => _menuOpen = open);
    }

    // A menu closed mid-build restyles its pill once the frame is drawn.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) => VaultMenuRegion(
    vault: widget.vault,
    isOpen: widget.isOpen,
    onManage: () => unawaited(showVaultPickerModal(context)),
    onOpenChanged: _onOpenChanged,
    child: widget.builder(_menuOpen),
  );
}

class _VaultPill extends ConsumerWidget {
  const _VaultPill({
    required this.path,
    required this.active,
    required this.menuOpen,
  });
  final String path;
  final bool active;
  final bool menuOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = p.basename(path);
    return _PillFrame(
      active: active,
      menuOpen: menuOpen,
      onTap: () => _openFromPill(context, LocalVaultRef(path)),
      children: [
        Icon(LucideIcons.folder, size: 11, color: vaultColorFor(name)),
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
    required this.vault,
    required this.serverName,
    required this.active,
    required this.menuOpen,
  });
  final HostedVaultRef vault;
  final String serverName;
  final bool active;
  final bool menuOpen;
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
      menuOpen: menuOpen,
      onTap: () => _openFromPill(context, vault),
      children: [
        Icon(LucideIcons.server, size: 11, color: vaultColorFor(label)),
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

/// A vault pill's outline: 26 px high, fully rounded; `surface4` / `line3`
/// when [active], else `surface3` / `line3` while its menu is open
/// ([menuOpen]), else no fill and `line1`.
class _PillFrame extends StatelessWidget {
  const _PillFrame({
    required this.active,
    required this.menuOpen,
    required this.onTap,
    required this.children,
  });
  final bool active;
  final bool menuOpen;
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
            color: active
                ? OmColors.surface4
                : menuOpen
                ? OmColors.surface3
                : Colors.transparent,
            border: Border.all(
              color: active || menuOpen ? OmColors.line3 : OmColors.line1,
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
