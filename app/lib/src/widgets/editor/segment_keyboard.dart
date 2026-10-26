import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_edits.dart';
import '../../editor/segment_selection.dart';
import 'editor_row.dart';
import 'line_boxes.dart';
import 'segment_view.dart';

/// Keyboard handling of one text segment's editor rows (D8, TD6, Spec
/// R15-R20, R22, R23, R26, R27): the keys that edit and move across rows.
///
/// - Enter and Shift+Enter (a key handler below each row field's own, so
///   the `[[` popover sees Enter first): in an item row, A3's `splitItem`,
///   `enterOnEmpty` or `shiftEnter`; over a selection that spans rows or
///   sits in an item, A4's `deleteRange` first, composed with the Enter into
///   one edit (`composeEdits`, D20). A prose or code row with no
///   such selection keeps the platform's newline.
/// - Backspace, Option+Backspace and Cmd+Backspace at a row's text start
///   (A3's `backspaceAtStart` or `joinPrevious`), forward Delete at a row's
///   text end (`deleteForwardAtEnd`), and `deleteRange` over a selection
///   that spans rows.
/// - Tab and Shift+Tab do nothing in a row.
/// - The arrows: Left/Right and Option+Left/Right at a row edge take A4's
///   steps into the adjacent row; Up/Down from a row's first or last visual
///   line land on the adjacent row's line nearest the caret's x (the rows'
///   `LineBoxSource`, D6); Cmd+Up/Down go to the segment's start and end.
///   With Shift they extend the segment selection across rows.
///
/// Every other case keeps the row field's own action (native grapheme,
/// word and line steps inside a row). While the focused field composes,
/// every key goes to the field (the IME) unchanged. Each key applies one
/// A3 or A4 `SegmentEdit` through [SegmentViewState.applyEdit] (D2, D20).
class SegmentKeyboard extends StatefulWidget {
  const SegmentKeyboard({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  State<SegmentKeyboard> createState() => _SegmentKeyboardState();
}

/// What a key works on: the segment's text, its rows (A1), the focused row
/// and the segment selection.
typedef _Keys = ({
  SegmentViewState view,
  String text,
  List<RowSpec> rows,
  int row,
  TextSelection selection,
});

class _SegmentKeyboardState extends State<SegmentKeyboard> {
  late final Map<Type, Action<Intent>> _actions = {
    DeleteCharacterIntent: _RowsAction<DeleteCharacterIntent>(
      (intent) => _delete(forward: intent.forward),
    ),
    DeleteToNextWordBoundaryIntent: _RowsAction<DeleteToNextWordBoundaryIntent>(
      (intent) => _delete(forward: intent.forward),
    ),
    DeleteToLineBreakIntent: _RowsAction<DeleteToLineBreakIntent>(
      (intent) => _delete(forward: intent.forward),
    ),
    ExtendSelectionByCharacterIntent:
        _RowsAction<ExtendSelectionByCharacterIntent>(
          (intent) => _horizontal(
            forward: intent.forward,
            collapse: intent.collapseSelection,
            word: false,
          ),
        ),
    ExtendSelectionToNextWordBoundaryIntent:
        _RowsAction<ExtendSelectionToNextWordBoundaryIntent>(
          (intent) => _horizontal(
            forward: intent.forward,
            collapse: intent.collapseSelection,
            word: true,
          ),
        ),
    ExtendSelectionToNextWordBoundaryOrCaretLocationIntent:
        _RowsAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(
          (intent) => _horizontal(
            forward: intent.forward,
            collapse: false,
            word: true,
            stopAtBase: true,
          ),
        ),
    // Typed as the field's own vertical action is, so it can be called.
    ExtendSelectionVerticallyToAdjacentLineIntent:
        _RowsAction<DirectionalCaretMovementIntent>(
          (intent) => _vertical(
            forward: intent.forward,
            collapse: intent.collapseSelection,
          ),
        ),
    ExtendSelectionToLineBreakIntent:
        _RowsAction<ExtendSelectionToLineBreakIntent>(
          (intent) => _lineBreak(
            forward: intent.forward,
            collapse: intent.collapseSelection,
          ),
        ),
    ExpandSelectionToLineBreakIntent:
        _RowsAction<ExpandSelectionToLineBreakIntent>(
          (intent) => _expandLineBreak(forward: intent.forward),
        ),
    ExtendSelectionToDocumentBoundaryIntent:
        _RowsAction<ExtendSelectionToDocumentBoundaryIntent>(
          (intent) => _document(
            forward: intent.forward,
            collapse: intent.collapseSelection,
            expand: false,
          ),
        ),
    ExpandSelectionToDocumentBoundaryIntent:
        _RowsAction<ExpandSelectionToDocumentBoundaryIntent>(
          (intent) =>
              _document(forward: intent.forward, collapse: false, expand: true),
        ),
    // Tab and Shift+Tab (`insertTab:` / `insertBacktab:`) do nothing in a
    // row (R22).
    NextFocusIntent: DoNothingAction(),
    PreviousFocusIntent: DoNothingAction(),
  };

  /// The state a key works on, or null when the key keeps the field's own
  /// behaviour: no focused row, no valid selection, or the focused field is
  /// composing (TS8).
  _Keys? _keys() {
    final focus = FocusManager.instance.primaryFocus?.context;
    final field = focus?.findAncestorStateOfType<EditableTextState>();
    if (field == null || field.textEditingValue.composing.isValid) return null;
    final view = context.findAncestorStateOfType<SegmentViewState>();
    final row = view?.focusedRow;
    if (view == null || row == null) return null;
    final selection = view.selection;
    if (!selection.isValid) return null;
    final text = view.text;
    return (
      view: view,
      text: text,
      rows: splitRows(text, atSegmentStart: true),
      row: row,
      selection: selection,
    );
  }

  // ---------------------------------------------------------------------
  // Enter and Shift+Enter
  // ---------------------------------------------------------------------

  /// Enter and Shift+Enter in a row (R15-R17, R27). Ignored (the platform
  /// inserts its newline) for a modified Enter, while composing, and in a
  /// prose or code row without a selection reaching outside it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final k = _keys();
    if (k == null) return KeyEventResult.ignored;
    final shift = keys.isShiftPressed;
    final spec = k.rows[k.row];
    final selection = k.selection;
    if (selection.isCollapsed) {
      final edit = _enterEdit(
        k.text,
        k.rows,
        k.row,
        _inRow(spec, selection.extentOffset),
        shift: shift,
      );
      if (edit == null) return KeyEventResult.ignored;
      k.view.applyEdit(edit);
      return KeyEventResult.handled;
    }
    if (_within(spec, selection) && !spec.isItem) {
      return KeyEventResult.ignored;
    }
    // Delete the range, then Enter at its start (R27).
    final range = _segment(selection);
    final delete = deleteRange(k.text, k.rows, range);
    final after = delete.apply(k.text);
    final afterRows = splitRows(after, atSegmentStart: true);
    final enter = _enterEdit(
      after,
      afterRows,
      _rowOf(afterRows, range.start),
      range.start,
      shift: shift,
    );
    // One key, one edit (D20): the delete and the Enter are composed.
    k.view.applyEdit(
      enter == null
          ? replaceRange(k.text, k.rows, range, '\n')
          : composeEdits(delete, enter, text: k.text),
    );
    return KeyEventResult.handled;
  }

  /// Enter ([shift] false) or Shift+Enter at [caret] in row [row]: A3's
  /// edit for an item row, null for a prose or code row.
  static SegmentEdit? _enterEdit(
    String text,
    List<RowSpec> rows,
    int row,
    int caret, {
    required bool shift,
  }) {
    final spec = rows[row];
    if (!spec.isItem) return null;
    if (shift) return shiftEnter(text, rows, row, caret);
    return spec.textLength == 0
        ? enterOnEmpty(text, rows, row)
        : splitItem(text, rows, row, caret);
  }

  // ---------------------------------------------------------------------
  // Backspace and Delete
  // ---------------------------------------------------------------------

  /// Backspace ([forward] false) or forward Delete, by character, word or
  /// line (R18-R20, R27). Returns whether it handled the key.
  bool _delete({required bool forward}) {
    final k = _keys();
    if (k == null) return false;
    final spec = k.rows[k.row];
    final selection = k.selection;
    if (!selection.isCollapsed) {
      if (_within(spec, selection)) return false;
      k.view.applyEdit(deleteRange(k.text, k.rows, _segment(selection)));
      return true;
    }
    final caret = _inRow(spec, selection.extentOffset);
    final SegmentEdit? edit;
    if (forward) {
      if (caret != spec.textEnd) return false;
      edit = deleteForwardAtEnd(k.text, k.rows, k.row);
    } else {
      if (caret != spec.textStart) return false;
      edit = spec.isItem
          ? backspaceAtStart(k.text, k.rows, k.row)
          : joinPrevious(k.text, k.rows, k.row, caret);
    }
    if (edit != null) k.view.applyEdit(edit);
    return true;
  }

  // ---------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------

  /// Left/Right ([word] false) or Option+Left/Right, collapsing or (with
  /// Shift) extending the selection (R23, R26). [stopAtBase] stops an
  /// extension that would pass the selection's base at the base.
  bool _horizontal({
    required bool forward,
    required bool collapse,
    required bool word,
    bool stopAtBase = false,
  }) {
    final k = _keys();
    if (k == null) return false;
    final spec = k.rows[k.row];
    final selection = k.selection;
    final across = !_within(spec, selection);
    int step(int offset) => word
        ? (forward ? nextWordOffset : previousWordOffset)(
            k.text,
            k.rows,
            offset,
          )
        : (forward ? nextCharacterOffset : previousCharacterOffset)(
            k.text,
            k.rows,
            offset,
          );
    if (collapse) {
      if (!selection.isCollapsed) {
        if (!across) return false;
        _moveTo(
          k,
          TextSelection.collapsed(
            offset: forward ? selection.end : selection.start,
          ),
        );
        return true;
      }
      final caret = _inRow(spec, selection.extentOffset);
      if (forward ? caret < spec.textEnd : caret > spec.textStart) {
        return false;
      }
      _moveTo(k, TextSelection.collapsed(offset: step(caret)));
      return true;
    }
    final extent = selection.extentOffset;
    final row = k.rows[_rowOf(k.rows, extent)];
    final atEdge = forward ? extent >= row.textEnd : extent <= row.textStart;
    if (!across && !atEdge) return false;
    var to = word || atEdge
        ? step(extent)
        : _graphemeStep(k.text, row, extent, forward: forward);
    final base = selection.baseOffset;
    if (stopAtBase && (extent - base) * (to - base) < 0) to = base;
    _moveTo(k, TextSelection(baseOffset: base, extentOffset: to));
    return true;
  }

  /// Up/Down, collapsing or (with Shift) extending the selection (R23,
  /// R26): from a row's first visual line Up lands on the previous row's
  /// last visual line at the nearest x, and Down the reverse (D6). A step
  /// between two lines of the focused row stays native.
  bool _vertical({required bool forward, required bool collapse}) {
    final k = _keys();
    if (k == null) return false;
    final boxes = k.view.lineBoxes();
    if (boxes == null) return false;
    final spec = k.rows[k.row];
    final selection = k.selection;
    final across = !_within(spec, selection);
    final origin = !collapse
        ? selection.extentOffset
        : selection.isCollapsed
        ? _inRow(spec, selection.extentOffset)
        : (forward ? selection.end : selection.start);
    final lines = boxes.lines;
    final at = lines.lastIndexWhere((line) => line.range.start <= origin);
    final next = at + (forward ? 1 : -1);
    final int to;
    if (at < 0 || next < 0 || next >= lines.length) {
      if (!across) return false;
      to = forward ? k.rows.last.textEnd : k.rows.first.textStart;
    } else {
      final line = lines[next];
      if (!across && _rowOf(k.rows, line.range.start) == k.row) return false;
      to = boxes.offsetAt(
        Offset(boxes.caretRect(origin).left, (line.top + line.bottom) / 2),
      );
    }
    _moveTo(
      k,
      collapse
          ? TextSelection.collapsed(offset: to)
          : TextSelection(baseOffset: selection.baseOffset, extentOffset: to),
    );
    return true;
  }

  /// Cmd+Left/Right: native inside the focused row; over a selection that
  /// spans rows, to the start or end of the visual line in its row.
  bool _lineBreak({required bool forward, required bool collapse}) {
    final k = _keys();
    if (k == null) return false;
    final selection = k.selection;
    if (_within(k.rows[k.row], selection)) return false;
    final origin = !collapse
        ? selection.extentOffset
        : (forward ? selection.end : selection.start);
    final to = _lineEdge(k, origin, forward: forward);
    _moveTo(
      k,
      collapse
          ? TextSelection.collapsed(offset: to)
          : TextSelection(baseOffset: selection.baseOffset, extentOffset: to),
    );
    return true;
  }

  /// Shift+Cmd+Left/Right: native inside the focused row; over a selection
  /// that spans rows, expanded to the visual line's start or end.
  bool _expandLineBreak({required bool forward}) {
    final k = _keys();
    if (k == null) return false;
    final selection = k.selection;
    if (_within(k.rows[k.row], selection)) return false;
    _moveTo(
      k,
      TextSelection(
        baseOffset: forward ? selection.start : selection.end,
        extentOffset: _lineEdge(
          k,
          forward ? selection.end : selection.start,
          forward: forward,
        ),
      ),
    );
    return true;
  }

  /// Cmd+Up/Down (R23) and Shift+Cmd+Up/Down: the segment's first row's
  /// text start or last row's text end.
  bool _document({
    required bool forward,
    required bool collapse,
    required bool expand,
  }) {
    final k = _keys();
    if (k == null) return false;
    final to = forward ? k.rows.last.textEnd : k.rows.first.textStart;
    final selection = k.selection;
    final base = expand
        ? (forward ? selection.start : selection.end)
        : selection.baseOffset;
    _moveTo(
      k,
      collapse
          ? TextSelection.collapsed(offset: to)
          : TextSelection(baseOffset: base, extentOffset: to),
    );
    return true;
  }

  /// The start or end of the visual line holding [offset], inside its row's
  /// text.
  int _lineEdge(_Keys k, int offset, {required bool forward}) {
    final row = k.rows[_rowOf(k.rows, offset)];
    final lines = k.view.lineBoxes()?.lines ?? const <LineBox>[];
    final at = lines.lastIndexWhere((line) => line.range.start <= offset);
    final edge = at < 0
        ? (forward ? row.textEnd : row.textStart)
        : (forward ? lines[at].range.end : lines[at].range.start);
    return edge.clamp(row.textStart, row.textEnd);
  }

  /// Sets the segment selection to [selection]. When it lies in one row
  /// that isn't focused, that row takes focus; a selection across rows
  /// leaves focus where it is.
  void _moveTo(_Keys k, TextSelection selection) {
    k.view.select(selection);
    final row = _rowOf(k.rows, selection.start);
    if (row == k.row || row != _rowOf(k.rows, selection.end)) return;
    _rowFocusNode(row)?.requestFocus();
  }

  /// The focus node of this segment's editor row [index].
  FocusNode? _rowFocusNode(int index) {
    FocusNode? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is EditorRow) {
        if (widget.index == index) found = widget.focusNode;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: _actions,
    // Below each row field's own key handler (the `[[` popover keeps
    // Enter), above the segment's.
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: widget.child,
    ),
  );
}

/// An override of a row field's editing action (TD6): runs [handle], and
/// when it returns false, the field's own action.
class _RowsAction<T extends Intent> extends ContextAction<T> {
  _RowsAction(this.handle);

  /// Handles the intent across rows; false leaves it to the field.
  final bool Function(T intent) handle;

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    if (handle(intent)) return null;
    final native = callingAction;
    if (native == null || !native.isEnabled(intent)) return null;
    return native is ContextAction<T>
        ? native.invoke(intent, context)
        : native.invoke(intent);
  }
}

SegmentSelection _segment(TextSelection selection) => SegmentSelection(
  baseOffset: selection.baseOffset,
  extentOffset: selection.extentOffset,
);

/// The index of the row holding segment [offset], as the rows host counts
/// it: the first row ending after it, or the last row.
int _rowOf(List<RowSpec> rows, int offset) {
  for (var i = 0; i < rows.length; i++) {
    if (offset < rows[i].end) return i;
  }
  return rows.length - 1;
}

/// [offset] clamped into [row]'s text.
int _inRow(RowSpec row, int offset) => offset.clamp(row.textStart, row.textEnd);

/// Whether [selection] lies inside [row]'s text.
bool _within(RowSpec row, TextSelection selection) =>
    selection.start >= row.textStart && selection.end <= row.textEnd;

/// One grapheme cluster step from [offset] inside [row]'s text of [text],
/// as the row field steps (an emoji sequence is one step).
int _graphemeStep(
  String text,
  RowSpec row,
  int offset, {
  required bool forward,
}) {
  final local = row.toLocal(offset);
  final rowText = text.substring(row.textStart, row.textEnd);
  final step = forward
      ? rowText.substring(local).characters.first.length
      : rowText.substring(0, local).characters.last.length;
  return row.toSegment(forward ? local + step : local - step);
}
