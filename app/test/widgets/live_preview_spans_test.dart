// WI #164 (B1): live preview styled spans with hidden and revealed markers
// (Spec #157 R2-R5, R13, R37, R38; TD4; rulings D2, D3, D7, D17; design pack
// design/156-live-preview/packs/164.md, which wins over WI numbers).
//
// Every test reads the built span the way the engine does: the effective
// style of one code unit is its ancestors' styles merged down the tree, and a
// width is what a TextPainter lays out for a range. Hidden markers must lay
// out zero-width; revealed markers must lay out at the width the same
// characters take in the line's own font size. Colours are OmColors tokens.
//
// The pure builder `buildLivePreviewSpan` is the seam B4's cards call; the
// controller must build exactly what it builds with the controller's own
// props (pinned by a table-driven relay test), so most styling tests call the
// builder directly.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/font_fetch_hold.dart';
import '../support/markdown_fixtures.dart';
import '../support/wi159_line_geometry.dart' show wi159EditableIn;

/// The editor body style every live preview field passes as its base
/// (`_bodyStyle` in text_segment.dart: mono 13.5, fg0, height 1.7).
TextStyle _base() => OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);

/// The design pack body line height (13.5 x 1.7).
const double _bodyLine = 22.95;

/// Builds through the pure builder with the body base style.
TextSpan _build(
  String text, {
  TextSelection? selection,
  bool forceHidden = false,
  bool itemText = false,
  bool taskDone = false,
  bool quote = false,
  bool atSegmentStart = true,
  bool Function(String target)? isResolved,
  TextRange? cmdHover,
}) => buildLivePreviewSpan(
  text,
  style: _base(),
  selection: selection,
  forceHidden: forceHidden,
  itemText: itemText,
  taskDone: taskDone,
  quote: quote,
  atSegmentStart: atSegmentStart,
  isResolved: isResolved,
  cmdHover: cmdHover,
);

TextSelection _caret(int offset) => TextSelection.collapsed(offset: offset);

/// `[start, end)` of the [nth] (0-based) occurrence of [needle] in [text].
(int, int) _range(String text, String needle, {int nth = 0}) {
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
    expect(at, isNonNegative, reason: 'fixture holds "$needle" #$i');
  }
  return (at, at + needle.length);
}

/// The effective style of the code unit at [offset]: every ancestor's style
/// merged down to the leaf holding it, as the engine inherits styles.
TextStyle _styleAt(InlineSpan root, int offset) {
  TextStyle? found;
  var pos = 0;
  bool visit(InlineSpan span, TextStyle? inherited) {
    expect(span, isA<TextSpan>(), reason: 'no WidgetSpan (TD4)');
    final own = span.style;
    final style = inherited == null
        ? own
        : (own == null ? inherited : inherited.merge(own));
    final textSpan = span as TextSpan;
    final t = textSpan.text ?? '';
    if (offset >= pos && offset < pos + t.length) {
      found = style;
      return false;
    }
    pos += t.length;
    for (final child in textSpan.children ?? const <InlineSpan>[]) {
      if (!visit(child, style)) return false;
    }
    return true;
  }

  visit(root, null);
  expect(found, isNotNull, reason: 'a style covers offset $offset');
  return found!;
}

/// Laid-out width of `[start, end)` (a range inside one line).
double _width(InlineSpan span, int start, int end, {StrutStyle? strut}) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: strut,
  )..layout();
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  painter.dispose();
  return boxes.fold(0.0, (sum, b) => sum + (b.right - b.left));
}

/// The width [chars] take as plain mono text at [size].
double _normalWidth(String chars, double size) => _width(
  TextSpan(
    text: chars,
    style: OmType.mono(size: size),
  ),
  0,
  chars.length,
);

bool _has(TextStyle s, TextDecoration d) => s.decoration?.contains(d) ?? false;

bool _decorated(TextStyle s) =>
    s.decoration != null && s.decoration != TextDecoration.none;

FontWeight _weight(TextStyle s) => s.fontWeight ?? FontWeight.w400;

FontStyle _fontStyle(TextStyle s) => s.fontStyle ?? FontStyle.normal;

/// Every code unit of `[start, end)` lays out zero-width.
void _expectHidden(TextSpan span, String text, int start, int end) {
  expect(
    _width(span, start, end),
    lessThan(0.01),
    reason: '"${text.substring(start, end)}" at $start..$end is hidden',
  );
}

void _expectHiddenRange(TextSpan span, String text, (int, int) r) =>
    _expectHidden(span, text, r.$1, r.$2);

/// `[start, end)` is a revealed marker: [color] (fg2 unless selected),
/// w400, upright, undecorated, at the line's [size] and its normal width.
void _expectMarker(
  TextSpan span,
  String text,
  (int, int) r, {
  double size = 13.5,
  Color color = OmColors.fg2,
}) {
  final (start, end) = r;
  final chars = text.substring(start, end);
  for (var i = start; i < end; i++) {
    final s = _styleAt(span, i);
    final why = 'marker "$chars" code unit $i';
    expect(s.color, color, reason: '$why colour');
    expect(s.fontSize, size, reason: '$why size');
    expect(_weight(s), FontWeight.w400, reason: '$why weight');
    expect(_fontStyle(s), FontStyle.normal, reason: '$why upright');
    expect(_decorated(s), isFalse, reason: '$why undecorated');
  }
  expect(
    _width(span, start, end),
    closeTo(_normalWidth(chars, size), 0.01),
    reason: 'marker "$chars" at its normal width',
  );
}

/// `[start, end)` renders as plain body text in [color]: 13.5, w400,
/// upright, undecorated, visible at its normal width.
void _expectPlain(
  TextSpan span,
  String text,
  int start,
  int end, {
  Color color = OmColors.fg0,
}) {
  final chars = text.substring(start, end);
  for (var i = start; i < end; i++) {
    final s = _styleAt(span, i);
    final why = '"$chars" code unit $i';
    expect(s.color, color, reason: '$why colour');
    expect(s.fontSize, 13.5, reason: '$why size');
    expect(_weight(s), FontWeight.w400, reason: '$why weight');
    expect(_fontStyle(s), FontStyle.normal, reason: '$why upright');
    expect(_decorated(s), isFalse, reason: '$why undecorated');
  }
  expect(
    _width(span, start, end),
    closeTo(_normalWidth(chars, 13.5), 0.01),
    reason: '"$chars" visible at its normal width',
  );
}

void _expectPlainRange(
  TextSpan span,
  String text,
  (int, int) r, {
  Color color = OmColors.fg0,
}) => _expectPlain(span, text, r.$1, r.$2, color: color);

/// Applies [check] to the effective style of every code unit of [r].
void _eachStyle(
  TextSpan span,
  String text,
  (int, int) r,
  void Function(TextStyle s, String why) check,
) {
  for (var i = r.$1; i < r.$2; i++) {
    check(_styleAt(span, i), '"${text.substring(r.$1, r.$2)}" code unit $i');
  }
}

/// toPlainText equals [text] exactly and the tree holds only TextSpans.
void _expectExactPlainText(TextSpan span, String text, String why) {
  expect(span.toPlainText(), text, reason: why);
  span.visitChildren((child) {
    expect(child, isA<TextSpan>(), reason: '$why: no WidgetSpan (TD4)');
    return true;
  });
}

/// Every `content_md` string in the api_v1 wire fixtures (read-only).
List<String> _apiV1ContentMd() {
  final found = <String>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final MapEntry(:key, :value) in node.entries) {
        if (key == 'content_md' && value is String) {
          found.add(value);
        } else {
          walk(value);
        }
      }
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  // `flutter test` runs with the package root (`app/`) as cwd.
  final files =
      Directory('test/fixtures/api_v1')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    walk(jsonDecode(f.readAsStringSync()));
  }
  return found;
}

/// A BuildContext for calling `buildTextSpan` directly.
Future<BuildContext> _context(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox(key: Key('wi164-context')));
  return tester.element(find.byKey(const Key('wi164-context')));
}

/// A controller holding [text] with [selection], its reveal gate [focused].
LivePreviewController _controller(
  String text, {
  TextSelection? selection,
  bool focused = true,
}) {
  final gate = ValueNotifier<bool>(focused);
  final c = LivePreviewController.fromValue(
    TextEditingValue(
      text: text,
      selection: selection ?? const TextSelection.collapsed(offset: -1),
    ),
  )..revealGate = gate;
  addTearDown(c.dispose);
  addTearDown(gate.dispose);
  return c;
}

TextSpan _controllerSpan(BuildContext context, LivePreviewController c) =>
    c.buildTextSpan(context: context, style: _base(), withComposing: false);

/// The design pack hidden fence line height (pack #161: 7 px padding plus
/// 1 px border).
const double _hiddenFence = 8;

/// The strut a field editing [c] really lays out with: what `EditableText`
/// derives from the controller's [LivePreviewController.strutStyle] and the
/// body style (a null strut becomes a forced strut from the style).
StrutStyle _effectiveStrut(LivePreviewController c) {
  final strut = c.strutStyle;
  return strut == null
      ? StrutStyle.fromTextStyle(_base(), forceStrutHeight: true)
      : strut.inheritFromTextStyle(_base());
}

/// Pumps [c] in a field laid out as `TextSegmentField` lays a live preview
/// field out (body style, the controller's own strut) and returns the real
/// line geometry of its render object (C0's line-box seam).
Future<LineBoxSource> _pumpCodeRowField(
  WidgetTester tester,
  LivePreviewController c,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: TextField(
            key: const Key('wi164-code-row-field'),
            controller: c,
            maxLines: null,
            style: _base(),
            strutStyle: c.strutStyle,
          ),
        ),
      ),
    ),
  );
  return RenderEditableLineBoxes(
    wi159EditableIn(tester, find.byKey(const Key('wi164-code-row-field'))),
  );
}

/// The laid-out height of every line of [lines].
List<double> _lineHeights(LineBoxSource lines) => [
  for (final line in lines.lines) line.bottom - line.top,
];

/// Every line of [lines] is as tall as [expected] (test-font line metrics
/// round to whole pixels: 0.51 tolerance).
void _expectLineHeights(
  LineBoxSource lines,
  List<double> expected,
  String why,
) {
  final heights = _lineHeights(lines);
  expect(heights, hasLength(expected.length), reason: '$why: line count');
  for (final (i, h) in heights.indexed) {
    expect(h, closeTo(expected[i], 0.51), reason: '$why: line $i of $heights');
  }
}

// ------------------------------------------------------------ WI #223 helpers

/// The new heading font size per level (WI #223, design A + D).
const List<(int, double)> _wi223Sizes = [
  (1, 26),
  (2, 19),
  (3, 15),
  (4, 11),
  (5, 11),
  (6, 11),
];

/// The heading colour per level (WI #223, design A + D).
const List<(int, Color)> _wi223Colours = [
  (1, OmColors.heading1),
  (2, OmColors.fg0),
  (3, OmColors.fg0),
  (4, OmColors.fg2),
  (5, OmColors.fg2),
  (6, OmColors.fg2),
];

/// A laid-out field line's tolerance: the field lays these lines out to
/// within a thousandth of a pixel, and the R5a trap adds about 0.6 px.
const double _wi223Tolerance = 0.05;

/// The two base styles heading text is checked over: the body base (fg0)
/// and the same base in fg1 (the card base, and the body after #224).
List<TextStyle> _wi223Bases() => [
  _base(),
  _base().copyWith(color: OmColors.fg1),
];

/// The name of [base]'s colour in a failure reason.
String _wi223BaseName(TextStyle base) =>
    base.color == OmColors.fg1 ? 'fg1' : 'fg0';

/// Every code unit of [r] is shown heading text: JetBrains Mono at [size]
/// in the [weight] face and [colour], [fontStyle] (upright by default), no
/// letter spacing, undecorated, and the range lays out at its normal width.
void _wi223ExpectHeadingText(
  TextSpan span,
  String text,
  (int, int) r, {
  required double size,
  required FontWeight weight,
  required Color colour,
  required String why,
  FontStyle fontStyle = FontStyle.normal,
}) {
  final face = OmType.mono(weight: weight);
  _eachStyle(span, text, r, (s, unit) {
    final at = '$why: $unit';
    expect(s.fontSize, size, reason: '$at size');
    expect(_weight(s), weight, reason: '$at weight');
    expect(s.fontFamily, startsWith('JetBrainsMono'), reason: '$at mono');
    expect(s.fontFamily, face.fontFamily, reason: '$at the $weight face');
    expect(s.color, colour, reason: '$at colour');
    expect(_fontStyle(s), fontStyle, reason: '$at font style');
    expect(s.letterSpacing ?? 0, 0, reason: '$at letter spacing');
    expect(_decorated(s), isFalse, reason: '$at undecorated');
  });
  final chars = text.substring(r.$1, r.$2);
  expect(
    _width(span, r.$1, r.$2),
    closeTo(_normalWidth(chars, size), 0.01),
    reason: '$why: "$chars" visible at its normal width',
  );
}

/// Pumps [c] in a field configured as `TextSegmentField` configures a live
/// preview field: the app theme (its Material 3 text style gives the field
/// even leading), the editor body style and the controller's own strut.
/// Returns the field's render object.
Future<RenderEditable> _wi223PumpEditorField(
  WidgetTester tester,
  LivePreviewController c,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: TextField(
            key: const Key('wi223-field'),
            controller: c,
            maxLines: null,
            style: editorBodyStyle(),
            strutStyle: c.strutStyle,
          ),
        ),
      ),
    ),
  );
  return wi159EditableIn(tester, find.byKey(const Key('wi223-field')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  holdFontFetches();

  group('plain text and no WidgetSpan (AC1, D17, TD4)', () {
    testWidgets(
      'span plain text equals the controller text for every fixture with the caret on each line and unfocused',
      (tester) async {
        final context = await _context(tester);
        final api = _apiV1ContentMd();
        expect(api.length, greaterThanOrEqualTo(40), reason: 'sweep is real');
        final texts = <String, String>{
          ...markdownFixtures,
          for (final (i, t) in api.indexed) 'content_md $i': t,
        };
        for (final MapEntry(key: name, value: text) in texts.entries) {
          final lines = classifyLines(text, atSegmentStart: true);

          // The controller, as the field renders it.
          final gate = ValueNotifier<bool>(false);
          final c = LivePreviewController(text: text)..revealGate = gate;
          _expectExactPlainText(
            _controllerSpan(context, c),
            text,
            '$name controller unfocused',
          );
          gate.value = true;
          for (final (i, line) in lines.indexed) {
            c.selection = _caret(line.start);
            _expectExactPlainText(
              _controllerSpan(context, c),
              text,
              '$name controller caret on line $i',
            );
          }
          c.dispose();
          gate.dispose();

          // The pure builder, under every prop combination a host sets.
          final variants =
              <
                String,
                TextSpan Function(TextSelection? sel, {bool forceHidden})
              >{
                'prose': (sel, {forceHidden = false}) =>
                    _build(text, selection: sel, forceHidden: forceHidden),
                'not at segment start': (sel, {forceHidden = false}) => _build(
                  text,
                  selection: sel,
                  forceHidden: forceHidden,
                  atSegmentStart: false,
                ),
                'item text': (sel, {forceHidden = false}) => _build(
                  text,
                  selection: sel,
                  forceHidden: forceHidden,
                  itemText: true,
                ),
                'done task': (sel, {forceHidden = false}) => _build(
                  text,
                  selection: sel,
                  forceHidden: forceHidden,
                  itemText: true,
                  taskDone: true,
                ),
                'quote': (sel, {forceHidden = false}) => _build(
                  text,
                  selection: sel,
                  forceHidden: forceHidden,
                  itemText: true,
                  quote: true,
                ),
                'ghosts hovered': (sel, {forceHidden = false}) => _build(
                  text,
                  selection: sel,
                  forceHidden: forceHidden,
                  isResolved: (_) => false,
                  cmdHover: TextRange(start: 0, end: text.length),
                ),
              };
          for (final MapEntry(key: variant, value: build) in variants.entries) {
            _expectExactPlainText(
              build(null),
              text,
              '$name $variant no selection',
            );
            _expectExactPlainText(
              build(_caret(0), forceHidden: true),
              text,
              '$name $variant forced hidden',
            );
            _expectExactPlainText(
              build(TextSelection(baseOffset: 0, extentOffset: text.length)),
              text,
              '$name $variant all selected',
            );
            for (final (i, line) in lines.indexed) {
              _expectExactPlainText(
                build(_caret(line.start)),
                text,
                '$name $variant caret on line $i',
              );
            }
          }
        }
      },
    );
  });

  group('controller seam (D7)', () {
    testWidgets(
      'the controller builds what buildLivePreviewSpan builds with its own props',
      (tester) async {
        final context = await _context(tester);
        const text =
            '---\nk: v\n---\n# Head **b** [[Ghost]] [[Real]] [l](u)\n'
            '- [x] done ~~s~~\n> q *i*\n```\n**x**\n```\n';
        bool resolver(String t) => t != 'Ghost';
        final hover = TextRange(
          start: text.indexOf('[[Real]]'),
          end: text.indexOf('[[Real]]') + 8,
        );
        final cases =
            <
              ({
                String name,
                bool focused,
                TextSelection selection,
                bool itemText,
                bool taskDone,
                bool quote,
                bool atSegmentStart,
                bool Function(String)? isResolved,
                TextRange? cmdHover,
              })
            >[
              (
                name: 'focused caret on heading',
                focused: true,
                selection: _caret(text.indexOf('Head')),
                itemText: false,
                taskDone: false,
                quote: false,
                atSegmentStart: true,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'unfocused caret on heading',
                focused: false,
                selection: _caret(text.indexOf('Head')),
                itemText: false,
                taskDone: false,
                quote: false,
                atSegmentStart: true,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'selection across lines',
                focused: true,
                selection: TextSelection(
                  baseOffset: 2,
                  extentOffset: text.indexOf('done'),
                ),
                itemText: false,
                taskDone: false,
                quote: false,
                atSegmentStart: false,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'item text',
                focused: true,
                selection: _caret(0),
                itemText: true,
                taskDone: false,
                quote: false,
                atSegmentStart: true,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'done task',
                focused: true,
                selection: _caret(0),
                itemText: true,
                taskDone: true,
                quote: false,
                atSegmentStart: true,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'quote',
                focused: false,
                selection: _caret(0),
                itemText: true,
                taskDone: false,
                quote: true,
                atSegmentStart: true,
                isResolved: null,
                cmdHover: null,
              ),
              (
                name: 'ghosts and hover',
                focused: true,
                selection: _caret(text.length),
                itemText: false,
                taskDone: false,
                quote: false,
                atSegmentStart: true,
                isResolved: resolver,
                cmdHover: hover,
              ),
            ];
        for (final k in cases) {
          final c =
              _controller(text, selection: k.selection, focused: k.focused)
                ..itemText = k.itemText
                ..taskDone = k.taskDone
                ..quote = k.quote
                ..atSegmentStart = k.atSegmentStart
                ..isResolved = k.isResolved
                ..cmdHover = k.cmdHover;
          final expected = buildLivePreviewSpan(
            text,
            style: _base(),
            selection: k.selection,
            forceHidden: !k.focused,
            itemText: k.itemText,
            taskDone: k.taskDone,
            quote: k.quote,
            atSegmentStart: k.atSegmentStart,
            isResolved: k.isResolved,
            cmdHover: k.cmdHover,
          );
          expect(_controllerSpan(context, c), expected, reason: k.name);
        }
      },
    );

    test('the isResolved and cmdHover props default to null', () {
      final c = LivePreviewController(text: '[[a]]');
      addTearDown(c.dispose);
      expect(c.isResolved, isNull);
      expect(c.cmdHover, isNull);
    });

    test(
      'setting isResolved or cmdHover notifies the controller listeners',
      () {
        final c = LivePreviewController(text: '[[a]]');
        addTearDown(c.dispose);
        var notified = 0;
        c.addListener(() => notified++);
        c.cmdHover = const TextRange(start: 0, end: 5);
        expect(notified, 1, reason: 'cmdHover set');
        c.isResolved = (_) => false;
        expect(notified, 2, reason: 'isResolved set');
        c.cmdHover = null;
        expect(notified, 3, reason: 'cmdHover cleared');
        expect(c.cmdHover, isNull);
        expect(c.isResolved!('a'), isFalse);
      },
    );

    test(
      'buildLivePreviewSpan defaults build a prose field at segment start with markers free to reveal',
      () {
        const text = '---\nk: v\n---\n# H **b** [[G]]\n';
        final sel = _caret(text.indexOf('H **'));
        expect(
          buildLivePreviewSpan(text, style: _base(), selection: sel),
          buildLivePreviewSpan(
            text,
            style: _base(),
            selection: sel,
            forceHidden: false,
            itemText: false,
            taskDone: false,
            quote: false,
            atSegmentStart: true,
            isResolved: null,
            cmdHover: null,
          ),
        );
        final span = buildLivePreviewSpan(text, style: _base(), selection: sel);
        // A heading line (not item text), its markers revealed at its size
        // (WI #223: H1 26 px, heading1).
        _expectMarker(span, text, _range(text, '# '), size: 26);
        _expectMarker(span, text, _range(text, '**'), size: 26);
        _eachStyle(span, text, _range(text, 'b'), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
          expect(_fontStyle(s), FontStyle.normal, reason: '$why not quote');
          expect(
            _has(s, TextDecoration.lineThrough),
            isFalse,
            reason: '$why not done',
          );
          expect(s.color, OmColors.heading1, reason: why);
        });
        // Frontmatter at the segment start: plain, not a hidden rule.
        _expectPlainRange(span, text, _range(text, '---'));
        _eachStyle(span, text, _range(text, 'G'), (s, why) {
          expect(s.color, OmColors.accent, reason: why);
        });
      },
    );
  });

  group('marker reveal (AC2, AC3)', () {
    testWidgets(
      'caret line markers render fg2 at normal width while other lines and an unfocused segment hide them',
      (tester) async {
        final context = await _context(tester);
        const text = 'one **b** two\nthree *i* four\nfive ~~s~~';
        final bold0 = _range(text, '**');
        final bold1 = _range(text, '**', nth: 1);
        final it0 = _range(text, '*i', nth: 0);
        final it1 = (text.indexOf('i* ') + 1, text.indexOf('i* ') + 2);
        final st0 = _range(text, '~~');
        final st1 = _range(text, '~~', nth: 1);

        final c = _controller(text, selection: _caret(2));
        var span = _controllerSpan(context, c);
        _expectMarker(span, text, bold0);
        _expectMarker(span, text, bold1);
        _expectHidden(span, text, it0.$1, it0.$1 + 1);
        _expectHiddenRange(span, text, it1);
        _expectHiddenRange(span, text, st0);
        _expectHiddenRange(span, text, st1);

        c.selection = _caret(text.indexOf('five'));
        span = _controllerSpan(context, c);
        _expectHiddenRange(span, text, bold0);
        _expectHiddenRange(span, text, bold1);
        _expectHidden(span, text, it0.$1, it0.$1 + 1);
        _expectMarker(span, text, st0);
        _expectMarker(span, text, st1);

        final unfocused = _controller(
          text,
          selection: _caret(2),
          focused: false,
        );
        span = _controllerSpan(context, unfocused);
        for (final r in [bold0, bold1, it1, st0, st1]) {
          _expectHiddenRange(span, text, r);
        }
        _expectHidden(span, text, it0.$1, it0.$1 + 1);
        // Content stays visible either way.
        expect(
          _width(span, text.indexOf('b'), text.indexOf('b') + 1),
          greaterThan(0),
        );
      },
    );

    testWidgets(
      'focusing the field reveals caret line markers and unfocusing hides them',
      (tester) async {
        const text = 'a **b** c\nnext';
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final gate = ValueNotifier<bool>(false);
        addTearDown(gate.dispose);
        focus.addListener(() => gate.value = focus.hasFocus);
        final c = LivePreviewController(text: text)..revealGate = gate;
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(
                key: const Key('wi164-field'),
                controller: c,
                focusNode: focus,
                maxLines: null,
                style: _base(),
              ),
            ),
          ),
        );
        InlineSpan rendered() =>
            wi159EditableIn(tester, find.byKey(const Key('wi164-field'))).text!;
        final marker = _range(text, '**');

        focus.requestFocus();
        await tester.pump();
        c.selection = _caret(1);
        await tester.pump();
        expect(_styleAt(rendered(), marker.$1).color, OmColors.fg2);
        expect(_width(rendered(), marker.$1, marker.$2), greaterThan(1));

        focus.unfocus();
        await tester.pump();
        expect(_width(rendered(), marker.$1, marker.$2), lessThan(0.01));
      },
    );

    test(
      'a caret at a line end reveals only that line and a caret at the next line start reveals only the next',
      () {
        const text = 'a **b**\nc **d**';
        final l0 = _range(text, '**');
        final l1 = _range(text, '**', nth: 2);
        var span = _build(text, selection: _caret(text.indexOf('\n')));
        _expectMarker(span, text, l0);
        _expectHiddenRange(span, text, l1);
        span = _build(text, selection: _caret(text.indexOf('\n') + 1));
        _expectHiddenRange(span, text, l0);
        _expectMarker(span, text, l1);
      },
    );

    testWidgets(
      'a selection spanning three lines reveals markers on all three and a selected marker renders fg1',
      (tester) async {
        final context = await _context(tester);
        const text = 'a **b**\nc *d*\ne ~~f~~\ng `h`';
        final sel = TextSelection(
          baseOffset: text.indexOf('**'),
          extentOffset: text.indexOf('f~~') + 1,
        );
        final span = _controllerSpan(
          context,
          _controller(text, selection: sel),
        );
        // Selected markers: fg1.
        _expectMarker(span, text, _range(text, '**'), color: OmColors.fg1);
        _expectMarker(
          span,
          text,
          _range(text, '**', nth: 1),
          color: OmColors.fg1,
        );
        final d = text.indexOf('*d*');
        _expectMarker(span, text, (d, d + 1), color: OmColors.fg1);
        _expectMarker(span, text, (d + 2, d + 3), color: OmColors.fg1);
        _expectMarker(span, text, _range(text, '~~'), color: OmColors.fg1);
        // Revealed (the line is touched) but outside the selection: fg2.
        _expectMarker(span, text, _range(text, '~~', nth: 1));
        // The fourth line is untouched: hidden.
        final h = text.indexOf('`h`');
        _expectHidden(span, text, h, h + 1);
        _expectHidden(span, text, h + 2, h + 3);
      },
    );

    test('forceHidden hides the caret line markers for read only cards', () {
      const text = '## Head **b** [l](u)';
      final span = _build(text, selection: _caret(4), forceHidden: true);
      _expectHidden(span, text, 0, 3);
      _expectHiddenRange(span, text, _range(text, '**'));
      _expectHiddenRange(span, text, _range(text, '](u)'));
    });
  });

  // WI #223 (Spec #222, ticket #221): heading levels in design A + D. Shown
  // heading text is JetBrains Mono H1 26 w700 heading1, H2 19 w700 fg0, H3
  // 15 w700 fg0, H4 to H6 11 w500 fg2; markers stay fg2 (fg1 selected)
  // regular at the line size; line heights stay 40 / 34 / 28.5 / 22.95.
  // Every style is checked over two bases (the fg0 body of today and the fg1
  // body of #224 and the cards), so a heading colour must be the heading's
  // own, never one inherited from the base.
  group('heading levels design A and D (WI 223)', () {
    test('OmColors heading1 is FFFFFFFF', () {
      expect(OmColors.heading1.toARGB32(), 0xFFFFFFFF, reason: 'heading1');
    });

    test(
      'headingFontSize returns 26 19 15 for levels one to three and 11 for levels four to six',
      () {
        for (final (level, size) in [
          (1, 26.0),
          (2, 19.0),
          (3, 15.0),
          (4, 11.0),
          (5, 11.0),
          (6, 11.0),
        ]) {
          expect(headingFontSize(level), size, reason: 'H$level');
        }
      },
    );

    for (final (name, levels, size, weight, colour) in [
      (
        'H1 shown text renders mono 26 w700 heading1 upright with no letter spacing hidden and revealed',
        [1],
        26.0,
        FontWeight.w700,
        OmColors.heading1,
      ),
      (
        'H2 shown text renders mono 19 w700 fg0 upright with no letter spacing hidden and revealed',
        [2],
        19.0,
        FontWeight.w700,
        OmColors.fg0,
      ),
      (
        'H3 shown text renders mono 15 w700 fg0 upright with no letter spacing hidden and revealed',
        [3],
        15.0,
        FontWeight.w700,
        OmColors.fg0,
      ),
      (
        'H4 H5 and H6 shown text renders mono 11 w500 fg2 in its written case upright with no letter spacing hidden and revealed',
        [4, 5, 6],
        11.0,
        FontWeight.w500,
        OmColors.fg2,
      ),
    ]) {
      test(name, () {
        for (final level in levels) {
          final text = '${'#' * level} Mixed Case title\nbody';
          final title = _range(text, 'Mixed Case title');
          final marker = (0, title.$1);
          for (final base in _wi223Bases()) {
            for (final (state, selection, forceHidden) in [
              ('hidden', _caret(text.length), false),
              ('revealed', _caret(title.$1 + 2), false),
              ('forced hidden', _caret(title.$1 + 2), true),
            ]) {
              final why =
                  'H$level $state over the ${_wi223BaseName(base)} base';
              final span = buildLivePreviewSpan(
                text,
                style: base,
                selection: selection,
                forceHidden: forceHidden,
              );
              _wi223ExpectHeadingText(
                span,
                text,
                title,
                size: size,
                weight: weight,
                colour: colour,
                why: why,
              );
              if (state == 'revealed') {
                _expectMarker(span, text, marker, size: size);
              } else {
                _expectHiddenRange(span, text, marker);
              }
              // The body line below keeps the base style.
              _expectPlainRange(
                span,
                text,
                _range(text, 'body'),
                color: base.color!,
              );
              // No text transform: the source stays byte-exact.
              _expectExactPlainText(span, text, why);
            }
          }
        }
      });
    }

    test(
      'revealed heading markers render fg2 or fg1 while selected in regular upright at the line font size',
      () {
        for (final (level, size) in _wi223Sizes) {
          final text = '${'#' * level} T **b** x\nbody';
          final marker = (0, level + 1);
          final why = 'H$level';
          // The caret on the line reveals every marker in fg2.
          var span = _build(text, selection: _caret(text.indexOf('T')));
          _expectMarker(span, text, marker, size: size);
          _expectMarker(span, text, _range(text, '**'), size: size);
          _expectMarker(span, text, _range(text, '**', nth: 1), size: size);
          // A selection over the hashes and space turns them fg1; the bold
          // markers outside it stay fg2.
          span = _build(
            text,
            selection: TextSelection(baseOffset: 0, extentOffset: level + 1),
          );
          _expectMarker(span, text, marker, size: size, color: OmColors.fg1);
          _expectMarker(span, text, _range(text, '**'), size: size);
          // Over the fg1 base the markers keep their own colours.
          span = buildLivePreviewSpan(
            text,
            style: _wi223Bases().last,
            selection: _caret(text.indexOf('T')),
          );
          _expectMarker(span, text, marker, size: size);
          expect(
            _styleAt(span, text.indexOf('T')).fontSize,
            size,
            reason: '$why text and markers share the line size',
          );
        }
      },
    );

    test(
      'inline tokens inside a heading keep their own colour and the heading colour fills the other runs',
      () {
        for (final (level, colour) in _wi223Colours) {
          final text =
              '${'#' * level} Lead `code` ~~old~~ [site](u) [[Real]] '
              '[[Ghost]] tail\nbody';
          final lineEnd = text.indexOf('\n');
          for (final base in _wi223Bases()) {
            final why = 'H$level over the ${_wi223BaseName(base)} base';
            final span = buildLivePreviewSpan(
              text,
              style: base,
              selection: _caret(text.length),
              isResolved: (t) => t == 'Real',
            );
            Color? at(String needle) =>
                _styleAt(span, _range(text, needle).$1).color;
            expect(at('Lead'), colour, reason: '$why plain run');
            expect(at('tail'), colour, reason: '$why plain run');
            expect(at('code'), OmColors.fg1, reason: '$why inline code');
            expect(at('old'), OmColors.fg2, reason: '$why strike');
            expect(at('site'), OmColors.info, reason: '$why link');
            expect(at('Real'), OmColors.accent, reason: '$why wikilink');
            expect(at('Ghost'), OmColors.fg2, reason: '$why ghost');
          }
          // Selected: link and ghost text turn fg1; the heading colour and
          // the other tokens stay.
          final span = buildLivePreviewSpan(
            text,
            style: _base(),
            selection: TextSelection(baseOffset: 0, extentOffset: lineEnd),
            isResolved: (t) => t == 'Real',
          );
          Color? at(String needle) =>
              _styleAt(span, _range(text, needle).$1).color;
          final why = 'H$level selected';
          expect(at('Lead'), colour, reason: '$why plain run');
          expect(at('site'), OmColors.fg1, reason: '$why link');
          expect(at('Ghost'), OmColors.fg1, reason: '$why ghost');
          expect(at('Real'), OmColors.accent, reason: '$why wikilink');
          expect(at('code'), OmColors.fg1, reason: '$why inline code');
          expect(at('old'), OmColors.fg2, reason: '$why strike');
        }
      },
    );

    test(
      'livePreviewTextStyle gives a heading run its colour only after token ink code line quote and done',
      () {
        TextStyle? style({
          int level = 1,
          LivePreviewInk ink = LivePreviewInk.none,
          bool codeLine = false,
          bool quote = false,
          bool done = false,
          bool selected = false,
        }) => livePreviewTextStyle(
          headingLevel: level,
          codeLine: codeLine,
          bold: false,
          italic: false,
          strike: false,
          link: false,
          ghost: false,
          hover: false,
          ink: ink,
          quote: quote,
          done: done,
          selected: selected,
        );

        for (final (level, colour) in _wi223Colours) {
          final why = 'H$level';
          expect(style(level: level)?.color, colour, reason: why);
          expect(
            style(level: level, selected: true)?.color,
            colour,
            reason: '$why selected plain heading text keeps its colour',
          );
          for (final (ink, selected, inked) in [
            (LivePreviewInk.code, false, OmColors.fg1),
            (LivePreviewInk.strike, false, OmColors.fg2),
            (LivePreviewInk.link, false, OmColors.info),
            (LivePreviewInk.link, true, OmColors.fg1),
            (LivePreviewInk.wikilink, false, OmColors.accent),
            (LivePreviewInk.ghost, false, OmColors.fg2),
            (LivePreviewInk.ghost, true, OmColors.fg1),
          ]) {
            expect(
              style(level: level, ink: ink, selected: selected)?.color,
              inked,
              reason: '$why $ink selected $selected beats the heading',
            );
          }
          expect(
            style(level: level, codeLine: true)?.color,
            OmColors.fg1,
            reason: '$why code line beats the heading',
          );
          expect(
            style(level: level, quote: true)?.color,
            OmColors.fg1,
            reason: '$why quote beats the heading',
          );
          expect(
            style(level: level, done: true)?.color,
            OmColors.fg2,
            reason: '$why done beats the heading',
          );
          expect(
            style(level: level, done: true, selected: true)?.color,
            OmColors.fg1,
            reason: '$why selected done beats the heading',
          );
        }
        // Not a heading: plain text inherits the base (no style at all).
        expect(style(level: 0), isNull, reason: 'body text inherits');
      },
    );

    test(
      'bold inside an H4 to H6 heading renders w700 while the rest of the line is w500',
      () {
        for (final level in [4, 5, 6]) {
          final text = '${'#' * level} plain **strong** *slant* end\nbody';
          for (final base in _wi223Bases()) {
            final span = buildLivePreviewSpan(
              text,
              style: base,
              selection: _caret(text.length),
            );
            final why = 'H$level over the ${_wi223BaseName(base)} base';
            _wi223ExpectHeadingText(
              span,
              text,
              _range(text, 'strong'),
              size: 11,
              weight: FontWeight.w700,
              colour: OmColors.fg2,
              why: '$why bold',
            );
            for (final rest in ['plain ', ' end']) {
              _wi223ExpectHeadingText(
                span,
                text,
                _range(text, rest),
                size: 11,
                weight: FontWeight.w500,
                colour: OmColors.fg2,
                why: '$why "$rest"',
              );
            }
            _wi223ExpectHeadingText(
              span,
              text,
              _range(text, 'slant'),
              size: 11,
              weight: FontWeight.w500,
              colour: OmColors.fg2,
              fontStyle: FontStyle.italic,
              why: '$why italic',
            );
          }
        }
        // H1 to H3 are w700 throughout, bold or not.
        for (final (level, size) in _wi223Sizes.take(3)) {
          final text = '${'#' * level} plain **strong**';
          final span = _build(text, selection: _caret(0), forceHidden: true);
          for (final run in ['plain ', 'strong']) {
            _eachStyle(span, text, _range(text, run), (s, why) {
              expect(_weight(s), FontWeight.w700, reason: 'H$level $why');
              expect(s.fontSize, size, reason: 'H$level $why');
            });
          }
        }
      },
    );

    testWidgets(
      'each heading line lays out at its line height in a field with even leading and the controller strut hidden and revealed',
      (tester) async {
        for (final (level, size) in _wi223Sizes) {
          final text = '${'#' * level} Title\nbody';
          final title = _range(text, 'Title');
          for (final revealed in [false, true]) {
            final why = 'H$level ${revealed ? 'revealed' : 'hidden'}';
            final c = _controller(
              text,
              selection: _caret(revealed ? title.$1 + 2 : text.length),
            );
            final editable = await _wi223PumpEditorField(tester, c);
            final span = editable.text! as TextSpan;
            // The premise: the field lays text out with even leading and
            // the heading at its new size, its markers as asked.
            expect(
              span.style?.leadingDistribution,
              TextLeadingDistribution.even,
              reason: '$why: the field style has even leading',
            );
            expect(
              _styleAt(span, title.$1).fontSize,
              size,
              reason: '$why: heading text size',
            );
            expect(
              _styleAt(span, 0).fontSize,
              revealed ? size : 0,
              reason: '$why: hash marker',
            );
            final lines = RenderEditableLineBoxes(editable).lines;
            final heights = [for (final l in lines) l.bottom - l.top];
            expect(heights, hasLength(2), reason: '$why: two lines');
            expect(
              heights.first,
              closeTo(headingLineHeight(level), _wi223Tolerance),
              reason: '$why: heading line of $heights',
            );
            expect(
              heights.last,
              closeTo(_bodyLine, _wi223Tolerance),
              reason: '$why: body line of $heights',
            );
            // Only the line heights: the engine snaps each line bottom to
            // a whole pixel, so line tops and bottoms are not sums of them.
            expect(
              lines.last.top,
              greaterThanOrEqualTo(lines.first.bottom),
              reason: '$why: the body line sits below the heading line',
            );
          }
        }
      },
    );

    testWidgets(
      'an H4 to H6 line followed by a body line totals two body lines in a field with even leading',
      (tester) async {
        // The reference: two plain body lines in the same field.
        final plain = _controller('Small heading\nbody line');
        final body = RenderEditableLineBoxes(
          await _wi223PumpEditorField(tester, plain),
        ).lines;
        expect(body, hasLength(2), reason: 'two body lines');
        for (final level in [4, 5, 6]) {
          for (final text in [
            '${'#' * level} Small heading\nbody line',
            '${'#' * level} Small **bold** `code` [[Real]]\nbody line',
          ]) {
            for (final revealed in [false, true]) {
              final why = 'H$level ${revealed ? 'revealed' : 'hidden'} "$text"';
              final c = _controller(
                text,
                selection: _caret(revealed ? level + 3 : text.length),
              );
              final editable = await _wi223PumpEditorField(tester, c);
              final span = editable.text! as TextSpan;
              expect(
                _styleAt(span, text.indexOf('Small')).fontSize,
                11,
                reason: '$why: H4 to H6 text is 11 px',
              );
              final lines = RenderEditableLineBoxes(editable).lines;
              expect(lines, hasLength(2), reason: '$why: two lines');
              // Laid out exactly as two body lines of the same field.
              for (final (i, line) in lines.indexed) {
                expect(
                  line.top,
                  closeTo(body[i].top, _wi223Tolerance),
                  reason: '$why: line $i top as two body lines',
                );
                expect(
                  line.bottom,
                  closeTo(body[i].bottom, _wi223Tolerance),
                  reason: '$why: line $i bottom as two body lines',
                );
              }
              final heights = [for (final l in lines) l.bottom - l.top];
              for (final (i, h) in heights.indexed) {
                expect(
                  h,
                  closeTo(_bodyLine, _wi223Tolerance),
                  reason: '$why: 22.95 + 22.95, line $i of $heights',
                );
              }
            }
          }
        }
      },
    );
  });

  group('inline styles (AC5, AC6, AC7, AC8, AC10)', () {
    test(
      'bold italic bold italic and strike render styled with delimiters hidden and snake case and unclosed stay plain',
      () {
        const text =
            'x **b** y *i* z ***bi*** w ~~s~~ snake_case *unclosed\nother';
        final span = _build(text, selection: _caret(text.indexOf('other')));
        final b = text.indexOf('**b**');
        _eachStyle(span, text, (b + 2, b + 3), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
          expect(_fontStyle(s), FontStyle.normal, reason: why);
          expect(s.color, OmColors.fg0, reason: why);
        });
        _expectHidden(span, text, b, b + 2);
        _expectHidden(span, text, b + 3, b + 5);

        final i = text.indexOf('*i*');
        _eachStyle(span, text, (i + 1, i + 2), (s, why) {
          expect(s.fontStyle, FontStyle.italic, reason: why);
          expect(_weight(s), FontWeight.w400, reason: why);
          expect(s.color, OmColors.fg0, reason: why);
        });
        _expectHidden(span, text, i, i + 1);
        _expectHidden(span, text, i + 2, i + 3);

        final bi = text.indexOf('***bi***');
        _eachStyle(span, text, (bi + 3, bi + 5), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
          expect(s.fontStyle, FontStyle.italic, reason: why);
        });
        _expectHidden(span, text, bi, bi + 3);
        _expectHidden(span, text, bi + 5, bi + 8);

        final st = text.indexOf('~~s~~');
        _eachStyle(span, text, (st + 2, st + 3), (s, why) {
          expect(_has(s, TextDecoration.lineThrough), isTrue, reason: why);
          expect(s.color, OmColors.fg2, reason: why);
        });
        _expectHidden(span, text, st, st + 2);
        _expectHidden(span, text, st + 3, st + 5);

        _expectPlainRange(span, text, _range(text, 'snake_case'));
        _expectPlainRange(span, text, _range(text, '*unclosed'));
        _expectPlainRange(span, text, _range(text, 'x '));
        _expectPlainRange(span, text, _range(text, ' w '));
      },
    );

    test(
      'a revealed marker inside bold stays regular upright and undecorated',
      () {
        const text = '***bi*** and ~~s~~';
        final span = _build(text, selection: _caret(0));
        _expectMarker(span, text, (0, 3));
        _expectMarker(span, text, (5, 8));
        _expectMarker(span, text, _range(text, '~~'));
        _expectMarker(span, text, _range(text, '~~', nth: 1));
        // Content keeps its style while its markers show.
        _eachStyle(span, text, (3, 5), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
          expect(s.fontStyle, FontStyle.italic, reason: why);
        });
      },
    );

    test(
      'inline code text renders fg1 with its backticks hidden off the caret line',
      () {
        const text = 'run `ls -a` now\nother';
        final code = _range(text, 'ls -a');
        var span = _build(text, selection: _caret(text.length));
        _expectPlainRange(span, text, code, color: OmColors.fg1);
        _expectHidden(span, text, code.$1 - 1, code.$1);
        _expectHidden(span, text, code.$2, code.$2 + 1);
        _expectPlainRange(span, text, _range(text, 'run '));
        span = _build(text, selection: _caret(0));
        _expectMarker(span, text, (code.$1 - 1, code.$1));
        _expectMarker(span, text, (code.$2, code.$2 + 1));
      },
    );

    test(
      'a markdown link shows its text in info with an underline and hides the brackets and url off the caret line',
      () {
        const text = '[text](https://x)\nother';
        final t = _range(text, 'text');
        final tail = _range(text, '](https://x)');
        void expectText(TextSpan span) {
          _eachStyle(span, text, t, (s, why) {
            expect(s.color, OmColors.info, reason: why);
            expect(_has(s, TextDecoration.underline), isTrue, reason: why);
            expect(_weight(s), FontWeight.w400, reason: why);
          });
          expect(
            _width(span, t.$1, t.$2),
            closeTo(_normalWidth('text', 13.5), 0.01),
          );
        }

        var span = _build(text, selection: _caret(text.indexOf('other')));
        expectText(span);
        _expectHidden(span, text, 0, 1);
        _expectHiddenRange(span, text, tail);

        // On the caret line `[` and `](https://x)` show fg2, not underlined.
        span = _build(text, selection: _caret(0));
        expectText(span);
        _expectMarker(span, text, (0, 1));
        _expectMarker(span, text, tail);
      },
    );

    test('a link wrapping bold text renders bold info underlined text', () {
      const text = '[**go** now](u)';
      final span = _build(text);
      _eachStyle(span, text, _range(text, 'go'), (s, why) {
        expect(s.fontWeight, FontWeight.w700, reason: why);
        expect(s.color, OmColors.info, reason: why);
        expect(_has(s, TextDecoration.underline), isTrue, reason: why);
      });
      _eachStyle(span, text, _range(text, ' now'), (s, why) {
        expect(s.color, OmColors.info, reason: why);
        expect(_has(s, TextDecoration.underline), isTrue, reason: why);
      });
      _expectHiddenRange(span, text, _range(text, '**'));
      _expectHiddenRange(span, text, _range(text, '](u)'));
    });

    test(
      'a wikilink shows its alias in accent without underline and hides the rest and a transclusion renders like a wikilink',
      () {
        const text =
            '[[Title~extends|alias]] [[Title]] ![[2026-09-05#^ab12]]\nother';
        void expectShown(TextSpan span, (int, int) r) {
          _eachStyle(span, text, r, (s, why) {
            expect(s.color, OmColors.accent, reason: why);
            expect(_decorated(s), isFalse, reason: '$why no underline');
            expect(_weight(s), FontWeight.w400, reason: why);
          });
          expect(
            _width(span, r.$1, r.$2),
            closeTo(_normalWidth(text.substring(r.$1, r.$2), 13.5), 0.01),
          );
        }

        final alias = _range(text, 'alias');
        final head = _range(text, '[[Title~extends|');
        final close0 = _range(text, ']]');
        final title = _range(text, 'Title', nth: 1);
        final date = _range(text, '2026-09-05');

        var span = _build(text, selection: _caret(text.indexOf('other')));
        expectShown(span, alias);
        _expectHiddenRange(span, text, head);
        _expectHiddenRange(span, text, close0);
        expectShown(span, title);
        _expectHidden(span, text, title.$1 - 2, title.$1);
        _expectHidden(span, text, title.$2, title.$2 + 2);
        expectShown(span, date);
        _expectHidden(span, text, date.$1 - 3, date.$1);
        _expectHiddenRange(span, text, _range(text, '#^ab12]]'));

        // On the caret line the kind and alias head is one fg2 run.
        span = _build(text, selection: _caret(0));
        expectShown(span, alias);
        _expectMarker(span, text, head);
        _expectMarker(span, text, close0);
        _expectMarker(span, text, (date.$1 - 3, date.$1));
        _expectMarker(span, text, _range(text, '#^ab12]]'));
      },
    );

    test(
      'an unresolved wikilink renders fg2 with a dashed fg3 underline and a null resolver renders every wikilink resolved',
      () {
        const text = '[[Ghost]] and [[Real]]\nother';
        final ghost = _range(text, 'Ghost');
        final real = _range(text, 'Real');
        final caret = _caret(text.indexOf('other'));
        void expectResolved(TextSpan span, (int, int) r) =>
            _eachStyle(span, text, r, (s, why) {
              expect(s.color, OmColors.accent, reason: why);
              expect(_decorated(s), isFalse, reason: '$why no underline');
            });

        var span = _build(
          text,
          selection: caret,
          isResolved: (t) => t == 'Real',
        );
        _eachStyle(span, text, ghost, (s, why) {
          expect(s.color, OmColors.fg2, reason: why);
          expect(_has(s, TextDecoration.underline), isTrue, reason: why);
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
          expect(s.decorationColor, OmColors.fg3, reason: why);
        });
        expectResolved(span, real);
        _expectHidden(span, text, ghost.$1 - 2, ghost.$1);
        _expectHidden(span, text, ghost.$2, ghost.$2 + 2);

        span = _build(text, selection: caret);
        expectResolved(span, ghost);
        expectResolved(span, real);

        span = _build(text, selection: caret, isResolved: (_) => true);
        expectResolved(span, ghost);
      },
    );

    test(
      'a revealed ghost wikilink shows fg2 brackets around its dashed underlined title',
      () {
        const text = 'see [[Ghost]]';
        final span = _build(
          text,
          selection: _caret(0),
          isResolved: (_) => false,
        );
        final ghost = _range(text, 'Ghost');
        _expectMarker(span, text, (ghost.$1 - 2, ghost.$1));
        _expectMarker(span, text, (ghost.$2, ghost.$2 + 2));
        _eachStyle(span, text, ghost, (s, why) {
          expect(s.color, OmColors.fg2, reason: why);
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
          expect(s.decorationColor, OmColors.fg3, reason: why);
        });
      },
    );

    test(
      'isResolved receives the trimmed wikilink target and the transclusion date',
      () {
        const text = '[[ Ghost |g]] [[Real]] ![[2026-09-05#^ab12]]';
        final asked = <String>[];
        final span = _build(
          text,
          isResolved: (t) {
            asked.add(t);
            return t == 'Real';
          },
        );
        expect(asked, containsAll(<String>['Ghost', 'Real', '2026-09-05']));
        _eachStyle(span, text, (text.indexOf('g]]'), text.indexOf('g]]') + 1), (
          s,
          why,
        ) {
          expect(s.color, OmColors.fg2, reason: why);
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
        });
        _eachStyle(span, text, _range(text, '2026-09-05'), (s, why) {
          expect(s.color, OmColors.fg2, reason: why);
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
          expect(s.decorationColor, OmColors.fg3, reason: why);
        });
        _eachStyle(span, text, _range(text, 'Real'), (s, why) {
          expect(s.color, OmColors.accent, reason: why);
        });
      },
    );

    test(
      'cmd hover underlines a resolved wikilink in accent and changes neither a link nor a ghost',
      () {
        const text = '[[Real]] [l](u) [[Ghost]]';
        bool resolver(String t) => t != 'Ghost';
        TextRange token(String s) =>
            TextRange(start: text.indexOf(s), end: text.indexOf(s) + s.length);
        final real = _range(text, 'Real');
        final ghost = _range(text, 'Ghost');

        var span = _build(
          text,
          isResolved: resolver,
          cmdHover: token('[[Real]]'),
        );
        _eachStyle(span, text, real, (s, why) {
          expect(s.color, OmColors.accent, reason: why);
          expect(_has(s, TextDecoration.underline), isTrue, reason: why);
          expect(
            s.decorationColor ?? s.color,
            OmColors.accent,
            reason: '$why underline in the token colour',
          );
        });

        final plain = _build(text, isResolved: resolver);
        _eachStyle(plain, text, real, (s, why) {
          expect(_decorated(s), isFalse, reason: '$why not hovered');
        });

        void expectSameStyles(TextSpan hovered, String why) {
          for (var i = 0; i < text.length; i++) {
            expect(
              _styleAt(hovered, i),
              _styleAt(plain, i),
              reason: '$why at $i',
            );
          }
        }

        span = _build(text, isResolved: resolver, cmdHover: token('[l](u)'));
        expectSameStyles(span, 'cmd hover on a link is a no-op');
        span = _build(text, isResolved: resolver, cmdHover: token('[[Ghost]]'));
        expectSameStyles(span, 'cmd hover on a ghost changes nothing');
        _eachStyle(span, text, ghost, (s, why) {
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
        });
      },
    );

    test(
      'strike renders fg2 line through and quote text renders italic fg1 and a selected link or ghost renders fg1',
      () {
        const strike = 'a ~~gone~~ b';
        var span = _build(strike);
        _eachStyle(span, strike, _range(strike, 'gone'), (s, why) {
          expect(_has(s, TextDecoration.lineThrough), isTrue, reason: why);
          expect(s.color, OmColors.fg2, reason: why);
          expect(_weight(s), FontWeight.w400, reason: why);
        });

        const q = 'keep it short';
        span = _build(q, itemText: true, quote: true);
        _eachStyle(span, q, (0, q.length), (s, why) {
          expect(s.fontStyle, FontStyle.italic, reason: why);
          expect(s.color, OmColors.fg1, reason: why);
          expect(_has(s, TextDecoration.lineThrough), isFalse, reason: why);
        });
        expect(_width(span, 0, q.length), closeTo(_normalWidth(q, 13.5), 0.01));

        const links = '[link](u) [[Ghost]]\nother';
        final sel = TextSelection(
          baseOffset: 1,
          extentOffset: links.indexOf('Ghost') + 5,
        );
        span = _build(links, selection: sel, isResolved: (_) => false);
        _eachStyle(span, links, _range(links, 'link'), (s, why) {
          expect(s.color, OmColors.fg1, reason: '$why selected link text');
          expect(_has(s, TextDecoration.underline), isTrue, reason: why);
        });
        _eachStyle(span, links, _range(links, 'Ghost'), (s, why) {
          expect(s.color, OmColors.fg1, reason: '$why selected ghost text');
          expect(s.decorationStyle, TextDecorationStyle.dashed, reason: why);
          expect(s.decorationColor, OmColors.fg3, reason: why);
        });
      },
    );

    test('quote text keeps bold content bold in italic fg1', () {
      const q = '**Note**: keep';
      final span = _build(q, itemText: true, quote: true);
      _eachStyle(span, q, _range(q, 'Note'), (s, why) {
        expect(s.fontWeight, FontWeight.w700, reason: why);
        expect(s.fontStyle, FontStyle.italic, reason: why);
        expect(s.color, OmColors.fg1, reason: why);
      });
      _expectHiddenRange(span, q, _range(q, '**'));
    });

    test('quote text with taskDone stays italic fg1 and is not struck', () {
      // Pack #164 decision 3: on a quote row a done-task rule does not apply.
      const q = 'keep **it** short';
      final span = _build(q, itemText: true, quote: true, taskDone: true);
      for (final r in [
        _range(q, 'keep '),
        _range(q, 'it'),
        _range(q, ' short'),
      ]) {
        _eachStyle(span, q, r, (s, why) {
          expect(s.fontStyle, FontStyle.italic, reason: why);
          expect(s.color, OmColors.fg1, reason: why);
          expect(_has(s, TextDecoration.lineThrough), isFalse, reason: why);
        });
      }
    });

    test(
      'a backslash escape keeps its backslash and escaped character visible as plain text',
      () {
        // Spec R5: the escaped character shows literally and the backslash
        // stays visible, on and off the caret line.
        const text =
            r'a \*not italic\* and \*\*not bold\*\* b'
            '\nother';
        final line = (0, text.indexOf('\n'));
        for (final caret in [0, text.length]) {
          final span = _build(text, selection: _caret(caret));
          _expectPlainRange(span, text, line);
        }
      },
    );

    test(
      'hidden markers stay zero width under a base style with letter spacing',
      () {
        // B4 cards and hosts pass their own base style; a hidden marker must
        // not keep the base letter spacing as width.
        const text = '# H **b** [[T|a]] [l](u)\nother';
        final span = buildLivePreviewSpan(
          text,
          style: _base().copyWith(letterSpacing: 1.5),
          selection: _caret(text.length),
        );
        for (final r in [
          _range(text, '# '),
          _range(text, '**'),
          _range(text, '**', nth: 1),
          _range(text, '[[T|'),
          _range(text, ']]'),
          _range(text, '[', nth: 2),
          _range(text, '](u)'),
        ]) {
          _expectHiddenRange(span, text, r);
        }
        expect(
          _width(span, text.indexOf('H'), text.indexOf('H') + 1),
          greaterThan(1),
        );
      },
    );
  });

  group('fenced code (AC9)', () {
    test(
      'a fenced block renders plain mono and its fence lines hide with the caret outside and reveal with the caret inside',
      () {
        const text = 'Before\n```dart\n**x** [[y]]\n```\nAfter';
        final open = _range(text, '```dart');
        final close = _range(text, '```', nth: 1);
        final code = _range(text, '**x** [[y]]');
        void expectCode(TextSpan span) =>
            _expectPlainRange(span, text, code, color: OmColors.fg1);

        for (final outside in [0, text.indexOf('After'), text.length]) {
          final span = _build(text, selection: _caret(outside));
          _expectHiddenRange(span, text, open);
          _expectHiddenRange(span, text, close);
          expectCode(span);
        }
        for (final inside in [open.$1, code.$1 + 2, close.$1, close.$2]) {
          final span = _build(text, selection: _caret(inside));
          _expectMarker(span, text, open);
          _expectMarker(span, text, close);
          expectCode(span);
          _expectPlainRange(span, text, _range(text, 'Before'));
        }
        final unfocused = _build(
          text,
          selection: _caret(code.$1),
          forceHidden: true,
        );
        _expectHiddenRange(unfocused, text, open);
        _expectHiddenRange(unfocused, text, close);
        expectCode(unfocused);
      },
    );

    test(
      'an unclosed fence reveals its opening line with the caret on any later line',
      () {
        const text = 'x\n```\n- inside\n\nmore';
        final open = _range(text, '```');
        var span = _build(text, selection: _caret(text.indexOf('more')));
        _expectMarker(span, text, open);
        _expectPlainRange(
          span,
          text,
          _range(text, '- inside'),
          color: OmColors.fg1,
        );
        span = _build(text, selection: _caret(0));
        _expectHiddenRange(span, text, open);
        _expectPlainRange(
          span,
          text,
          _range(text, 'more'),
          color: OmColors.fg1,
        );
      },
    );
  });

  group('item text and frontmatter (AC11, AC12)', () {
    test(
      'item text with taskDone renders struck through in fg2 and item text keeps a leading hash as plain text',
      () {
        const done = 'ship **A1** today';
        var span = _build(done, itemText: true, taskDone: true);
        for (final r in [
          _range(done, 'ship '),
          _range(done, 'A1'),
          _range(done, ' today'),
        ]) {
          _eachStyle(span, done, r, (s, why) {
            expect(_has(s, TextDecoration.lineThrough), isTrue, reason: why);
            expect(s.color, OmColors.fg2, reason: why);
          });
        }
        _eachStyle(span, done, _range(done, 'A1'), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
        });
        _expectHiddenRange(span, done, _range(done, '**'));

        // Selected done-task text renders fg1.
        span = _build(
          done,
          itemText: true,
          taskDone: true,
          selection: const TextSelection(baseOffset: 0, extentOffset: 4),
        );
        _eachStyle(span, done, (0, 4), (s, why) {
          expect(s.color, OmColors.fg1, reason: why);
          expect(_has(s, TextDecoration.lineThrough), isTrue, reason: why);
        });
        _eachStyle(span, done, _range(done, ' today'), (s, why) {
          expect(s.color, OmColors.fg2, reason: why);
        });

        // Item text: inline styling only, no line classification.
        for (final item in ['# not heading', '---', '```', '> not quote']) {
          span = _build(item, itemText: true);
          _expectPlain(span, item, 0, item.length);
          span = _build(item, itemText: true, selection: _caret(0));
          _expectPlain(span, item, 0, item.length);
        }
        const inline = 'buy **milk**';
        span = _build(inline, itemText: true);
        _eachStyle(span, inline, _range(inline, 'milk'), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
        });
        _expectHiddenRange(span, inline, _range(inline, '**'));
      },
    );

    test(
      'item lines in a prose field keep their markers visible as plain text',
      () {
        const text = '- [ ] task **b**\n1. one\n> quote\n- bullet\nother';
        final span = _build(text, selection: _caret(text.indexOf('other')));
        _expectPlainRange(span, text, _range(text, '- [ ] task '));
        _expectPlainRange(span, text, _range(text, '1. one'));
        _expectPlainRange(span, text, _range(text, '> quote'));
        _expectPlainRange(span, text, _range(text, '- bullet'));
        _expectHiddenRange(span, text, _range(text, '**'));
      },
    );

    test('leading frontmatter renders as plain prose with atSegmentStart', () {
      const text = '---\ntitle: Plan\n# not heading\n---\n# Body';
      final caret = _caret(text.indexOf('Body'));
      var span = _build(text, selection: caret);
      _expectPlainRange(span, text, (0, 3));
      _expectPlainRange(span, text, _range(text, 'title: Plan'));
      _expectPlainRange(span, text, _range(text, '# not heading'));
      _expectPlainRange(span, text, _range(text, '---', nth: 1));
      _eachStyle(span, text, _range(text, 'Body'), (s, why) {
        expect(s.fontSize, 26, reason: why);
        expect(s.fontWeight, FontWeight.w700, reason: why);
      });
      // Off the caret line too.
      span = _build(text, selection: _caret(text.length), forceHidden: true);
      _expectPlainRange(span, text, (0, 3));
      _expectPlainRange(span, text, _range(text, '# not heading'));

      // Not at the segment start: no frontmatter, the first --- is a rule.
      span = _build(text, selection: caret, atSegmentStart: false);
      _expectHidden(span, text, 0, 3);
    });
  });

  group('not rendered (AC13)', () {
    test(
      'a table row html a bare url highlight and a setext underline render unstyled except the hidden rule',
      () {
        const text =
            '| a | b |\n<b>x</b>\nhttps://x.y\n==hi==\nText\n---\nlast';
        final rule = _range(text, '---');
        var span = _build(text, selection: _caret(text.indexOf('last')));
        for (final line in [
          '| a | b |',
          '<b>x</b>',
          'https://x.y',
          '==hi==',
          'Text',
          'last',
        ]) {
          _expectPlainRange(span, text, _range(text, line));
        }
        _expectHiddenRange(span, text, rule);

        // On the caret line the rule characters show as fg2 markers.
        span = _build(text, selection: _caret(rule.$1));
        _expectMarker(span, text, rule);
        _expectPlainRange(span, text, _range(text, 'Text'));
      },
    );
  });

  group('line metrics (AC14, R13)', () {
    test(
      'strutStyle is a 22.95 minimum strut without forceStrutHeight and an H1 line lays out 40 high',
      () {
        final c = LivePreviewController(text: '# Title');
        addTearDown(c.dispose);
        final strut = c.strutStyle;
        expect(strut, isNotNull);
        expect(strut!.fontSize! * strut.height!, closeTo(_bodyLine, 1e-9));
        expect(strut.forceStrutHeight, isNot(true));

        double heightOf(TextSpan span) {
          final painter = TextPainter(
            text: span,
            textDirection: TextDirection.ltr,
            strutStyle: strut,
          )..layout();
          final h = painter.height;
          painter.dispose();
          return h;
        }

        // Test-font line metrics round to whole pixels: 0.51 tolerance.
        expect(heightOf(_build('# Title')), closeTo(40, 0.51), reason: 'H1');
        expect(
          heightOf(_build('# Title', selection: _caret(0))),
          closeTo(40, 0.51),
          reason: 'revealed H1',
        );
        expect(heightOf(_build('## Two')), closeTo(34, 0.51), reason: 'H2');
        expect(
          heightOf(_build('## Two', selection: _caret(0))),
          closeTo(34, 0.51),
          reason: 'revealed H2 keeps 34',
        );
        expect(heightOf(_build('### Three')), closeTo(28.5, 0.51));
        expect(heightOf(_build('#### Four')), closeTo(_bodyLine, 0.51));
        expect(heightOf(_build('body')), closeTo(_bodyLine, 0.51));
        // A hidden rule line keeps its line height.
        expect(heightOf(_build('a\n---\nb')), closeTo(3 * _bodyLine, 3 * 0.51));
        expect(
          heightOf(_build('# Title\nbody')),
          closeTo(40 + _bodyLine, 2 * 0.51),
        );
      },
    );

    test(
      'inline code content lays out on the same glyph rows as plain text under the strut',
      () {
        // B2 draws the code pill from the line top (17 px at line top + 2),
        // so the code style must not move its glyphs off the line the plain
        // text sits on: no size, height or face of its own.
        const text = 'say `code` now';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        final strut = c.strutStyle;

        List<TextBox> boxes(InlineSpan span, int start, int end) {
          final painter = TextPainter(
            text: span,
            textDirection: TextDirection.ltr,
            strutStyle: strut,
          )..layout();
          final b = painter.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
          );
          painter.dispose();
          return b;
        }

        final code = _range(text, 'code');
        final styled = _build(text);
        final plain = TextSpan(text: text, style: _base());
        expect(_styleAt(styled, code.$1).color, OmColors.fg1);
        final codeBox = boxes(styled, code.$1, code.$2).single;
        final sayBox = boxes(styled, 0, 3).single;
        final plainBox = boxes(plain, code.$1, code.$2).single;
        expect(codeBox.top, sayBox.top, reason: 'same top as plain text');
        expect(codeBox.bottom, sayBox.bottom, reason: 'same bottom');
        expect(codeBox.top, plainBox.top, reason: 'as unstyled text lays out');
        expect(codeBox.bottom, plainBox.bottom);
        expect(
          codeBox.right - codeBox.left,
          closeTo(_normalWidth('code', 13.5), 1e-9),
          reason: 'body size',
        );
      },
    );

    test('the strut uses the body mono face', () {
      // The strut sets the minimum line from the body face, so heading and
      // body heights do not depend on the platform default font.
      final c = LivePreviewController(text: 'x');
      addTearDown(c.dispose);
      final strut = c.strutStyle!;
      final body = OmType.mono(size: 13.5);
      expect(strut.fontFamily, body.fontFamily);
      expect(strut.fontFamily, isNotNull);
      expect(strut.fontFamilyFallback, body.fontFamilyFallback);
      expect(strut.fontSize, 13.5);
    });
  });

  // Ruling D18: a code row's field (C1 sets codeRow) lays its hidden fence
  // lines out at the design's 8 px (pack #161: code box 61.88 = 8 + 2 x
  // 22.94 + 8); every other field keeps the 22.95 px minimum strut.
  group('code row strut (D18)', () {
    testWidgets(
      'codeRow defaults to false and keeps the 22.95 minimum strut and 22.95 hidden fence lines',
      (tester) async {
        const text = '```\nab\ncd\n```';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        expect(c.codeRow, isFalse);
        final fromValue = LivePreviewController.fromValue(
          const TextEditingValue(text: text),
        );
        addTearDown(fromValue.dispose);
        expect(fromValue.codeRow, isFalse, reason: 'fromValue default');

        final strut = c.strutStyle;
        expect(strut, isNotNull);
        expect(strut!.fontSize! * strut.height!, closeTo(_bodyLine, 1e-9));
        expect(strut.forceStrutHeight, isNot(true));

        // Unfocused (the default reveal gate): both fence lines hidden, and
        // a prose field keeps them at the body line (D18: #164 as merged).
        final lines = await _pumpCodeRowField(tester, c);
        _expectLineHeights(lines, [
          _bodyLine,
          _bodyLine,
          _bodyLine,
          _bodyLine,
        ], 'default field');
      },
    );

    testWidgets(
      'codeRow true drops the 22.95 minimum strut and lays out each hidden fence line 8 high',
      (tester) async {
        final fixtures = <(String, List<double>)>[
          (
            '```\nab\ncd\n```',
            [_hiddenFence, _bodyLine, _bodyLine, _hiddenFence],
          ),
          ('```dart\nab\n```', [_hiddenFence, _bodyLine, _hiddenFence]),
        ];
        for (final (text, heights) in fixtures) {
          final c = LivePreviewController(text: text)..codeRow = true;
          addTearDown(c.dispose);
          expect(c.codeRow, isTrue);

          final strut = _effectiveStrut(c);
          expect(strut.forceStrutHeight, isNot(true), reason: text);
          expect(
            strut.fontSize! * (strut.height ?? 1),
            lessThanOrEqualTo(_hiddenFence + 1e-9),
            reason: '$text: no minimum above the hidden fence line',
          );

          final lines = await _pumpCodeRowField(tester, c);
          _expectLineHeights(lines, heights, text);

          // The fence characters stay hidden (zero-width) and the code lines
          // stay plain fg1 mono at the body size.
          final open = _range(
            text,
            text.startsWith('```dart') ? '```dart' : '```',
          );
          final close = _range(text, '```', nth: 1);
          for (final fence in [open, close]) {
            final boxes = lines.boxesFor(
              TextRange(start: fence.$1, end: fence.$2),
            );
            expect(boxes, isNotEmpty, reason: '$text fence $fence');
            for (final b in boxes) {
              expect(
                b.width,
                lessThan(0.01),
                reason: '$text fence $fence hidden',
              );
            }
          }
          final rendered =
              wi159EditableIn(
                    tester,
                    find.byKey(const Key('wi164-code-row-field')),
                  ).text!
                  as TextSpan;
          _expectExactPlainText(rendered, text, text);
          _expectPlainRange(
            rendered,
            text,
            _range(text, 'ab'),
            color: OmColors.fg1,
          );
        }
      },
    );

    testWidgets(
      'codeRow true keeps code lines, blank code lines and revealed fence lines 22.95 high',
      (tester) async {
        const text = '```dart\nab\n\ncd\n```';
        final gate = ValueNotifier<bool>(false);
        addTearDown(gate.dispose);
        final c = LivePreviewController(text: text)
          ..codeRow = true
          ..revealGate = gate;
        addTearDown(c.dispose);

        var lines = await _pumpCodeRowField(tester, c);
        _expectLineHeights(lines, [
          _hiddenFence,
          _bodyLine,
          _bodyLine,
          _bodyLine,
          _hiddenFence,
        ], 'hidden: a blank code line keeps the body line');

        // Caret inside the block while focused: both fence lines show fg2 at
        // the body line (pack #161: revealed fence line 22.95).
        gate.value = true;
        c.selection = _caret(text.indexOf('ab'));
        await tester.pump();
        lines = await _pumpCodeRowField(tester, c);
        _expectLineHeights(lines, [
          _bodyLine,
          _bodyLine,
          _bodyLine,
          _bodyLine,
          _bodyLine,
        ], 'revealed');
        final rendered =
            wi159EditableIn(
                  tester,
                  find.byKey(const Key('wi164-code-row-field')),
                ).text!
                as TextSpan;
        _expectMarker(rendered, text, _range(text, '```dart'));
        _expectMarker(rendered, text, _range(text, '```', nth: 1));
        _expectPlainRange(
          rendered,
          text,
          _range(text, 'cd'),
          color: OmColors.fg1,
        );
      },
    );

    testWidgets(
      'setting codeRow notifies the controller listeners and setting it back restores the 22.95 minimum strut',
      (tester) async {
        const text = '```\nab\n```';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        var notified = 0;
        c.addListener(() => notified++);

        c.codeRow = true;
        expect(notified, 1, reason: 'codeRow set');
        expect(c.codeRow, isTrue);
        var lines = await _pumpCodeRowField(tester, c);
        _expectLineHeights(lines, [
          _hiddenFence,
          _bodyLine,
          _hiddenFence,
        ], 'code row');

        final before = notified;
        c.codeRow = false;
        expect(notified, before + 1, reason: 'codeRow cleared');
        expect(c.codeRow, isFalse);
        final strut = c.strutStyle!;
        expect(strut.fontSize! * strut.height!, closeTo(_bodyLine, 1e-9));
        expect(strut.forceStrutHeight, isNot(true));
        lines = await _pumpCodeRowField(tester, c);
        _expectLineHeights(lines, [
          _bodyLine,
          _bodyLine,
          _bodyLine,
        ], 'back to a prose field');
      },
    );

    testWidgets(
      'the controller builds what buildLivePreviewSpan builds with codeRow',
      (tester) async {
        final context = await _context(tester);
        const text = '```dart\n**x** [[y]]\n\n```';
        for (final (focused, selection) in [
          (false, _caret(text.indexOf('**x'))),
          (true, _caret(text.indexOf('**x'))),
          (true, _caret(-1)),
        ]) {
          final c = _controller(text, selection: selection, focused: focused)
            ..codeRow = true;
          expect(
            _controllerSpan(context, c),
            buildLivePreviewSpan(
              text,
              style: _base(),
              selection: selection,
              forceHidden: !focused,
              codeRow: true,
            ),
            reason: 'focused $focused, $selection',
          );
        }
      },
    );

    test('buildLivePreviewSpan codeRow defaults to false', () {
      const text = '```\nab\n```';
      final sel = _caret(-1);
      final byDefault = buildLivePreviewSpan(
        text,
        style: _base(),
        selection: sel,
      );
      expect(
        byDefault,
        buildLivePreviewSpan(
          text,
          style: _base(),
          selection: sel,
          codeRow: false,
        ),
      );
      // A code row lays its hidden fence lines out shorter than a prose
      // field does, so its span differs while the fences are hidden.
      expect(
        byDefault,
        isNot(
          buildLivePreviewSpan(
            text,
            style: _base(),
            selection: sel,
            codeRow: true,
          ),
        ),
      );
    });
  });
}
