import 'dart:async';

import '../../editor/editor_rows.dart';

/// What the segment's ops (C4) know about an edit the host records: whether
/// it was typed into a row field (the field's text ran ahead of the
/// segment's), whether that field is composing, and the segment selection
/// before the edit.
typedef SegmentEditOrigin = ({
  bool typed,
  bool composing,
  SegmentSelection selection,
});

/// One undo step: the segment text and the selection to restore with it.
typedef _Step = ({String text, SegmentSelection? selection});

/// An open step that the next typed edits complete (a type-over or an IME
/// composition over a selection that spans rows).
enum _Open { none, key, composing }

/// The undo recorder of one text segment (D8, D9, Spec R30): the rows host
/// calls [record] once for every [SegmentEdit] it applies to the segment's
/// text (typing, a replaced text, an autocomplete insert, a checkbox toggle)
/// and [reset] when the segment is rebuilt from outside (another note, a
/// Source edit, a server write).
///
/// Its history holds whole segment texts, so [undo] and [redo] restore exact
/// bytes (D17). An applied edit is one step. Typed edits coalesce as
/// Flutter's `UndoHistory` does: the first starts a [coalesce] timer, and
/// when it fires the latest typed text becomes one step. While the timer
/// runs, [undo] drops the typing that is not a step yet. Text typed while
/// the field composes becomes a step only once it commits.
class SegmentUndoRecorder {
  SegmentUndoRecorder();

  /// Flutter's `UndoHistory` throttle.
  static const coalesce = Duration(milliseconds: 500);

  /// Says how the edit being recorded was made; null treats every edit as
  /// applied (one step each).
  SegmentEditOrigin Function()? origin;

  final List<_Step> _steps = [];
  int _index = -1;
  Timer? _timer;
  _Step? _pending;
  _Open _open = _Open.none;
  bool _replaying = false;

  /// [edit] was applied to the segment text [before].
  void record(SegmentEdit edit, {required String before}) {
    if (_replaying) return;
    final from = origin?.call();
    if (_steps.isEmpty) _push((text: before, selection: from?.selection));
    final after = (text: edit.apply(before), selection: edit.selection);
    if (from == null || !from.typed) {
      _flush();
      _open = _Open.none;
      _push(after);
    } else if (_open != _Open.none) {
      _steps[_index] = after;
      _open = from.composing ? _Open.composing : _Open.none;
    } else if (!from.composing) {
      _pending = after;
      _timer ??= Timer(coalesce, _flush);
    }
  }

  /// The edit just recorded and the typed edit that follows it are one step;
  /// when that typed edit starts a composition, the step takes the
  /// composition up to its commit.
  void continueWithTyping() => _open = _Open.key;

  /// The key that began [continueWithTyping] went up: a later typed edit is
  /// its own step. An open composition stays open.
  void endTyping() {
    if (_open == _Open.key) _open = _Open.none;
  }

  /// Makes pending typing a step now.
  void flush() => _flush();

  /// Forgets every recorded edit.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _steps.clear();
    _index = -1;
    _open = _Open.none;
  }

  /// Cmd+Z from the segment text [current]: the edit back to the last step,
  /// or null when it changes nothing.
  SegmentEdit? undo(String current) {
    if (_steps.isEmpty) return null;
    _open = _Open.none;
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      _pending = null;
    } else if (_index > 0) {
      _index--;
    }
    return _restore(current);
  }

  /// Shift+Cmd+Z from the segment text [current]: the edit forward to the
  /// next step, or null when there is none.
  SegmentEdit? redo(String current) {
    if (_steps.isEmpty) return null;
    _open = _Open.none;
    _flush();
    if (_index < _steps.length - 1) _index++;
    return _restore(current);
  }

  /// Runs [apply], the host applying an [undo] or [redo] edit, without
  /// recording it.
  void replay(void Function() apply) {
    _replaying = true;
    try {
      apply();
    } finally {
      _replaying = false;
    }
  }

  void _flush() {
    final pending = _pending;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    if (pending != null) _push(pending);
  }

  void _push(_Step step) {
    if (_steps.isNotEmpty && _steps[_index].text == step.text) return;
    _steps
      ..removeRange(_index + 1, _steps.length)
      ..add(step);
    _index = _steps.length - 1;
  }

  SegmentEdit? _restore(String current) {
    final step = _steps[_index];
    if (step.text == current) return null;
    final diff = SegmentEdit.diff(current, step.text);
    return SegmentEdit(
      start: diff.start,
      end: diff.end,
      replacement: diff.replacement,
      selection:
          step.selection ??
          SegmentSelection.collapsed(diff.start + diff.replacement.length),
    );
  }
}

/// Makes the recorder of each text segment the rows host builds. Tests
/// replace it to observe the edits a segment applies.
SegmentUndoRecorder Function() segmentUndoRecorderFactory =
    SegmentUndoRecorder.new;
