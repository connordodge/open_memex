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
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';

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
        // A heading line (not item text), its markers revealed at its size.
        _expectMarker(span, text, _range(text, '# '), size: 20);
        _expectMarker(span, text, _range(text, '**'), size: 20);
        _eachStyle(span, text, _range(text, 'b'), (s, why) {
          expect(s.fontWeight, FontWeight.w700, reason: why);
          expect(_fontStyle(s), FontStyle.normal, reason: '$why not quote');
          expect(
            _has(s, TextDecoration.lineThrough),
            isFalse,
            reason: '$why not done',
          );
          expect(s.color, OmColors.fg0, reason: why);
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

  group('headings (AC4)', () {
    test(
      'heading text renders mono w700 at 20 17 15 and 13.5 with the hash marker and space hidden off the caret line',
      () {
        const text =
            '# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n'
            'body';
        const sizes = {
          'One': 20.0,
          'Two': 17.0,
          'Three': 15.0,
          'Four': 13.5,
          'Five': 13.5,
          'Six': 13.5,
        };
        void expectHeadings(TextSpan span, {String? revealed}) {
          for (final MapEntry(key: word, value: size) in sizes.entries) {
            final w = _range(text, word);
            final lineStart = text.lastIndexOf('\n', w.$1) + 1;
            _eachStyle(span, text, w, (s, why) {
              expect(s.fontSize, size, reason: '$why size');
              expect(s.fontWeight, FontWeight.w700, reason: '$why weight');
              expect(s.color, OmColors.fg0, reason: '$why colour');
              expect(
                s.fontFamily,
                startsWith('JetBrainsMono'),
                reason: '$why mono',
              );
              expect(_fontStyle(s), FontStyle.normal, reason: '$why upright');
            });
            expect(
              _width(span, w.$1, w.$2),
              closeTo(_normalWidth(word, size), 0.01),
              reason: '$word visible',
            );
            if (word == revealed) {
              // `## ` in fg2, regular, at the heading's own size.
              _expectMarker(span, text, (lineStart, w.$1), size: size);
            } else {
              _expectHidden(span, text, lineStart, w.$1);
            }
          }
        }

        expectHeadings(_build(text, selection: _caret(text.length)));
        expectHeadings(
          _build(text, selection: _caret(text.indexOf('Two'))),
          revealed: 'Two',
        );
        expectHeadings(
          _build(text, selection: _caret(text.indexOf('Six'))),
          revealed: 'Six',
        );
        expectHeadings(_build(text, selection: _caret(0), forceHidden: true));
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
        expect(s.fontSize, 20, reason: why);
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
}
