// Spec #122 (mutation batch 1): RenderParagraphLineBoxes.lineAt on a source
// line that ends in a run of hidden (zero-width) markers right before its
// line break, after a space where the line wrapped. The markers then lie on
// the line below the text, and the line break is the only character with a
// box to find them by; the lazy line boxes must give the line main's
// whole-text measurement gave (LineBoxOracle).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/line_box_oracle.dart';

/// Six words and the space after the last, then two hidden markers and the
/// line break, then a visible line.
const _visible = 'aaa bbb ccc ddd eee fff ';
const _hidden = '**';
const _tail = '\nnext';

/// Where the hidden run starts: the space before it ends the last visible
/// line, so the run opens the line below.
const _runStart = 24;

void main() {
  holdFontFetches();

  for (final (name, width) in <(String, double)>[
    (
      'a hidden run after a wrapping space and before the line break measures as main in a 50 px box',
      50,
    ),
    (
      'a hidden run after a wrapping space and before the line break measures as main in a 100 px box',
      100,
    ),
    (
      'a hidden run after a wrapping space and before the line break measures as main in a 110 px box',
      110,
    ),
    (
      'a hidden run after a wrapping space and before the line break measures as main in a 160 px box',
      160,
    ),
  ]) {
    testWidgets(name, (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: LineBoxEpoch(
                child: RichText(
                  key: const Key('hidden-run-paragraph'),
                  text: const TextSpan(
                    style: TextStyle(fontSize: 14, height: 1.7),
                    children: [
                      TextSpan(text: _visible),
                      TextSpan(text: _hidden, style: livePreviewHiddenStyle),
                      TextSpan(text: _tail),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('hidden-run-paragraph')),
      );
      final oracle = LineBoxOracle.paragraph(paragraph);
      addTearDown(oracle.dispose);
      expect(
        paragraph.text.toPlainText().length,
        _visible.length + _hidden.length + _tail.length,
      );

      // The layout this test is about: the run sits alone on its own line,
      // below the line holding the last word.
      final run = oracle.lineAt(_runStart);
      expect(
        (run.range.start, run.range.end),
        (_runStart, _runStart + _hidden.length),
        reason: 'the hidden run is a line of its own',
      );
      expect(
        oracle.lineAt(_runStart - 2).range.start,
        lessThan(_runStart),
        reason: 'the last word is on the line above',
      );

      // Baselines of a line holding nothing but hidden markers are not
      // compared: the class docs leave them out of the equality.
      Object key(LineBox l) => (l.range.start, l.range.end, l.top, l.bottom);
      for (
        var offset = _runStart;
        offset < _runStart + _hidden.length;
        offset++
      ) {
        expect(
          key(RenderParagraphLineBoxes(paragraph).lineAt(offset)),
          key(oracle.lineAt(offset)),
          reason: 'lineAt($offset) in a $width px box',
        );
      }
    });
  }
}
