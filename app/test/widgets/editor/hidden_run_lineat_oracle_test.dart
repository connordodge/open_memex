// Spec #122 Req "line geometry matches the oracle" (WI #126 AC1), fix PR:
// RenderParagraphLineBoxes.lineAt on a source line that wraps after the
// space right before a run of hidden (zero-width) markers. On main, at
// offset 12 of the text below in a 160 px box, the whole-text measurement
// (LineBoxOracle) gives the line (12, 24) while lineAt gave (12, 26): the
// wrapped line above swallowed the hidden run's own line (24, 26). Line
// ranges must partition the text, and each must be the oracle's, at every
// offset: lines above, inside and after the run.
import 'package:flutter/material.dart';
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
const _text = _visible + _hidden + _tail;

/// Where the hidden run starts.
const _runStart = 24;
const _runEnd = _runStart + _hidden.length;

/// Pumps the paragraph in a [width] px box under its own [key] (a new key
/// is a fresh render object, so a fresh line cache), and returns it.
Future<RenderParagraph> _pump(
  WidgetTester tester,
  double width,
  String key,
) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: LineBoxEpoch(
            child: RichText(
              key: Key(key),
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
  final paragraph = tester.renderObject<RenderParagraph>(find.byKey(Key(key)));
  expect(paragraph.text.toPlainText(), _text);
  return paragraph;
}

/// Whether [oracle]'s layout wraps right before the hidden run: the run
/// opens a line, and the line holding the space before it ends there.
bool _wrapsBeforeRun(LineBoxOracle oracle) =>
    oracle.lineAt(_runStart).range.start == _runStart &&
    oracle.lineAt(_runStart - 1).range.end == _runStart;

/// Whether [line] holds nothing but hidden markers.
bool _hiddenOnly(LineBox line) =>
    line.range.start >= _runStart && line.range.end <= _runEnd;

String _show(LineBox l) =>
    '(${l.range.start}, ${l.range.end}) top ${l.top} bottom ${l.bottom} '
    'baseline ${l.baseline}';

/// Compares lineAt with [oracle] at every offset of the text (and one past
/// each end, which clamps), querying in [order] on a fresh line cache, and
/// checks that the distinct lines it gives partition the text.
void _expectMatchesOracle(
  RenderParagraph paragraph,
  LineBoxOracle oracle,
  List<int> order,
  String where,
) {
  final source = RenderParagraphLineBoxes(paragraph);
  final got = <int, LineBox>{};
  for (final offset in order) {
    final line = source.lineAt(offset);
    final want = oracle.lineAt(offset);
    final reason =
        'lineAt($offset) $where: got ${_show(line)}, '
        'oracle ${_show(want)}';
    expect(
      (line.range.start, line.range.end, line.top, line.bottom),
      (want.range.start, want.range.end, want.top, want.bottom),
      reason: reason,
    );
    // Baselines of a line holding nothing but hidden markers are left out
    // of the equality by the class docs.
    if (!_hiddenOnly(want)) {
      expect(line.baseline, want.baseline, reason: reason);
    }
    got[offset] = line;
  }

  // Every in-text offset lies inside the line lineAt gives for it.
  for (var offset = 0; offset <= _text.length; offset++) {
    final r = got[offset]!.range;
    expect(
      r.start <= offset && offset <= r.end,
      isTrue,
      reason: 'lineAt($offset) $where gave (${r.start}, ${r.end})',
    );
  }

  // The distinct ranges partition the text: they start at 0, end at its
  // end, and each starts where the one above ends (after its line break,
  // if it has one), so no two overlap and none leaves a gap.
  final ranges = <(int, int)>{
    for (var offset = 0; offset <= _text.length; offset++)
      (got[offset]!.range.start, got[offset]!.range.end),
  }.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  expect(ranges.first.$1, 0, reason: 'lines $ranges $where');
  expect(ranges.last.$2, _text.length, reason: 'lines $ranges $where');
  for (var i = 1; i < ranges.length; i++) {
    final (_, end) = ranges[i - 1];
    final (start, _) = ranges[i];
    final next = end < _text.length && _text.codeUnitAt(end) == 0x0A
        ? end + 1
        : end;
    expect(
      start,
      next,
      reason:
          'line ${ranges[i]} must start where ${ranges[i - 1]} ends: '
          'lines $ranges $where',
    );
  }
}

/// Every offset, -1 to one past the end (both ends clamp).
final _forward = [for (var o = -1; o <= _text.length + 1; o++) o];

Future<void> _checkWidth(WidgetTester tester, double width) async {
  for (final (name, order) in [
    ('forward', _forward),
    ('backward', _forward.reversed.toList()),
  ]) {
    final paragraph = await _pump(tester, width, 'p-$width-$name');
    final oracle = LineBoxOracle.paragraph(paragraph);
    try {
      _expectMatchesOracle(
        paragraph,
        oracle,
        order,
        'in a $width px box, queried $name',
      );
    } finally {
      oracle.dispose();
    }
  }
}

void main() {
  holdFontFetches();

  // Widths where the wrap lands right before the hidden run: one glyph per
  // line (14 px, the test font's glyph width), each word on its own line
  // (50), two words a line (100, 110), three (160), and all six on one line
  // with the run alone below them (322).
  for (final (name, width) in <(String, double)>[
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 14 px box',
      14,
    ),
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 50 px box',
      50,
    ),
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 100 px box',
      100,
    ),
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 110 px box',
      110,
    ),
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 160 px box',
      160,
    ),
    (
      'lineAt matches the oracle at every offset around a hidden run after a wrapping space in a 322 px box',
      322,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final paragraph = await _pump(tester, width, 'probe');
      final oracle = LineBoxOracle.paragraph(paragraph);
      final wraps = _wrapsBeforeRun(oracle);
      oracle.dispose();
      expect(
        wraps,
        isTrue,
        reason:
            'the layout this test is about: a $width px box wraps right '
            'before the hidden run',
      );
      await _checkWidth(tester, width);
    });
  }

  testWidgets(
    'lineAt matches the oracle at every offset in every box width from 14 to 400 px, including each where the wrap lands right before the hidden run',
    (tester) async {
      final before = <double>[];
      for (var w = 14; w <= 400; w++) {
        final width = w.toDouble();
        final paragraph = await _pump(tester, width, 'probe-$w');
        final oracle = LineBoxOracle.paragraph(paragraph);
        if (_wrapsBeforeRun(oracle)) before.add(width);
        oracle.dispose();
        await _checkWidth(tester, width);
      }
      // The sweep is not vacuous: some widths wrap right before the run,
      // and some keep the run on the line above. Narrower boxes than one
      // glyph (14 px) are left out: no editor row is that narrow.
      expect(before, isNotEmpty);
      expect(before.length, lessThan(400 - 14 + 1));
    },
  );

  // A hidden run that ends the whole text (no line break after it), kept on
  // the last visible line: the fix leaves the end of the text alone, so the
  // line still takes in the run.
  testWidgets(
    'lineAt matches the oracle at every offset of a hidden run that ends the text on the last visible line',
    (tester) async {
      const visible = 'aaa bbb ';
      const text = '$visible**';
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 322,
              child: LineBoxEpoch(
                child: RichText(
                  key: const Key('text-end'),
                  text: const TextSpan(
                    style: TextStyle(fontSize: 14, height: 1.7),
                    children: [
                      TextSpan(text: visible),
                      TextSpan(text: '**', style: livePreviewHiddenStyle),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('text-end')),
      );
      expect(paragraph.text.toPlainText(), text);
      final oracle = LineBoxOracle.paragraph(paragraph);
      final source = RenderParagraphLineBoxes(paragraph);
      try {
        for (var offset = 0; offset <= text.length; offset++) {
          final line = source.lineAt(offset);
          final want = oracle.lineAt(offset);
          expect(
            (line.range.start, line.range.end, line.top, line.bottom),
            (want.range.start, want.range.end, want.top, want.bottom),
            reason:
                'lineAt($offset): got ${_show(line)}, oracle ${_show(want)}',
          );
        }
        expect(source.lineAt(0).range.end, text.length);
      } finally {
        oracle.dispose();
      }
    },
  );
}
