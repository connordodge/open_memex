// WI #132 (Spec #122 Req 27-29, 31-34, TD5): shared probes of the active
// and idle rows of a text segment, for `idle_rows_parity_test.dart`,
// `idle_rows_handover_test.dart` and `perf/idle_rows_open_test.dart`.
//
// Every probe reads a row through the rows host (`SegmentViewState`): its
// geometry through the row-geometry accessor (`rowBoxes`), its field through
// `rowField`, which row is active through `activeRow`, focus through
// `focusedRow`. An idle row is a row whose text slot is a `RichText`
// (`rowBoxes` answers `RenderParagraphLineBoxes`) and that has no field
// (`rowField` is null); the active row is the one row with a field.
//
// Helpers carry the `wi132`/`Wi132` prefix so stacked siblings never
// collide. Text is synthetic (public repo).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import 'app_harness.dart' show pumpFrames;
import 'editor_rows_probe.dart';
import 'segment_editing_finder.dart';

/// The rows host of text segment [segment].
SegmentViewState wi132Host(WidgetTester tester, [int segment = 0]) =>
    rowsHostOf(tester, segment);

/// The index of the row of text segment [segment] whose line (marker
/// included, indentation trimmed) starts with [prefix].
int wi132RowOf(WidgetTester tester, String prefix, {int segment = 0}) {
  final host = wi132Host(tester, segment);
  for (var i = 0; i < host.rowCount; i++) {
    final spec = host.rowSpec(i)!;
    final line = host.text.substring(spec.start, spec.textEnd).trimLeft();
    if (line.startsWith(prefix)) return i;
  }
  throw TestFailure('no row of text segment $segment starts with "$prefix"');
}

/// Row [row]'s text (the field's text: an item row's without its marker).
String wi132RowText(WidgetTester tester, int row, {int segment = 0}) {
  final host = wi132Host(tester, segment);
  final spec = host.rowSpec(row)!;
  return host.text.substring(spec.textStart, spec.textEnd);
}

/// Whether row [row] is idle now: no field, and its geometry is a
/// `RichText`'s.
bool wi132IsIdle(WidgetTester tester, int row, {int segment = 0}) {
  final host = wi132Host(tester, segment);
  return host.rowField(row) == null &&
      host.rowBoxes(row) is RenderParagraphLineBoxes;
}

/// Expects row [row] to be idle ([wi132IsIdle]).
void wi132ExpectIdle(
  WidgetTester tester,
  int row, {
  int segment = 0,
  String? reason,
}) {
  final host = wi132Host(tester, segment);
  expect(
    host.rowField(row),
    isNull,
    reason: '${reason ?? 'row $row'}: an idle row has no field',
  );
  expect(
    host.rowBoxes(row),
    isA<RenderParagraphLineBoxes>(),
    reason: '${reason ?? 'row $row'}: an idle row is a RichText',
  );
}

/// Expects row [row] to be the active row: `activeRow` names it and it has
/// a field.
void wi132ExpectActive(
  WidgetTester tester,
  int row, {
  int segment = 0,
  String? reason,
}) {
  final host = wi132Host(tester, segment);
  expect(
    host.activeRow.value,
    row,
    reason: '${reason ?? 'row $row'}: activeRow names it',
  );
  expect(
    host.rowField(row),
    isNotNull,
    reason: '${reason ?? 'row $row'}: the active row is a field',
  );
}

/// Expects exactly row [row] to have a field, every other row idle.
void wi132ExpectOnlyActive(WidgetTester tester, int row, {int segment = 0}) {
  final host = wi132Host(tester, segment);
  wi132ExpectActive(tester, row, segment: segment);
  for (var i = 0; i < host.rowCount; i++) {
    if (i == row) continue;
    expect(
      host.rowField(i),
      isNull,
      reason: 'row $i has no field while row $row is active',
    );
  }
}

/// Takes focus out of the editor (nothing has primary focus) and pumps.
Future<void> wi132Unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pump();
  expect(
    wi132Host(tester).widget.focusNode.hasFocus,
    isFalse,
    reason: 'fixture: the segment has no focus',
  );
}

/// Moves the segment selection to [selection] through the host (no focus
/// change), then pumps.
Future<void> wi132Select(
  WidgetTester tester,
  TextSelection selection, {
  int segment = 0,
}) async {
  wi132Host(tester, segment).select(selection);
  await tester.pump();
  await tester.pump();
}

/// Asks the host to make row [row] the active row with [selection]
/// (`activateRow`, the activation seam), then pumps one frame or [frames].
Future<void> wi132Activate(
  WidgetTester tester,
  int row,
  TextSelection selection, {
  int segment = 0,
  int frames = 2,
}) async {
  wi132Host(tester, segment).activateRow(row, selection);
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
}

/// The caret at row [row]'s text start (+ [offset]), in segment offsets.
TextSelection wi132CaretIn(
  WidgetTester tester,
  int row, {
  int offset = 0,
  int segment = 0,
}) => TextSelection.collapsed(
  offset: wi132Host(tester, segment).rowSpec(row)!.textStart + offset,
);

/// The editor page's scroll position.
ScrollPosition wi132Page(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .ancestor(
            of: find.byKey(textSegmentKey(0)),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// The global rect of row [row]'s whole subtree (marker column included).
Rect wi132RowRect(WidgetTester tester, int row, {int segment = 0}) {
  final host = wi132Host(tester, segment);
  return tester.getRect(find.byKey(ObjectKey(host.rowController(row))));
}

/// The global rect of row [row]'s text slot (under its index Key
/// `editor-row-<s>-<r>`).
Rect wi132SlotRect(WidgetTester tester, int row, {int segment = 0}) =>
    tester.getRect(find.byKey(ValueKey('editor-row-$segment-$row')));

/// [local] of [box] in global coordinates.
Rect wi132Global(RenderBox box, Rect local) => Rect.fromPoints(
  box.localToGlobal(local.topLeft),
  box.localToGlobal(local.bottomRight),
);

/// The global centre of row [row]'s glyph at row offset [local].
Offset wi132GlyphPoint(WidgetTester tester, int row, int local) {
  final boxes = wi132Host(tester).rowBoxes(row)!;
  final rects = boxes.boxesFor(TextRange(start: local, end: local + 1));
  if (rects.isEmpty) throw TestFailure('row $row has no glyph at $local');
  return wi132Global(boxes.box, rects.first).center;
}

/// What row [row] lays out, in global coordinates: its text slot's (or
/// block's) rect, its lines (range, top, bottom, baseline), every
/// character's glyph boxes, every row's rect and the page's scroll offset.
typedef Wi132Geometry = ({
  Rect slot,
  List<(TextRange, double, double, double)> lines,
  List<List<Rect>> glyphs,
  List<Rect> rows,
  double pixels,
});

/// Row [row]'s [Wi132Geometry] now; [table]: the row shows its grid (its
/// block's rect, Key `editor-table-<s>-<r>`).
Wi132Geometry wi132Geometry(
  WidgetTester tester,
  int row, {
  bool table = false,
  int segment = 0,
}) {
  final host = wi132Host(tester, segment);
  final boxes = host.rowBoxes(row);
  if (boxes == null) throw TestFailure('row $row reports no geometry');
  final box = boxes.box;
  final length = wi132RowText(tester, row, segment: segment).length;
  return (
    slot: table
        ? tester.getRect(find.byKey(ValueKey('editor-table-$segment-$row')))
        : wi132SlotRect(tester, row, segment: segment),
    lines: [
      for (final l in boxes.lines)
        (
          l.range,
          box.localToGlobal(Offset(0, l.top)).dy,
          box.localToGlobal(Offset(0, l.bottom)).dy,
          box.localToGlobal(Offset(0, l.baseline)).dy,
        ),
    ],
    glyphs: [
      for (var i = 0; i < length; i++)
        [
          for (final r in boxes.boxesFor(TextRange(start: i, end: i + 1)))
            wi132Global(box, r),
        ],
    ],
    rows: [
      for (var i = 0; i < host.rowCount; i++)
        wi132RowRect(tester, i, segment: segment),
    ],
    pixels: wi132Page(tester).pixels,
  );
}

void _expectRect(Rect got, Rect want, String reason) {
  expect(got.left, moreOrLessEquals(want.left, epsilon: 0.01), reason: reason);
  expect(got.top, moreOrLessEquals(want.top, epsilon: 0.01), reason: reason);
  expect(
    got.right,
    moreOrLessEquals(want.right, epsilon: 0.01),
    reason: reason,
  );
  expect(
    got.bottom,
    moreOrLessEquals(want.bottom, epsilon: 0.01),
    reason: reason,
  );
}

/// Expects [idle] to equal [active] (row heights, line boxes, glyph
/// positions, every row's place and the scroll offset), to 0.01 px.
void wi132ExpectSameGeometry(
  Wi132Geometry idle,
  Wi132Geometry active,
  String what,
) {
  _expectRect(idle.slot, active.slot, '$what: the slot rect');
  expect(
    idle.lines.length,
    active.lines.length,
    reason: '$what: the line count',
  );
  for (final (i, l) in idle.lines.indexed) {
    final f = active.lines[i];
    expect(l.$1, f.$1, reason: '$what: line $i range');
    expect(l.$2, moreOrLessEquals(f.$2, epsilon: 0.01), reason: '$what $i');
    expect(l.$3, moreOrLessEquals(f.$3, epsilon: 0.01), reason: '$what $i');
    expect(l.$4, moreOrLessEquals(f.$4, epsilon: 0.01), reason: '$what $i');
  }
  expect(idle.glyphs.length, active.glyphs.length, reason: '$what: chars');
  for (final (i, g) in idle.glyphs.indexed) {
    final f = active.glyphs[i];
    expect(g.length, f.length, reason: '$what: glyph $i boxes');
    for (final (j, r) in g.indexed) {
      _expectRect(r, f[j], '$what: glyph $i');
    }
  }
  expect(idle.rows.length, active.rows.length, reason: '$what: row count');
  for (final (i, r) in idle.rows.indexed) {
    _expectRect(r, active.rows[i], '$what: row $i rect');
  }
  expect(idle.pixels, active.pixels, reason: '$what: the scroll offset');
}

/// The selection fill row [row] paints (`OmColors.selection` rects), in
/// its text slot's coordinates.
List<Rect> wi132SelectionRects(
  WidgetTester tester,
  int row, {
  int segment = 0,
}) {
  final object = tester.renderObject(
    find.byKey(ValueKey('editor-row-$segment-$row')),
  );
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  object.paint(context, Offset.zero);
  context.dispose();
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRect &&
          (call.invocation.positionalArguments[1] as Paint).color.toARGB32() ==
              OmColors.selection.toARGB32())
        call.invocation.positionalArguments[0] as Rect,
  ];
}

/// Every paint call [object] makes painted at the origin (its children
/// included): the call name, its rect or path bounds when it has one, and
/// its paint colour when it has one.
List<(Symbol, Rect?, int?)> wi132PaintLog(RenderObject object) {
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  object.paint(context, Offset.zero);
  context.dispose();
  Rect? area(Object? arg) => switch (arg) {
    final Rect r => r,
    final RRect r => r.outerRect,
    final Path p => p.getBounds(),
    _ => null,
  };
  return [
    for (final call in canvas.invocations)
      (
        call.invocation.memberName,
        call.invocation.positionalArguments.isEmpty
            ? null
            : area(call.invocation.positionalArguments.first),
        call.invocation.positionalArguments
            .whereType<Paint>()
            .firstOrNull
            ?.color
            .toARGB32(),
      ),
  ];
}

/// Expects two paint logs ([wi132PaintLog]) to draw the same shapes in the
/// same colours (positions to 0.01 px). Text draws (`drawParagraph`) are
/// compared by count only.
void wi132ExpectSamePaint(
  List<(Symbol, Rect?, int?)> idle,
  List<(Symbol, Rect?, int?)> active,
  String what,
) {
  List<(Symbol, Rect?, int?)> shapes(List<(Symbol, Rect?, int?)> log) => [
    for (final op in log)
      if (op.$1 != #drawParagraph && op.$1 != #save && op.$1 != #restore) op,
  ];
  final a = shapes(idle);
  final b = shapes(active);
  expect(
    [for (final op in a) (op.$1, op.$3)],
    [for (final op in b) (op.$1, op.$3)],
    reason: '$what: the same draws in the same colours',
  );
  for (final (i, op) in a.indexed) {
    final want = b[i].$2;
    final got = op.$2;
    if (want == null || got == null) {
      expect(got, want, reason: '$what: draw $i area');
      continue;
    }
    _expectRect(got, want, '$what: draw $i area');
  }
}

/// A primary-button mouse click at global [at], then pumps one frame.
Future<void> wi132ClickDown(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// [wi132ClickDown], then lets any click chain expire.
Future<void> wi132Click(WidgetTester tester, Offset at) async {
  await wi132ClickDown(tester, at);
  await pumpFrames(tester);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// Presses [key] as macOS delivers it (no pump).
Future<void> wi132Key(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyEvent(key, platform: 'macos');

/// Types [text] into the focused row field as the platform's text input
/// does: it replaces the selection of the value the input connection holds
/// now. No pump.
void wi132Type(WidgetTester tester, String text) {
  final state = tester.testTextInput.editingState;
  if (state == null) throw TestFailure('no row field has an input connection');
  final value = TextEditingValue.fromJSON(state);
  final sel = value.selection;
  final start = sel.isValid ? sel.start : value.text.length;
  final end = sel.isValid ? sel.end : value.text.length;
  final next = TextEditingValue(
    text: value.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
  tester.testTextInput.editingState = next.toJSON();
  tester.testTextInput.updateEditingValue(next);
}

/// Records every value the segment's reveal gate (its focus gate) and focus
/// node report from now on.
class Wi132FocusWatch {
  Wi132FocusWatch(WidgetTester tester, {int segment = 0})
    : _host = wi132Host(tester, segment) {
    _host.widget.revealGate.addListener(_onGate);
    _host.widget.focusNode.addListener(_onFocus);
    addTearDown(dispose);
  }

  final SegmentViewState _host;

  /// Every reveal gate value notified.
  final List<bool> gate = [];

  /// The segment node's `hasFocus` at each of its notifications.
  final List<bool> focus = [];

  void _onGate() => gate.add(_host.widget.revealGate.value);
  void _onFocus() => focus.add(_host.widget.focusNode.hasFocus);

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _host.widget.revealGate.removeListener(_onGate);
    _host.widget.focusNode.removeListener(_onFocus);
  }

  /// Expects the gate never flipped and the segment never lost focus.
  void expectSteady(String what) {
    expect(gate, isEmpty, reason: '$what: the focus gate never flips');
    expect(
      focus.where((f) => !f),
      isEmpty,
      reason: '$what: the segment keeps focus throughout',
    );
    expect(
      _host.widget.revealGate.value,
      isTrue,
      reason: '$what: the segment is focused',
    );
  }
}

/// [RowSpec] of row [row] of segment [segment].
RowSpec wi132Spec(WidgetTester tester, int row, {int segment = 0}) =>
    wi132Host(tester, segment).rowSpec(row)!;

/// The [LineBoxSource] of row [row] now.
LineBoxSource wi132Boxes(WidgetTester tester, int row, {int segment = 0}) =>
    rowBoxesOf(tester, segment, row);
