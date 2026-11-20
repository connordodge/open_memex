// Spec #122 Req "line geometry matches the oracle" (WI #126 AC1), fix PR:
// RenderParagraphLineBoxes.lineAt on a source line that wraps after the
// space right before a run of hidden (zero-width) markers. On main, at
// offset 12 of the text below in a 160 px box, the whole-text measurement
// (LineBoxOracle) gives the line (12, 24) while lineAt gave (12, 26): the
// wrapped line above swallowed the hidden run's own line (24, 26). Line
// ranges must partition the text, and each must be the oracle's, at every
// offset: lines above, inside and after the run. The same holds when the
// hidden run ends the whole text (no line break after it), the shape of an
// editor row ending in hidden markup, and for lines, boxesFor and
// caretRect, not only lineAt.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/line_box_oracle.dart';

/// Six words and the space after the last, then two hidden markers.
const _visible = 'aaa bbb ccc ddd eee fff ';
const _hidden = '**';

/// A text: [visible], the hidden run, then [tail] (a line break and a
/// visible line, or nothing so that the run ends the text).
class _Fixture {
  const _Fixture(this.tail, {this.visible = _visible, this.prefix = ''});

  final String tail;
  final String visible;

  /// Text before [visible], ahead of the hidden run.
  final String prefix;

  String get text => prefix + visible + _hidden + tail;

  /// Where the hidden run starts and ends.
  int get runStart => prefix.length + visible.length;
  int get runEnd => runStart + _hidden.length;

  TextSpan get span => TextSpan(
    style: const TextStyle(fontSize: 14, height: 1.7),
    children: [
      TextSpan(text: prefix + visible),
      const TextSpan(text: _hidden, style: livePreviewHiddenStyle),
      if (tail.isNotEmpty) TextSpan(text: tail),
    ],
  );

  /// Whether [line] holds nothing but hidden markers.
  bool hiddenOnly(LineBox line) =>
      line.range.start >= runStart && line.range.end <= runEnd;

  /// Whether [oracle]'s layout wraps right before the hidden run: the run
  /// opens a line, and the line holding the space before it ends there.
  bool wrapsBeforeRun(LineBoxOracle oracle) =>
      runStart > 0 &&
      oracle.lineAt(runStart).range.start == runStart &&
      oracle.lineAt(runStart - 1).range.end == runStart;
}

/// The run followed by a line break and a visible line.
const _withTail = _Fixture('\nnext');

/// The run ending the text.
const _atEnd = _Fixture('');

/// Pumps the paragraph in a [width] px box under its own [key] (a new key
/// is a fresh render object, so a fresh line cache), and returns it.
Future<RenderParagraph> _pump(
  WidgetTester tester,
  _Fixture fixture,
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
            child: RichText(key: Key(key), text: fixture.span),
          ),
        ),
      ),
    ),
  );
  final paragraph = tester.renderObject<RenderParagraph>(find.byKey(Key(key)));
  expect(paragraph.text.toPlainText(), fixture.text);
  return paragraph;
}

String _show(LineBox l) =>
    '(${l.range.start}, ${l.range.end}) top ${l.top} bottom ${l.bottom} '
    'baseline ${l.baseline}';

/// Compares lineAt with [oracle] at every offset of the text (and one past
/// each end, which clamps), querying in [order], and checks that the
/// distinct lines it gives partition the text.
void _expectLineAtMatches(
  _Fixture fixture,
  RenderParagraphLineBoxes source,
  LineBoxOracle oracle,
  List<int> order,
  String where,
) {
  final text = fixture.text;
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
    if (!fixture.hiddenOnly(want)) {
      expect(line.baseline, want.baseline, reason: reason);
    }
    got[offset] = line;
  }

  // Every in-text offset lies inside the line lineAt gives for it.
  for (var offset = 0; offset <= text.length; offset++) {
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
    for (var offset = 0; offset <= text.length; offset++)
      (got[offset]!.range.start, got[offset]!.range.end),
  }.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  expect(ranges.first.$1, 0, reason: 'lines $ranges $where');
  expect(ranges.last.$2, text.length, reason: 'lines $ranges $where');
  for (var i = 1; i < ranges.length; i++) {
    final (_, end) = ranges[i - 1];
    final (start, _) = ranges[i];
    final next = end < text.length && text.codeUnitAt(end) == 0x0A
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

/// Compares lines, boxesFor (over ranges crossing the run and its ends)
/// and caretRect (at every offset, and one past each end) with [oracle].
void _expectWholeMatches(
  _Fixture fixture,
  RenderParagraphLineBoxes source,
  LineBoxOracle oracle,
  String where,
) {
  final len = fixture.text.length;
  final lines = source.lines;
  (int, int, double, double) key(LineBox l) =>
      (l.range.start, l.range.end, l.top, l.bottom);
  expect(
    lines.map(key).toList(),
    oracle.lines.map(key).toList(),
    reason:
        'lines $where: got ${lines.map(_show).toList()}, '
        'oracle ${oracle.lines.map(_show).toList()}',
  );
  for (var i = 0; i < lines.length; i++) {
    if (!fixture.hiddenOnly(oracle.lines[i])) {
      expect(
        lines[i].baseline,
        oracle.lines[i].baseline,
        reason: 'lines[$i] baseline $where',
      );
    }
  }

  final starts = {
    0,
    for (final d in const [12, 4, 1, 0, -1]) fixture.runStart - d,
  }.where((o) => o >= 0 && o < len);
  final ends = {
    fixture.runStart + 1,
    fixture.runEnd,
    fixture.runEnd + 1,
    len,
  }.where((o) => o <= len);
  for (final s in starts) {
    for (final e in ends) {
      if (e <= s) continue;
      expect(
        source.boxesFor(TextRange(start: s, end: e)),
        oracle.boxesFor(TextRange(start: s, end: e)),
        reason: 'boxesFor($s, $e) $where',
      );
    }
  }

  for (var offset = -1; offset <= len + 1; offset++) {
    expect(
      source.caretRect(offset),
      oracle.caretRect(offset),
      reason: 'caretRect($offset) $where',
    );
  }
}

/// Every offset of [fixture]'s text, -1 to one past the end (both clamp).
List<int> _forward(_Fixture fixture) => [
  for (var o = -1; o <= fixture.text.length + 1; o++) o,
];

/// Checks [fixture] in a [width] px box, twice on a fresh paragraph each:
/// the whole-text reads first and then lineAt forward, and lineAt backward
/// and then the whole-text reads (so a line cache filled by one walk
/// serves the other).
Future<void> _checkWidth(
  WidgetTester tester,
  _Fixture fixture,
  double width,
) async {
  for (final (name, order, wholeFirst) in [
    ('forward', _forward(fixture), true),
    ('backward', _forward(fixture).reversed.toList(), false),
  ]) {
    final paragraph = await _pump(tester, fixture, width, 'p-$width-$name');
    final oracle = LineBoxOracle.paragraph(paragraph);
    final source = RenderParagraphLineBoxes(paragraph);
    final where = 'in a $width px box, queried $name';
    try {
      if (wholeFirst) _expectWholeMatches(fixture, source, oracle, where);
      _expectLineAtMatches(fixture, source, oracle, order, where);
      if (!wholeFirst) _expectWholeMatches(fixture, source, oracle, where);
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
  // with the run alone below them (322). The run is followed by a line
  // break and a visible line, or ends the text.
  for (final (name, fixture, width) in <(String, _Fixture, double)>[
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 14 px box',
      _withTail,
      14,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 50 px box',
      _withTail,
      50,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 100 px box',
      _withTail,
      100,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 110 px box',
      _withTail,
      110,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 160 px box',
      _withTail,
      160,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run after a wrapping space in a 322 px box',
      _withTail,
      322,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 14 px box',
      _atEnd,
      14,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 50 px box',
      _atEnd,
      50,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 100 px box',
      _atEnd,
      100,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 110 px box',
      _atEnd,
      110,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 160 px box',
      _atEnd,
      160,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset around a hidden run ending the text after a wrapping space in a 322 px box',
      _atEnd,
      322,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final paragraph = await _pump(tester, fixture, width, 'probe');
      final oracle = LineBoxOracle.paragraph(paragraph);
      final wraps = fixture.wrapsBeforeRun(oracle);
      oracle.dispose();
      expect(
        wraps,
        isTrue,
        reason:
            'the layout this test is about: a $width px box wraps right '
            'before the hidden run',
      );
      await _checkWidth(tester, fixture, width);
    });
  }

  for (final (name, fixture) in <(String, _Fixture)>[
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset in every box width from 14 to 400 px, including each where the wrap lands right before the hidden run',
      _withTail,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset of a hidden run ending the text in every box width from 14 to 400 px, including each where the wrap lands right before the hidden run',
      _atEnd,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final before = <double>[];
      for (var w = 14; w <= 400; w++) {
        final width = w.toDouble();
        final paragraph = await _pump(tester, fixture, width, 'probe-$w');
        final oracle = LineBoxOracle.paragraph(paragraph);
        if (fixture.wrapsBeforeRun(oracle)) before.add(width);
        oracle.dispose();
        await _checkWidth(tester, fixture, width);
      }
      // The sweep is not vacuous: some widths wrap right before the run,
      // and some keep the run on the line above. Narrower boxes than one
      // glyph (14 px) are left out: no editor row is that narrow.
      expect(before, isNotEmpty);
      expect(before.length, lessThan(400 - 14 + 1));
    });
  }

  // Other places for the run: opening the text, opening a source line
  // below another, and in the middle of a line, where the zero-width
  // characters have a box after them (or none before them) to name their
  // line. The middle one starts at 50 px: a narrower box breaks a word in
  // the middle, which lineAt places differently from the oracle (a known
  // older gap, outside this fix).
  for (final (name, fixture, from) in <(String, _Fixture, int)>[
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset of a hidden run opening the text in every box width from 14 to 400 px',
      _Fixture(' ddd eee fff ggg hhh iii', visible: ''),
      14,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset of a hidden run opening a source line in every box width from 14 to 400 px',
      _Fixture(' ddd eee fff ggg\nnext', visible: '', prefix: 'aaa bbb\n'),
      14,
    ),
    (
      'lineAt, lines, boxesFor and caretRect match the oracle at every offset of a hidden run in the middle of a line in every box width from 50 to 400 px',
      _Fixture('ddd eee fff ggg hhh iii', visible: 'aaa bbb ccc '),
      50,
    ),
  ]) {
    testWidgets(name, (tester) async {
      for (var w = from; w <= 400; w++) {
        await _checkWidth(tester, fixture, w.toDouble());
      }
    });
  }

  // A hidden run that ends the whole text, kept on the last visible line
  // (nothing wraps in 322 px): the line takes in the run, as the oracle's.
  testWidgets(
    'lineAt, lines, boxesFor and caretRect match the oracle at every offset of a hidden run that ends the text on the last visible line',
    (tester) async {
      const fixture = _Fixture('', visible: 'aaa bbb ');
      final paragraph = await _pump(tester, fixture, 322, 'text-end');
      final oracle = LineBoxOracle.paragraph(paragraph);
      final source = RenderParagraphLineBoxes(paragraph);
      try {
        expect(
          fixture.wrapsBeforeRun(oracle),
          isFalse,
          reason: 'the layout this test is about: the run stays on the line',
        );
        _expectWholeMatches(fixture, source, oracle, 'in a 322 px box');
        _expectLineAtMatches(
          fixture,
          source,
          oracle,
          _forward(fixture),
          'in a 322 px box',
        );
        expect(source.lineAt(0).range.end, fixture.text.length);
      } finally {
        oracle.dispose();
      }
    },
  );
}
