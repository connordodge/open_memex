// The Agents sheet shell (Spec #394 req 1, 6-12, 44, 46-47; WI #407).
//
// Seam contract for the tab WIs (#410 Live, #411 Connect, #412 Tools,
// #413 Semantic recall). Frozen: each tab WI edits only its own pair of
// files.
//
// - `widgets/agents_sheet/<tab>_tab.dart` exports the tab body widget
//   (`LiveTab`, `ConnectTab`, `ToolsTab`, `RecallTab`), taking no required
//   argument beyond `key`. The shell shows the active tab's widget in the
//   scrolling body.
// - `state/agents_sheet/<tab>_tab_state.dart` exports the chip's badge
//   provider: `liveTabBadgeProvider` (String? suffix, `2 connected`),
//   `toolsTabBadgeProvider` (String? suffix, `37 tools`),
//   `recallTabDotProvider` (bool?: true accent dot, false fg2 dot, null no
//   dot). Connect has none. The shell ships them returning null.
// - `agentsSheetTabProvider` (state/agents_sheet/agents_sheet_state.dart) is
//   the open sheet's active `AgentsTab`; `select(AgentsTab)` switches tabs.
// - `AgentsTabLoading` (agents_tab_loading.dart) is the shared loading
//   state: empty, then `loading…` in fg2 from 400 ms on `clockProvider`.
// - Tests pump the sheet with `pumpAgentsSheet(tester, overrides: …)`
//   (test/support/agents_sheet_harness.dart); tab WIs add their fakes
//   through `overrides`, never by editing the harness.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../state/agent_activity.dart';
import '../../state/agents_sheet/agents_sheet_state.dart';
import '../../state/agents_sheet/live_tab_state.dart';
import '../../state/agents_sheet/recall_tab_state.dart';
import '../../state/agents_sheet/tools_tab_state.dart';
import '../../state/app_exit.dart';
import '../../state/clock.dart';
import '../../state/hosted_identity.dart';
import '../../state/url_opener.dart';
import '../../state/vault_open_hosted.dart' show hostedVaultLabel;
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'connect_tab.dart';
import 'live_tab.dart';
import 'recall_tab.dart';
import 'tools_tab.dart';

/// The docs link's target on a local vault (Spec #394 req 11).
const agentsLocalDocsUrl =
    'https://github.com/connordodge/open_memex/blob/main/docs/claude-desktop-setup.md';

/// The docs link's target on a hosted vault (Spec #394 req 11).
const agentsHostedDocsUrl =
    'https://github.com/connordodge/open_memex/blob/main/docs/hosted-vault.md';

/// The sheet's width in a window of at least [_narrowBelow] (req 8).
const _sheetWidth = 720.0;

/// Below this window width the sheet is the window minus 16 px each side.
const _narrowBelow = _sheetWidth + 32;

/// How long the sheet waits for agent activity before it opens on Connect
/// (req 10).
const _openingTabWindow = Duration(milliseconds: 300);

/// The root navigators that have an Agents sheet open. Per navigator, not
/// process-wide, so an app that is torn down with the sheet open (a test)
/// leaves nothing behind.
final _openSheets = Expando<bool>('agents sheet open');

/// Opens the Agents sheet. The one entry function every entry point calls
/// (the status bar button, the footer link, Window ▸ Agents…). While a
/// sheet is open, or while another modal route covers [context] (Backups,
/// hosted setup, any dialog), it does nothing: sheets never stack (req 6).
/// Completes when the sheet closes.
Future<void> openAgentsSheet(BuildContext context) async {
  if (ModalRoute.isCurrentOf(context) == false) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_openSheets[navigator] ?? false) return;
  _openSheets[navigator] = true;
  // The sheet is built under the root navigator, outside the caller's
  // subtree: hand it the caller's container.
  final container = ProviderScope.containerOf(context, listen: false);
  final route = RawDialogRoute<void>(
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: OmColors.surface0.withAlpha(184),
    transitionDuration: const Duration(milliseconds: 150),
    // Focus is trapped in the sheet: Tab wraps round inside it (req 12).
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    pageBuilder: (context, _, _) => UncontrolledProviderScope(
      container: container,
      child: const _AgentsSheet(),
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  try {
    await navigator.push<void>(route);
  } finally {
    _releaseWhenFaded(navigator, route.animation);
  }
}

/// Clears [navigator]'s open-sheet mark once the closing sheet has faded
/// out, not when the close starts, so a reopen during the 150 ms fade
/// does not stack a second sheet on the fading one.
void _releaseWhenFaded(NavigatorState navigator, Animation<double>? fade) {
  if (fade == null || fade.isDismissed) {
    _openSheets[navigator] = null;
    return;
  }
  late final AnimationStatusListener listener;
  listener = (status) {
    if (status != AnimationStatus.dismissed) return;
    fade.removeStatusListener(listener);
    _openSheets[navigator] = null;
  };
  fade.addStatusListener(listener);
}

/// Attaches Window ▸ Agents… (`openAgents` on `windowMenuHostProvider`) to
/// [openAgentsSheet] while it is mounted (D24: the workspace appends it).
/// Builds nothing.
class AgentsWindowMenuAttach extends ConsumerStatefulWidget {
  const AgentsWindowMenuAttach({super.key});

  @override
  ConsumerState<AgentsWindowMenuAttach> createState() =>
      _AgentsWindowMenuAttachState();
}

class _AgentsWindowMenuAttachState
    extends ConsumerState<AgentsWindowMenuAttach> {
  late final WindowMenuHost _host;

  @override
  void initState() {
    super.initState();
    _host = ref.read(windowMenuHostProvider);
    _host.attach(onOpenAgents: _openAgents);
  }

  void _openAgents() {
    if (mounted) unawaited(openAgentsSheet(context));
  }

  @override
  void dispose() {
    _host.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The editor status bar's `agents ⇧⌘A` button (req 3): mono 10.5, fg2,
/// fg0 while hovered; a tap opens the sheet. ⇧⌘A itself is the native
/// menu's (req 4), so nothing here handles keys.
class AgentsStatusBarButton extends StatefulWidget {
  const AgentsStatusBarButton({super.key});

  @override
  State<AgentsStatusBarButton> createState() => _AgentsStatusBarButtonState();
}

class _AgentsStatusBarButtonState extends State<AgentsStatusBarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(openAgentsSheet(context)),
          child: Text(
            'agents ⇧⌘A',
            style: OmType.mono(
              size: 10.5,
              color: _hover ? OmColors.fg0 : OmColors.fg2,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sheet

class _AgentsSheet extends ConsumerStatefulWidget {
  const _AgentsSheet();

  @override
  ConsumerState<_AgentsSheet> createState() => _AgentsSheetState();
}

class _AgentsSheetState extends ConsumerState<_AgentsSheet> {
  final _chipNodes = {
    for (final tab in AgentsTab.values)
      tab: FocusNode(debugLabel: 'agents tab ${tab.name}'),
  };

  /// The opening-tab choice is made (req 10); until then no tab is active
  /// and the body is empty. Once made, the sheet never switches by itself.
  bool _decided = false;

  /// Fires the Connect fallback [_openingTabWindow] after opening.
  Timer? _fallback;

  /// The vault the sheet opened for. The chip and docs link show it, and
  /// the sheet closes when the current vault changes or goes away (a
  /// hosted vault the server no longer has), so it never outlives it.
  late final VaultRef? _vault;

  @override
  void initState() {
    super.initState();
    _vault = ref.read(currentVaultProvider);
    ref.listenManual(currentVaultProvider, (_, next) {
      if (next != _vault) scheduleMicrotask(_closeForVault);
    });
    _fallback = ref
        .read(clockProvider)
        .after(_openingTabWindow, () => _decide(AgentsTab.connect));
    ref.listenManual(agentActivityAsyncProvider, (_, next) => _consider(next));
    ref.listenManual(agentsSheetTabProvider, (_, _) => _onTabChanged());
    // The first look waits a microtask: choosing a tab changes a provider,
    // which Riverpod forbids while the tree builds.
    scheduleMicrotask(() {
      if (mounted) _consider(ref.read(agentActivityAsyncProvider));
    });
  }

  @override
  void dispose() {
    _fallback?.cancel();
    for (final node in _chipNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Opens on Live once activity has settled with at least one connected
  /// agent on a server that reports activity; on Connect when it settled
  /// with none, unavailable or errored. A load still in flight, including a
  /// reload that carries the previous vault's value (D31), waits for the
  /// fallback.
  void _consider(AsyncValue<AgentActivityView> activity) {
    if (_decided || activity.isLoading) return;
    final view = activity.hasError ? null : activity.valueOrNull;
    final live = view != null && view.available && view.connected.isNotEmpty;
    scheduleMicrotask(() => _decide(live ? AgentsTab.live : AgentsTab.connect));
  }

  void _decide(AgentsTab tab) {
    if (_decided || !mounted) return;
    _choose(tab);
  }

  /// Makes [tab] active: the opening choice, a tap or an arrow key.
  void _choose(AgentsTab tab) {
    _fallback?.cancel();
    if (!_decided) setState(() => _decided = true);
    if (ref.read(agentsSheetTabProvider) == tab) {
      _revealActive();
    } else {
      ref.read(agentsSheetTabProvider.notifier).select(tab);
    }
  }

  /// A tab changed, here or through `select` from a tab body.
  void _onTabChanged() {
    if (!mounted) return;
    _fallback?.cancel();
    if (!_decided) setState(() => _decided = true);
    _revealActive();
  }

  /// After the next layout: scrolls the active chip fully into the tab
  /// row's view (ruling 11) and gives it the focus (req 12).
  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _chipNodes[ref.read(agentsSheetTabProvider)]!;
      final chip = node.context;
      if (chip == null) return;
      unawaited(
        Scrollable.ensureVisible(
          chip,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
      unawaited(
        Scrollable.ensureVisible(
          chip,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
      node.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Left and Right on a focused chip move the active tab, wrapping round
  /// at the ends; a held arrow keeps moving. Anything else, or an arrow
  /// with a modifier, passes on.
  KeyEventResult _onChipKey(AgentsTab tab, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final step = key == LogicalKeyboardKey.arrowRight
        ? 1
        : key == LogicalKeyboardKey.arrowLeft
        ? -1
        : 0;
    if (step == 0) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    const tabs = AgentsTab.values;
    _choose(tabs[(tabs.indexOf(tab) + step) % tabs.length]);
    return KeyEventResult.handled;
  }

  void _close() => Navigator.of(context).maybePop();

  /// The vault changed under the open sheet: close it, unless it is
  /// already closing.
  void _closeForVault() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent ?? false) _close();
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final width = math.max(
      0.0,
      window.width < _narrowBelow ? window.width - 32 : _sheetWidth,
    );
    final vault = _vault;
    final tab = ref.watch(agentsSheetTabProvider);
    final active = _decided ? tab : null;

    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: window.height),
          child: SizedBox(
            width: width,
            // A Container, so the content sits inside the 1 px border (as
            // the board's CSS border box does).
            child: Container(
              key: const Key('agents-sheet'),
              decoration: BoxDecoration(
                color: OmColors.surface2,
                border: Border(
                  left: BorderSide(color: OmColors.line2),
                  right: BorderSide(color: OmColors.line2),
                  bottom: BorderSide(color: OmColors.line2),
                ),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: OmColors.dialogShadow,
                    offset: Offset(0, 24),
                    blurRadius: 64,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(chipLabel: _vaultChipLabel(vault), onClose: _close),
                  _tabRow(active),
                  const OmHairline(),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                      child: switch (active) {
                        null => const SizedBox.shrink(),
                        AgentsTab.live => const LiveTab(),
                        AgentsTab.connect => const ConnectTab(),
                        AgentsTab.tools => const ToolsTab(),
                        AgentsTab.recall => const RecallTab(),
                      },
                    ),
                  ),
                  _Footer(
                    docsUrl: vault is HostedVaultRef
                        ? agentsHostedDocsUrl
                        : agentsLocalDocsUrl,
                    docsLabel: vault is HostedVaultRef
                        ? 'docs/hosted-vault.md ↗'
                        : 'docs/claude-desktop-setup.md ↗',
                    onClose: _close,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `<vault> · local vault`, or `<vault> · <server> · hosted` (req 1).
  String _vaultChipLabel(VaultRef? vault) => switch (vault) {
    null => '',
    LocalVaultRef(:final path) => '${p.basename(path)} · local vault',
    HostedVaultRef(:final serverId, :final vaultName) =>
      '${hostedVaultLabel(vaultName, ref.watch(hostedServerNameProvider(serverId)))} · hosted',
  };

  /// The tab chips in a row that scrolls sideways when they do not fit
  /// (ruling 11).
  Widget _tabRow(AgentsTab? active) {
    final liveBadge = ref.watch(liveTabBadgeProvider);
    final toolsBadge = ref.watch(toolsTabBadgeProvider);
    final recallDot = ref.watch(recallTabDotProvider);
    Widget chip(AgentsTab tab, String label, {String? badge, bool? dot}) =>
        _TabChip(
          key: Key('agents-tab-${tab.name}'),
          label: label,
          badge: badge,
          dot: dot,
          active: tab == active,
          focusNode: _chipNodes[tab]!,
          onTap: () => _choose(tab),
          onKey: (event) => _onChipKey(tab, event),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // The tab bar sits inside the scroll view: its children must all be
        // tabs.
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          role: SemanticsRole.tabBar,
          child: Row(
            children: [
              chip(AgentsTab.live, 'Live', badge: liveBadge),
              const SizedBox(width: 2),
              chip(AgentsTab.connect, 'Connect'),
              const SizedBox(width: 2),
              chip(AgentsTab.tools, 'Tools', badge: toolsBadge),
              const SizedBox(width: 2),
              chip(AgentsTab.recall, 'Semantic recall', dot: recallDot),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether keyboard focus should draw a ring now (CSS `:focus-visible`).
bool _focusVisible(bool focused) =>
    focused &&
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// The 2 px inset accent focus ring (#393 D29), drawn over a box.
BoxDecoration? _focusRing(bool visible, double radius) => visible
    ? BoxDecoration(
        border: Border.all(
          color: OmColors.accent,
          width: 2,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
        borderRadius: BorderRadius.circular(radius),
      )
    : null;

class _Header extends StatelessWidget {
  const _Header({required this.chipLabel, required this.onClose});

  final String chipLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24),
        child: Row(
          children: [
            Semantics(
              header: true,
              label: 'Agents',
              excludeSemantics: true,
              child: const Eyebrow('Agents'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  key: const Key('agents-sheet-vault-chip'),
                  padding: const EdgeInsets.symmetric(
                    vertical: 2,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: OmColors.line2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    chipLabel,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: OmType.mono(
                      size: 10.5,
                      height: 1.4,
                      color: OmColors.fg2,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _CloseX(onTap: onClose),
          ],
        ),
      ),
    );
  }
}

/// The header's 24 px close `x` (the setup-sheet pattern; Esc and the
/// footer Close are the keyboard's way out).
class _CloseX extends StatefulWidget {
  const _CloseX({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CloseX> createState() => _CloseXState();
}

class _CloseXState extends State<_CloseX> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: 'close',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            key: const Key('agents-sheet-close'),
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? OmColors.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(LucideIcons.x, size: 14, color: OmColors.fg2),
          ),
        ),
      ),
    );
  }
}

/// One tab chip: 28 high, surface3 + fg0 when active, fg2 otherwise; the
/// badge suffix is always fg2 (pack 407). Only the active chip is a Tab
/// stop; Left and Right move between chips.
class _TabChip extends StatefulWidget {
  const _TabChip({
    super.key,
    required this.label,
    required this.badge,
    required this.dot,
    required this.active,
    required this.focusNode,
    required this.onTap,
    required this.onKey,
  });

  final String label;
  final String? badge;
  final bool? dot;
  final bool active;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final badge = widget.badge;
    final dot = widget.dot;
    return Semantics(
      container: true,
      role: SemanticsRole.tab,
      selected: widget.active,
      label: badge == null ? widget.label : '${widget.label} $badge',
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Focus(
        focusNode: widget.focusNode,
        skipTraversal: !widget.active,
        includeSemantics: false,
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (_, event) => widget.onKey(event),
        child: MouseRegion(
          cursor: widget.active
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          // The active chip takes no tap, so a short drag that starts on it
          // scrolls the tab row instead of being read as a tap.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.active ? null : widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: widget.active ? OmColors.surface3 : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              foregroundDecoration: _focusRing(_focusVisible(_focused), 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dot != null) ...[
                    SizedBox(
                      width: 6,
                      height: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: dot ? OmColors.accent : OmColors.fg2,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    widget.label,
                    maxLines: 1,
                    softWrap: false,
                    style: OmType.sans(
                      size: 12.5,
                      height: 1.0,
                      color: widget.active ? OmColors.fg0 : OmColors.fg2,
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      badge,
                      maxLines: 1,
                      softWrap: false,
                      style: OmType.mono(size: 10.5, color: OmColors.fg2),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.docsUrl,
    required this.docsLabel,
    required this.onClose,
  });

  final String docsUrl;
  final String docsLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: OmColors.line1)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _DocsLink(
                  key: const Key('agents-sheet-docs'),
                  url: docsUrl,
                  label: docsLabel,
                ),
              ),
            ),
            const SizedBox(width: 10),
            OmButton(
              key: const Key('agents-sheet-footer-close'),
              label: 'Close',
              size: 28,
              focusable: true,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The footer's docs link: mono 11 info text, a Tab stop that Enter and
/// Space open, through `urlOpenerProvider`.
class _DocsLink extends ConsumerStatefulWidget {
  const _DocsLink({super.key, required this.url, required this.label});

  final String url;
  final String label;

  @override
  ConsumerState<_DocsLink> createState() => _DocsLinkState();
}

class _DocsLinkState extends ConsumerState<_DocsLink> {
  bool _focused = false;

  void _open() => unawaited(ref.read(urlOpenerProvider).open(widget.url));

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _open();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      link: true,
      label: widget.label,
      onTap: _open,
      excludeSemantics: true,
      child: Focus(
        includeSemantics: false,
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: Container(
              foregroundDecoration: _focusRing(_focusVisible(_focused), 4),
              child: Text(
                widget.label,
                style: OmType.mono(size: 11, color: OmColors.info),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
