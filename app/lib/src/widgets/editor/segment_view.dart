import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_geometry.dart';
import '../../editor/tag_grammar.dart' show fencedRowLines;
import 'editor_row.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'segment_editing.dart';
import 'segment_keyboard.dart';
import 'segment_pointer_layer.dart';
import 'segment_selection_ops.dart';
import 'segment_undo.dart';
import 'table_grid.dart';

/// What the rows host hands its field builder for one editor row.
@immutable
class EditorRowField {
  const EditorRowField({
    required this.controller,
    required this.focusNode,
    required this.first,
    required this.last,
    required this.hintText,
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
}

/// Builds the field of one editor row: an editable field (a
/// `TextSegmentField`) of [EditorRowField.controller] and
/// [EditorRowField.focusNode].
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

/// One text segment of the segmented editor as editor rows (Spec R9, D5,
/// D8, D9, TD12).
///
/// [controller] holds the segment's whole text and its selection in segment
/// offsets. The segment renders as A1's rows of that text (`splitRows`),
/// re-derived after every change: one field per row, each editing its own
/// `LivePreviewController` that holds only the row's text, keyed
/// `editor-row-<index>-<r>`. Rows are matched across changes (`matchRows`),
/// so the focused row keeps its controller, focus node and field.
///
/// A row edit becomes one `SegmentEdit` of the segment text: the segment
/// controller and every row controller are written in one pass, the
/// segment's undo recorder records it once and [onChanged] reports it once,
/// synchronously. A change of [controller]'s text from outside (another
/// note, a server write) re-derives the rows without reporting and resets
/// the undo recorder.
///
/// [focusNode] wraps the rows: it has focus while a row has, and focusing it
/// moves focus to the row holding the segment's caret. Below the last row
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

  @override
  State<SegmentView> createState() => SegmentViewState();
}

/// One editor row of a [SegmentView].
class _Row {
  _Row(this.spec, this.text)
    : controller = LivePreviewController(text: text),
      focusNode = FocusNode(debugLabel: 'editor-row'),
      fieldKey = GlobalKey(debugLabel: 'editor-row-field'),
      gridKey = GlobalKey(debugLabel: 'editor-row-table-grid');

  RowSpec spec;

  /// The row's text as last derived from the segment text.
  String text;

  final LivePreviewController controller;
  final FocusNode focusNode;

  /// Keeps the row's field (and its EditableText, focus and text input
  /// connection) when the row moves or changes kind.
  final GlobalKey fieldKey;

  /// Holds a table row's grid while it shows (ruling D12).
  final GlobalKey gridKey;

  late final VoidCallback onValue;
  late final VoidCallback onFocus;
}

/// The [SegmentEditing] handle over a [SegmentView]'s editor rows.
class SegmentViewState extends State<SegmentView> implements SegmentEditing {
  final _rowsKey = GlobalKey(debugLabel: 'editor-rows');
  final SegmentUndoRecorder _undo = segmentUndoRecorderFactory();
  List<_Row> _rows = const [];

  /// Rows removed by a re-derive, disposed after the frame.
  final List<_Row> _retired = [];

  /// The segment text the rows were derived from.
  String _text = '';

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
    _applying = true;
    try {
      _syncRows(widget.controller.selection);
    } finally {
      _applying = false;
    }
    widget.controller.addListener(_onSegmentChanged);
    widget.focusNode.addListener(_onSegmentFocus);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSegmentChanged);
    widget.focusNode.removeListener(_onSegmentFocus);
    for (final row in _rows) {
      _unlisten(row);
    }
    _retired.addAll(_rows);
    _disposeRetired();
    super.dispose();
  }

  _Row _newRow(RowSpec spec) {
    final row = _Row(spec, _text.substring(spec.textStart, spec.textEnd));
    row.onValue = () => _onRowValue(row);
    row.onFocus = () => _onRowFocus(row);
    row.controller.addListener(row.onValue);
    row.focusNode.addListener(row.onFocus);
    return row;
  }

  void _unlisten(_Row row) {
    row.controller.removeListener(row.onValue);
    row.focusNode.removeListener(row.onFocus);
  }

  /// [row] has no continuation: its field goes away with this frame.
  void _retire(_Row row) {
    _unlisten(row);
    widget.onRowRemoved(row.controller);
    if (_retired.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _disposeRetired());
    }
    _retired.add(row);
  }

  void _disposeRetired() {
    for (final row in _retired) {
      row.controller.dispose();
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
    if (_applying) return;
    final value = row.controller.value;
    if (_intercepted(row, value)) return;
    if (value.text != row.text) {
      final local = SegmentEdit.diff(row.text, value.text);
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
    if (row.focusNode.hasFocus) _selectFrom(row);
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
    if (external) _undo.reset();
  }

  /// The segment node itself got focus: hand it to the row holding the
  /// segment's caret.
  void _onSegmentFocus() {
    if (!widget.focusNode.hasPrimaryFocus) return;
    _rows[_rowHolding(widget.controller.selection.extentOffset)].focusNode
        .requestFocus();
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
    final match = matchRows(
      [for (final row in _rows) row.spec],
      specs,
      edit: edit,
      focused: focusedRow,
    );
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
    _syncRows(selection);
    setState(() {});
  }

  /// Writes every row's props, text and slice of the segment [selection]
  /// (Spec R26). A focused row that is composing keeps its value while its
  /// text is unchanged (D9).
  void _syncRows(TextSelection selection) {
    final slices = rowSlices([
      for (final row in _rows) row.spec,
    ], _segmentSelection(selection));
    final backward = selection.baseOffset > selection.extentOffset;
    final fenced = fencedRowLines(_text, [for (final row in _rows) row.spec]);
    for (final (j, row) in _rows.indexed) {
      final spec = row.spec;
      row.controller
        ..fenced = fenced[j]
        ..itemText = spec.isItem
        ..taskDone = spec.done
        ..quote = spec.kind == RowKind.quote
        ..atSegmentStart = spec.textStart == 0
        ..revealGate = widget.revealGate;
      // A code row's hidden fence lines lay out 8 px tall (ruling D18).
      // Setting codeRow notifies, so only a change is written.
      final code = spec.kind == RowKind.code;
      if (row.controller.codeRow != code) row.controller.codeRow = code;
      // A table row shows its grid until revealed (Spec #197 R12, D12).
      // Setting tableRow notifies, so only a change is written.
      final table = spec.kind == RowKind.table;
      if (row.controller.tableRow != table) row.controller.tableRow = table;
      final text = _text.substring(spec.textStart, spec.textEnd);
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
      }
      row.text = text;
    }
  }

  /// Puts the caret at the segment's end, in its last row, with focus.
  void _focusEnd() {
    _select(TextSelection.collapsed(offset: _text.length));
    _rows.last.focusNode.requestFocus();
  }

  /// The rows' line boxes in segment offsets, or null before every row is
  /// laid out.
  LineBoxSource? lineBoxes() {
    final box = _rowsKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final rows = <_RowBoxes>[];
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

  /// [row]'s line boxes once laid out, in its field's text offsets: a
  /// rendered table's from its grid (`TableGridState.lineBoxes`, ruling
  /// D12), every other row's from its field. Until a table's grid is built
  /// and laid out, its field (mounted offstage, still laid out) answers.
  LineBoxSource? _rowBoxes(_Row row) {
    final controller = row.controller;
    if (!controller.tableRow || controller.tableRevealed) {
      return _fieldBoxes(row);
    }
    return _gridBoxes(row) ?? _fieldBoxes(row);
  }

  /// [row]'s grid line boxes while its grid is mounted and laid out.
  LineBoxSource? _gridBoxes(_Row row) {
    TableGridState? grid;
    void visit(Element element) {
      if (grid != null) return;
      if (element is StatefulElement && element.state is TableGridState) {
        grid = element.state as TableGridState;
      } else {
        element.visitChildren(visit);
      }
    }

    row.gridKey.currentContext?.visitChildElements(visit);
    return grid?.lineBoxes();
  }

  /// [row]'s field line boxes once it is laid out.
  RenderEditableLineBoxes? _fieldBoxes(_Row row) {
    final editable = findRenderEditable(
      row.fieldKey.currentContext?.findRenderObject(),
    );
    return editable != null && editable.hasSize
        ? RenderEditableLineBoxes(editable)
        : null;
  }

  @override
  String get text => _text;

  @override
  TextSelection get selection => widget.controller.selection;

  /// Row [index]'s spec, null past the last row.
  RowSpec? rowSpec(int index) =>
      index >= 0 && index < _rows.length ? _rows[index].spec : null;

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
  void applyEdit(SegmentEdit edit) => _apply(edit);

  @override
  Widget build(BuildContext context) {
    final geometries = rowGeometries([for (final row in _rows) row.spec]);
    final last = _rows.length - 1;
    final rows = Column(
      key: _rowsKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (r, row) in _rows.indexed)
          KeyedSubtree(
            key: ObjectKey(row.controller),
            child: EditorRow(
              segment: widget.index,
              index: r,
              kind: row.spec.kind,
              geometry: geometries[r],
              // The marker as written, without the row's indentation.
              marker: _text
                  .substring(row.spec.start, row.spec.textStart)
                  .trimLeft(),
              controller: row.controller,
              focusNode: row.focusNode,
              boxes: () => _rowBoxes(row),
              gridKey: row.gridKey,
              field: KeyedSubtree(
                key: row.fieldKey,
                child: widget.fieldBuilder(
                  context,
                  EditorRowField(
                    controller: row.controller,
                    focusNode: row.focusNode,
                    first: r == 0,
                    last: r == last,
                    hintText: _text.isEmpty ? widget.hintText : null,
                  ),
                ),
              ),
            ),
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

/// One laid-out row of a [_RowsLineBoxes]: its spec, its field's line boxes
/// and where its field sits in the rows' box.
typedef _RowBoxes = ({RowSpec spec, LineBoxSource source, Offset shift});

/// [LineBoxSource] over a segment's editor rows (R33), in the rows' box
/// coordinates and segment offsets. An item row's first line starts at the
/// row's start (its marker is drawn on that line).
class _RowsLineBoxes implements LineBoxSource {
  _RowsLineBoxes(this.box, this._rows);

  @override
  final RenderBox box;

  final List<_RowBoxes> _rows;

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

  _RowBoxes _holding(int offset) => _rows.firstWhere(
    (row) => offset < row.spec.end,
    orElse: () => _rows.last,
  );

  @override
  Rect caretRect(int offset) {
    final row = _holding(offset);
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
}
