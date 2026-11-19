// WI #436 (Spec #392): the widgets that run a note editor's
// SpellCheckController (state/spell_check_controller.dart) over its fields
// and hand it to them. Kept out of state/, which imports no widgets (WI #92).
//
// Frozen for E5 (#438): [SpellCheckScope.maybeOf].
//
// WI #439 (Spec #392 req 20, 21): Check Document Now. Each host listens to
// `SpellingService.checkDocumentNowRequests`; only the host of the focused
// note editor acts (see [SpellCheckHost]).
import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/spell_issues.dart';
import '../../state/clock.dart';
import '../../state/learned_words_seam.dart';
import '../../state/settings.dart';
import '../../state/spell_check_controller.dart';
import '../../state/spell_session_state.dart';
import '../../state/spelling_service.dart';
import 'live_preview_controller.dart';
import 'segment_view.dart';
import 'spell_issue_scope.dart';
import 'spelling_menu.dart';

/// Hands a note editor's [SpellCheckController] to the fields below it
/// (E5's SpellingMenu finds it from a field's context).
class SpellCheckScope extends InheritedWidget {
  const SpellCheckScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SpellCheckController controller;

  /// The nearest scope's controller, or null with none above [context].
  /// Registers [context] as a dependent.
  static SpellCheckController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SpellCheckScope>()?.controller;

  @override
  bool updateShouldNotify(SpellCheckScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// A [SpellIssueRegistry] as a [SpellCheckController]'s [SpellIssueSink].
class _RegistrySink implements SpellIssueSink {
  _RegistrySink(this.registry);

  final SpellIssueRegistry registry;

  @override
  List<SpellIssue> issuesOf(TextEditingController field) =>
      registry.issuesFor(field).value;

  @override
  void setIssues(TextEditingController field, List<SpellIssue> issues) =>
      registry.setIssues(field, issues);

  @override
  void forget(TextEditingController field) => registry.forget(field);
}

/// Runs one note editor's [SpellCheckController] over the
/// [SpellCheckField]s below it, publishing into [registry]. It reads the
/// spelling seam, the session, the clock, the flags and the learned keys
/// from Riverpod; without settings (a bare pump) spelling stays off.
///
/// Check Document Now (`SpellingService.checkDocumentNowRequests`, Spec
/// #392 req 20) acts here when this editor is the focused note editor: one
/// of its fields has the primary focus, or a SpellingMenu has it and this
/// editor's field had it last (the menu Check Document Now or a right click
/// opened). It checks the whole note from the caret
/// ([SpellCheckController.checkAll]), then goes to
/// [SpellCheckController.nextIssue]: selects the issue's range (the
/// segment selection too, in a live preview row), focuses its field,
/// scrolls it into view and opens SpellingMenu on it ([showSpellingMenu]).
/// With no issue it changes nothing.
class SpellCheckHost extends ConsumerStatefulWidget {
  const SpellCheckHost({
    super.key,
    required this.noteId,
    required this.registry,
    required this.child,
    this.footerStartOf,
  });

  /// The note the editor shows.
  final String noteId;

  /// The editor's issue registry.
  final SpellIssueRegistry registry;

  /// See [SpellCheckController.footerStartOf].
  final int? Function(String text)? footerStartOf;

  final Widget child;

  @override
  ConsumerState<SpellCheckHost> createState() => _SpellCheckHostState();
}

class _SpellCheckHostState extends ConsumerState<SpellCheckHost> {
  late final SpellCheckController _controller;
  StreamSubscription<void>? _checkNow;

  /// This editor's field that last had the primary focus while focus stayed
  /// in this editor or went to a SpellingMenu; null otherwise.
  _SpellCheckFieldState? _lastFocused;

  /// Bumped by every Check Document Now this host acts on: an older one
  /// still waiting on its checks then stops.
  int _checkNowRun = 0;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
    _controller = SpellCheckController(
      noteId: widget.noteId,
      sink: _RegistrySink(widget.registry),
      session: () => ref.read(spellSessionProvider),
      service: () => ref.read(spellingServiceProvider),
      clock: ref.read(clockProvider),
      learnedKeys: ref.read(learnedWordKeysProvider),
      footerStartOf: (text) => widget.footerStartOf?.call(text),
    );
    ref.listenManual<Set<String>>(
      learnedWordKeysProvider,
      (_, keys) => _controller.learnedKeys = keys,
    );
    ref.listenManual<SpellingService>(spellingServiceProvider, (_, service) {
      unawaited(_checkNow?.cancel());
      _checkNow = service.checkDocumentNowRequests.listen(
        (_) => unawaited(_onCheckDocumentNow()),
      );
    }, fireImmediately: true);
    try {
      _controller.flags = ref.read(spellCheckFlagsProvider);
    } on UnimplementedError {
      // No settings above this editor (a bare pump): spelling stays off.
      return;
    }
    ref.listenManual<SpellFlags>(
      spellCheckFlagsProvider,
      (_, flags) => _controller.flags = flags,
    );
  }

  @override
  void didUpdateWidget(SpellCheckHost old) {
    super.didUpdateWidget(old);
    _controller.noteId = widget.noteId;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    unawaited(_checkNow?.cancel());
    _controller.dispose();
    super.dispose();
  }

  /// The primary focus moved: remembers this editor's field holding it, and
  /// keeps the last one while a SpellingMenu holds it.
  void _onFocus() {
    final field = _fieldWithFocus();
    if (field != null) {
      _lastFocused = identical(field._checker, _controller) ? field : null;
    } else if (!_spellingMenuHasFocus()) {
      _lastFocused = null;
    }
  }

  /// This editor's field Check Document Now starts from: the one holding
  /// the primary focus, or, while a SpellingMenu holds it, the field that
  /// last did. Null when the focus is anywhere else.
  _SpellCheckFieldState? _checkNowOrigin() {
    final focused = _fieldWithFocus();
    if (focused != null) {
      return identical(focused._checker, _controller) ? focused : null;
    }
    final last = _lastFocused;
    if (last == null || !last.mounted || !_spellingMenuHasFocus()) return null;
    return last;
  }

  /// Check Document Now, when this is the focused note editor (see
  /// [SpellCheckHost]). Nothing moves when the focus left that field while
  /// the note was checked.
  Future<void> _onCheckDocumentNow() async {
    final from = _checkNowOrigin();
    if (from == null) return;
    final run = ++_checkNowRun;
    final ctrl = from.widget.controller;
    await _controller.checkAll(from: ctrl);
    if (!mounted || run != _checkNowRun) return;
    if (!identical(_checkNowOrigin(), from)) return;
    final next = _controller.nextIssue(from: ctrl);
    final target = next?.host;
    if (next == null || target is! _SpellCheckFieldState || !target.mounted) {
      return;
    }
    await target._goTo(next.issue, stillCurrent: () => run == _checkNowRun);
  }

  /// The page scrolled, or its content or viewport changed size: other
  /// paragraphs may now be within one screen.
  bool _onNotification(Notification n) {
    final (depth, metrics) = switch (n) {
      ScrollNotification() => (n.depth, n.metrics),
      ScrollMetricsNotification() => (n.depth, n.metrics),
      _ => (-1, null),
    };
    if (depth == 0 && metrics?.axis == Axis.vertical) {
      _controller.viewportChanged();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => SpellCheckScope(
    controller: _controller,
    child: NotificationListener<Notification>(
      onNotification: _onNotification,
      child: widget.child,
    ),
  );
}

/// Joins the field of [controller] to the nearest [SpellCheckHost]'s
/// checks. Inside a live preview row ([SegmentView]) the field's paragraphs
/// come from the row's line, its block marker included (E2 ruling Q1);
/// anywhere else from the field's whole text.
class SpellCheckField extends StatefulWidget {
  const SpellCheckField({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  State<SpellCheckField> createState() => _SpellCheckFieldState();
}

/// Test-only work counter: how many times any spell-check field host
/// answered [SpellFieldHost.line] (a segment row lookup).
@visibleForTesting
int debugSpellHostLineCalls = 0;

/// Test-only work counter: how many times any spell-check field host
/// measured an issue's rect in its field.
@visibleForTesting
int debugSpellHostRectCalls = 0;

/// Test-only work counter: how many times any spell-check field host
/// resolved its field's laid-out text, as main's `editable()` counted: once
/// per [SpellFieldHost.extent] call (the geometry entry point of an
/// evaluation's viewport check, once per field), and per issue-rect or
/// Check Document Now read. [SpellFieldHost.extentAt] reuses the text
/// [SpellFieldHost.extent] resolved while it stays laid out (WI #127), so
/// it counts only when there is none.
@visibleForTesting
int debugSpellHostEditableCalls = 0;

/// A `TextField`'s default scroll padding, which a row without a field
/// pads a Check Document Now range by (WI #128).
const _fieldScrollPadding = EdgeInsets.all(20);

class _SpellCheckFieldState extends State<SpellCheckField>
    implements SpellFieldHost {
  SpellCheckController? _checker;
  ScrollableState? _scrollable;

  /// The live preview segment holding this field, or null (Source mode).
  SegmentViewState? _segment;

  /// [hasFocus] when focus last moved.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  /// The primary focus moved: tells the checker when it entered or left
  /// this field.
  void _onFocus() {
    final focused = _focusInside();
    if (focused == _focused) return;
    _focused = focused;
    _checker?.focusChanged(widget.controller);
  }

  /// Whether the primary focus is this field or below it.
  bool _focusInside() {
    final focus = _primaryFocusContext();
    if (!mounted || focus == null) return false;
    if (identical(focus, context)) return true;
    var inside = false;
    focus.visitAncestorElements((e) {
      if (!identical(e, context)) return true;
      inside = true;
      return false;
    });
    return inside;
  }

  @override
  void activate() {
    super.activate();
    _segment = context.findAncestorStateOfType<SegmentViewState>();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _segment = context.findAncestorStateOfType<SegmentViewState>();
    _scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    final checker = SpellCheckScope.maybeOf(context);
    if (!identical(checker, _checker)) {
      _checker?.removeField(widget.controller, this, forget: false);
      _checker = checker;
      checker?.addField(widget.controller, this);
    }
  }

  @override
  void didUpdateWidget(SpellCheckField old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      _checker?.removeField(old.controller, this, forget: true);
      _checker?.addField(widget.controller, this);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _checker?.removeField(widget.controller, this, forget: true);
    super.dispose();
  }

  @override
  SpellFieldLine line(TextEditingController field) {
    debugSpellHostLineCalls++;
    final segment = _segment;
    if (segment != null && segment.mounted) {
      final row = segment.rowLineOf(field);
      if (row != null) {
        return (
          line: row.line,
          base: row.textStart,
          atSegmentStart: row.atSegmentStart,
        );
      }
    }
    return (line: field.text, base: 0, atSegmentStart: true);
  }

  /// The laid-out text [extent] last resolved ([_text]), which [extentAt]
  /// reuses while it is still laid out in the tree.
  RenderBox? _slot;

  /// The `RichText` span whose plain-text length [_slotLength] holds.
  InlineSpan? _slotSpan;
  int _slotLength = 0;

  /// This field's laid-out text (WI #127): the text slot under it, a
  /// field's or a `RichText`'s standing in for it (`textSlotBox`, the
  /// row-geometry accessor's text-slot half), or null.
  RenderBox? _text() {
    debugSpellHostEditableCalls++;
    if (!mounted) return null;
    final box = textSlotBox(context.findRenderObject());
    return box != null && box.attached ? box : null;
  }

  /// [box]'s global top and the global bottom of its local [rect].
  static ({double top, double bottom}) _globalBand(RenderBox box, Rect rect) =>
      (
        top: box.localToGlobal(Offset(0, rect.top)).dy,
        bottom: box.localToGlobal(Offset(0, rect.bottom)).dy,
      );

  @override
  ({double top, double bottom})? extent() {
    final box = _slot = _text();
    return box == null ? null : _globalBand(box, Offset.zero & box.size);
  }

  @override
  ({double top, double bottom})? extentAt(int offset) {
    if (!mounted) return null;
    final cached = _slot;
    final box = cached != null && cached.attached && cached.hasSize
        ? cached
        : _slot = _text();
    final Rect? caret = switch (box) {
      final RenderEditable field => field.getLocalRectForCaret(
        TextPosition(offset: offset.clamp(0, field.plainText.length)),
      ),
      final RenderParagraph text => _paragraphCaret(text, offset),
      _ => null,
    };
    return box == null || caret == null ? null : _globalBand(box, caret);
  }

  /// [text]'s caret rect at [offset] (clamped to its text), as tall as its
  /// line's caret.
  Rect _paragraphCaret(RenderParagraph text, int offset) {
    final position = TextPosition(offset: offset.clamp(0, _lengthOf(text)));
    final at = text.getOffsetForCaret(position, Rect.zero);
    return Rect.fromLTWH(at.dx, at.dy, 0, text.getFullHeightForCaret(position));
  }

  /// [text]'s plain-text length, counted once per span (no copy of its
  /// text: a row's span can hold a whole long paragraph).
  int _lengthOf(RenderParagraph text) {
    final span = text.text;
    if (!identical(span, _slotSpan)) {
      _slotSpan = span;
      _slotLength = _spanLength(span);
    }
    return _slotLength;
  }

  /// [span]'s plain-text length as its laid-out text holds it: a text
  /// span's text, one code unit per placeholder (a widget span).
  static int _spanLength(InlineSpan span) {
    var length = 0;
    span.visitChildren((s) {
      length += switch (s) {
        TextSpan(:final text) => text?.length ?? 0,
        PlaceholderSpan() => 1,
        _ => 0,
      };
      return true;
    });
    return length;
  }

  @override
  ({double top, double bottom})? viewport() {
    final box = _scrollable?.context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize
        ? _globalBand(box, Offset.zero & box.size)
        : null;
  }

  @override
  bool revealed(TextEditingController field) =>
      field is! LivePreviewController || !field.textHidden;

  @override
  ValueListenable<bool>? revealGate(TextEditingController field) =>
      field is LivePreviewController ? field.revealGate : null;

  @override
  bool hasFocus(TextEditingController field) => _focusInside();

  /// This field's EditableText, or null.
  EditableTextState? _editableText() {
    if (!mounted) return null;
    EditableTextState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement &&
          e.state is EditableTextState &&
          identical(
            (e.state as EditableTextState).widget.controller,
            widget.controller,
          )) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// [issue]'s range in the field's laid-out text ([_text], local), or
  /// null.
  Rect? _rectOf(SpellIssue issue) {
    debugSpellHostRectCalls++;
    final range = TextSelection(
      baseOffset: issue.start,
      extentOffset: issue.start + issue.length,
    );
    final boxes = switch (_text()) {
      final RenderEditable field => field.getBoxesForSelection(range),
      final RenderParagraph text => text.getBoxesForSelection(range),
      _ => const <TextBox>[],
    };
    if (boxes.isEmpty) return null;
    var rect = boxes.first.toRect();
    for (final b in boxes.skip(1)) {
      rect = rect.expandToInclude(b.toRect());
    }
    return rect;
  }

  /// Check Document Now's move to [issue], an issue of this field: selects
  /// its range (and the segment's in a live preview row), focuses the field,
  /// scrolls the range into view and, after the frame, opens SpellingMenu on
  /// it. In a live preview row the row becomes the active row with that
  /// selection (`SegmentViewState.activateRow`, WI #128), which focuses it;
  /// a row without a field ([_goToRow]) mounts its field then. Nothing more
  /// happens once [stillCurrent] is false, the field is gone or its text
  /// changed.
  Future<void> _goTo(
    SpellIssue issue, {
    required bool Function() stillCurrent,
  }) async {
    final segment = _segment;
    final row = segment != null && segment.mounted
        ? segment.rowIndexOf(widget.controller)
        : null;
    final field = _editableText();
    if (field == null) {
      if (segment != null && row != null) {
        await _goToRow(segment, row, issue, stillCurrent: stillCurrent);
      }
      return;
    }
    final ctrl = widget.controller;
    final text = ctrl.text;
    final end = issue.start + issue.length;
    if (issue.start < 0 || end > text.length) return;
    if (segment != null && row != null) {
      final base = segment.rowSpec(row)!.textStart;
      segment.activateRow(
        row,
        TextSelection(baseOffset: base + issue.start, extentOffset: base + end),
      );
    } else {
      ctrl.selection = TextSelection(
        baseOffset: issue.start,
        extentOffset: end,
      );
      field.widget.focusNode.requestFocus();
    }
    // The field's own reveal on focus pads its selection by its scroll
    // padding: padding the same way leaves it nothing to scroll.
    final rect = _rectOf(issue);
    if (rect != null) {
      _text()?.showOnScreen(
        rect: field.widget.scrollPadding.inflateRect(rect),
        duration: Duration.zero,
      );
    }
    await SchedulerBinding.instance.endOfFrame;
    if (!stillCurrent() || !mounted || !field.mounted || ctrl.text != text) {
      return;
    }
    final e = _text();
    final shown = _rectOf(issue);
    if (e == null || shown == null) return;
    await showSpellingMenu(
      field,
      issue: issue,
      anchor: e.localToGlobal(shown.bottomLeft),
    );
  }

  /// [_goTo] on row [row] of [segment], a row without a field (WI #128):
  /// the row becomes the active row with [issue]'s range selected, its text
  /// scrolls the range into view (padded as a field pads it) and, after the
  /// frame, SpellingMenu opens on the range through the segment
  /// (`showRowSpellingMenu`), below the range as the row lays it out then.
  /// The menu hangs off the segment: this host joined the row's `RichText`,
  /// which the row's field replaces once the row is active.
  Future<void> _goToRow(
    SegmentViewState segment,
    int row,
    SpellIssue issue, {
    required bool Function() stillCurrent,
  }) async {
    final ctrl = widget.controller;
    final text = ctrl.text;
    final end = issue.start + issue.length;
    if (issue.start < 0 || end > text.length) return;
    final base = segment.rowSpec(row)!.textStart;
    segment.activateRow(
      row,
      TextSelection(baseOffset: base + issue.start, extentOffset: base + end),
    );
    final rect = _rectOf(issue);
    if (rect != null) {
      _text()?.showOnScreen(
        rect: _fieldScrollPadding.inflateRect(rect),
        duration: Duration.zero,
      );
    }
    await SchedulerBinding.instance.endOfFrame;
    if (!stillCurrent() || !segment.mounted || ctrl.text != text) return;
    final now = segment.rowIndexOf(ctrl);
    final boxes = now == null ? null : segment.rowBoxes(now);
    if (now == null || boxes == null || !boxes.box.attached) return;
    final rects = boxes.boxesFor(TextRange(start: issue.start, end: end));
    if (rects.isEmpty) return;
    final shown = rects
        .skip(1)
        .fold(rects.first, (a, b) => a.expandToInclude(b));
    await showRowSpellingMenu(
      segment,
      now,
      issue: issue,
      anchor: boxes.box.localToGlobal(shown.bottomLeft),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The primary focus's context when an ancestor walk from it is safe, or
/// null.
///
/// Focus can still sit in a field whose row swapped to idle this frame: a
/// click on a later row deactivates the earlier row's field before focus
/// moves on. That element is deactivated but still [BuildContext.mounted],
/// and an ancestor lookup from it throws "Looking up a deactivated
/// widget's ancestor is unsafe" when a [SpellCheckField] registers in the
/// same frame. Such a context counts as no focus. Only debug builds can
/// tell an inactive element; in profile and release the walk is safe and
/// stops at the deactivated subtree's detached root, so it reaches no
/// live field.
BuildContext? _primaryFocusContext() {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null || !focus.mounted) return null;
  var active = true;
  assert(() {
    active = focus is! Element || focus.debugIsActive;
    return true;
  }());
  return active ? focus : null;
}

/// The [SpellCheckField] whose subtree holds the primary focus, or null.
_SpellCheckFieldState? _fieldWithFocus() {
  final focus = _primaryFocusContext();
  if (focus == null) return null;
  _SpellCheckFieldState? found;
  bool visit(Element e) {
    if (e is StatefulElement && e.state is _SpellCheckFieldState) {
      found = e.state as _SpellCheckFieldState;
      return false;
    }
    return true;
  }

  if (focus is Element && visit(focus)) focus.visitAncestorElements(visit);
  return found;
}

/// Whether the primary focus is in a SpellingMenu.
bool _spellingMenuHasFocus() {
  final focus = _primaryFocusContext();
  if (focus == null) return false;
  return focus.widget is SpellingMenu ||
      focus.findAncestorWidgetOfExactType<SpellingMenu>() != null;
}
