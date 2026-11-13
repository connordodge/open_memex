import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../state/echo_scroll_target.dart';
import '../state/editor_controller.dart';
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
import 'editor/echo_arrival_highlight.dart';
import 'editor/editor_toolbar.dart';
import 'editor/note_header.dart';
import 'editor/note_menu.dart';
import 'editor/segmented_body.dart';
import 'editor/source_surface.dart';
import 'editor/spelling_learn_error.dart';
import 'editor/text_segment.dart' show EditorScrollScope;

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
/// [TabsNotifier.takeScrollRestore] hands out or else to the top.
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
    _bodyCtrl = TextEditingController();
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
    // An echo's target wins over the restore, which is still taken so it
    // can't reach a later arrival; it also keeps a daily note's caret put.
    final echo = ref.read(echoScrollTargetProvider.notifier).take(note.id);
    final restore = _tabs?.takeScrollRestore(note.id);
    if (echo != null) {
      _landAtEcho(note, echo.startByte);
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
    // The note as it is stored now: [_hydratedNote] is the copy from when
    // this note was hydrated, and an edit saved since changed its text.
    final current = currentVaultData(
      ref.read(editorNoteAsyncProvider),
      ref.read(currentVaultProvider),
    )?.value;
    final note = current?.id == noteId ? current : _hydratedNote;
    if (echo != null && note != null) {
      _landAtEcho(note, echo.startByte);
      return;
    }
    _jumpAfterLayout(restore ?? 0.0);
  }

  /// The arrival highlight showing, if any.
  OverlayEntry? _echoHighlight;

  void _clearEchoHighlight() {
    final entry = _echoHighlight;
    _echoHighlight = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  /// An arrival with an echo's target (Spec #391 req 27): after [note]'s
  /// layout, scrolls the passage at [startByte] to a third of the viewport
  /// and highlights it, or opens at the top without a usable offset. The
  /// landing offset is recorded on the entry, so Back then Forward returns
  /// to the passage.
  void _landAtEcho(Note note, int? startByte) {
    final arrival = locateEchoArrival(
      note.contentMd,
      startByte,
      role: note.role,
    );
    if (arrival == null) {
      _jumpAfterLayout(0.0);
      return;
    }
    final jump = ++_jumpSeq;
    var tries = 0;
    void land(Duration _) {
      if (!mounted || jump != _jumpSeq) return;
      final found = _echoRow(note, arrival);
      if (found == null && ++tries < 8) {
        WidgetsBinding.instance
          ..addPostFrameCallback(land)
          ..scheduleFrame();
        return;
      }
      final viewport = found == null
          ? null
          : RenderAbstractViewport.maybeOf(found.row);
      if (found == null || viewport == null || !_scroll.hasClients) {
        _jumpAfterLayout(0.0);
        return;
      }
      final rects = echoArrivalRects(found.row, arrival, column: found.column);
      final position = _scroll.position;
      final reveal = viewport
          .getOffsetToReveal(found.row, 0.0, rect: rects.anchor)
          .offset;
      final to = math.min(
        reveal,
        reveal - (position.viewportDimension / 3 - rects.anchor.height / 2),
      );
      _scroll.jumpTo(
        to.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _reportsHeld = false;
      _tabs?.recordScrollOffset(note.id, _scroll.offset);
      _clearEchoHighlight();
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      final clip = switch (viewport) {
        final RenderBox box => box,
        _ => null,
      };
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => EchoArrivalHighlight(
          target: found.row,
          band: rects.band,
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

    WidgetsBinding.instance.addPostFrameCallback(land);
  }

  /// The laid-out widget holding [arrival] in this editor's segmented body
  /// showing [note]'s stored text, and its text segment; null until then.
  ({RenderBox row, RenderBox? column})? _echoRow(
    Note note,
    EchoArrival arrival,
  ) {
    Element? body;
    void findBody(Element e) {
      if (body != null) return;
      final w = e.widget;
      if (w is SegmentedBody && w.note.id == note.id) {
        body = e;
      } else {
        e.visitChildren(findBody);
      }
    }

    context.visitChildElements(findBody);
    final host = body;
    if (host == null ||
        (host.widget as SegmentedBody).content != note.contentMd) {
      return null;
    }
    final keys = {
      arrival.key,
      ?arrival.fallbackKey,
      ValueKey('text-segment-${arrival.segment}'),
    };
    final found = <Key, Element>{};
    void visit(Element e) {
      final key = e.widget.key;
      if (key != null && keys.contains(key)) found.putIfAbsent(key, () => e);
      e.visitChildren(visit);
    }

    host.visitChildren(visit);
    RenderBox? laidOut(Key? key) {
      final box = key == null ? null : found[key]?.findRenderObject();
      return box is RenderBox && box.attached && box.hasSize ? box : null;
    }

    final row = laidOut(arrival.key) ?? laidOut(arrival.fallbackKey);
    if (row == null) return null;
    return (
      row: row,
      column: laidOut(ValueKey('text-segment-${arrival.segment}')),
    );
  }

  /// Jumps to [offset], clamped, after the next frame: that frame lays out what
  /// the caller just asked to be built. Runs once, unless an arrival cancels it.
  void _jumpAfterLayout(double offset) {
    final jump = ++_jumpSeq;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || jump != _jumpSeq) return;
      if (_scroll.hasClients) {
        final position = _scroll.position;
        _scroll.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
      _reportsHeld = false;
    });
  }

  /// In Source, the field follows text the editor took from elsewhere while
  /// it showed [prev]'s (a merged save, a server change, Spec #7 Req 34a),
  /// with the selection kept on its line, so the next keystroke builds on
  /// it. Typing in the field already matches [next].
  void _followSource(EditorStateValue? prev, EditorStateValue next) {
    if (!_sourceMode || prev == null) return;
    final shown = _bodyCtrl.text;
    if (next.contentMd == shown || prev.contentMd != shown) return;
    _bodyCtrl.value = TextEditingValue(
      text: next.contentMd,
      selection: carrySelection(_bodyCtrl.selection, shown, next.contentMd),
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

  @override
  Widget build(BuildContext context) {
    final note = watchVaultValue(ref, editorNoteAsyncProvider, null);
    final editor = ref.watch(editorControllerProvider);
    final controller = ref.read(editorControllerProvider.notifier);
    final vaultPath = ref.watch(currentVaultProvider).localPath;

    if (ref.exists(tabsProvider)) ref.listen<TabsState>(tabsProvider, _onTabs);
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
          EditorToolbar(
            note: note,
            vaultPath: vaultPath,
            status: editor.status,
            rightOpen: widget.rightPanelOpen,
            onToggleRight: widget.onToggleRightPanel,
            sourceMode: _sourceMode,
            onToggleSource: note == null ? null : _toggleSource,
          ),
          const OmHairline(),
          if (note != null) NoteDeleteError(noteId: note.id),
          if (note != null) SpellingLearnError(noteId: note.id),
          Expanded(
            child: note == null
                ? _EmptyEditor()
                : _sourceMode
                ? SourceSurface(
                    bodyCtrl: _bodyCtrl,
                    bodyFocusNode: _bodyFocus,
                    noteId: note.id,
                    noteRole: note.role,
                    onContentChanged: controller.onContentChanged,
                    errorMessage: editor.errorMessage,
                    header: header,
                    dailyNoteId:
                        note.role == 'daily' &&
                            VirtualTodayTab.dateOf(note.id) == null
                        ? note.id
                        : null,
                    onTopicLinked: (version) => rebaseEditorOnVersion(
                      ref,
                      fallback: note,
                      version: version,
                      content: _bodyCtrl.text,
                    ),
                  )
                : EditorScrollScope(
                    controller: _scroll,
                    child: SegmentedBody(
                      // Until the post-frame hydrate loads a newly selected
                      // note, the editor still holds the previous note's text:
                      // keep the body on the note that text belongs to.
                      note: _hydratedNote ?? note,
                      content: editor.contentMd,
                      savedVersion: editor.lastSavedVersion,
                      onContentChanged: controller.onContentChanged,
                      primaryFocusNode: _bodyFocus,
                      errorMessage: editor.errorMessage,
                      onDismissError: controller.dismissError,
                      header: header,
                    ),
                  ),
          ),
          const OmHairline(),
          _StatusBar(status: editor.status),
        ],
      ),
    );
  }
}

/// The editor body: the segmented view (default) or the single Source field.
enum _BodyView { segmented, source }

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
