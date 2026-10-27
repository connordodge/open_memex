// WI #207 (Tables 6, Spec #197 R21, R22, TD4, TD5; Interview Ledger L3,
// L5, L7; rulings D10, D12, D13, D14, D18; design pack
// design/192-md-tables/packs/207.md): pointer and links on a rendered table.
// - `segment_pointer_layer.dart` owns every press on a rendered grid (D14):
//   a plain click reveals the table, focuses its row and puts the caret at
//   the offset the seam's `offsetAt` gives for the press point; a double or
//   triple click selects the word or the grid row's source line at the
//   press-time offset (L7: the reveal's layout change never retargets it);
//   a drag or Shift+click selects through the table, with no extend before
//   `kPrecisePointerHitSlop`; a secondary click places the caret like a
//   plain click and the context menu shows.
// - The grid shows the text cursor, and a press on it never unfocuses the
//   focused row first (the layer's `TextFieldTapRegion`).
// - `link_region.dart`: Cmd over a resolved wikilink or an http(s) link in
//   a rendered cell shows the pointer and sets `cmdHover` (field offsets);
//   Cmd+click opens it (flush a pending save, then `openOrFocus`; a URL
//   through the `UrlOpener`). A ghost ignores Cmd: Cmd+click on it is a
//   plain click (pack correction). Links are found per cell through the one
//   splitter (D10).
//
// Face-agnostic (D18): every press point and expected offset comes from the
// segment's `LineBoxSource` (`segmentBoxes()`), the grid's own rect and the
// cell splitter, so the tests hold for T3's stub grid and T4's real grid.
// Every test runs under macOS.
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        kDoubleTapSlop,
        kDoubleTapTimeout,
        kMiddleMouseButton,
        kPrimaryButton,
        kPrecisePointerHitSlop,
        kSecondaryButton;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/markdown_table.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/table_harness.dart';

/// The prose line above the table (row 0).
const _wi207Intro = 'Intro line';

/// The header line: four columns.
const _wi207Header = '| Step | Notes | Cost | State |';

/// The delimiter line.
const _wi207Delim = '| --- | --- | --- | --- |';

/// Body line 1: bold markup (hidden while rendered), a resolved wikilink.
const _wi207Row1 =
    '| **Marker parser** in pure Dart | see [[Known]] here | 1.5 | done |';

/// Body line 2: a ghost wikilink, an empty cell (column 2) and a missing
/// cell (column 3).
const _wi207Row2 = '| Table reveal | [[Ghost]] |  |';

/// Body line 3: an https link, and a code span the splitter cuts into three
/// cells (D10), so `[[Known]]` is a link of its own cell (column 2) though a
/// whole-line tokenizer sees it inside one code span.
const _wi207Row3 = '| [site](https://example.com) | `a | [[Known]] | b` |';

/// The table row's text (row 1).
const _wi207Table =
    '$_wi207Header\n$_wi207Delim\n$_wi207Row1\n$_wi207Row2\n$_wi207Row3';

/// The prose line below the table (row 2).
const _wi207Below = 'Below line';

const _wi207Text = '$_wi207Intro\n$_wi207Table\n$_wi207Below';

/// The table row's first segment offset.
const _wi207TableStart = _wi207Intro.length + 1;

/// The id of the note titled `Known`.
const _wi207KnownId = 'topic-known';

/// The segment offset of the [nth] occurrence of [needle] in [_wi207Text]
/// at or after [from], plus [plus].
int _wi207At(String needle, {int plus = 0, int from = 0, int nth = 0}) {
  var i = _wi207Text.indexOf(needle, from);
  for (var k = 0; k < nth && i >= 0; k++) {
    i = _wi207Text.indexOf(needle, i + 1);
  }
  if (i < 0) throw ArgumentError('$needle is not in the fixture');
  return i + plus;
}

/// The segment offset where source line [line] of [_wi207Text] starts.
int _wi207LineStart(String line) => _wi207At(line);

/// Every event the link observers saw, in order: `flush` for
/// `EditorController.flushPendingSave`, `open <tab>` for
/// `TabsNotifier.openOrFocus`, `url <url>` for `UrlOpener.open`.
typedef _Wi207Log = List<String>;

/// A `TabsNotifier` that records `openOrFocus` and opens nothing.
class _Wi207Tabs extends TabsNotifier {
  _Wi207Tabs(this.log)
    : super(
        store: UiStateStore(vaultPath: '/dev/null'),
        onPersistedSelection: (_) {},
      );

  final _Wi207Log log;
  final List<WorkspaceTab> opened = [];

  @override
  int openOrFocus(WorkspaceTab tab) {
    log.add('open $tab');
    opened.add(tab);
    return 0;
  }
}

/// An `EditorController` that records `flushPendingSave` calls.
class _Wi207Editor extends EditorController {
  _Wi207Editor(super.ref, this.log);

  final _Wi207Log log;

  @override
  void flushPendingSave() {
    log.add('flush');
    super.flushPendingSave();
  }
}

/// A `UrlOpener` that records every URL and opens nothing.
class _Wi207Opener implements UrlOpener {
  _Wi207Opener(this.log);

  final _Wi207Log log;
  final List<String> opened = [];

  @override
  Future<void> open(String url) async {
    log.add('url $url');
    opened.add(url);
  }
}

/// A pumped [_wi207Text] with its link observers.
class _Wi207Body {
  _Wi207Body(this.b, this.log, this.tabs, this.opener);

  final TableBody b;
  final _Wi207Log log;
  final _Wi207Tabs tabs;
  final _Wi207Opener opener;

  WidgetTester get tester => b.tester;
}

/// Pumps [_wi207Text] (or [text]) with the note `Known` in the titles, a
/// recording tabs notifier, editor controller and URL opener.
Future<_Wi207Body> _wi207Pump(
  WidgetTester tester, {
  String text = _wi207Text,
}) async {
  final log = <String>[];
  final tabs = _Wi207Tabs(log);
  final opener = _Wi207Opener(log);
  final b = await pumpTable(
    tester,
    text,
    titles: [NoteTitle(id: _wi207KnownId, title: 'Known', updatedAt: 1)],
    opener: opener,
    overrides: [
      tabsProvider.overrideWith((ref) => tabs),
      editorControllerProvider.overrideWith((ref) => _Wi207Editor(ref, log)),
    ],
  );
  // The titles load (an async provider), then LinkRegion applies them after
  // a frame.
  await tester.pump();
  await tester.pump();
  expect(
    [for (final r in b.rows()) r.kind],
    const [RowKind.prose, RowKind.table, RowKind.prose],
    reason: 'fixture rows',
  );
  expectTableRendered(0, 1, reason: 'the table starts rendered');
  return _Wi207Body(b, log, tabs, opener);
}

/// The local rect (seam box coordinates) of the glyph at segment [offset].
Rect _wi207GlyphLocal(TableBody b, int offset) {
  final rects = b.segmentBoxes().boxesFor(
    TextRange(start: offset, end: offset + 1),
  );
  if (rects.isEmpty) throw TestFailure('no glyph rect at $offset');
  return rects.first;
}

/// A global point inside the glyph at segment [offset], in its left
/// quarter, so the nearest offset is [offset].
Offset _wi207Glyph(TableBody b, int offset) {
  final boxes = b.segmentBoxes();
  final r = _wi207GlyphLocal(b, offset);
  final local = Offset(r.left + math.min(2.0, r.width / 4), r.center.dy);
  return boxes.box.localToGlobal(local);
}

/// The seam's offset for global [point], read now (press time).
int _wi207SeamOffset(TableBody b, Offset point) {
  final boxes = b.segmentBoxes();
  return boxes.offsetAt(boxes.box.globalToLocal(point));
}

/// The seam line holding segment [offset].
LineBox _wi207LineOf(TableBody b, int offset) =>
    lineHolding(b.segmentBoxes().lines, offset);

/// A global point at local ([x], [y]) of the seam box.
Offset _wi207Global(TableBody b, double x, double y) =>
    b.segmentBoxes().box.localToGlobal(Offset(x, y));

/// Lets the double-click window pass, so the next click is a single click.
Future<void> _wi207PastDoubleClick(WidgetTester tester) =>
    tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));

/// A mouse click at [at] with the [buttons] (primary by default), then a
/// pump.
Future<void> _wi207Click(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryButton,
}) async {
  final mouse = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await tester.pump();
  await mouse.up();
  await tester.pump();
}

/// The table field's selection, in field offsets.
TextSelection _wi207FieldSelection(WidgetTester tester) =>
    tableRowController(tester, 0, 1).selection;

/// Expects a collapsed caret at segment [offset], in the focused table row,
/// with the table revealed.
void _wi207ExpectCaretInTable(TableBody b, int offset, {String? reason}) {
  expectTableRevealed(0, 1, reason: reason);
  expect(
    b.selection(),
    TextSelection.collapsed(offset: offset),
    reason: reason ?? 'segment caret',
  );
  expect(b.view().focusedRow, 1, reason: reason ?? 'the table row has focus');
  expect(
    tableRowFocusNode(b.tester, 0, 1).hasPrimaryFocus,
    isTrue,
    reason: reason ?? 'the table field holds primary focus',
  );
  expect(
    _wi207FieldSelection(b.tester),
    TextSelection.collapsed(offset: offset - _wi207TableStart),
    reason: reason ?? 'field caret (field offsets)',
  );
}

/// Adds a hovering mouse at [at] and pumps; remove it with
/// [_wi207RemoveMouse].
Future<TestGesture> _wi207MouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  return mouse;
}

Future<void> _wi207RemoveMouse(WidgetTester tester, TestGesture mouse) async {
  await mouse.removePointer();
  await tester.pump();
}

/// The mouse cursor the app shows for the test mouse (device 1).
MouseCursor? _wi207Cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

Future<void> _wi207CmdDown(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

Future<void> _wi207CmdUp(WidgetTester tester) async {
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

/// The context menu button labelled [label] (case ignored).
Finder _wi207MenuButton(String label) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase() ==
          label.toLowerCase(),
  description: 'menu button "$label"',
);

/// The trimmed cells of the source line [line] (D10's splitter), in
/// segment offsets.
List<TableCell> _wi207Cells(String line) {
  final start = _wi207LineStart(line);
  final split = splitTableLine(line);
  return [
    for (final c in split.cells) TableCell(start + c.start, start + c.end),
  ];
}

/// True once T4's grid draws cells (Key `editor-table-cell-...`): the
/// seam's offsetAt then maps padding, rules, the band and empty or missing
/// cells to a cell's text end (D13).
bool _wi207CellsDrawn() => tableCell(0, 1, 0, 0).evaluate().isNotEmpty;

/// The global rect of T4's cell [col] of grid row [row] (0: the header) of
/// the table, or null while no cells are drawn (T3's stub).
Rect? _wi207CellRect(WidgetTester tester, int row, int col) {
  final cell = tableCell(0, 1, row, col);
  return cell.evaluate().isEmpty ? null : tester.getRect(cell);
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: plain click (R21)
  // -------------------------------------------------------------------------
  group('plain click (AC1)', () {
    testWidgets(
      'a plain click on a character in a rendered body cell reveals the table focuses its row and puts the caret at that character',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        // `pars|er`: the `e` of `parser` in body line 1, column 0.
        final offset = _wi207At('parser', plus: 4);
        final at = _wi207Glyph(b, offset);
        expect(_wi207SeamOffset(b, at), offset, reason: 'seam guard');

        await _wi207Click(tester, at);

        _wi207ExpectCaretInTable(b, offset);
        expect(b.reportCount, 0, reason: 'a caret reveal reports nothing');
        expect(b.undoRecordCount, 0, reason: 'nor records an undo step');
        // Nothing moves the caret once the double click window passes.
        await _wi207PastDoubleClick(tester);
        _wi207ExpectCaretInTable(b, offset, reason: 'after the click settles');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a rendered cell with the caret on the line above moves focus and caret into the table',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await b.placeCaret(3);
        expectTableRendered(0, 1, reason: 'caret above: still rendered');
        // `see` in column 1 of body line 1: its `e`.
        final offset = _wi207At('see', plus: 1);

        await _wi207Click(tester, _wi207Glyph(b, offset));

        _wi207ExpectCaretInTable(b, offset);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on the header line puts the caret in the header source line',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        // `No|tes` in the header.
        final offset = _wi207At('Notes', plus: 2);

        await _wi207Click(tester, _wi207Glyph(b, offset));

        _wi207ExpectCaretInTable(b, offset);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a link in a rendered cell is a plain click and opens nothing',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        // `Kn|own` of the resolved wikilink in body line 1.
        final offset = _wi207At('Known]] here', plus: 2);

        await _wi207Click(tester, _wi207Glyph(b, offset));

        _wi207ExpectCaretInTable(b, offset);
        expect(t.log, isEmpty, reason: 'no flush, no tab, no URL');
        expect(t.tabs.opened, isEmpty);
        expect(t.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on an https link in a rendered cell opens nothing',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        // `si|te` of the link text in body line 3.
        final offset = _wi207At('site', plus: 2);

        await _wi207Click(tester, _wi207Glyph(b, offset));

        _wi207ExpectCaretInTable(b, offset);
        expect(t.opener.opened, isEmpty);
        expect(t.log, isEmpty);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: padding, empty cell, rule, band (R21, D13)
  // -------------------------------------------------------------------------
  // Each press point is taken from T4's drawn cells (Key
  // `editor-table-cell-...`, TD8) once they exist, else from the seam's
  // glyph rects and lines (T3's stub draws no cells). The caret goes where
  // the seam's offsetAt maps the point at press time; with T4's cells drawn
  // that is the nearest cell's text end (D13).
  group('padding empty cell rule band (AC2)', () {
    /// Clicks at [at] (global) and expects the caret at the offset the seam
    /// gave for [at] at press time, and, once T4 draws cells, at [cellEnd].
    Future<void> clickExpectingMapped(
      _Wi207Body t,
      Offset at,
      int cellEnd,
      String what,
    ) async {
      final b = t.b;
      final mapped = _wi207SeamOffset(b, at);
      if (_wi207CellsDrawn()) {
        expect(mapped, cellEnd, reason: '$what: the seam maps to the text end');
      }
      await _wi207Click(t.tester, at);
      _wi207ExpectCaretInTable(b, mapped, reason: what);
      expect(b.reportCount, 0, reason: '$what: nothing reported');
      expect(b.undoRecordCount, 0, reason: '$what: no undo step');
    }

    testWidgets(
      'a click in the left padding of a body cell puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cell = _wi207Cells(_wi207Row1)[1]; // `see [[Known]] here`
        final drawn = _wi207CellRect(tester, 1, 1);
        final first = _wi207GlyphLocal(b, cell.start);
        final at = drawn != null
            ? Offset(drawn.left + 3, drawn.center.dy)
            : _wi207Global(b, first.left - 3, first.center.dy);

        await clickExpectingMapped(t, at, cell.end, 'left padding');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click in the right padding of the last body cell puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cell = _wi207Cells(_wi207Row1)[3]; // `done`
        final drawn = _wi207CellRect(tester, 1, 3);
        final last = _wi207GlyphLocal(b, cell.end - 1);
        final at = drawn != null
            ? Offset(drawn.right - 3, drawn.center.dy)
            : _wi207Global(b, last.right + 3, last.center.dy);

        await clickExpectingMapped(t, at, cell.end, 'right padding');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click in an empty cell puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final empty = _wi207Cells(_wi207Row2)[2];
        expect(empty.start, empty.end, reason: 'fixture: column 2 is empty');
        // Column 2 (the header's `Cost`) on body line 2.
        final drawn = _wi207CellRect(tester, 2, 2);
        final cost = _wi207GlyphLocal(b, _wi207At('Cost', plus: 1));
        final line = _wi207LineOf(b, _wi207LineStart(_wi207Row2) + 2);
        final at =
            drawn?.center ??
            _wi207Global(b, cost.center.dx, (line.top + line.bottom) / 2);

        await clickExpectingMapped(t, at, empty.end, 'empty cell');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click in a missing cell puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cells = _wi207Cells(_wi207Row2);
        expect(cells, hasLength(3), reason: 'fixture: column 3 is missing');
        // Column 3 (the header's `State`) on body line 2.
        final column = _wi207CellRect(tester, 0, 3);
        final row = _wi207CellRect(tester, 2, 0);
        final state = _wi207GlyphLocal(b, _wi207At('State', plus: 2));
        final line = _wi207LineOf(b, _wi207LineStart(_wi207Row2) + 2);
        final at = column != null && row != null
            ? Offset(column.center.dx, row.center.dy)
            : _wi207Global(b, state.center.dx, (line.top + line.bottom) / 2);

        await clickExpectingMapped(t, at, cells.last.end, 'missing cell');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on the rule under a body row puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cell = _wi207Cells(_wi207Row1)[0];
        // The last pixel row of body line 1 (the rule), in column 0.
        final drawn = _wi207CellRect(tester, 1, 0);
        final next = _wi207LineOf(b, _wi207LineStart(_wi207Row2) + 2);
        final x = _wi207GlyphLocal(b, _wi207At('pure', plus: 1)).center.dx;
        final at = drawn != null
            ? Offset(drawn.center.dx, drawn.bottom - 0.5)
            : _wi207Global(b, x, next.top - 0.5);

        await clickExpectingMapped(t, at, cell.end, 'rule');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click in the blank top strip of the header band puts the caret at the offset the seam maps it to',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cell = _wi207Cells(_wi207Header)[1]; // `Notes`
        final drawn = _wi207CellRect(tester, 0, 1);
        final glyph = _wi207GlyphLocal(b, _wi207At('Notes', plus: 2));
        final header = _wi207LineOf(b, _wi207TableStart);
        final at = drawn != null
            ? Offset(drawn.center.dx, drawn.top + 1)
            : _wi207Global(b, glyph.center.dx, header.top + 1);

        await clickExpectingMapped(t, at, cell.end, 'header band');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: multi-click (R21, L7)
  // -------------------------------------------------------------------------
  group('multi-click (AC3)', () {
    testWidgets(
      'a double click on a word in a rendered cell selects that word in the raw text although the first click revealed the table',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        // `pure` sits after the hidden `**...**` markup: the reveal moves it.
        final word = _wi207At('pure');
        final at = _wi207Glyph(b, word + 1);

        await _wi207Click(tester, at);
        expectTableRevealed(0, 1, reason: 'the first click reveals');
        await tester.pump(const Duration(milliseconds: 50));
        await _wi207Click(tester, at);

        expect(
          b.selection(),
          TextSelection(baseOffset: word, extentOffset: word + 4),
        );
        expect(b.view().focusedRow, 1);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click on a word in the header selects that word in the raw text',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final word = _wi207At('State');
        final at = _wi207Glyph(b, word + 2);

        await _wi207Click(tester, at);
        await tester.pump(const Duration(milliseconds: 50));
        await _wi207Click(tester, at);

        expect(
          b.selection(),
          TextSelection(baseOffset: word, extentOffset: word + 5),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a triple click on a rendered body row selects that grid row whole source line',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final start = _wi207LineStart(_wi207Row1);
        final end = start + _wi207Row1.length;
        final at = _wi207Glyph(b, _wi207At('pure', plus: 1));

        await _wi207Click(tester, at);
        await tester.pump(const Duration(milliseconds: 50));
        await _wi207Click(tester, at);
        await tester.pump(const Duration(milliseconds: 50));
        await _wi207Click(tester, at);

        final selection = b.selection();
        expect(selection.start, start, reason: 'from the line start');
        // The line's content, with or without its line break.
        expect(selection.end, anyOf(end, end + 1), reason: 'to the line end');
        expect(b.view().focusedRow, 1);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click after the double click timeout is a plain click and selects no word',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final at = _wi207Glyph(b, _wi207At('pure', plus: 1));

        await _wi207Click(tester, at);
        await _wi207PastDoubleClick(tester);
        // Revealed now: the same point maps through the field.
        final mapped = _wi207SeamOffset(b, at);
        await _wi207Click(tester, at);

        expect(b.selection(), TextSelection.collapsed(offset: mapped));
      },
      variant: macOnly,
    );
  });

  group('multi-click bounds (AC3)', () {
    testWidgets(
      'a second click far from the first within the double click timeout is a plain click at its own point',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final first = _wi207Glyph(b, _wi207At('pure', plus: 1));

        await _wi207Click(tester, first);
        await tester.pump(const Duration(milliseconds: 50));
        // Revealed now: a point more than kDoubleTapSlop away, mapped
        // through today's layout.
        final second = _wi207Glyph(b, _wi207At(_wi207Below, plus: 3));
        expect((second - first).distance, greaterThan(kDoubleTapSlop));
        final mapped = _wi207SeamOffset(b, second);
        await _wi207Click(tester, second);

        expect(b.selection(), TextSelection.collapsed(offset: mapped));
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: drag and Shift+click (R21)
  // -------------------------------------------------------------------------
  group('drag and Shift click (AC4)', () {
    testWidgets(
      'a drag from a rendered cell into the paragraph below selects from the press time offset through the drag end and reveals the table',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final anchor = _wi207At('pure', plus: 1);
        final mouse = await tester.startGesture(
          _wi207Glyph(b, anchor),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        // The press revealed the table; aim at `Bel|ow` in today's layout.
        final end = _wi207At(_wi207Below, plus: 3);
        await mouse.moveTo(_wi207Glyph(b, end) - const Offset(0, 30));
        await tester.pump();
        await mouse.moveTo(_wi207Glyph(b, end));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        expect(
          b.selection(),
          TextSelection(baseOffset: anchor, extentOffset: end),
        );
        expect(b.view().focusedRow, isNotNull);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a movement under kPrecisePointerHitSlop after a press on a rendered cell does not extend the selection',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final anchor = _wi207At('pure', plus: 1);
        final at = _wi207Glyph(b, anchor);
        final mouse = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        await mouse.moveTo(at + Offset(kPrecisePointerHitSlop / 2, 0));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        _wi207ExpectCaretInTable(b, anchor);
      },
      variant: macOnly,
    );

    testWidgets(
      'a movement of exactly kPrecisePointerHitSlop after a press on a rendered cell does not extend the selection',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final anchor = _wi207At('pure', plus: 1);
        final at = _wi207Glyph(b, anchor);
        final mouse = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        await mouse.moveTo(at + const Offset(0, kPrecisePointerHitSlop));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        _wi207ExpectCaretInTable(b, anchor);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag inside a rendered table past the slop extends from the press time offset',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final anchor = _wi207At('pure', plus: 1);
        final mouse = await tester.startGesture(
          _wi207Glyph(b, anchor),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        // Revealed: aim at `do|ne` of the same line in today's layout.
        final end = _wi207At('done', plus: 2);
        await mouse.moveTo(_wi207Glyph(b, end));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        expect(
          b.selection(),
          TextSelection(baseOffset: anchor, extentOffset: end),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift click into a rendered table from a caret above extends the selection to the mapped offset',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await b.placeCaret(3);
        expectTableRendered(0, 1);
        final offset = _wi207At('see', plus: 1);
        final at = _wi207Glyph(b, offset);

        await tester.macClick(at, shift: true);

        expect(
          b.selection(),
          TextSelection(baseOffset: 3, extentOffset: offset),
        );
        expect(b.view().focusedRow, isNotNull);
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag from the paragraph above into a rendered table selects into it from the press offset',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final anchor = 2;
        final mouse = await tester.startGesture(
          _wi207Glyph(b, anchor),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expectTableRendered(0, 1, reason: 'a caret above keeps the grid');
        final end = _wi207At('Notes', plus: 2);
        // Into the rendered grid's header cell.
        await mouse.moveTo(_wi207Glyph(b, end));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        final selection = b.selection();
        expect(selection.baseOffset, anchor);
        expect(selection.extentOffset, greaterThan(_wi207TableStart));
        expectTableRevealed(0, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: secondary click (R21)
  // -------------------------------------------------------------------------
  group('secondary click (AC5)', () {
    testWidgets(
      'a secondary click on a rendered cell reveals the table places the caret like a plain click and shows the context menu',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final offset = _wi207At('parser', plus: 4);
        final at = _wi207Glyph(b, offset);

        final mouse = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();

        _wi207ExpectCaretInTable(b, offset);
        expect(_wi207MenuButton('Select All'), findsOneWidget);
        expect(b.reportCount, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'a secondary click on a rendered table with the caret in another row moves the caret into the table and shows the menu',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await b.placeCaret(_wi207At(_wi207Below, plus: 2));
        final offset = _wi207At('see', plus: 1);

        await _wi207Click(
          tester,
          _wi207Glyph(b, offset),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();

        _wi207ExpectCaretInTable(b, offset);
        expect(_wi207MenuButton('Select All'), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'a middle button click on a rendered cell neither reveals the table nor moves the caret',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await b.placeCaret(3);

        await _wi207Click(
          tester,
          _wi207Glyph(b, _wi207At('see', plus: 1)),
          buttons: kMiddleMouseButton,
        );
        await tester.pumpAndSettle();

        expect(b.selection(), const TextSelection.collapsed(offset: 3));
        expectTableRendered(0, 1);
        expect(_wi207MenuButton('Select All'), findsNothing);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: focus and cursor (TD4)
  // -------------------------------------------------------------------------
  group('focus and cursor (AC6)', () {
    testWidgets(
      'with another row focused a press on the grid hands focus straight to the table row without unfocusing first',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await b.placeCaret(3);
        final intro = tableRowFocusNode(tester, 0, 0);
        final table = tableRowFocusNode(tester, 0, 1);
        expect(intro.hasPrimaryFocus, isTrue);
        final seen = <FocusNode?>[];
        void record() => seen.add(FocusManager.instance.primaryFocus);
        FocusManager.instance.addListener(record);
        addTearDown(() => FocusManager.instance.removeListener(record));

        final offset = _wi207At('see', plus: 1);
        final mouse = await tester.startGesture(
          _wi207Glyph(b, offset),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await mouse.up();
        await tester.pump();

        expect(table.hasPrimaryFocus, isTrue);
        expect(
          seen.where((n) => !identical(n, intro) && !identical(n, table)),
          isEmpty,
          reason: 'focus never left the two rows: $seen',
        );
        expect(seen, isNotEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'the mouse shows the text cursor over a rendered cell its padding and the header',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final cell = _wi207Cells(_wi207Row1)[1];
        final first = _wi207GlyphLocal(b, cell.start);
        final points = {
          'cell text': _wi207Glyph(b, _wi207At('parser', plus: 2)),
          'padding': _wi207Global(b, first.left - 3, first.center.dy),
          'header': _wi207Glyph(b, _wi207At('Notes', plus: 1)),
        };
        for (final MapEntry(:key, :value) in points.entries) {
          expect(
            await tester.macCursorAt(value),
            SystemMouseCursors.text,
            reason: key,
          );
        }
        expectTableRendered(0, 1, reason: 'hovering reveals nothing');
      },
      variant: macOnly,
    );

    testWidgets(
      'the mouse shows the text cursor over a link in a rendered cell without Cmd',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final mouse = await _wi207MouseAt(
          tester,
          _wi207Glyph(b, _wi207At('Known]] here', plus: 1)),
        );
        expect(_wi207Cursor(), SystemMouseCursors.text);
        expect(tableRowController(tester, 0, 1).cmdHover, isNull);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: Cmd-hover (R22)
  // -------------------------------------------------------------------------
  group('Cmd hover (AC7)', () {
    testWidgets(
      'with Cmd held over a resolved wikilink in a rendered cell the cursor is the pointer and cmdHover covers the wikilink',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final link = _wi207At('[[Known]] here');
        await _wi207CmdDown(tester);
        final mouse = await _wi207MouseAt(tester, _wi207Glyph(b, link + 3));

        expect(_wi207Cursor(), SystemMouseCursors.click);
        expect(
          tableRowController(tester, 0, 1).cmdHover,
          TextRange(
            start: link - _wi207TableStart,
            end: link - _wi207TableStart + '[[Known]]'.length,
          ),
          reason: 'the whole token, in field offsets',
        );
        expectTableRendered(0, 1, reason: 'hovering reveals nothing');

        await _wi207CmdUp(tester);
        expect(_wi207Cursor(), SystemMouseCursors.text);
        expect(tableRowController(tester, 0, 1).cmdHover, isNull);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held over a wikilink the splitter puts in its own cell the cursor is the pointer',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final row3 = _wi207LineStart(_wi207Row3);
        final link = _wi207At('[[Known]]', from: row3);
        await _wi207CmdDown(tester);
        final mouse = await _wi207MouseAt(tester, _wi207Glyph(b, link + 3));

        expect(_wi207Cursor(), SystemMouseCursors.click);
        expect(
          tableRowController(tester, 0, 1).cmdHover,
          TextRange(
            start: link - _wi207TableStart,
            end: link - _wi207TableStart + '[[Known]]'.length,
          ),
        );
        await _wi207CmdUp(tester);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held over an https link in a rendered cell the cursor is the pointer',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final link = _wi207At('[site]');
        await _wi207CmdDown(tester);
        final mouse = await _wi207MouseAt(tester, _wi207Glyph(b, link + 2));

        expect(_wi207Cursor(), SystemMouseCursors.click);
        expect(
          tableRowController(tester, 0, 1).cmdHover,
          TextRange(
            start: link - _wi207TableStart,
            end: link - _wi207TableStart + '[site](https://example.com)'.length,
          ),
        );
        await _wi207CmdUp(tester);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held over a ghost wikilink in a rendered cell the cursor stays the text cursor and nothing changes',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await _wi207CmdDown(tester);
        final mouse = await _wi207MouseAt(
          tester,
          _wi207Glyph(b, _wi207At('Ghost', plus: 1)),
        );

        expect(_wi207Cursor(), SystemMouseCursors.text);
        expect(tableRowController(tester, 0, 1).cmdHover, isNull);
        expectTableRendered(0, 1);
        await _wi207CmdUp(tester);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held over plain cell text the cursor stays the text cursor',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        await _wi207CmdDown(tester);
        final mouse = await _wi207MouseAt(
          tester,
          _wi207Glyph(b, _wi207At('reveal', plus: 1)),
        );

        expect(_wi207Cursor(), SystemMouseCursors.text);
        expect(tableRowController(tester, 0, 1).cmdHover, isNull);
        await _wi207CmdUp(tester);
        await _wi207RemoveMouse(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: Cmd+click (R22)
  // -------------------------------------------------------------------------
  group('Cmd click (AC8)', () {
    testWidgets(
      'Cmd click on a resolved wikilink in a rendered cell saves a pending edit then opens its note once',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;

        await tester.macCmdClick(
          _wi207Glyph(b, _wi207At('Known]] here', plus: 2)),
        );

        expect(t.tabs.opened, [const NoteTab(_wi207KnownId)]);
        expect(t.log, ['flush', 'open ${const NoteTab(_wi207KnownId)}']);
        expect(t.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd click on a wikilink the splitter puts in its own cell opens its note once',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final row3 = _wi207LineStart(_wi207Row3);

        await tester.macCmdClick(
          _wi207Glyph(b, _wi207At('Known', from: row3, plus: 2)),
        );

        expect(t.tabs.opened, [const NoteTab(_wi207KnownId)]);
        expect(t.log, ['flush', 'open ${const NoteTab(_wi207KnownId)}']);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd click on an https link in a rendered cell calls the url opener once',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;

        await tester.macCmdClick(_wi207Glyph(b, _wi207At('site', plus: 1)));

        expect(t.opener.opened, ['https://example.com']);
        expect(t.tabs.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd click on a ghost wikilink in a rendered cell opens nothing and is handled as a plain click',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final offset = _wi207At('Ghost', plus: 2);

        await tester.macCmdClick(_wi207Glyph(b, offset));

        expect(t.log, isEmpty, reason: 'nothing flushed or opened');
        expect(t.tabs.opened, isEmpty);
        expect(t.opener.opened, isEmpty);
        _wi207ExpectCaretInTable(b, offset);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd click on plain text in a rendered cell opens nothing and is handled as a plain click',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final offset = _wi207At('reveal', plus: 2);

        await tester.macCmdClick(_wi207Glyph(b, offset));

        expect(t.log, isEmpty);
        _wi207ExpectCaretInTable(b, offset);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd press on a resolved wikilink released over another cell opens nothing',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final down = _wi207Glyph(b, _wi207At('Known]] here', plus: 2));
        final up = _wi207Glyph(b, _wi207At('done', plus: 1));

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final mouse = await tester.startGesture(
            down,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await mouse.moveTo(up);
          await tester.pump();
          await mouse.up();
          await tester.pump();
        });

        expect(t.tabs.opened, isEmpty);
        expect(t.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd secondary click on a resolved wikilink in a rendered cell opens nothing',
      (tester) async {
        final t = await _wi207Pump(tester);
        final b = t.b;
        final at = _wi207Glyph(b, _wi207At('Known]] here', plus: 2));

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          await _wi207Click(tester, at, buttons: kSecondaryButton);
        });
        await tester.pumpAndSettle();

        expect(t.log, isEmpty);
        expect(t.tabs.opened, isEmpty);
      },
      variant: macOnly,
    );
  });
}
