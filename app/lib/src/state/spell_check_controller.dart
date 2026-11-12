// WI #436 (Spec #392 req 1, 3, 4, 4b, 8, 12, 15, 24): the spell-check
// scheduler of one note editor. SegmentedBody runs one over its editor row
// fields and SourceSurface one over its single field; each publishes
// field-local issues into that editor's SpellIssueRegistry. The widgets that
// run it (SpellCheckHost, SpellCheckField, SpellCheckScope) are in
// widgets/editor/spell_check_host.dart: state/ imports no widgets (WI #92).
//
// Frozen for E5 (#438) and E6 (#439): [SpellCheckController.ignoreSpelling],
// [SpellCheckController.ignoreGrammar], [SpellCheckController.checkAll] and
// SpellCheckScope.maybeOf.
import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../editor/editor_rows.dart' show SegmentEdit;
import '../editor/segments.dart';
import '../editor/spell_issues.dart';
import '../editor/spell_ranges.dart';
import 'clock.dart';
import 'spell_session_state.dart';
import 'spelling_service.dart';

/// How long a paragraph's text must stay unchanged before it is checked
/// (Spec #392 req 3).
const spellCheckDebounce = Duration(milliseconds: 400);

/// The effective spelling flags: spelling, and grammar (only with spelling).
typedef SpellFlags = ({bool spelling, bool grammar});

const SpellFlags _off = (spelling: false, grammar: false);

/// One field's text as the paragraph splitter sees it: [line] is the row's
/// text from the row's start (an item row's block marker included), [base]
/// is where the field's own text starts in [line], and [atSegmentStart]
/// whether [line] starts its text segment.
typedef SpellFieldLine = ({String line, int base, bool atSegmentStart});

/// Where a [SpellCheckController] publishes each field's issues
/// (field-local offsets): the note editor's SpellIssueRegistry, as
/// SpellCheckHost adapts it.
abstract interface class SpellIssueSink {
  /// The issues last set for [field].
  List<SpellIssue> issuesOf(TextEditingController field);

  void setIssues(TextEditingController field, List<SpellIssue> issues);

  /// [field] is gone: drop its entry.
  void forget(TextEditingController field);
}

/// What a [SpellCheckController] reads about a field from the widget that
/// joined it (SpellCheckField).
abstract interface class SpellFieldHost {
  /// [field]'s line (see [SpellFieldLine]).
  SpellFieldLine line(TextEditingController field);

  /// The field's laid-out text, or null.
  RenderEditable? editable();

  /// The editor page's laid-out viewport, or null.
  RenderBox? viewportBox();

  /// False only for a table row that shows its grid (Spec #392 req 2).
  bool revealed(TextEditingController field);

  /// The listenable that flips [revealed] for [field], or null.
  ValueListenable<bool>? revealGate(TextEditingController field);

  /// Whether [field] has the keyboard focus. Its selection counts as the
  /// caret only while it does: a field keeps its selection after focus
  /// leaves it. The host calls [SpellCheckController.focusChanged] when
  /// this flips.
  bool hasFocus(TextEditingController field);
}

/// Schedules, filters and publishes the spelling and grammar issues of one
/// note editor's fields.
///
/// Fields join through SpellCheckField ([addField]). A field's text is split with
/// `spellParagraphs`; each paragraph is checked whole:
/// - [spellCheckDebounce] after the field's text last changed, and
/// - when it is within one screen above or below the viewport,
/// - never further away (only [checkAll] reaches those).
///
/// Results are cached for the session by note, paragraph text and the
/// grammar flag ([SpellSession]), so an unchanged paragraph is never sent
/// twice. A reply is used only when it answers the newest request for its
/// text and that text is still a paragraph of the editor. Published issues
/// are field-local and filtered by the skip ranges, the learned words, the
/// session's ignore sets, the composing range, the caret and the flags.
class SpellCheckController {
  SpellCheckController({
    required String noteId,
    required SpellIssueSink sink,
    required SpellSession Function() session,
    required SpellingService Function() service,
    AppClock clock = const SystemClock(),
    SpellFlags flags = _off,
    Set<String> learnedKeys = const {},
    this.footerStartOf,
  }) : _noteId = noteId,
       _sink = sink,
       _sessionOf = session,
       _serviceOf = service,
       _clock = clock,
       _flags = flags,
       _learned = learnedKeys;

  final SpellIssueSink _sink;
  final SpellSession Function() _sessionOf;
  final SpellingService Function() _serviceOf;
  final AppClock _clock;

  /// Where the Note footer of a field's text starts (Source mode), or null.
  final int? Function(String text)? footerStartOf;

  SpellSession get _session => _sessionOf();
  SpellingService get _service => _serviceOf();

  String _noteId;
  SpellFlags _flags;
  Set<String> _learned;

  final _fields = <TextEditingController, _Field>{};

  /// The request id sent for each (note, text, grammar) still waiting.
  final _inflight = <(String, String, bool), int>{};
  final _pending = <(String, String, bool), Future<void>>{};

  Timer? _debounce;
  bool _evaluateScheduled = false;
  final _deferred = <_Field>{};
  bool _flushScheduled = false;
  String? _awaitingTagFor;
  bool _disposed = false;

  /// The note whose fields this checks (its document tag and ignore sets).
  /// Setting another note drops every issue and request of the old one.
  String get noteId => _noteId;
  set noteId(String value) {
    if (value == _noteId) return;
    _noteId = value;
    _debounce?.cancel();
    _debounce = null;
    _inflight.clear();
    _pending.clear();
    for (final f in _fields.values) {
      f
        ..dirty = false
        ..base = const []
        ..shown = const [];
      _rebase(f);
    }
    _publishAll();
    _scheduleEvaluate();
  }

  /// The effective spelling flags (`spellCheckFlagsProvider`).
  SpellFlags get flags => _flags;
  set flags(SpellFlags value) {
    final old = _flags;
    if (value == old) return;
    _flags = value;
    if (!value.spelling) {
      _debounce?.cancel();
      _debounce = null;
      _inflight.clear();
      _pending.clear();
    } else {
      for (final f in _fields.values) {
        f.dirty = false;
        _rebase(f);
      }
      _scheduleEvaluate();
    }
    _publishAll();
  }

  /// The learned word keys (`learnedWordKeysProvider`). A change re-filters
  /// every field at once, with no check.
  set learnedKeys(Set<String> value) {
    if (identical(value, _learned)) return;
    _learned = value;
    _publishAll();
  }

  bool get _canCheck => !_disposed && _flags.spelling && _service.available;

  /// Ignore Spelling on [issue], a published issue of [field] (field-local
  /// offsets): calls `SpellingService.ignore` with the flagged word and the
  /// note's document tag, adds the word to the note's session ignore set
  /// (so cached results stay filtered) and removes the issue at once.
  Future<void> ignoreSpelling(
    SpellIssue issue,
    TextEditingController field,
  ) async {
    final word = _flagged(field.text, issue);
    if (word == null || _disposed) return;
    final note = _noteId;
    _session.ignoreSpelling(note, word);
    _publishAll();
    final service = _service;
    if (!service.available) return;
    final tag = await _session.documentTag(note);
    if (tag != null) await service.ignore(word, tag);
  }

  /// Ignore Grammar on [issue], a published grammar issue of [field]: adds
  /// (note id, flagged text, description) to the session set, removes the
  /// issue at once and suppresses matching grammar results in this note.
  void ignoreGrammar(SpellIssue issue, TextEditingController field) {
    final text = _flagged(field.text, issue);
    if (text == null || _disposed) return;
    _session.ignoreGrammar(_noteId, text, issue.description);
    _publishAll();
  }

  /// Checks every paragraph of every field not yet checked, whatever its
  /// distance from the viewport (Check Document Now, E6). Completes once
  /// their results are published.
  ///
  /// The checks are sent in document order (the fields as laid out, top to
  /// bottom). With [from], a field of this editor, they start at the
  /// paragraph holding the start of [from]'s selection, run to the note's
  /// end, then wrap to the top (Spec #392 req 3, 20).
  Future<void> checkAll({TextEditingController? from}) async {
    if (!_canCheck) return;
    final note = _noteId;
    if (_session.knownTag(note) == null) {
      final tag = await _session.documentTag(note);
      if (tag == null || note != _noteId || !_canCheck) return;
    }
    await Future.wait(_evaluate(all: true, from: from));
  }

  /// The issue Check Document Now goes to next (Spec #392 req 20), with its
  /// field and that field's host; null when no field has one.
  ///
  /// It looks at the issues as shown, except that a new spelling issue at
  /// the caret and a grammar issue in the caret's sentence count although
  /// their squiggles still wait (req 4): Check Document Now is an explicit
  /// request, so a word just typed is reachable.
  ///
  /// Fields are taken in document order. Within a field, issues go by start
  /// offset, a spelling issue before a grammar issue at the same start
  /// (then the shorter first). With [from], a field of this editor: when
  /// its selection is an issue's range (the issue this method last
  /// returned, else the last issue in that order with that range), the next
  /// issue of [from] after it in that order, so an issue starting inside
  /// the selected one is reached too; otherwise the first issue of [from]
  /// starting at or after the end of its selection. Else the first issue of
  /// a later field, else, wrapping, the first issue from the top. Without
  /// [from], the first issue from the top.
  ({TextEditingController field, SpellFieldHost host, SpellIssue issue})?
  nextIssue({TextEditingController? from}) {
    if (_disposed) return null;
    final next = _nextIssue(from);
    _wentTo = next == null ? null : (field: next.field, issue: next.issue);
    return next;
  }

  /// The issue [nextIssue] last returned, with its field.
  ({TextEditingController field, SpellIssue issue})? _wentTo;

  ({TextEditingController field, SpellFieldHost host, SpellIssue issue})?
  _nextIssue(TextEditingController? from) {
    final order = _inDocumentOrder();
    final at = from == null
        ? -1
        : order.indexWhere((f) => identical(f.ctrl, from));
    if (at >= 0) {
      final caret = order[at];
      final issues = _issuesInOrder(caret);
      final selection = caret.ctrl.selection;
      final on = selection.isValid ? _selectedIn(caret, issues) : -1;
      final after = selection.isValid ? selection.end : 0;
      for (final (k, i) in issues.indexed) {
        if (on >= 0 ? k > on : i.start >= after) {
          return (field: caret.ctrl, host: caret.host, issue: i);
        }
      }
    }
    final rest = at >= 0
        ? [...order.skip(at + 1), ...order.take(at), order[at]]
        : order;
    for (final f in rest) {
      final issues = _issuesInOrder(f);
      if (issues.isNotEmpty) {
        return (field: f.ctrl, host: f.host, issue: issues.first);
      }
    }
    return null;
  }

  /// The index in [issues] (of [f], in [_issuesInOrder]) of the issue whose
  /// range [f]'s selection is: the one [nextIssue] last returned, else the
  /// last with that range; -1 when the selection is no issue's range.
  int _selectedIn(_Field f, List<SpellIssue> issues) {
    final selection = f.ctrl.selection;
    if (selection.isCollapsed) return -1;
    bool isSelected(SpellIssue i) =>
        i.start == selection.start && i.start + i.length == selection.end;
    final went = _wentTo;
    if (went != null &&
        identical(went.field, f.ctrl) &&
        isSelected(went.issue)) {
      final k = issues.indexOf(went.issue);
      if (k >= 0) return k;
    }
    return issues.lastIndexWhere(isSelected);
  }

  /// [f]'s issues for [nextIssue] (shown, waiting ones included) by start
  /// offset, spelling first at a tie, then the shorter first.
  List<SpellIssue> _issuesInOrder(_Field f) =>
      [..._visible(f, holds: false)]..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        if (byStart != 0) return byStart;
        final byKind = a.kind.index.compareTo(b.kind.index);
        return byKind != 0 ? byKind : a.length.compareTo(b.length);
      });

  /// The fields in document order: by the laid-out top of their text, then
  /// its left; a field not laid out goes after those, in joining order.
  List<_Field> _inDocumentOrder() {
    final keyed = [
      for (final (i, f) in _fields.values.indexed)
        (field: f, origin: f.host.editable()?.localToGlobal(Offset.zero), i: i),
    ];
    keyed.sort((a, b) {
      final ao = a.origin;
      final bo = b.origin;
      if (ao == null || bo == null) {
        if (ao != null) return -1;
        if (bo != null) return 1;
        return a.i.compareTo(b.i);
      }
      final byTop = ao.dy.compareTo(bo.dy);
      if (byTop != 0) return byTop;
      final byLeft = ao.dx.compareTo(bo.dx);
      return byLeft != 0 ? byLeft : a.i.compareTo(b.i);
    });
    return [for (final k in keyed) k.field];
  }

  /// Every field's paragraphs as Check Document Now checks them (see
  /// [checkAll]): in document order, from the paragraph holding the start
  /// of [from]'s selection to the end, then from the top.
  List<(_Field, List<SpellParagraph>)> _wholeNoteFrom(
    TextEditingController? from,
  ) {
    final order = _inDocumentOrder();
    final at = from == null
        ? -1
        : order.indexWhere((f) => identical(f.ctrl, from));
    if (at < 0) return [for (final f in order) (f, _layoutOf(f).paragraphs)];
    final caret = order[at];
    final layout = _layoutOf(caret);
    final selection = caret.ctrl.selection;
    final offset = selection.isValid ? selection.start : 0;
    // The first paragraph ending at or after the caret.
    var split = layout.paragraphs.indexWhere(
      (p) => p.end - layout.base >= offset,
    );
    if (split < 0) split = layout.paragraphs.length;
    return [
      (caret, layout.paragraphs.sublist(split)),
      for (final f in order.skip(at + 1)) (f, _layoutOf(f).paragraphs),
      for (final f in order.take(at)) (f, _layoutOf(f).paragraphs),
      (caret, layout.paragraphs.sublist(0, split)),
    ];
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    for (final f in _fields.values) {
      f.detach();
    }
    _fields.clear();
    _inflight.clear();
    _pending.clear();
    _deferred.clear();
  }

  // --------------------------------------------------------------- fields

  /// Checks [ctrl], whose widget is [host], from now on (replacing any
  /// earlier host of [ctrl]).
  void addField(TextEditingController ctrl, SpellFieldHost host) {
    if (_disposed) return;
    _fields.remove(ctrl)?.detach();
    final f = _Field(ctrl, host, () => _onField(ctrl))
      ..dirty = _debounce?.isActive ?? false;
    _fields[ctrl] = f;
    f.attach();
    _rebase(f);
    _publish(f);
    _scheduleEvaluate();
  }

  /// Stops checking [ctrl] when [host] is still its host. With [forget],
  /// the sink forgets [ctrl] after this frame unless it joined again.
  void removeField(
    TextEditingController ctrl,
    SpellFieldHost host, {
    required bool forget,
  }) {
    final f = _fields[ctrl];
    if (f == null || !identical(f.host, host)) return;
    f.detach();
    _fields.remove(ctrl);
    _deferred.remove(f);
    if (!forget) return;
    // After this frame: the field's listeners go with this frame's tree.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_fields.containsKey(ctrl)) _sink.forget(ctrl);
    });
  }

  /// [ctrl]'s focus flipped ([SpellFieldHost.hasFocus]): re-publishes its
  /// issues, so a word held under the caret shows once focus leaves it.
  void focusChanged(TextEditingController ctrl) {
    final f = _fields[ctrl];
    if (f == null || _disposed) return;
    _publish(f);
  }

  void _onField(TextEditingController ctrl) {
    final f = _fields[ctrl];
    if (f == null || _disposed) return;
    final value = ctrl.value;
    var changed = false;
    if (value.text != f.text) {
      final edit = _editOf(f.text, value.text, value.selection);
      final inserted = value.text.substring(
        edit.start,
        edit.start + edit.inserted,
      );
      f
        ..base = shiftSpellIssues(
          f.base,
          start: edit.start,
          end: edit.end,
          insertedLength: edit.inserted,
          insertedText: inserted,
        )
        ..shown = shiftSpellIssues(
          f.shown,
          start: edit.start,
          end: edit.end,
          insertedLength: edit.inserted,
          insertedText: inserted,
        )
        ..text = value.text;
      changed = true;
    }
    final composingEnded =
        _composes(f.composing) && !_composes(value.composing);
    f.composing = value.composing;
    if (changed || composingEnded) {
      f.dirty = true;
      _touch();
    }
    f.watchGate();
    final revealed = f.revealed;
    if (revealed != f.wasRevealed) {
      f.wasRevealed = revealed;
      if (revealed) _scheduleEvaluate();
    }
    _publish(f);
  }

  /// Restarts the debounce: [spellCheckDebounce] after the last change.
  void _touch() {
    _debounce?.cancel();
    _debounce = null;
    if (!_flags.spelling || _disposed) return;
    _debounce = _clock.after(spellCheckDebounce, _onDebounce);
  }

  void _onDebounce() {
    _debounce = null;
    if (_disposed) return;
    for (final f in _fields.values) {
      if (!f.dirty) continue;
      f.dirty = false;
      _rebase(f);
    }
    _publishAll();
    _scheduleEvaluate();
  }

  // ------------------------------------------------------------- checking

  /// Evaluates after the next frame is laid out (its geometry is current).
  void _scheduleEvaluate() {
    if (_evaluateScheduled || _disposed || !_flags.spelling) return;
    _evaluateScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _evaluateScheduled = false;
      if (!_disposed) _evaluate();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// The editor's page scrolled, or its content or viewport changed size:
  /// other paragraphs may now be within one screen.
  void viewportChanged() => _scheduleEvaluate();

  /// Sends a check for every paragraph that needs one: not cached, not
  /// waiting, not composing, of a field not changed within the debounce, on
  /// a revealed table row and (unless [all]) within one screen of the
  /// viewport. Answers the futures of those checks (and of the ones already
  /// waiting, with [all]). With [all] they go in [checkAll]'s order, from
  /// [from]'s caret.
  List<Future<void>> _evaluate({
    bool all = false,
    TextEditingController? from,
  }) {
    if (!_canCheck) return const [];
    final note = _noteId;
    final tag = _session.knownTag(note);
    if (tag == null) {
      _askTag(note);
      return const [];
    }
    _prune();
    final window = all ? null : _window();
    final futures = <Future<void>>[];
    final List<(_Field, List<SpellParagraph>?)> runs = all
        ? _wholeNoteFrom(from)
        : [for (final f in _fields.values.toList()) (f, null)];
    for (final (f, only) in runs) {
      if (!all && f.dirty) continue;
      if (!f.revealed) continue;
      final layout = _layoutOf(f);
      if (layout.paragraphs.isEmpty) continue;
      final candidates =
          only ??
          (window == null ? layout.paragraphs : _near(f, layout, window));
      for (final p in candidates) {
        final footer = layout.footerStart;
        if (footer != null && p.start >= footer) continue;
        final start = p.start - layout.base;
        final end = p.end - layout.base;
        if (_composes(f.composing) &&
            f.composing.start <= end &&
            start <= f.composing.end) {
          continue;
        }
        if (_lookup(p.text) != null) continue;
        final key = (note, p.text, _flags.grammar);
        final waiting = _pending[key];
        if (waiting != null) {
          if (all) futures.add(waiting);
          continue;
        }
        futures.add(_send(key, tag));
      }
    }
    return futures;
  }

  void _askTag(String note) {
    if (_awaitingTagFor == note) return;
    _awaitingTagFor = note;
    _session.documentTag(note).then((tag) {
      if (_awaitingTagFor == note) _awaitingTagFor = null;
      if (tag != null && note == _noteId) _scheduleEvaluate();
    });
  }

  Future<void> _send((String, String, bool) key, int tag) {
    final id = _session.nextRequestId();
    _inflight[key] = id;
    final Future<void> done = _service
        .check(
          requestId: id,
          text: key.$2,
          documentTag: tag,
          spelling: true,
          grammar: key.$3,
        )
        .then<void>(
          (reply) => _onReply(key, id, reply),
          onError: (Object _) => _onReply(key, id, null),
        );
    _pending[key] = done;
    return done;
  }

  void _onReply((String, String, bool) key, int id, SpellCheckReply? reply) {
    if (_disposed || _inflight[key] != id) return;
    _inflight.remove(key);
    _pending.remove(key);
    if (reply == null || reply.requestId != id) return;
    final text = key.$2;
    final holding = [
      for (final f in _fields.values)
        if (_layoutOf(f).paragraphs.any((p) => p.text == text)) f,
    ];
    // The text changed since the request: no paragraph holds it any more.
    if (holding.isEmpty) return;
    _session.cacheResult(key.$1, text, grammar: key.$3, issues: reply.issues);
    for (final f in holding) {
      _rebase(f);
      _publish(f);
    }
  }

  /// Drops the waiting requests whose text is no longer a paragraph of any
  /// field: a newer request supersedes them when the text comes back.
  void _prune() {
    if (_inflight.isEmpty) return;
    final texts = {
      for (final f in _fields.values)
        for (final p in _layoutOf(f).paragraphs) p.text,
    };
    _inflight.removeWhere((key, _) {
      final stale = key.$1 != _noteId || !texts.contains(key.$2);
      if (stale) _pending.remove(key);
      return stale;
    });
  }

  /// The cached result for paragraph [text] under the current flags. With
  /// grammar off, a result checked with grammar serves too (its grammar
  /// issues are filtered out when published).
  List<SpellIssue>? _lookup(String text) {
    final session = _session;
    final grammar = _flags.grammar;
    return session.cachedResult(_noteId, text, grammar: grammar) ??
        (grammar ? null : session.cachedResult(_noteId, text, grammar: true));
  }

  // -------------------------------------------------------------- geometry

  /// The vertical band, in global coordinates, from one screen above the
  /// viewport to one screen below it; null without a laid-out viewport.
  ({double top, double bottom})? _window() {
    for (final f in _fields.values) {
      final box = f.host.viewportBox();
      if (box == null) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final h = box.size.height;
      return (top: top - h, bottom: top + 2 * h);
    }
    return null;
  }

  /// [layout]'s paragraphs of [f] whose lines lie within [window].
  List<SpellParagraph> _near(
    _Field f,
    _Layout layout,
    ({double top, double bottom}) window,
  ) {
    final editable = f.host.editable();
    if (editable == null) return const [];
    final origin = editable.localToGlobal(Offset.zero).dy;
    if (origin + editable.size.height <= window.top ||
        origin >= window.bottom) {
      return const [];
    }
    final length = f.text.length;
    double top(SpellParagraph p) =>
        origin +
        editable
            .getLocalRectForCaret(
              TextPosition(offset: (p.start - layout.base).clamp(0, length)),
            )
            .top;
    double bottom(SpellParagraph p) =>
        origin +
        editable
            .getLocalRectForCaret(
              TextPosition(offset: (p.end - layout.base).clamp(0, length)),
            )
            .bottom;
    final ps = layout.paragraphs;
    // The first paragraph ending below the window's top.
    var lo = 0;
    var hi = ps.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (bottom(ps[mid]) > window.top) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final out = <SpellParagraph>[];
    for (var i = lo; i < ps.length; i++) {
      if (top(ps[i]) >= window.bottom) break;
      out.add(ps[i]);
    }
    return out;
  }

  // ------------------------------------------------------------ publishing

  _Layout _layoutOf(_Field f) {
    final given = f.host.line(f.ctrl);
    var line = given.line;
    var base = given.base;
    final text = f.ctrl.text;
    if (base < 0 || line.length - base != text.length || !line.endsWith(text)) {
      line = text;
      base = 0;
    }
    final cached = f.layout;
    if (cached != null &&
        cached.line == line &&
        cached.base == base &&
        cached.atSegmentStart == given.atSegmentStart) {
      return cached;
    }
    return f.layout = _Layout(
      line: line,
      base: base,
      atSegmentStart: given.atSegmentStart,
      footerStart: footerStartOf?.call(line),
    );
  }

  /// Recomputes [f]'s issues before the publish filters: a paragraph with a
  /// cached result takes it (skip ranges applied, field-local offsets); any
  /// other keeps its shifted issues until its check answers.
  void _rebase(_Field f) {
    if (!_flags.spelling) return;
    final layout = _layoutOf(f);
    final out = <SpellIssue>[];
    for (final p in layout.paragraphs) {
      final start = p.start - layout.base;
      final end = p.end - layout.base;
      final cached = _lookup(p.text);
      if (cached == null) {
        for (final i in f.base) {
          if (i.start >= start && i.start + i.length <= end) out.add(i);
        }
        continue;
      }
      for (final i in cached) {
        if (i.start < 0 || i.length < 0 || i.start + i.length > p.text.length) {
          continue;
        }
        final s = p.start + i.start;
        final e = s + i.length;
        final drop = i.kind == SpellIssueKind.spelling
            ? dropsSpelling(s, e, layout.skips)
            : dropsGrammar(s, e, layout.skips);
        if (drop || s < layout.base) continue;
        out.add(
          SpellIssue(
            kind: i.kind,
            start: s - layout.base,
            length: i.length,
            description: i.description,
            corrections: i.corrections,
          ),
        );
      }
    }
    f.base = out;
  }

  void _publishAll() {
    for (final f in _fields.values) {
      _publish(f);
    }
  }

  /// Publishes [f]'s issues after the filters. During a build or layout the
  /// registry is written after the frame.
  void _publish(_Field f) {
    f.shown = _visible(f);
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      _deferred.add(f);
      if (!_flushScheduled) {
        _flushScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _flushScheduled = false;
          final due = _deferred.toList();
          _deferred.clear();
          for (final d in due) {
            if (identical(_fields[d.ctrl], d)) _write(d);
          }
        });
      }
      return;
    }
    _deferred.remove(f);
    _write(f);
  }

  void _write(_Field f) {
    final now = _sink.issuesOf(f.ctrl);
    if (!_sameIssues(now, f.shown)) _sink.setIssues(f.ctrl, f.shown);
  }

  /// [f]'s issues as shown: none with spelling off or on an unrevealed
  /// table row; no grammar with grammar off; none for a learned or ignored
  /// word, an ignored grammar result, or in the composing range; a new
  /// spelling issue at the caret and a grammar issue in the caret's
  /// sentence wait (see [SpellCheckController]), while the field has focus.
  /// Without [holds], those waiting issues are kept too.
  List<SpellIssue> _visible(_Field f, {bool holds = true}) {
    if (!_flags.spelling || !f.revealed || f.base.isEmpty) return const [];
    final text = f.text;
    final selection = f.ctrl.selection;
    final caret =
        holds &&
            selection.isValid &&
            selection.isCollapsed &&
            f.host.hasFocus(f.ctrl)
        ? selection.baseOffset
        : null;
    final sentence = caret != null && f.dirty
        ? _sentenceAround(text, caret)
        : null;
    final composing = _composes(f.composing) ? f.composing : null;
    final session = _session;
    final out = <SpellIssue>[];
    for (final i in f.base) {
      final end = i.start + i.length;
      if (i.start < 0 || end > text.length) continue;
      final flagged = text.substring(i.start, end);
      if (composing != null &&
          i.start < composing.end &&
          composing.start < end) {
        continue;
      }
      switch (i.kind) {
        case SpellIssueKind.spelling:
          if (_learned.contains(flagged.toLowerCase()) ||
              session.isSpellingIgnored(_noteId, flagged)) {
            continue;
          }
          if (caret != null &&
              i.start <= caret &&
              caret <= end &&
              !f.shown.any((s) => _sameSpan(s, i))) {
            continue;
          }
        case SpellIssueKind.grammar:
          if (!_flags.grammar ||
              session.isGrammarIgnored(_noteId, flagged, i.description)) {
            continue;
          }
          if (sentence != null &&
              i.start < sentence.end &&
              sentence.start < end) {
            continue;
          }
      }
      out.add(i);
    }
    return out;
  }
}

// ---------------------------------------------------------------- helpers

/// The flagged text of [issue] in [text], or null when it is out of range.
String? _flagged(String text, SpellIssue issue) {
  final end = issue.start + issue.length;
  if (issue.start < 0 || issue.length <= 0 || end > text.length) return null;
  return text.substring(issue.start, end);
}

bool _composes(TextRange r) => r.isValid && !r.isCollapsed;

bool _sameSpan(SpellIssue a, SpellIssue b) =>
    a.kind == b.kind && a.start == b.start && a.length == b.length;

bool _sameIssues(List<SpellIssue> a, List<SpellIssue> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09 || unit == 0x0A;

bool _endsSentence(int unit) => unit == 0x2E || unit == 0x21 || unit == 0x3F;

/// The sentence of [text] holding [caret]: from just after the previous
/// `.`, `!` or `?` followed by a space (or a line start) to just after the
/// next one (or the line end).
({int start, int end}) _sentenceAround(String text, int caret) {
  final at = min(max(caret, 0), text.length);
  var start = 0;
  for (var i = at - 1; i >= 0; i--) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0A) {
      start = i + 1;
      break;
    }
    if (_endsSentence(unit) && i + 1 < at && _isSpace(text.codeUnitAt(i + 1))) {
      start = i + 1;
      break;
    }
  }
  var end = text.length;
  for (var i = at; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0A) {
      end = i;
      break;
    }
    if (_endsSentence(unit) &&
        (i + 1 == text.length || _isSpace(text.codeUnitAt(i + 1)))) {
      end = i + 1;
      break;
    }
  }
  return (start: start, end: end);
}

/// The edit that turned [before] into [after]: `[start, end)` of [before]
/// replaced by [inserted] code units. When the text only grew or shrank, the
/// edit is placed at the caret ([selection]) if it fits there, so typing a
/// letter next to the same letter lands where it was typed.
({int start, int end, int inserted}) _editOf(
  String before,
  String after,
  TextSelection selection,
) {
  if (selection.isValid && selection.isCollapsed) {
    final caret = selection.baseOffset;
    final grown = after.length - before.length;
    if (grown > 0) {
      final start = caret - grown;
      if (start >= 0 &&
          caret <= after.length &&
          after.startsWith(before.substring(0, start)) &&
          after.substring(caret) == before.substring(start)) {
        return (start: start, end: start, inserted: grown);
      }
    } else if (grown < 0) {
      final end = caret - grown;
      if (caret >= 0 &&
          end <= before.length &&
          before.startsWith(after.substring(0, caret)) &&
          before.substring(end) == after.substring(caret)) {
        return (start: caret, end: end, inserted: 0);
      }
    }
  }
  final diff = SegmentEdit.diff(before, after);
  return (start: diff.start, end: diff.end, inserted: diff.replacement.length);
}

/// Where the Note footer starts in a Source mode body [text] of a note with
/// [role] (its marker line), or null without one. A guide note has none; a
/// daily note splits as `splitDailyBody`, any other as `splitNoteBody`.
int? spellFooterStart(String text, {String? role}) {
  if (role == 'guide' || !text.contains(topicsMarker)) return null;
  final person =
      (role == 'daily' ? splitDailyBody(text) : splitNoteBody(text)).person;
  if (person == text) return null;
  // The person section keeps the text before the footer's marker line, and
  // never that line: the last marker line start it keeps the text before.
  int? at;
  for (
    var i = text.indexOf(topicsMarker);
    i >= 0;
    i = text.indexOf(topicsMarker, i + 1)
  ) {
    if (i > 0 && text.codeUnitAt(i - 1) != 0x0A) continue;
    if (!person.startsWith(text.substring(0, i))) break;
    at = i;
  }
  return at;
}

/// One field's paragraphs and skip ranges, for one [line].
class _Layout {
  _Layout({
    required this.line,
    required this.base,
    required this.atSegmentStart,
    required this.footerStart,
  }) : paragraphs = spellParagraphs(line, atSegmentStart: atSegmentStart);

  final String line;
  final int base;
  final bool atSegmentStart;
  final int? footerStart;
  final List<SpellParagraph> paragraphs;

  late final List<SpellSkipRange> skips = spellSkipRanges(
    line,
    atSegmentStart: atSegmentStart,
    footerStart: footerStart,
  );
}

/// One field a [SpellCheckController] checks.
class _Field {
  _Field(this.ctrl, this.host, this._onChange)
    : text = ctrl.text,
      composing = ctrl.value.composing,
      wasRevealed = host.revealed(ctrl);

  final TextEditingController ctrl;
  final SpellFieldHost host;
  final VoidCallback _onChange;

  /// The text the issues below are for.
  String text;
  TextRange composing;

  /// Changed since the debounce last fired.
  bool dirty = false;

  /// The issues before the publish filters, field-local.
  List<SpellIssue> base = const [];

  /// The issues last published.
  List<SpellIssue> shown = const [];

  _Layout? layout;

  /// [revealed] when last read (at attach, then on each field change).
  bool wasRevealed;
  ValueListenable<bool>? _gate;

  /// See [SpellFieldHost.revealed].
  bool get revealed => host.revealed(ctrl);

  void attach() {
    ctrl.addListener(_onChange);
    watchGate();
  }

  /// Follows the row's reveal gate, which also decides [revealed].
  void watchGate() {
    final gate = host.revealGate(ctrl);
    if (identical(gate, _gate)) return;
    _gate?.removeListener(_onChange);
    _gate = gate?..addListener(_onChange);
  }

  void detach() {
    ctrl.removeListener(_onChange);
    _gate?.removeListener(_onChange);
    _gate = null;
  }
}

/// Spec #392 req 8: [issues] (offsets into one text) after an edit replaced
/// `[start, end)` of that text with [insertedLength] code units. An issue
/// wholly before the edit is kept as it is; one wholly after it moves by the
/// edit's length change (`insertedLength - (end - start)`); one the edit
/// overlaps or falls inside is dropped. Kind, description and corrections
/// are kept. Order is kept.
///
/// An edit that only touches an issue's edge (lead ruling Q2, #436): when
/// [insertedText] (the `insertedLength` code units put in) extends the
/// flagged word there, because its character next to the range is a letter,
/// a digit, an apostrophe or a combining mark, the word was edited and the
/// issue is dropped. Otherwise an edit ending at the issue's start moves it
/// and one starting at its end keeps it. A null [insertedText] counts as not
/// extending the word.
List<SpellIssue> shiftSpellIssues(
  List<SpellIssue> issues, {
  required int start,
  required int end,
  required int insertedLength,
  String? insertedText,
}) {
  final delta = insertedLength - (end - start);
  final text = insertedText ?? '';
  final extendsAtStart = text.isNotEmpty && _extendsWord(text.runes.last);
  final extendsAtEnd = text.isNotEmpty && _extendsWord(text.runes.first);
  final out = <SpellIssue>[];
  for (final i in issues) {
    final issueEnd = i.start + i.length;
    if (issueEnd <= start) {
      if (issueEnd == start && extendsAtEnd) continue;
      out.add(i);
    } else if (i.start >= end) {
      if (i.start == end && extendsAtStart) continue;
      out.add(
        SpellIssue(
          kind: i.kind,
          start: i.start + delta,
          length: i.length,
          description: i.description,
          corrections: i.corrections,
        ),
      );
    }
  }
  return out;
}

/// A letter, digit, apostrophe (ASCII or typographic) or combining mark:
/// a character that, put next to a word, makes it a different word.
final _wordChar = RegExp(r"^[\p{L}\p{N}\p{M}'’]$", unicode: true);

bool _extendsWord(int rune) => _wordChar.hasMatch(String.fromCharCode(rune));
