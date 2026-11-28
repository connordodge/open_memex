// WI #83 (Spec #61 F3): the FindHighlights overlay painter and its theme
// tokens, over a real pumped editor field (TextSegmentField, the theme's
// even leading), and each mount's `active` flag on its own.
//
// D20: fills are checked through recorded paint calls only (support/
// wi83_find_paint.dart), never pixels under glyphs. Every expected x, width
// and line top comes from the field's own line boxes; the box is 17 px tall
// and 3 px below the top of its 22.95 px body line (pack 83).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/source_surface.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../../support/find_pump.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/wi83_find_paint.dart';

const _wi83LayerKey = Key('wi83-layer');
const _wi83FieldKey = Key('wi83-field');

/// A real editor field of [controller] with a [FindHighlights] of [ranges]
/// stacked over it, measuring the field's editable.
class _Wi83Field extends StatefulWidget {
  const _Wi83Field({
    required this.controller,
    required this.ranges,
    this.layout,
    this.width = 400,
  });

  final LivePreviewController controller;
  final ValueListenable<List<FindPaintRange>> ranges;

  /// The layer's `layout` value, read on each rebuild.
  final ValueListenable<Object?>? layout;
  final double width;

  @override
  State<_Wi83Field> createState() => _Wi83FieldState();
}

class _Wi83FieldState extends State<_Wi83Field> {
  final _chips = KindChipHost();
  final _fieldKey = GlobalKey(debugLabel: 'wi83-field');

  @override
  void dispose() {
    _chips.dispose();
    super.dispose();
  }

  LineBoxSource? _boxes() {
    final editable = findRenderEditable(
      _fieldKey.currentContext?.findRenderObject(),
    );
    return editable != null && editable.hasSize
        ? RenderEditableLineBoxes(editable)
        : null;
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: widget.width,
      child: Stack(
        children: [
          KeyedSubtree(
            key: _fieldKey,
            child: TextSegmentField(
              key: _wi83FieldKey,
              controller: widget.controller,
              kindChips: _chips,
            ),
          ),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: Listenable.merge([widget.ranges, widget.layout]),
              builder: (context, _) => FindHighlights(
                key: _wi83LayerKey,
                ranges: widget.ranges.value,
                boxes: _boxes,
                repaint: widget.controller,
                layout: widget.layout?.value,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A pumped [_Wi83Field]: its controller and its ranges.
typedef _Wi83Pumped = ({
  LivePreviewController controller,
  ValueNotifier<List<FindPaintRange>> ranges,
  ValueNotifier<Object?> layout,
});

/// Pumps [_Wi83Field] of [text] with [ranges].
Future<_Wi83Pumped> _wi83PumpField(
  WidgetTester tester,
  String text,
  List<FindPaintRange> ranges, {
  double width = 400,
}) async {
  final controller = LivePreviewController(text: text);
  addTearDown(controller.dispose);
  final notifier = ValueNotifier(ranges);
  addTearDown(notifier.dispose);
  final layout = ValueNotifier<Object?>(null);
  addTearDown(layout.dispose);
  await pumpFind(
    tester,
    child: _Wi83Field(
      controller: controller,
      ranges: notifier,
      layout: layout,
      width: width,
    ),
  );
  await tester.pump();
  return (controller: controller, ranges: notifier, layout: layout);
}

/// Rebuilds the pumped field's layer with [ranges] (a new list).
Future<void> _wi83Rebuild(
  WidgetTester tester,
  _Wi83Pumped field,
  List<FindPaintRange> ranges,
) async {
  field.ranges.value = ranges;
  await tester.pump();
}

RenderEditable _wi83Editable(WidgetTester tester) =>
    findRenderEditable(tester.renderObject(find.byKey(_wi83FieldKey)))!;

/// The design boxes of [range] in the layer, from the field's line boxes.
List<Wi83Box> _wi83Expected(
  WidgetTester tester,
  TextRange range,
  FindPaintStyle style,
) {
  final editable = _wi83Editable(tester);
  return wi83BoxesOf(
    RenderEditableLineBoxes(editable),
    range,
    style,
    wi83Layer(tester, _wi83LayerKey),
    scale: wi83ScaleOf(editable),
  );
}

/// The line box (layer coordinates) the editable rect [r] sits on.
Rect _wi83LineRect(WidgetTester tester, Rect r) {
  final editable = _wi83Editable(tester);
  return MatrixUtils.transformRect(
    editable.getTransformTo(wi83Layer(tester, _wi83LayerKey)),
    r,
  );
}

void main() {
  holdFontFetches();

  group('theme tokens', () {
    test('findMatch is warn at 0x33 and findMatchLine is warn at 0x80', () {
      expect(wi83SameColor(OmColors.findMatch, wi83OtherFill), isTrue);
      expect(OmColors.findMatch.toARGB32(), 0x33FFD27A);
      expect(OmColors.findMatchLine.toARGB32(), 0x80FFD27A);
      expect(
        wi83SameColor(OmColors.findMatch, OmColors.warnBg),
        isFalse,
        reason: 'warnBg (10%) is not the find fill',
      );
    });
  });

  group('box styles and geometry', () {
    testWidgets(
      'an other match paints a findMatch fill radius 2 and a 1 px inside findMatchLine border 17 tall 3 below its body line top',
      (tester) async {
        const text = 'Sift the rye flour';
        final rye = wi83Find(text, 'rye');
        await _wi83PumpField(tester, text, [
          FindPaintRange(rye.start, rye.end, FindPaintStyle.other),
        ]);
        final editable = _wi83Editable(tester);
        final line = RenderEditableLineBoxes(editable).boxesFor(rye).single;
        expect(
          line.height,
          moreOrLessEquals(22.95, epsilon: 0.2),
          reason: 'fixture: a body line of the real field',
        );
        final lineRect = _wi83LineRect(tester, line);
        final ops = wi83LayerOps(tester, _wi83LayerKey);
        final expected = _wi83Expected(tester, rye, FindPaintStyle.other);
        wi83ExpectBoxes(ops, expected, y: 0.05);
        final box = expected.single.rect;
        expect(box.top - lineRect.top, moreOrLessEquals(3, epsilon: 0.05));
        expect(box.height, moreOrLessEquals(17, epsilon: 0.05));
        expect(box.width, moreOrLessEquals(line.width, epsilon: 0.01));
        final fill = ops.firstWhere(
          (op) => op.isFill && wi83SameColor(op.color, wi83OtherFill),
        );
        expect(fill.radius, 2, reason: 'radius 2');
      },
    );

    testWidgets(
      'the current match paints a solid warn fill with a 1 px outward spread',
      (tester) async {
        const text = 'Sift the rye flour';
        final rye = wi83Find(text, 'rye');
        await _wi83PumpField(tester, text, [
          FindPaintRange(rye.start, rye.end, FindPaintStyle.current),
        ]);
        final ops = wi83LayerOps(tester, _wi83LayerKey);
        wi83ExpectBoxes(
          ops,
          _wi83Expected(tester, rye, FindPaintStyle.current),
          y: 0.05,
        );
        expect(
          ops.where((op) => !wi83SameColor(op.color, wi83Current)),
          isEmpty,
          reason: 'the current box has no other-match fill or border',
        );
      },
    );

    testWidgets('an outline paints the 1 px inside border and no fill', (
      tester,
    ) async {
      const text = 'see the label here';
      final label = wi83Find(text, 'label');
      await _wi83PumpField(tester, text, [
        FindPaintRange(label.start, label.end, FindPaintStyle.outline),
      ]);
      final ops = wi83LayerOps(tester, _wi83LayerKey);
      wi83ExpectBoxes(
        ops,
        _wi83Expected(tester, label, FindPaintStyle.outline),
        y: 0.05,
      );
      expect(ops.where((op) => op.isFill), isEmpty);
    });

    testWidgets(
      'two adjacent matches paint two boxes that touch and each keeps its border',
      (tester) async {
        const text = 'ee bread';
        await _wi83PumpField(tester, text, const [
          FindPaintRange(0, 1, FindPaintStyle.other),
          FindPaintRange(1, 2, FindPaintStyle.other),
        ]);
        final first = _wi83Expected(
          tester,
          const TextRange(start: 0, end: 1),
          FindPaintStyle.other,
        );
        final second = _wi83Expected(
          tester,
          const TextRange(start: 1, end: 2),
          FindPaintStyle.other,
        );
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
          ...first,
          ...second,
        ], y: 0.05);
        expect(
          first.single.rect.right,
          moreOrLessEquals(second.single.rect.left, epsilon: 0.01),
        );
      },
    );

    testWidgets(
      'a match wrapping across two lines paints one box per line box',
      (tester) async {
        // Unique words, so the query spans the wrap and nothing else.
        final words = [
          for (var i = 0; i < 40; i++) 'w${i.toString().padLeft(2, '0')}',
        ];
        final text = words.join(' ');
        final field = await _wi83PumpField(tester, text, const [], width: 200);
        final lines = RenderEditableLineBoxes(_wi83Editable(tester)).lines;
        expect(lines.length, greaterThan(1), reason: 'fixture: the text wraps');
        // The last word of line 0 and the first of line 1.
        final wrap = lines[1].range.start;
        final from = text.lastIndexOf(' ', wrap - 2) + 1;
        final to = text.indexOf(' ', wrap);
        final range = TextRange(start: from, end: to);
        await _wi83Rebuild(tester, field, [
          FindPaintRange(range.start, range.end, FindPaintStyle.current),
        ]);
        final expected = _wi83Expected(tester, range, FindPaintStyle.current);
        expect(expected, hasLength(2), reason: 'fixture: one rect per line');
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), expected, y: 0.05);
        expect(
          expected.first.rect.top,
          lessThan(expected.last.rect.top),
          reason: 'one box on each line, no join',
        );
      },
    );

    testWidgets('a range past the field text end paints to the text end', (
      tester,
    ) async {
      const text = 'rye bread';
      await _wi83PumpField(tester, text, const [
        FindPaintRange(4, 999, FindPaintStyle.other),
      ]);
      expect(tester.takeException(), isNull);
      wi83ExpectBoxes(
        wi83LayerOps(tester, _wi83LayerKey),
        _wi83Expected(
          tester,
          const TextRange(start: 4, end: text.length),
          FindPaintStyle.other,
        ),
        y: 0.05,
      );
    });

    testWidgets('the layer paints boxes only and never draws glyphs', (
      tester,
    ) async {
      const text = 'rye and rye';
      await _wi83PumpField(tester, text, const [
        FindPaintRange(0, 3, FindPaintStyle.current),
        FindPaintRange(8, 11, FindPaintStyle.other),
      ]);
      final recording = wi83Record(wi83Layer(tester, _wi83LayerKey));
      expect(recording.find, isNotEmpty, reason: 'it paints the boxes');
      expect(
        recording.colors.where((c) => c == null),
        isEmpty,
        reason: 'no drawParagraph or other glyph draw (D20)',
      );
      expect(
        recording.ops.where((op) => !wi83IsFindColor(op.color)),
        isEmpty,
        reason: 'only the find colours',
      );
    });

    testWidgets('no ranges paint nothing', (tester) async {
      const text = 'rye and rye';
      final field = await _wi83PumpField(tester, text, const [
        FindPaintRange(0, 3, FindPaintStyle.other),
      ]);
      expect(wi83LayerOps(tester, _wi83LayerKey), isNotEmpty);
      await _wi83Rebuild(tester, field, const []);
      expect(wi83Record(wi83Layer(tester, _wi83LayerKey)).ops, isEmpty);
    });
  });

  group('repaint', () {
    testWidgets(
      'boxes follow the field layout when its text changes with the same ranges',
      (tester) async {
        const text = 'rye bread';
        final field = await _wi83PumpField(tester, text, const [
          FindPaintRange(4, 9, FindPaintStyle.other),
        ]);
        final controller = field.controller;
        final before = _wi83Expected(
          tester,
          const TextRange(start: 4, end: 9),
          FindPaintStyle.other,
        ).single.rect;
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
          (rect: before, style: FindPaintStyle.other),
        ], y: 0.05);
        final paints = debugFindHighlightPaints;
        // The same offsets now lie on a second line.
        controller.text = 'ab\nrye bread';
        await tester.pump();
        expect(debugFindHighlightPaints, greaterThan(paints));
        final after = _wi83Expected(
          tester,
          const TextRange(start: 4, end: 9),
          FindPaintStyle.other,
        ).single.rect;
        expect(after.top, greaterThan(before.bottom));
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
          (rect: after, style: FindPaintStyle.other),
        ], y: 0.05);
      },
    );

    testWidgets(
      'a changed layout value repaints the layer under equal ranges and an equal one does not',
      (tester) async {
        const ranges = [FindPaintRange(0, 3, FindPaintStyle.other)];
        final field = await _wi83PumpField(tester, 'rye bread', ranges);
        field.layout.value = ('numbered', 8.1);
        await tester.pump();
        var paints = debugFindHighlightPaints;
        // A rebuild with equal ranges and an equal (new) layout value.
        field.layout.value = ('numbered', 8.1);
        await _wi83Rebuild(tester, field, [
          const FindPaintRange(0, 3, FindPaintStyle.other),
        ]);
        expect(
          debugFindHighlightPaints,
          paints,
          reason: 'an equal layout value does not repaint',
        );
        // Each part of the layout value counts.
        field.layout.value = ('numbered', 16.2);
        await _wi83Rebuild(tester, field, [
          const FindPaintRange(0, 3, FindPaintStyle.other),
        ]);
        expect(
          debugFindHighlightPaints,
          greaterThan(paints),
          reason: 'a changed layout value repaints',
        );
        paints = debugFindHighlightPaints;
        field.layout.value = null;
        await _wi83Rebuild(tester, field, [
          const FindPaintRange(0, 3, FindPaintStyle.other),
        ]);
        expect(
          debugFindHighlightPaints,
          greaterThan(paints),
          reason: 'a layout value that goes away repaints',
        );
        // The repainted layer still paints the same boxes.
        wi83ExpectBoxes(
          wi83LayerOps(tester, _wi83LayerKey),
          _wi83Expected(
            tester,
            const TextRange(start: 0, end: 3),
            FindPaintStyle.other,
          ),
          y: 0.05,
        );
      },
    );

    // Each arm of the layer's repaint check: a change of any range's start,
    // end or style, or of the list's length, repaints; equal ranges in a new
    // list do not.
    for (final (name, next) in <(String, List<FindPaintRange>)>[
      (
        'a changed range start repaints the layer',
        const [
          FindPaintRange(1, 3, FindPaintStyle.other),
          FindPaintRange(8, 11, FindPaintStyle.current),
        ],
      ),
      (
        'a changed range end repaints the layer',
        const [
          FindPaintRange(0, 2, FindPaintStyle.other),
          FindPaintRange(8, 11, FindPaintStyle.current),
        ],
      ),
      (
        'a changed range style repaints the layer',
        const [
          FindPaintRange(0, 3, FindPaintStyle.current),
          FindPaintRange(8, 11, FindPaintStyle.other),
        ],
      ),
      (
        'an added range repaints the layer',
        const [
          FindPaintRange(0, 3, FindPaintStyle.other),
          FindPaintRange(4, 7, FindPaintStyle.other),
          FindPaintRange(8, 11, FindPaintStyle.current),
        ],
      ),
      (
        'a removed range repaints the layer',
        const [FindPaintRange(0, 3, FindPaintStyle.other)],
      ),
    ]) {
      testWidgets(name, (tester) async {
        const text = 'rye and rye';
        final field = await _wi83PumpField(tester, text, const [
          FindPaintRange(0, 3, FindPaintStyle.other),
          FindPaintRange(8, 11, FindPaintStyle.current),
        ]);
        var paints = debugFindHighlightPaints;
        // An unrelated rebuild: equal ranges in a new list.
        await _wi83Rebuild(tester, field, [
          FindPaintRange(0, 'rye'.length, FindPaintStyle.other),
          FindPaintRange(8, 11, FindPaintStyle.current),
        ]);
        expect(
          debugFindHighlightPaints,
          paints,
          reason: 'unchanged ranges do not repaint',
        );
        paints = debugFindHighlightPaints;
        await _wi83Rebuild(tester, field, next);
        expect(debugFindHighlightPaints, greaterThan(paints));
        // And it paints the new ranges.
        final expected = [
          for (final r in next)
            ..._wi83Expected(
              tester,
              TextRange(start: r.start, end: r.end),
              r.style,
            ),
        ];
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), expected, y: 0.05);
      });
    }
  });

  group('scroll and detached fields', () {
    testWidgets('boxes follow an internally scrolling field when it scrolls', (
      tester,
    ) async {
      final text = [for (var i = 0; i < 12; i++) 'line $i rye'].join('\n');
      final target = wi83Find(text, 'rye', 4);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      final fieldKey = GlobalKey(debugLabel: 'wi83-scroll-field');
      await pumpFind(
        tester,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: Stack(
              children: [
                KeyedSubtree(
                  key: fieldKey,
                  child: TextField(
                    controller: controller,
                    scrollController: scroll,
                    maxLines: 3,
                    decoration: const InputDecoration.collapsed(hintText: null),
                  ),
                ),
                Positioned.fill(
                  child: FindHighlights(
                    key: _wi83LayerKey,
                    ranges: [
                      FindPaintRange(
                        target.start,
                        target.end,
                        FindPaintStyle.other,
                      ),
                    ],
                    boxes: () {
                      final editable = findRenderEditable(
                        fieldKey.currentContext?.findRenderObject(),
                      );
                      return editable != null && editable.hasSize
                          ? RenderEditableLineBoxes(editable)
                          : null;
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final editable = findRenderEditable(
        tester.renderObject(find.byKey(fieldKey)),
      )!;
      List<Wi83Box> expected() => wi83BoxesOf(
        RenderEditableLineBoxes(editable),
        target,
        FindPaintStyle.other,
        wi83Layer(tester, _wi83LayerKey),
        scale: wi83ScaleOf(editable),
      );
      final before = expected().single.rect;
      wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
        (rect: before, style: FindPaintStyle.other),
      ], y: 0.05);
      final paints = debugFindHighlightPaints;
      scroll.jumpTo(40);
      await tester.pump();
      expect(
        debugFindHighlightPaints,
        greaterThan(paints),
        reason: 'a scroll of the field repaints the layer',
      );
      final after = expected().single.rect;
      expect(after.top, moreOrLessEquals(before.top - 40, epsilon: 0.05));
      wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
        (rect: after, style: FindPaintStyle.other),
      ], y: 0.05);
    });

    testWidgets('a layer over a field that is detached paints nothing', (
      tester,
    ) async {
      final field = RenderParagraph(
        const TextSpan(text: 'rye'),
        textDirection: TextDirection.ltr,
      );
      addTearDown(field.dispose);
      field.layout(BoxConstraints.tight(const Size(100, 20)));
      expect(field.hasSize, isTrue, reason: 'fixture: laid out');
      expect(field.attached, isFalse, reason: 'fixture: not in a tree');
      await pumpFind(
        tester,
        child: FindHighlights(
          key: _wi83LayerKey,
          ranges: const [FindPaintRange(0, 3, FindPaintStyle.other)],
          boxes: () => _Wi83Unlaid(field),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(wi83LayerOps(tester, _wi83LayerKey), isEmpty);
    });

    testWidgets(
      'a layer over a field that is attached but not laid out paints nothing',
      (tester) async {
        final textKey = GlobalKey(debugLabel: 'wi83-offstage-text');
        await pumpFind(
          tester,
          child: Stack(
            children: [
              _Wi83NeverLaidOut(
                child: RichText(
                  key: textKey,
                  text: const TextSpan(text: 'rye'),
                  textDirection: TextDirection.ltr,
                ),
              ),
              Positioned.fill(
                child: FindHighlights(
                  key: _wi83LayerKey,
                  ranges: const [FindPaintRange(0, 3, FindPaintStyle.other)],
                  boxes: () {
                    final box = textKey.currentContext?.findRenderObject();
                    return box is RenderBox ? _Wi83Unlaid(box) : null;
                  },
                ),
              ),
            ],
          ),
        );
        final paragraph =
            textKey.currentContext!.findRenderObject()! as RenderParagraph;
        expect(paragraph.attached, isTrue, reason: 'fixture: in the tree');
        expect(
          paragraph.hasSize,
          isFalse,
          reason: 'fixture: its parent never lays it out',
        );
        expect(tester.takeException(), isNull);
        expect(wi83LayerOps(tester, _wi83LayerKey), isEmpty);
      },
    );
  });

  group('FindGridScope', () {
    // A dependent counts its builds; its `const` child rebuilds only when
    // the scope notifies.
    var builds = 0;
    FindGridScope? seen;

    Future<void> pumpScope(
      WidgetTester tester, {
      int segment = 1,
      int textStart = 10,
      bool active = true,
      int? cardRow,
    }) => tester.pumpWidget(
      FindGridScope(
        segment: segment,
        textStart: textStart,
        active: active,
        cardRow: cardRow,
        child: const _Wi83ScopeProbe(),
      ),
    );

    setUp(() {
      builds = 0;
      seen = null;
      _wi83ScopeBuilt = (scope) {
        builds++;
        seen = scope;
      };
    });

    testWidgets('a dependent reads the scope it sits under and none above it', (
      tester,
    ) async {
      await tester.pumpWidget(const _Wi83ScopeProbe());
      expect(seen, isNull);
      await pumpScope(tester);
      expect(seen!.segment, 1);
      expect(seen!.textStart, 10);
      expect(seen!.active, isTrue);
    });

    for (final (name, segment, textStart, active, notifies) in [
      (
        'a scope with only its segment changed notifies its dependents',
        2,
        10,
        true,
        true,
      ),
      (
        'a scope with only its text start changed notifies its dependents',
        1,
        11,
        true,
        true,
      ),
      (
        'a scope with only its active flag changed notifies its dependents',
        1,
        10,
        false,
        true,
      ),
      (
        'a scope with nothing changed does not notify its dependents',
        1,
        10,
        true,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await pumpScope(tester);
        final first = builds;
        await pumpScope(
          tester,
          segment: segment,
          textStart: textStart,
          active: active,
        );
        expect(builds - first, notifies ? 1 : 0);
        expect(seen!.segment, segment);
        expect(seen!.textStart, textStart);
        expect(seen!.active, active);
      });
    }

    for (final (name, from, to, notifies) in <(String, int?, int?, bool)>[
      (
        'a scope that becomes a card scope notifies its dependents',
        null,
        0,
        true,
      ),
      (
        'a scope that stops being a card scope notifies its dependents',
        0,
        null,
        true,
      ),
      (
        'a scope with only its card row changed notifies its dependents',
        0,
        1,
        true,
      ),
      (
        'a card scope with nothing changed does not notify its dependents',
        2,
        2,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await pumpScope(tester, cardRow: from);
        final first = builds;
        await pumpScope(tester, cardRow: to);
        expect(builds - first, notifies ? 1 : 0);
        expect(seen!.cardRow, to);
      });
    }

    testWidgets(
      'a text segment scope matches body text and keys its cells find-highlights-grid',
      (tester) async {
        await pumpScope(tester, segment: 4);
        expect(seen!.cardRow, isNull);
        expect(seen!.kind, FindSourceKind.body);
        expect(seen!.cellKey(2, 1), findGridHighlightsKey(4, 2, 1));
        expect(
          (seen!.cellKey(2, 1) as ValueKey<String>).value,
          'find-highlights-grid-4-2-1',
        );
      },
    );

    testWidgets(
      'a card scope matches card text and keys its cells find-highlights-card-grid',
      (tester) async {
        await pumpScope(tester, segment: 4, cardRow: 3);
        expect(seen!.cardRow, 3);
        expect(seen!.kind, FindSourceKind.card);
        expect(seen!.cellKey(2, 1), findCardGridHighlightsKey(4, 3, 2, 1));
        expect(
          (seen!.cellKey(2, 1) as ValueKey<String>).value,
          'find-highlights-card-grid-4-3-2-1',
        );
        // A card row 0 is a card scope too.
        await pumpScope(tester, segment: 4, cardRow: 0);
        expect(seen!.kind, FindSourceKind.card);
        expect(seen!.cellKey(0, 0), findCardGridHighlightsKey(4, 0, 0, 0));
      },
    );
  });

  group('card without a segment', () {
    testWidgets(
      'a card row with no segment and no excerpt card mounts no layer',
      (tester) async {
        const text = 'Raised rye to 78%.';
        await pumpFind(
          tester,
          sources: [
            const FindSource(segment: 3, kind: FindSourceKind.card, text: text),
          ],
          query: 'rye',
          child: const CardRows(text: text),
        );
        expect(find.byType(FindHighlights), findsNothing);
        expect(find.byKey(const ValueKey('card-row-text-0')), findsOneWidget);
      },
    );
  });

  group('pointers', () {
    testWidgets(
      'the layer ignores pointers: a tap on a highlighted word places the caret there',
      (tester) async {
        const text = 'Sift the rye flour';
        final rye = wi83Find(text, 'rye');
        final field = await _wi83PumpField(tester, text, [
          FindPaintRange(rye.start, rye.end, FindPaintStyle.current),
        ]);
        final controller = field.controller;
        final layer = wi83Layer(tester, _wi83LayerKey);
        final box = _wi83Expected(
          tester,
          rye,
          FindPaintStyle.current,
        ).single.rect;
        // Between `r` and `y`: the caret lands at rye.start + 1.
        final local = Offset(box.left + box.width / 3, box.center.dy);
        wi83ExpectBoxes(wi83LayerOps(tester, _wi83LayerKey), [
          (rect: box, style: FindPaintStyle.current),
        ], y: 0.05);
        final global = layer.localToGlobal(local);
        final path = tester.hitTestOnBinding(global).path;
        expect(
          path.any((entry) => identical(entry.target, layer)),
          isFalse,
          reason: 'the layer is never hit (D14)',
        );
        final editable = _wi83Editable(tester);
        final want = editable.getPositionForPoint(global).offset;
        await tester.tapAt(global);
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.selection, TextSelection.collapsed(offset: want));
        expect(want, inInclusiveRange(rye.start, rye.end));
      },
    );
  });

  group('excerpt card table cells and card stacking', () {
    // A card of a prose row and a table: its header cell and a body cell
    // hold `rye`, the body cell after other text.
    const text =
        'Intro rye\n| rye bread | B |\n| --- | --- |\n| big rye | x |\n';
    final sources = [
      const FindSource(segment: 3, kind: FindSourceKind.card, text: text),
    ];
    final tableRow = splitRows(
      text,
      atSegmentStart: true,
    ).indexWhere((spec) => spec.kind == RowKind.table);

    RenderParagraph paragraphOf(WidgetTester tester, Key key) =>
        tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is FindParagraphHighlights && w.layerKey == key,
            ),
            matching: find.byType(RichText),
          ),
        );

    List<Wi83Box> boxesIn(
      WidgetTester tester,
      Key key,
      TextRange range,
      FindPaintStyle style,
    ) {
      final paragraph = paragraphOf(tester, key);
      return wi83BoxesOf(
        RenderParagraphLineBoxes(paragraph),
        range,
        style,
        wi83Layer(tester, key),
        scale: wi83ScaleOf(paragraph),
      );
    }

    Key cell(int g, int c) => findCardGridHighlightsKey(3, tableRow, g, c);

    testWidgets(
      'a card table cell match paints in its cell with the card keys and the current one is solid',
      (tester) async {
        expect(tableRow, 1, reason: 'fixture: the table is card row 1');
        // Matches in order: the prose row, the header cell, the body cell.
        await pumpFind(
          tester,
          sources: sources,
          query: 'rye',
          current: 1,
          child: const CardRows(text: text, segment: 3),
        );
        expect(
          find.byKey(const ValueKey('card-table-1')),
          findsOneWidget,
          reason: 'the table stays a grid',
        );
        wi83ExpectBoxes(
          wi83LayerOps(tester, cell(0, 0)),
          boxesIn(
            tester,
            cell(0, 0),
            const TextRange(start: 0, end: 3),
            FindPaintStyle.current,
          ),
          reason: 'header cell',
        );
        wi83ExpectBoxes(
          wi83LayerOps(tester, cell(1, 0)),
          boxesIn(
            tester,
            cell(1, 0),
            const TextRange(start: 4, end: 7),
            FindPaintStyle.other,
          ),
          reason: 'body cell',
        );
        expect(wi83LayerOps(tester, cell(0, 1)), isEmpty, reason: 'cell B');
        expect(wi83LayerOps(tester, cell(1, 1)), isEmpty, reason: 'cell x');
        // The prose row paints its own match, as an other box.
        wi83ExpectBoxes(
          wi83LayerOps(tester, findCardHighlightsKey(3, 0)),
          boxesIn(
            tester,
            findCardHighlightsKey(3, 0),
            const TextRange(start: 6, end: 9),
            FindPaintStyle.other,
          ),
          reason: 'prose row',
        );
        // The table row itself has no paragraph layer: its cells do.
        expect(find.byKey(findCardHighlightsKey(3, 1)), findsNothing);
      },
    );

    testWidgets(
      'a card table cell layer is not an excerpt card body layer and a card scope does not reach a text segment key',
      (tester) async {
        await pumpFind(
          tester,
          sources: sources,
          query: 'rye',
          child: const CardRows(text: text, segment: 3),
        );
        expect(
          find.byKey(findGridHighlightsKey(3, 0, 0)),
          findsNothing,
          reason: 'a card cell never takes a text segment grid key',
        );
        expect(find.byKey(cell(0, 0)), findsOneWidget);
      },
    );

    testWidgets('a card with active false paints no find boxes in its table', (
      tester,
    ) async {
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: const CardRows(text: text, segment: 3),
      );
      expect(wi83LayerOps(tester, cell(0, 0)), isNotEmpty);
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: const CardRows(text: text, segment: 3, active: false),
      );
      expect(_wi83FindOpsAt(tester, cell(0, 0)), isEmpty);
      expect(_wi83FindOpsAt(tester, cell(1, 0)), isEmpty);
      expect(_wi83FindOpsAt(tester, findCardHighlightsKey(3, 0)), isEmpty);
    });

    testWidgets(
      'a card row layer and a card table cell layer paint below the row text',
      (tester) async {
        await pumpFind(
          tester,
          sources: sources,
          query: 'rye',
          child: const CardRows(text: text, segment: 3),
        );
        for (final key in [
          findCardHighlightsKey(3, 0),
          cell(0, 0),
          cell(1, 0),
        ]) {
          final stack = tester.renderObject(
            find.byWidgetPredicate(
              (w) => w is FindParagraphHighlights && w.layerKey == key,
            ),
          );
          final colors = wi83Record(stack).colors;
          final lastFind = colors.lastIndexWhere(
            (c) => c != null && wi83IsFindColor(c),
          );
          final firstText = colors.indexWhere((c) => c == null);
          expect(lastFind, isNonNegative, reason: '$key: boxes paint');
          expect(firstText, isNonNegative, reason: '$key: the text paints');
          expect(lastFind, lessThan(firstText), reason: '$key: below its text');
        }
      },
    );

    testWidgets(
      'a card row repaints when its text changes under equal ranges and not when it is rebuilt unchanged',
      (tester) async {
        const before = 'Raised rye to 78%.';
        final next = ValueNotifier<(String, int)>((before, 0));
        addTearDown(next.dispose);
        await pumpFind(
          tester,
          sources: const [
            FindSource(segment: 3, kind: FindSourceKind.card, text: before),
          ],
          query: 'rye',
          child: ValueListenableBuilder(
            valueListenable: next,
            builder: (context, v, _) => CardRows(text: v.$1, segment: 3),
          ),
        );
        var paints = debugFindHighlightPaints;
        next.value = (before, 1);
        await tester.pump();
        expect(
          debugFindHighlightPaints,
          paints,
          reason: 'unchanged: no repaint',
        );
        next.value = ('Raised rye to 79%.', 2);
        await tester.pump();
        expect(
          debugFindHighlightPaints,
          greaterThan(paints),
          reason: 'the row text changed: the layer repaints',
        );
        paints = debugFindHighlightPaints;
        next.value = ('Raised rye to 79%.', 3);
        await tester.pump();
        expect(debugFindHighlightPaints, paints, reason: 'unchanged again');
      },
    );

    testWidgets(
      'a card table cell repaints when its text changes under equal ranges and not when it is rebuilt unchanged',
      (tester) async {
        const before = '| rye 78 | B |\n| --- | --- |\n| x | y |\n';
        final next = ValueNotifier<(String, int)>((before, 0));
        addTearDown(next.dispose);
        await pumpFind(
          tester,
          sources: const [
            FindSource(segment: 3, kind: FindSourceKind.card, text: before),
          ],
          query: 'rye',
          child: ValueListenableBuilder(
            valueListenable: next,
            builder: (context, v, _) => CardRows(text: v.$1, segment: 3),
          ),
        );
        final key = findCardGridHighlightsKey(3, 0, 0, 0);
        expect(wi83LayerOps(tester, key), isNotEmpty, reason: 'fixture');
        var paints = debugFindHighlightPaints;
        next.value = (before, 1);
        await tester.pump();
        expect(
          debugFindHighlightPaints,
          paints,
          reason: 'unchanged: no repaint',
        );
        next.value = (before.replaceFirst('78', '79'), 2);
        await tester.pump();
        expect(
          debugFindHighlightPaints,
          greaterThan(paints),
          reason: 'the cell text changed: its layer repaints',
        );
      },
    );
  });

  group('mounts with active false', () {
    testWidgets('a Source surface with active false paints no find boxes', (
      tester,
    ) async {
      const text = 'rye bread and rye';
      final ctrl = TextEditingController(text: text);
      addTearDown(ctrl.dispose);
      final sources = [
        const FindSource(segment: 0, kind: FindSourceKind.source, text: text),
      ];
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: SourceSurface(bodyCtrl: ctrl, onContentChanged: (_) {}),
      );
      final ops = wi83LayerOps(tester, findSourceHighlightsKey);
      expect(ops, isNotEmpty, reason: 'active by default: it paints');
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: SourceSurface(
          bodyCtrl: ctrl,
          onContentChanged: (_) {},
          active: false,
        ),
      );
      expect(_wi83FindOpsAt(tester, findSourceHighlightsKey), isEmpty);
    });

    testWidgets('a card with active false paints no find boxes', (
      tester,
    ) async {
      const text = 'Raised rye to 78%.';
      final sources = [
        const FindSource(segment: 3, kind: FindSourceKind.card, text: text),
      ];
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: const CardRows(text: text, segment: 3),
      );
      final key = findCardHighlightsKey(3, 0);
      expect(wi83LayerOps(tester, key), isNotEmpty, reason: 'active: paints');
      await pumpFind(
        tester,
        sources: sources,
        query: 'rye',
        child: const CardRows(text: text, segment: 3, active: false),
      );
      expect(_wi83FindOpsAt(tester, key), isEmpty);
    });

    testWidgets(
      'a text segment with active false paints no find boxes in its rows or grid cells',
      (tester) async {
        const text = 'rye one\n| A | B |\n| --- | --- |\n| rye | x |\n';
        final sources = [wi83Body(0, text)];
        await pumpFind(
          tester,
          sources: sources,
          query: 'rye',
          child: _Wi83Segment(text: text),
        );
        final row = findHighlightsKey(0, 0);
        final cell = findGridHighlightsKey(0, 1, 0);
        expect(wi83LayerOps(tester, row), isNotEmpty, reason: 'row paints');
        expect(wi83LayerOps(tester, cell), isNotEmpty, reason: 'cell paints');
        await pumpFind(
          tester,
          sources: sources,
          query: 'rye',
          child: _Wi83Segment(text: text, active: false),
        );
        expect(_wi83FindOpsAt(tester, row), isEmpty);
        expect(_wi83FindOpsAt(tester, cell), isEmpty);
        expect(
          find.byType(SegmentView),
          findsOneWidget,
          reason: 'the segment itself still shows',
        );
      },
    );
  });
}

/// The find ops under [key], or none when no layer is mounted there.
List<Wi83Op> _wi83FindOpsAt(WidgetTester tester, Key key) =>
    find.byKey(key).evaluate().isEmpty ? const [] : wi83LayerOps(tester, key);

/// A bare text segment of [text] (rows from A1, real editor fields), as
/// `SegmentedBody` builds it, segment index 0, unfocused.
class _Wi83Segment extends StatefulWidget {
  const _Wi83Segment({required this.text, this.active = true});

  final String text;
  final bool active;

  @override
  State<_Wi83Segment> createState() => _Wi83SegmentState();
}

class _Wi83SegmentState extends State<_Wi83Segment> {
  late final _controller = LivePreviewController(text: widget.text);
  final _focus = FocusNode();
  final _gate = ValueNotifier(false);
  final _chips = KindChipHost();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _gate.dispose();
    _chips.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: SegmentView(
      index: 0,
      controller: _controller,
      focusNode: _focus,
      revealGate: _gate,
      minLines: 1,
      hintText: null,
      onChanged: () {},
      onRowRemoved: (_) {},
      active: widget.active,
      fieldBuilder: (context, row) => TextSegmentField(
        controller: row.controller,
        focusNode: row.focusNode,
        kindChips: _chips,
        paintsSelection: false,
      ),
      builder: (context, rows, _) => rows,
    ),
  );
}

/// A line box source over a [RenderParagraph] that was never laid out: its
/// geometry accessors fail if the layer asks for them.
class _Wi83Unlaid implements LineBoxSource {
  _Wi83Unlaid(this.box);

  @override
  final RenderBox box;

  @override
  List<LineBox> get lines => throw StateError('not laid out');

  @override
  List<Rect> boxesFor(TextRange range) => throw StateError('not laid out');

  @override
  Rect caretRect(int offset) => throw StateError('not laid out');

  @override
  int offsetAt(Offset point) => throw StateError('not laid out');

  @override
  LineBox lineAt(int offset) => throw StateError('not laid out');
}

/// Called by [_Wi83ScopeProbe] on every build with the scope it reads.
void Function(FindGridScope? scope) _wi83ScopeBuilt = (_) {};

class _Wi83ScopeProbe extends StatelessWidget {
  const _Wi83ScopeProbe();

  @override
  Widget build(BuildContext context) {
    _wi83ScopeBuilt(FindGridScope.maybeOf(context));
    return const SizedBox.shrink();
  }
}

/// Mounts [child] but never lays it out nor paints it, as a parent that
/// skips a child would.
class _Wi83NeverLaidOut extends SingleChildRenderObjectWidget {
  const _Wi83NeverLaidOut({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _Wi83RenderNeverLaidOut();
}

class _Wi83RenderNeverLaidOut extends RenderProxyBox {
  @override
  void performLayout() => size = constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {}

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {}
}
