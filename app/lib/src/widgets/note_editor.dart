import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../state/echo_scroll_target.dart';
import '../state/editor_controller.dart';
import '../state/note_reveal.dart';
import '../state/pending_saves.dart';
import '../state/tabs_state.dart'
    show CanvasTab, TabsNotifier, TabsState, VirtualTodayTab, tabsProvider;
import '../state/today_state.dart';
import '../state/topic_actions.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/vault_scoped.dart';
import 'agents_sheet/agents_sheet.dart' show AgentsStatusBarButton;
import 'atoms.dart';
import 'editor/attachment_drop_target.dart';
import 'editor/echo_arrival_highlight.dart';
import 'editor/editor_toolbar.dart';
import 'editor/note_header.dart';
import 'editor/note_menu.dart';
import 'editor/note_reveal.dart';
import 'editor/segmented_body.dart';
import 'editor/source_surface.dart';
import 'editor/spelling_learn_error.dart';
import 'editor/text_segment.dart' show EditorScrollScope;
import 'find/find_in_note_host.dart';
import 'find/find_source_controller.dart';
import 'outline/section_tracker.dart';

/// The note editor host: wires the selected note and [EditorController] into
/// the [EditorToolbar], the body (with its [NoteHeader]) and the save status
/// bar.
///
/// The body is the [SegmentedBody] by default; the toolbar's `Source` toggle
/// switches it to the single plain [SourceSurface] field and back (WI #27).
/// Opening another note starts in the segmented view again.
///
/// The selected note comes from [editorNoteAsyncProvider] (D14a: nothing
/// while a vault's first read is pending or from another vault), so a virtual Today tab
/// (#22) shows as an empty, unsaved daily note. Opening a daily note puts
/// the cursor at the end of its focused body, ready to type.
///
/// Scroll offsets live on Tab history entries (#270, TD7). This editor reports
/// the segmented body's offset to [TabsNotifier.recordScrollOffset]; an arrival
/// on the active tab jumps once, after the note's layout, to the offset
/// [TabsNotifier.takeScrollRestore] hands out or else to the top. An echo's
/// target or a [noteRevealProvider] request lands instead (#66, D3).
class NoteEditor extends ConsumerStatefulWidget {
  const NoteEditor({
    super.key,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
  });
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  @override
  ConsumerState<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<NoteEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  final _bodyFocus = FocusNode(debugLabel: 'editor-body');
  String? _hydratedFor;

  /// The note the body was last hydrated for (see [_hydrate]).
  Note? _hydratedNote;

  /// Which body the editor shows; [_BodyView.segmented] for every newly
  /// opened note.
  _BodyView _view = _BodyView.segmented;

  bool get _sourceMode => _view == _BodyView.source;

  /// The segmented body's scroll. Source mode has no controller, so it reports
  /// nothing.
  final _scroll = ScrollController();

  /// True from an arrival until its jump has run, and until this State's first
  /// jump: a layout clamping the old offset, or the last offset of another tab
  /// on this note, must not be written into the entry just arrived at.
  bool _reportsHeld = true;

  /// Identifies the jump that is due, so an arrival cancels an earlier one.
  int _jumpSeq = 0;

  /// Identifies the latest reveal request on the note shown, so a later one
  /// cancels it while it still waits for its row.
  int _revealSeq = 0;

  /// The reveal request on the note shown that still waits for its row, by
  /// its [_revealSeq], or null.
  int? _revealWaiting;

  /// The [_jumpSeq] of an arrival landing that gave up while a later request
  /// on the note shown still waited: that request owes the arrival's jump to
  /// the top if it gives up too.
  int? _topOwedAt;

  /// The note this State was built to zoom into, null on a note tab. An
  /// `AnimatedSwitcher` keeps the old zoomed editor alive through a zoom
  /// change, and it sees the new selection too. A note tab's editor stays until
  /// the next build too, when the active tab becomes a zoomed canvas.
  String? _zoomedNote;

  /// The active tab now needs another editor than this State: it takes no
  /// restore, reports no offset and never jumps. Sticky on a zoomed editor,
  /// since the incoming editor can be on the note this one was built for. A note
  /// tab's editor clears it: the next build goes on using this State when the
  /// active tab is a note tab again by then.
  bool _outgoing = false;

  /// The open tabs, or null when nothing created them: an editor pumped without
  /// a workspace must not, as creating them selects today's note.
  TabsNotifier? get _tabs =>
      ref.exists(tabsProvider) ? ref.read(tabsProvider.notifier) : null;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    // Source mode draws Find in note's match ink (#61 F6, TD3).
    _bodyCtrl = FindSourceController();
    _scroll.addListener(_reportScroll);
    if (ref.exists(tabsProvider)) {
      final tab = ref.read(tabsProvider).activeTab;
      if (tab is CanvasTab) _zoomedNote = tab.zoomedNoteId;
    }
  }

  @override
  void dispose() {
    // The arrival highlight listens to [_scroll] and follows a row of this
    // editor: it goes first.
    _clearEchoHighlight();
    _scroll.dispose();
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _hydrate(Note? note, EditorController controller) {
    if (note?.id == _hydratedFor) return;
    _hydratedFor = note?.id;
    _hydratedNote = note;
    // A virtual Today note that just became [note] keeps the editor's text
    // (typing may still be going on); any other note loads, in the
    // segmented view.
    final resolved = note != null && controller.takeResolved(note.id);
    if (!resolved) {
      controller.loadNote(note);
      _view = _BodyView.segmented;
    }
    // Rebuild with the hydrated note (this may run outside a build).
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
    final editor = ref.read(editorControllerProvider);
    _titleCtrl.text = editor.title;
    if (_bodyCtrl.text != editor.contentMd) {
      _bodyCtrl.value = TextEditingValue(
        text: editor.contentMd,
        selection: TextSelection.collapsed(offset: editor.contentMd.length),
      );
    }
    if (resolved || note == null || _outgoing) return;
    // An echo's target wins over the restore and a reveal request, which are
    // still taken so they can't reach a later arrival; a reveal request wins
    // over the restore. Either keeps a daily note's caret put.
    final echo = ref.read(echoScrollTargetProvider.notifier).take(note.id);
    final restore = _tabs?.takeScrollRestore(note.id);
    final reveal = ref.read(noteRevealProvider.notifier).take(note.id);
    final request = echo == null ? reveal : _echoRequest(echo);
    if (request != null) {
      _reveal(note, request, arrival: true);
      return;
    }
    _jumpAfterLayout(restore ?? 0.0);
    if (restore == null && note.role == 'daily') {
      _bodyCtrl.selection = TextSelection.collapsed(
        offset: _bodyCtrl.text.length,
      );
      _bodyFocus.requestFocus();
    }
  }

  void _reportScroll() {
    final noteId = _hydratedFor;
    if (_reportsHeld || _outgoing || noteId == null) return;
    _tabs?.recordScrollOffset(noteId, _scroll.offset);
  }

  /// An arrival on the active tab. A different note jumps from [_hydrate] when
  /// it has loaded. The note already hydrated won't hydrate again (two tabs on
  /// one note), so it jumps from here.
  void _onTabs(TabsState? previous, TabsState next) {
    if (previous?.arrivals == next.arrivals) return;
    _clearEchoHighlight();
    final tab = next.activeTab;
    if ((tab is CanvasTab ? tab.zoomedNoteId : null) != _zoomedNote) {
      _outgoing = true;
      return;
    }
    if (_zoomedNote == null) _outgoing = false;
    final noteId = next.activeNoteId;
    _reportsHeld = true;
    _jumpSeq++;
    if (noteId == null || noteId != _hydratedFor) return;
    setState(() => _view = _BodyView.segmented);
    final echo = ref.read(echoScrollTargetProvider.notifier).take(noteId);
    final restore = _tabs?.takeScrollRestore(noteId);
    // A request made before this arrival dies here (D3b); one made after it
    // reaches [_onReveal].
    final reveal = ref.read(noteRevealProvider.notifier).take(noteId);
    final request = echo == null ? reveal : _echoRequest(echo);
    final note = _storedNote(noteId);
    if (request != null && note != null) {
      _reveal(note, request, arrival: true);
      return;
    }
    _jumpAfterLayout(restore ?? 0.0);
  }

  /// Note [noteId] as it is stored now: [_hydratedNote] is the copy from when
  /// this note was hydrated, and an edit saved since changed its text.
  Note? _storedNote(String noteId) {
    final current = currentVaultData(
      ref.read(editorNoteAsyncProvider),
      ref.read(currentVaultProvider),
    )?.value;
    return current?.id == noteId ? current : _hydratedNote;
  }

  /// A reveal request made for the note shown (D3a): it lands on the next
  /// frame. Requests for any other note wait for its hydrate.
  void _onReveal(PendingReveal? previous, PendingReveal? next) {
    final noteId = _hydratedFor;
    if (next == null || noteId == null || _outgoing) return;
    if (next.request.noteId != noteId) return;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || _outgoing || noteId != _hydratedFor) return;
        // A later request in the same frame replaced this one: the first
        // callback takes it, the others find nothing.
        final request = ref.read(noteRevealProvider.notifier).take(noteId);
        final note = _storedNote(noteId);
        if (request == null || note == null) return;
        if (!_sourceMode) {
          _reveal(note, request, now: true);
        } else if (request.leaveSource) {
          setState(() => _view = _BodyView.segmented);
          _reveal(note, request);
        }
      })
      ..scheduleFrame();
  }

  /// An echo's target (Spec #391 req 27) as the reveal it lands as: its
  /// passage a third of the way down, highlighted.
  NoteRevealRequest _echoRequest(EchoScrollTarget echo) => NoteRevealRequest(
    echo.noteId,
    RevealAtByte(echo.startByte),
    const RevealThird(),
    flash: true,
  );

  /// The arrival highlight showing, if any.
  OverlayEntry? _echoHighlight;

  void _clearEchoHighlight() {
    final entry = _echoHighlight;
    _echoHighlight = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  /// Lands [request] on [note] under the D3 rules: finds its anchor in the
  /// segmented body after the next layout (at once when [now]: the caller
  /// runs after a layout), retrying for up to 8 frames, then scrolls it to
  /// the request's placement, records the offset on the entry and, with
  /// `flash`, highlights its band. Never touches the selection, focus or
  /// history. [arrival]: the request came with an arrival on this note, which
  /// then opens at the top when the request cannot land; on the note already
  /// shown such a request does nothing. A byte request with no offset always
  /// opens at the top.
  ///
  /// An arrival cancels any jump still due when it starts. A request on the
  /// note shown cancels one only when it lands, so one that gives up leaves an
  /// arrival landing that is still retrying to finish (and to release the
  /// held scroll reports). An arrival landing that gives up while a later
  /// request on the note shown still waits leaves that request to land; if it
  /// gives up too, it opens the note at the top for the arrival.
  void _reveal(
    Note note,
    NoteRevealRequest request, {
    bool arrival = false,
    bool now = false,
  }) {
    final at = request.at;
    var content = note.contentMd;
    EchoArrival? target;
    int? end;
    int? cardStart;
    int? cardEnd;
    switch (at) {
      case RevealAtByte(:final startByte):
        if (startByte == null) {
          _jumpAfterLayout(0.0);
          return;
        }
        target = locateEchoArrival(content, startByte, role: note.role);
      case RevealAtText(:final segment, :final start, end: final to):
        content = at.content;
        target = locateInSegment(content, segment, start, role: note.role);
        // `toLocal` shifts a prose row's offsets by its start.
        if (target != null && to != null) {
          end = (target.local + to - start).clamp(0, target.rowText.length);
        }
      case RevealAtCard(:final segment):
        content = at.content;
        target = locateInSegment(content, segment, 0, role: note.role);
        // A text segment is no card.
        if (target?.kind != null) target = null;
        // The card's lines holding [start, end) (#61 F6, D2).
        cardStart = at.start;
        cardEnd = at.end;
    }
    final found = target;
    if (found == null) {
      if (arrival) _jumpAfterLayout(0.0);
      return;
    }
    final jump = arrival ? ++_jumpSeq : _jumpSeq;
    final mine = arrival ? null : ++_revealSeq;
    // Requests on the note shown made after this arrival have higher numbers.
    final revealsBefore = _revealSeq;
    if (mine != null) _revealWaiting = mine;
    var tries = 0;
    void land(Duration _) {
      if (!mounted || jump != _jumpSeq) return;
      if (mine != null && mine != _revealSeq) return;
      final shown = revealRow(context, note.id, content, found);
      if (shown == null && ++tries < 8) {
        WidgetsBinding.instance
          ..addPostFrameCallback(land)
          ..scheduleFrame();
        return;
      }
      final viewport = shown == null
          ? null
          : RenderAbstractViewport.maybeOf(shown.row);
      if (shown == null || viewport == null || !_scroll.hasClients) {
        if (mine != null) {
          if (_revealWaiting == mine) _revealWaiting = null;
          if (_topOwedAt == jump) {
            _topOwedAt = null;
            _jumpAfterLayout(0.0);
          }
        } else if ((_revealWaiting ?? 0) > revealsBefore) {
          // A request made after this arrival still waits for its row: it
          // lands, or jumps to the top for this arrival if it gives up.
          _topOwedAt = jump;
          _reportsHeld = false;
        } else {
          _jumpAfterLayout(0.0);
        }
        return;
      }
      final rects = echoArrivalRects(shown.row, found, column: shown.column);
      final anchor = at is RevealAtByte
          ? rects.anchor
          : revealAnchorRect(
              shown.row,
              found,
              end: end,
              element: shown.element,
              cardStart: cardStart,
              cardEnd: cardEnd,
            );
      final position = _scroll.position;
      final to = revealScrollOffset(
        request.placement,
        reveal: viewport.getOffsetToReveal(shown.row, 0.0, rect: anchor).offset,
        pixels: position.pixels,
        viewport: position.viewportDimension,
        height: anchor.height,
      );
      // Landing now: any jump still due (an arrival's) is cancelled.
      if (mine != null) {
        _jumpSeq++;
        if (_revealWaiting == mine) _revealWaiting = null;
      }
      // Held across the jump: the landing records its offset once, below.
      _reportsHeld = true;
      if (to != null) {
        _scroll.jumpTo(
          to.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
      _reportsHeld = false;
      _tabs?.recordScrollOffset(note.id, _scroll.offset);
      _clearEchoHighlight();
      if (request.flash) _flash(shown.row, rects.band, viewport);
    }

    if (now) {
      land(Duration.zero);
    } else {
      WidgetsBinding.instance.addPostFrameCallback(land);
    }
  }

  /// Shows the arrival highlight over [band] of [row], clipped to
  /// [viewport], in the root overlay.
  void _flash(RenderBox row, Rect band, RenderAbstractViewport viewport) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final clip = switch (viewport) {
      final RenderBox box => box,
      _ => null,
    };
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => EchoArrivalHighlight(
        target: row,
        band: band,
        clip: clip,
        repaint: _scroll,
        onDone: () {
          if (identical(_echoHighlight, entry)) _echoHighlight = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _echoHighlight = entry;
    overlay.insert(entry);
  }

  /// The segmented body as the editor shows it: the Outline's section
  /// tracker (#58) wraps it here.
  Widget _trackSections(Note note, Widget body) =>
      SectionTracker(note: note, child: body);

  /// Jumps to [offset], clamped, after the next frame: that frame lays out what
  /// the caller just asked to be built. Runs once, unless an arrival cancels it.
  /// Schedules that frame: a caller inside a post-frame callback (a landing
  /// that gave up) has none coming.
  void _jumpAfterLayout(double offset) {
    final jump = ++_jumpSeq;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || jump != _jumpSeq) return;
        if (_scroll.hasClients) {
          final position = _scroll.position;
          _scroll.jumpTo(
            offset.clamp(position.minScrollExtent, position.maxScrollExtent),
          );
        }
        _reportsHeld = false;
      })
      ..scheduleFrame();
  }

  /// In Source, the field follows text the editor took from elsewhere while
  /// it showed [prev]'s (a merged save, a server change, Spec #7 Req 34a),
  /// so the next keystroke builds on it. A merged save's text keeps the
  /// selection on its line; any other keeps its offsets, clamped. Typing in
  /// the field already matches [next].
  void _followSource(EditorStateValue? prev, EditorStateValue next) {
    if (!_sourceMode || prev == null) return;
    final shown = _bodyCtrl.text;
    if (next.contentMd == shown || prev.contentMd != shown) return;
    _bodyCtrl.value = TextEditingValue(
      text: next.contentMd,
      selection: keepSelection(
        _bodyCtrl.selection,
        shown,
        next.contentMd,
        carry:
            next.contentMd ==
            ref.read(editorControllerProvider.notifier).mergedText,
      ),
    );
  }

  /// Switches the body between the segmented view and Source. Source starts
  /// from the editor's current markdown; coming back re-splits it.
  void _toggleSource() {
    final content = ref.read(editorControllerProvider).contentMd;
    setState(() {
      _view = _sourceMode ? _BodyView.segmented : _BodyView.source;
      if (_sourceMode) {
        _bodyCtrl.value = TextEditingValue(
          text: content,
          selection: TextSelection.collapsed(offset: content.length),
        );
      }
    });
  }

  /// The editor body for [note]: the Source field, or the segmented body
  /// through [_trackSections].
  Widget _body(
    Note note,
    _BodyState editor,
    EditorController controller,
    Widget? header,
  ) {
    if (_sourceMode) {
      return SourceSurface(
        bodyCtrl: _bodyCtrl,
        bodyFocusNode: _bodyFocus,
        noteId: note.id,
        noteRole: note.role,
        onContentChanged: controller.onContentChanged,
        errorMessage: editor.errorMessage,
        header: header,
        // The outgoing editor of a zoom paints no find highlights (#61 F6).
        active: !_outgoing,
        dailyNoteId:
            note.role == 'daily' && VirtualTodayTab.dateOf(note.id) == null
            ? note.id
            : null,
        onTopicLinked: (version) => rebaseEditorOnVersion(
          ref,
          fallback: note,
          version: version,
          content: _bodyCtrl.text,
        ),
      );
    }
    return _trackSections(
      note,
      EditorScrollScope(
        controller: _scroll,
        child: SegmentedBody(
          // Until the post-frame hydrate loads a newly selected note, the
          // editor still holds the previous note's text: keep the body on
          // the note that text belongs to.
          note: _hydratedNote ?? note,
          content: editor.contentMd,
          savedVersion: editor.lastSavedVersion,
          onContentChanged: controller.onContentChanged,
          primaryFocusNode: _bodyFocus,
          errorMessage: editor.errorMessage,
          onDismissError: controller.dismissError,
          header: header,
          carryCaret: editor.contentMd == controller.mergedText,
        ),
      ),
    );
  }

  /// What the editor shows over [note]'s body, above it in the body's Stack
  /// (Find in note's bar and matches, #61).
  List<Widget> _bodyOverlays(Note note) => [
    // The attach action's link to this editor (#146; #147's drop and paste
    // reach the editor through it too). Draws nothing.
    NoteAttachHost(
      note: _hydratedNote ?? note,
      sourceMode: _sourceMode,
      sourceController: _bodyCtrl,
      bodyFocus: _bodyFocus,
      active: !_outgoing,
    ),
    Positioned.fill(
      child: FindInNoteHost(
        note: _hydratedNote ?? note,
        sourceMode: _sourceMode,
        sourceController: _bodyCtrl as FindSourceController,
        bodyFocus: _bodyFocus,
        zoomedNote: _zoomedNote,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final note = watchVaultValue(ref, editorNoteAsyncProvider, null);
    // Only the fields the body renders (Spec #122 R20): a save status
    // change rebuilds the toolbar and the status bar, not the body.
    final editor = ref.watch(
      editorControllerProvider.select(
        (e) => (
          contentMd: e.contentMd,
          errorMessage: e.errorMessage,
          lastSavedVersion: e.lastSavedVersion,
        ),
      ),
    );
    final controller = ref.read(editorControllerProvider.notifier);
    final vaultPath = ref.watch(currentVaultProvider).localPath;

    if (ref.exists(tabsProvider)) ref.listen<TabsState>(tabsProvider, _onTabs);
    ref.listen<PendingReveal?>(noteRevealProvider, _onReveal);
    ref.listen<EditorStateValue>(editorControllerProvider, _followSource);
    ref.listen<AsyncValue<VaultScoped<Note?>>>(
      editorNoteAsyncProvider,
      (_, curr) => _hydrate(
        currentVaultData(curr, ref.read(currentVaultProvider))?.value,
        controller,
      ),
    );
    if (note != null && _hydratedFor != note.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hydrate(note, controller);
      });
    }

    final header = note == null
        ? null
        : NoteHeader(
            note: note,
            titleCtrl: _titleCtrl,
            onTitleChanged: controller.onTitleChanged,
            pendingLabel: ref.watch(pendingSaveLabelProvider(note.id)),
          );

    // Returns a plain Container (not Expanded): each call site places this in
    // its own flex/bounded parent (workspace `_TabBody` inside an Expanded,
    // `_ZoomedNoteView` inside a Positioned.fill). Rooting in Expanded here
    // caused two competing FlexParentData widgets on the same RenderObject.
    return Container(
      color: OmColors.surface2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Consumer(
            builder: (context, ref, _) => EditorToolbar(
              note: note,
              vaultPath: vaultPath,
              status: ref.watch(_saveStatus),
              rightOpen: widget.rightPanelOpen,
              onToggleRight: widget.onToggleRightPanel,
              sourceMode: _sourceMode,
              onToggleSource: note == null ? null : _toggleSource,
            ),
          ),
          const OmHairline(),
          if (note != null) NoteDeleteError(noteId: note.id),
          if (note != null) SpellingLearnError(noteId: note.id),
          Expanded(
            child: note == null
                ? _EmptyEditor()
                : Stack(
                    children: [
                      Positioned.fill(
                        // Files dropped on the body attach (#147, R7); the
                        // outgoing editor of a zoom takes no drop.
                        child: AttachmentDropTarget(
                          active: !_outgoing,
                          child: _body(note, editor, controller, header),
                        ),
                      ),
                      ..._bodyOverlays(note),
                    ],
                  ),
          ),
          const OmHairline(),
          Consumer(
            builder: (context, ref, _) =>
                _StatusBar(status: ref.watch(_saveStatus)),
          ),
        ],
      ),
    );
  }
}

/// The editor body: the segmented view (default) or the single Source field.
enum _BodyView { segmented, source }

/// What the editor body renders of the editor state.
typedef _BodyState = ({
  String contentMd,
  String? errorMessage,
  int? lastSavedVersion,
});

/// The editor's save status, for the toolbar and the status bar.
final _saveStatus = editorControllerProvider.select((e) => e.status);

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status});
  final SaveStatus status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SaveStatus.idle => ('idle', OmColors.fg3),
      SaveStatus.dirty => ('unsaved', OmColors.warn),
      SaveStatus.saving => ('saving…', OmColors.fg2),
      SaveStatus.clean => ('saved', OmColors.accent),
      SaveStatus.error => ('save failed', OmColors.danger),
      SaveStatus.conflict => ('conflict', OmColors.danger),
    };
    return Container(
      key: const Key('save-indicator'),
      height: 26,
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          OmDot(color: color, size: 5, pulse: status == SaveStatus.saving),
          const SizedBox(width: 5),
          Text(
            label,
            style: OmType.mono(size: 10.5, color: color, letterSpacing: 0.2),
          ),
          const SizedBox(width: 10),
          Text('·', style: OmType.mono(size: 11, color: OmColors.fg4)),
          const SizedBox(width: 10),
          Text('md', style: OmType.mono(size: 10.5, color: OmColors.fg3)),
          const Spacer(),
          const AgentsStatusBarButton(key: Key('status-bar-agents')),
        ],
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'select a note from the sidebar',
            style: OmType.mono(size: 12, color: OmColors.fg3),
          ),
          const SizedBox(height: 12),
          Text(
            'or press ⌘N to create a new one',
            style: OmType.mono(size: 11, color: OmColors.fg4),
          ),
        ],
      ),
    );
  }
}
