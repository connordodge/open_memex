import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/editor_rows.dart';
import '../../editor/find_in_note.dart';
import '../../editor/markdown_lines.dart';
import '../../state/find_in_note_state.dart';
import '../find/find_highlights.dart';
import '../find/find_in_note_host.dart' show findFieldDecoration;
import '../find/find_keys.dart';
import '../../editor/row_geometry.dart';
import '../../editor/tag_grammar.dart' show fencedRowLines;
import 'editor_row.dart';
import 'find_decoration.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'marker_column.dart' show isMarkerColumnBox;
import 'paragraph_line_boxes.dart';
import 'row_kinds.dart';
import 'segment_editing.dart';
import 'segment_keyboard.dart';
import 'segment_pointer_layer.dart';
import 'segment_selection_ops.dart';
import 'segment_undo.dart';

/// What the rows host hands its field builder for one editor row.
@immutable
class EditorRowField {
  const EditorRowField({
    required this.controller,
    required this.focusNode,
    required this.first,
    required this.last,
    required this.hintText,
    this.active = true,
    this.onActivate,
  });

  /// The row field's controller: it holds only the row's text.
  final LivePreviewController controller;

  /// The row field's focus node.
  final FocusNode focusNode;

  /// Whether this is the segment's first row.
  final bool first;

  /// Whether this is the segment's last row.
  final bool last;

  /// The field's hint, or null.
  final String? hintText;

  /// Whether the row is its segment's active row (WI #132, Spec #122 Req
  /// 27): the builder builds its editable field then, and else may build
  /// the row's idle text (`IdleRowText`) in its place. Default true (a
  /// builder that ignores it gives every row a field, as before #132).
  final bool active;

  /// Makes the row the active row with the caret at its text end (the idle
  /// row's semantics activate action, Req 34); null outside a rows host.
  final VoidCallback? onActivate;
}

/// Builds the field of one editor row: an editable field (a
/// `TextSegmentField`) of [EditorRowField.controller] and
/// [EditorRowField.focusNode] while [EditorRowField.active], else that or
/// the row's idle text.
typedef EditorRowFieldBuilder =
    Widget Function(BuildContext context, EditorRowField row);

/// Wraps a text segment's [rows] (e.g. with the capture gutter); [boxes]
/// reports the rows' line boxes once they are laid out (null before).
typedef SegmentRowsBuilder =
    Widget Function(
      BuildContext context,
      Widget rows,
      LineBoxSource? Function() boxes,
    );

/// Where a segment selection meets one editor row's edges (WI #129, Spec
/// #122 R17a): it holds the line break above the row ([fromAbove]), the
/// line break after it ([rowBreak]), or runs from at or before the row's
/// start to at or past its text end ([spans]). All false for a collapsed or
/// invalid selection.
typedef RowSelectionEdges = ({bool fromAbove, bool rowBreak, bool spans});

const RowSelectionEdges _noEdges = (
  fromAbove: false,
  rowBreak: false,
  spans: false,
);

/// One laid-out editor row of a segment's line boxes
/// ([SegmentLineBoxes.rowHolding]): its spec, its text slot's line boxes in
/// row offsets and where its slot sits in the rows' box.
typedef RowLineBoxes = ({RowSpec spec, LineBoxSource source, Offset shift});

/// A segment's line boxes over its editor rows ([SegmentViewState.lineBoxes])
/// that also answers row by row, so a caller measures only the rows it
/// reads (WI #129, Spec #122 R11).
abstract interface class SegmentLineBoxes implements LineBoxSource {
  /// The row holding segment [offset]: the first row ending after it, or
  /// the last row.
  RowLineBoxes rowHolding(int offset);
}

/// One text segment of the segmented editor as editor rows (Spec R9, D5,
/// D8, D9, TD12).
///
/// [controller] holds the segment's whole text and its selection in segment
/// offsets. The segment renders as A1's rows of that text (`splitRows`),
/// re-derived after every change: one row per spec, each with its own
/// `LivePreviewController` that holds only the row's text, keyed
/// `editor-row-<index>-<r>`. Only the [SegmentViewState.activeRow] builds
/// its editable field; every other row is an idle row, whose text
/// [fieldBuilder] builds with [EditorRowField.active] false (WI #132, Spec
/// #122 Req 27, TD5). Rows are matched across changes (`matchRows`), so
/// the focused row, else the active row, keeps its controller, focus node
/// and field.
///
/// Each row's subtree is kept across changes and built again only when what
/// it shows changed (WI #129, Spec #122 R17-R19, TD2, TD4): its kind,
/// geometry, marker, index or field configuration. A row moved to another
/// index keeps its field subtree: its D10 index Keys follow it (the field's
/// through a thin wrapper, `EditorRow`), and its offsets are read from the
/// host when needed. Each row is its own repaint boundary.
///
/// A row edit becomes one `SegmentEdit` of the segment text: the segment
/// controller and every row controller are written in one pass, the
/// segment's undo recorder records it once and [onChanged] reports it once,
/// synchronously. A change of [controller]'s text from outside (another
/// note, a server write) re-derives the rows without reporting and resets
/// the undo recorder.
///
/// [focusNode] wraps the rows: it has focus while a row has, and focusing it
/// makes the row holding the segment's caret the active row, which takes
/// focus. Below the last row
/// an empty area makes the segment [minLines] lines tall; a click there
/// puts the caret at the segment's end.
///
/// Its State is the segment's [SegmentEditing] handle, found under the
/// segment's Key `text-segment-<i>`.
class SegmentView extends StatefulWidget {
  const SegmentView({
    super.key,
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.revealGate,
    required this.minLines,
    required this.hintText,
    required this.onChanged,
    required this.onRowRemoved,
    required this.fieldBuilder,
    required this.builder,
    this.active = true,
    this.fieldsKey,
  });

  /// The segment's index (`<i>` of `text-segment-<i>`).
  final int index;

  /// The segment's text and selection.
  final TextEditingController controller;

  /// The segment's focus node, the parent of its rows' focus nodes.
  final FocusNode focusNode;

  /// Every row controller's reveal gate: true while the segment has focus.
  final ValueListenable<bool> revealGate;

  /// The segment's minimum height in body lines.
  final int minLines;

  /// The hint the first row shows while the segment is empty, or null.
  final String? hintText;

  /// A row edit changed the segment text (called once per edit).
  final VoidCallback onChanged;

  /// A row went away; its controller is disposed after this frame.
  final ValueChanged<TextEditingController> onRowRemoved;

  final EditorRowFieldBuilder fieldBuilder;

  final SegmentRowsBuilder builder;

  /// Whether this segment belongs to the active editor (#61 F3, F6 wires
  /// it): its rows' and table grid cells' find highlights (Keys
  /// `find-highlights-<s>-<r>`, `find-highlights-grid-<s>-<row>-<cell>`)
  /// paint only while true.
  final bool active;

  /// What the fields [fieldBuilder] builds depend on beyond each row's
  /// [EditorRowField] (WI #129). When non-null, a rebuilt segment builds its
  /// rows' fields again only when this changes (by `==`), so a parent that
  /// rebuilds with a new but equivalent [fieldBuilder] rebuilds no row.
  /// Null: the fields are built again whenever [fieldBuilder] is another
  /// function.
  final Object? fieldsKey;

  @override
  State<SegmentView> createState() => SegmentViewState();
}

/// One editor row of a [SegmentView].
class _Row {
  _Row(this.spec, this.text)
    : controller = LivePreviewController(text: text),
      focusNode = FocusNode(debugLabel: 'editor-row'),
      fieldKey = GlobalKey(debugLabel: 'editor-row-field'),
      rowKey = GlobalKey(debugLabel: 'editor-row'),
      gridKey = GlobalKey(debugLabel: 'editor-row-table-grid');

  RowSpec spec;

  /// The row's text as last derived from the segment text.
  String text;

  /// The row's index in its segment now.
  int index = 0;

  final LivePreviewController controller;
  final FocusNode focusNode;

  /// Where the segment selection meets the row's edges, as the host last
  /// wrote its rows: it notifies only when that changes.
  final ValueNotifier<RowSelectionEdges> edges = ValueNotifier(_noEdges);

  /// The row's geometry (the row-geometry accessor's answer for it, read
  /// when called), and its text slot's: one function each for the row's
  /// life, so a rebuilt row hands its layers the same ones.
  late final LineBoxSource? Function() boxes;
  late final LineBoxSource? Function() slotBoxes;

  /// The row's field ([EditorRowField] of its first/last/hint state) and
  /// what it was built with; built again only when that changes.
  Widget? field;
  Object? fieldConfig;

  /// The row's subtree and what it was built with; built again only when
  /// that changes.
  Widget? built;
  Object? config;

  /// The line kinds of [controller]'s text, cached by text and segment
  /// start (Spec #122 R18).
  List<MdLine> lines() {
    final text = controller.text;
    final atStart = controller.atSegmentStart;
    final cached = _lines;
    if (cached != null && atStart == _linesAtStart && text == _linesText) {
      return cached;
    }
    _linesText = text;
    _linesAtStart = atStart;
    return _lines = classifyLines(text, atSegmentStart: atStart);
  }

  List<MdLine>? _lines;
  String? _linesText;
  bool? _linesAtStart;

  /// Keeps the row's field (and its EditableText, focus and text input
  /// connection) when the row moves or changes kind.
  final GlobalKey fieldKey;

  /// The row's [EditorRow]: where the host looks for the row's text when
  /// its presenter builds no text slot (WI #127).
  final GlobalKey rowKey;

  /// Holds the row's block while it shows (a table row's grid, ruling D12;
  /// an attachment's image or card): its presenter's
  /// `PresentedRow.blockKey`.
  final GlobalKey gridKey;

  /// What the row's presenter was last built with (WI #124): the host asks
  /// that presenter for the row's geometry and presses, so it answers for
  /// the body it built. Null before the row's first build.
  PresentedRow? presented;

  /// Find in note's decoration of the row's field (#61 F6, D7).
  final ValueNotifier<FindDecoration?> find = ValueNotifier(null);

  /// The controller's value as its listener last saw it: a notification
  /// with the same value (the controller repainting for its find
  /// decoration, hover or resolver) is no edit and no selection move.
  TextEditingValue seen = TextEditingValue.empty;

  late final VoidCallback onValue;
  late final VoidCallback onFocus;

  /// Makes the row the active row, caret at its text end
  /// ([EditorRowField.onActivate]): one function for the row's life.
  late final VoidCallback activate;
}

/// The [SegmentEditing] handle over a [SegmentView]'s editor rows.
class SegmentViewState extends State<SegmentView> implements SegmentEditing {
  /// Test-only work counter: how many times any segment view built.
  @visibleForTesting
  static int debugBuilds = 0;

  /// Test-only work counter: how many times any segment view called
  /// `setState` after re-deriving its rows.
  @visibleForTesting
  static int debugSetStates = 0;

  /// Test-only work counter (WI #131): how many row boxes
  /// [rowsWithin] read, so a bisection (a handful per call) tells from a
  /// scan of every row.
  @visibleForTesting
  static int debugRowEdgeReads = 0;

  /// Test-only work counter (WI #131): how many times a segment view rebuilt
  /// its row-controller index, so a lookup (one build per re-derive) tells
  /// from a scan per call.
  @visibleForTesting
  static int debugRowIndexBuilds = 0;

  final _rowsKey = GlobalKey(debugLabel: 'editor-rows');
  final SegmentUndoRecorder _undo = segmentUndoRecorderFactory();
  List<_Row> _rows = const [];

  /// The current rows by their controller.
  final Map<TextEditingController, _Row> _rowOf = {};

  /// Bumped when the rows' fields must be built again (a new [SegmentView]
  /// field builder or fields key).
  int _fieldsGeneration = 0;

  /// Rows removed by a re-derive, disposed after the frame.
  final List<_Row> _retired = [];

  /// The segment text the rows were derived from.
  String _text = '';

  /// The Find in note state the rows' decorations follow (#61 F6).
  ProviderSubscription<FindInNoteState>? _find;

  /// True while the host writes the segment and row controllers.
  bool _applying = false;

  /// The segment's undo recorder (ruling D19): the host records every
  /// [SegmentEdit] it applies to the segment text with it, once per edit,
  /// and resets it on a change from outside.
  SegmentUndoRecorder get undo => _undo;

  /// Runs first when a row field starts composing over a segment selection
  /// that crosses rows (ruling D19), with the row's index and its composing
  /// value. Returning true means it has already deleted the selected range
  /// into that row (focus stays there); the host then applies the
  /// composing text at the resulting selection. Null (the default) keeps
  /// the plain row behaviour.
  set rowComposingInterceptor(
    bool Function(int rowIndex, TextEditingValue value)? f,
  ) => _composingInterceptor = f;

  bool Function(int rowIndex, TextEditingValue value)? _composingInterceptor;

  @override
  void initState() {
    super.initState();
    _text = widget.controller.text;
    _rows = [
      for (final spec in splitRows(_text, atSegmentStart: true)) _newRow(spec),
    ];
    _indexRows();
    // The segment opens unfocused: the row holding the extent is active.
    _setActive(
      _rows[_rowHolding(widget.controller.selection.extentOffset)],
      rebuild: false,
    );
    _applying = true;
    try {
      _syncRows(widget.controller.selection, props: true, notify: false);
    } finally {
      _applying = false;
    }
    widget.controller.addListener(_onSegmentChanged);
    widget.focusNode.addListener(_onSegmentFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_find != null) return;
    _find = ProviderScope.containerOf(
      context,
      listen: false,
    ).listen<FindInNoteState>(findInNoteProvider, (_, _) => _decorateRows());
    _decorateRows();
  }

  @override
  void didUpdateWidget(SegmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final fieldsChanged = widget.fieldsKey == null
        ? !identical(oldWidget.fieldBuilder, widget.fieldBuilder)
        : widget.fieldsKey != oldWidget.fieldsKey;
    if (fieldsChanged) _fieldsGeneration++;
    if (!identical(oldWidget.revealGate, widget.revealGate)) {
      _applying = true;
      try {
        _syncRows(widget.controller.selection, props: true);
      } finally {
        _applying = false;
      }
    }
    if (oldWidget.active != widget.active || oldWidget.index != widget.index) {
      _decorateRows();
    }
  }

  /// Every row's find decoration, from the Find in note state; none while
  /// not [SegmentView.active].
  void _decorateRows() {
    for (final row in _rows) {
      _decorate(row);
    }
  }

  void _decorate(_Row row) {
    final state = _find?.read();
    row.find.value = state == null || !widget.active
        ? null
        : findFieldDecoration(
            state,
            segment: widget.index,
            kind: FindSourceKind.body,
            start: row.spec.textStart,
            end: row.spec.textEnd,
          );
  }

  @override
  void dispose() {
    _activeRow.dispose();
    _find?.close();
    widget.controller.removeListener(_onSegmentChanged);
    widget.focusNode.removeListener(_onSegmentFocus);
    for (final row in _rows) {
      _unlisten(row);
    }
    _rowOf.clear();
    _retired.addAll(_rows);
    _disposeRetired();
    super.dispose();
  }

  _Row _newRow(RowSpec spec) {
    final row = _Row(spec, _text.substring(spec.textStart, spec.textEnd));
    row.seen = row.controller.value;
    row.onValue = () => _onRowValue(row);
    row.onFocus = () => _onRowFocus(row);
    row.boxes = () => _rowBoxes(row);
    row.slotBoxes = () => _slotBoxes(row);
    row.activate = () => _activateAtEnd(row);
    row.controller.addListener(row.onValue);
    row.focusNode.addListener(row.onFocus);
    // The row's presenter says whether its text is hidden (WI #124, D2):
    // every suppression site reads it as the controller's textHidden.
    row.controller.presenterTextHidden = () => _textHidden(row);
    _rowOf[row.controller] = row;
    return row;
  }

  /// Writes each row's index in [_rows].
  void _indexRows() {
    for (final (j, row) in _rows.indexed) {
      row.index = j;
    }
  }

  void _unlisten(_Row row) {
    row.controller.removeListener(row.onValue);
    row.focusNode.removeListener(row.onFocus);
  }

  /// [row] has no continuation: its field goes away with this frame.
  void _retire(_Row row) {
    _unlisten(row);
    if (identical(_active, row)) _active = null;
    if (identical(_activating, row)) _activating = null;
    if (identical(_focusPending, row)) _focusPending = null;
    _rowOf.remove(row.controller);
    widget.onRowRemoved(row.controller);
    if (_retired.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _disposeRetired());
    }
    _retired.add(row);
  }

  void _disposeRetired() {
    for (final row in _retired) {
      row.controller.dispose();
      row.find.dispose();
      row.edges.dispose();
      row.focusNode.dispose();
    }
    _retired.clear();
  }

  /// The index of the row holding segment [offset]: the first row ending
  /// after it, or the last row.
  int _rowHolding(int offset) {
    for (var i = 0; i < _rows.length; i++) {
      if (offset < _rows[i].spec.end) return i;
    }
    return _rows.length - 1;
  }

  static SegmentSelection _segmentSelection(TextSelection selection) =>
      SegmentSelection(
        baseOffset: selection.baseOffset,
        extentOffset: selection.extentOffset,
      );

  /// A row field's typed change or selection move.
  void _onRowValue(_Row row) {
    final value = row.controller.value;
    final prior = row.seen;
    final changed = value != prior;
    row.seen = value;
    if (_applying || !changed) return;
    if (_intercepted(row, value)) return;
    if (value.text != row.text) {
      final local = SegmentEdit.diff(row.text, value.text);
      if (_handedOver(row, prior, local)) return;
      final at = row.spec.textStart;
      final selection = value.selection;
      _apply(
        SegmentEdit(
          start: at + local.start,
          end: at + local.end,
          replacement: local.replacement,
          selection: selection.isValid
              ? SegmentSelection(
                  baseOffset: at + selection.baseOffset,
                  extentOffset: at + selection.extentOffset,
                )
              : null,
        ),
      );
    } else if (row.focusNode.hasFocus) {
      _selectFrom(row);
    }
  }

  /// Text typed into [row] while it still holds the text input connection
  /// but a handover to another row waits for its field ([_focusPending]):
  /// it goes in at the segment selection, in the row the caret moved to,
  /// as it would once that row's field has focus (Req 31, 33). Only a
  /// plain insertion while the selection lies in the waiting row, into a
  /// row that held no composition ([prior]), moves: an IME commit or a
  /// deletion stays in [row]. Returns whether [local] went in elsewhere;
  /// [row]'s field then gets its own text back.
  bool _handedOver(_Row row, TextEditingValue prior, SegmentEdit local) {
    final pending = _focusPending;
    if (pending == null || identical(pending, row)) return false;
    if (prior.composing.isValid) return false;
    if (local.end != local.start || local.replacement.isEmpty) return false;
    final selection = widget.controller.selection;
    if (!selection.isValid ||
        _rowHolding(selection.start) != pending.index ||
        _rowHolding(selection.end) != pending.index) {
      return false;
    }
    _apply(
      SegmentEdit(
        start: selection.start,
        end: selection.end,
        replacement: local.replacement,
        selection: SegmentSelection.collapsed(
          selection.start + local.replacement.length,
        ),
      ),
    );
    return true;
  }

  /// Offers [row]'s composing [value] to the composing interceptor while the
  /// segment selection crosses rows. When it takes it and leaves a
  /// selection within one row, the composing text [row] typed over its
  /// slice of the selection goes in at that selection, through the row
  /// holding it, and this returns true.
  bool _intercepted(_Row row, TextEditingValue value) {
    final intercept = _composingInterceptor;
    if (intercept == null || !value.composing.isValid) return false;
    final selection = widget.controller.selection;
    if (!_crossesRows(selection)) return false;
    final index = _rows.indexOf(row);
    // The composing text replaced the row's slice of the selection.
    final slice = rowSlices([
      for (final r in _rows) r.spec,
    ], _segmentSelection(selection))[index];
    if (slice == null) return false;
    final cut = value.text.length - (row.text.length - slice.end);
    final inserted = cut > slice.start
        ? value.text.substring(slice.start, cut)
        : '';
    if (!intercept(index, value)) return false;
    final after = widget.controller.selection;
    if (_crossesRows(after)) return false;
    final target = _rows[_rowHolding(after.start)];
    final start = target.spec.toLocal(after.start);
    final end = target.spec.toLocal(after.end);
    int shift(int offset) =>
        start + (offset - slice.start).clamp(0, inserted.length);
    target.controller.value = TextEditingValue(
      text: target.text.replaceRange(start, end, inserted),
      selection: TextSelection(
        baseOffset: shift(value.selection.baseOffset),
        extentOffset: shift(value.selection.extentOffset),
      ),
      composing: TextRange(
        start: shift(value.composing.start),
        end: shift(value.composing.end),
      ),
    );
    return true;
  }

  /// Whether [selection]'s ends lie in different rows.
  bool _crossesRows(TextSelection selection) =>
      _rowHolding(selection.start) != _rowHolding(selection.end);

  void _onRowFocus(_Row row) {
    if (!row.focusNode.hasFocus) return;
    final activating = identical(_activating, row);
    _activating = null;
    // The row holding focus is the active row (Req 27). One that took
    // focus while idle (a request on its node from outside the host)
    // mounts its field, which then needs the keyboard.
    if (!identical(_focusPending, row)) _focusPending = null;
    _setActive(row);
    if (_fieldStateOf(row) == null) _focusAfterFrame(row);
    // An activated row's focus keeps the segment selection (WI #128), and
    // re-slices it so the row the caret left drops the end-of-text caret
    // its field took while still focused (D24).
    if (activating) {
      _select(widget.controller.selection);
    } else {
      _selectFrom(row);
    }
  }

  /// The focused [row]'s selection becomes the segment's.
  void _selectFrom(_Row row) {
    final selection = row.controller.selection;
    if (!selection.isValid) return;
    final at = row.spec.textStart;
    _select(
      TextSelection(
        baseOffset: at + selection.baseOffset,
        extentOffset: at + selection.extentOffset,
      ),
    );
  }

  /// Moves the segment selection to [selection] and every row's to its
  /// slice of it.
  void _select(TextSelection selection) {
    _applying = true;
    try {
      widget.controller.selection = selection;
      _syncRows(selection);
    } finally {
      _applying = false;
    }
    _followExtent();
  }

  /// The segment controller changed: from outside when its text is not the
  /// rows' text.
  void _onSegmentChanged() {
    if (_applying) return;
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final external = text != _text;
    _applying = true;
    try {
      if (external) {
        final diff = SegmentEdit.diff(_text, text);
        _rederive(
          SegmentEdit(
            start: diff.start,
            end: diff.end,
            replacement: diff.replacement,
            selection: _segmentSelection(selection),
          ),
          text,
          selection,
        );
      } else {
        _syncRows(selection);
      }
    } finally {
      _applying = false;
    }
    if (!external) _followExtent();
    if (external) _undo.reset();
  }

  /// The segment node itself got focus: hand it to the row holding the
  /// segment's caret, which becomes the active row (`activateRow`, keeping
  /// the selection). The segment lost focus: the row holding the
  /// selection extent becomes the active row (Req 27).
  void _onSegmentFocus() {
    if (widget.focusNode.hasPrimaryFocus) {
      final selection = widget.controller.selection;
      activateRow(_rowHolding(selection.extentOffset), selection);
    } else if (!widget.focusNode.hasFocus) {
      // Focus left the segment before a handover's row took it: the
      // handover is dropped, so that row does not take focus back.
      _focusPending = null;
      _followExtent();
    }
  }

  /// Applies [edit] to the segment text as one edit (D9).
  void _apply(SegmentEdit edit) {
    final before = _text;
    final text = edit.apply(before);
    final selection = switch (edit.selection) {
      final s? => TextSelection(
        baseOffset: s.baseOffset,
        extentOffset: s.extentOffset,
      ),
      null => widget.controller.selection.copyWith(
        baseOffset: widget.controller.selection.baseOffset.clamp(
          0,
          text.length,
        ),
        extentOffset: widget.controller.selection.extentOffset.clamp(
          0,
          text.length,
        ),
      ),
    };
    _undo.record(edit, before: before);
    _applying = true;
    try {
      widget.controller.value = TextEditingValue(
        text: text,
        selection: selection,
      );
      _rederive(
        SegmentEdit(
          start: edit.start,
          end: edit.end,
          replacement: edit.replacement,
          selection: _segmentSelection(selection),
        ),
        text,
        selection,
      );
    } finally {
      _applying = false;
    }
    widget.onChanged();
  }

  /// Re-derives the rows from [text] after [edit] (Spec R39, R40): rows
  /// with a continuation keep their controller, focus node and field; the
  /// rest are retired and new rows are made.
  void _rederive(SegmentEdit edit, String text, TextSelection selection) {
    final specs = splitRows(text, atSegmentStart: true);
    final before = [for (final row in _rows) row.spec];
    // The row holding focus keeps its controller (Req 33): typing lands in
    // the focused row even while a row a move just activated waits to take
    // focus.
    final focused = focusedRow;
    var match = matchRows(before, specs, edit: edit, focused: focused);
    // With no row focused the active row keeps its controller too, but only
    // through the edit's selection when it has no continuation of its own:
    // carrying it to the row of a caret the edit moved elsewhere would
    // leave every row in between without one (rebuilt and repainted).
    final active = _active?.index;
    if (focused == null &&
        active != null &&
        active < match.length &&
        match[active] == null) {
      match = matchRows(before, specs, edit: edit, focused: active);
    }
    final kept = List<_Row?>.filled(specs.length, null);
    for (final (k, j) in match.indexed) {
      if (j == null) {
        _retire(_rows[k]);
      } else {
        kept[j] = _rows[k];
      }
    }
    _text = text;
    _rows = [
      for (final (j, spec) in specs.indexed)
        if (kept[j] case final row?) (row..spec = spec) else _newRow(spec),
    ];
    _indexRows();
    // The active row keeps being active where it moved to (WI #128); once
    // it went away, the focused row or the row holding the extent is.
    _restoreActive(selection);
    _syncRows(selection, props: true);
    debugSetStates++;
    setState(() {});
  }

  /// Writes every row's slice of the segment [selection] (Spec R26) and
  /// where the selection meets its edges; with [props] (the rows were
  /// derived from new text) also each row's text, props and find
  /// decoration. A focused row that is composing keeps its value while its
  /// text is unchanged (D9). A row whose text, slice, edges and props are
  /// unchanged is not notified (Spec #122 R17a, R19). A row whose props
  /// changed alone is told so once (unless not [notify]), so it re-renders
  /// without being rebuilt; a row whose text or slice changed too already
  /// notifies for that, and gets no second notification.
  void _syncRows(
    TextSelection selection, {
    bool props = false,
    bool notify = true,
  }) {
    final specs = [for (final row in _rows) row.spec];
    final slices = rowSlices(specs, _segmentSelection(selection));
    final backward = selection.baseOffset > selection.extentOffset;
    final fenced = props ? fencedRowLines(_text, specs) : null;
    for (final (j, row) in _rows.indexed) {
      final spec = row.spec;
      final before = row.text;
      final text = fenced == null
          ? before
          : _text.substring(spec.textStart, spec.textEnd);
      final propsChanged = fenced != null && _writeProps(row, fenced[j]);
      row.text = text;
      final local = switch (slices[j]) {
        null => const TextSelection.collapsed(offset: -1),
        final s when backward => TextSelection(
          baseOffset: s.end,
          extentOffset: s.start,
        ),
        final s => TextSelection(baseOffset: s.start, extentOffset: s.end),
      };
      final value = row.controller.value;
      if (value.text != text) {
        row.controller.value = TextEditingValue(text: text, selection: local);
      } else if (value.selection != local &&
          !(row.focusNode.hasFocus && value.composing.isValid)) {
        row.controller.selection = local;
      } else if (propsChanged && notify && text == before) {
        // The row's own field typed a new text: that already notified.
        row.controller.propsChanged();
      }
      row.edges.value = _edgesOf(spec, selection);
    }
  }

  /// Writes [row]'s props from its spec and [fenced] (which of its lines
  /// are fenced code over the whole segment), and its find decoration;
  /// returns whether a prop that notifies nothing when set changed.
  /// [fenced] is kept when equal, so caches keyed on it hold.
  bool _writeProps(_Row row, List<bool> fenced) {
    final spec = row.spec;
    final controller = row.controller;
    final quote = spec.kind == RowKind.quote;
    final atSegmentStart = spec.textStart == 0;
    final changed =
        !listEquals(controller.fenced, fenced) ||
        controller.itemText != spec.isItem ||
        controller.taskDone != spec.done ||
        controller.quote != quote ||
        controller.atSegmentStart != atSegmentStart ||
        !identical(controller.revealGate, widget.revealGate);
    if (changed) {
      if (!listEquals(controller.fenced, fenced)) controller.fenced = fenced;
      controller
        ..itemText = spec.isItem
        ..taskDone = spec.done
        ..quote = quote
        ..atSegmentStart = atSegmentStart
        ..revealGate = widget.revealGate;
    }
    controller.findDecoration = row.find;
    _decorate(row);
    // A code row's hidden fence lines lay out 8 px tall (ruling D18).
    // Setting codeRow notifies, so only a change is written.
    final code = spec.kind == RowKind.code;
    if (controller.codeRow != code) controller.codeRow = code;
    // A table row shows its grid until revealed (Spec #197 R12, D12).
    // Setting tableRow notifies, so only a change is written.
    final table = spec.kind == RowKind.table;
    if (controller.tableRow != table) controller.tableRow = table;
    return changed;
  }

  /// Where [selection] meets the edges of the row of [spec].
  RowSelectionEdges _edgesOf(RowSpec spec, TextSelection selection) {
    if (!selection.isValid || selection.isCollapsed) return _noEdges;
    final end = spec.textEnd;
    final unit = end < _text.length ? _text.codeUnitAt(end) : 0;
    final breakAfter = unit == 0x0A || unit == 0x0D;
    return (
      fromAbove: selection.start < spec.start && spec.start <= selection.end,
      rowBreak: breakAfter && selection.start <= end && end < selection.end,
      spans: selection.start <= spec.start && selection.end >= end,
    );
  }

  /// Puts the caret at the segment's end, in its last row, with focus.
  void _focusEnd() {
    _select(TextSelection.collapsed(offset: _text.length));
    _rows.last.focusNode.requestFocus();
  }

  /// The rows' line boxes in segment offsets, each row's through the
  /// row-geometry accessor ([rowBoxes]: a block's, or its text slot's,
  /// whether a field or a `RichText`), or null before every row is laid
  /// out.
  LineBoxSource? lineBoxes() {
    final box = _rowsKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final rows = <RowLineBoxes>[];
    for (final row in _rows) {
      final source = _rowBoxes(row);
      if (source == null) return null;
      rows.add((
        spec: row.spec,
        source: source,
        shift: MatrixUtils.transformPoint(
          source.box.getTransformTo(box),
          Offset.zero,
        ),
      ));
    }
    return _RowsLineBoxes(box, rows);
  }

  /// Row [i]'s geometry (WI #124, ruling D3): its presenter's
  /// `blockBoxes` when non-null (a rendered table's grid), else its text
  /// slot's (field's) line boxes, in the row field's text offsets and the
  /// source's own box coordinates. Null past the last row and before the
  /// row is laid out.
  LineBoxSource? rowBoxes(int i) =>
      i >= 0 && i < _rows.length ? _rowBoxes(_rows[i]) : null;

  /// [row]'s geometry, as [rowBoxes] reports it: its presenter's block
  /// boxes when non-null, else its text slot's line boxes ([_slotBoxes]). A
  /// rendered table's grid answers once built and laid out
  /// (`TableGridState.lineBoxes`, ruling D12); until then its field
  /// (mounted offstage, still laid out) does.
  LineBoxSource? _rowBoxes(_Row row) {
    final presented = _presented(row);
    return presenterFor(presented.kind).blockBoxes(presented) ??
        _slotBoxes(row);
  }

  /// What [row]'s presenter was last built with; before its first build, or
  /// once the row changed kind or index since, the row as it stands.
  PresentedRow _presented(_Row row) {
    final built = row.presented;
    if (built != null &&
        built.kind == row.spec.kind &&
        built.index == row.index) {
      return built;
    }
    return PresentedRow(
      segment: widget.index,
      index: row.index,
      kind: row.spec.kind,
      controller: row.controller,
      blockKey: row.gridKey,
    );
  }

  /// Whether [row]'s presenter hides its text now (WI #124, D2).
  bool _textHidden(_Row row) {
    final presented = _presented(row);
    return presenterFor(presented.kind).textHidden(presented);
  }

  /// Whether a row's presenter owns the press at global [position] (WI #124,
  /// ruling D5): the segment's pointer layer then ignores it, as it does a
  /// marker column's.
  bool rowOwnsPress(Offset position) {
    for (final row in _rows) {
      final presented = _presented(row);
      if (presenterFor(presented.kind).ownsPress(presented, position)) {
        return true;
      }
    }
    return false;
  }

  /// The line boxes of [row]'s text slot once it is laid out (WI #127): of
  /// the text laid out under the row's field (a field's, or a `RichText`'s
  /// standing in for it), else, when its presenter built no text slot, of
  /// the text laid out under the row ([textSlotBoxes]).
  LineBoxSource? _slotBoxes(_Row row) => textSlotBoxes(_slotRoot(row));

  /// The laid-out text of [row]'s text slot ([textSlotBox]), or null.
  RenderBox? _slotText(_Row row) => textSlotBox(_slotRoot(row));

  /// Where [row]'s text slot lies: its field's subtree, else the row's.
  RenderObject? _slotRoot(_Row row) =>
      _attachedUnder(row.fieldKey) ?? _attachedUnder(row.rowKey);

  /// The render object of [key]'s subtree while it is in the tree, else
  /// null. A subtree that left the tree this frame (a row swapping its
  /// field for a `RichText`, WI #128) keeps its key until the frame ends,
  /// with its render object detached.
  static RenderObject? _attachedUnder(GlobalKey key) {
    final element = key.currentContext as Element?;
    final box = element?.renderObject;
    return box != null && box.attached ? box : null;
  }

  /// Row [i]'s controller (it holds only the row's text), null past the
  /// last row.
  LivePreviewController? rowController(int i) =>
      i >= 0 && i < _rows.length ? _rows[i].controller : null;

  /// The index now of the row whose field edits [row], or null when [row]
  /// is no row field of this segment (WI #129: the D10 index Keys read it;
  /// WI #128's pointer layer too).
  int? rowIndexOf(TextEditingController row) => _rowOf[row]?.index;

  /// Where the segment selection meets the edges of the row whose field
  /// edits [row]: it notifies only when that changes, once the rows hold
  /// the selection (WI #129, Spec #122 R17a). Null when [row] is no row
  /// field of this segment.
  ValueListenable<RowSelectionEdges>? rowEdgesOf(TextEditingController row) =>
      _rowOf[row]?.edges;

  /// The line kinds (`classifyLines`) of [row]'s text, parsed once per
  /// change of that text (Spec #122 R18); null when [row] is no row field
  /// of this segment.
  List<MdLine>? rowLinesOf(TextEditingController row) => _rowOf[row]?.lines();

  /// Row [i]'s focus node, null past the last row.
  FocusNode? rowFocusNode(int i) =>
      i >= 0 && i < _rows.length ? _rows[i].focusNode : null;

  /// The text position (row offset and affinity) of row [i]'s text slot
  /// under global [point], as the slot's own text resolves it; null past
  /// the last row and before the slot is laid out. A rendered table row
  /// answers through its field (mounted offstage).
  TextPosition? rowPositionAt(int i, Offset point) {
    if (i < 0 || i >= _rows.length) return null;
    return switch (_slotText(_rows[i])) {
      final RenderEditable field => field.getPositionForPoint(point),
      final RenderParagraph text => text.getPositionForOffset(
        text.globalToLocal(point),
      ),
      _ => null,
    };
  }

  /// The word at [position] (a row offset) in row [i]'s text slot, as the
  /// slot's own text finds words; null past the last row and before the
  /// slot is laid out.
  TextRange? rowWordBoundary(int i, TextPosition position) {
    if (i < 0 || i >= _rows.length) return null;
    return switch (_slotText(_rows[i])) {
      final RenderEditable field => field.getWordBoundary(position),
      final RenderParagraph text => text.getWordBoundary(position),
      _ => null,
    };
  }

  /// A press the segment's pointer layer took at row offset [local] of row
  /// [i], as the row field's own tap would end it: hides the field's
  /// toolbar and, while the field has focus and an IME is composing in it,
  /// puts its caret at [local] through the field (the segment's select
  /// leaves a composing row's selection alone, D9; the field's selection
  /// change ends a composition the caret leaves). Nothing for a row
  /// without a field.
  void rowPressed(int i, int local) {
    if (i < 0 || i >= _rows.length) return;
    final field = _fieldStateOf(_rows[i]);
    if (field == null) return;
    field.hideToolbar();
    final value = field.textEditingValue;
    if (!field.widget.focusNode.hasFocus || !value.composing.isValid) return;
    field.userUpdateTextEditingValue(
      value.copyWith(selection: TextSelection.collapsed(offset: local)),
      SelectionChangedCause.tap,
    );
  }

  /// The segment's active row (WI #128, #132, Spec #122 Req 27): the one
  /// row shown as its editable field, every other row idle. It notifies
  /// when it changes, and the rows host builds the two rows' fields again.
  ///
  /// - While the segment has focus it is the row whose field holds focus,
  ///   or the row [activateRow] asked focus for until that focus arrives
  ///   (the old row keeps focus and its text input connection until the
  ///   new row's field is mounted, so the segment stays focused
  ///   throughout).
  /// - Otherwise it is the row holding the segment's selection extent.
  /// - A selection that crosses rows keeps it in the row holding focus,
  ///   the row the selection started from.
  ///
  /// It follows its row when rows re-derive (an agent reload keeps the
  /// row's controller, `matchRows`); when that row goes away, the focused
  /// row or the row holding the extent becomes active.
  ///
  /// The host's activation seam (lead ruling Q1).
  ValueListenable<int?> get activeRow => _activeRow;
  final ValueNotifier<int?> _activeRow = ValueNotifier(null);

  /// The row [activeRow] names.
  _Row? _active;

  /// The row [activateRow] asked focus for until that focus arrives: the
  /// focus keeps the segment selection rather than taking the row's slice.
  _Row? _activating;

  /// The active row that takes focus after this frame, once its field is
  /// mounted ([_focusAfterFrame]); null when none waits.
  _Row? _focusPending;

  /// Makes [row] the active row; with [rebuild], the rows are built again,
  /// so the row that was active builds its idle text and [row] its field.
  void _setActive(_Row row, {bool rebuild = true}) {
    if (identical(row, _active) && _activeRow.value == row.index) return;
    _active = row;
    _activeRow.value = row.index;
    if (rebuild && mounted) setState(() {});
  }

  /// While the segment has no focus, the row holding the selection extent
  /// is the active row (Req 27).
  void _followExtent() {
    if (widget.focusNode.hasFocus || _rows.isEmpty) return;
    _setActive(_rows[_rowHolding(widget.controller.selection.extentOffset)]);
  }

  /// After a re-derive: the active row where it moved to, else (it went
  /// away) the row holding focus or the row holding [selection]'s extent.
  void _restoreActive(TextSelection selection) {
    final active = _active;
    if (active != null && identical(_rowOf[active.controller], active)) {
      _activeRow.value = active.index;
    } else {
      _setActive(
        _rows[focusedRow ?? _rowHolding(selection.extentOffset)],
        rebuild: false,
      );
    }
    _followExtent();
  }

  /// Makes row [i] the active row with segment [selection] (WI #128, #132,
  /// Spec #122 Req 30, 33): a press, a menu, a keyboard move, the segment
  /// taking focus, an idle row's activate action or Check Document Now
  /// acting on a row asks for it.
  ///
  /// - An IME composition open in another row is committed there first
  ///   (its text stays; the composing range closes).
  /// - The segment selection becomes [selection] and [activeRow] becomes
  ///   [i].
  /// - Row [i] takes focus: now when its field is mounted, else after this
  ///   frame, which mounts it. Until then the row holding focus keeps it
  ///   (and its text input connection), so the segment stays focused and
  ///   nothing typed meanwhile is lost.
  /// - When that focus arrives the segment selection stays as it is then
  ///   (a drag may have extended it), so a selection across rows keeps its
  ///   ends.
  ///
  /// Nothing past the last row. The host's activation seam (lead ruling
  /// Q1): the pointer layer, the keyboard, the row menus and Check
  /// Document Now activate rows through it only.
  void activateRow(int i, TextSelection selection) {
    if (i < 0 || i >= _rows.length) return;
    final row = _rows[i];
    _commitComposing(except: row);
    _select(selection);
    _setActive(row);
    final node = row.focusNode;
    _activating = node.hasFocus ? null : row;
    final field = _fieldStateOf(row);
    if (field == null) {
      _focusAfterFrame(row);
    } else {
      _focusPending = null;
      if (!node.hasFocus) _focusField(row, field);
    }
  }

  /// Focuses [row]'s unfocused [field] as a click on it does: the field's
  /// own update with its value unchanged focuses it and builds its
  /// selection overlay, so its toolbar and context menu (SpellingMenu) can
  /// show over the caret activation gave it, also for a right click on
  /// that caret, which selects nothing. A plain focus request builds no
  /// overlay for a field that already holds a valid selection.
  void _focusField(_Row row, EditableTextState field) {
    if (identical(field.widget.focusNode, row.focusNode)) {
      field.userUpdateTextEditingValue(field.textEditingValue, null);
    } else {
      row.focusNode.requestFocus();
    }
  }

  /// [row]'s activate action: the active row, caret at its text end.
  void _activateAtEnd(_Row row) {
    if (!identical(_rowOf[row.controller], row)) return;
    activateRow(row.index, TextSelection.collapsed(offset: row.spec.textEnd));
  }

  /// Commits an IME composition open in the focused row unless that row is
  /// [except] (Req 33): its composing range closes and its text stays.
  void _commitComposing({required _Row except}) {
    final i = focusedRow;
    if (i == null) return;
    final row = _rows[i];
    final value = row.controller.value;
    if (identical(row, except) || !value.composing.isValid) return;
    _applying = true;
    try {
      row.controller.value = value.copyWith(composing: TextRange.empty);
    } finally {
      _applying = false;
    }
  }

  /// [row] takes focus after this frame, once its field is mounted: a
  /// field takes the text input connection when its node gains focus, so
  /// the node is asked then, not before. A row whose node already holds
  /// focus (it took focus while idle) asks its field for the keyboard
  /// instead. Only the last row asked for waits; nothing once it went away
  /// or stopped being active, or once focus moved elsewhere since the ask:
  /// out of the segment ([_onSegmentFocus] drops the wait), or, asked while
  /// the segment had no focus, to another node that is not a focus scope
  /// (a palette or search field took it; a tap outside a field only
  /// unfocuses it to its scope).
  void _focusAfterFrame(_Row row) {
    _focusPending = row;
    final from = FocusManager.instance.primaryFocus;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted || !identical(_focusPending, row)) return;
      _focusPending = null;
      if (!identical(_active, row) || !identical(_rowOf[row.controller], row)) {
        return;
      }
      final now = FocusManager.instance.primaryFocus;
      if (!widget.focusNode.hasFocus &&
          now != null &&
          !identical(now, from) &&
          now is! FocusScopeNode) {
        return;
      }
      final field = _fieldStateOf(row);
      if (field == null) return;
      if (row.focusNode.hasFocus) {
        field.requestKeyboard();
      } else {
        _focusField(row, field);
      }
    }, debugLabel: 'SegmentView.focusActiveRow');
    binding.ensureVisualUpdate();
  }

  /// Row [i]'s field state (WI #128), or null past the last row and while
  /// the row's text slot holds no field (a `RichText` stands in for it).
  EditableTextState? rowField(int i) =>
      i >= 0 && i < _rows.length ? _fieldStateOf(_rows[i]) : null;

  /// [row]'s field state, or null while its slot holds no field.
  EditableTextState? _fieldStateOf(_Row row) {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
      } else {
        element.visitChildren(visit);
      }
    }

    if (_attachedUnder(row.fieldKey) == null) return null;
    row.fieldKey.currentContext?.visitChildElements(visit);
    return found;
  }

  @override
  String get text => _text;

  @override
  TextSelection get selection => widget.controller.selection;

  /// Row [index]'s spec, null past the last row.
  RowSpec? rowSpec(int index) =>
      index >= 0 && index < _rows.length ? _rows[index].spec : null;

  /// The row whose field edits [row] (WI #436, spell checking): its line
  /// from the row's start (an item row's block marker included), where the
  /// field's text starts in it, and whether the row starts the segment.
  /// Null when [row] is no row field of this segment.
  ({String line, int textStart, bool atSegmentStart})? rowLineOf(
    TextEditingController row,
  ) {
    final i = _rowIndexOf(row);
    if (i == null) return null;
    final spec = _rows[i].spec;
    return (
      line: _text.substring(spec.start, spec.textEnd),
      textStart: spec.textStart - spec.start,
      atSegmentStart: spec.start == 0,
    );
  }

  /// The rows [_rowIndex] indexes; rebuilt when the rows are re-derived (a
  /// re-derive makes a new list).
  List<_Row>? _indexedRows;

  /// Each row field's controller to its row's index (WI #131).
  Map<TextEditingController, int> _rowIndex = const {};

  /// The index of the row whose field edits [row], or null: a lookup, not a
  /// scan of the rows (Spec #122 Req 25).
  int? _rowIndexOf(TextEditingController row) {
    if (!identical(_indexedRows, _rows)) {
      _indexedRows = _rows;
      debugRowIndexBuilds++;
      _rowIndex = Map.identity()
        ..addAll({for (final (i, r) in _rows.indexed) r.controller: i});
    }
    return _rowIndex[row];
  }

  /// The row-top index (WI #131, Spec #122 Req 25): the rows whose laid-out
  /// [EditorRow]s meet the global band [top]..[bottom], as `(first, last)`
  /// (`first > last` when none does), found by bisection over the rows'
  /// global tops and bottoms, never by a walk of every row. Null while a
  /// row it reads is not laid out.
  ({int first, int last})? rowsWithin(double top, double bottom) {
    final count = _rows.length;
    double? edge(int i, {required bool bottomEdge}) {
      debugRowEdgeReads++;
      final box = _rows[i].rowKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      final y = bottomEdge ? box.size.height : 0.0;
      return box.localToGlobal(Offset(0, y)).dy;
    }

    // The first row ending below [top].
    var lo = 0;
    var hi = count;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final y = edge(mid, bottomEdge: true);
      if (y == null) return null;
      if (y > top) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final first = lo;
    // The first row starting at or below [bottom].
    hi = count;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final y = edge(mid, bottomEdge: false);
      if (y == null) return null;
      if (y >= bottom) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return (first: first, last: lo - 1);
  }

  /// Row [i]'s [EditorRow] context (WI #131: a reveal finds a row's widgets
  /// under it, never by a walk of every row), null past the last row and
  /// before the row is built.
  BuildContext? rowContext(int i) =>
      i >= 0 && i < _rows.length ? _rows[i].rowKey.currentContext : null;

  /// Where [row]'s field text starts in the segment text (WI #438), or
  /// null when [row] is no row field of this segment.
  int? rowTextStartOf(TextEditingController row) {
    for (final r in _rows) {
      if (identical(r.controller, row)) return r.spec.textStart;
    }
    return null;
  }

  @override
  int? get focusedRow {
    final i = _rows.indexWhere((row) => row.focusNode.hasFocus);
    return i < 0 ? null : i;
  }

  @override
  int get rowCount => _rows.length;

  @override
  Rect rectForOffset(int offset) {
    final boxes = lineBoxes()!;
    final local = boxes.caretRect(offset);
    return Rect.fromPoints(
      boxes.box.localToGlobal(local.topLeft),
      boxes.box.localToGlobal(local.bottomRight),
    );
  }

  @override
  void select(TextSelection selection) => _select(selection);

  @override
  void replaceText(String text) {
    if (text == _text) {
      _select(TextSelection.collapsed(offset: text.length));
      return;
    }
    final diff = SegmentEdit.diff(_text, text);
    _apply(
      SegmentEdit(
        start: diff.start,
        end: diff.end,
        replacement: diff.replacement,
        selection: SegmentSelection.collapsed(text.length),
      ),
    );
  }

  /// Applies [edit] to the segment's text as one edit (D2, D12): the rows
  /// re-derive, the segment's undo recorder records it once, and the note's
  /// joined body is reported once through `onContentChanged`. C1b's
  /// checkbox toggle applies `toggleTask` through it.
  @override
  void applyEdit(SegmentEdit edit) => _apply(edit);

  @override
  int? offsetAtGlobal(Offset position) {
    final boxes = lineBoxes();
    return boxes?.offsetAt(boxes.box.globalToLocal(position));
  }

  /// [row]'s subtree (WI #129, Spec #122 R17, R19, TD2, TD4): the same
  /// widget as at the last build while what it shows is unchanged (its
  /// field's configuration, index, kind, geometry, marker, a table row's
  /// offset and the segment's own props), so a rebuilt segment rebuilds
  /// only the rows that changed. Its offsets are read from the row when
  /// needed. A row is its own repaint boundary; [first] and [last]: whether
  /// it is the segment's first and last row.
  Widget _rowWidget(
    BuildContext context,
    _Row row,
    ItemGeometry? geometry, {
    required bool first,
    required bool last,
  }) {
    final spec = row.spec;
    // The marker as written, without the row's indentation.
    final marker = _text.substring(spec.start, spec.textStart).trimLeft();
    row.presented = PresentedRow(
      segment: widget.index,
      index: row.index,
      kind: spec.kind,
      controller: row.controller,
      geometry: geometry,
      marker: marker,
      blockKey: row.gridKey,
    );
    final hint = _text.isEmpty ? widget.hintText : null;
    // Only the active row builds its editable field (WI #132).
    final active = identical(row, _active);
    final fieldConfig = (
      first: first,
      last: last,
      hint: hint,
      active: active,
      generation: _fieldsGeneration,
    );
    var field = row.field;
    if (field == null || row.fieldConfig != fieldConfig) {
      row.fieldConfig = fieldConfig;
      field = row.field = KeyedSubtree(
        key: row.fieldKey,
        child: widget.fieldBuilder(
          context,
          EditorRowField(
            controller: row.controller,
            focusNode: row.focusNode,
            first: first,
            last: last,
            hintText: hint,
            active: active,
            onActivate: row.activate,
          ),
        ),
      );
    }
    final table = spec.kind == RowKind.table;
    final config = (
      field: field,
      segment: widget.index,
      index: row.index,
      kind: spec.kind,
      geometry: geometry == null
          ? null
          : (
              geometry.markerX,
              geometry.columns,
              geometry.columnWidth,
              geometry.textX,
              geometry.childMarkerX,
            ),
      marker: marker,
      depth: spec.depth,
      done: spec.done,
      // Only a table's grid cells read the row's offset.
      textStart: table ? spec.textStart : 0,
      active: widget.active,
      revealGate: widget.revealGate,
    );
    final built = row.built;
    if (built != null && row.config == config) return built;
    row.config = config;
    return row.built = KeyedSubtree(
      key: ObjectKey(row.controller),
      child: RepaintBoundary(
        // Find highlights below the row (#61 F3, Req 28): under its
        // selection fill, spelling squiggles and text.
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: _RowFindHighlights(
                segment: widget.index,
                index: row.index,
                row: row,
                revealGate: widget.revealGate,
                active: widget.active,
                boxes: row.slotBoxes,
                // Where the field sits in the row: an indent or a wider
                // marker column moves it under equal ranges.
                layout: (spec.kind, geometry?.textX),
              ),
            ),
            FindGridScope(
              segment: widget.index,
              textStart: config.textStart,
              active: widget.active,
              child: EditorRow(
                key: row.rowKey,
                segment: widget.index,
                index: row.index,
                kind: spec.kind,
                geometry: geometry,
                marker: marker,
                controller: row.controller,
                focusNode: row.focusNode,
                boxes: row.boxes,
                gridKey: row.gridKey,
                field: field,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugBuilds++;
    final geometries = rowGeometries([for (final row in _rows) row.spec]);
    final last = _rows.length - 1;
    final rows = Column(
      key: _rowsKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (r, row) in _rows.indexed)
          _rowWidget(
            context,
            row,
            geometries[r],
            first: r == 0,
            last: r == last,
          ),
      ],
    );
    return widget.builder(
      context,
      Focus(
        focusNode: widget.focusNode,
        child: SegmentKeyboard(
          child: SegmentPointerLayer(
            child: SegmentSelectionOps(
              child: TextFieldTapRegion(
                child: Stack(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: widget.minLines * lineHeight(LineHeightKind.body),
                    ),
                    // The empty area below the last row.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _focusEnd,
                      ),
                    ),
                    Listener(behavior: HitTestBehavior.opaque, child: rows),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      lineBoxes,
    );
  }
}

/// The find highlights of one editor row's field (#61 F3, Key
/// `find-highlights-<segment>-<index>`): the matches in the row's
/// `[textStart, textEnd)` of the segment text, over the field's line boxes.
///
/// A hidden match on a line the field reveals now (the caret or selection
/// on it, as `revealedLines` decides for the field's own span) paints as a
/// visible match (lead ruling Q1). A table row showing its grid paints
/// nothing here: its cells paint their own (D8). Nothing while not
/// [active].
class _RowFindHighlights extends ConsumerWidget {
  const _RowFindHighlights({
    required this.segment,
    required this.index,
    required this.row,
    required this.revealGate,
    required this.active,
    required this.boxes,
    required this.layout,
  });

  final int segment;
  final int index;

  /// The row: its offsets are read when the highlights build, since a row
  /// is not rebuilt when the rows above it change (WI #129).
  final _Row row;
  final ValueListenable<bool> revealGate;
  final bool active;
  final LineBoxSource? Function() boxes;

  /// The layer's [FindHighlights.layout]: the field's place in the row.
  final Object? layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(findInNoteProvider);
    final controller = row.controller;
    // The field's text, selection and reveal change its layout and which
    // lines show their markup.
    final changes = Listenable.merge([controller, revealGate]);
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) {
        final spec = row.spec;
        return FindHighlights(
          key: findHighlightsKey(segment, index),
          ranges: active && !controller.textHidden
              ? findPaintRanges(
                  state,
                  segment: segment,
                  kind: FindSourceKind.body,
                  start: spec.textStart,
                  end: spec.textEnd,
                  revealed: _revealed(),
                )
              : const [],
          boxes: boxes,
          repaint: changes,
          layout: layout,
        );
      },
    );
  }

  /// The field-local ranges of the field's lines that show their markup
  /// now, as `LivePreviewController.buildTextSpan` decides them; the line
  /// kinds are parsed once per change of the row's text.
  List<TextRange> _revealed() {
    final controller = row.controller;
    final lines = row.lines();
    final revealed = revealedLines(
      lines,
      controller.selection,
      forceHidden: !revealGate.value,
      itemText: controller.itemText,
      // A line Find in note reveals for the current match shows its markup
      // too (#61 F6, lead ruling Q1).
      revealRange: controller.findDecoration?.value?.revealRange,
    );
    return [
      for (final (i, line) in lines.indexed)
        if (revealed[i]) TextRange(start: line.start, end: line.contentEnd),
    ];
  }
}

/// [LineBoxSource] over a segment's editor rows (R33), in the rows' box
/// coordinates and segment offsets. An item row's first line starts at the
/// row's start (its marker is drawn on that line).
class _RowsLineBoxes implements SegmentLineBoxes {
  _RowsLineBoxes(this.box, this._rows);

  @override
  final RenderBox box;

  final List<RowLineBoxes> _rows;

  @override
  List<LineBox> get lines => [
    for (final row in _rows)
      for (final (i, line) in row.source.lines.indexed)
        LineBox(
          range: TextRange(
            start: i == 0
                ? row.spec.start
                : row.spec.toSegment(line.range.start),
            end: row.spec.toSegment(line.range.end),
          ),
          top: line.top + row.shift.dy,
          bottom: line.bottom + row.shift.dy,
          baseline: line.baseline + row.shift.dy,
        ),
  ];

  @override
  List<Rect> boxesFor(TextRange range) => [
    for (final row in _rows)
      for (final rect in row.source.boxesFor(
        TextRange(
          start: row.spec.toLocal(range.start),
          end: row.spec.toLocal(range.end),
        ),
      ))
        rect.shift(row.shift),
  ];

  @override
  RowLineBoxes rowHolding(int offset) => _rows.firstWhere(
    (row) => offset < row.spec.end,
    orElse: () => _rows.last,
  );

  @override
  Rect caretRect(int offset) {
    final row = rowHolding(offset);
    return row.source.caretRect(row.spec.toLocal(offset)).shift(row.shift);
  }

  @override
  int offsetAt(Offset point) {
    final row = _rows.firstWhere(
      (row) => point.dy < row.shift.dy + row.source.box.size.height,
      orElse: () => _rows.last,
    );
    return row.spec.toSegment(row.source.offsetAt(point - row.shift));
  }

  /// The line holding [offset]: in the last row starting at or before it
  /// (the first row for an offset before every row), that row's line
  /// holding the offset's row-local place, in segment offsets. Measures that
  /// one line only.
  @override
  LineBox lineAt(int offset) {
    final row = _rows.lastWhere(
      (row) => row.spec.start <= offset,
      orElse: () => _rows.first,
    );
    final line = row.source.lineAt(row.spec.toLocal(offset));
    return LineBox(
      range: TextRange(
        start: line.range.start == 0
            ? row.spec.start
            : row.spec.toSegment(line.range.start),
        end: row.spec.toSegment(line.range.end),
      ),
      top: line.top + row.shift.dy,
      bottom: line.bottom + row.shift.dy,
      baseline: line.baseline + row.shift.dy,
    );
  }
}

/// The laid-out text an editor row's text slot shows at or under [root]
/// (WI #127, Spec #122 TD5): the first field's (`RenderEditable`), else the
/// first `RichText`'s (`RenderParagraph`) standing in for the field; null
/// when neither is there or laid out. A marker column's subtree
/// ([isMarkerColumnBox]) is skipped: its marker text is not the row's. The
/// row-geometry accessor's text-slot half (`SegmentViewState.rowBoxes`);
/// [textSlotBoxes] measures it.
RenderBox? textSlotBox(RenderObject? root) {
  RenderEditable? field;
  RenderParagraph? text;
  void visit(RenderObject node) {
    if (field != null || isMarkerColumnBox(node)) return;
    if (node is RenderEditable) {
      field = node;
    } else if (node is RenderParagraph) {
      text ??= node;
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  final box = field ?? text;
  return box != null && box.hasSize ? box : null;
}

/// The line boxes of [textSlotBox] at or under [root]: a field's
/// (`RenderEditableLineBoxes`) or a `RichText`'s
/// (`RenderParagraphLineBoxes`), in its own box coordinates and text
/// offsets; null before it is laid out.
LineBoxSource? textSlotBoxes(RenderObject? root) =>
    _lineBoxesOf(textSlotBox(root));

LineBoxSource? _lineBoxesOf(RenderBox? slot) => switch (slot) {
  final RenderEditable field => RenderEditableLineBoxes(field),
  final RenderParagraph text => RenderParagraphLineBoxes(text),
  _ => null,
};

/// The [textSlotBoxes] at or under [root] and their lines while they hold
/// [text]: a field's laid-out text equals it, a `RichText`'s has its length
/// (the last line ends at the laid-out text's end); null before then, or
/// while the slot shows another text.
({LineBoxSource boxes, List<LineBox> lines})? textSlotLines(
  RenderObject? root,
  String text,
) {
  final slot = textSlotBox(root);
  if (slot is RenderEditable && slot.plainText != text) return null;
  final boxes = _lineBoxesOf(slot);
  if (boxes == null) return null;
  final lines = boxes.lines;
  if (lines.isEmpty || lines.last.range.end != text.length) return null;
  return (boxes: boxes, lines: lines);
}
