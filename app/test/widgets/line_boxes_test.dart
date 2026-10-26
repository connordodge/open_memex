// WI #159 (D6, TD10, Spec R32/R33): the line-box seam. `LineBoxSource`
// over a laid-out field's RenderEditable reports the field's real line
// boxes: a caret rect is as tall as its line box, also at a hidden
// (zero-width) character and on a taller line; offsetAt maps a point back
// to the nearest offset; boxesFor and lines span full line heights.
//
// The field renders through a test controller: lines starting with `BIG`
// at 40 px, `**` hidden at font size 0. Expected line boxes come from an
// independent oracle (the field's own span laid out again, max-height
// selection boxes), never from the adapter.
//
// Its two consumers measure through it: the capture gutter's rules span
// their blocks' real line boxes (R33) and the `[[` popover anchors under
// the caret's real line box (R32), with a taller line in the field.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/capture_gutter.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/wi159_line_geometry.dart';

/// Lines: 0 `first line` (0..10), 1 `BIG line` (11..19, 40 px font),
/// 2 `ab**cd` (20..26, `**` at 22..24 hidden), 3 `last` (27..31).
const _text = 'first line\nBIG line\nab**cd\nlast';
const _line0 = TextRange(start: 0, end: 10);
const _line1 = TextRange(start: 11, end: 19);
const _line2 = TextRange(start: 20, end: 26);
const _line3 = TextRange(start: 27, end: 31);

/// Width of one 13.5 px glyph in the fallback test font.
const _glyph = 13.5;

/// Pumps a field rendering [text] through the test controller, the editor's
/// body style, and [strut] (null: the field's default, forced strut), at
/// [width]; returns its RenderEditable.
Future<RenderEditable> _pumpField(
  WidgetTester tester, {
  String text = _text,
  StrutStyle? strut = wi159MinimumStrut,
  double width = 600,
}) async {
  final controller = Wi159TallLineController(text: text);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(37, 53, 0, 0),
            child: SizedBox(
              width: width,
              child: TextField(
                key: const Key('field'),
                controller: controller,
                maxLines: null,
                strutStyle: strut,
                style: OmType.mono(
                  size: 13.5,
                  color: OmColors.fg0,
                  height: 1.7,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return wi159EditableIn(tester, find.byKey(const Key('field')));
}

void _expectSpansLine(Rect rect, Rect line, {required String reason}) {
  expect(rect.top, moreOrLessEquals(line.top, epsilon: 0.5), reason: reason);
  expect(
    rect.bottom,
    moreOrLessEquals(line.bottom, epsilon: 0.5),
    reason: reason,
  );
}

void main() {
  holdFontFetches();

  testWidgets(
    'caretRect at an offset whose glyph renders zero width has the height of its line',
    (tester) async {
      final editable = await _pumpField(tester);
      final boxes = RenderEditableLineBoxes(editable);
      final line = wi159LineBox(editable, _line2);
      expect(line.height, greaterThan(20), reason: 'oracle sanity');

      for (final offset in [22, 23, 24]) {
        final caret = boxes.caretRect(offset);
        expect(caret.height, greaterThan(0), reason: 'offset $offset');
        _expectSpansLine(caret, line, reason: 'hidden offset $offset');
      }
      // The hidden `**` has no width: its three offsets share one x, and the
      // next visible character moves right by one glyph.
      final x22 = boxes.caretRect(22).left;
      expect(boxes.caretRect(23).left, moreOrLessEquals(x22, epsilon: 0.5));
      expect(boxes.caretRect(24).left, moreOrLessEquals(x22, epsilon: 0.5));
      expect(
        boxes.caretRect(25).left - x22,
        moreOrLessEquals(_glyph, epsilon: 1),
      );
    },
    variant: macOnly,
  );

  testWidgets(
    'caretRect on a taller line spans that line box from its top to its bottom',
    (tester) async {
      final editable = await _pumpField(tester);
      final boxes = RenderEditableLineBoxes(editable);
      final tall = wi159LineBox(editable, _line1);
      final above = wi159LineBox(editable, _line0);
      expect(tall.height, greaterThan(above.height + 10), reason: 'oracle');

      for (final offset in [11, 13, 19]) {
        _expectSpansLine(
          boxes.caretRect(offset),
          tall,
          reason: 'offset $offset on the tall line',
        );
      }
      _expectSpansLine(boxes.caretRect(0), above, reason: 'offset 0');
      _expectSpansLine(boxes.caretRect(10), above, reason: 'end of line 0');
      _expectSpansLine(
        boxes.caretRect(_text.length),
        wi159LineBox(editable, _line3),
        reason: 'end of text',
      );
      // The caret's x is the glyph boundary: 2 glyphs of 40 px into line 1.
      expect(
        boxes.caretRect(13).left - boxes.caretRect(11).left,
        moreOrLessEquals(2 * wi159TallFontSize, epsilon: 1),
      );
    },
    variant: macOnly,
  );

  testWidgets(
    'caretRect with the field default forced strut spans the line box',
    (tester) async {
      final editable = await _pumpField(tester, strut: null);
      final boxes = RenderEditableLineBoxes(editable);

      for (final (offset, line) in [
        (0, _line0),
        (13, _line1),
        (23, _line2),
        (29, _line3),
      ]) {
        _expectSpansLine(
          boxes.caretRect(offset),
          wi159LineBox(editable, line),
          reason: 'offset $offset',
        );
      }
    },
    variant: macOnly,
  );

  testWidgets(
    'offsetAt maps a point inside a line back to the nearest offset',
    (tester) async {
      final editable = await _pumpField(tester);
      final boxes = RenderEditableLineBoxes(editable);
      final line0 = wi159LineBox(editable, _line0);
      final line1 = wi159LineBox(editable, _line1);
      final line3 = wi159LineBox(editable, _line3);

      // Just right of the boundary after 3 glyphs: offset 3.
      expect(boxes.offsetAt(Offset(3 * _glyph + 2, line0.center.dy)), 3);
      // Past the middle of the 4th glyph: the boundary after it, offset 4.
      expect(boxes.offsetAt(Offset(3 * _glyph + 10, line0.center.dy)), 4);
      // Near the top edge of the tall line, 2 of its 40 px glyphs in.
      expect(
        boxes.offsetAt(Offset(2 * wi159TallFontSize + 5, line1.top + 3)),
        13,
      );
      // Right of the last line's text: the end of that line.
      expect(boxes.offsetAt(Offset(500, line3.center.dy)), 31);
      // Right of line 0's text: line 0's end, not the next line.
      expect(boxes.offsetAt(Offset(500, line0.center.dy)), 10);
    },
    variant: macOnly,
  );

  testWidgets(
    'boxesFor gives one full height rect per line the range touches',
    (tester) async {
      final editable = await _pumpField(tester);
      final boxes = RenderEditableLineBoxes(editable);
      final line0 = wi159LineBox(editable, _line0);
      final line1 = wi159LineBox(editable, _line1);

      // `line` of line 0 and `BI` of the tall line 1.
      final rects = boxes.boxesFor(const TextRange(start: 6, end: 13));
      expect(rects, hasLength(2));
      _expectSpansLine(rects[0], line0, reason: 'first rect');
      expect(rects[0].left, moreOrLessEquals(6 * _glyph, epsilon: 1));
      expect(rects[0].right, moreOrLessEquals(10 * _glyph, epsilon: 1));
      _expectSpansLine(rects[1], line1, reason: 'second rect');
      expect(rects[1].left, moreOrLessEquals(0, epsilon: 1));
      expect(
        rects[1].right,
        moreOrLessEquals(2 * wi159TallFontSize, epsilon: 1),
      );

      // Within one line: one rect over just those characters.
      final within = boxes.boxesFor(const TextRange(start: 1, end: 3));
      expect(within, hasLength(1));
      _expectSpansLine(within.single, line0, reason: 'within line 0');
      expect(within.single.left, moreOrLessEquals(_glyph, epsilon: 1));
      expect(within.single.right, moreOrLessEquals(3 * _glyph, epsilon: 1));

      expect(boxes.boxesFor(const TextRange.collapsed(4)), isEmpty);
    },
    variant: macOnly,
  );

  testWidgets(
    'lines lists every laid out line with its range and full line box',
    (tester) async {
      final editable = await _pumpField(tester);
      final boxes = RenderEditableLineBoxes(editable);

      expect(boxes.box, same(editable));
      final lines = boxes.lines;
      expect(lines.map((l) => l.range), [_line0, _line1, _line2, _line3]);
      for (final (i, range) in [_line0, _line1, _line2, _line3].indexed) {
        final expected = wi159LineBox(editable, range);
        expect(
          lines[i].top,
          moreOrLessEquals(expected.top, epsilon: 0.5),
          reason: 'line $i top',
        );
        expect(
          lines[i].bottom,
          moreOrLessEquals(expected.bottom, epsilon: 0.5),
          reason: 'line $i bottom',
        );
      }
      // Line boxes tile the text: each starts where the previous ends.
      for (var i = 1; i < lines.length; i++) {
        expect(
          lines[i].top,
          moreOrLessEquals(lines[i - 1].bottom, epsilon: 0.5),
        );
      }
    },
    variant: macOnly,
  );

  testWidgets('lines gives one line per visual line of a wrapped source line', (
    tester,
  ) async {
    const long = 'aaaaaaaaaaaaaaaaaaaaaaaa';
    final editable = await _pumpField(tester, text: long, width: 200);
    final boxes = RenderEditableLineBoxes(editable);

    final lines = boxes.lines;
    expect(lines, hasLength(2));
    expect(lines.first.range.start, 0);
    expect(lines.first.range.end, lines.last.range.start);
    expect(lines.last.range.end, long.length);
    expect(lines.last.top, greaterThan(lines.first.top));
  }, variant: macOnly);

  testWidgets(
    'lines and caretRect cover blank lines a trailing empty line and an empty text',
    (tester) async {
      // Lines: `ab` (0..2), blank (3..3), `cd` (4..6), empty last (7..7).
      const text = 'ab\n\ncd\n';
      final editable = await _pumpField(tester, text: text);
      final boxes = RenderEditableLineBoxes(editable);
      final full = wi159LineBox(editable, const TextRange(start: 0, end: 2));

      final lines = boxes.lines;
      expect(lines.map((l) => l.range), const [
        TextRange(start: 0, end: 2),
        TextRange(start: 3, end: 3),
        TextRange(start: 4, end: 6),
        TextRange(start: 7, end: 7),
      ]);
      for (var i = 0; i < lines.length; i++) {
        expect(
          lines[i].bottom - lines[i].top,
          moreOrLessEquals(full.height, epsilon: 0.5),
          reason: 'line $i is one body line tall',
        );
        if (i > 0) {
          expect(
            lines[i].top,
            moreOrLessEquals(lines[i - 1].bottom, epsilon: 0.5),
          );
        }
      }
      for (final (offset, line) in [(3, 1), (7, 3)]) {
        final caret = boxes.caretRect(offset);
        expect(caret.top, moreOrLessEquals(lines[line].top, epsilon: 0.5));
        expect(
          caret.bottom,
          moreOrLessEquals(lines[line].bottom, epsilon: 0.5),
        );
      }

      final empty = await _pumpField(tester, text: '');
      final emptyBoxes = RenderEditableLineBoxes(empty);
      expect(emptyBoxes.lines, hasLength(1));
      expect(emptyBoxes.lines.single.range, const TextRange.collapsed(0));
      final caret = emptyBoxes.caretRect(0);
      expect(caret.height, moreOrLessEquals(full.height, epsilon: 0.5));
      expect(caret.top, moreOrLessEquals(0, epsilon: 0.5));
    },
    variant: macOnly,
  );

  group('consumers of the line boxes', () {
    testWidgets(
      'each capture gutter rule spans its block real line boxes when a line renders at a larger font',
      (tester) async {
        // Line 0 person, lines 1-2 an agent block whose first line is tall,
        // lines 3-4 a quick-entry block whose last line is tall.
        const text =
            'Plain first.\nBIG agent line\nafter big\nPlain again\nBIG END\n';
        BlockRow block(String id, String source, String blockText) {
          final start = text.indexOf(blockText);
          return BlockRow(
            blockId: id,
            ord: 0,
            text: blockText,
            source: source,
            createdVersion: 2,
            createdAt: DateTime(2026, 10, 3, 14, 32).millisecondsSinceEpoch,
            startByte: start,
            endByte: start + blockText.length,
          );
        }

        final blocks = [
          block('p-first', 'person', 'Plain first.'),
          block('a-big', 'agent', 'BIG agent line\nafter big'),
          block('q-end', 'quick-entry', 'Plain again\nBIG END'),
        ];
        final controller = Wi159TallLineController(text: text);
        addTearDown(controller.dispose);
        const fieldKey = Key('gutter-field');
        RenderEditable? editable() {
          if (find.byKey(fieldKey).evaluate().isEmpty) return null;
          return wi159EditableIn(tester, find.byKey(fieldKey));
        }

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              blocksForNoteAsyncProvider.overrideWith(
                (ref, noteId) async => VaultScoped(null, blocks),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.fromLTRB(30, 41, 30, 0),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          left: captureGutterWidth,
                        ),
                        child: TextField(
                          key: fieldKey,
                          controller: controller,
                          maxLines: null,
                          strutStyle: wi159MinimumStrut,
                          style: OmType.mono(
                            size: 13.5,
                            color: OmColors.fg0,
                            height: 1.7,
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: captureGutterWidth,
                        child: CaptureGutter(
                          noteId: 'daily-gutter',
                          controller: controller,
                          editable: editable,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        final field = wi159EditableIn(tester, find.byKey(fieldKey));
        Rect line(String of) => wi159Global(
          field,
          wi159LineBox(field, wi159LineOf(text, text.indexOf(of))),
        );
        final tall = line('BIG agent');
        expect(
          tall.height,
          greaterThan(line('Plain first.').height + 10),
          reason: 'oracle: the BIG line lays out taller',
        );

        final agent = tester.getRect(
          find.byKey(const Key('capture-gutter-rule-a-big')),
        );
        expect(agent.top, moreOrLessEquals(tall.top, epsilon: 0.5));
        expect(
          agent.bottom,
          moreOrLessEquals(line('after big').bottom, epsilon: 0.5),
        );

        final quick = tester.getRect(
          find.byKey(const Key('capture-gutter-rule-q-end')),
        );
        expect(
          quick.top,
          moreOrLessEquals(line('Plain again').top, epsilon: 0.5),
        );
        expect(
          quick.bottom,
          moreOrLessEquals(line('BIG END').bottom, epsilon: 0.5),
        );
        expect(
          find.byKey(const Key('capture-gutter-rule-p-first')),
          findsNothing,
        );
      },
      variant: macOnly,
    );

    for (final (name, text, tallLine) in [
      (
        'the wikilink popover anchors at the bottom of the caret real line box on a line at a larger font',
        'BIG see [[',
        'BIG see [[',
      ),
      (
        'the wikilink popover anchors at the bottom of the caret real line box below a line at a larger font',
        'BIG title\nsee [[',
        'BIG title',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final controller = Wi159TallLivePreviewController();
        addTearDown(controller.dispose);
        final chips = KindChipHost();
        addTearDown(chips.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.fromLTRB(44, 37, 44, 0),
                  child: TextSegmentField(
                    key: const Key('segment-field'),
                    controller: controller,
                    onChanged: (_) {},
                    kindChips: chips,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.showKeyboard(find.byKey(const Key('segment-field')));
        // Typed one character at a time, as a person types: the popover
        // opens on the second `[`, a frame after the rest was laid out.
        for (var i = 1; i <= text.length; i++) {
          await tester.macEditingValue(text.substring(0, i));
        }
        await tester.pump();

        final popover = find.byKey(const Key('wikilink-popover'));
        expect(popover, findsOneWidget);
        final field = wi159EditableIn(
          tester,
          find.byKey(const Key('segment-field')),
        );
        final caretLine = wi159Global(
          field,
          wi159LineBox(field, wi159LineOf(text, text.length)),
        );
        final tall = wi159LineBox(field, wi159LineOf(text, 0));
        expect(
          tall.height,
          greaterThan(30),
          reason:
              'the field lays out with its controller strut, so $tallLine is taller',
        );
        // The popover sits its fixed 6 px gap below its anchor.
        expect(
          tester.getTopLeft(popover).dy,
          moreOrLessEquals(caretLine.bottom + 6, epsilon: 0.5),
        );
      }, variant: macOnly);
    }
  });

  group('line box contracts (verify)', () {
    testWidgets(
      'lineHolding puts an offset at a wrap boundary on the line it starts',
      (tester) async {
        const long = 'aaaaaaaaaaaaaaaaaaaaaaaa';
        final editable = await _pumpField(tester, text: long, width: 200);
        final boxes = RenderEditableLineBoxes(editable);
        final lines = boxes.lines;
        expect(lines, hasLength(2), reason: 'the text wraps once');
        final boundary = lines.last.range.start;
        expect(boundary, greaterThan(0));

        expect(lineHolding(lines, boundary), same(lines.last));
        expect(lineHolding(lines, boundary - 1), same(lines.first));
        expect(lineHolding(lines, 0), same(lines.first));
        expect(lineHolding(lines, long.length), same(lines.last));
        // The caret at the boundary is drawn on the line it starts.
        final caret = boxes.caretRect(boundary);
        expect(caret.top, moreOrLessEquals(lines.last.top, epsilon: 0.5));
        expect(caret.bottom, moreOrLessEquals(lines.last.bottom, epsilon: 0.5));

        // Pure lists: the last line starting at or before the offset.
        const a = LineBox(
          range: TextRange(start: 0, end: 4),
          top: 0,
          bottom: 10,
        );
        const b = LineBox(
          range: TextRange(start: 4, end: 9),
          top: 10,
          bottom: 30,
        );
        const c = LineBox(
          range: TextRange(start: 10, end: 12),
          top: 30,
          bottom: 40,
        );
        expect(lineHolding(const [a, b, c], 3), same(a));
        expect(lineHolding(const [a, b, c], 4), same(b));
        expect(lineHolding(const [a, b, c], 9), same(b));
        expect(lineHolding(const [a, b, c], 10), same(c));
        expect(lineHolding(const [a, b, c], 99), same(c));
      },
      variant: macOnly,
    );

    testWidgets(
      'boxesFor over only hidden characters gives a zero width rect at the caret x spanning the line',
      (tester) async {
        final editable = await _pumpField(tester);
        final boxes = RenderEditableLineBoxes(editable);
        final line = wi159LineBox(editable, _line2);

        // `**` (22..24) renders zero-width.
        final rects = boxes.boxesFor(const TextRange(start: 22, end: 24));
        expect(rects, hasLength(1));
        final rect = rects.single;
        _expectSpansLine(rect, line, reason: 'hidden range');
        expect(rect.width, moreOrLessEquals(0, epsilon: 0.5));
        // At the text caret x: the glyph boundary before the marker (the
        // drawn macOS cursor sits up to 1 px left of it).
        expect(rect.left, moreOrLessEquals(2 * _glyph, epsilon: 0.5));
        expect(
          rect.left,
          moreOrLessEquals(boxes.caretRect(22).left, epsilon: 1),
        );

        // A range from the hidden marker into visible text starts at the
        // same x and covers the visible glyph.
        final mixed = boxes.boxesFor(const TextRange(start: 22, end: 25));
        expect(mixed, hasLength(1));
        expect(mixed.single.left, moreOrLessEquals(2 * _glyph, epsilon: 1));
        expect(mixed.single.right, moreOrLessEquals(3 * _glyph, epsilon: 1));
      },
      variant: macOnly,
    );

    testWidgets(
      'caretRect clamps an offset past the laid out text to its end',
      (tester) async {
        final editable = await _pumpField(tester);
        final boxes = RenderEditableLineBoxes(editable);
        final end = boxes.caretRect(_text.length);
        for (final offset in [_text.length + 1, _text.length + 7]) {
          final past = boxes.caretRect(offset);
          expect(past.left, moreOrLessEquals(end.left, epsilon: 0.01));
          expect(past.top, moreOrLessEquals(end.top, epsilon: 0.01));
          expect(past.bottom, moreOrLessEquals(end.bottom, epsilon: 0.01));
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'findRenderEditable finds the field editable under a root and null without one',
      (tester) async {
        final editable = await _pumpField(tester);
        expect(findRenderEditable(null), isNull);
        expect(findRenderEditable(editable), same(editable));
        expect(
          findRenderEditable(tester.renderObject(find.byType(Scaffold))),
          same(editable),
        );

        await tester.pumpWidget(
          const MaterialApp(home: Text('no field', key: Key('plain'))),
        );
        expect(
          findRenderEditable(tester.renderObject(find.byType(MaterialApp))),
          isNull,
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'line boxes of a scrolled single line field follow the painted text',
      (tester) async {
        const text = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ';
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 150,
                  child: TextField(
                    key: const Key('single'),
                    controller: controller,
                    maxLines: 1,
                    style: OmType.mono(size: 13.5, color: OmColors.fg0),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.showKeyboard(find.byKey(const Key('single')));
        controller.selection = const TextSelection.collapsed(
          offset: text.length,
        );
        await tester.pumpAndSettle();
        final editable = wi159EditableIn(
          tester,
          find.byKey(const Key('single')),
        );
        expect(editable.offset.pixels, greaterThan(100), reason: 'scrolled');

        final boxes = RenderEditableLineBoxes(editable);
        final painted = editable.getLocalRectForCaret(
          const TextPosition(offset: text.length - 2),
        );
        final rect = boxes
            .boxesFor(const TextRange(start: text.length - 2, end: text.length))
            .single;
        expect(rect.left, moreOrLessEquals(painted.left, epsilon: 1));
        expect(rect.width, moreOrLessEquals(2 * _glyph, epsilon: 1));
        // Scrolling sideways does not move the line vertically.
        expect(boxes.lines, hasLength(1));
        expect(rect.top, lessThanOrEqualTo(painted.center.dy));
        expect(rect.bottom, greaterThanOrEqualTo(painted.center.dy));
        expect(
          boxes.lines.single.top,
          moreOrLessEquals(rect.top, epsilon: 0.01),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'line boxes of a scrolled multiline field follow the painted text',
      (tester) async {
        const text = 'l0\nl1\nl2\nl3\nl4\nl5';
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  child: TextField(
                    key: const Key('multi'),
                    controller: controller,
                    maxLines: 2,
                    style: OmType.mono(size: 13.5, color: OmColors.fg0),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.showKeyboard(find.byKey(const Key('multi')));
        controller.selection = const TextSelection.collapsed(
          offset: text.length,
        );
        await tester.pumpAndSettle();
        final editable = wi159EditableIn(
          tester,
          find.byKey(const Key('multi')),
        );
        expect(editable.offset.pixels, greaterThan(20), reason: 'scrolled');

        final boxes = RenderEditableLineBoxes(editable);
        final lines = boxes.lines;
        expect(lines, hasLength(6));
        expect(lines.first.top, lessThan(0), reason: 'scrolled out above');
        for (final (i, line) in lines.indexed) {
          final painted = editable.getLocalRectForCaret(
            TextPosition(offset: line.range.start),
          );
          expect(
            line.top,
            lessThanOrEqualTo(painted.center.dy),
            reason: 'line $i',
          );
          expect(
            line.bottom,
            greaterThanOrEqualTo(painted.center.dy),
            reason: 'line $i',
          );
        }
        final last = boxes.boxesFor(lines.last.range).single;
        expect(
          last.left,
          moreOrLessEquals(
            editable
                .getLocalRectForCaret(
                  TextPosition(offset: lines.last.range.start),
                )
                .left,
            epsilon: 1,
          ),
        );
        expect(last.top, moreOrLessEquals(lines.last.top, epsilon: 0.01));
      },
      variant: macOnly,
    );
  });
}
