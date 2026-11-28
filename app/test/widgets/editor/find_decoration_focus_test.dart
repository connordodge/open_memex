// WI #84 (#61 F4, ruling D7), fix round 1. Three seams the first round left
// open:
//
// - A find decoration fire notifies every listener of a row controller. The
//   segment view listens to each row to rebuild its selection from the
//   focused row, so an unchanged-value notification must leave a cross-row
//   selection alone (a match recompute with a multi-row selection held).
// - `layoutDecorations(findReveal:)`: a fenced block or table the find reveal
//   range touches outsets (code box) or gains pills (table) whatever the
//   segment's focus, beside the focused selection, as the spans reveal it.
// - The same through the pumped decorations while the segment is focused.
//
// Geometry comes from fake line boxes (pure layout) or from a pumped field's
// own line boxes (widget), never constants.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';

/// `[start, end)` of the [nth] occurrence of [needle] in [text].
TextRange _w84Range(String text, String needle, {int nth = 0}) {
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
    expect(at, isNonNegative, reason: 'fixture holds "$needle" #$i');
  }
  return TextRange(start: at, end: at + needle.length);
}

/// A [LineBoxSource] with one 20 px tall visual line per source line and 8 px
/// per character.
class _W84Boxes implements LineBoxSource {
  _W84Boxes(this.text) {
    var start = 0;
    var top = 0.0;
    for (final line in text.split('\n')) {
      _lines.add(
        LineBox(
          range: TextRange(start: start, end: start + line.length),
          top: top,
          bottom: top + 20,
        ),
      );
      start += line.length + 1;
      top += 20;
    }
  }

  final String text;
  final List<LineBox> _lines = [];

  @override
  RenderBox get box => throw UnimplementedError('the fake has no render box');

  @override
  List<LineBox> get lines => List.unmodifiable(_lines);

  @override
  List<Rect> boxesFor(TextRange range) => [
    for (final line in _lines)
      if (_overlap(range, line) case (final s, final e))
        Rect.fromLTRB(s * 8.0, line.top, e * 8.0, line.bottom),
  ];

  static (int, int)? _overlap(TextRange range, LineBox line) {
    final s = range.start > line.range.start ? range.start : line.range.start;
    final e = range.end < line.range.end ? range.end : line.range.end;
    return s < e ? (s, e) : null;
  }

  @override
  Rect caretRect(int offset) => throw UnimplementedError();

  @override
  int offsetAt(Offset point) => throw UnimplementedError();

  @override
  LineBox lineAt(int offset) => lineHolding(_lines, offset);
}

List<PaintedDecoration> _w84Layout(
  String text, {
  TextSelection? reveal,
  TextRange? findReveal,
}) => layoutDecorations(
  text: text,
  boxes: _W84Boxes(text),
  columnLeft: 0,
  columnRight: 300,
  reveal: reveal,
  findReveal: findReveal,
);

List<double> _w84BoxHeights(List<PaintedDecoration> all) => [
  for (final d in all)
    if (d.kind == DecorationKind.codeBox) d.rect.height,
];

TextStyle _w84Base() =>
    OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);

/// The heights of every filled surface1 rounded rect (the code boxes) a
/// pumped [LivePreviewDecorations] paints, top to bottom.
List<double> _w84PaintedBoxHeights(WidgetTester tester) {
  final heights = <double>[];
  final pattern = paints
    ..something((method, args) {
      if (method != #drawRRect) return false;
      final paint = args[1] as Paint;
      if (paint.style == PaintingStyle.fill &&
          paint.color.toARGB32() == OmColors.surface1.toARGB32()) {
        heights.add((args[0] as RRect).height);
      }
      return false;
    });
  // The pattern never matches (the callback always declines): it is only a
  // way to visit every recorded call.
  (pattern as Matcher).matches(
    tester.renderObject(find.byType(LivePreviewDecorations)),
    <dynamic, dynamic>{},
  );
  return heights;
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // A decoration fire keeps a cross-row selection
  // -------------------------------------------------------------------------
  group('segment selection under a find decoration fire', () {
    Future<
      ({
        SegmentViewState state,
        List<LivePreviewController> rows,
        List<FocusNode> nodes,
        TextEditingController controller,
      })
    >
    pump(WidgetTester tester, String text) async {
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final gate = ValueNotifier(true);
      addTearDown(gate.dispose);
      final rows = <LivePreviewController>[];
      final nodes = <FocusNode>[];
      await pumpEditorScoped(
        tester,
        MaterialApp(
          home: Scaffold(
            body: SegmentView(
              index: 0,
              controller: controller,
              focusNode: focus,
              revealGate: gate,
              minLines: 1,
              hintText: null,
              onChanged: () {},
              onRowRemoved: (_) {},
              fieldBuilder: (context, row) {
                if (!rows.contains(row.controller)) {
                  rows.add(row.controller);
                  nodes.add(row.focusNode);
                }
                return TextField(
                  controller: row.controller,
                  focusNode: row.focusNode,
                  maxLines: null,
                );
              },
              builder: (context, r, b) => r,
            ),
          ),
        ),
      );
      return (
        state: tester.state<SegmentViewState>(find.byType(SegmentView)),
        rows: rows,
        nodes: nodes,
        controller: controller,
      );
    }

    testWidgets(
      'a find decoration fire leaves a cross row segment selection and the focused row unchanged',
      (tester) async {
        const text = 'abc\n```\ncode\n```\ndef';
        final p = await pump(tester, text);
        expect(p.rows.length, greaterThan(1), reason: 'prose and a code row');
        p.nodes.first.requestFocus();
        await tester.pump();
        // A selection from inside the first row to inside the code row.
        const held = TextSelection(baseOffset: 1, extentOffset: 18);
        p.state.select(held);
        await tester.pump();
        expect(p.state.selection, held, reason: 'the selection is held');
        final focused = p.state.focusedRow;

        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        for (final c in p.rows) {
          c.findDecoration = n;
        }
        n.value = const FindDecoration(
          revealRange: TextRange(start: 0, end: 1),
          inkRanges: [TextRange(start: 0, end: 1)],
          current: TextRange(start: 0, end: 1),
        );
        await tester.pump();
        expect(p.state.selection, held, reason: 'a fire keeps the selection');
        expect(p.state.focusedRow, focused, reason: 'and the focused row');

        // A second, different fire and a clear leave it too.
        n.value = const FindDecoration(
          inkRanges: [TextRange(start: 14, end: 16)],
        );
        await tester.pump();
        n.value = null;
        await tester.pump();
        expect(p.state.selection, held, reason: 'every fire keeps it');
        expect(p.controller.text, text, reason: 'no text change');
      },
    );

    testWidgets(
      'a typed change in a row still reaches the segment after a find decoration fire',
      (tester) async {
        final p = await pump(tester, 'abc\n```\ncode\n```\ndef');
        p.nodes.first.requestFocus();
        await tester.pump();
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        for (final c in p.rows) {
          c.findDecoration = n;
        }
        n.value = const FindDecoration(
          inkRanges: [TextRange(start: 0, end: 1)],
        );
        await tester.pump();

        // The guard skips a notification whose value did not change, never a
        // real edit: a typed character is applied to the segment text.
        final row = p.rows.first;
        row.value = const TextEditingValue(
          text: 'abXc',
          selection: TextSelection.collapsed(offset: 3),
        );
        await tester.pump();
        expect(p.controller.text, startsWith('abXc\n'));
        expect(p.state.selection, const TextSelection.collapsed(offset: 3));
      },
    );
  });

  // -------------------------------------------------------------------------
  // layoutDecorations(findReveal:)
  // -------------------------------------------------------------------------
  group('layoutDecorations find reveal', () {
    const text = 'intro\n```\nlet a = 1;\n```\nafter';
    final block = TextRange(
      start: text.indexOf('```'),
      end: text.indexOf('```\nafter') + 3,
    );

    test(
      'a find reveal range touches a fenced block from its start through its end and no further',
      () {
        final b = _W84Boxes(text);
        final top = b.lines[1].top;
        final bottom = b.lines[3].bottom;
        Rect box(TextRange? range, {TextSelection? reveal}) {
          final boxes = _w84Layout(
            text,
            findReveal: range,
            reveal: reveal,
          ).where((d) => d.kind == DecorationKind.codeBox);
          expect(boxes, hasLength(1));
          return boxes.single.rect;
        }

        final rest = Rect.fromLTRB(0, top, 300, bottom);
        final out = Rect.fromLTRB(0, top - 8, 300, bottom + 8);
        expect(box(null), rest, reason: 'no range');
        expect(
          box(TextRange(start: block.start, end: block.start)),
          out,
          reason: 'a caret at the opening fence start',
        );
        expect(
          box(TextRange(start: block.end, end: block.end)),
          out,
          reason: 'a caret at the closing fence end',
        );
        expect(
          box(_w84Range(text, 'a = 1')),
          out,
          reason: 'a range on the code line',
        );
        expect(
          box(TextRange(start: block.start - 1, end: block.start - 1)),
          rest,
          reason: 'the intro line end, one before the block',
        );
        expect(
          box(TextRange(start: 0, end: block.start - 1)),
          rest,
          reason: 'a range ending one before the block',
        );
        expect(
          box(TextRange(start: block.end + 1, end: text.length)),
          rest,
          reason: 'a range starting one after the block',
        );
        expect(
          box(const TextRange(start: -1, end: 99)),
          rest,
          reason: 'an invalid range reveals nothing',
        );
        expect(
          box(const TextRange(start: 99, end: -1)),
          rest,
          reason: 'an invalid reversed range reveals nothing',
        );
        expect(
          box(
            _w84Range(text, 'after'),
            reveal: TextSelection.collapsed(offset: block.start),
          ),
          out,
          reason: 'the selection alone still reveals',
        );
      },
    );

    test(
      'a find reveal range and the focused selection each reveal their own fenced block',
      () {
        const two =
            'intro\n```\nlet a = 1;\n```\nmid\n```\nlet b = 2;\n```\nafter';
        final b = _W84Boxes(two);
        double height(int open, int close) =>
            b.lines[close].bottom - b.lines[open].top;
        final a = height(1, 3);
        final c = height(5, 7);
        expect(a, c, reason: 'the blocks are alike');

        List<double> heights({TextSelection? reveal, TextRange? find}) =>
            _w84BoxHeights(_w84Layout(two, reveal: reveal, findReveal: find));

        expect(heights(), [a, c], reason: 'nothing reveals');
        expect(heights(find: _w84Range(two, 'b = 2')), [
          a,
          c + 16,
        ], reason: 'the find range reveals its block only');
        expect(
          heights(reveal: TextSelection.collapsed(offset: two.indexOf('a ='))),
          [a + 16, c],
          reason: 'the selection reveals its block only',
        );
        expect(
          heights(
            reveal: TextSelection.collapsed(offset: two.indexOf('a =')),
            find: _w84Range(two, 'b = 2'),
          ),
          [a + 16, c + 16],
          reason: 'the focused caret on block A, the find range on block B',
        );
        expect(
          heights(
            reveal: const TextSelection.collapsed(offset: -1),
            find: _w84Range(two, 'b = 2'),
          ),
          [a, c + 16],
          reason: 'a focused segment whose caret is in another row',
        );
      },
    );

    test(
      'a find reveal range touching a table adds the pills of every table line and one beyond it adds none',
      () {
        const table =
            'intro\n| `a` | b |\n|---|---|\n| c | `d` |\n| `e` | f |\nafter';
        List<PaintedDecoration> pills({
          TextSelection? reveal,
          TextRange? find,
        }) => _w84Layout(
          table,
          reveal: reveal,
          findReveal: find,
        ).where((d) => d.kind == DecorationKind.codePill).toList();
        final start = table.indexOf('| `a`');
        final end = table.indexOf('\nafter');

        expect(pills(), isEmpty, reason: 'a table at rest has no pills');
        expect(
          pills(find: _w84Range(table, 'f')),
          hasLength(3),
          reason: 'a range on the last line pills a, d and e',
        );
        expect(
          pills(
            find: TextRange(start: start, end: start),
          ),
          hasLength(3),
          reason: 'a caret at the table start',
        );
        expect(
          pills(
            find: TextRange(start: end, end: end),
          ),
          hasLength(3),
          reason: 'a caret at the table end',
        );
        expect(
          pills(
            find: TextRange(start: start - 1, end: start - 1),
          ),
          isEmpty,
          reason: 'one before the table',
        );
        expect(
          pills(
            find: TextRange(start: end + 1, end: end + 1),
          ),
          isEmpty,
          reason: 'one after the table',
        );
        expect(
          pills(find: const TextRange(start: -1, end: 99)),
          isEmpty,
          reason: 'an invalid range',
        );
        expect(
          pills(reveal: TextSelection.collapsed(offset: start)),
          hasLength(3),
          reason: 'the selection alone still adds them',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // The pumped decorations in a focused segment
  // -------------------------------------------------------------------------
  group('decorations of a focused segment', () {
    testWidgets(
      'the decorations outset the fenced code boxes of the caret and of the find reveal range while the segment is focused',
      (tester) async {
        const text =
            'intro\n\n```\nlet a = 1;\n```\n\nmid\n\n```\nlet b = 2;\n```\n\nafter';
        final controller = LivePreviewController(text: text);
        addTearDown(controller.dispose);
        final gate = ValueNotifier<bool>(true);
        addTearDown(gate.dispose);
        controller.revealGate = gate;
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        controller.findDecoration = n;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final editable = GlobalKey(debugLabel: 'w84-focused');
        LineBoxSource? boxes() {
          final e = findRenderEditable(
            editable.currentContext?.findRenderObject(),
          );
          return e == null ? null : RenderEditableLineBoxes(e);
        }

        controller.selection = const TextSelection.collapsed(offset: 2);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildOmTheme(),
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: LivePreviewDecorations(
                    controller: controller,
                    boxes: boxes,
                    textLeft: 14,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: EditableText(
                        key: editable,
                        controller: controller,
                        focusNode: focus,
                        style: _w84Base(),
                        strutStyle: controller.strutStyle,
                        cursorColor: OmColors.accent,
                        backgroundCursorColor: OmColors.surface2,
                        maxLines: null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final rest = _w84PaintedBoxHeights(tester);
        expect(rest, hasLength(2), reason: 'two code boxes');
        expect(rest[0], closeTo(rest[1], 0.01), reason: 'alike at rest');

        // The caret on block A, the find range on block B: both outset.
        controller.selection = TextSelection.collapsed(
          offset: text.indexOf('a = 1'),
        );
        n.value = FindDecoration(revealRange: _w84Range(text, 'b = 2'));
        await tester.pump();
        final both = _w84PaintedBoxHeights(tester);
        expect(both, hasLength(2));
        expect(both[0], closeTo(rest[0] + 16, 0.01), reason: 'the caret block');
        expect(both[1], closeTo(rest[1] + 16, 0.01), reason: 'the find block');

        // The caret off both blocks: the find range alone.
        controller.selection = const TextSelection.collapsed(offset: 2);
        await tester.pump();
        final findOnly = _w84PaintedBoxHeights(tester);
        expect(findOnly[0], closeTo(rest[0], 0.01), reason: 'A is at rest');
        expect(findOnly[1], closeTo(rest[1] + 16, 0.01), reason: 'B reveals');

        // The range moves off block B: both at rest again.
        n.value = FindDecoration(revealRange: _w84Range(text, 'after'));
        await tester.pump();
        final off = _w84PaintedBoxHeights(tester);
        expect(off[0], closeTo(rest[0], 0.01));
        expect(off[1], closeTo(rest[1], 0.01));

        // The segment unfocused: the find range still reveals, the caret not.
        gate.value = false;
        controller.selection = TextSelection.collapsed(
          offset: text.indexOf('a = 1'),
        );
        n.value = FindDecoration(revealRange: _w84Range(text, 'b = 2'));
        await tester.pump();
        final unfocused = _w84PaintedBoxHeights(tester);
        expect(unfocused[0], closeTo(rest[0], 0.01), reason: 'no caret reveal');
        expect(unfocused[1], closeTo(rest[1] + 16, 0.01));
      },
    );
  });
}
