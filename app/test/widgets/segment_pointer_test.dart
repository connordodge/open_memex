// WI #170 (C3, Spec #157 R2, R26, R28; TD5, TD10, TD11; rulings D6, D8, D11;
// design pack design/156-live-preview/packs/170.md): mouse selection across
// one text segment's editor rows.
// - A drag from one row into others selects across them; Shift+click extends
//   the selection; a plain click places the caret; Cmd+A selects the whole
//   focused text segment.
// - Every touched row carries its slice (so markers reveal on its lines);
//   a line whose newline is selected ends in a one-column, full-line-height
//   newline mark, and a selected blank line is that mark alone (TD10's pure
//   `newlineMarks`).
// - Dragging near the editor page's top or bottom edge scrolls the page.
// - Excerpt cards and the Topics footer are boundaries (R28).
// - The gesture layer is in the rows' tap region group (D11).
// Every pointer test runs under macOS (TS7).
import 'dart:typed_data';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapTimeout, kPrecisePointerHitSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_pointer_layer.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';

/// A paragraph, three bullets and a last paragraph. Rows (segment offsets):
/// - 0 prose `para one` [0, 9), text [0, 8)
/// - 1 bullet `alpha` [9, 17), text [11, 16)
/// - 2 bullet `beta` [17, 24), text [19, 23)
/// - 3 bullet `gamma` [24, 32), text [26, 31)
/// - 4 prose `end` [32, 35)
const _wi170List = 'para one\n- alpha\n- beta\n- gamma\nend';

/// A card token: text segment 0, card 1, text segment 2.
const _wi170Token = fixtureRangeToken;

/// One mono column at the body size (pack #170): 8.1 px.
const double _wi170Col = 8.1;

/// A body or item line (R13): 13.5 x 1.7.
const double _wi170Line = 22.95;

Note _wi170Note(String content) => Note(
  id: 'topic-170',
  title: 'Pointer',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// Pumps a topic note's [SegmentedBody] holding [text] above a 40 px strip
/// (Key `wi170-outside`) outside every tap region. `onContentChanged` is fed
/// back as the content, as `EditorController` does.
Future<void> _wi170Pump(WidgetTester tester, String text) async {
  final content = ValueNotifier(text);
  addTearDown(content.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: content,
                  builder: (context, value, _) => SegmentedBody(
                    note: _wi170Note(value),
                    content: value,
                    savedVersion: 3,
                    onContentChanged: (joined) => content.value = joined,
                  ),
                ),
              ),
              const SizedBox(
                key: Key('wi170-outside'),
                height: 40,
                width: double.infinity,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Opens the fixture topic note holding [body] in the workspace (a vault is
/// open, so excerpt cards render).
Future<SegmentedEditorRobot> _wi170OpenTopic(
  WidgetTester tester,
  String body,
) async {
  final r = await launchSegmented(
    tester,
    vault: seedSegmentedVault(topicBody: body),
  );
  await r.open(fixtureTopicId);
  expect(r.segmentText(0), isNotEmpty);
  return r;
}

Finder _wi170Row(int s, int r) => find.byKey(Key('editor-row-$s-$r'));

Finder _wi170Marker(int s, int r) => find.byKey(Key('editor-row-marker-$s-$r'));

Finder _wi170FieldOf(int s, int r) =>
    find.descendant(of: _wi170Row(s, r), matching: find.byType(EditableText));

/// How many `editor-row-<s>-<r>` Keys segment [s] shows.
int _wi170RowCount(int s) => find
    .byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          RegExp('^editor-row-$s-\\d+\$').hasMatch(k.value);
    })
    .evaluate()
    .length;

LivePreviewController _wi170Ctrl(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(_wi170FieldOf(s, r)).controller
        as LivePreviewController;

RenderEditable _wi170Editable(WidgetTester tester, int s, int r) {
  final found = findRenderEditable(tester.renderObject(_wi170Row(s, r)));
  if (found == null) throw TestFailure('No RenderEditable in row $s-$r');
  return found;
}

/// A global point on segment [s]'s glyph at [offset]: just right of the
/// caret there, at the middle of its line, so the nearest offset is
/// [offset] (right of the last glyph at a line's end).
Offset _wi170At(WidgetTester tester, int s, int offset) {
  final caret = segmentEditingAt(tester, s).rectForOffset(offset);
  return Offset(caret.left + 2, caret.center.dy);
}

/// Focus row [s]-[r]'s field (without a pointer) and put its caret at
/// local [local] (default: the row text's end).
Future<void> _wi170FocusRow(
  WidgetTester tester,
  int s,
  int r, {
  int? local,
}) async {
  await tester.showKeyboard(_wi170Row(s, r));
  await tester.pump();
  final ctrl = _wi170Ctrl(tester, s, r);
  ctrl.selection = TextSelection.collapsed(offset: local ?? ctrl.text.length);
  await tester.pump();
}

/// Lets the double-click window pass, so the next click is a single click.
Future<void> _wi170PastDoubleClick(WidgetTester tester) =>
    tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));

/// Each row's selection in segment [s] is [slices] (row-local start and
/// end, in either direction); null for a row the selection doesn't reach
/// (no valid selection).
void _wi170ExpectSlices(WidgetTester tester, int s, List<(int, int)?> slices) {
  expect(_wi170RowCount(s), slices.length, reason: 'rows of segment $s');
  for (final (r, slice) in slices.indexed) {
    final selection = _wi170Ctrl(tester, s, r).selection;
    if (slice == null) {
      expect(
        selection.isValid,
        isFalse,
        reason: 'row $s-$r is untouched: $selection',
      );
    } else {
      expect(
        (selection.start, selection.end),
        slice,
        reason: 'row $s-$r slice: $selection',
      );
    }
  }
}

/// No row of segment [s] holds a non-collapsed selection.
void _wi170ExpectNoRange(WidgetTester tester, int s) {
  for (var r = 0; r < _wi170RowCount(s); r++) {
    final selection = _wi170Ctrl(tester, s, r).selection;
    expect(
      selection.isValid && !selection.isCollapsed,
      isFalse,
      reason: 'row $s-$r shows a range: $selection',
    );
  }
}

/// [color] is `OmColors.selection` as 8-bit ARGB (a focused field's
/// highlight paint carries it through float channels).
bool _wi170IsSelection(Color color) =>
    color.toARGB32() == OmColors.selection.toARGB32();

/// Every rect segment [s] paints in `OmColors.selection` (drawRect and
/// drawRRect outer rects), in global coordinates.
List<Rect> _wi170SelectionFills(WidgetTester tester, int s) {
  final root = tester.renderObject<RenderBox>(find.byKey(textSegmentKey(s)));
  final canvas = TestRecordingCanvas();
  root.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  var at = Offset.zero;
  final saved = <Offset>[];
  final out = <Rect>[];
  for (final call in canvas.invocations) {
    final i = call.invocation;
    final args = i.positionalArguments;
    switch (i.memberName) {
      case #save || #saveLayer:
        saved.add(at);
      case #restore:
        at = saved.removeLast();
      case #translate:
        at += Offset((args[0] as num).toDouble(), (args[1] as num).toDouble());
      case #transform:
        final m = Matrix4.fromFloat64List(args[0] as Float64List);
        at += Offset(m.getTranslation().x, m.getTranslation().y);
      case #drawRect when _wi170IsSelection((args[1] as Paint).color):
        out.add((args[0] as Rect).shift(at));
      case #drawRRect when _wi170IsSelection((args[1] as Paint).color):
        out.add((args[0] as RRect).outerRect.shift(at));
    }
  }
  return [for (final r in out) root.localToGlobal(r.topLeft) & r.size];
}

/// The newline marks segment [s] paints: selection fills one body column
/// wide and one body line tall, top to bottom.
List<Rect> _wi170Marks(WidgetTester tester, int s) => [
  for (final r in _wi170SelectionFills(tester, s))
    if ((r.width - _wi170Col).abs() < 0.3 &&
        (r.height - _wi170Line).abs() < 0.6)
      r,
]..sort((a, b) => a.top.compareTo(b.top));

/// The global rect a newline mark should have on line [line] of row
/// [s]-[r]: from the right end of the line's last glyph (the field's text
/// left on a blank line), one column wide, the line box's full height.
Rect _wi170ExpectedMark(WidgetTester tester, int s, int r, int line) {
  final e = _wi170Editable(tester, s, r);
  final boxes = RenderEditableLineBoxes(e);
  final box = boxes.lines[line];
  final double x;
  if (box.range.isCollapsed) {
    x = 0;
  } else {
    x = boxes.boxesFor(box.range).last.right;
  }
  final topLeft = e.localToGlobal(Offset(x, box.top));
  return Rect.fromLTWH(topLeft.dx, topLeft.dy, _wi170Col, box.bottom - box.top);
}

void _wi170ExpectRects(List<Rect> actual, List<Rect> expected) {
  expect(actual, hasLength(expected.length), reason: '$actual');
  for (final (i, rect) in expected.indexed) {
    final a = actual[i];
    expect(a.left, moreOrLessEquals(rect.left, epsilon: 1.0), reason: '$i x');
    expect(a.top, moreOrLessEquals(rect.top, epsilon: 0.5), reason: '$i top');
    expect(a.width, moreOrLessEquals(rect.width, epsilon: 0.3), reason: '$i w');
    expect(
      a.height,
      moreOrLessEquals(rect.height, epsilon: 0.5),
      reason: '$i height',
    );
  }
}

/// Rects equal to [expected] within 1e-6 on every side, in order.
void _wi170ExpectExact(List<Rect> actual, List<Rect> expected) {
  expect(actual, hasLength(expected.length), reason: '$actual');
  for (final (i, rect) in expected.indexed) {
    final a = actual[i];
    for (final (side, got, want) in [
      ('left', a.left, rect.left),
      ('top', a.top, rect.top),
      ('right', a.right, rect.right),
      ('bottom', a.bottom, rect.bottom),
    ]) {
      expect(got, moreOrLessEquals(want, epsilon: 1e-6), reason: '$i $side');
    }
  }
}

/// The editor page's scroll position.
ScrollPosition _wi170Scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(EditorPage),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// The editor page's viewport, in global coordinates.
Rect _wi170Viewport(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(EditorPage),
        matching: find.byType(Scrollable),
      )
      .first,
);

/// A built line at runtime (TD10 inputs), so the constructor runs.
NewlineMarkLine _wi170MarkLine({
  required int end,
  required bool breaks,
  required double top,
  required double height,
  required double endX,
  double columnWidth = _wi170Col,
}) => NewlineMarkLine(
  end: end,
  breaks: breaks,
  top: top,
  bottom: top + height,
  endX: endX,
  columnWidth: columnWidth,
);

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: drag across rows
  // -------------------------------------------------------------------------
  group('drag across rows (AC1)', () {
    testWidgets(
      'a mouse drag from inside a prose row to inside the second item row below selects the matching segment range and every row reports its slice',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        expect(segmentEditingAt(tester, 0).rowCount, 5);

        await tester.macDrag(_wi170At(tester, 0, 2), _wi170At(tester, 0, 22));

        final handle = segmentEditingAt(tester, 0);
        expect(
          handle.selection,
          const TextSelection(baseOffset: 2, extentOffset: 22),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 3), null, null]);
        // The drag focused the segment.
        expect(handle.focusedRow, isNotNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'the selection follows the pointer across rows while the drag is still down and shrinks back when it returns',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        final mouse = await tester.startGesture(
          _wi170At(tester, 0, 2),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        // Into the first item row: `alp|ha`.
        await mouse.moveTo(_wi170At(tester, 0, 14));
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 14),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 3), null, null, null]);

        // Further down: `gam|ma`.
        await mouse.moveTo(_wi170At(tester, 0, 29));
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 29),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 4), (0, 3), null]);

        // Back into the start row: the item rows lose their slices.
        await mouse.moveTo(_wi170At(tester, 0, 5));
        await tester.pump();
        await mouse.up();
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 5),
        );
        _wi170ExpectSlices(tester, 0, [(2, 5), null, null, null, null]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a mouse drag upward from an item row into the prose row above keeps the drag start as the selection base',
      (tester) async {
        await _wi170Pump(tester, _wi170List);

        await tester.macDrag(_wi170At(tester, 0, 22), _wi170At(tester, 0, 2));

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 22, extentOffset: 2),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 3), null, null]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag that ends over an item marker column extends to the start of that item text',
      (tester) async {
        await _wi170Pump(tester, _wi170List);

        await tester.macDrag(
          _wi170At(tester, 0, 2),
          tester.getCenter(_wi170Marker(0, 2)),
        );

        // The marker is display only: the selection stops at `beta`'s start.
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 19),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 0), null, null]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag or Shift click at an emoji on a row edge never lands inside the emoji',
      (tester) async {
        // Row 1 `thumbs 👍`: text [11, 20), the emoji [18, 20).
        const text = 'para one\n- thumbs 👍\nend';
        await _wi170Pump(tester, text);
        final field = tester.getRect(_wi170FieldOf(0, 1));

        // Past the row's end, right of the emoji.
        await tester.macDrag(
          _wi170At(tester, 0, 2),
          Offset(field.right - 4, field.center.dy),
        );
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 20),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 9), null]);

        // Shift+click on the emoji's glyph: before or after it, never
        // between its surrogates.
        await _wi170PastDoubleClick(tester);
        final e = _wi170Editable(tester, 0, 1);
        final glyph = e
            .getBoxesForSelection(
              const TextSelection(baseOffset: 7, extentOffset: 9),
            )
            .first
            .toRect();
        await tester.macClick(e.localToGlobal(glyph.center), shift: true);
        final selection = segmentEditingAt(tester, 0).selection;
        expect(selection.baseOffset, 2);
        expect(selection.extentOffset, anyOf(18, 20));
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click inside a row still selects the word under the pointer',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        final at = _wi170At(tester, 0, 13);

        await tester.macClick(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.macClick(at);

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 11, extentOffset: 16),
        );
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: Shift+click and plain click
  // -------------------------------------------------------------------------
  group('Shift click and plain click (AC2)', () {
    testWidgets(
      'Shift click in a later row extends the caret to the clicked offset and a plain click then collapses it to a caret there',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 2),
        );

        await tester.macClick(_wi170At(tester, 0, 29), shift: true);

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 29),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 4), (0, 3), null]);
        expect(segmentEditingAt(tester, 0).focusedRow, isNotNull);

        await _wi170PastDoubleClick(tester);
        await tester.macClick(_wi170At(tester, 0, 20));

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 20),
        );
        expect(segmentEditingAt(tester, 0).focusedRow, 2);
        _wi170ExpectNoRange(tester, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift click extends an existing cross row selection from its base backward and forward',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 2, local: 1);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 20, extentOffset: 29));
        await tester.pump();

        // Backward, into the prose row above: `para| one`.
        await tester.macClick(_wi170At(tester, 0, 4), shift: true);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 20, extentOffset: 4),
        );
        _wi170ExpectSlices(tester, 0, [(4, 8), (0, 5), (0, 1), null, null]);

        // Forward, into the last prose row: `e|nd`.
        await _wi170PastDoubleClick(tester);
        await tester.macClick(_wi170At(tester, 0, 33), shift: true);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 20, extentOffset: 33),
        );
        _wi170ExpectSlices(tester, 0, [null, null, (1, 4), (0, 5), (0, 1)]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a wikilink inside a cross row selection places the caret at the clicked offset',
      (tester) async {
        // Row 1 text `see [[Other note]] now` starts at 11.
        const text = 'para one\n- see [[Other note]] now\nend';
        await _wi170Pump(tester, text);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 2, extentOffset: 36));
        await tester.pump();

        // `see [[Ot|her`: segment offset 11 + 9.
        await tester.macClick(_wi170At(tester, 0, 20));

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 20),
        );
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        _wi170ExpectNoRange(tester, 0);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: Cmd+A
  // -------------------------------------------------------------------------
  group('Cmd A (AC3)', () {
    const text = '- a\n- b\n$_wi170Token\nplain\n- c';

    testWidgets(
      'Cmd A in an item row selects the whole text segment and nothing in the segment after the excerpt card',
      (tester) async {
        await _wi170OpenTopic(tester, text);
        expect(find.byKey(const Key('excerpt-card-1')), findsOneWidget);
        await _wi170FocusRow(tester, 0, 1, local: 1);
        final length = segmentEditingAt(tester, 0).text.length;

        await tester.macCmdChord(LogicalKeyboardKey.keyA);

        final first = segmentEditingAt(tester, 0);
        expect(
          first.selection,
          TextSelection(baseOffset: 0, extentOffset: length),
        );
        // Focus stays in the row.
        expect(first.focusedRow, 1);
        expect(
          _wi170Ctrl(tester, 0, 0).selection,
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        expect(
          _wi170Ctrl(tester, 0, 1).selection,
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        expect(segmentEditingAt(tester, 2).selection.isCollapsed, isTrue);
        _wi170ExpectNoRange(tester, 2);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd A in a prose row after an excerpt card selects only that text segment',
      (tester) async {
        await _wi170OpenTopic(tester, text);
        await _wi170FocusRow(tester, 2, 0, local: 2);
        final length = segmentEditingAt(tester, 2).text.length;

        await tester.macCmdChord(LogicalKeyboardKey.keyA);

        final last = segmentEditingAt(tester, 2);
        expect(
          last.selection,
          TextSelection(baseOffset: 0, extentOffset: length),
        );
        expect(last.focusedRow, 0);
        expect(
          _wi170Ctrl(tester, 2, 0).selection,
          const TextSelection(baseOffset: 0, extentOffset: 5),
        );
        expect(
          _wi170Ctrl(tester, 2, 1).selection,
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        _wi170ExpectNoRange(tester, 0);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: highlight, newline mark, blank line (TD10 geometry)
  // -------------------------------------------------------------------------
  group('newline mark geometry (AC4)', () {
    test(
      'a line whose newline is inside the selection gets a mark one column wide and the full line height at its end',
      () {
        final top = 2 * _wi170Line;
        final line = _wi170MarkLine(
          end: 8,
          breaks: true,
          top: top,
          height: _wi170Line,
          endX: 8 * _wi170Col,
        );
        _wi170ExpectExact(
          newlineMarks([line], const TextRange(start: 2, end: 22)),
          [Rect.fromLTWH(8 * _wi170Col, top, _wi170Col, _wi170Line)],
        );
      },
    );

    test('an H2 line mark is one H2 column wide and the H2 line tall', () {
      final width = newlineMarkWidth(2);
      final line = _wi170MarkLine(
        end: 8,
        breaks: true,
        top: 0,
        height: 34,
        endX: 81.6,
        columnWidth: width,
      );
      _wi170ExpectExact(
        newlineMarks([line], const TextRange(start: 0, end: 9)),
        [const Rect.fromLTWH(81.6, 0, 10.2, 34)],
      );
    });

    test('a soft wrapped line gets no mark even inside the selection', () {
      final line = _wi170MarkLine(
        end: 40,
        breaks: false,
        top: 0,
        height: _wi170Line,
        endX: 300,
      );
      expect(newlineMarks([line], const TextRange(start: 0, end: 90)), isEmpty);
    });

    test(
      'the line where the selection ends gets no mark when the selection stops at or before its newline',
      () {
        final line = _wi170MarkLine(
          end: 18,
          breaks: true,
          top: 0,
          height: _wi170Line,
          endX: 145.8,
        );
        expect(
          newlineMarks([line], const TextRange(start: 2, end: 18)),
          isEmpty,
          reason: 'selection ends right before the newline',
        );
        expect(
          newlineMarks([line], const TextRange(start: 2, end: 10)),
          isEmpty,
          reason: 'selection ends mid-line',
        );
      },
    );

    test(
      'a line whose newline is the first selected character gets a mark',
      () {
        final line = _wi170MarkLine(
          end: 8,
          breaks: true,
          top: _wi170Line,
          height: _wi170Line,
          endX: 64.8,
        );
        _wi170ExpectExact(
          newlineMarks([line], const TextRange(start: 8, end: 12)),
          [Rect.fromLTWH(64.8, _wi170Line, _wi170Col, _wi170Line)],
        );
      },
    );

    test(
      'a line before the selection start or a last line without a terminator gets no mark',
      () {
        final before = _wi170MarkLine(
          end: 8,
          breaks: true,
          top: 0,
          height: _wi170Line,
          endX: 64.8,
        );
        final last = _wi170MarkLine(
          end: 30,
          breaks: false,
          top: _wi170Line,
          height: _wi170Line,
          endX: 170.1,
        );
        expect(
          newlineMarks([before, last], const TextRange(start: 9, end: 30)),
          isEmpty,
        );
      },
    );

    test(
      'a selected blank line gets its mark at the text left at full line height',
      () {
        final top = _wi170Line;
        final blank = _wi170MarkLine(
          end: 9,
          breaks: true,
          top: top,
          height: _wi170Line,
          endX: 0,
        );
        _wi170ExpectExact(
          newlineMarks([blank], const TextRange(start: 2, end: 22)),
          [Rect.fromLTWH(0, top, _wi170Col, _wi170Line)],
        );
      },
    );

    test('a collapsed selection gives no marks', () {
      final line = _wi170MarkLine(
        end: 8,
        breaks: true,
        top: 0,
        height: _wi170Line,
        endX: 64.8,
      );
      expect(newlineMarks([line], const TextRange.collapsed(8)), isEmpty);
      expect(newlineMarks([line], const TextRange.collapsed(4)), isEmpty);
    });

    test(
      'marks come in line order for a selection over a wrapped paragraph a heading a blank line and an item',
      () {
        var y = 0.0;
        NewlineMarkLine next(
          int end,
          bool breaks,
          double height,
          double x, [
          double column = _wi170Col,
        ]) {
          final line = _wi170MarkLine(
            end: end,
            breaks: breaks,
            top: y,
            height: height,
            endX: x,
            columnWidth: column,
          );
          y += height;
          return line;
        }

        final lines = [
          next(20, false, _wi170Line, 600), // wrapped first line: no mark
          next(40, true, _wi170Line, 162), // paragraph end
          next(49, true, 34, 81.6, newlineMarkWidth(2)), // `## Notes`
          next(50, true, _wi170Line, 0), // blank line
          next(68, true, _wi170Line, 307.8), // item end
          next(80, true, _wi170Line, 97.2), // selection ends mid-line
        ];
        final top = [for (final l in lines) l.top];
        _wi170ExpectExact(
          newlineMarks(lines, const TextRange(start: 5, end: 75)),
          [
            Rect.fromLTWH(162, top[1], _wi170Col, _wi170Line),
            Rect.fromLTWH(81.6, top[2], 10.2, 34),
            Rect.fromLTWH(0, top[3], _wi170Col, _wi170Line),
            Rect.fromLTWH(307.8, top[4], _wi170Col, _wi170Line),
          ],
        );
      },
    );

    test(
      'newlineMarkWidth is one mono column at the font size of the line',
      () {
        for (final (level, width) in [
          (null, 8.1),
          (1, 12.0),
          (2, 10.2),
          (3, 9.0),
          (4, 8.1),
          (5, 8.1),
          (6, 8.1),
        ]) {
          expect(
            newlineMarkWidth(level),
            moreOrLessEquals(width, epsilon: 1e-9),
            reason: 'heading level $level',
          );
        }
      },
    );

    test('newlineMarkWidth rejects a heading level outside one to six', () {
      expect(() => newlineMarkWidth(0), throwsArgumentError);
      expect(() => newlineMarkWidth(7), throwsArgumentError);
    });
  });

  group('selection painting (AC4)', () {
    // Rows: prose `para one\n` + blank line [0, 10), bullet `alpha` text
    // [12, 17), bullet `beta` text [20, 24), prose `end` [25, 28).
    const text = 'para one\n\n- alpha\n- beta\nend';

    testWidgets(
      'a selection over a paragraph a blank line and two item rows paints a newline mark at the end of each line whose newline it holds',
      (tester) async {
        await _wi170Pump(tester, text);
        await _wi170FocusRow(tester, 0, 1, local: 0);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 2, extentOffset: 22));
        await tester.pump();

        // `para one` end, the blank line (at the text left), `alpha` end;
        // not `beta` (the selection ends mid-line) and not `end`.
        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 0),
          _wi170ExpectedMark(tester, 0, 0, 1),
          _wi170ExpectedMark(tester, 0, 1, 0),
        ]);
        expect(
          _wi170ExpectedMark(tester, 0, 0, 1).left,
          moreOrLessEquals(
            tester.getRect(_wi170FieldOf(0, 0)).left,
            epsilon: 1,
          ),
          reason: 'the blank line mark starts at the text left',
        );

        // The whole segment: `beta` ends in a mark too; the last line has
        // no newline.
        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection(baseOffset: 0, extentOffset: text.length));
        await tester.pump();
        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 0),
          _wi170ExpectedMark(tester, 0, 0, 1),
          _wi170ExpectedMark(tester, 0, 1, 0),
          _wi170ExpectedMark(tester, 0, 2, 0),
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection that stops at a line end or a caret paints no newline mark',
      (tester) async {
        await _wi170Pump(tester, text);
        await _wi170FocusRow(tester, 0, 0, local: 2);

        // A range in the first line ending right before its newline: no
        // mark, but a slice.
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 2, extentOffset: 8));
        await tester.pump();
        expect(_wi170Marks(tester, 0), isEmpty);
        expect(_wi170SelectionFills(tester, 0), isNotEmpty);

        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection.collapsed(offset: 15));
        await tester.pump();
        expect(_wi170Marks(tester, 0), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag across rows leaves every touched row painting its slice in the selection colour and untouched rows painting none',
      (tester) async {
        await _wi170Pump(tester, _wi170List);

        await tester.macDrag(_wi170At(tester, 0, 2), _wi170At(tester, 0, 22));

        for (final (r, slice) in [(0, (2, 8)), (1, (0, 5)), (2, (0, 3))]) {
          final e = _wi170Editable(tester, 0, r);
          final width = RenderEditableLineBoxes(
            e,
          ).boxesFor(TextRange(start: slice.$1, end: slice.$2)).single.width;
          expect(
            tester.renderObject(_wi170Row(0, r)),
            paints..something((method, args) {
              if (method != #drawRect) return false;
              final rect = args[0] as Rect;
              final paint = args[1] as Paint;
              return _wi170IsSelection(paint.color) &&
                  rect.height < 13.5 + 1 &&
                  (rect.width - width).abs() < 0.5;
            }),
            reason: 'row $r paints its slice, focused or not',
          );
        }
        for (final r in [3, 4]) {
          expect(
            tester.renderObject(_wi170Row(0, r)),
            isNot(
              paints..something(
                (method, args) =>
                    method == #drawRect &&
                    _wi170IsSelection((args[1] as Paint).color),
              ),
            ),
            reason: 'row $r is untouched',
          );
        }
        // The `para one` and `alpha` newlines are selected.
        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 0),
          _wi170ExpectedMark(tester, 0, 1, 0),
        ]);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: reveal on touched lines
  // -------------------------------------------------------------------------
  group('reveal on touched lines (AC5)', () {
    testWidgets(
      'with the segment focused a drag gives every touched row its slice under an open reveal gate and leaves untouched rows without one',
      (tester) async {
        // Rows: prose `para one` [0, 9); `alpha` text [11, 16); `beta`
        // [19, 23); `gamma` [26, 31); prose `last one\nlast two` from 32.
        const text = 'para one\n- alpha\n- beta\n- gamma\nlast one\nlast two';
        await _wi170Pump(tester, text);
        await _wi170FocusRow(tester, 0, 0, local: 0);
        await _wi170PastDoubleClick(tester);

        // `al|pha` to `last| one`.
        await tester.macDrag(_wi170At(tester, 0, 13), _wi170At(tester, 0, 36));

        final handle = segmentEditingAt(tester, 0);
        expect(
          handle.selection,
          const TextSelection(baseOffset: 13, extentOffset: 36),
        );
        expect(handle.focusedRow, isNotNull);
        _wi170ExpectSlices(tester, 0, [null, (2, 5), (0, 4), (0, 5), (0, 4)]);
        for (var r = 0; r < 5; r++) {
          expect(
            _wi170Ctrl(tester, 0, r).revealGate.value,
            isTrue,
            reason: 'row $r may reveal while the segment has focus',
          );
        }
        // The last prose row's second line is untouched: its slice stays on
        // the first line.
        expect(
          _wi170Ctrl(tester, 0, 4).selection.end,
          lessThanOrEqualTo('last one'.length),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: auto-scroll
  // -------------------------------------------------------------------------
  group('auto-scroll (AC6)', () {
    // `intro`, 50 bullets `item NN`, `outro`: far taller than the page.
    final text = [
      'intro',
      for (var i = 0; i < 50; i++) '- item ${i.toString().padLeft(2, '0')}',
      'outro',
    ].join('\n');

    /// The segment offset of each row's text start and end, from the core.
    List<RowSpec> rows() => splitRows(text, atSegmentStart: true);

    testWidgets(
      'dragging into the bottom edge zone of the editor page scrolls it down while the selection keeps extending',
      (tester) async {
        await _wi170Pump(tester, text);
        final viewport = _wi170Viewport(tester);
        expect(_wi170Scroll(tester).pixels, 0);
        // The last row whose text is fully on screen before the drag.
        final visible = rows().lastWhere(
          (row) =>
              segmentEditingAt(tester, 0).rectForOffset(row.textEnd).bottom <=
              viewport.bottom,
        );
        final from = _wi170At(tester, 0, rows()[2].textStart + 2);

        final mouse = await tester.startGesture(
          from,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        final edge = Offset(from.dx, viewport.bottom - 2);
        for (var i = 1; i <= 4; i++) {
          await mouse.moveTo(Offset.lerp(from, edge, i / 4)!);
          await tester.pump();
        }
        // Hold still in the edge zone.
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(_wi170Scroll(tester).pixels, greaterThan(0));
        final held = segmentEditingAt(tester, 0).selection;
        expect(held.baseOffset, rows()[2].textStart + 2);
        expect(
          held.extentOffset,
          greaterThan(visible.end),
          reason: 'the selection extends to rows scrolled into view',
        );

        await mouse.up();
        await tester.pump();
        final stopped = _wi170Scroll(tester).pixels;
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          _wi170Scroll(tester).pixels,
          stopped,
          reason: 'the page stops when the drag ends',
        );
        expect(segmentEditingAt(tester, 0).selection, held);
      },
      variant: macOnly,
    );

    testWidgets(
      'dragging into the top edge zone of the editor page scrolls it up while the selection keeps extending',
      (tester) async {
        await _wi170Pump(tester, text);
        _wi170Scroll(tester).jumpTo(400);
        await tester.pump();
        final viewport = _wi170Viewport(tester);
        // The first row whose text is fully on screen before the drag.
        final visible = rows().firstWhere(
          (row) =>
              segmentEditingAt(tester, 0).rectForOffset(row.textStart).top >=
              viewport.top,
        );
        // A row in the middle of the page.
        final middle = rows().firstWhere(
          (row) =>
              segmentEditingAt(tester, 0).rectForOffset(row.textStart).top >=
              viewport.center.dy,
        );
        final from = _wi170At(tester, 0, middle.textStart + 2);

        final mouse = await tester.startGesture(
          from,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        final edge = Offset(from.dx, viewport.top + 2);
        for (var i = 1; i <= 4; i++) {
          await mouse.moveTo(Offset.lerp(from, edge, i / 4)!);
          await tester.pump();
        }
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(_wi170Scroll(tester).pixels, lessThan(400));
        final held = segmentEditingAt(tester, 0).selection;
        expect(held.baseOffset, middle.textStart + 2);
        expect(
          held.extentOffset,
          lessThan(visible.start),
          reason: 'the selection extends to rows scrolled into view',
        );
        await mouse.up();
        await tester.pump();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: boundaries
  // -------------------------------------------------------------------------
  group('segment boundaries (AC7)', () {
    const text = '- a\n- b\n$_wi170Token\nplain\n- c';

    testWidgets(
      'a drag from an item row into the excerpt card below or past it into the next text segment clamps the selection to the segment end',
      (tester) async {
        await _wi170OpenTopic(tester, text);
        final length = segmentEditingAt(tester, 0).text.length;
        final card = find.byKey(const Key('excerpt-card-1'));
        expect(card, findsOneWidget);

        await tester.macDrag(_wi170At(tester, 0, 2), tester.getCenter(card));
        expect(
          segmentEditingAt(tester, 0).selection,
          TextSelection(baseOffset: 2, extentOffset: length),
        );
        _wi170ExpectNoRange(tester, 2);

        // Past the card, into the next segment's last row.
        await _wi170PastDoubleClick(tester);
        await tester.macDrag(
          _wi170At(tester, 0, 2),
          _wi170At(tester, 2, segmentEditingAt(tester, 2).text.length),
        );
        expect(
          segmentEditingAt(tester, 0).selection,
          TextSelection(baseOffset: 2, extentOffset: length),
        );
        expect(segmentEditingAt(tester, 2).selection.isCollapsed, isTrue);
        _wi170ExpectNoRange(tester, 2);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag from a prose row up into the excerpt card above clamps the selection to the segment start',
      (tester) async {
        await _wi170OpenTopic(tester, text);
        final card = find.byKey(const Key('excerpt-card-1'));

        // `pl|ain`.
        await tester.macDrag(_wi170At(tester, 2, 2), tester.getCenter(card));

        expect(
          segmentEditingAt(tester, 2).selection,
          const TextSelection(baseOffset: 2, extentOffset: 0),
        );
        _wi170ExpectNoRange(tester, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag from the person text into the Topics footer clamps the selection to the segment end',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);
        final length = r.segmentText(0).length;
        expect(r.segmentText(0), startsWith('Fixed the jump arc.'));
        final footer = find.byKey(const Key('footer-chip-row'));
        expect(footer, findsOneWidget);
        final rect = tester.getRect(footer);
        // The footer and the person text are both on screen.
        expect(rect.bottom, lessThan(tester.view.physicalSize.height));
        expect(_wi170At(tester, 0, 2).dy, greaterThan(0));

        await tester.macDrag(
          _wi170At(tester, 0, 2),
          Offset(rect.left + 10, rect.center.dy),
        );

        expect(
          r.segmentSelection(0),
          TextSelection(baseOffset: 2, extentOffset: length),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: the gesture layer is in the rows' tap region
  // -------------------------------------------------------------------------
  group('tap region (AC8)', () {
    testWidgets(
      'a pointer down on the gesture layer below the rows keeps the focused row focused and a drag from there selects up into the rows',
      (tester) async {
        // Rows: prose `a` [0, 2), bullet `b` text [4, 5); 12 lines tall.
        await _wi170Pump(tester, 'a\n- b');
        await _wi170FocusRow(tester, 0, 1);
        final node = FocusManager.instance.primaryFocus;
        final segment = tester.getRect(find.byKey(textSegmentKey(0)));
        final below = Offset(segment.left + 200, segment.bottom - 20);
        expect(
          below.dy,
          greaterThan(tester.getRect(_wi170FieldOf(0, 1)).bottom),
        );

        final mouse = await tester.startGesture(
          below,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(segmentEditingAt(tester, 0).focusedRow, 1);

        await mouse.moveTo(_wi170At(tester, 0, 0));
        await tester.pump();
        await mouse.up();
        await tester.pump();

        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, isNotNull);
        expect(
          handle.selection,
          const TextSelection(baseOffset: 5, extentOffset: 0),
        );
        _wi170ExpectSlices(tester, 0, [(0, 1), (0, 1)]);

        // Control: a click outside every tap region does unfocus the rows.
        await _wi170PastDoubleClick(tester);
        await tester.tapAt(
          tester.getCenter(find.byKey(const Key('wi170-outside'))),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'the mouse shows the text cursor over a row text with the gesture layer in place',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        for (final offset in [3, 13, 33]) {
          expect(
            await tester.macCursorAt(_wi170At(tester, 0, offset)),
            SystemMouseCursors.text,
            reason: 'offset $offset',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'the mouse shows the text cursor over an item marker column and the empty area below the rows',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        final segment = tester.getRect(find.byKey(textSegmentKey(0)));
        final lastRow = tester.getRect(_wi170Row(0, 4));
        expect(segment.bottom - lastRow.bottom, greaterThan(40));
        for (final (what, at) in [
          ('marker column', tester.getCenter(_wi170Marker(0, 2))),
          ('empty area', Offset(segment.left + 200, segment.bottom - 20)),
        ]) {
          expect(
            await tester.macCursorAt(at),
            SystemMouseCursors.text,
            reason: what,
          );
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Contracts the layer documents (verify): Cmd press, Shift drag, focus
  // re-assert, row filter, repaint, heading marks, auto-scroll speed.
  // -------------------------------------------------------------------------
  group('documented layer contracts (verify)', () {
    testWidgets(
      'a Cmd press and drag from a row is left to the row and never selects across rows',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 2, local: 1);
        await _wi170PastDoubleClick(tester);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 20),
        );

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final mouse = await tester.startGesture(
            _wi170At(tester, 0, 2),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          for (var i = 1; i <= 4; i++) {
            await mouse.moveTo(
              Offset.lerp(
                _wi170At(tester, 0, 2),
                _wi170At(tester, 0, 29),
                i / 4,
              )!,
            );
            await tester.pump();
          }
          await mouse.up();
          await tester.pump();
        });

        final selection = segmentEditingAt(tester, 0).selection;
        expect(
          selection.end,
          lessThan(24),
          reason:
              'the layer never extends a Cmd drag into the gamma row: '
              '$selection',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a Shift drag keeps extending the selection from its base after the Shift press',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        await _wi170PastDoubleClick(tester);

        await tester.macHolding([LogicalKeyboardKey.shiftLeft], () async {
          final mouse = await tester.startGesture(
            _wi170At(tester, 0, 13),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          expect(
            segmentEditingAt(tester, 0).selection,
            const TextSelection(baseOffset: 2, extentOffset: 13),
          );
          await mouse.moveTo(_wi170At(tester, 0, 29));
          await tester.pump();
          expect(
            segmentEditingAt(tester, 0).selection,
            const TextSelection(baseOffset: 2, extentOffset: 29),
          );
          await mouse.up();
          await tester.pump();
        });

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 2, extentOffset: 29),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 4), (0, 3), null]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Shift click with no row focused focuses a row and keeps the extended range',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        await _wi170PastDoubleClick(tester);
        // Unfocus the rows; the caret stays at 2.
        await tester.tapAt(
          tester.getCenter(find.byKey(const Key('wi170-outside'))),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(segmentEditingAt(tester, 0).selection.baseOffset, 2);
        await _wi170PastDoubleClick(tester);

        await tester.macClick(_wi170At(tester, 0, 29), shift: true);
        await tester.pump();

        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, isNotNull);
        expect(
          handle.selection,
          const TextSelection(baseOffset: 2, extentOffset: 29),
        );
        _wi170ExpectSlices(tester, 0, [(2, 8), (0, 5), (0, 4), (0, 3), null]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection that starts at a row newline paints that row newline mark',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        // From the `para one` newline (8) into `beta`.
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 8, extentOffset: 21));
        await tester.pump();

        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 0),
          _wi170ExpectedMark(tester, 0, 1, 0),
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'the newline marks repaint when the segment selection or the reveal gate changes',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        final marks = tester.allRenderObjects
            .where((o) => o.runtimeType.toString() == '_RenderNewlineMarks')
            .single;
        expect(marks.debugNeedsPaint, isFalse);

        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 2, extentOffset: 22));
        expect(
          marks.debugNeedsPaint,
          isTrue,
          reason: 'a new selection moves the marks',
        );
        await tester.pump();
        expect(marks.debugNeedsPaint, isFalse);

        // Unfocusing the segment closes its reveal gate.
        FocusManager.instance.primaryFocus!.unfocus();
        await tester.idle();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(
          marks.debugNeedsPaint,
          isTrue,
          reason: 'a closed reveal gate moves line ends',
        );
        await tester.pump();
      },
      variant: macOnly,
    );

    testWidgets(
      'a selected H2 line ends in a mark one H2 column wide and the H2 line tall',
      (tester) async {
        // Prose `## Notes\nbody`.
        await _wi170Pump(tester, '## Notes\nbody');
        await _wi170FocusRow(tester, 0, 0, local: 0);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 0, extentOffset: 11));
        await tester.pump();

        final h2 = [
          for (final r in _wi170SelectionFills(tester, 0))
            if ((r.width - 10.2).abs() < 0.3) r,
        ];
        expect(h2, hasLength(1), reason: '${_wi170SelectionFills(tester, 0)}');
        expect(h2.single.height, moreOrLessEquals(34, epsilon: 0.5));
        expect(_wi170Marks(tester, 0), isEmpty, reason: 'no body-size mark');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Auto-scroll zone and speed (verify)
  // -------------------------------------------------------------------------
  group('auto-scroll zone and speed (verify)', () {
    final text = [
      'intro',
      for (var i = 0; i < 50; i++) '- item ${i.toString().padLeft(2, '0')}',
      'outro',
    ].join('\n');

    /// Presses at the third row, moves past the slop, then to [dy] (global)
    /// and holds still for [frames] 16 ms frames. Returns the page scroll
    /// the hold added.
    Future<double> holdAt(
      WidgetTester tester,
      double Function(Rect viewport) dy, {
      int frames = 10,
      double startScroll = 0,
    }) async {
      await _wi170Pump(tester, text);
      if (startScroll != 0) {
        _wi170Scroll(tester).jumpTo(startScroll);
        await tester.pump();
      }
      final viewport = _wi170Viewport(tester);
      final rows = splitRows(text, atSegmentStart: true);
      final middle = rows.firstWhere(
        (row) =>
            segmentEditingAt(tester, 0).rectForOffset(row.textStart).top >=
            viewport.center.dy,
      );
      final from = _wi170At(tester, 0, middle.textStart + 2);
      final mouse = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(from + const Offset(0, 6));
      await tester.pump();
      await mouse.moveTo(Offset(from.dx, dy(viewport)));
      await tester.pump();
      final before = _wi170Scroll(tester).pixels;
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final added = _wi170Scroll(tester).pixels - before;
      await mouse.up();
      await tester.pump();
      return added;
    }

    testWidgets(
      'a drag held just outside the edge zone does not scroll the page',
      (tester) async {
        expect(await holdAt(tester, (v) => v.bottom - 42), 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'the page scrolls at a speed that grows linearly from the zone edge to the page edge',
      (tester) async {
        // 1200 px/s x (1 - 20 / 40) for 10 frames of 16 ms: 96 px.
        expect(
          await holdAt(tester, (v) => v.bottom - 20),
          moreOrLessEquals(96, epsilon: 1),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the page scrolls at full speed with the drag at or past the page bottom edge',
      (tester) async {
        // 1200 px/s for 10 frames of 16 ms: 192 px, capped past the edge.
        expect(
          await holdAt(tester, (v) => v.bottom + 20),
          moreOrLessEquals(192, epsilon: 1),
        );
      },
      variant: macOnly,
    );

    testWidgets('the page scrolls up at the same speed in the top edge zone', (
      tester,
    ) async {
      expect(
        await holdAt(tester, (v) => v.top + 20, startScroll: 400),
        moreOrLessEquals(-96, epsilon: 1),
      );
    }, variant: macOnly);

    testWidgets(
      'auto-scroll stops at the end of the page and the selection reaches the segment end',
      (tester) async {
        await holdAt(tester, (v) => v.bottom - 2, frames: 150);
        final position = _wi170Scroll(tester);
        expect(position.pixels, position.maxScrollExtent);
        expect(position.maxScrollExtent, greaterThan(0));
        expect(segmentEditingAt(tester, 0).selection.extentOffset, text.length);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Gate r1 MUTATION survivors (verify): leading frontmatter rows, the drag
  // slop boundary, CRLF line ends and soft wraps.
  // -------------------------------------------------------------------------
  group('frontmatter rows, drag slop and line ends (verify)', () {
    // Leading frontmatter holding a `- a` line. Split at the segment start
    // (A1), it is two rows: prose `---\n- a\n---\nbody` text [0, 16) and
    // bullet `b` text [19, 20). Split as if mid segment, `- a` would be an
    // item row of its own (four rows).
    const frontmatter = '---\n- a\n---\nbody\n- b';

    testWidgets(
      'a Shift click with no row focused under leading frontmatter focuses the clicked item row',
      (tester) async {
        await _wi170Pump(tester, frontmatter);
        expect(segmentEditingAt(tester, 0).rowCount, 2);
        await _wi170FocusRow(tester, 0, 0, local: 13);
        await _wi170PastDoubleClick(tester);
        await tester.tapAt(
          tester.getCenter(find.byKey(const Key('wi170-outside'))),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(segmentEditingAt(tester, 0).selection.baseOffset, 13);
        await _wi170PastDoubleClick(tester);

        await tester.macClick(_wi170At(tester, 0, 19), shift: true);
        await tester.pump();

        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, 1);
        expect(
          handle.selection,
          const TextSelection(baseOffset: 13, extentOffset: 19),
        );
        _wi170ExpectSlices(tester, 0, [(13, 16), (0, 0)]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection over the newline after leading frontmatter paints that line newline mark',
      (tester) async {
        await _wi170Pump(tester, frontmatter);
        expect(segmentEditingAt(tester, 0).rowCount, 2);
        await _wi170FocusRow(tester, 0, 1, local: 0);
        // `b|ody` through the end of `b`: the `body` newline (16) is in.
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 13, extentOffset: 20));
        await tester.pump();

        final lines = RenderEditableLineBoxes(
          _wi170Editable(tester, 0, 0),
        ).lines;
        expect(lines, hasLength(4), reason: 'the frontmatter row lines');
        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 3),
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a mouse move of exactly the precise pointer slop is still a click and one past it starts a drag',
      (tester) async {
        await _wi170Pump(tester, _wi170List);
        final handle = segmentEditingAt(tester, 0);
        final e = _wi170Editable(tester, 0, 0);
        // The first x (in quarter pixels) over the `o` in `para one` where
        // the nearest offset turns from 5 to 6.
        final before = handle.rectForOffset(5);
        final y = before.center.dy;
        var flip = before.left.floorToDouble();
        while (e.getPositionForPoint(Offset(flip, y)).offset < 6) {
          flip += 0.25;
          expect(flip, lessThan(handle.rectForOffset(6).right));
        }
        expect(e.getPositionForPoint(Offset(flip - 1, y)).offset, 5);
        // Half a pixel before the flip: a move of exactly the slop (exact
        // in binary) ends half a pixel past it, over offset 6.
        final x = flip - 0.5;

        final mouse = await tester.startGesture(
          Offset(x, y),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 5),
        );

        await mouse.moveTo(Offset(x + kPrecisePointerHitSlop, y));
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 5),
          reason: 'a move of exactly the slop does not start a drag',
        );

        await mouse.moveTo(Offset(x + kPrecisePointerHitSlop + 0.5, y));
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 5, extentOffset: 6),
          reason: 'past the slop the drag selects to the pointer',
        );
        await mouse.up();
        await tester.pump();
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection over CRLF line ends paints a newline mark at the end of each row whose CRLF it holds',
      (tester) async {
        // Rows: prose `para one` [0, 8) + CRLF, bullet `alpha` text
        // [12, 17) + CRLF, prose `end` [19, 22).
        const text = 'para one\r\n- alpha\r\nend';
        await _wi170Pump(tester, text);
        expect(segmentEditingAt(tester, 0).rowCount, 3);
        await _wi170FocusRow(tester, 0, 0, local: 2);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 2, extentOffset: 20));
        await tester.pump();

        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, 0),
          _wi170ExpectedMark(tester, 0, 1, 0),
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection over a soft wrapped paragraph paints a newline mark only at its newline and none at a wrap',
      (tester) async {
        final paragraph = List.filled(40, 'wrapping').join(' ');
        final text = '$paragraph\n- alpha';
        await _wi170Pump(tester, text);
        expect(segmentEditingAt(tester, 0).rowCount, 2);
        await _wi170FocusRow(tester, 0, 1, local: 0);
        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection(baseOffset: 0, extentOffset: text.length));
        await tester.pump();

        final lines = RenderEditableLineBoxes(
          _wi170Editable(tester, 0, 0),
        ).lines;
        expect(lines.length, greaterThan(1), reason: 'the paragraph wraps');
        _wi170ExpectRects(_wi170Marks(tester, 0), [
          _wi170ExpectedMark(tester, 0, 0, lines.length - 1),
        ]);
      },
      variant: macOnly,
    );
  });
}
