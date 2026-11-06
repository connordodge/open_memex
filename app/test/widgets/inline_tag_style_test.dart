// WI #245 (A1, Spec #234; rulings D17, D19, TD4; design pack
// design/229-tags/packs/245.md, which wins over the WI): how a rendered
// `#tag` looks in live preview.
//
// The pack: a tag at rest is `fg2`; a collapsed caret inside it (the end
// edge included: `#work|` counts) makes it `accentSoft`; a range selection
// across it leaves it `fg2`; a Cmd hover makes it `accentSoft` with a solid
// underline. Same size, weight and line as the text around it, no characters
// hidden, no background. The tag ink wins over the line's colour. A bare `#`
// is not a tag. The dashed underline stays the ghost wikilink's alone.
//
// LEAD RULING: the span builder honours `cmdHover` for a tag exactly as it
// does for a wikilink (the tag inside the hover range), because #247 may only
// edit link_region.dart and sets `cmdHover` on the tag's range.
//
// Colours are OmColors tokens. Every test reads the built span the way the
// engine does: the effective style of one code unit is its ancestors' styles
// merged down the tree. Line heights come from a real TextField with the app
// theme (even leading) and the controller strut (repo lesson #223).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/font_fetch_hold.dart';
import '../support/markdown_fixtures.dart';
import '../support/wi159_line_geometry.dart' show wi159EditableIn;

/// The body style the span builder is given (mono 13.5, fg0, height 1.7).
TextStyle _base() => OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);

/// The design pack body line height (13.5 x 1.7).
const double _bodyLine = 22.95;

TextSelection _caret(int offset) => TextSelection.collapsed(offset: offset);

TextSpan _build(
  String text, {
  TextSelection? selection,
  bool forceHidden = false,
  bool itemText = false,
  bool taskDone = false,
  bool quote = false,
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
  isResolved: isResolved,
  cmdHover: cmdHover,
);

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

double _width(InlineSpan span, int start, int end) {
  final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
    ..layout();
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  painter.dispose();
  return boxes.fold(0.0, (sum, b) => sum + (b.right - b.left));
}

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

/// Every code unit of [r] has the colour [colour].
void _expectColour(
  InlineSpan span,
  (int, int) r,
  Color colour, {
  String why = '',
}) {
  for (var i = r.$1; i < r.$2; i++) {
    expect(
      _styleAt(span, i).color,
      colour,
      reason: '$why code unit $i of ${r.$1}..${r.$2}',
    );
  }
}

/// `[r]` is a tag at rest or lit: [colour], the line's [size], regular and
/// upright, undecorated (or underlined when [underlined]), no letter spacing,
/// visible at its normal width.
void _expectTag(
  TextSpan span,
  String text,
  (int, int) r,
  Color colour, {
  bool underlined = false,
  double size = 13.5,
  FontWeight weight = FontWeight.w400,
  FontStyle fontStyle = FontStyle.normal,
  String why = '',
}) {
  final chars = text.substring(r.$1, r.$2);
  for (var i = r.$1; i < r.$2; i++) {
    final s = _styleAt(span, i);
    final at = '$why "$chars" code unit $i';
    expect(s.color, colour, reason: '$at colour');
    expect(s.fontSize, size, reason: '$at size');
    expect(_weight(s), weight, reason: '$at weight');
    expect(_fontStyle(s), fontStyle, reason: '$at font style');
    expect(s.letterSpacing ?? 0, 0, reason: '$at letter spacing');
    expect(s.backgroundColor, isNull, reason: '$at no background');
    expect(
      _has(s, TextDecoration.underline),
      underlined,
      reason: '$at underline',
    );
    if (underlined) {
      // Solid, in the text colour.
      expect(
        s.decorationStyle,
        anyOf(isNull, TextDecorationStyle.solid),
        reason: '$at underline is solid',
      );
      expect(
        s.decorationColor,
        anyOf(isNull, colour),
        reason: '$at underline is in the text colour',
      );
    } else {
      expect(_decorated(s), isFalse, reason: '$at undecorated');
    }
  }
  expect(
    _width(span, r.$1, r.$2),
    closeTo(_normalWidth(chars, size), 0.01),
    reason: '$why "$chars" visible at its normal width',
  );
}

/// A BuildContext for calling `buildTextSpan` directly.
Future<BuildContext> _context(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox(key: Key('wi245-context')));
  return tester.element(find.byKey(const Key('wi245-context')));
}

/// A controller holding [text] with [selection], its reveal gate [focused].
LivePreviewController _controller(
  String text, {
  TextSelection? selection,
  bool focused = true,
  TextRange? cmdHover,
}) {
  final gate = ValueNotifier<bool>(focused);
  final c = LivePreviewController.fromValue(
    TextEditingValue(
      text: text,
      selection: selection ?? const TextSelection.collapsed(offset: -1),
    ),
  )..revealGate = gate;
  if (cmdHover != null) c.cmdHover = cmdHover;
  addTearDown(c.dispose);
  addTearDown(gate.dispose);
  return c;
}

TextSpan _controllerSpan(BuildContext context, LivePreviewController c) =>
    c.buildTextSpan(context: context, style: _base(), withComposing: false);

/// Pumps [c] in a field configured as `TextSegmentField` configures a live
/// preview field: the app theme (its Material 3 text style gives the field
/// even leading), the editor body style and the controller's own strut.
Future<RenderEditable> _pumpEditorField(
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
            key: const Key('wi245-field'),
            controller: c,
            maxLines: null,
            style: editorBodyStyle(),
            strutStyle: c.strutStyle,
          ),
        ),
      ),
    ),
  );
  return wi159EditableIn(tester, find.byKey(const Key('wi245-field')));
}

List<double> _heights(RenderEditable editable) => [
  for (final l in RenderEditableLineBoxes(editable).lines) l.bottom - l.top,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  holdFontFetches();

  group('tag ink at rest and with the caret (AC5)', () {
    test(
      'a tag renders fg2 over exactly its characters with no caret in it',
      () {
        for (final text in [
          'call with Sam about pricing #work until done.',
          '- call with Sam about pricing #work',
          '#work',
          'x #work.',
          '(#work)',
        ]) {
          final tag = _range(text, '#work');
          for (final selection in [null, _caret(0), _caret(text.length)]) {
            if (selection != null &&
                selection.baseOffset >= tag.$1 &&
                selection.baseOffset <= tag.$2) {
              continue;
            }
            final span = _build(text, selection: selection);
            _expectTag(
              span,
              text,
              tag,
              OmColors.fg2,
              why: '"$text" $selection',
            );
            // Only the tag takes the ink: every other code unit is body text.
            for (var i = 0; i < text.length; i++) {
              if (i >= tag.$1 && i < tag.$2) continue;
              expect(
                _styleAt(span, i).color,
                OmColors.fg0,
                reason: '"$text" $selection: code unit $i is not the tag',
              );
            }
          }
        }
      },
    );

    test(
      'a collapsed caret inside a tag turns it accentSoft with both edges included',
      () {
        const text = 'x #work y';
        final tag = _range(text, '#work'); // 2..7
        for (var caret = 0; caret <= text.length; caret++) {
          final inside = caret >= tag.$1 && caret <= tag.$2;
          final span = _build(text, selection: _caret(caret));
          _expectTag(
            span,
            text,
            tag,
            inside ? OmColors.accentSoft : OmColors.fg2,
            why: 'caret $caret',
          );
        }
      },
    );

    test('a caret at the end of a tag followed by nothing is inside it', () {
      // F3.3: the caret at the end of a completed tag; B4 `#p|` cells.
      const text = 'call with Sam #work';
      final span = _build(text, selection: _caret(text.length));
      _expectTag(span, text, _range(text, '#work'), OmColors.accentSoft);
      const short = '#p';
      _expectTag(_build(short, selection: _caret(2)), short, (
        0,
        2,
      ), OmColors.accentSoft);
      _expectTag(_build(short, selection: _caret(1)), short, (
        0,
        2,
      ), OmColors.accentSoft);
    });

    test(
      'a caret in one tag lights that tag only and the next tag across a space stays fg2',
      () {
        const text = '#a #b #c';
        final a = _range(text, '#a'); // 0..2
        final b = _range(text, '#b'); // 3..5
        final c = _range(text, '#c'); // 6..8
        for (final (caret, lit) in [
          (1, [a]),
          (2, [a]),
          (3, [b]),
          (4, [b]),
          (5, [b]),
          (6, [c]),
          (8, [c]),
        ]) {
          final span = _build(text, selection: _caret(caret));
          for (final tag in [a, b, c]) {
            _expectTag(
              span,
              text,
              tag,
              lit.contains(tag) ? OmColors.accentSoft : OmColors.fg2,
              why: 'caret $caret tag $tag',
            );
          }
        }
      },
    );

    test('a range selection across or inside a tag leaves it fg2', () {
      const text = 'x #work y';
      final tag = _range(text, '#work');
      for (final selection in [
        const TextSelection(baseOffset: 0, extentOffset: 9),
        const TextSelection(baseOffset: 2, extentOffset: 7),
        const TextSelection(baseOffset: 3, extentOffset: 5),
        const TextSelection(baseOffset: 2, extentOffset: 3),
        const TextSelection(baseOffset: 6, extentOffset: 7),
        const TextSelection(baseOffset: 7, extentOffset: 2),
        const TextSelection(baseOffset: 5, extentOffset: 9),
        const TextSelection(baseOffset: 0, extentOffset: 3),
      ]) {
        _expectTag(
          _build(text, selection: selection),
          text,
          tag,
          OmColors.fg2,
          why: '$selection',
        );
      }
    });

    test('a missing or invalid selection leaves a tag fg2', () {
      const text = 'x #work y';
      final tag = _range(text, '#work');
      for (final selection in [
        null,
        const TextSelection.collapsed(offset: -1),
        TextSelection.collapsed(offset: -1, affinity: TextAffinity.upstream),
      ]) {
        _expectTag(
          _build(text, selection: selection),
          text,
          tag,
          OmColors.fg2,
          why: '$selection',
        );
      }
    });

    test(
      'a bare hash stays body colour and a tag starts at its first letter',
      () {
        const bare = 'call with Sam #';
        for (final selection in [
          null,
          _caret(bare.length),
          _caret(bare.length - 1),
        ]) {
          _expectColour(
            _build(bare, selection: selection),
            (0, bare.length),
            OmColors.fg0,
            why: 'bare hash $selection',
          );
        }
        const p = 'call with Sam #p';
        _expectTag(_build(p), p, _range(p, '#p'), OmColors.fg2);
        _expectColour(_build(p), (0, 14), OmColors.fg0);
        // Digits first, a dash first and an underscore first are no tag.
        const nonTags = '#1 and #_a and #-a and a#b and (a)#c';
        _expectColour(
          _build(nonTags, selection: _caret(1)),
          (0, nonTags.length),
          OmColors.fg0,
          why: 'non tags',
        );
        // The premise: the same words with a real tag add the ink.
        const withTag = '#1 and #t';
        _expectTag(
          _build(withTag),
          withTag,
          _range(withTag, '#t'),
          OmColors.fg2,
        );
      },
    );

    test(
      'a tag ends before trailing punctuation and trailing dashes and underscores stay body colour',
      () {
        const text = 'see #work. then #plan- and #my_tag_ done';
        final span = _build(text);
        _expectTag(span, text, _range(text, '#work'), OmColors.fg2);
        _expectTag(span, text, _range(text, '#plan'), OmColors.fg2);
        _expectTag(span, text, _range(text, '#my_tag'), OmColors.fg2);
        final dot = text.indexOf('.');
        final dash = text.indexOf('-');
        final underscore = text.lastIndexOf('_');
        for (final at in [dot, dash, underscore]) {
          expect(_styleAt(span, at).color, OmColors.fg0, reason: 'unit $at');
        }
        // A caret right after the trailing dash is past the tag.
        final past = _build(text, selection: _caret(dash + 1));
        _expectTag(past, text, _range(text, '#plan'), OmColors.fg2);
        // A caret right before it is the tag's end edge.
        final edge = _build(text, selection: _caret(dash));
        _expectTag(edge, text, _range(text, '#plan'), OmColors.accentSoft);
      },
    );

    test('a tag is not lit by a caret while the field is not focused', () {
      // `forceHidden` is the unfocused field: its markers hide, and a caret
      // left in it from before must not light a tag either.
      const text = '#work and more';
      for (final caret in [0, 3, 5]) {
        _expectTag(
          _build(text, selection: _caret(caret), forceHidden: true),
          text,
          (0, 5),
          OmColors.fg2,
          why: 'unfocused caret $caret',
        );
      }
      _expectTag(
        _build(text, selection: _caret(3)),
        text,
        (0, 5),
        OmColors.accentSoft,
        why: 'focused control',
      );
    });

    testWidgets(
      'the controller lights a tag from its own caret while its reveal gate is true',
      (tester) async {
        final context = await _context(tester);
        const text = 'call with Sam #work now';
        final tag = _range(text, '#work');
        for (final (caret, focused, colour) in [
          (0, true, OmColors.fg2),
          (14, true, OmColors.accentSoft),
          (16, true, OmColors.accentSoft),
          (19, true, OmColors.accentSoft),
          (20, true, OmColors.fg2),
          (13, true, OmColors.fg2),
          (16, false, OmColors.fg2),
        ]) {
          final c = _controller(
            text,
            selection: _caret(caret),
            focused: focused,
          );
          _expectTag(
            _controllerSpan(context, c),
            text,
            tag,
            colour,
            why: 'caret $caret focused $focused',
          );
        }
      },
    );

    testWidgets(
      'a pumped live preview field renders the tag fg2 and accentSoft with the caret inside',
      (tester) async {
        const text = 'call with Sam #work now';
        final tag = _range(text, '#work');
        final c = _controller(text, selection: _caret(0));
        final editable = await _pumpEditorField(tester, c);
        TextSpan span() => editable.text! as TextSpan;
        expect(span().toPlainText(), text);
        _expectColour(span(), tag, OmColors.fg2, why: 'caret elsewhere');
        _expectColour(span(), (0, 14), editorBodyStyle().color!);

        c.selection = _caret(16);
        await tester.pump();
        _expectColour(span(), tag, OmColors.accentSoft, why: 'caret inside');

        c.selection = _caret(19);
        await tester.pump();
        _expectColour(
          span(),
          tag,
          OmColors.accentSoft,
          why: 'caret at the end',
        );

        c.selection = _caret(20);
        await tester.pump();
        _expectColour(span(), tag, OmColors.fg2, why: 'caret one past the end');

        c.selection = const TextSelection(baseOffset: 10, extentOffset: 20);
        await tester.pump();
        _expectColour(span(), tag, OmColors.fg2, why: 'range across the tag');
      },
    );
  });

  group('Cmd hover (lead ruling on D19)', () {
    test(
      'a Cmd hover over exactly a tag gives accentSoft with a solid underline',
      () {
        const text = 'x #work y';
        final tag = _range(text, '#work');
        final span = _build(
          text,
          cmdHover: TextRange(start: tag.$1, end: tag.$2),
        );
        _expectTag(span, text, tag, OmColors.accentSoft, underlined: true);
        // Nothing around it is underlined or recoloured.
        for (final at in [0, 1, 7, 8]) {
          final s = _styleAt(span, at);
          expect(s.color, OmColors.fg0, reason: 'unit $at');
          expect(_decorated(s), isFalse, reason: 'unit $at');
        }
      },
    );

    test(
      'a hover range that encloses the tag hovers it and one that cuts it does not',
      () {
        const text = 'x #work y';
        final tag = _range(text, '#work'); // 2..7
        for (final (start, end, hovered) in [
          (2, 7, true),
          (0, 9, true),
          (1, 7, true),
          (2, 8, true),
          (3, 7, false),
          (2, 6, false),
          (3, 6, false),
          (0, 2, false),
          (7, 9, false),
          (0, 0, false),
          (4, 4, false),
        ]) {
          _expectTag(
            _build(
              text,
              cmdHover: TextRange(start: start, end: end),
            ),
            text,
            tag,
            hovered ? OmColors.accentSoft : OmColors.fg2,
            underlined: hovered,
            why: 'hover $start..$end',
          );
        }
      },
    );

    test('a hover over one tag leaves the other tags at rest', () {
      const text = '#a #b #c';
      final a = _range(text, '#a');
      final b = _range(text, '#b');
      final c = _range(text, '#c');
      final span = _build(
        text,
        cmdHover: TextRange(start: b.$1, end: b.$2),
      );
      _expectTag(span, text, a, OmColors.fg2);
      _expectTag(span, text, b, OmColors.accentSoft, underlined: true);
      _expectTag(span, text, c, OmColors.fg2);
    });

    test(
      'a hovered tag with the caret inside is accentSoft and underlined only because of the hover',
      () {
        const text = 'x #work y';
        final tag = _range(text, '#work');
        _expectTag(
          _build(
            text,
            selection: _caret(4),
            cmdHover: TextRange(start: tag.$1, end: tag.$2),
          ),
          text,
          tag,
          OmColors.accentSoft,
          underlined: true,
        );
        _expectTag(
          _build(text, selection: _caret(4)),
          text,
          tag,
          OmColors.accentSoft,
        );
      },
    );

    test(
      'a hover is not gated by the reveal gate so a read only card tag can hover',
      () {
        const text = 'x #work y';
        final tag = _range(text, '#work');
        _expectTag(
          _build(
            text,
            forceHidden: true,
            cmdHover: TextRange(start: tag.$1, end: tag.$2),
          ),
          text,
          tag,
          OmColors.accentSoft,
          underlined: true,
        );
      },
    );

    test(
      'a hover over a wikilink does not hover the tag next to it and the reverse',
      () {
        const text = 'read [[Pricing]] and #pricing';
        final link = _range(text, '[[Pricing]]');
        final tag = _range(text, '#pricing');
        final over = _build(
          text,
          cmdHover: TextRange(start: link.$1, end: link.$2),
        );
        _expectTag(over, text, tag, OmColors.fg2);
        final linkText = _range(text, 'Pricing');
        for (var i = linkText.$1; i < linkText.$2; i++) {
          expect(_has(_styleAt(over, i), TextDecoration.underline), isTrue);
        }
        final tagOver = _build(
          text,
          cmdHover: TextRange(start: tag.$1, end: tag.$2),
        );
        _expectTag(tagOver, text, tag, OmColors.accentSoft, underlined: true);
        for (var i = linkText.$1; i < linkText.$2; i++) {
          final s = _styleAt(tagOver, i);
          expect(s.color, OmColors.accent, reason: 'wikilink stays accent');
          expect(_has(s, TextDecoration.underline), isFalse);
        }
      },
    );

    testWidgets('the controller relays cmdHover to a tag', (tester) async {
      final context = await _context(tester);
      const text = 'x #work y';
      final tag = _range(text, '#work');
      final c = _controller(text, selection: _caret(0));
      _expectTag(_controllerSpan(context, c), text, tag, OmColors.fg2);
      c.cmdHover = TextRange(start: tag.$1, end: tag.$2);
      _expectTag(
        _controllerSpan(context, c),
        text,
        tag,
        OmColors.accentSoft,
        underlined: true,
      );
      c.cmdHover = null;
      _expectTag(_controllerSpan(context, c), text, tag, OmColors.fg2);
    });
  });

  group('tag ink against the other inks (AC5, AC4)', () {
    test(
      'a tag in a heading stays fg2 in the heading size and weight while the heading words keep their colour',
      () {
        const h1 = '# Title #x';
        final span1 = _build(h1);
        _expectTag(
          span1,
          h1,
          _range(h1, '#x'),
          OmColors.fg2,
          size: 26,
          weight: FontWeight.w700,
        );
        _expectColour(span1, _range(h1, 'Title'), OmColors.heading1);

        const h2 = '## Renewal call #work';
        final span2 = _build(h2);
        _expectTag(
          span2,
          h2,
          _range(h2, '#work'),
          OmColors.fg2,
          size: 19,
          weight: FontWeight.w700,
        );
        _expectColour(span2, _range(h2, 'Renewal'), OmColors.fg0);

        const h4 = '#### Small #x';
        _expectTag(
          _build(h4),
          h4,
          _range(h4, '#x'),
          OmColors.fg2,
          size: 11,
          weight: FontWeight.w500,
        );
        // The caret in the tag lights it in the heading's size too.
        _expectTag(
          _build(h2, selection: _caret(h2.length)),
          h2,
          _range(h2, '#work'),
          OmColors.accentSoft,
          size: 19,
          weight: FontWeight.w700,
        );
        // A heading with a caret on it reveals its marker; the tag is unchanged.
        final revealed = _build(h1, selection: _caret(1));
        _expectTag(
          revealed,
          h1,
          _range(h1, '#x'),
          OmColors.fg2,
          size: 26,
          weight: FontWeight.w700,
        );
        // `## ` heading marker hashes are not tags.
        _expectColour(revealed, (0, 1), OmColors.fg2, why: 'revealed marker');
      },
    );

    test(
      'a tag keeps bold italic and strike from the emphasis around it and wins the colour',
      () {
        // A `*` is no opener, so `*#x*` holds no tag: emphasis only.
        const starred = '*#x* more';
        _expectColour(_build(starred), (0, 4), OmColors.fg0);
        _expectColour(_build(starred, selection: _caret(2)), (
          1,
          3,
        ), OmColors.fg0);
        const bold = '**a #x** more';
        _expectTag(
          _build(bold),
          bold,
          _range(bold, '#x'),
          OmColors.fg2,
          weight: FontWeight.w700,
        );
        const italic = '*a #x* more';
        _expectTag(
          _build(italic),
          italic,
          _range(italic, '#x'),
          OmColors.fg2,
          fontStyle: FontStyle.italic,
        );
        _expectTag(
          _build(italic, selection: _caret(4)),
          italic,
          _range(italic, '#x'),
          OmColors.accentSoft,
          fontStyle: FontStyle.italic,
        );
        const strike = '~~a #x~~ more';
        final tag = _range(strike, '#x');
        final span = _build(strike);
        for (var i = tag.$1; i < tag.$2; i++) {
          final s = _styleAt(span, i);
          expect(s.color, OmColors.fg2);
          expect(
            _has(s, TextDecoration.lineThrough),
            isTrue,
            reason: 'unit $i',
          );
        }
        // The caret in a strike tag lights it and keeps the strike.
        final lit = _build(strike, selection: _caret(tag.$1 + 1));
        for (var i = tag.$1; i < tag.$2; i++) {
          final s = _styleAt(lit, i);
          expect(s.color, OmColors.accentSoft, reason: 'unit $i');
          expect(
            _has(s, TextDecoration.lineThrough),
            isTrue,
            reason: 'unit $i',
          );
        }
      },
    );

    test(
      'a tag in a quote row stays italic and a tag in a done task stays struck, both in fg2',
      () {
        const quoted = 'an idea #idea';
        final quote = _build(quoted, quote: true);
        _expectTag(
          quote,
          quoted,
          _range(quoted, '#idea'),
          OmColors.fg2,
          fontStyle: FontStyle.italic,
        );
        _expectColour(quote, _range(quoted, 'an idea'), OmColors.fg1);

        const done = 'call Sam #work';
        final span = _build(done, itemText: true, taskDone: true);
        final tag = _range(done, '#work');
        for (var i = tag.$1; i < tag.$2; i++) {
          final s = _styleAt(span, i);
          expect(s.color, OmColors.fg2, reason: 'unit $i');
          expect(
            _has(s, TextDecoration.lineThrough),
            isTrue,
            reason: 'unit $i',
          );
        }
        // Selected done text turns fg1; the tag does not.
        final selected = _build(
          done,
          itemText: true,
          taskDone: true,
          selection: const TextSelection(baseOffset: 0, extentOffset: 14),
        );
        _expectColour(selected, _range(done, 'call Sam'), OmColors.fg1);
        _expectColour(selected, tag, OmColors.fg2);
      },
    );

    test(
      'a tag beside a wikilink a ghost wikilink and a bare URL keeps its own ink',
      () {
        const resolved = 'read [[Pricing]] and #pricing';
        final span = _build(resolved);
        _expectColour(span, _range(resolved, 'Pricing'), OmColors.accent);
        _expectTag(span, resolved, _range(resolved, '#pricing'), OmColors.fg2);

        const ghost = 'ask about [[Annual tier]]  #memex';
        final ghostSpan = _build(ghost, isResolved: (_) => false);
        final ghostText = _range(ghost, 'Annual tier');
        for (var i = ghostText.$1; i < ghostText.$2; i++) {
          final s = _styleAt(ghostSpan, i);
          expect(s.color, OmColors.fg2, reason: 'ghost text');
          expect(s.decorationStyle, TextDecorationStyle.dashed);
        }
        // The same fg2, told apart by the ghost's dashed underline: the tag
        // has none.
        _expectTag(ghostSpan, ghost, _range(ghost, '#memex'), OmColors.fg2);

        const url = 'compare with stripe.com/pricing #reading';
        final urlSpan = _build(url);
        _expectTag(urlSpan, url, _range(url, '#reading'), OmColors.fg2);
        _expectColour(urlSpan, (0, url.indexOf('#reading')), OmColors.fg0);
      },
    );

    test(
      'a hash inside a code span a URL a wikilink target or a word is no tag while a real tag next to them is',
      () {
        const issue =
            'fixes issue #1 and colour `#fff` on example.com/docs#setup #real';
        final span = _build(issue);
        _expectColour(span, _range(issue, '#1'), OmColors.fg0);
        _expectColour(span, _range(issue, '#fff'), OmColors.fg1);
        _expectColour(span, _range(issue, '#setup'), OmColors.fg0);
        _expectTag(span, issue, _range(issue, '#real'), OmColors.fg2);
        // A caret in the code span or the URL lights nothing.
        for (final caret in [
          _range(issue, '#fff').$1 + 1,
          issue.indexOf('#setup') + 2,
        ]) {
          final lit = _build(issue, selection: _caret(caret));
          _expectColour(lit, _range(issue, '#fff'), OmColors.fg1);
          _expectColour(lit, _range(issue, '#setup'), OmColors.fg0);
        }

        const wiki = 'see [[Pricing#Annual]] and a mid-word c#sharp #t';
        final wikiSpan = _build(wiki);
        _expectColour(
          wikiSpan,
          _range(wiki, 'Pricing#Annual'),
          OmColors.accent,
        );
        _expectColour(wikiSpan, _range(wiki, 'c#sharp'), OmColors.fg0);
        _expectTag(wikiSpan, wiki, _range(wiki, '#t'), OmColors.fg2);

        const link = '[see #x](https://example.com) and #y';
        final linkSpan = _build(link);
        _expectColour(linkSpan, _range(link, 'see #x'), OmColors.info);
        _expectTag(linkSpan, link, _range(link, '#y'), OmColors.fg2);
      },
    );

    test(
      'a tag on a fenced line gets no tag ink while the tags around the fence do',
      () {
        const text = '#a\n```\n#x\n```\n#b';
        final x = _range(text, '#x');
        final a = _range(text, '#a');
        final b = _range(text, '#b');
        for (final caret in [null, x.$1 + 1, x.$2, a.$2, b.$2]) {
          final span = _build(
            text,
            selection: caret == null ? null : _caret(caret),
          );
          _expectColour(
            span,
            x,
            OmColors.fg1,
            why: 'fenced line, caret $caret',
          );
          final lit = <int?, (int, int)>{a.$2: a, b.$2: b}[caret];
          _expectTag(
            span,
            text,
            a,
            lit == a ? OmColors.accentSoft : OmColors.fg2,
            why: 'before the fence, caret $caret',
          );
          _expectTag(
            span,
            text,
            b,
            lit == b ? OmColors.accentSoft : OmColors.fg2,
            why: 'after the fence, caret $caret',
          );
        }
        // An unclosed fence runs to the end: its tags are code too.
        const open = '#a\n```\n#x\n#y';
        final openSpan = _build(open);
        _expectTag(openSpan, open, _range(open, '#a'), OmColors.fg2);
        _expectColour(openSpan, _range(open, '#x'), OmColors.fg1);
        _expectColour(openSpan, _range(open, '#y'), OmColors.fg1);
      },
    );

    test('a tag in a table cell renders fg2', () {
      const table = '| item | note |\n|---|---|\n| a | #t |';
      _expectTag(_build(table), table, _range(table, '#t'), OmColors.fg2);
    });
  });

  group('excerpt card (AC6)', () {
    Future<TextSpan> pumpRow(WidgetTester tester, String text, int row) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildOmTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 600, child: CardRows(text: text)),
            ),
          ),
        ),
      );
      final rich = find.descendant(
        of: find.byKey(Key('card-row-text-$row')),
        matching: find.byType(RichText),
      );
      return tester.widget<RichText>(rich).text as TextSpan;
    }

    testWidgets(
      'a tag in an excerpt card renders with the same fg2 style as in the editor',
      (tester) async {
        const body = 'Pricing call #work then #memex.';
        final span = await pumpRow(tester, body, 0);
        expect(span.toPlainText(), body);
        final base = _styleAt(span, 0);
        expect(base.color, OmColors.fg1, reason: 'card body is fg1');
        for (final tag in [_range(body, '#work'), _range(body, '#memex')]) {
          _expectTag(span, body, tag, OmColors.fg2);
        }
        for (final at in [0, 12, 18, 23, body.length - 1]) {
          expect(_styleAt(span, at).color, OmColors.fg1, reason: 'unit $at');
        }
      },
    );

    testWidgets('a tag in a card bullet and quote row renders fg2', (
      tester,
    ) async {
      const text = '- renewal maths #memex\n> an idea #idea';
      final bullet = await pumpRow(tester, text, 0);
      const bulletText = 'renewal maths #memex';
      expect(bullet.toPlainText(), bulletText);
      _expectTag(
        bullet,
        bulletText,
        _range(bulletText, '#memex'),
        OmColors.fg2,
      );
      final quote = await pumpRow(tester, text, 1);
      const quoteText = 'an idea #idea';
      expect(quote.toPlainText(), quoteText);
      _expectTag(
        quote,
        quoteText,
        _range(quoteText, '#idea'),
        OmColors.fg2,
        fontStyle: FontStyle.italic,
      );
    });
  });

  group('line height and offsets (AC7, AC8)', () {
    testWidgets(
      'a line with a tag has the same line height as a plain body line in a field with even leading and the controller strut',
      (tester) async {
        const plain = 'Plain body line\n- plain bullet text\nsecond line';
        const tagged = 'Tagged #work line\n- plain bullet #work\nsecond #more';
        final reference = await _pumpEditorField(tester, _controller(plain));
        final refLines = RenderEditableLineBoxes(reference).lines;
        expect(refLines, hasLength(3));
        expect(
          (reference.text! as TextSpan).style?.leadingDistribution,
          TextLeadingDistribution.even,
          reason: 'the field has even leading',
        );

        for (final caret in [null, 9, 20, tagged.length]) {
          final why = 'caret $caret';
          final c = _controller(
            tagged,
            selection: caret == null ? null : _caret(caret),
          );
          final editable = await _pumpEditorField(tester, c);
          // The premise: the tag really is styled, in this field.
          final span = editable.text! as TextSpan;
          expect(
            _styleAt(span, tagged.indexOf('#work')).color,
            anyOf(OmColors.fg2, OmColors.accentSoft),
            reason: '$why: the tag has its ink',
          );
          final lines = RenderEditableLineBoxes(editable).lines;
          expect(lines, hasLength(3), reason: '$why: three lines');
          for (final (i, line) in lines.indexed) {
            expect(
              line.bottom - line.top,
              closeTo(_bodyLine, 0.05),
              reason: '$why: line $i is a body line of ${_heights(editable)}',
            );
            expect(
              line.top,
              closeTo(refLines[i].top, 0.05),
              reason: '$why: top $i',
            );
            expect(
              line.bottom,
              closeTo(refLines[i].bottom, 0.05),
              reason: '$why: bottom $i',
            );
          }
        }
      },
    );

    testWidgets(
      'a heading line with a tag has the same height as the heading line without it',
      (tester) async {
        for (final level in [1, 2, 3, 4]) {
          final marks = '#' * level;
          final plainField = await _pumpEditorField(
            tester,
            _controller('$marks Renewal call\nbody'),
          );
          final plainHeights = _heights(plainField);
          final taggedC = _controller('$marks Renewal call #work\nbody');
          final taggedField = await _pumpEditorField(tester, taggedC);
          final span = taggedField.text! as TextSpan;
          final at = taggedC.text.indexOf('#work');
          expect(
            _styleAt(span, at).color,
            OmColors.fg2,
            reason: 'H$level premise',
          );
          expect(
            _styleAt(span, at).fontSize,
            headingFontSize(level),
            reason: 'H$level tag takes the heading size',
          );
          final heights = _heights(taggedField);
          expect(heights, hasLength(plainHeights.length));
          for (final (i, h) in heights.indexed) {
            expect(
              h,
              closeTo(plainHeights[i], 0.05),
              reason: 'H$level line $i',
            );
          }
          expect(
            heights.last,
            closeTo(_bodyLine, 0.05),
            reason: 'H$level: the body line after it',
          );
        }
      },
    );

    testWidgets(
      'character offsets and hit positions in a tagged line match the plain line',
      (tester) async {
        // Same length, same characters but the tag's hash: a plain twin.
        const tagged = 'call with Sam #work now\nand #more #x';
        const plain = 'call with Sam xwork now\nand xmore #1';
        final plainC = _controller(plain);
        final plainField = await _pumpEditorField(tester, plainC);
        final plainCarets = <Rect>[
          for (var i = 0; i <= plain.length; i++)
            plainField.getLocalRectForCaret(TextPosition(offset: i)),
        ];
        final plainBoxes = [
          for (var i = 0; i < plain.length; i++)
            plainField
                .getBoxesForSelection(
                  TextSelection(baseOffset: i, extentOffset: i + 1),
                )
                .map((b) => b.toRect())
                .toList(),
        ];

        for (final caret in [null, 0, 16, 19, 25, tagged.length]) {
          final c = _controller(
            tagged,
            selection: caret == null ? null : _caret(caret),
          );
          final editable = await _pumpEditorField(tester, c);
          final why = 'caret $caret';
          // The premise: the tag is styled.
          expect(
            _styleAt(editable.text! as TextSpan, tagged.indexOf('#work')).color,
            anyOf(OmColors.fg2, OmColors.accentSoft),
            reason: '$why: the tag has its ink',
          );
          // Text and selection are what was set.
          expect(c.text, tagged, reason: why);
          expect(
            (editable.text! as TextSpan).toPlainText(),
            tagged,
            reason: '$why: the span reads back as the text',
          );
          if (caret != null) expect(c.selection, _caret(caret));
          for (var i = 0; i <= tagged.length; i++) {
            final rect = editable.getLocalRectForCaret(TextPosition(offset: i));
            expect(
              rect.left,
              closeTo(plainCarets[i].left, 0.01),
              reason: '$why caret $i x',
            );
            expect(
              rect.top,
              closeTo(plainCarets[i].top, 0.01),
              reason: '$why caret $i y',
            );
            expect(
              rect.height,
              closeTo(plainCarets[i].height, 0.01),
              reason: '$why caret $i height',
            );
          }
          for (var i = 0; i < tagged.length; i++) {
            final boxes = editable
                .getBoxesForSelection(
                  TextSelection(baseOffset: i, extentOffset: i + 1),
                )
                .map((b) => b.toRect())
                .toList();
            expect(
              boxes,
              hasLength(plainBoxes[i].length),
              reason: '$why box $i',
            );
            for (final (k, box) in boxes.indexed) {
              expect(
                box.left,
                closeTo(plainBoxes[i][k].left, 0.01),
                reason: '$why box $i',
              );
              expect(
                box.width,
                closeTo(plainBoxes[i][k].width, 0.01),
                reason: '$why box $i',
              );
            }
            // A hit in the left quarter of a character is that character.
            final box = boxes.first;
            if (tagged.codeUnitAt(i) == 0x0A) continue;
            final hit = editable.getPositionForPoint(
              editable.localToGlobal(
                Offset(box.left + box.width * 0.25, box.center.dy),
              ),
            );
            expect(hit.offset, i, reason: '$why: a hit on character $i');
          }
        }
      },
    );

    test(
      'the span of a tagged text reads back as the text for every caret position and every fixture',
      () {
        final texts = <String>[
          '#work',
          'x #work y #more.',
          '- call with Sam about pricing #work',
          '## Renewal call #work',
          '*#x* **#y** ~~#z~~ _#my_tag_',
          'read [[Pricing]] and #pricing `#c` [a #b](u) #d',
          '#\u{20000}x \u{1F600} #\u{1D7D8}',
          '#a\n```\n#x\n```\n#b',
          'first #a\r\n#b\r\n',
          ...markdownFixtures.values,
        ];
        var tagged = 0;
        for (final text in texts) {
          // Every caret position of a short text; a long fixture takes the
          // two ends and the middle.
          final carets = text.length <= 80
              ? [for (var i = 0; i <= text.length; i++) i]
              : [0, text.length ~/ 2, text.length];
          for (final caret in carets) {
            final span = _build(text, selection: _caret(caret));
            expect(span.toPlainText(), text, reason: 'caret $caret in "$text"');
          }
          if (text.contains('#work')) {
            final tag = _range(text, '#work');
            _expectColour(_build(text), tag, OmColors.fg2, why: text);
            tagged++;
          }
          final range = _build(
            text,
            selection: TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          expect(range.toPlainText(), text);
        }
        expect(tagged, 4);
      },
    );
  });
}
