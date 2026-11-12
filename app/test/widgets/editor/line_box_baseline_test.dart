// WI #437 (Spec #392 req 7, ruling D23): `LineBox.baseline`. Every line box
// source fills each line's baseline from its measuring TextPainter's line
// metrics, in the same coordinates as `top` and `bottom`: the editable's
// (also scrolled), the paragraph's, and the segment's merged rows box, where
// each row's baselines shift with the row as its tops do.
//
// Expected baselines come from an independent oracle: the field's own text
// span laid out again with its strut, scaler and width, reading
// `computeLineMetrics()`, never from the adapter under test. Live preview
// lines are measured in the real editor (pumpSpellingEditor), so the theme's
// even leading and the controller strut apply (run 20261102-221 lesson).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/spelling_editor_pump.dart';

/// Oracle: every line's baseline of [editable]'s laid-out text, top to
/// bottom, in the editable's local coordinates (its vertical scroll
/// applied): the editable's own span laid out again as the editable lays it
/// out, read through `computeLineMetrics()`.
List<double> _wi437EditableBaselines(RenderEditable editable) {
  final multiline = editable.maxLines != 1;
  final painter = TextPainter(
    text: editable.text,
    textAlign: editable.textAlign,
    textDirection: editable.textDirection,
    textScaler: editable.textScaler,
    locale: editable.locale,
    maxLines: multiline ? null : 1,
    strutStyle: editable.strutStyle,
    textHeightBehavior: editable.textHeightBehavior,
    textWidthBasis: editable.textWidthBasis,
  );
  try {
    // RenderEditable lays its text out its caret gap (1) plus its cursor
    // width narrower than itself.
    final available = editable.constraints.maxWidth - 1 - editable.cursorWidth;
    painter.layout(
      minWidth: editable.forceLine ? available : 0,
      maxWidth: multiline ? available : double.infinity,
    );
    final scroll = multiline ? editable.offset.pixels : 0.0;
    return [for (final m in painter.computeLineMetrics()) m.baseline - scroll];
  } finally {
    painter.dispose();
  }
}

/// Oracle: every line's baseline of [paragraph]'s laid-out text, in the
/// paragraph's local coordinates.
List<double> _wi437ParagraphBaselines(RenderParagraph paragraph) {
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
    maxLines: paragraph.maxLines,
    strutStyle: paragraph.strutStyle,
    textHeightBehavior: paragraph.textHeightBehavior,
    textWidthBasis: paragraph.textWidthBasis,
  );
  try {
    painter.layout(
      minWidth: paragraph.constraints.minWidth,
      maxWidth: paragraph.constraints.maxWidth,
    );
    return [for (final m in painter.computeLineMetrics()) m.baseline];
  } finally {
    painter.dispose();
  }
}

RenderEditable _wi437EditableOf(WidgetTester tester, Finder field) =>
    findRenderEditable(tester.renderObject(field))!;

void _wi437ExpectBaselines(
  List<LineBox> lines,
  List<double?> expected, {
  required String what,
}) {
  expect(
    lines,
    hasLength(expected.length),
    reason: '$what: one line box per laid-out line',
  );
  for (final (i, line) in lines.indexed) {
    final want = expected[i];
    if (want == null) continue;
    expect(
      line.baseline,
      moreOrLessEquals(want, epsilon: 0.01),
      reason: '$what: line $i ${line.range} baseline from its line metrics',
    );
    expect(
      line.baseline,
      inExclusiveRange(line.top, line.bottom),
      reason: '$what: line $i baseline lies inside its line box',
    );
  }
}

void main() {
  holdFontFetches();

  group('LineBox.baseline (AC1)', () {
    testWidgets(
      'RenderEditableLineBoxes fills each line baseline from the editable line metrics on a body line and an H1 line',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '# Heading teh\n\nteh cat adn dog\n',
        );
        final field = e.rowFields(0).first;
        final editable = _wi437EditableOf(tester, field);
        final lines = RenderEditableLineBoxes(editable).lines;

        // The fixture: line 0 is the H1, line 2 a body line; the H1 lays out
        // taller than the body line.
        final h1 = lines[0];
        final body = lines[2];
        expect(
          tester.widget<EditableText>(field).controller.text,
          startsWith('# Heading teh\n'),
        );
        expect(
          h1.bottom - h1.top,
          greaterThan(body.bottom - body.top + 2),
          reason: 'fixture: line 0 is an H1, taller than a body line',
        );

        _wi437ExpectBaselines(
          lines,
          _wi437EditableBaselines(editable),
          what: 'H1 and body row',
        );
        // The H1 baseline sits further below its top than the body line's.
        expect(
          h1.baseline - h1.top,
          greaterThan(body.baseline - body.top + 1),
          reason: 'the H1 baseline is its own, not a body line one',
        );
      },
    );

    testWidgets(
      'RenderEditableLineBoxes shifts each baseline with the editable scroll offset like top',
      (tester) async {
        final controller = LivePreviewController(
          text: 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight',
        );
        final scroll = ScrollController();
        addTearDown(controller.dispose);
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: TextField(
                    key: const Key('wi437-scrolled'),
                    controller: controller,
                    scrollController: scroll,
                    strutStyle: controller.strutStyle,
                    style: editorBodyStyle(),
                    maxLines: 3,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final editable = _wi437EditableOf(
          tester,
          find.byKey(const Key('wi437-scrolled')),
        );
        final unscrolled = RenderEditableLineBoxes(editable).lines;
        _wi437ExpectBaselines(
          unscrolled,
          _wi437EditableBaselines(editable),
          what: 'unscrolled',
        );

        scroll.jumpTo(37);
        await tester.pump();
        expect(editable.offset.pixels, 37, reason: 'fixture: it scrolled');
        final scrolled = RenderEditableLineBoxes(editable).lines;
        _wi437ExpectBaselines(
          scrolled,
          _wi437EditableBaselines(editable),
          what: 'scrolled by 37',
        );
        for (final (i, line) in scrolled.indexed) {
          expect(
            line.baseline - line.top,
            moreOrLessEquals(
              unscrolled[i].baseline - unscrolled[i].top,
              epsilon: 0.01,
            ),
            reason: 'line $i baseline moves with its top',
          );
        }
      },
    );

    testWidgets(
      'RenderParagraphLineBoxes fills each line baseline from the paragraph line metrics',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: RichText(
                  key: const Key('wi437-paragraph'),
                  strutStyle: const StrutStyle(fontSize: 13.5, height: 1.7),
                  text: const TextSpan(
                    style: TextStyle(fontSize: 13.5, height: 1.7),
                    children: [
                      TextSpan(text: 'small line\n'),
                      TextSpan(
                        text: 'BIG line',
                        style: TextStyle(fontSize: 30, height: 1),
                      ),
                      TextSpan(text: '\nlast'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('wi437-paragraph')),
        );
        final lines = RenderParagraphLineBoxes(paragraph).lines;
        _wi437ExpectBaselines(
          lines,
          _wi437ParagraphBaselines(paragraph),
          what: 'paragraph',
        );
        expect(
          lines[1].baseline - lines[1].top,
          greaterThan(lines[0].baseline - lines[0].top + 4),
          reason: 'the 30 px line has its own, lower baseline',
        );
      },
    );

    testWidgets(
      'the segment merged line boxes shift each row baseline with the row',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat\n\n- item teh\n- next adn\n',
        );
        final view = tester.state<SegmentViewState>(
          find.descendant(
            of: e.textSegment(0),
            matching: find.byType(SegmentView),
          ),
        );
        final merged = view.lineBoxes()!;
        final expected = <double?>[];
        final shifts = <double>[];
        // Every row field under the rows box, in paint (row) order.
        final editables = <RenderEditable>[];
        void visit(RenderObject node) {
          if (node is RenderEditable) {
            editables.add(node);
          } else {
            node.visitChildren(visit);
          }
        }

        merged.box.visitChildren(visit);
        for (final editable in editables) {
          final shift = MatrixUtils.transformPoint(
            editable.getTransformTo(merged.box),
            Offset.zero,
          ).dy;
          shifts.add(shift);
          // An empty field has no line metrics (its one line box is a
          // caret's); it is not checked here.
          final baselines = _wi437EditableBaselines(editable);
          if (baselines.isEmpty) expected.add(null);
          for (final b in baselines) {
            expected.add(b + shift);
          }
        }
        expect(
          shifts.where((s) => s > 10),
          isNotEmpty,
          reason: 'fixture: rows below the first sit lower in the rows box',
        );
        _wi437ExpectBaselines(merged.lines, expected, what: 'merged rows');
      },
    );
  });
}
