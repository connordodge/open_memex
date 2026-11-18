// WI #85 (Spec #61 F6): Find in note wired into the note editor. The note
// editor mounts one [FindInNoteHost] in its `_bodyOverlays` slot (ruling D6);
// it feeds F1's state from the shown body (sources, caret), performs the
// native menu's Find actions, mounts F2's bar, scrolls every new current
// match through the note reveal seam (#66, D2) and puts the editor's focus
// and selection back on close. The body's fields read their decorations
// (F4, D7) and whether they belong to the active editor (F3) through the
// small pieces at the top of this file.
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart' show Note;
import '../../editor/editor_rows.dart' show RowKind, splitRows;
import '../../editor/find_in_note.dart';
import '../../editor/segments.dart';
import '../../state/editor_controller.dart' show editorControllerProvider;
import '../../state/find_in_note_state.dart';
import '../../state/note_reveal.dart';
import '../../state/tabs_state.dart' show CanvasTab, TabsState, tabsProvider;
import '../../state/vault_state.dart' show currentVaultProvider;
import '../../vault_access/vault_scoped.dart' show currentVaultData;
import '../editor/excerpt_card.dart' show excerptRenderProvider;
import '../editor/find_decoration.dart';
import '../editor/line_boxes.dart';
import '../editor/note_reveal.dart' show revealScrollOffset;
import 'find_bar.dart';
import 'find_source_controller.dart';
import 'find_sources.dart';

/// The top inset every new current match scrolls into view with: the box's
/// 10 px offset, its 38 px height and a 12 px margin (Req 23).
const double findRevealInset = 60;

/// One text segment of the segmented body: its `split()` index, its
/// controller (segment offsets) and its focus node (focused while one of its
/// rows is).
typedef FindBodyField = ({
  int segment,
  TextEditingController controller,
  FocusNode focus,
});

/// What a note editor's [FindInNoteHost] and its body share, found by the
/// editor's primary body focus node (the one both `SegmentedBody` and
/// `SourceSurface` take): the host sits beside the body in the editor's
/// Stack, not above it.
final class FindEditorLink {
  FindEditorLink._();

  static final _links = Expando<FindEditorLink>('find-editor-link');

  /// The link of the editor whose primary body focus node is [primary].
  static FindEditorLink of(FocusNode primary) =>
      _links[primary] ??= FindEditorLink._();

  /// Whether the editor is the active one (F3's `active`): false for the
  /// outgoing editor of a canvas zoom. Set by the host.
  final ValueNotifier<bool> active = ValueNotifier<bool>(true);

  /// The segmented body's text segments, while it shows. Set by the body.
  List<FindBodyField> Function()? fields;
}

/// Whether the fields below belong to the active editor (F3's `active`), for
/// fields whose builders do not pass it on (an excerpt card's rows). True
/// where no scope is above.
class FindActiveScope extends InheritedWidget {
  const FindActiveScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FindActiveScope>()?.active ??
      true;

  @override
  bool updateShouldNotify(FindActiveScope oldWidget) =>
      active != oldWidget.active;
}

/// The [FindDecoration] of one field showing `[start, end)` of source
/// ([segment], [kind]) in [state], in field offsets (minus [start]); null
/// while the bar is closed, the query is empty or no match touches the
/// field (D7).
///
/// - `inkRanges`: every match touching the field, clipped to it.
/// - `current`: the current match's range when it touches the field.
/// - `revealRange`: the current match's range when it is hidden (Req 27).
FindDecoration? findFieldDecoration(
  FindInNoteState state, {
  required int segment,
  required FindSourceKind kind,
  required int start,
  required int end,
}) {
  if (!state.open || state.query.isEmpty) return null;
  final ink = <TextRange>[];
  TextRange? current;
  TextRange? reveal;
  for (final (i, m) in state.matches.indexed) {
    if (m.segment != segment || m.kind != kind) continue;
    if (m.end <= start || m.start >= end) continue;
    final range = TextRange(
      start: math.max(m.start, start) - start,
      end: math.min(m.end, end) - start,
    );
    ink.add(range);
    if (i == state.current) {
      current = range;
      if (m.hidden) reveal = range;
    }
  }
  if (ink.isEmpty) return null;
  return FindDecoration(revealRange: reveal, inkRanges: ink, current: current);
}

/// Find in note over one note editor's body (Spec #61 F6), mounted by the
/// editor over its body (`Positioned.fill` in the body's Stack).
///
/// - Sources (Reqs 1-4, 37): while the bar is open, after every change to
///   the searched text (the body's text segments and loaded excerpt card
///   text in live preview, the Source field in Source mode) and before every
///   menu action, it gives F1 the shown text, with `carry`, and the caret
///   anchor (the last body or Source selection, Req 18).
/// - Menu actions (Reqs 11-15, 21): only the active editor performs them.
///   `next`/`previous` with an editor field focused also select a new body
///   match there.
/// - Every step, opening and query change requests one reveal of the new
///   current match with `RevealWithin(60)` (Req 23, D2); in Source mode the
///   Source field's page scrolls itself with the same inset (TD4).
/// - Close (Req 40): focus returns to the editor, with the current body
///   match selected, or else the caret where it was.
/// - Another note showing closes the bar (Req 42): a tab arrival that shows
///   another note or tab, a zoom change, a vault switch, or the editor
///   going away while active.
class FindInNoteHost extends ConsumerStatefulWidget {
  const FindInNoteHost({
    super.key,
    required this.note,
    required this.sourceMode,
    required this.sourceController,
    required this.bodyFocus,
    this.zoomedNote,
  });

  /// The note the body shows.
  final Note note;

  /// Whether the body is the Source field.
  final bool sourceMode;

  /// The Source field's controller.
  final FindSourceController sourceController;

  /// The editor's primary body focus node: the first text segment's, or the
  /// Source field's.
  final FocusNode bodyFocus;

  /// The note the editor was built to zoom into, null on a note tab.
  final String? zoomedNote;

  @override
  ConsumerState<FindInNoteHost> createState() => _FindInNoteHostState();
}

class _FindInNoteHostState extends ConsumerState<FindInNoteHost> {
  late final FindEditorLink _link = FindEditorLink.of(widget.bodyFocus);
  late final FindInNoteNotifier _notifier;

  /// Whether this editor is the active one. A zoomed editor that stopped
  /// being active never is again (the incoming editor can be on its note).
  bool _active = true;

  /// The sources last given to F1, or null.
  List<FindSource>? _pushed;

  /// The Source toggle switched modes since the last flush.
  bool _modeSwitch = false;

  /// A flush is scheduled after this frame.
  bool _flushDue = false;

  /// The text segment that last had focus in this note, or null.
  int? _lastSegment;

  /// Whether the Source field had focus since Source mode started.
  bool _sourcePlaced = false;

  /// True while a menu step runs (it reveals its match itself).
  bool _stepping = false;

  /// Hidden ranges by text, kept from the last flush.
  Map<String, List<FindRange>> _hidden = const {};

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(findInNoteProvider.notifier);
    final tabs = ref.exists(tabsProvider) ? ref.read(tabsProvider) : null;
    _active = _link.active.value && (tabs == null || _zoomMatches(tabs));
    if (_active != _link.active.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _link.active.value = _active;
      });
    }
    if (ref.exists(tabsProvider)) {
      ref.listenManual<TabsState>(tabsProvider, _onTabs);
    }
    ref.listenManual(currentVaultProvider, (previous, next) {
      if (_active && previous != next) _closeForNoteChange();
    });
    ref.listenManual<FindMenuDispatch?>(findMenuActionsProvider, _onMenu);
    ref.listenManual<FindInNoteState>(findInNoteProvider, _onState);
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(FindInNoteHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceMode != widget.sourceMode) {
      _modeSwitch = true;
      _lastSegment = null;
      _sourcePlaced = false;
      _scheduleFlush();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    // The note stops showing in the active editor (Req 42). Providers can't
    // change while the tree is locked: after this frame.
    if (_active) {
      final notifier = _notifier;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => notifier.noteChanged(),
      );
    }
    super.dispose();
  }

  /// Whether the active tab shows what this editor was built for: its
  /// zoomed note, or (on a note tab) no zoomed note.
  bool _zoomMatches(TabsState tabs) {
    final tab = tabs.activeTab;
    return (tab is CanvasTab ? tab.zoomedNoteId : null) == widget.zoomedNote;
  }

  void _onTabs(TabsState? previous, TabsState next) {
    final matches = _zoomMatches(next);
    final active = widget.zoomedNote == null ? matches : _active && matches;
    if (active != _active) {
      if (_active) _closeForNoteChange();
      setState(() => _active = active);
      _link.active.value = active;
      widget.sourceController.find = null;
      return;
    }
    if (!_active || previous == null || previous.arrivals == next.arrivals) {
      return;
    }
    if (previous.activeIndex != next.activeIndex ||
        previous.activeNoteId != next.activeNoteId) {
      _closeForNoteChange();
    }
  }

  /// Another note shows: the bar closes and the caret anchor is forgotten.
  void _closeForNoteChange() {
    _notifier.noteChanged();
    _pushed = null;
    _lastSegment = null;
    _sourcePlaced = false;
  }

  // ----------------------------------------------------------------- state

  void _onState(FindInNoteState? previous, FindInNoteState next) {
    if (!_active) return;
    widget.sourceController.find = widget.sourceMode
        ? findFieldDecoration(
            next,
            segment: 0,
            kind: FindSourceKind.source,
            start: 0,
            end: widget.sourceController.text.length,
          )
        : null;
    if (!next.open || _stepping) return;
    final opened = previous == null || !previous.open;
    if (!opened && previous.query == next.query) return;
    // Opening and a query change set a new current match (Reqs 18, 23).
    if (next.currentMatch case final match?) _reveal(match);
  }

  void _onFocus() {
    if (!_active || !mounted) return;
    if (widget.sourceMode) {
      if (widget.bodyFocus.hasFocus) _sourcePlaced = true;
    } else if (_focusedField() case final field?) {
      _lastSegment = field.segment;
    }
    if (ref.read(findInNoteProvider).open) _scheduleFlush();
  }

  // --------------------------------------------------------------- sources

  void _scheduleFlush() {
    if (_flushDue) return;
    _flushDue = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _flush())
      ..ensureVisualUpdate();
  }

  /// Gives F1 the shown text (when it changed, or the mode switched) and
  /// the caret anchor.
  void _flush() {
    _flushDue = false;
    if (!mounted || !_active) return;
    final sources = _sources();
    final stored = ref.read(findInNoteProvider).sources;
    if (_modeSwitch) {
      _modeSwitch = false;
      _notifier.switchMode(sources, tokenOffset: _tokenOffsets());
      _pushed = sources;
    } else if (!identical(stored, _pushed) ||
        !_sameSources(_pushed!, sources)) {
      _notifier.setSources(sources);
      _pushed = sources;
    }
    final caret = _caret();
    if (caret != ref.read(findInNoteProvider).caret) _notifier.setCaret(caret);
  }

  List<Segment> _split(String content) => split(
    content,
    isDaily: widget.note.role == 'daily',
    noteFooter: widget.note.role != 'guide',
  );

  /// The searched text as the body shows it now (Reqs 1-2).
  List<FindSource> _sources() {
    if (widget.sourceMode) {
      return [
        FindSource(
          segment: 0,
          kind: FindSourceKind.source,
          text: widget.sourceController.text,
        ),
      ];
    }
    final content = ref.read(editorControllerProvider).contentMd;
    final hidden = <String, List<FindRange>>{};
    List<FindRange> hiddenOf(String text) =>
        hidden[text] ??= _hidden[text] ?? _hiddenRanges(text);
    final out = <FindSource>[];
    for (final (i, segment) in _split(content).indexed) {
      switch (segment) {
        case TextSegment(:final text):
          out.add(
            FindSource(
              segment: i,
              kind: FindSourceKind.body,
              text: text,
              hidden: hiddenOf(text),
            ),
          );
        case final TransclusionSegment card:
          if (_cardText(card) case final text?) {
            out.add(
              FindSource(
                segment: i,
                kind: FindSourceKind.card,
                text: text,
                hidden: hiddenOf(text),
              ),
            );
          }
        case FooterSegment():
          break;
      }
    }
    _hidden = hidden;
    return out;
  }

  /// The card's loaded text (`RenderedExcerpt.text`), or null before it
  /// loads and for a removed excerpt's stub, which shows no matches.
  String? _cardText(TransclusionSegment card) {
    final rendered = currentVaultData(
      ref.read(
        excerptRenderProvider((date: card.date, from: card.from, to: card.to)),
      ),
      ref.read(currentVaultProvider),
    )?.value;
    return rendered == null || rendered.removed ? null : rendered.text;
  }

  /// The ranges of [text] its rows render hidden, row by row as the editor
  /// and the cards lay them out.
  static List<FindRange> _hiddenRanges(String text) => [
    for (final spec in splitRows(text, atSegmentStart: true))
      for (final range in livePreviewHiddenRanges(
        text.substring(spec.textStart, spec.textEnd),
        itemText: spec.isItem,
        codeRow: spec.kind == RowKind.code,
      ))
        FindRange(spec.textStart + range.start, spec.textStart + range.end),
  ];

  static bool _sameSources(List<FindSource> a, List<FindSource> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].segment != b[i].segment ||
          a[i].kind != b[i].kind ||
          a[i].text != b[i].text) {
        return false;
      }
    }
    return true;
  }

  /// The Source-field offset where each `split()` segment starts.
  int Function(int segment) _tokenOffsets() {
    final starts = <int>[];
    var at = 0;
    for (final segment in _split(
      ref.read(editorControllerProvider).contentMd,
    )) {
      starts.add(at);
      at += switch (segment) {
        TextSegment(:final text) => text.length,
        TransclusionSegment(:final raw) => raw.length,
        FooterSegment() => 0,
      };
    }
    return (segment) => segment < starts.length ? starts[segment] : at;
  }

  /// The caret anchor: the focused (or last focused) text segment's
  /// selection start, the Source field's in Source mode; null while the
  /// caret was never placed in this note (Req 18).
  FindCaret? _caret() {
    if (widget.sourceMode) {
      final selection = widget.sourceController.selection;
      if (!_sourcePlaced || !selection.isValid) return null;
      return FindCaret(0, selection.start);
    }
    final field = _focusedField() ?? _fieldAt(_lastSegment);
    if (field == null) return null;
    final selection = field.controller.selection;
    if (!selection.isValid) return null;
    return FindCaret(field.segment, selection.start);
  }

  List<FindBodyField> get _fields => _link.fields?.call() ?? const [];

  FindBodyField? _focusedField() {
    for (final field in _fields) {
      if (field.focus.hasFocus) return field;
    }
    return null;
  }

  FindBodyField? _fieldAt(int? segment) {
    if (segment == null) return null;
    for (final field in _fields) {
      if (field.segment == segment) return field;
    }
    return null;
  }

  // ---------------------------------------------------------------- actions

  void _onMenu(FindMenuDispatch? previous, FindMenuDispatch? next) {
    if (next == null || !_active || !mounted) return;
    _flush();
    switch (next.action) {
      case FindMenuAction.show:
        _notifier.show();
      case FindMenuAction.useSelection:
        // A selection in the title (or anywhere outside the body) is
        // ignored (Req 14).
        if (_selectionText() case final text?) _useSelection(text);
      case FindMenuAction.next:
        _menuStep(forward: true);
      case FindMenuAction.previous:
        _menuStep(forward: false);
    }
  }

  /// ⌘G / ⇧⌘G: steps, and with an editor field focused selects a new body
  /// match there (Req 21).
  void _menuStep({required bool forward}) {
    final focused = widget.sourceMode
        ? widget.bodyFocus.hasFocus
        : _focusedField() != null;
    _stepping = true;
    final FindMatch? match;
    try {
      match = forward ? _notifier.next() : _notifier.previous();
    } finally {
      _stepping = false;
    }
    if (match == null) return;
    if (focused) _select(match);
    _reveal(match);
  }

  /// ⌘E with [text]: it sets the query and the current match (Req 18). The
  /// open bar's own query again is no query change to [_onState], so a
  /// current match it moves is revealed here (Req 23).
  void _useSelection(String text) {
    final before = ref.read(findInNoteProvider);
    _notifier.useSelection(text);
    final after = ref.read(findInNoteProvider);
    if (!before.open || before.query != after.query) return;
    if (after.current == before.current) return;
    if (after.currentMatch case final match?) _reveal(match);
  }

  /// The non-empty selection of the focused body field (the Source field in
  /// Source mode), or null.
  String? _selectionText() {
    final TextEditingController controller;
    if (widget.sourceMode) {
      if (!widget.bodyFocus.hasFocus) return null;
      controller = widget.sourceController;
    } else {
      final field = _focusedField();
      if (field == null) return null;
      controller = field.controller;
    }
    final selection = controller.selection;
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.end > controller.text.length) {
      return null;
    }
    return selection.textInside(controller.text);
  }

  /// Selects [match] in its field and focuses it: a body match in its text
  /// segment, a Source match in the Source field. A card match changes
  /// nothing. Returns whether it selected.
  bool _select(FindMatch match) {
    switch (match.kind) {
      case FindSourceKind.source when widget.sourceMode:
        _selectIn(widget.sourceController, widget.bodyFocus, match);
        return true;
      case FindSourceKind.body when !widget.sourceMode:
        final field = _fieldAt(match.segment);
        if (field == null) return false;
        _selectIn(field.controller, field.focus, match);
        return true;
      default:
        return false;
    }
  }

  static void _selectIn(
    TextEditingController controller,
    FocusNode focus,
    FindMatch match,
  ) {
    final length = controller.text.length;
    controller.selection = TextSelection(
      baseOffset: match.start.clamp(0, length),
      extentOffset: match.end.clamp(0, length),
    );
    // A text segment's node hands focus to the row holding its caret.
    focus.requestFocus();
  }

  /// The bar closed with [match] current (Req 40).
  void _onClose(FindMatch? match) {
    if (!_active) return;
    if (match != null && _select(match)) return;
    if (widget.sourceMode) {
      widget.bodyFocus.requestFocus();
      return;
    }
    // The caret returns to its last body position.
    (_fieldAt(_lastSegment)?.focus ?? widget.bodyFocus).requestFocus();
  }

  // ----------------------------------------------------------------- reveal

  /// Scrolls [match] into view (Req 23): through the note reveal seam in
  /// live preview (D2), by the Source field's page in Source mode (TD4).
  void _reveal(FindMatch match) {
    if (widget.sourceMode) {
      if (match.kind == FindSourceKind.source) _revealInSource(match);
      return;
    }
    final content = ref.read(editorControllerProvider).contentMd;
    final RevealAt at = match.kind == FindSourceKind.card
        ? RevealAtCard(segment: match.segment, content: content)
        : RevealAtText(
            segment: match.segment,
            start: match.start,
            end: match.end,
            content: content,
          );
    ref
        .read(noteRevealProvider.notifier)
        .request(
          NoteRevealRequest(
            widget.note.id,
            at,
            const RevealWithin(findRevealInset),
          ),
        );
  }

  /// After the next layout, scrolls the Source field's page so the line
  /// holding [match] lies in [top + 60, bottom], by the smallest scroll.
  void _revealInSource(FindMatch match) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !widget.sourceMode) return;
        final context = widget.bodyFocus.context;
        if (context == null || !context.mounted) return;
        final editable = findRenderEditable(context.findRenderObject());
        final scrollable = Scrollable.maybeOf(context);
        if (editable == null ||
            !editable.attached ||
            !editable.hasSize ||
            scrollable == null ||
            match.start > editable.plainText.length) {
          return;
        }
        final viewport = RenderAbstractViewport.maybeOf(editable);
        if (viewport == null) return;
        final line = lineHolding(
          RenderEditableLineBoxes(editable).lines,
          match.start,
        );
        final rect = Rect.fromLTRB(
          0,
          line.top,
          editable.size.width,
          line.bottom,
        );
        final position = scrollable.position;
        final to = revealScrollOffset(
          const RevealWithin(findRevealInset),
          reveal: viewport.getOffsetToReveal(editable, 0, rect: rect).offset,
          pixels: position.pixels,
          viewport: position.viewportDimension,
          height: rect.height,
        );
        if (to != null) {
          position.jumpTo(
            to.clamp(position.minScrollExtent, position.maxScrollExtent),
          );
        }
      })
      ..ensureVisualUpdate();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    if (ref.watch(findInNoteProvider.select((s) => s.open))) {
      // Rebuilt on every change to the searched text, which flushes it.
      final content = ref.watch(
        editorControllerProvider.select((e) => e.contentMd),
      );
      if (!widget.sourceMode) {
        for (final segment in _split(content)) {
          if (segment is TransclusionSegment) {
            ref.watch(
              excerptRenderProvider((
                date: segment.date,
                from: segment.from,
                to: segment.to,
              )),
            );
          }
        }
      }
      _scheduleFlush();
    }
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          FindBarOverlay(
            bodyWidth: box.maxWidth,
            onStep: _reveal,
            onClose: _onClose,
          ),
        ],
      ),
    );
  }
}
