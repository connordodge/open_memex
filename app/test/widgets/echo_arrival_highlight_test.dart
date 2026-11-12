// Edge cases of `echoArrivalRects` and `EchoArrivalHighlight` (WI #428) that
// the workspace-level tests in `echo_scroll_target_test.dart` do not reach:
// the prose-band fallbacks, a text range that begins at a line break, a band
// that changes while the highlight shows, and a target that is gone or a
// highlight that has faded out completely. They pin the mutants the merge gate
// found surviving. Plain widget tests on fake async, no workspace.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart' show RowKind;
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';

const _rowKey = ValueKey('row');

/// A plain multi-line editable (a prose row's field) of [text] in a 300 px
/// wide box, and its render box.
Future<RenderBox> _pumpRow(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: _rowKey,
          width: 300,
          child: EditableText(
            controller: TextEditingController(text: text),
            focusNode: FocusNode(),
            style: const TextStyle(fontSize: 14, height: 1.5),
            cursorColor: Colors.black,
            backgroundCursorColor: Colors.grey,
            maxLines: null,
          ),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderBox>(find.byKey(_rowKey));
}

EchoArrival _arrival(String content, int offset) {
  final arrival = locateEchoArrival(content, offset);
  expect(arrival, isNotNull);
  expect(arrival!.kind, RowKind.prose);
  return arrival;
}

void main() {
  group('echoArrivalRects', () {
    testWidgets(
      'a row whose field text differs from the arrival covers the whole row',
      (tester) async {
        const content = 'one\n\ntwo\nthree\n\nfour\n';
        // The editable holds the row without its trailing line break: it has a
        // size and lines, but is not the text the arrival was located in.
        final row = await _pumpRow(tester, content.substring(0, 20));
        final arrival = _arrival(content, content.indexOf('two'));
        expect(arrival.rowText, content);

        final rects = echoArrivalRects(row, arrival);

        final whole = Offset.zero & row.size;
        expect(rects.band, whole);
        expect(rects.anchor, whole);
      },
    );

    testWidgets('the same row with matching text covers only the passage', (
      tester,
    ) async {
      const content = 'one\n\ntwo\nthree\n\nfour\n';
      final row = await _pumpRow(tester, content);
      final arrival = _arrival(content, content.indexOf('two'));

      final rects = echoArrivalRects(row, arrival);

      expect(rects.band.top, greaterThan(0));
      expect(rects.band.bottom, lessThan(row.size.height));
    });

    testWidgets(
      'a prose row starting with a line break skips that blank line',
      (tester) async {
        // Offset 0 is the line break itself: the passage starts at the next
        // non-blank line, so the band begins below the empty first line.
        const content = '\nfoo\nbar';
        final row = await _pumpRow(tester, content);
        final arrival = _arrival(content, 0);

        final rects = echoArrivalRects(row, arrival);

        final lines = RenderEditableLineBoxes(findRenderEditable(row)!).lines;
        expect(lines.length, 3);
        expect(rects.band.top, closeTo(lines[1].top, 0.5));
        expect(rects.band.top, greaterThan(0));
        expect(rects.anchor.top, closeTo(lines[1].top, 0.5));
      },
    );

    testWidgets(
      'a passage on the last line, with no line break after it, ends with the row',
      (tester) async {
        const content = 'one\n\ntwo\nthree';
        final row = await _pumpRow(tester, content);
        final arrival = _arrival(content, content.indexOf('two'));

        final rects = echoArrivalRects(row, arrival);

        expect(rects.band.top, greaterThan(0));
        expect(rects.band.bottom, row.size.height);
      },
    );
  });

  group('EchoArrivalHighlight', () {
    const first = Rect.fromLTWH(10, 20, 50, 30);
    const second = Rect.fromLTWH(30, 60, 40, 20);
    final targetKey = GlobalKey();

    /// The highlight over [band] of the target box [box] (its render box, kept
    /// as the editor's overlay keeps it); the target widget itself is in the
    /// tree only while [withTarget].
    Widget tree(RenderBox? box, Rect band, {bool withTarget = true}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              if (withTarget) SizedBox(key: targetKey, width: 200, height: 200),
              if (box != null)
                Positioned.fill(
                  key: const ValueKey('highlight'),
                  child: EchoArrivalHighlight(
                    target: box,
                    band: band,
                    onDone: () {},
                  ),
                ),
            ],
          ),
        );

    /// Pumps the highlight over [first] and returns the target's render box.
    Future<RenderBox> pumpHighlight(WidgetTester tester) async {
      await tester.pumpWidget(tree(null, first));
      final box = tester.renderObject<RenderBox>(find.byKey(targetKey));
      await tester.pumpWidget(tree(box, first));
      await tester.pump();
      return box;
    }

    RenderObject painter(WidgetTester tester) => tester.renderObject(
      find.descendant(
        of: find.byType(EchoArrivalHighlight),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_HighlightPaint',
        ),
      ),
    );

    testWidgets('paints its band, then the new band when it changes', (
      tester,
    ) async {
      final box = await pumpHighlight(tester);
      expect(painter(tester), paints..rect(rect: first));

      await tester.pumpWidget(tree(box, second));

      expect(painter(tester), paints..rect(rect: second));
    });

    testWidgets('paints nothing once its target has left the tree', (
      tester,
    ) async {
      final box = await pumpHighlight(tester);
      expect(painter(tester), paints..rect());

      await tester.pumpWidget(tree(box, first, withTarget: false));
      await tester.pump();

      expect(box.attached, isFalse);
      expect(box.hasSize, isTrue);
      expect(painter(tester), paintsNothing);
    });

    testWidgets('paints nothing once it has faded out completely', (
      tester,
    ) async {
      await pumpHighlight(tester);
      expect(painter(tester), paints..rect());

      await tester.pump(EchoArrivalHighlight.duration);

      expect(painter(tester), paintsNothing);
    });
  });
}
