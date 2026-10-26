// WI #165 (B2, Spec #157 R4, R6, R13; TD4, TD10; TS2, TS9): live preview's
// painted decorations, drawn from a field's real line boxes.
// - Pure geometry (codeBoxRect, quoteBandRect, codePillRects, ruleRect,
//   layoutDecorations) over a fake LineBoxSource: empty ranges, wrapped
//   lines, line-start code spans, colours, radii, paint order (TD10).
// - The painter: pixels of a LivePreviewDecorations around a real
//   EditableText measured through RenderEditableLineBoxes (D6), its text
//   column starting at textLeft (R6).
// - A daily note person segment paints nothing into the capture gutter.
// - Decorations never change text: open and edit send the same bytes.
// Design pack design/156-live-preview/packs/165.md wins over WI numbers:
// pill 17 px tall at line top + 2, radius 3; rule 1 px line2 at top + 11.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_frame.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/font_fetch_hold.dart';
import '../support/segment_editing_finder.dart';

// ------------------------------------------------------------------ fakes

/// The body line height (13.5 x 1.7).
const double _wi165Line = 22.95;

/// A [LineBoxSource] over [text] laid out in fixed-width columns: every
/// source line is one visual line, or several of [wrap] code units each;
/// each visual line of source line `i` is `heights[i]` (default [_wi165Line])
/// tall; characters at [hidden] offsets are zero-width (as B1 hides
/// markers); x starts at [left].
class _Wi165FakeBoxes implements LineBoxSource {
  _Wi165FakeBoxes(
    this.text, {
    this.left = 0,
    int? wrap,
    Map<int, double> heights = const {},
    this.hidden = const {},
  }) {
    var top = 0.0;
    var start = 0;
    final source = text.split('\n');
    for (var i = 0; i < source.length; i++) {
      final end = start + source[i].length;
      final height = heights[i] ?? _wi165Line;
      var at = start;
      do {
        final chunkEnd = wrap == null ? end : (at + wrap).clamp(at, end);
        _lines.add(
          LineBox(
            range: TextRange(start: at, end: chunkEnd),
            top: top,
            bottom: top + height,
          ),
        );
        top += height;
        at = chunkEnd;
      } while (at < end);
      start = end + 1;
    }
  }

  final String text;
  final double left;
  final double charWidth = 8.1;
  final Set<int> hidden;
  final List<LineBox> _lines = [];

  /// The x of [offset] on [line].
  double xOf(LineBox line, int offset) {
    var visible = 0;
    for (var i = line.range.start; i < offset; i++) {
      if (!hidden.contains(i)) visible++;
    }
    return left + visible * charWidth;
  }

  @override
  RenderBox get box => throw UnimplementedError('the fake has no render box');

  @override
  List<LineBox> get lines => List.unmodifiable(_lines);

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    return [
      for (final line in _lines)
        if (_overlap(range, line) case (final s, final e))
          Rect.fromLTRB(xOf(line, s), line.top, xOf(line, e), line.bottom),
    ];
  }

  static (int, int)? _overlap(TextRange range, LineBox line) {
    final s = range.start > line.range.start ? range.start : line.range.start;
    final e = range.end < line.range.end ? range.end : line.range.end;
    return s < e ? (s, e) : null;
  }

  @override
  Rect caretRect(int offset) {
    final line = lineHolding(_lines, offset);
    return Rect.fromLTRB(
      xOf(line, offset),
      line.top,
      xOf(line, offset) + 1,
      line.bottom,
    );
  }

  @override
  int offsetAt(Offset point) => throw UnimplementedError();
}

/// Every backtick offset of [text] (to hide them, as B1 does off the caret
/// line).
Set<int> _wi165Ticks(String text) => {
  for (var i = 0; i < text.length; i++)
    if (text.codeUnitAt(i) == 0x60) i,
};

void _wi165ExpectRect(Rect? actual, Rect expected, {String reason = ''}) {
  expect(actual, isNotNull, reason: 'expected $expected. $reason');
  final a = actual!;
  for (final (name, got, want) in [
    ('left', a.left, expected.left),
    ('top', a.top, expected.top),
    ('right', a.right, expected.right),
    ('bottom', a.bottom, expected.bottom),
  ]) {
    expect(
      got,
      moreOrLessEquals(want, epsilon: 1e-6),
      reason: '$name of $a, expected $expected. $reason',
    );
  }
}

List<PaintedDecoration> _wi165Of(
  List<PaintedDecoration> all,
  DecorationKind kind,
) => [
  for (final d in all)
    if (d.kind == kind) d,
];

// --------------------------------------------------------- widget harness

final _wi165BoundaryKey = GlobalKey(debugLabel: 'wi165-boundary');
const double _wi165Width = 420;
const _wi165Clear = Color(0x00000000);

/// One pumped decorated field.
final class _Wi165Field {
  _Wi165Field(this.controller, this._editable);

  final LivePreviewController controller;
  final GlobalKey _editable;

  LineBoxSource get boxes => RenderEditableLineBoxes(
    findRenderEditable(_editable.currentContext!.findRenderObject())!,
  );

  /// Line [i]'s box, in global coordinates (x across the editable).
  Rect line(int i) {
    final source = boxes;
    final l = source.lines[i];
    final origin = source.box.localToGlobal(Offset.zero);
    return Rect.fromLTRB(
      origin.dx,
      origin.dy + l.top,
      origin.dx + source.box.size.width,
      origin.dy + l.bottom,
    );
  }

  /// The single line rect of [range], in global coordinates.
  Rect range(TextRange range) {
    final source = boxes;
    return source
        .boxesFor(range)
        .single
        .shift(source.box.localToGlobal(Offset.zero));
  }
}

/// Pumps [controller] (default: a [LivePreviewController] over [text]) in
/// an [EditableText] whose text column starts at [textLeft] and whose field
/// starts at [fieldLeft] (default [textLeft]), inside a
/// [LivePreviewDecorations] [_wi165Width] wide, over a `surface2` background,
/// under a repaint boundary at the top left. [textColor] defaults to
/// transparent so pixels show only the decorations.
Future<_Wi165Field> _wi165Pump(
  WidgetTester tester, {
  String text = '',
  LivePreviewController? controller,
  double textLeft = 14,
  double? fieldLeft,
  Color? quoteBandColor,
  Color textColor = _wi165Clear,
  bool measured = true,
  bool measuresNull = false,
}) async {
  final c = controller ?? LivePreviewController(text: text);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  final editable = GlobalKey(debugLabel: 'wi165-editable');
  LineBoxSource? measure() {
    if (measuresNull) return null;
    final e = findRenderEditable(editable.currentContext?.findRenderObject());
    return e == null ? null : RenderEditableLineBoxes(e);
  }

  final field = Padding(
    padding: EdgeInsets.only(left: fieldLeft ?? textLeft),
    child: EditableText(
      key: editable,
      controller: c,
      focusNode: focus,
      style: TextStyle(fontSize: 13.5, height: 1.7, color: textColor),
      cursorColor: OmColors.accent,
      backgroundCursorColor: OmColors.surface2,
      maxLines: null,
    ),
  );
  final boxes = measured ? measure : null;
  final decorations = quoteBandColor == null
      ? LivePreviewDecorations(
          controller: c,
          boxes: boxes,
          textLeft: textLeft,
          child: field,
        )
      : LivePreviewDecorations(
          controller: c,
          boxes: boxes,
          textLeft: textLeft,
          quoteBandColor: quoteBandColor,
          child: field,
        );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _wi165BoundaryKey,
          child: ColoredBox(
            color: OmColors.surface2,
            child: SizedBox(
              width: _wi165Width,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: decorations,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Wi165Field(c, editable);
}

/// The RGBA pixels of a repaint boundary, read at global points.
final class _Wi165Pixels {
  _Wi165Pixels(this._bytes, this.width, this.height, this._origin);

  final ByteData _bytes;
  final int width;
  final int height;
  final Offset _origin;

  /// The pixel holding global [point] (floored).
  Color at(Offset point) {
    final p = point - _origin;
    final x = p.dx.floor();
    final y = p.dy.floor();
    expect(x, inInclusiveRange(0, width - 1), reason: 'x of $point');
    expect(y, inInclusiveRange(0, height - 1), reason: 'y of $point');
    return atPixel(x, y);
  }

  /// The pixel at image column [x], row [y].
  Color atPixel(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _bytes.getUint8(i + 3),
      _bytes.getUint8(i),
      _bytes.getUint8(i + 1),
      _bytes.getUint8(i + 2),
    );
  }

  /// The global x of image column [x]'s left edge.
  double globalX(int x) => _origin.dx + x;
}

Future<_Wi165Pixels> _wi165Capture(
  WidgetTester tester, {
  Finder? boundary,
}) async {
  final render = tester.renderObject<RenderRepaintBoundary>(
    boundary ?? find.byKey(_wi165BoundaryKey),
  );
  final image = (await tester.runAsync(() => render.toImage()))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final pixels = _Wi165Pixels(
    bytes,
    image.width,
    image.height,
    render.localToGlobal(Offset.zero),
  );
  image.dispose();
  return pixels;
}

int _wi165Channel(double c) => (c * 255).round();

/// Matches a [Color] whose RGBA channels are each within [tolerance] of
/// [expected].
class _Wi165Near extends Matcher {
  const _Wi165Near(this.expected, {this.tolerance = 1});

  final Color expected;
  final int tolerance;

  static List<int> _channels(Color c) => [
    _wi165Channel(c.r),
    _wi165Channel(c.g),
    _wi165Channel(c.b),
    _wi165Channel(c.a),
  ];

  static String _hex(Color c) =>
      '0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! Color) return false;
    final a = _channels(item);
    final b = _channels(expected);
    for (var i = 0; i < 4; i++) {
      if ((a[i] - b[i]).abs() > tolerance) return false;
    }
    return true;
  }

  @override
  Description describe(Description description) =>
      description.add('a colour within $tolerance of ${_hex(expected)}');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) => item is Color
      ? mismatchDescription.add('is ${_hex(item)}')
      : mismatchDescription.add('is not a Color');
}

/// The box border colour as painted over the box fill.
Color get _wi165BorderOverFill =>
    Color.alphaBlend(OmColors.line1, OmColors.surface1);

/// Hides every backtick (font size 0, zero width), as B1 does off the caret
/// line; no character is added or removed.
class _Wi165HiddenTicksController extends LivePreviewController {
  _Wi165HiddenTicksController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final children = <TextSpan>[];
    var at = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0x60) continue;
      if (i > at) children.add(TextSpan(text: text.substring(at, i)));
      children.add(const TextSpan(text: '`', style: TextStyle(fontSize: 0)));
      at = i + 1;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: children);
  }
}

// ------------------------------------------------- real editor harnesses

Note _wi165Note(String content, {required bool daily}) => Note(
  id: daily ? 'daily-2026-10-03' : 'topic-165',
  title: daily ? '2026-10-03' : 'Decorations',
  contentMd: content,
  frontmatter: daily ? '{"role":"daily"}' : '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

final _wi165EditorKey = GlobalKey(debugLabel: 'wi165-editor');

/// A topic body with every decoration: a code span, two quote lines, a
/// rule and a fenced block.
const _wi165Decorated =
    'Intro with `code` span\n'
    '> quoted line\n'
    '> second quote\n'
    '---\n'
    '```dart\n'
    'let a = 1;\n'
    '```\n'
    'Outro\n';

// ------------------------------------- listener counting fakes (verify)

/// A reveal gate that counts its listeners.
class _Wi165CountingGate extends ValueNotifier<bool> {
  _Wi165CountingGate(super.value);

  final List<VoidCallback> _listeners = [];
  int get listeners => _listeners.length;

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }
}

/// A [LivePreviewController] that counts its listeners.
class _Wi165CountingController extends LivePreviewController {
  _Wi165CountingController({super.text});

  final List<VoidCallback> _listeners = [];
  int get listeners => _listeners.length;

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }
}

/// The fenced block text the reveal tests use: the fence opens on line 2
/// and closes on line 4.
const _wi165RevealText = 'intro\n\n```\nlet a = 1;\n```\n\nafter';

/// Expects the box of [_wi165RevealText] in [f] to be 8 px outset above
/// and below when [outset], flush with its fence lines otherwise.
Future<void> _wi165ExpectOutset(
  WidgetTester tester,
  _Wi165Field f, {
  required bool outset,
  required String reason,
}) async {
  final open = f.line(2);
  final close = f.line(4);
  const x = 20.0;
  final px = await _wi165Capture(tester);
  final top = outset ? open.top - 8 : open.top;
  final bottom = outset ? close.bottom + 8 : close.bottom;
  expect(
    px.at(Offset(x, top + 2.5)),
    const _Wi165Near(OmColors.surface1),
    reason: '$reason: inside the top',
  );
  expect(
    px.at(Offset(x, top - 1.5)),
    const _Wi165Near(OmColors.surface2),
    reason: '$reason: above the top',
  );
  expect(
    px.at(Offset(x, bottom - 2.5)),
    const _Wi165Near(OmColors.surface1),
    reason: '$reason: inside the bottom',
  );
  expect(
    px.at(Offset(x, bottom + 1.5)),
    const _Wi165Near(OmColors.surface2),
    reason: '$reason: below the bottom',
  );
}

/// [decorations] in the same tree [_wi165Pump] builds.
Widget _wi165Tree(Widget decorations) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Align(
    alignment: Alignment.topLeft,
    child: RepaintBoundary(
      key: _wi165BoundaryKey,
      child: ColoredBox(
        color: OmColors.surface2,
        child: SizedBox(
          width: _wi165Width,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: decorations,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  holdFontFetches();

  group('code box geometry (AC1, AC6)', () {
    const text = 'intro\n```\nlet a = 1;\nlet b = 2;\n```\nafter';
    final block = TextRange(
      start: text.indexOf('```'),
      end: text.lastIndexOf('```') + 3,
    );
    // Hidden fence lines are 8 px (pack #161); the code text is inset.
    _Wi165FakeBoxes boxes() =>
        _Wi165FakeBoxes(text, left: 16.2, heights: const {1: 8, 4: 8});

    test(
      'codeBoxRect spans the text column from the first fence line top to the last fence line bottom',
      () {
        final b = boxes();
        _wi165ExpectRect(
          codeBoxRect(b, block, columnLeft: 0, columnRight: 300),
          Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[4].bottom),
          reason: 'left edge is the text column, not the inset code text',
        );
      },
    );

    test('codeBoxRect outsets the box 8 px above and below while revealed', () {
      final b = boxes();
      _wi165ExpectRect(
        codeBoxRect(b, block, columnLeft: 0, columnRight: 300, revealed: true),
        Rect.fromLTRB(0, b.lines[1].top - 8, 300, b.lines[4].bottom + 8),
      );
    });

    test('codeBoxRect of an empty range is null', () {
      expect(
        codeBoxRect(
          boxes(),
          TextRange.collapsed(block.start),
          columnLeft: 0,
          columnRight: 300,
        ),
        isNull,
      );
    });

    test('codeBoxRect covers every visual line of a wrapped code line', () {
      final long = '```\n${'x' * 30}\n```';
      final b = _Wi165FakeBoxes(long, wrap: 20);
      expect(b.lines, hasLength(4), reason: 'the code line wraps once');
      _wi165ExpectRect(
        codeBoxRect(
          b,
          TextRange(start: 0, end: long.length),
          columnLeft: 0,
          columnRight: 300,
        ),
        Rect.fromLTRB(0, b.lines.first.top, 300, b.lines.last.bottom),
      );
    });
  });

  group('quote band geometry (AC2, AC6)', () {
    test(
      'quoteBandRect spans the text column and every visual line of a wrapped quote line',
      () {
        final quote = '> ${'q' * 30}';
        final text = 'intro\n$quote\nafter';
        final b = _Wi165FakeBoxes(text, wrap: 20);
        expect(b.lines, hasLength(4), reason: 'the quote line wraps once');
        _wi165ExpectRect(
          quoteBandRect(
            b,
            TextRange(start: 6, end: 6 + quote.length),
            columnLeft: 0,
            columnRight: 300,
          ),
          Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[2].bottom),
        );
      },
    );

    test(
      'quoteBandRect of two consecutive quote lines is one band with no gap',
      () {
        const text = 'intro\n> one\n> two\nafter';
        final b = _Wi165FakeBoxes(text);
        _wi165ExpectRect(
          quoteBandRect(
            b,
            TextRange(
              start: text.indexOf('> one'),
              end: text.indexOf('\nafter'),
            ),
            columnLeft: 0,
            columnRight: 300,
          ),
          Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[2].bottom),
        );
      },
    );

    test('quoteBandRect of an empty range is null', () {
      expect(
        quoteBandRect(
          _Wi165FakeBoxes('intro\n> one'),
          const TextRange.collapsed(6),
          columnLeft: 0,
          columnRight: 300,
        ),
        isNull,
      );
    });
  });

  group('code pill geometry (AC3, AC6)', () {
    test(
      'codePillRects widens a mid line code span by 3 px on each side with height 17 at line top plus 2',
      () {
        const text = 'say `code` now';
        final b = _Wi165FakeBoxes(text);
        final pills = codePillRects(
          b,
          const TextRange(start: 5, end: 9),
          columnLeft: 0,
        );
        expect(pills, hasLength(1));
        // 4 chars x 8.1 + 6 (design: chars x 8.1 + 6).
        _wi165ExpectRect(
          pills.single,
          Rect.fromLTRB(5 * 8.1 - 3, 2, 9 * 8.1 + 3, 19),
        );
      },
    );

    test('codePillRects gives a line start code span no left widening', () {
      // Backticks hidden: the content starts exactly at the text column.
      for (final (text, line) in [
        ('`openmemex.dev` is up', 0),
        ('intro\n`openmemex.dev` is up', 1),
      ]) {
        final b = _Wi165FakeBoxes(text, hidden: _wi165Ticks(text));
        final start = text.indexOf('openmemex');
        final pills = codePillRects(
          b,
          TextRange(start: start, end: start + 13),
          columnLeft: 0,
        );
        final top = b.lines[line].top + 2;
        expect(pills, hasLength(1), reason: text);
        // 13 chars x 8.1 + 3 = 108.3, starting exactly at the column.
        _wi165ExpectRect(
          pills.single,
          Rect.fromLTRB(0, top, 13 * 8.1 + 3, top + 17),
          reason: text,
        );
      }
    });

    test(
      'codePillRects of a code span wrapped over two lines pads only its outer ends',
      () {
        final text = 'ab `${'c' * 30}` z';
        final b = _Wi165FakeBoxes(text, wrap: 20);
        expect(b.lines, hasLength(2));
        final pills = codePillRects(
          b,
          const TextRange(start: 4, end: 34),
          columnLeft: 0,
        );
        expect(pills, hasLength(2));
        // First part: left padded, runs to its visual line end unpadded.
        _wi165ExpectRect(pills[0], Rect.fromLTRB(4 * 8.1 - 3, 2, 20 * 8.1, 19));
        // Second part: starts at the line start unpadded, right padded.
        final top = b.lines[1].top + 2;
        _wi165ExpectRect(
          pills[1],
          Rect.fromLTRB(0, top, 14 * 8.1 + 3, top + 17),
        );
      },
    );

    test('codePillRects of an empty range is empty', () {
      expect(
        codePillRects(
          _Wi165FakeBoxes('say `code` now'),
          const TextRange.collapsed(5),
          columnLeft: 0,
        ),
        isEmpty,
      );
    });

    test('codePillRects never starts a pill left of the text column', () {
      // The field starts 1 px right of the column: 3 px padding would cross it.
      const text = '`ab` z';
      final b = _Wi165FakeBoxes(text, left: 1, hidden: _wi165Ticks(text));
      final pill = codePillRects(
        b,
        const TextRange(start: 1, end: 3),
        columnLeft: 0,
      ).single;
      expect(pill.left, greaterThanOrEqualTo(0));
      expect(pill.left, lessThanOrEqualTo(1));
      expect(pill.right, moreOrLessEquals(1 + 2 * 8.1 + 3, epsilon: 1e-6));
    });
  });

  group('rule geometry (AC4, AC6)', () {
    test(
      'ruleRect is a 1 px line across the text column 11 px below the rule line top',
      () {
        const text = 'above\n---\nbelow';
        final b = _Wi165FakeBoxes(text);
        final top = b.lines[1].top;
        _wi165ExpectRect(
          ruleRect(
            b,
            const TextRange(start: 6, end: 9),
            columnLeft: 0,
            columnRight: 300,
          ),
          Rect.fromLTRB(0, top + 11, 300, top + 12),
        );
      },
    );

    test('ruleRect of an empty range is null', () {
      expect(
        ruleRect(
          _Wi165FakeBoxes('above\n---'),
          const TextRange.collapsed(6),
          columnLeft: 0,
          columnRight: 300,
        ),
        isNull,
      );
    });
  });

  group('layoutDecorations (AC1 to AC5)', () {
    List<PaintedDecoration> layout(
      String text, {
      _Wi165FakeBoxes? boxes,
      bool atSegmentStart = true,
      bool quote = false,
      TextSelection? reveal,
      Color? quoteBandColor,
    }) {
      final b = boxes ?? _Wi165FakeBoxes(text);
      return quoteBandColor == null
          ? layoutDecorations(
              text: text,
              boxes: b,
              columnLeft: 0,
              columnRight: 300,
              atSegmentStart: atSegmentStart,
              quote: quote,
              reveal: reveal,
            )
          : layoutDecorations(
              text: text,
              boxes: b,
              columnLeft: 0,
              columnRight: 300,
              atSegmentStart: atSegmentStart,
              quote: quote,
              reveal: reveal,
              quoteBandColor: quoteBandColor,
            );
    }

    test(
      'a fenced block lays out one surface1 code box with a line1 border and radius 4',
      () {
        const text = 'intro\n```\nlet a = 1;\n```\nafter';
        final b = _Wi165FakeBoxes(text, heights: const {1: 8, 3: 8});
        final all = layout(text, boxes: b);
        expect(all, hasLength(1), reason: '$all');
        final box = all.single;
        expect(box.kind, DecorationKind.codeBox);
        expect(box.fill, OmColors.surface1);
        expect(box.border, OmColors.line1);
        expect(box.radius, 4);
        _wi165ExpectRect(
          box.rect,
          Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[3].bottom),
        );
      },
    );

    test(
      'a fenced block reveals its 8 px outset only while the selection touches it',
      () {
        const text = 'intro\n```\nlet a = 1;\n```\nafter';
        final b = _Wi165FakeBoxes(text);
        final hidden = Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[3].bottom);
        final revealed = Rect.fromLTRB(
          0,
          b.lines[1].top - 8,
          300,
          b.lines[3].bottom + 8,
        );
        final cases = <(String, TextSelection?, Rect)>[
          ('segment unfocused', null, hidden),
          (
            'caret on the code line',
            TextSelection.collapsed(offset: text.indexOf('a =')),
            revealed,
          ),
          (
            'caret at the opening fence start',
            TextSelection.collapsed(offset: text.indexOf('```')),
            revealed,
          ),
          (
            'selection from the prose line into the block',
            TextSelection(baseOffset: 2, extentOffset: text.indexOf('a =')),
            revealed,
          ),
          (
            'caret on the prose line after the block',
            TextSelection.collapsed(offset: text.indexOf('after')),
            hidden,
          ),
          (
            'caret at the end of the prose line before the block',
            const TextSelection.collapsed(offset: 5),
            hidden,
          ),
        ];
        for (final (name, reveal, rect) in cases) {
          final boxes = _wi165Of(
            layout(text, boxes: b, reveal: reveal),
            DecorationKind.codeBox,
          );
          expect(boxes, hasLength(1), reason: name);
          _wi165ExpectRect(boxes.single.rect, rect, reason: name);
        }
      },
    );

    test('an unclosed fence runs its code box to the last line', () {
      const text = 'intro\n```\nlet a = 1;';
      final b = _Wi165FakeBoxes(text);
      final boxes = _wi165Of(layout(text, boxes: b), DecorationKind.codeBox);
      expect(boxes, hasLength(1));
      _wi165ExpectRect(
        boxes.single.rect,
        Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[2].bottom),
      );
    });

    test(
      'two consecutive quote lines lay out one surface3 band and the prose line after has none',
      () {
        const text = 'intro\n> one\n> two\nafter';
        final b = _Wi165FakeBoxes(text);
        final all = layout(text, boxes: b);
        expect(all, hasLength(1), reason: '$all');
        final band = all.single;
        expect(band.kind, DecorationKind.quoteBand);
        expect(band.fill, OmColors.surface3);
        expect(band.radius, 0, reason: 'the band has no radius');
        expect(band.border, isNull, reason: 'the band has no border');
        _wi165ExpectRect(
          band.rect,
          Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[2].bottom),
        );
      },
    );

    test('quote lines separated by a blank line lay out two bands', () {
      const text = 'intro\n> one\n\n> two';
      final b = _Wi165FakeBoxes(text);
      final bands = _wi165Of(layout(text, boxes: b), DecorationKind.quoteBand);
      expect(bands, hasLength(2));
      _wi165ExpectRect(
        bands[0].rect,
        Rect.fromLTRB(0, b.lines[1].top, 300, b.lines[1].bottom),
      );
      _wi165ExpectRect(
        bands[1].rect,
        Rect.fromLTRB(0, b.lines[3].top, 300, b.lines[3].bottom),
      );
    });

    test('the quote band colour parameter lays out a surface4 band', () {
      final bands = _wi165Of(
        layout('> in a card', quoteBandColor: OmColors.surface4),
        DecorationKind.quoteBand,
      );
      expect(bands.single.fill, OmColors.surface4);
    });

    test('a quote row field lays out one band over all its lines', () {
      // A quote row holds only the quote text (its marker is in the column).
      const text = 'a quote row that wraps';
      final b = _Wi165FakeBoxes(text, wrap: 10);
      expect(b.lines, hasLength(3));
      final bands = _wi165Of(
        layout(text, boxes: b, quote: true),
        DecorationKind.quoteBand,
      );
      expect(bands, hasLength(1));
      _wi165ExpectRect(
        bands.single.rect,
        Rect.fromLTRB(0, b.lines.first.top, 300, b.lines.last.bottom),
      );
      final empty = _Wi165FakeBoxes('');
      final emptyBands = _wi165Of(
        layout('', boxes: empty, quote: true),
        DecorationKind.quoteBand,
      );
      expect(emptyBands, hasLength(1), reason: 'an empty quote row has a band');
      _wi165ExpectRect(
        emptyBands.single.rect,
        Rect.fromLTRB(
          0,
          empty.lines.single.top,
          300,
          empty.lines.single.bottom,
        ),
      );
    });

    test(
      'a code span lays out a surface4 pill with radius 3 around its content not its backticks',
      () {
        const text = 'say `code` now';
        final b = _Wi165FakeBoxes(text);
        final all = layout(text, boxes: b);
        expect(all, hasLength(1), reason: '$all');
        final pill = all.single;
        expect(pill.kind, DecorationKind.codePill);
        expect(pill.fill, OmColors.surface4);
        expect(pill.radius, 3);
        expect(pill.border, isNull);
        _wi165ExpectRect(
          pill.rect,
          Rect.fromLTRB(5 * 8.1 - 3, 2, 9 * 8.1 + 3, 19),
        );
      },
    );

    test('a rule line lays out one line2 rule across the text column', () {
      const text = 'above\n---\nbelow';
      final b = _Wi165FakeBoxes(text);
      final all = layout(text, boxes: b);
      expect(all, hasLength(1), reason: '$all');
      final rule = all.single;
      expect(rule.kind, DecorationKind.rule);
      expect(rule.fill, OmColors.line2);
      final top = b.lines[1].top;
      _wi165ExpectRect(rule.rect, Rect.fromLTRB(0, top + 11, 300, top + 12));
    });

    test(
      'leading frontmatter delimiters are not rules but the same lines off the segment start are',
      () {
        const text = '---\ntitle: x\n---\nbody';
        final b = _Wi165FakeBoxes(text);
        expect(
          _wi165Of(layout(text, boxes: b), DecorationKind.rule),
          isEmpty,
          reason: 'frontmatter at the segment start',
        );
        final rules = _wi165Of(
          layout(text, boxes: b, atSegmentStart: false),
          DecorationKind.rule,
        );
        expect(rules, hasLength(2));
        _wi165ExpectRect(
          rules[0].rect,
          Rect.fromLTRB(0, b.lines[0].top + 11, 300, b.lines[0].top + 12),
        );
        _wi165ExpectRect(
          rules[1].rect,
          Rect.fromLTRB(0, b.lines[2].top + 11, 300, b.lines[2].top + 12),
        );
      },
    );

    test(
      'code spans quote markers and rule lines inside a fence lay out only the box',
      () {
        const text = '```\n`code` here\n> not a quote\n---\n```';
        final all = layout(text);
        expect(all, hasLength(1), reason: '$all');
        expect(all.single.kind, DecorationKind.codeBox);
      },
    );

    test('a quote line with a code span lays out the band before the pill', () {
      const text = '> say `code` now';
      final all = layout(text);
      expect(
        [for (final d in all) d.kind],
        [DecorationKind.quoteBand, DecorationKind.codePill],
      );
    });

    test('every laid out rect starts at or right of the text column', () {
      const text =
          '`lead` code at the line start\n'
          '> quote with `q` inside\n'
          '---\n'
          'intro\n'
          '```\n'
          'code\n'
          '```\n'
          'after with `tail`';
      final b = _Wi165FakeBoxes(text, hidden: _wi165Ticks(text));
      final all = layout(text, boxes: b);
      expect(
        {for (final d in all) d.kind},
        DecorationKind.values.toSet(),
        reason: 'every kind is laid out: $all',
      );
      for (final d in all) {
        expect(d.rect.left, greaterThanOrEqualTo(0), reason: '$d');
        expect(d.rect.right, lessThanOrEqualTo(300), reason: '$d');
      }
      final lead = _wi165Of(all, DecorationKind.codePill).first;
      expect(
        lead.rect.left,
        0,
        reason: 'the line start pill sits at the column',
      );
    });

    test('text without decorations lays out nothing', () {
      expect(layout('just prose\nmore *prose* [[Link]]'), isEmpty);
      expect(layout(''), isEmpty);
    });
  });

  group('LivePreviewDecorations painting (AC1 to AC5)', () {
    testWidgets(
      'the decorations paint a fenced block box with a line1 border from the text column left of the inset code text',
      (tester) async {
        final f = await _wi165Pump(
          tester,
          text: 'intro\n\n```\nlet a = 1;\n```\n\nafter',
          fieldLeft: 14 + 16.2,
        );
        final open = f.line(2);
        final code = f.line(3);
        final close = f.line(4);
        final px = await _wi165Capture(tester);
        const x = 20.0;
        expect(
          px.at(Offset(x, code.center.dy)),
          const _Wi165Near(OmColors.surface1),
        );
        // 1 px line1 border inside the rect, at the text column (x 14).
        expect(
          px.at(Offset(14.5, code.center.dy)),
          _Wi165Near(_wi165BorderOverFill, tolerance: 2),
        );
        expect(
          px.at(Offset(15.5, code.center.dy)),
          const _Wi165Near(OmColors.surface1),
        );
        expect(
          px.at(Offset(13.5, code.center.dy)),
          const _Wi165Near(OmColors.surface2),
        );
        // Right edge: the text column right (this widget right).
        expect(
          px.at(Offset(_wi165Width - 0.5, code.center.dy)),
          _Wi165Near(_wi165BorderOverFill, tolerance: 2),
        );
        expect(
          px.at(Offset(_wi165Width - 2.5, code.center.dy)),
          const _Wi165Near(OmColors.surface1),
        );
        // Top and bottom: the first and last fence line boxes.
        expect(
          px.at(Offset(x, open.top + 2.5)),
          const _Wi165Near(OmColors.surface1),
        );
        expect(
          px.at(Offset(x, open.top - 1.5)),
          const _Wi165Near(OmColors.surface2),
        );
        expect(
          px.at(Offset(x, close.bottom - 2.5)),
          const _Wi165Near(OmColors.surface1),
        );
        expect(
          px.at(Offset(x, close.bottom + 1.5)),
          const _Wi165Near(OmColors.surface2),
        );
      },
    );

    testWidgets(
      'the decorations paint the revealed box 8 px outset and repaint when the reveal gate or caret moves',
      (tester) async {
        const text = 'intro\n\n```\nlet a = 1;\n```\n\nafter';
        final gate = ValueNotifier(true);
        addTearDown(gate.dispose);
        final controller = LivePreviewController(text: text)
          ..revealGate = gate
          ..selection = TextSelection.collapsed(offset: text.indexOf('a ='));
        final f = await _wi165Pump(
          tester,
          controller: controller,
          fieldLeft: 14 + 16.2,
        );
        final open = f.line(2);
        final close = f.line(4);
        const x = 20.0;

        Future<void> expectOutset(bool outset, String reason) async {
          final px = await _wi165Capture(tester);
          final top = outset ? open.top - 8 : open.top;
          final bottom = outset ? close.bottom + 8 : close.bottom;
          expect(
            px.at(Offset(x, top + 2.5)),
            const _Wi165Near(OmColors.surface1),
            reason: '$reason: inside the top',
          );
          expect(
            px.at(Offset(x, top - 1.5)),
            const _Wi165Near(OmColors.surface2),
            reason: '$reason: above the top',
          );
          expect(
            px.at(Offset(x, bottom - 2.5)),
            const _Wi165Near(OmColors.surface1),
            reason: '$reason: inside the bottom',
          );
          expect(
            px.at(Offset(x, bottom + 1.5)),
            const _Wi165Near(OmColors.surface2),
            reason: '$reason: below the bottom',
          );
        }

        await expectOutset(true, 'caret inside while focused');

        gate.value = false;
        await tester.pump();
        await expectOutset(false, 'segment unfocused');

        gate.value = true;
        controller.selection = TextSelection.collapsed(
          offset: text.indexOf('after'),
        );
        await tester.pump();
        await expectOutset(false, 'caret on the prose line after');

        controller.selection = TextSelection.collapsed(
          offset: text.indexOf('let'),
        );
        await tester.pump();
        await expectOutset(true, 'caret back inside');
      },
    );

    testWidgets(
      'the decorations paint consecutive quote bands in surface3 with no gap and no band on the prose line after',
      (tester) async {
        final f = await _wi165Pump(
          tester,
          text: 'intro\n> first quote\n> second quote\nafter',
        );
        final first = f.line(1);
        final second = f.line(2);
        final px = await _wi165Capture(tester);
        const x = _wi165Width - 3;
        expect(
          px.at(Offset(x, first.center.dy)),
          const _Wi165Near(OmColors.surface3),
        );
        expect(
          px.at(Offset(x, second.center.dy)),
          const _Wi165Near(OmColors.surface3),
        );
        // No gap where the two quote lines meet.
        for (final dy in [-1.5, -0.5, 0.5, 1.5]) {
          expect(
            px.at(Offset(x, first.bottom + dy)),
            const _Wi165Near(OmColors.surface3),
            reason: 'seam ${first.bottom} + $dy',
          );
        }
        expect(
          px.at(Offset(x, first.top + 1.5)),
          const _Wi165Near(OmColors.surface3),
        );
        expect(
          px.at(Offset(x, first.top - 1.5)),
          const _Wi165Near(OmColors.surface2),
        );
        expect(
          px.at(Offset(x, second.bottom - 1.5)),
          const _Wi165Near(OmColors.surface3),
        );
        expect(
          px.at(Offset(x, second.bottom + 1.5)),
          const _Wi165Near(OmColors.surface2),
        );
        expect(
          px.at(Offset(x, f.line(3).center.dy)),
          const _Wi165Near(OmColors.surface2),
        );
        expect(
          px.at(Offset(x, f.line(0).center.dy)),
          const _Wi165Near(OmColors.surface2),
        );
        // The band starts at the text column.
        expect(
          px.at(Offset(14.5, first.center.dy)),
          const _Wi165Near(OmColors.surface3),
        );
        expect(
          px.at(Offset(13.5, first.center.dy)),
          const _Wi165Near(OmColors.surface2),
        );
      },
    );

    testWidgets(
      'the decorations paint the band in the quote band colour given',
      (tester) async {
        final f = await _wi165Pump(
          tester,
          text: '> in an excerpt card\nafter',
          quoteBandColor: OmColors.surface4,
        );
        final px = await _wi165Capture(tester);
        expect(
          px.at(Offset(_wi165Width - 3, f.line(0).center.dy)),
          const _Wi165Near(OmColors.surface4),
        );
      },
    );

    testWidgets(
      'the decorations paint a surface4 code pill widened 3 px on each side 17 px tall from line top plus 2',
      (tester) async {
        final f = await _wi165Pump(tester, text: 'say `code` now');
        final content = f.range(const TextRange(start: 5, end: 9));
        final line = f.line(0);
        final left = content.left - 3;
        final right = content.right + 3;
        final top = line.top + 2;
        final bottom = top + 17;
        final y = top + 8.5;
        final px = await _wi165Capture(tester);
        expect(
          px.at(Offset(left + 1.5, y)),
          const _Wi165Near(OmColors.surface4),
        );
        expect(
          px.at(Offset(left - 1.5, y)),
          const _Wi165Near(OmColors.surface2),
        );
        expect(
          px.at(Offset(right - 1.5, y)),
          const _Wi165Near(OmColors.surface4),
        );
        expect(
          px.at(Offset(right + 1.5, y)),
          const _Wi165Near(OmColors.surface2),
        );
        // The top and bottom edges are probed in the 3 px widened margins:
        // B1 paints the code glyphs fg1 over the pill's centre column.
        for (final x in [left + 1.5, right - 1.5]) {
          expect(
            px.at(Offset(x, top + 1.5)),
            const _Wi165Near(OmColors.surface4),
          );
          expect(
            px.at(Offset(x, top - 1.5)),
            const _Wi165Near(OmColors.surface2),
          );
          expect(
            px.at(Offset(x, bottom - 1.5)),
            const _Wi165Near(OmColors.surface4),
          );
          expect(
            px.at(Offset(x, bottom + 1.5)),
            const _Wi165Near(OmColors.surface2),
          );
        }
      },
    );

    testWidgets('the decorations paint the band and pill under the text', (
      tester,
    ) async {
      final f = await _wi165Pump(
        tester,
        text: '> `XXXX` quoted',
        textColor: OmColors.fg1,
      );
      final content = f.range(const TextRange(start: 3, end: 7));
      final y = f.line(0).center.dy;
      final px = await _wi165Capture(tester);
      // Background showing: the pill above the glyphs (the pill starts at
      // line top + 2, the 13.5 px glyphs 4.7 px below the line top), the
      // band at the column right.
      expect(
        px.at(Offset(content.center.dx, f.line(0).top + 3)),
        const _Wi165Near(OmColors.surface4),
      );
      expect(
        px.at(Offset(_wi165Width - 3, y)),
        const _Wi165Near(OmColors.surface3),
      );
      // Glyphs on top: the middle of the second X is text colour.
      expect(
        px.at(Offset(content.left + 13.5 * 1.5, y)),
        const _Wi165Near(OmColors.fg1, tolerance: 2),
      );
    });

    testWidgets('the decorations paint a rule line inside the text column', (
      tester,
    ) async {
      final f = await _wi165Pump(tester, text: 'above\n---\nbelow');
      final rule = f.line(1).top + 11;
      final px = await _wi165Capture(tester);
      for (final x in [14.5, 200.0, _wi165Width - 0.5]) {
        expect(
          px.at(Offset(x, rule + 0.5)),
          isNot(const _Wi165Near(OmColors.surface2, tolerance: 4)),
          reason: 'rule at x $x',
        );
        expect(
          px.at(Offset(x, rule - 1.5)),
          const _Wi165Near(OmColors.surface2),
          reason: 'above the rule at x $x',
        );
        expect(
          px.at(Offset(x, rule + 2.5)),
          const _Wi165Near(OmColors.surface2),
          reason: 'below the rule at x $x',
        );
      }
      expect(
        px.at(Offset(13.5, rule + 0.5)),
        const _Wi165Near(OmColors.surface2),
      );
      for (final i in [0, 2]) {
        expect(
          px.at(Offset(200, f.line(i).top + 11.5)),
          const _Wi165Near(OmColors.surface2),
          reason: 'no rule on line $i',
        );
      }
    });

    testWidgets(
      'nothing paints left of textLeft in the capture gutter column',
      (tester) async {
        const text =
            '`lead` code at the line start\n'
            '> quote with `q` inside\n'
            '---\n'
            'intro\n'
            '```\n'
            'code\n'
            '```\n'
            'after';
        final f = await _wi165Pump(
          tester,
          controller: _Wi165HiddenTicksController(text: text),
        );
        final px = await _wi165Capture(tester);
        // The decorations reach the column: line-start pill and quote band.
        expect(
          px.at(Offset(14.5, f.line(0).center.dy)),
          const _Wi165Near(OmColors.surface4),
          reason: 'the line start pill starts at textLeft',
        );
        expect(
          px.at(Offset(14.5, f.line(1).center.dy)),
          const _Wi165Near(OmColors.surface3),
        );
        // Every pixel of the 14 px gutter column is background.
        for (var y = 0; y < px.height; y++) {
          for (var x = 0; x < 14; x++) {
            final c = px.atPixel(x, y);
            if (!const _Wi165Near(OmColors.surface2).matches(c, {})) {
              fail('gutter pixel ($x, $y) is painted: $c');
            }
          }
        }
      },
    );

    testWidgets(
      'the decorations read the controller quote and atSegmentStart props',
      (tester) async {
        final row = LivePreviewController(text: 'a quote row')..quote = true;
        var f = await _wi165Pump(tester, controller: row);
        var px = await _wi165Capture(tester);
        expect(
          px.at(Offset(_wi165Width - 3, f.line(0).center.dy)),
          const _Wi165Near(OmColors.surface3),
          reason: 'a quote row is banded',
        );

        const text = '---\nx\n---';
        for (final atStart in [true, false]) {
          final c = LivePreviewController(text: text)..atSegmentStart = atStart;
          f = await _wi165Pump(tester, controller: c);
          px = await _wi165Capture(tester);
          final y = f.line(0).top + 11.5;
          expect(
            px.at(Offset(200, y)),
            atStart
                ? const _Wi165Near(OmColors.surface2)
                : isNot(const _Wi165Near(OmColors.surface2, tolerance: 4)),
            reason: atStart ? 'frontmatter, no rule' : 'a rule off the start',
          );
        }
      },
    );

    testWidgets('the decorations repaint when the text changes', (
      tester,
    ) async {
      final f = await _wi165Pump(tester, text: 'plain words');
      final y = f.line(0).center.dy;
      var px = await _wi165Capture(tester);
      expect(
        px.at(Offset(_wi165Width - 3, y)),
        const _Wi165Near(OmColors.surface2),
      );

      f.controller.text = '> quote word';
      await tester.pump();
      px = await _wi165Capture(tester);
      expect(
        px.at(Offset(_wi165Width - 3, y)),
        const _Wi165Near(OmColors.surface3),
      );
    });

    testWidgets(
      'with no line boxes yet the decorations paint nothing and render the child',
      (tester) async {
        for (final (measured, measuresNull) in [(false, false), (true, true)]) {
          final f = await _wi165Pump(
            tester,
            text: '> quote',
            measured: measured,
            measuresNull: measuresNull,
          );
          expect(find.byType(EditableText), findsOneWidget);
          expect(f.controller.text, '> quote');
          final px = await _wi165Capture(tester);
          expect(
            px.at(Offset(_wi165Width - 3, f.line(0).center.dy)),
            const _Wi165Near(OmColors.surface2),
            reason: 'measured $measured, null $measuresNull',
          );
        }
      },
    );

    testWidgets(
      'a daily note person segment paints its quote band right of the capture gutter',
      (tester) async {
        // Both lines start with the same glyph, so their gutter pixels match
        // unless something paints there; `>plain` (no space) is prose (A1).
        const content = '> quoted person line\n>plain person line\n';
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: RepaintBoundary(
                  key: _wi165EditorKey,
                  child: SegmentedBody(
                    note: _wi165Note(content, daily: true),
                    content: content,
                    savedVersion: 3,
                    onContentChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        // TEST-CHANGE (#167): the segment renders as editor rows, the quote
        // line and the prose line each in its own row's LivePreviewFrame.
        final frameFinder = find.descendant(
          of: find.byKey(textSegmentKey(0)),
          matching: find.byType(LivePreviewFrame),
        );
        expect(frameFinder, findsNWidgets(2));
        double lineMid(int row) {
          final boxes = tester
              .widget<LivePreviewFrame>(frameFinder.at(row))
              .boxes!
              .call()!;
          final l = boxes.lines.first;
          return boxes.box.localToGlobal(Offset(0, (l.top + l.bottom) / 2)).dy;
        }

        final gutter = tester.getRect(find.byKey(const Key('capture-gutter')));
        final frameRect = tester.getRect(frameFinder.first);
        final quoteY = lineMid(0);
        final plainY = lineMid(1);
        final px = await _wi165Capture(
          tester,
          boundary: find.byKey(_wi165EditorKey),
        );
        expect(
          px.at(Offset(frameRect.right - 3, quoteY)),
          const _Wi165Near(OmColors.surface3),
          reason: 'the quote line is banded',
        );
        expect(
          px.at(Offset(frameRect.right - 3, plainY)),
          isNot(const _Wi165Near(OmColors.surface3)),
          reason: 'the prose line after has no band',
        );
        // TEST-CHANGE (#167): the prose row's first glyph now starts at the
        // text column edge while the quote row shows its marker column, so
        // the last gutter pixel column carries that glyph's anti-aliasing
        // beside the prose line only. Compare every column but that one, and
        // check no gutter column beside the quote line is banded.
        for (var x = gutter.left.ceil(); x < gutter.right.floor(); x++) {
          final at = x + 0.5;
          expect(
            px.at(Offset(at, quoteY)),
            isNot(const _Wi165Near(OmColors.surface3)),
            reason: 'gutter column x $at beside the quote line is not banded',
          );
          if (x == gutter.right.floor() - 1) continue;
          expect(
            px.at(Offset(at, quoteY)),
            px.at(Offset(at, plainY)),
            reason: 'gutter column x $at is the same beside the quote line',
          );
        }
      },
    );
  });

  group('repaint and listener contracts (verify)', () {
    testWidgets(
      'the decorations follow a swapped reveal gate and let go of the old one',
      (tester) async {
        final first = _Wi165CountingGate(true);
        addTearDown(first.dispose);
        final second = _Wi165CountingGate(false);
        addTearDown(second.dispose);
        final controller = LivePreviewController(text: _wi165RevealText)
          ..revealGate = first
          ..selection = TextSelection.collapsed(
            offset: _wi165RevealText.indexOf('a ='),
          );
        final f = await _wi165Pump(
          tester,
          controller: controller,
          fieldLeft: 14 + 16.2,
        );
        expect(first.listeners, 1, reason: 'the first gate is listened to');
        await _wi165ExpectOutset(
          tester,
          f,
          outset: true,
          reason: 'first gate open',
        );

        // The host swaps the gate; the caret moves inside the block.
        controller
          ..revealGate = second
          ..selection = TextSelection.collapsed(
            offset: _wi165RevealText.indexOf('let'),
          );
        await tester.pump();
        expect(first.listeners, 0, reason: 'the old gate is let go');
        expect(second.listeners, 1, reason: 'the new gate is listened to');
        await _wi165ExpectOutset(
          tester,
          f,
          outset: false,
          reason: 'the new gate is closed',
        );

        // Only the new gate opens: no controller change at all.
        second.value = true;
        await tester.pump();
        await _wi165ExpectOutset(
          tester,
          f,
          outset: true,
          reason: 'the new gate opened',
        );

        second.value = false;
        await tester.pump();
        await _wi165ExpectOutset(
          tester,
          f,
          outset: false,
          reason: 'the new gate closed again',
        );

        await tester.pumpWidget(const SizedBox());
        expect(second.listeners, 0, reason: 'detached: no gate listener');
        expect(first.listeners, 0);
      },
    );

    testWidgets(
      'a reveal gate swapped without a controller change is followed from the next paint',
      (tester) async {
        final first = _Wi165CountingGate(false);
        addTearDown(first.dispose);
        final second = _Wi165CountingGate(true);
        addTearDown(second.dispose);
        final controller = LivePreviewController(text: _wi165RevealText)
          ..revealGate = first
          ..selection = TextSelection.collapsed(
            offset: _wi165RevealText.indexOf('a ='),
          );
        final f = await _wi165Pump(
          tester,
          controller: controller,
          fieldLeft: 14 + 16.2,
        );
        await _wi165ExpectOutset(tester, f, outset: false, reason: 'closed');

        // A silent swap (the gate field notifies nobody), then an
        // unrelated repaint.
        controller.revealGate = second;
        tester
            .renderObject(find.byType(LivePreviewDecorations))
            .markNeedsPaint();
        await tester.pump();
        expect(first.listeners, 0, reason: 'the old gate is let go');
        expect(second.listeners, 1, reason: 'the new gate is listened to');
        await _wi165ExpectOutset(
          tester,
          f,
          outset: true,
          reason: 'painted with the new open gate',
        );

        // From then on the new gate alone drives repaints.
        second.value = false;
        await tester.pump();
        await _wi165ExpectOutset(
          tester,
          f,
          outset: false,
          reason: 'the new gate closed',
        );
      },
    );

    testWidgets(
      'rebuilding the decorations with new line boxes text column or band colour repaints them',
      (tester) async {
        final controller = LivePreviewController(text: '> quote line\nafter');
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final editable = GlobalKey(debugLabel: 'wi165-rebuild-editable');
        LineBoxSource? measure() {
          final e = findRenderEditable(
            editable.currentContext?.findRenderObject(),
          );
          return e == null ? null : RenderEditableLineBoxes(e);
        }

        // One child instance for every pump, so only the decorations'
        // own properties change.
        final field = Padding(
          padding: const EdgeInsets.only(left: 40),
          child: EditableText(
            key: editable,
            controller: controller,
            focusNode: focus,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.7,
              color: _wi165Clear,
            ),
            cursorColor: OmColors.accent,
            backgroundCursorColor: OmColors.surface2,
            maxLines: null,
          ),
        );
        Future<void> pumpWith({
          LineBoxSource? Function()? boxes,
          double textLeft = 14,
          Color quoteBandColor = OmColors.surface3,
        }) async {
          await tester.pumpWidget(
            _wi165Tree(
              LivePreviewDecorations(
                controller: controller,
                boxes: boxes,
                textLeft: textLeft,
                quoteBandColor: quoteBandColor,
                child: field,
              ),
            ),
          );
          await tester.pump();
        }

        Future<Color> pixel(double x) async {
          final source = measure()!;
          final l = source.lines[0];
          final y = source.box
              .localToGlobal(Offset(0, (l.top + l.bottom) / 2))
              .dy;
          return (await _wi165Capture(tester)).at(Offset(x, y));
        }

        await pumpWith();
        expect(
          await pixel(200),
          const _Wi165Near(OmColors.surface2),
          reason: 'no line boxes: nothing painted',
        );

        await pumpWith(boxes: measure);
        expect(
          await pixel(200),
          const _Wi165Near(OmColors.surface3),
          reason: 'line boxes given: the band paints',
        );
        expect(await pixel(20), const _Wi165Near(OmColors.surface3));

        await pumpWith(boxes: measure, textLeft: 30);
        expect(
          await pixel(20),
          const _Wi165Near(OmColors.surface2),
          reason: 'the text column moved right of x 20',
        );
        expect(await pixel(30.5), const _Wi165Near(OmColors.surface3));

        await pumpWith(
          boxes: measure,
          textLeft: 30,
          quoteBandColor: OmColors.surface4,
        );
        expect(
          await pixel(200),
          const _Wi165Near(OmColors.surface4),
          reason: 'the band colour changed',
        );
      },
    );

    testWidgets(
      'rebuilding the decorations with a new controller paints and follows the new one',
      (tester) async {
        // Both texts have lines of the same lengths, so the child line
        // boxes measure either.
        final shown = _Wi165CountingController(text: '> quote line\nafter');
        final next = _Wi165CountingController(text: 'plain words.\nafter');
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final editable = GlobalKey(debugLabel: 'wi165-swap-editable');
        LineBoxSource? measure() {
          final e = findRenderEditable(
            editable.currentContext?.findRenderObject(),
          );
          return e == null ? null : RenderEditableLineBoxes(e);
        }

        final field = Padding(
          padding: const EdgeInsets.only(left: 14),
          child: EditableText(
            key: editable,
            controller: shown,
            focusNode: focus,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.7,
              color: _wi165Clear,
            ),
            cursorColor: OmColors.accent,
            backgroundCursorColor: OmColors.surface2,
            maxLines: null,
          ),
        );
        Future<void> pumpWith(LivePreviewController c) async {
          await tester.pumpWidget(
            _wi165Tree(
              LivePreviewDecorations(
                controller: c,
                boxes: measure,
                textLeft: 14,
                child: field,
              ),
            ),
          );
          await tester.pump();
        }

        Future<Color> pixel() async {
          final source = measure()!;
          final l = source.lines[0];
          final y = source.box
              .localToGlobal(Offset(0, (l.top + l.bottom) / 2))
              .dy;
          return (await _wi165Capture(tester)).at(Offset(200, y));
        }

        await pumpWith(shown);
        final shownBefore = shown.listeners;
        expect(next.listeners, 0);
        expect(await pixel(), const _Wi165Near(OmColors.surface3));

        await pumpWith(next);
        expect(
          await pixel(),
          const _Wi165Near(OmColors.surface2),
          reason: 'the new controller text has no quote',
        );
        expect(next.listeners, 1, reason: 'the new controller is listened to');
        expect(
          shown.listeners,
          shownBefore - 1,
          reason: 'the old controller is let go',
        );

        next.text = '> again here\nafter';
        await tester.pump();
        expect(
          await pixel(),
          const _Wi165Near(OmColors.surface3),
          reason: 'a change on the new controller repaints',
        );

        await tester.pumpWidget(const SizedBox());
        expect(next.listeners, 0, reason: 'detached: no controller listener');
      },
    );
  });

  group('decorations never change text (AC7)', () {
    testWidgets(
      'opening a note with decorations and moving the caret through them saves nothing',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(topicBody: _wi165Decorated),
        );
        await r.open(fixtureTopicId);
        // TEST-CHANGE (#167): one LivePreviewDecorations per editor row.
        expect(
          find.byType(LivePreviewDecorations),
          findsNWidgets(r.segment(0).rowCount),
        );
        for (final at in ['let a', 'quoted', 'code', '---', 'Outro']) {
          await r.focusSegment(0, offset: _wi165Decorated.indexOf(at));
        }
        await r.waitForSave();

        expect(r.updates, isEmpty);
        expect(r.segmentText(0), _wi165Decorated);
      },
    );

    testWidgets('editing a note with decorations saves exactly the typed bytes', (
      tester,
    ) async {
      final r = await launchSegmented(
        tester,
        vault: seedSegmentedVault(topicBody: _wi165Decorated),
      );
      await r.open(fixtureTopicId);
      final at = _wi165Decorated.indexOf('1;');
      await r.focusSegment(0, offset: at);
      final edited =
          '${_wi165Decorated.substring(0, at)}2${_wi165Decorated.substring(at)}';
      // TEST-CHANGE (#167): the focused field is the editor row holding
      // `1;`, so the text input sends that row's text with the typed `2`.
      final row = segmentRowFields(r.textSegment(0))
          .evaluate()
          .map((e) => e.widget as EditableText)
          .singleWhere((w) => w.focusNode.hasFocus);
      final value = row.controller.value;
      final caret = value.selection.baseOffset;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text:
              '${value.text.substring(0, caret)}2${value.text.substring(caret)}',
          selection: TextSelection.collapsed(offset: caret + 1),
        ),
      );
      await tester.pump();
      await r.waitForSave();

      expect(r.updates, hasLength(1));
      expect(r.updates.single.stdinBody, edited);
      expect(r.segmentText(0), edited);
    });
  });

  group('rulings (D3, D6, R6)', () {
    test(
      'decorations measure only through LineBoxSource and take grammar only from A1 and A2',
      () {
        final source =
            File('lib/src/widgets/editor/live_preview_decorations.dart')
                .readAsLinesSync()
                .where((l) => !l.trimLeft().startsWith('//'))
                .join('\n');
        expect(source, contains('markdown_lines.dart'));
        expect(source, contains('markdown_inline.dart'));
        expect(source, contains('classifyLines('));
        expect(source, contains('tokenizeInline('));
        expect(source, isNot(contains('RegExp')), reason: 'no regexes (D3)');
        expect(
          source,
          isNot(contains('TextPainter')),
          reason: 'measure through LineBoxSource only (D6)',
        );
        expect(
          source,
          isNot(contains('Color(0x')),
          reason: 'colours only from OmColors (R6)',
        );
      },
    );
  });
}
