import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/markdown_preview_text.dart';
import '../memex_cli.dart' show MemexException;
import '../state/clock.dart';
import '../state/echo_link_actions.dart';
import '../state/echo_scroll_target.dart';
import '../state/echoes_state.dart';
import '../state/tabs_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/vault_access.dart';
import 'atoms.dart';
import 'editor/note_header.dart' show formatDayAgo, formatRelativeAgo;
import 'inline_error.dart';

/// How long the first read of a note may run before the tab shows
/// `listening for echoes…` (Spec #391 req 34).
const _firstLoadDelay = Duration(milliseconds: 400);

/// The echoes tab's link state for the selected note ([noteId]).
///
/// It lives in [_echoLinksProvider], not in the tab, so a right-panel tab
/// switch or a panel close in the middle of a link keeps the busy guard and
/// the hidden rows (req 30, 32).
@immutable
class _EchoLinks {
  const _EchoLinks({
    required this.noteId,
    this.hidden = const {},
    this.busy = const {},
    this.errors = const {},
  });

  /// The selected note that [hidden] and [errors] belong to.
  final String? noteId;

  /// Echo ids linked from [noteId]: their rows are hidden.
  final Set<String> hidden;

  /// `<open note id>\u0000<echo id>` of each link in flight.
  final Set<String> busy;

  /// The failed link's message per echo id, for [noteId].
  final Map<String, String> errors;

  _EchoLinks copyWith({
    String? noteId,
    Set<String>? hidden,
    Set<String>? busy,
    Map<String, String>? errors,
  }) => _EchoLinks(
    noteId: noteId ?? this.noteId,
    hidden: hidden ?? this.hidden,
    busy: busy ?? this.busy,
    errors: errors ?? this.errors,
  );
}

String _busyKey(String? openNoteId, String echoId) =>
    '$openNoteId\u0000$echoId';

/// Runs the echo links and keeps [_EchoLinks] for the selected note: a note
/// switch (or a vault switch) drops the hidden rows and link errors, and a
/// shown result that no longer lists a hidden echo shows it again later.
class _EchoLinksNotifier extends Notifier<_EchoLinks> {
  @override
  _EchoLinks build() {
    ref.watch(currentVaultProvider);
    ref.listen<String?>(selectedNoteIdProvider, (_, next) {
      if (next != state.noteId) {
        state = _EchoLinks(noteId: next, busy: state.busy);
      }
    });
    ref.listen<EchoesViewState>(echoesAsyncProvider, (_, next) => _prune(next));
    return _EchoLinks(noteId: ref.read(selectedNoteIdProvider));
  }

  void _prune(EchoesViewState view) {
    final ready = switch (view) {
      EchoesShown(:final result) => result,
      _ => null,
    };
    if (ready == null || state.hidden.isEmpty) return;
    final ids = {for (final e in ready.echoes) e.noteId};
    final kept = state.hidden.where(ids.contains).toSet();
    if (kept.length != state.hidden.length) {
      state = state.copyWith(hidden: kept);
    }
  }

  void dismissError(String echoId) {
    if (!state.errors.containsKey(echoId)) return;
    state = state.copyWith(errors: {...state.errors}..remove(echoId));
  }

  /// Links [echo] to [openNoteId] once: a second call for the same pair
  /// while the first is in flight does nothing.
  Future<void> link(String openNoteId, Echo echo, EchoLinkPlan plan) async {
    final key = _busyKey(openNoteId, echo.noteId);
    if (state.busy.contains(key)) return;
    state = state.copyWith(
      busy: {...state.busy, key},
      errors: {...state.errors}..remove(echo.noteId),
    );
    final echoes = ref.read(echoesAsyncProvider.notifier);
    final actions = ref.read(echoLinkActionsProvider);
    Object? failure;
    try {
      await actions.link(openNoteId: openNoteId, echo: echo, plan: plan);
    } catch (e) {
      failure = e;
    }
    final busy = {...state.busy}..remove(key);
    // A note switch in the meantime dropped this note's rows.
    state = state.noteId != openNoteId
        ? state.copyWith(busy: busy)
        : failure == null
        ? state.copyWith(busy: busy, hidden: {...state.hidden, echo.noteId})
        : state.copyWith(
            busy: busy,
            errors: {...state.errors, echo.noteId: failure.toString()},
          );
    if (failure == null) {
      unawaited(echoes.linkCompleted());
      return;
    }
    if (failure is MemexException && failure.code == 'not_found') {
      unawaited(echoes.retry());
    }
  }
}

final _echoLinksProvider = NotifierProvider<_EchoLinksNotifier, _EchoLinks>(
  _EchoLinksNotifier.new,
);

/// The right panel's echoes tab (Spec #391 reqs 22, 25-28, 30, 32-35):
/// the header, then the copy of the selected note's [EchoesViewState] from
/// `echoesAsyncProvider`, or its echo rows.
///
/// An echo row opens its note on a click of the title or passage, or on
/// Enter, and offers `link` per [echoLinkPlan] while the open note's role is
/// loaded. A linked echo is hidden at once and stays hidden for this note
/// until a result no longer lists it or the note changes.
class EchoesTab extends ConsumerStatefulWidget {
  const EchoesTab({super.key});

  @override
  ConsumerState<EchoesTab> createState() => _EchoesTabState();
}

class _EchoesTabState extends ConsumerState<EchoesTab> {
  /// The 400 ms first-load timer, for the note [_delayFor].
  Timer? _delay;
  String? _delayFor;
  bool _listening = false;

  /// The read error the person dismissed (its `InlineError` stays hidden).
  Object? _dismissedError;

  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(selectedNoteIdProvider, (_, _) => _syncDelay());
    ref.listenManual<EchoesViewState>(
      echoesAsyncProvider,
      (_, _) => _syncDelay(),
    );
    _syncDelay();
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  /// Starts the first-load timer when the view enters [EchoesFirstLoad] for
  /// a note, restarts it for another note, and drops it on leaving.
  ///
  /// `build` watches `selectedNoteIdProvider`, so a switch between two
  /// first loads (an equal view) still rebuilds without the copy.
  void _syncDelay() {
    final view = ref.read(echoesAsyncProvider);
    final key = view is EchoesFirstLoad
        ? ref.read(selectedNoteIdProvider)
        : null;
    if (key == _delayFor) return;
    _delay?.cancel();
    _delay = null;
    _delayFor = key;
    _listening = false;
    if (key == null) return;
    _delay = ref.read(clockProvider).after(_firstLoadDelay, () {
      if (!mounted || _delayFor != key) return;
      setState(() => _listening = true);
    });
  }

  void _open(Echo echo) {
    // The target first: `follow` updates the tabs at once, and the editor
    // takes the target when it sees the new tab.
    ref
        .read(echoScrollTargetProvider.notifier)
        .set(EchoScrollTarget(echo.noteId, echo.startByte));
    ref.read(tabsProvider.notifier).follow(NoteTab(echo.noteId));
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(echoesAsyncProvider);
    ref.watch(selectedNoteIdProvider);
    final notifier = ref.read(echoesAsyncProvider.notifier);
    return ListView(
      children: [
        const PanelHeader(eyebrow: 'echoes · forgotten threads'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'past notes the indexer thinks you\'d want now. all from your own '
            'writing — never an outside source.',
            style: OmType.mono(size: 10.5, color: OmColors.fg3, height: 1.6),
          ),
        ),
        const OmHairline(),
        ...switch (view) {
          EchoesNoNote() => [_copy('select a note to see its echoes.')],
          EchoesNothingWritten() => [_nothingWritten],
          EchoesFirstLoad() => [if (_listening) _copy('listening for echoes…')],
          EchoesShown(:final result) => _ready(result),
          EchoesUnavailableView(:final reason) => _unavailable(
            reason,
            notifier,
          ),
          EchoesDownloading() => [_copy('downloading the model…')],
          EchoesError(:final error, :final lastGood) => [
            if (lastGood != null) ..._ready(lastGood),
            if (!identical(error, _dismissedError))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: InlineError(
                  message: error.toString(),
                  onDismiss: () => setState(() => _dismissedError = error),
                  onRetry: notifier.retry,
                ),
              ),
          ],
        },
      ],
    );
  }

  Widget get _nothingWritten =>
      _copy('write something and echoes will surface here.');

  /// The rows of [result] not hidden by a link, or the empty copy, then the
  /// `still indexing` line while passages are pending.
  List<Widget> _ready(EchoesReady result) {
    if (result.emptyNote) return [_nothingWritten];
    final links = ref.watch(_echoLinksProvider);
    final echoes = result.echoes
        .where((e) => !links.hidden.contains(e.noteId))
        .toList();
    final openNoteId = ref.watch(selectedNoteIdProvider);
    final openNote = watchVaultValue(ref, selectedNoteAsyncProvider, null);
    // The link plan needs the open note's role: no `link` until it loads.
    final roleLoaded = openNote != null && openNote.id == openNoteId;
    final now = ref.read(clockProvider).now();
    return [
      if (echoes.isEmpty)
        _copy(
          'nothing surfaced yet.\n'
          'echoes appear when older writing is close to this note.',
        )
      else ...[
        const SizedBox(height: 6),
        for (final echo in echoes)
          _EchoRow(
            key: Key('echo-row-${echo.noteId}'),
            echo: echo,
            now: now,
            plan: roleLoaded
                ? echoLinkPlan(openRole: openNote.role, echoRole: echo.noteRole)
                : EchoLinkPlan.none,
            busy: links.busy.contains(_busyKey(openNoteId, echo.noteId)),
            error: links.errors[echo.noteId],
            onOpen: () => _open(echo),
            onLink: (plan) => ref
                .read(_echoLinksProvider.notifier)
                .link(openNoteId!, echo, plan),
            onDismissError: () =>
                ref.read(_echoLinksProvider.notifier).dismissError(echo.noteId),
          ),
      ],
      if (result.pending > 0)
        _copy(
          'still indexing · ${result.pending} passages left',
          top: echoes.isEmpty ? 0 : 12,
        ),
    ];
  }

  List<Widget> _unavailable(
    EchoesUnavailableReason reason,
    EchoesNotifier notifier,
  ) => switch (reason) {
    EmbeddingsOff() => [
      _copy(
        'semantic recall is off on this vault server — start it with '
        '--with-embeddings to see echoes.',
      ),
    ],
    ModelNotDownloaded() => [
      _copy("echoes run on a local model that isn't downloaded yet."),
      _action(
        OmButton(
          key: const Key('echo-download'),
          kind: OmButtonKind.secondary,
          size: 28,
          dense: true,
          focusable: true,
          label: 'Download model (130 MB)',
          semanticLabel: 'Download the embedding model, 130 megabytes',
          onPressed: notifier.download,
        ),
      ),
    ],
    EmbedderUnavailable(:final message) => [
      _copy("couldn't load the embedding model."),
      _copy(message, top: 6),
      _action(
        OmButton(
          kind: OmButtonKind.secondary,
          size: 28,
          dense: true,
          focusable: true,
          label: 'retry',
          onPressed: notifier.retry,
        ),
      ),
    ],
    NoCli() => [_copy('echoes need the memex CLI.')],
    Outdated() => [_copy('update memex to see echoes.')],
  };

  /// A state line in fg2 mono (D26).
  Widget _copy(String text, {double top = 24}) => Padding(
    padding: EdgeInsets.fromLTRB(16, top, 16, 0),
    child: Text(
      text,
      style: OmType.mono(size: 11, color: OmColors.fg2, height: 1.6),
    ),
  );

  /// A state's button, left-aligned under its copy.
  Widget _action(Widget button) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Align(alignment: Alignment.centerLeft, child: button),
  );
}

/// The age an echo row shows at the right of its title, and the one its
/// semantics label uses (req 26, 35): a daily note's `day` against today;
/// any other note `topic · <relative>` or `note · <relative>` of
/// `note_updated_at`, announced as the relative part only.
({String shown, String spoken}) _echoAge(Echo echo, DateTime now) {
  final day = echo.day;
  if (echo.noteRole == 'daily' &&
      day != null &&
      DateTime.tryParse(day) != null) {
    final age = formatDayAgo(day, now: now);
    return (shown: age, spoken: age);
  }
  final relative = formatRelativeAgo(echo.noteUpdatedAt, now: now);
  return switch (echo.noteRole) {
    'daily' => (shown: relative, spoken: relative),
    'topic' => (shown: 'topic · $relative', spoken: relative),
    _ => (shown: 'note · $relative', spoken: relative),
  };
}

/// One echo (Key `echo-row-<noteId>`, the whole padded row): one focusable
/// semantics node that Enter opens, holding the open target (Key
/// `echo-open-<noteId>`: title, age and passage) and the 24 px `link` box
/// (Key `echo-link-<noteId>`), which owns every press inside it.
class _EchoRow extends StatefulWidget {
  const _EchoRow({
    super.key,
    required this.echo,
    required this.now,
    required this.plan,
    required this.busy,
    required this.error,
    required this.onOpen,
    required this.onLink,
    required this.onDismissError,
  });

  final Echo echo;
  final DateTime now;

  /// [EchoLinkPlan.none] hides the `link` button.
  final EchoLinkPlan plan;

  /// A link of this row is in flight: `link` is disabled.
  final bool busy;

  /// The last failed link's message, shown in an `InlineError`.
  final String? error;
  final VoidCallback onOpen;
  final void Function(EchoLinkPlan plan) onLink;
  final VoidCallback onDismissError;

  @override
  State<_EchoRow> createState() => _EchoRowState();
}

class _EchoRowState extends State<_EchoRow> {
  final FocusNode _node = FocusNode(debugLabel: 'echo-row');

  /// Whether the row itself (not its `link` button) has the focus.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_node.hasPrimaryFocus != _focused) {
      setState(() => _focused = _node.hasPrimaryFocus);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) widget.onOpen();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final echo = widget.echo;
    final id = echo.noteId;
    final age = _echoAge(echo, widget.now);
    final passage = markdownPreviewText(echo.passage);
    final plan = widget.plan;
    final error = widget.error;

    final open = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('echo-open-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    echo.noteTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OmType.sans(
                      size: 13,
                      weight: FontWeight.w500,
                      color: OmColors.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  age.shown,
                  maxLines: 1,
                  style: OmType.mono(size: 10.5, color: OmColors.fg2),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Tooltip(
              message: passage,
              child: Text(
                passage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: OmType.sans(size: 12, color: OmColors.fg1, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );

    return Focus(
      focusNode: _node,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        focusable: true,
        focused: _focused,
        label: 'Echo from ${echo.noteTitle}, ${age.spoken}: $passage',
        onTap: widget.onOpen,
        child: Container(
          color: _focused ? OmColors.surface3 : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: ExcludeSemantics(child: open)),
                  if (plan != EchoLinkPlan.none) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      key: Key('echo-link-$id'),
                      height: 24,
                      child: OmButton(
                        kind: OmButtonKind.ghost,
                        size: 24,
                        dense: true,
                        focusable: true,
                        label: 'link',
                        semanticLabel: 'Link ${echo.noteTitle} to this note',
                        onPressed: widget.busy
                            ? null
                            : () => widget.onLink(plan),
                      ),
                    ),
                  ],
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Semantics(
                    container: true,
                    child: InlineError(
                      message: error,
                      onDismiss: widget.onDismissError,
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
