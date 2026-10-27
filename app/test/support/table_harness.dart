// Shared widget-test pump of Spec #197's table WIs (ruling D17, WI #204).
// Only T3 (#204) edits this file; T4-T7 (#205-#208) keep their own helpers
// private to their own test files. Built on `editorScope` (no "No
// ProviderScope found").
//
// - [pumpTable] pumps a note body (a [SegmentedBody]) of a text at a window
//   width ([tableDesktopWidth] or [tableNarrowWidth]) and a text scale, with
//   a focusable field below the body ([tableOutsideKey]) to move focus out
//   of the segment.
// - [TableBody] counts content reports (`onContentChanged`) and undo
//   records (`SegmentUndoRecorder.record` calls) since [TableBody.resetCounts],
//   writes the note as a poll would ([TableBody.serverWrite]), and drives a
//   segment: caret, selection, focus, typing and keys as macOS delivers
//   them.
// - Finders: [tableGrid] (`editor-table-<s>-<r>`), [tableCell]
//   (`editor-table-cell-<s>-<r>-<row>-<col>`, TD8; T4 draws cells),
//   [tableRowField] (a row's field, also while it is offstage).
// - [TableBody.segmentBoxes] is the segment's `LineBoxSource` (segment
//   offsets): take press points and expected rects from it, never from
//   hard-coded coordinates (D18).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/editor/segment_undo.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';

import 'editor_scope.dart';
import 'mac_editing.dart';
import 'segment_editing_finder.dart';

/// The desktop window width (the editor column at its 760 px maximum).
const double tableDesktopWidth = 1280;

/// The narrow window width (Sketch board B2, Spec #197 R27).
const double tableNarrowWidth = 720;

/// The window height every table pump uses.
const double tableWindowHeight = 1000;

/// Key of the focusable field below the note body.
const tableOutsideKey = Key('table-harness-outside');

/// The id of the note [pumpTable] shows: a daily note's or a topic's.
String tableNoteId({bool daily = false}) =>
    daily ? 'daily-2026-10-03' : 'topic-table';

Note _tableNote(String content, {required bool daily}) => Note(
  id: tableNoteId(daily: daily),
  title: daily ? '2026-10-03' : 'Tables',
  contentMd: content,
  frontmatter: daily ? '{"role":"daily"}' : '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// One edit a segment's undo recorder was told about.
typedef TableUndoRecord = ({String before, SegmentEdit edit});

/// A segment undo recorder that remembers what the host told it and then
/// records it as the real one does (undo and redo keep working).
class _TableRecorder extends SegmentUndoRecorder {
  final List<TableUndoRecord> records = [];

  @override
  void record(SegmentEdit edit, {required String before}) {
    records.add((before: before, edit: edit));
    super.record(edit, before: before);
  }
}

/// The text segment [s]'s rows host.
SegmentViewState tableView(WidgetTester tester, [int s = 0]) =>
    tester.state<SegmentViewState>(
      find.descendant(
        of: find.byKey(textSegmentKey(s)),
        matching: find.byType(SegmentView),
      ),
    );

/// The rendered grid of table row [r] of text segment [s] (Key
/// `editor-table-<s>-<r>`, ruling D12).
Finder tableGrid(int s, int r) => find.byKey(Key('editor-table-$s-$r'));

/// Cell [col] of grid row [row] (0: the header) of table row [r] of text
/// segment [s] (Key `editor-table-cell-<s>-<r>-<row>-<col>`, TD8).
Finder tableCell(int s, int r, int row, int col) =>
    find.byKey(Key('editor-table-cell-$s-$r-$row-$col'));

/// Editor row [r] of text segment [s] (Key `editor-row-<s>-<r>`), also
/// while offstage.
Finder tableEditorRow(int s, int r) =>
    find.byKey(Key('editor-row-$s-$r'), skipOffstage: false);

/// Editor row [r]'s field, also while it is offstage (a rendered table).
Finder tableRowField(int s, int r) => find.descendant(
  of: tableEditorRow(s, r),
  matching: find.byType(EditableText, skipOffstage: false),
  skipOffstage: false,
);

/// Editor row [r]'s field only while it is onstage.
Finder tableRowFieldOnstage(int s, int r) => find.descendant(
  of: find.byKey(Key('editor-row-$s-$r')),
  matching: find.byType(EditableText),
);

/// Editor row [r]'s controller (also while its field is offstage).
LivePreviewController tableRowController(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(tableRowField(s, r)).controller
        as LivePreviewController;

/// Editor row [r]'s focus node (also while its field is offstage).
FocusNode tableRowFocusNode(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(tableRowField(s, r)).focusNode;

/// Editor row [r]'s field state (also while offstage).
EditableTextState tableRowFieldState(WidgetTester tester, int s, int r) =>
    tester.state<EditableTextState>(tableRowField(s, r));

/// The grid's state of table row [r] of text segment [s].
TableGridState tableGridState(WidgetTester tester, int s, int r) =>
    tester.state<TableGridState>(tableGrid(s, r));

/// The [EditorRow] widget of row [r] of text segment [s].
EditorRow tableEditorRowWidget(WidgetTester tester, int s, int r) =>
    tester.widget<EditorRow>(
      find.byWidgetPredicate(
        (w) => w is EditorRow && w.segment == s && w.index == r,
        description: 'EditorRow $s-$r',
        skipOffstage: false,
      ),
    );

/// Table row [r] of segment [s] shows its grid: the grid is on screen and
/// the row's field is mounted but offstage.
void expectTableRendered(int s, int r, {String? reason}) {
  expect(tableGrid(s, r), findsOneWidget, reason: reason ?? 'grid shows');
  expect(
    tableRowField(s, r),
    findsOneWidget,
    reason: reason ?? 'the field stays mounted',
  );
  expect(
    tableRowFieldOnstage(s, r),
    findsNothing,
    reason: reason ?? 'the field is offstage',
  );
}

/// Table row [r] of segment [s] is revealed: its field is on screen and no
/// grid shows.
void expectTableRevealed(int s, int r, {String? reason}) {
  expect(tableGrid(s, r), findsNothing, reason: reason ?? 'grid is gone');
  expect(
    tableRowFieldOnstage(s, r),
    findsOneWidget,
    reason: reason ?? 'the field shows',
  );
}

/// A pumped note body holding tables, with report and undo-record counters.
class TableBody {
  TableBody._(this.tester, this._content, this.reports, this._recorders);

  final WidgetTester tester;
  final ValueNotifier<String> _content;

  /// Every joined body `onContentChanged` reported since the pump, in order.
  final List<String> reports;
  final List<_TableRecorder> _recorders;

  int _reportMark = 0;
  int _recordMark = 0;

  List<TableUndoRecord> get _allRecords => [
    for (final r in _recorders) ...r.records,
  ];

  /// Content reports since the pump or the last [resetCounts].
  int get reportCount => reports.length - _reportMark;

  /// Undo records (`record` calls on any segment's recorder) since the pump
  /// or the last [resetCounts].
  int get undoRecordCount => _allRecords.length - _recordMark;

  /// The undo records since the pump or the last [resetCounts].
  List<TableUndoRecord> get undoRecords => _allRecords.sublist(_recordMark);

  /// Starts counting reports and undo records from zero.
  void resetCounts() {
    _reportMark = reports.length;
    _recordMark = _allRecords.length;
  }

  /// The server's copy of the note changed to [text] (a poll, a merge): the
  /// body keeps its selection (clamped), as `SegmentedBody` does.
  Future<void> serverWrite(String text) async {
    _content.value = text;
    await tester.pump();
    await tester.pump();
  }

  /// Text segment [s]'s handle.
  SegmentEditing segment([int s = 0]) => segmentEditingAt(tester, s);

  /// Text segment [s]'s rows host.
  SegmentViewState view([int s = 0]) => tableView(tester, s);

  /// Text segment [s]'s text.
  String text([int s = 0]) => segment(s).text;

  /// Text segment [s]'s selection, in segment offsets.
  TextSelection selection([int s = 0]) => segment(s).selection;

  /// Text segment [s]'s rows as A1 derives them.
  List<RowSpec> rows([int s = 0]) => splitRows(text(s), atSegmentStart: true);

  /// Text segment [s]'s line boxes (segment offsets, rows' box
  /// coordinates).
  LineBoxSource segmentBoxes([int s = 0]) =>
      view(s).lineBoxes() ?? (throw TestFailure('segment $s is not laid out'));

  /// The global rect of [local], a rect in [boxes]' box coordinates.
  Rect toGlobal(LineBoxSource boxes, Rect local) => Rect.fromPoints(
    boxes.box.localToGlobal(local.topLeft),
    boxes.box.localToGlobal(local.bottomRight),
  );

  /// Focuses the field of segment [s]'s row holding [selection]'s extent
  /// (offstage or not), then selects [selection] (segment offsets) through
  /// the segment's handle, as a click or drag would leave it.
  Future<void> select(TextSelection selection, {int s = 0}) async {
    final r = segmentRowHolding(segment(s), selection.extentOffset);
    await tester.showKeyboard(tableRowField(s, r));
    await tester.pump();
    segment(s).select(selection);
    await tester.pump();
  }

  /// [select] with the caret at segment [offset].
  Future<void> placeCaret(int offset, {int s = 0}) =>
      select(TextSelection.collapsed(offset: offset), s: s);

  /// Moves focus out of every text segment, to the field below the body.
  Future<void> focusOutside() async {
    await tester.showKeyboard(find.byKey(tableOutsideKey));
    await tester.pump();
  }

  /// Focuses text segment [s] itself, as tabbing back into it does: the
  /// segment hands focus to the row holding its caret.
  Future<void> refocus({int s = 0}) async {
    view(s).widget.focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
  }

  /// The focused field's state.
  EditableTextState focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    final state = context == null
        ? null
        : context is StatefulElement && context.state is EditableTextState
        ? context.state as EditableTextState
        : context.findAncestorStateOfType<EditableTextState>();
    if (state == null) throw TestFailure('no text field has focus');
    return state;
  }

  /// Types [ch] into the focused field as macOS delivers it: for a
  /// lowercase letter the key down reaches Flutter first; then the text
  /// input inserts [ch] over the field's selection; then the key goes up.
  Future<void> typeChar(String ch) async {
    final letter = RegExp(r'^[a-z]$').hasMatch(ch);
    final key = letter
        ? LogicalKeyboardKey.findKeyByKeyId(ch.codeUnitAt(0))
        : null;
    if (key != null) {
      await tester.sendKeyDownEvent(key, platform: 'macos', character: ch);
      await tester.pump();
    }
    final value = focusedField().textEditingValue;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    await tester.macEditingValue(
      value.text.replaceRange(sel.start, sel.end, ch),
      selection: TextSelection.collapsed(offset: sel.start + ch.length),
    );
    if (key != null) {
      await tester.sendKeyUpEvent(key, platform: 'macos');
      await tester.pump();
    }
  }

  /// Presses [key] (with the modifiers held) as macOS delivers it: the key
  /// event goes to Flutter; when Flutter leaves it unhandled, flutter_test
  /// sends the key's selector to the focused field, and for Enter the text
  /// system inserts a newline over the focused field's selection. Returns
  /// whether Flutter handled the key event.
  Future<bool> press(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
    bool meta = false,
  }) async {
    final mods = [
      if (meta) LogicalKeyboardKey.metaLeft,
      if (alt) LogicalKeyboardKey.altLeft,
      if (shift) LogicalKeyboardKey.shiftLeft,
    ];
    for (final m in mods) {
      await tester.sendKeyDownEvent(m, platform: 'macos');
    }
    final bool handled;
    try {
      handled = await tester.sendKeyEvent(key, platform: 'macos');
      await tester.pump();
      if (!handled && key == LogicalKeyboardKey.enter) {
        final value = focusedField().textEditingValue;
        final sel = value.selection;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: value.text.replaceRange(sel.start, sel.end, '\n'),
            selection: TextSelection.collapsed(offset: sel.start + 1),
          ),
        );
        await tester.pump();
      }
    } finally {
      for (final m in mods.reversed) {
        await tester.sendKeyUpEvent(m, platform: 'macos');
      }
      await tester.pump();
    }
    return handled;
  }

  /// Tab (Shift+Tab when [shift]) held for one key repeat, as macOS
  /// delivers it: each key event goes to Flutter, and when Flutter leaves
  /// one unhandled the text system sends `insertTab:` (`insertBacktab:`).
  /// flutter_test forwards the key down's selector itself.
  Future<void> pressTab({bool shift = false}) async {
    const tab = LogicalKeyboardKey.tab;
    if (shift) {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
    }
    try {
      await tester.sendKeyDownEvent(tab, platform: 'macos');
      await tester.pump();
      final repeat = await tester.sendKeyRepeatEvent(tab, platform: 'macos');
      await tester.pump();
      if (!repeat) {
        await tester.macSelector(shift ? 'insertBacktab:' : 'insertTab:');
      }
      await tester.sendKeyUpEvent(tab, platform: 'macos');
    } finally {
      if (shift) {
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.shiftLeft,
          platform: 'macos',
        );
      }
      await tester.pump();
    }
  }

  /// Cmd+A.
  Future<void> selectAll() => tester.macCmdChord(LogicalKeyboardKey.keyA);

  /// Lets typed edits settle into undo steps (the recorder's coalesce
  /// timer), so no timer is left pending at the end of a test.
  Future<void> settleTyping() => tester.pump(
    SegmentUndoRecorder.coalesce + const Duration(milliseconds: 1),
  );
}

/// Pumps a note body of [text] in the segmented editor, in a window
/// [width] wide (device pixel ratio 1) with the editor's text scaled by
/// [textScale]. A [daily] note's first segment has the capture gutter.
/// [titles], [opener] and [overrides] go to `editorScope`. Counting starts
/// at zero after the pump.
Future<TableBody> pumpTable(
  WidgetTester tester,
  String text, {
  double width = tableDesktopWidth,
  double textScale = 1,
  bool daily = false,
  List<NoteTitle> titles = const [],
  UrlOpener? opener,
  List<Override> overrides = const [],
}) async {
  tester.view
    ..physicalSize = Size(width, tableWindowHeight)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final recorders = <_TableRecorder>[];
  final previous = segmentUndoRecorderFactory;
  segmentUndoRecorderFactory = () {
    final r = _TableRecorder();
    recorders.add(r);
    return r;
  };
  addTearDown(() => segmentUndoRecorderFactory = previous);
  final content = ValueNotifier(text);
  addTearDown(content.dispose);
  final reports = <String>[];
  await pumpEditorScoped(
    tester,
    MaterialApp(
      theme: buildOmTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: content,
                builder: (context, _) => SegmentedBody(
                  note: _tableNote(content.value, daily: daily),
                  content: content.value,
                  savedVersion: 3,
                  onContentChanged: (joined) {
                    reports.add(joined);
                    content.value = joined;
                  },
                ),
              ),
            ),
            const SizedBox(height: 40, child: TextField(key: tableOutsideKey)),
          ],
        ),
      ),
    ),
    titles: titles,
    opener: opener,
    overrides: overrides,
  );
  await tester.pump();
  final body = TableBody._(tester, content, reports, recorders);
  body.resetCounts();
  return body;
}

/// Whether [descendant] is [ancestor] or lies under it in the render tree.
bool tableRenderUnder(RenderObject descendant, RenderObject ancestor) {
  RenderObject? node = descendant;
  while (node != null) {
    if (identical(node, ancestor)) return true;
    node = node.parent;
  }
  return false;
}
