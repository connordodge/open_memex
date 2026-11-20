// WI #77 (56-A3, Spec #59 reqs 4-11, 24-27, 40-42; D13, D17; lead rulings
// W1-W3): the Command palette's shell, its command and note choosers, and
// the overrides that wire #76's seam at the app root.
import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../graph/graph_scope.dart';
import '../../state/attach_controller.dart';
import '../../state/clock.dart';
import '../../state/command_palette_state.dart';
import '../../state/daily_state.dart';
import '../../state/editor_controller.dart';
import '../../state/palette_commands.dart';
import '../../state/palette_titles.dart';
import '../../state/sidebar_mode_state.dart';
import '../../state/tabs_state.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../state/workspace_actions.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../agents_sheet/agents_sheet.dart';
import '../backups/backups_sheet.dart';
import '../note_editor.dart';
import '../picker/vault_picker_modal.dart';
import '../vault_settings_dialog.dart';
import 'palette_group_header.dart';
import 'palette_preview.dart';
import 'palette_row.dart';
import 'passages_states.dart';

/// #77's production wiring of #76's seam (lead ruling W1), spread into
/// `appRootOverrides`: the Commands and titles sources, and the command and
/// note choosers. A chooser closes the palette first, then runs its action
/// with the context the palette was opened over (R24).
final List<Override> paletteShellOverrides = [
  paletteCommandsOverride,
  paletteTitlesOverride,
  paletteCommandChooserProvider.overrideWith((ref) {
    final session = ref.watch(_sessionProvider);
    return (item, {required newTab}) => session.choose(
      (host, container) =>
          _runCommand(host, container, item.command, newTab: newTab),
    );
  }),
  paletteNoteChooserProvider.overrideWith((ref) {
    final session = ref.watch(_sessionProvider);
    return (item, {required newTab}) => session.choose(
      (host, container) => _showNote(container, item, newTab: newTab),
    );
  }),
];

/// Whether a Command palette shows (from its push until it closes): the
/// Command bar draws its open state (board C3 state 3).
final commandPaletteOpenProvider = StateProvider<bool>((_) => false);

/// The closing palette's fade. Not drawn (pack 77 flows have no
/// animation); short, so the closing card's provider scope still rebuilds
/// before it goes.
const _fadeOut = Duration(milliseconds: 100);

/// The window width from which the card shows the preview pane (req 9).
const _wideFrom = 950.0;

/// The card's top edge below the window top, and its bottom margin (pack
/// 77: top-anchored, height min(560, h - 96 - 48)).
const _cardTop = 96.0;
const _cardBottomMargin = 48.0;

/// The list column's width in the wide card (399 + its 1 px rule).
const _listWidth = 400.0;

/// Opens the Command palette as a root-navigator dialog over [context] (the
/// Workspace's, or the Command bar's, context): the commands it runs run
/// after the palette pops, with [context]. Never stacks a second palette,
/// and does nothing while another modal route covers [context]. It opens
/// empty, with the input focused and the first row selected; closing
/// without a choice gives the focus back to where it was. Completes when
/// the palette closes.
Future<void> showCommandPalette(BuildContext context) async {
  if (ModalRoute.isCurrentOf(context) == false) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final session = container.read(_sessionProvider);
  if (session.route != null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  // A fresh session even when the last palette is still being torn down
  // (lead ruling W2: the notifier has no open()).
  container.invalidate(paletteProvider);
  late final _PaletteRoute route;
  route = _PaletteRoute(
    // The palette is built under the root navigator, outside the caller's
    // subtree: hand it the caller's container (D13, TD7; ruling W1).
    pageBuilder: (_, _, _) => UncontrolledProviderScope(
      container: container,
      child: ValueListenableBuilder<bool>(
        valueListenable: route.cleared,
        builder: (_, cleared, _) =>
            cleared ? const SizedBox.shrink() : const _CommandPalette(),
      ),
    ),
  );
  route.onPopped = () => session.closed(route);
  session.opened(
    route: route,
    host: context,
    restoreFocus: FocusManager.instance.primaryFocus,
  );
  final closed = navigator.push<void>(route);
  session.watchFade(route);
  await closed;
}

/// Whether the Command palette shows over [container]'s app.
bool isCommandPaletteShowing(ProviderContainer container) =>
    container.read(_sessionProvider).route != null;

/// Whether the Command palette shows and is the current route: false while
/// another modal (an update or leave-confirm dialog) covers it.
bool isCommandPaletteCurrent(ProviderContainer container) =>
    container.read(_sessionProvider).route?.isCurrent ?? false;

/// Closes the Command palette without a choice, when it shows.
void closeCommandPalette(ProviderContainer container) =>
    container.read(_sessionProvider).close();

final _sessionProvider = Provider<_PaletteSession>(
  (ref) => _PaletteSession(ref.container),
);

/// The one palette an app can show, and what it was opened over.
class _PaletteSession {
  _PaletteSession(this.container);

  final ProviderContainer container;

  /// The showing palette's route; null once it pops.
  _PaletteRoute? route;

  /// The context the palette was opened over: choices run with it.
  BuildContext? host;

  /// The focus before the palette opened, given back on a close without a
  /// choice.
  FocusNode? _restoreFocus;

  /// Set by a choice: the chosen row's action places the focus.
  var _chosen = false;

  /// Palette routes pushed and not yet faded out (or removed).
  final _live = <_PaletteRoute>{};

  void opened({
    required _PaletteRoute route,
    required BuildContext host,
    required FocusNode? restoreFocus,
  }) {
    this.route = route;
    this.host = host;
    _restoreFocus = restoreFocus;
    _chosen = false;
    _live.add(route);
    container.read(commandPaletteOpenProvider.notifier).state = true;
  }

  /// The Command bar keeps its open look until [route] has faded out
  /// (board C3 state 3: "also while it closes").
  void watchFade(_PaletteRoute route) {
    final fade = route.animation;
    if (fade == null) return _faded(route);
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.dismissed) return;
      fade.removeStatusListener(listener);
      _faded(route);
    };
    fade.addStatusListener(listener);
  }

  /// [route] has faded out, or was removed without a fade: once no palette
  /// route is left, the Command bar draws its rest state.
  void _faded(_PaletteRoute route) {
    _live.remove(route);
    if (_live.isNotEmpty) return;
    try {
      container.read(commandPaletteOpenProvider.notifier).state = false;
    } on StateError {
      // The app went with the palette.
    }
  }

  /// Closes the palette (no choice), from Cmd+K, a vault change or the
  /// Workspace unmounting.
  void close() {
    final route = this.route;
    if (route == null) return;
    if (route.isCurrent) {
      route.navigator?.pop();
    } else {
      // Another modal covers it (an update or leave-confirm dialog): remove
      // it in place. It plays no fade, and the focus stays with the modal
      // on top.
      closed(route, restoreFocus: false);
      _removeCovered(route);
    }
  }

  /// Removes the covered [route] in steps, a frame apart: the card's
  /// widgets go first, under the route's provider scope, then the route,
  /// and the Command bar rests once it has gone.
  ///
  /// The scope takes its share of every provider task scheduled while it is
  /// mounted, and drops it only when it builds. Removing the route with the
  /// card in it, in a frame where a task is pending (a vault change and the
  /// vault opening it starts, or the writes [closed] just made), leaves the
  /// scope inactive with a task it never ran, and the card's auto-dispose on
  /// unmount then trips Riverpod's debug assert 'Only one task can be
  /// scheduled at a time'. With the card gone first, its unmount runs while
  /// the scope is still active, and the route's own unmount schedules no
  /// task.
  void _removeCovered(_PaletteRoute route) {
    final binding = WidgetsBinding.instance;
    void afterFrame(VoidCallback step) {
      binding.addPostFrameCallback((_) => step());
      binding.ensureVisualUpdate();
    }

    // Already gone (the app is torn down with it): nothing to remove.
    if (!route.isActive) return _faded(route);
    route.cleared.value = true;
    afterFrame(() {
      if (route.isActive) route.navigator?.removeRoute(route);
      afterFrame(() => _faded(route));
    });
  }

  /// A row was chosen: closes the palette, then runs [action] with the
  /// context the palette was opened over, when it is still mounted.
  void choose(void Function(BuildContext host, ProviderContainer c) action) {
    final host = this.host;
    _chosen = true;
    close();
    if (host == null || !host.mounted) return;
    action(host, container);
  }

  /// [route] closed (popped or removed): tells the palette's sources, and
  /// gives the focus back unless a row was chosen or [restoreFocus] is
  /// false (another route is on top).
  void closed(_PaletteRoute route, {bool restoreFocus = true}) {
    if (this.route != route) return;
    this.route = null;
    host = null;
    if (container.exists(paletteProvider)) {
      container.read(paletteProvider.notifier).close();
    }
    final restore = _restoreFocus;
    _restoreFocus = null;
    if (_chosen || !restoreFocus || restore == null) return;
    if (restore.context?.mounted ?? false) restore.requestFocus();
  }
}

/// The palette's dialog route: it shows at once (pack 77 flows: no
/// transition) and fades out in [_fadeOut], the `dialogShadow` scrim closes
/// it, and Tab stays inside it.
class _PaletteRoute extends RawDialogRoute<void> {
  _PaletteRoute({required super.pageBuilder})
    : super(
        barrierDismissible: true,
        barrierLabel: 'close',
        barrierColor: OmColors.dialogShadow,
        transitionDuration: Duration.zero,
        transitionBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      );

  VoidCallback? onPopped;

  /// Set when a covered palette is removed: the route then builds no card,
  /// only its provider scope (see [_PaletteSession._removeCovered]).
  final cleared = ValueNotifier<bool>(false);

  @override
  void dispose() {
    cleared.dispose();
    super.dispose();
  }

  @override
  Duration get reverseTransitionDuration => _fadeOut;

  @override
  bool didPop(void result) {
    onPopped?.call();
    return super.didPop(result);
  }
}

// ---------------------------------------------------------------------------
// Choices (Spec #59 reqs 24, 27).
// ---------------------------------------------------------------------------

void _runCommand(
  BuildContext host,
  ProviderContainer container,
  PaletteCommand command, {
  required bool newTab,
}) {
  final tabs = container.read(tabsProvider.notifier);
  void show(WorkspaceTab tab) =>
      newTab ? tabs.openOrFocus(tab) : tabs.navigate(tab);
  switch (command) {
    case PaletteCommand.newNote:
      unawaited(createNote(host));
    case PaletteCommand.newCanvas:
      unawaited(newCanvas(host));
    case PaletteCommand.attachFile:
      unawaited(
        container.read(attachControllerProvider).attachFromPicker(host),
      );
    case PaletteCommand.openToday:
      unawaited(_openToday(container, show));
    case PaletteCommand.openVaultGraph:
      show(GraphTab(const GraphScope.vault()));
    case PaletteCommand.switchVault:
      unawaited(showVaultPickerModal(host));
    case PaletteCommand.vaultSettings:
      unawaited(showVaultSettingsDialog(host));
    case PaletteCommand.backups:
      final vault = container.read(currentVaultProvider);
      if (vault != null) unawaited(showBackupsSheet(host, vault));
    case PaletteCommand.agents:
      unawaited(openAgentsSheet(host));
    case PaletteCommand.rightPanel:
      container.read(rightPanelOpenProvider.notifier).update((open) => !open);
    case PaletteCommand.showDays:
      unawaited(
        container.read(sidebarModeProvider.notifier).select(SidebarMode.days),
      );
    case PaletteCommand.showTopics:
      unawaited(
        container.read(sidebarModeProvider.notifier).select(SidebarMode.topics),
      );
    case PaletteCommand.showTags:
      unawaited(
        container.read(sidebarModeProvider.notifier).select(SidebarMode.tags),
      );
  }
}

/// Open today (`openToday` semantics): today's daily note, or the virtual
/// Today note when there is none yet, shown through [show].
Future<void> _openToday(
  ProviderContainer container,
  void Function(WorkspaceTab tab) show,
) async {
  final date = container.read(todayDateProvider);
  String? noteId;
  try {
    final today = await container.read(todayNoteAsyncProvider.future);
    if (today.vault == container.read(currentVaultProvider)) {
      noteId = today.value?.noteId;
    }
  } catch (_) {
    // No daily notes read: the virtual Today note.
  }
  show(noteId == null ? VirtualTodayTab(date) : NoteTab(noteId));
}

/// Shows the chosen note, daily note or canvas: [TabsNotifier.navigate]
/// without ⌘, [TabsNotifier.openOrFocus] with it. A note's editor then takes
/// the keyboard focus.
void _showNote(
  ProviderContainer container,
  NoteItem item, {
  required bool newTab,
}) {
  final WorkspaceTab tab = item.kind == PaletteNoteKind.canvas
      ? CanvasTab(item.noteId)
      : NoteTab(item.noteId);
  final tabs = container.read(tabsProvider.notifier);
  if (newTab) {
    tabs.openOrFocus(tab);
  } else {
    tabs.navigate(tab);
  }
  if (tab is NoteTab) _focusEditorOnArrival(container, item.noteId, tab);
}

/// How long [_focusEditorOnArrival] waits for the editor to show the note
/// (a hosted vault reads it over the network).
const _editorFocusWait = Duration(seconds: 10);

/// Puts the keyboard focus in the note editor's body once it shows
/// [noteId] (req 28: after a choice, focus goes to the opened note's
/// editor). It reacts to the editor taking the note, then waits one frame
/// so the editor has rebuilt its body for it. Gives up when the active tab
/// moves on, or at its first check later than [_editorFocusWait] after the
/// choice (by [clockProvider]): a check runs on each editor change.
void _focusEditorOnArrival(
  ProviderContainer container,
  String noteId,
  NoteTab tab,
) {
  final binding = SchedulerBinding.instance;
  final clock = container.read(clockProvider);
  final deadline = clock.now().add(_editorFocusWait);
  ProviderSubscription<Object?>? editor;
  ProviderSubscription<Object?>? tabs;
  var done = false;
  var scheduled = false;
  var loaded = false;

  void stop() {
    done = true;
    editor?.close();
    tabs?.close();
  }

  void check() {
    if (done || scheduled) return;
    scheduled = true;
    binding.addPostFrameCallback((_) {
      scheduled = false;
      if (done) return;
      try {
        if (container.read(tabsProvider).activeTab != tab ||
            clock.now().isAfter(deadline)) {
          return stop();
        }
        final shown =
            container.read(editorControllerProvider.notifier).activeNoteId ==
            noteId;
        if (!shown) {
          // Wait for the editor to take the note.
          loaded = false;
          return;
        }
        if (loaded) {
          final field = _editorBodyField();
          if (field != null) {
            if (!field.focusNode.hasFocus) field.focusNode.requestFocus();
            return stop();
          }
        }
        loaded = true;
      } on StateError {
        return stop(); // The container was disposed.
      }
      check();
    });
    binding.scheduleFrame();
  }

  try {
    editor = container.listen(editorControllerProvider, (_, _) => check());
    tabs = container.listen<TabsState>(tabsProvider, (_, next) {
      if (next.activeTab != tab) stop();
    });
  } on StateError {
    return stop();
  }
  // The editor may show the note already (it was the active note).
  check();
}

/// The note editor body's first text field (Key `editor-body`), if a note
/// editor shows.
EditableText? _editorBodyField() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  EditableText? found;
  void inEditor(Element e) {
    if (found != null) return;
    final widget = e.widget;
    if (widget is EditableText) {
      found = widget;
      return;
    }
    e.visitChildElements(inEditor);
  }

  void inBody(Element e) {
    if (found != null) return;
    if (e.widget.key == const Key('editor-body')) {
      inEditor(e);
      return;
    }
    e.visitChildElements(inBody);
  }

  void search(Element e) {
    if (found != null) return;
    if (e.widget is NoteEditor) {
      inBody(e);
      return;
    }
    e.visitChildElements(search);
  }

  search(root);
  return found;
}

// ---------------------------------------------------------------------------
// The card (design pack 77, boards C1, N1).
// ---------------------------------------------------------------------------

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) Navigator.of(context).pop();
  }

  /// The current vault changed (req 42): closes without a choice, also
  /// while another modal covers the palette.
  void _closeForVaultChange() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeForVaultChange();
      });
      return;
    }
    closeCommandPalette(ProviderScope.containerOf(context, listen: false));
  }

  /// ↑, ↓, ↵, ⌘↵ and Esc, as key-downs (req 25). Repeats of ↑ and ↓ move;
  /// a held ↵ or Esc acts once.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final down = event is KeyDownEvent;
    final palette = ref.read(paletteProvider.notifier);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        palette.move(1);
      case LogicalKeyboardKey.arrowUp:
        palette.move(-1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        // The ⌘ flag is captured here, at the key.
        if (down) {
          palette.choose(newTab: HardwareKeyboard.instance.isMetaPressed);
        }
      case LogicalKeyboardKey.escape:
        if (down) _close();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentVaultProvider, (_, _) => _closeForVaultChange());
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= _wideFrom;
    final width = max(0.0, min(wide ? 960.0 : 640.0, size.width - 48));
    final height = max(
      0.0,
      min(560.0, size.height - _cardTop - _cardBottomMargin),
    );
    final list = _PaletteList(wide: wide);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: _cardTop),
        child: SizedBox(
          key: PaletteKeys.palette,
          width: width,
          height: height,
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: 'Command palette',
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: OmColors.surface1,
                  border: Border.all(color: OmColors.line3),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: OmColors.dialogShadow,
                      offset: Offset(0, 24),
                      blurRadius: 64,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Focus(
                          onKeyEvent: _onKey,
                          child: _InputRow(
                            controller: _input,
                            onChanged: (query) => ref
                                .read(paletteProvider.notifier)
                                .setQuery(query),
                          ),
                        ),
                        _Rule(OmColors.line2),
                        Expanded(
                          child: wide
                              ? Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      width: _listWidth - 1,
                                      child: list,
                                    ),
                                    _Rule(OmColors.line1, vertical: true),
                                    const Expanded(child: _PreviewSlot()),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(child: list),
                                    const _NarrowHints(),
                                  ],
                                ),
                        ),
                      ],
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

/// A 1 px rule in [color]: horizontal, or [vertical].
class _Rule extends StatelessWidget {
  const _Rule(this.color, {this.vertical = false});

  final Color color;
  final bool vertical;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: vertical ? 1 : null,
    height: vertical ? null : 1,
    child: ColoredBox(color: color),
  );
}

/// The input row: search icon, the field and the `esc` chip (51 px, then
/// the card's 1 px rule).
class _InputRow extends StatelessWidget {
  const _InputRow({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = OmType.sans(size: 15, height: 19 / 15);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 51),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(LucideIcons.search, size: 16, color: OmColors.fg2),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                label: 'Search notes, note text and commands',
                child: TextField(
                  key: PaletteKeys.input,
                  controller: controller,
                  autofocus: true,
                  // A click on the card outside the field (the preview, a
                  // header, the hint footer) keeps the keyboard here, so
                  // Esc, the arrows and Enter still work.
                  onTapOutside: (_) {},
                  onChanged: onChanged,
                  style: style,
                  cursorColor: OmColors.accent,
                  decoration: InputDecoration.collapsed(
                    hintText: 'search notes, note text and commands…',
                    hintStyle: style.copyWith(color: OmColors.fg2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const _KeyChip('esc', mono: true, minWidth: 32),
          ],
        ),
      ),
    );
  }
}

/// The wide card's right side: [PalettePreview] (#78) over the hint footer.
class _PreviewSlot extends StatelessWidget {
  const _PreviewSlot();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: OmColors.surface2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: PalettePreview()),
        _WideHints(),
      ],
    ),
  );
}

/// The result list: the groups, the Passages state row and footer (#78),
/// the empty-input footer and the no-matches row. It scrolls, keeping the
/// selected row in view.
class _PaletteList extends ConsumerStatefulWidget {
  const _PaletteList({required this.wide});

  final bool wide;

  @override
  ConsumerState<_PaletteList> createState() => _PaletteListState();
}

class _PaletteListState extends ConsumerState<_PaletteList> {
  final _scroll = ScrollController();
  final _rowKeys = <PaletteItemId, GlobalKey>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls [id]'s row into view after this frame's layout: the top for
  /// the first row (its group header with it), otherwise just enough.
  void _reveal(PaletteItemId? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final groups = ref.read(paletteProvider).groups;
      final first = groups.firstOrNull?.rows.firstOrNull?.id;
      if (id == first) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
        return;
      }
      final row = _rowKeys[id]?.currentContext;
      if (row == null) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      paletteProvider.select((s) => s.selected),
      (_, next) => _reveal(next),
    );
    final state = ref.watch(paletteProvider);
    final canWrite = ref.watch(vaultAccessProvider)?.canWrite ?? false;
    final query = state.query.trim();
    final typed = query.isNotEmpty;
    final dimmed = state.passages is PassagesDimmed;
    final listed = <PaletteItemId>{};
    final passagesListed = state.groups.any(
      (group) => group.kind == PaletteGroupKind.passages,
    );

    Widget row(PaletteItem item) {
      listed.add(item.id);
      return KeyedSubtree(
        key: _rowKeys.putIfAbsent(item.id, GlobalKey.new),
        child: PaletteRow(
          item: item,
          selected: item.id == state.selected,
          showEnterChip: !widget.wide,
        ),
      );
    }

    final children = <Widget>[
      for (final group in state.groups) ...[
        PaletteGroupHeader(
          kind: group.kind,
          count: group.rows.length,
          hint: group.hint,
        ),
        for (final item in group.rows)
          // Req 17 (ruling W3): the previous answer's rows, dimmed, until
          // the debounce fires.
          group.kind == PaletteGroupKind.passages && dimmed
              ? Opacity(opacity: 0.5, child: row(item))
              : row(item),
        if (group.kind == PaletteGroupKind.passages) const PassagesFooter(),
      ],
      if (typed &&
          !passagesListed &&
          !state.noMatches &&
          state.passages is! PassagesIdle)
        const PassagesStateRow(),
      if (state.noMatches) _NoMatches(query),
      if (!typed && canWrite) const _EmptyInputFooter(),
    ];
    _rowKeys.removeWhere((id, _) => !listed.contains(id));

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: RawScrollbar(
        controller: _scroll,
        thumbColor: OmColors.line3,
        thickness: 4,
        radius: const Radius.circular(2),
        crossAxisMargin: 2,
        mainAxisMargin: 6,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// `type to search note text`, after Recent on the empty input (req 13).
/// No board draws it: the Passages footer look of C4 state 4 (pack 77).
class _EmptyInputFooter extends StatelessWidget {
  const _EmptyInputFooter();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: OmColors.line1)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Text(
          'type to search note text',
          style: OmType.mono(size: 11, color: OmColors.fg2, height: 17.6 / 11),
        ),
      ),
    ),
  );
}

/// `no matches for “<query>”` (C4 state 8): no header, 44 px.
class _NoMatches extends StatelessWidget {
  const _NoMatches(this.query);

  final String query;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    key: PaletteKeys.noMatches,
    constraints: const BoxConstraints(minHeight: 44),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'no matches for “$query”',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: OmType.mono(size: 11, color: OmColors.fg2, height: 14 / 11),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Key hints (pack 77 "Key-hint footers").
// ---------------------------------------------------------------------------

typedef _Hint = (String chip, bool mono, double chipWidth, String label);

const _hintMove = ('↑↓', true, 26.0, 'move');
const _hintClose = ('esc', true, 32.0, 'close');
const _hintChoose = ('↵', false, 23.0, 'choose');
const _hintNewTab = ('⌘↵', false, 33.0, 'new tab');

/// The wide card's footer, at the bottom of the preview slot: its labels
/// follow the selected row's kind.
class _WideHints extends ConsumerWidget {
  const _WideHints();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(paletteProvider.select((s) => s.selected?.kind));
    final List<_Hint> hints = switch (kind) {
      PaletteItemKind.command => const [
        _hintMove,
        ('↵', false, 23.0, 'run'),
        ('⌘↵', false, 33.0, 'in a new tab'),
        _hintClose,
      ],
      PaletteItemKind.passage => const [
        ('↵', false, 23.0, 'show here, at this passage'),
        _hintNewTab,
        _hintClose,
      ],
      PaletteItemKind.note || PaletteItemKind.daily || PaletteItemKind.canvas =>
        const [_hintMove, _hintChoose, _hintNewTab, _hintClose],
      PaletteItemKind.attachment || null => const [_hintMove, _hintClose],
    };
    return _HintBar(
      hints: hints,
      height: 40,
      rule: OmColors.line1,
      padding: 28,
      gap: 16,
    );
  }
}

/// The list-only card's footer across the card bottom (board N1).
class _NarrowHints extends StatelessWidget {
  const _NarrowHints();

  @override
  Widget build(BuildContext context) => _HintBar(
    hints: const [_hintMove, _hintChoose, _hintNewTab, _hintClose],
    height: 34,
    rule: OmColors.line2,
    padding: 16,
    gap: 18,
  );
}

class _HintBar extends StatelessWidget {
  const _HintBar({
    required this.hints,
    required this.height,
    required this.rule,
    required this.padding,
    required this.gap,
  });

  final List<_Hint> hints;

  /// The footer's height, its 1 px top [rule] included.
  final double height;
  final Color rule;
  final double padding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final label = OmType.mono(
      size: 10.5,
      color: OmColors.fg2,
      height: 13 / 10.5,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Rule(rule),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: height - 1),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padding),
            child: Row(
              children: [
                for (final (i, (chip, mono, width, text)) in hints.indexed) ...[
                  if (i > 0) SizedBox(width: gap),
                  _KeyChip(chip, mono: mono, minWidth: width),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: label,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A key chip: 18 high, padding H5, 1 px `line3` border, radius 4, glyphs
/// 10.5 in `fg2`, letter spacing 0.2; [mono] picks JetBrains Mono.
class _KeyChip extends StatelessWidget {
  const _KeyChip(this.text, {required this.mono, required this.minWidth});

  final String text;
  final bool mono;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? OmType.mono(
            size: 10.5,
            color: OmColors.fg2,
            height: 1.2,
            letterSpacing: 0.2,
          )
        : OmType.sans(
            size: 10.5,
            color: OmColors.fg2,
            height: 1.2,
            letterSpacing: 0.2,
          );
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: 18),
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
            child: Text(text, maxLines: 1, softWrap: false, style: style),
          ),
        ),
      ),
    );
  }
}
