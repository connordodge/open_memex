// WI #224 (Spec #222 under #221; ACs 1-5): editor body text is fg1 (#D6D3CC),
// not fg0. Every surface that lays text out with `editorBodyStyle()` follows:
// segmented prose rows, the Source surface field and the table grid's cell
// text. Plain bold and italic inherit the colour; size 13.5, weight w400,
// height 1.7 and the JetBrains Mono face stay as they were.
//
// Colours are read from what each field or cell lays out (its span, every
// ancestor's style merged down to the leaf), never from the style function
// alone, so a surface that stopped using the shared style would fail.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/table_harness.dart';

const _prose = 'Plain body text here';
const _marked = 'plain **bold** and *italic* words';
const _outside = 'Other line';

const _table =
    '| Head | Other |\n'
    '|:--|--:|\n'
    '| Cell | Value |';

/// The effective style of the code unit at [offset] of [root]: every
/// ancestor's style merged down to the leaf holding it.
TextStyle _styleAt(InlineSpan root, int offset) {
  var at = 0;
  TextStyle? found;
  bool visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (offset >= at && offset < at + text.length) {
        found = style;
        return false;
      }
      at += text.length;
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (!visit(child, style)) return false;
      }
    }
    return true;
  }

  visit(root, const TextStyle());
  return found ?? (throw TestFailure('no span holds offset $offset'));
}

int? _argb(Color? c) => c?.toARGB32();

/// Every code unit offset of [text]'s first occurrence in [full].
Iterable<int> _range(String full, String text) {
  final i = full.indexOf(text);
  if (i < 0) throw ArgumentError('$text is not in $full');
  return [for (var k = i; k < i + text.length; k++) k];
}

void _expectFg1(InlineSpan span, String full, String text, String what) {
  for (final at in _range(full, text)) {
    expect(
      _argb(_styleAt(span, at).color),
      OmColors.fg1.toARGB32(),
      reason: '$what "${full[at]}" (offset $at) renders in fg1',
    );
  }
}

/// The span editor row [r] of segment 0 lays out.
InlineSpan _rowSpan(WidgetTester tester, int r) =>
    tableRowFieldState(tester, 0, r).renderEditable.text!;

/// The span the rendered grid's cell ([row], [col]) of table row [r] shows.
InlineSpan _cellSpan(WidgetTester tester, int r, int row, int col) => tester
    .widget<RichText>(
      find.descendant(
        of: tableCell(0, r, row, col),
        matching: find.byType(RichText),
        matchRoot: true,
      ),
    )
    .text;

void main() {
  holdFontFetches();

  group('editorBodyStyle (AC1)', () {
    test('editorBodyStyle colour is fg1', () {
      expect(
        editorBodyStyle().color?.toARGB32(),
        OmColors.fg1.toARGB32(),
        reason: 'body text is fg1 (#D6D3CC), not fg0',
      );
    });

    test(
      'editorBodyStyle keeps size 13.5 weight w400 height 1.7 and the mono face',
      () {
        final style = editorBodyStyle();
        expect(style.fontSize, 13.5);
        expect(style.fontWeight, FontWeight.w400);
        expect(style.height, 1.7);
        expect(style.fontFamily, OmType.mono().fontFamily);
      },
    );
  });

  group('segmented editor (AC2, AC5)', () {
    testWidgets('a segmented prose row lays plain body text out in fg1', (
      tester,
    ) async {
      final body = await pumpTable(tester, '$_prose\n$_outside');
      await body.placeCaret(_prose.length + 1);
      final span = _rowSpan(tester, 0);
      expect(span.toPlainText(), startsWith(_prose));
      _expectFg1(span, _prose, _prose, 'prose');
      expect(_styleAt(span, 0).fontWeight, FontWeight.w400);
      expect(_styleAt(span, 0).fontSize, 13.5);
    }, variant: macOnly);

    testWidgets(
      'plain bold and italic body text in a segmented row inherit fg1',
      (tester) async {
        final body = await pumpTable(tester, '$_marked\n$_outside');
        await body.placeCaret(_marked.length + 1);
        final span = _rowSpan(tester, 0);
        expect(span.toPlainText(), startsWith(_marked));

        _expectFg1(span, _marked, 'bold', 'bold word');
        expect(
          _styleAt(span, _marked.indexOf('bold')).fontWeight,
          FontWeight.w700,
          reason: 'fixture: the word is bold',
        );
        _expectFg1(span, _marked, 'italic', 'italic word');
        expect(
          _styleAt(span, _marked.indexOf('italic')).fontStyle,
          FontStyle.italic,
          reason: 'fixture: the word is italic',
        );
        _expectFg1(span, _marked, 'plain ', 'plain text before the markup');
        _expectFg1(span, _marked, ' words', 'plain text after the markup');
      },
      variant: macOnly,
    );

    testWidgets(
      'bold and italic body text stay fg1 while the caret is inside them',
      (tester) async {
        final body = await pumpTable(tester, '$_marked\n$_outside');
        await body.placeCaret(_marked.indexOf('bold') + 1);
        final span = _rowSpan(tester, 0);
        _expectFg1(span, _marked, 'bold', 'revealed bold word');
        _expectFg1(span, _marked, 'italic', 'italic word');
      },
      variant: macOnly,
    );
  });

  group('Source surface (AC3)', () {
    testWidgets('the Source surface field lays body text out in fg1', (
      tester,
    ) async {
      const body = 'Source body line\nsecond **bold** line';
      final r = await launchSegmented(
        tester,
        vault: seedSegmentedVault(topicBody: body),
      );
      await r.open(fixtureTopicId);
      await r.toggleSource();
      expect(r.sourceSurface, findsOneWidget);
      final state = tester.state<EditableTextState>(
        find.descendant(
          of: r.sourceBody,
          matching: find.byType(EditableText),
          matchRoot: true,
        ),
      );
      final span = state.renderEditable.text!;
      expect(span.toPlainText(), body);
      _expectFg1(span, body, 'Source body line', 'source text');
      _expectFg1(span, body, 'second ', 'source text');
    }, variant: macOnly);
  });

  group('table grid (AC4)', () {
    testWidgets(
      'a rendered table grid shows header cells in fg1 w700 and body cells in fg1',
      (tester) async {
        await pumpTable(tester, '$_outside\n$_table');
        expectTableRendered(0, 1);

        for (final (col, text) in [(0, 'Head'), (1, 'Other')]) {
          final span = _cellSpan(tester, 1, 0, col);
          expect(span.toPlainText(), text);
          _expectFg1(span, text, text, 'header cell');
          expect(
            _styleAt(span, 0).fontWeight,
            FontWeight.w700,
            reason: 'header cell "$text" stays bold',
          );
        }
        for (final (col, text) in [(0, 'Cell'), (1, 'Value')]) {
          final span = _cellSpan(tester, 1, 1, col);
          expect(span.toPlainText(), text);
          _expectFg1(span, text, text, 'body cell');
          expect(
            _styleAt(span, 0).fontWeight,
            isNot(FontWeight.w700),
            reason: 'body cell "$text" is not bold',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a revealed table field shows header and body cell text in fg1 with the header w700',
      (tester) async {
        final body = await pumpTable(tester, '$_outside\n$_table');
        await body.placeCaret(_outside.length + 1 + _table.indexOf('Cell'));
        expectTableRevealed(0, 1);
        final span = _rowSpan(tester, 1);
        final text = tableRowController(tester, 0, 1).text;
        expect(text, _table);
        _expectFg1(span, text, 'Head', 'revealed header cell');
        expect(
          _styleAt(span, text.indexOf('Head')).fontWeight,
          FontWeight.w700,
        );
        _expectFg1(span, text, 'Cell', 'revealed body cell');
        _expectFg1(span, text, 'Value', 'revealed body cell');
      },
      variant: macOnly,
    );
  });
}
