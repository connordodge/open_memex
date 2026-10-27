// WI #203 (T2): table geometry (Spec #197 R18, R19, R21 mapping, TD5;
// rulings D13, D18, D21). Every design number comes from the design pack
// `design/192-md-tables/packs/203.md` (its "Design pack corrections" win over
// the WI text): padding c = 8.1 left and right, header band inset 4 + 4, body
// cells no vertical inset, the rule in the last pixel inside its row.
//
// Boundary and mutation tests use exact binary metrics (L 24, H 8, c 8,
// t 1) so a point on an edge is exactly on it; design-number tests use the
// pack's metrics with closeTo.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, TextAlign, TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/table_geometry.dart';

const _eps = 1e-9;

/// The design pack's widths are printed to 0.01.
const _packEps = 0.005;

Matcher _px(double v) => closeTo(v, _eps);

/// Text scale 1 (pack 203): L 22.95, H 8, c 8.1, t 1.
const _design = TableMetrics(
  lineHeight: 22.95,
  hiddenLineHeight: 8,
  cellPadding: 8.1,
  ruleThickness: 1,
);

/// Exact binary metrics for edge tests.
const _exact = TableMetrics(
  lineHeight: 24,
  hiddenLineHeight: 8,
  cellPadding: 8,
  ruleThickness: 1,
);

void _expectRect(
  Rect actual,
  double left,
  double top,
  double right,
  double bottom, {
  double eps = _eps,
  String? reason,
}) {
  final why = '${reason ?? ''} got $actual';
  expect(actual.left, closeTo(left, eps), reason: '$why left');
  expect(actual.top, closeTo(top, eps), reason: '$why top');
  expect(actual.right, closeTo(right, eps), reason: '$why right');
  expect(actual.bottom, closeTo(bottom, eps), reason: '$why bottom');
}

void _expectWidths(
  List<double> actual,
  List<double> expected, {
  double eps = _eps,
  String? reason,
}) {
  expect(actual, hasLength(expected.length), reason: reason);
  for (var i = 0; i < expected.length; i++) {
    expect(
      actual[i],
      closeTo(expected[i], eps),
      reason: '${reason ?? ''} column $i of $actual',
    );
  }
}

double _sum(Iterable<double> xs) => xs.fold(0.0, (a, b) => a + b);

/// Columns measured in mono glyph columns of [c] px (pack 203's worked
/// examples give n and m in glyphs).
List<TableColumnMeasure> _glyphs(
  List<int> n,
  List<int> m,
  List<bool> noWrap, {
  double c = 8.1,
}) => [
  for (var i = 0; i < n.length; i++)
    TableColumnMeasure(
      naturalWidth: n[i] * c,
      minWidth: m[i] * c,
      noWrap: noWrap[i],
    ),
];

/// A table whose every cell is one line: [bodyRows] body rows.
TableLayout _oneLine(
  List<double> widths,
  int bodyRows, {
  TableMetrics metrics = _design,
}) => TableLayout(
  columnWidths: widths,
  headerLines: [for (final _ in widths) 1],
  bodyLines: [
    for (var r = 0; r < bodyRows; r++) [for (final _ in widths) 1],
  ],
  metrics: metrics,
);

/// The hit-mapping fixture (exact metrics): widths 100 / 200 / 50.
/// Header cells 1, 1, empty. Body row 1: 1, 2, 1 lines (48 high). Body
/// row 2: 1, empty, 1. Body row 3: 1, 1, 1.
///
/// Band 0..32 (header text block 4..28); row 1 32..80 (rule 79..80); row 2
/// 80..104 (rule 103..104); row 3 104..128 (no rule). Content x: column 0
/// 8..92, column 1 108..292, column 2 308..342.
TableLayout _hitFixture({TableMetrics metrics = _exact}) => TableLayout(
  columnWidths: const [100, 200, 50],
  headerLines: const [1, 1, 0],
  bodyLines: const [
    [1, 2, 1],
    [1, 0, 1],
    [1, 1, 1],
  ],
  metrics: metrics,
);

TableCellTarget _cell(int row, int column, {bool end = false}) =>
    TableCellTarget(row: row, column: column, atTextEnd: end);

void _expectHits(TableLayout layout, List<(Offset, TableCellTarget)> cases) {
  for (final (point, target) in cases) {
    expect(layout.hitTest(point), target, reason: 'point $point');
  }
}

/// Source ranges of a table's text, split with a naive test-only splitter
/// (no escapes, no wikilinks): line 1 is the delimiter line.
({
  List<TextRange> rowLines,
  TextRange delimiterLine,
  List<List<TextRange>> rowCells,
})
_source(String text) {
  final lines = <TextRange>[];
  var start = 0;
  while (true) {
    final end = text.indexOf('\n', start);
    if (end < 0) {
      lines.add(TextRange(start: start, end: text.length));
      break;
    }
    lines.add(TextRange(start: start, end: end));
    start = end + 1;
  }
  List<TextRange> cellsOf(TextRange line) {
    final cells = <TextRange>[];
    final body = text.substring(line.start, line.end);
    final pipes = [
      -1,
      for (var i = 0; i < body.length; i++)
        if (body[i] == '|') i,
      body.length,
    ];
    for (var p = 0; p + 1 < pipes.length; p++) {
      final from = pipes[p] + 1;
      final to = pipes[p + 1];
      final raw = body.substring(from, to);
      final trimmed = raw.trim();
      final outer = (p == 0 || p + 2 == pipes.length) && trimmed.isEmpty;
      if (outer) continue;
      final lead = raw.indexOf(trimmed);
      cells.add(
        TextRange(
          start: line.start + from + lead,
          end: line.start + from + lead + trimmed.length,
        ),
      );
    }
    return cells;
  }

  final rowLines = [lines[0], ...lines.skip(2)];
  return (
    rowLines: rowLines,
    delimiterLine: lines[1],
    rowCells: [for (final line in rowLines) cellsOf(line)],
  );
}

void main() {
  group('header band (AC R18)', () {
    test('a one line header band is one line plus the hidden line height', () {
      final one = _oneLine(const [100, 100], 0);
      expect(one.bandHeight, _px(30.95));
      expect(one.rowTop(0), _px(0));
      expect(one.rowHeight(0), _px(30.95));

      final two = TableLayout(
        columnWidths: const [100, 100],
        headerLines: const [1, 2],
        bodyLines: const [],
        metrics: _design,
      );
      expect(two.bandHeight, _px(53.9));

      // An all-empty header still takes one line.
      final empty = TableLayout(
        columnWidths: const [100, 100],
        headerLines: const [0, 0],
        bodyLines: const [],
        metrics: _design,
      );
      expect(empty.bandHeight, _px(30.95));
    });

    test('the header band scales from the passed line and hidden heights', () {
      const scale = 1.2;
      final scaled = TableMetrics(
        lineHeight: 22.95 * scale,
        hiddenLineHeight: 8 * scale,
        cellPadding: 8.1 * scale,
        ruleThickness: 1,
      );
      final one = _oneLine(const [100, 100], 0, metrics: scaled);
      expect(one.bandHeight, _px(27.54 + 9.6));
      final two = TableLayout(
        columnWidths: const [100, 100],
        headerLines: const [2, 1],
        bodyLines: const [],
        metrics: scaled,
      );
      expect(two.bandHeight, _px(2 * 27.54 + 9.6));
      // Exact metrics: 3 lines x 24 + 8.
      final exact = TableLayout(
        columnWidths: const [100],
        headerLines: const [3],
        bodyLines: const [],
        metrics: _exact,
      );
      expect(exact.bandHeight, 80);
    });
  });

  group('body rows (AC R18)', () {
    test('a body row is its tallest cell line count times the line height', () {
      final layout = TableLayout(
        columnWidths: const [100, 100, 100],
        headerLines: const [1, 1, 1],
        bodyLines: const [
          [1, 1, 1],
          [1, 2, 1],
          [3, 1, 2],
          [0, 0, 0],
          [0, 2, 0],
        ],
        metrics: _design,
      );
      expect(layout.rowHeight(1), _px(22.95));
      expect(layout.rowHeight(2), _px(45.9));
      expect(layout.rowHeight(3), _px(68.85));
      // An empty cell is one line.
      expect(layout.rowHeight(4), _px(22.95));
      expect(layout.rowHeight(5), _px(45.9));
    });

    test('body row tops are cumulative after the header band', () {
      final layout = TableLayout(
        columnWidths: const [100, 100],
        headerLines: const [1, 1],
        bodyLines: const [
          [1, 1],
          [2, 1],
          [1, 3],
        ],
        metrics: _design,
      );
      expect(layout.rowTop(1), _px(30.95));
      expect(layout.rowTop(2), _px(30.95 + 22.95));
      expect(layout.rowTop(3), _px(30.95 + 22.95 + 45.9));
      expect(layout.height, _px(30.95 + 22.95 + 45.9 + 68.85));
      for (var r = 1; r < 3; r++) {
        expect(
          layout.rowTop(r) + layout.rowHeight(r),
          _px(layout.rowTop(r + 1)),
          reason: 'row $r has no gap below it',
        );
      }
    });

    test('a header only table is its header band alone', () {
      final layout = _oneLine(const [120, 80], 0);
      expect(layout.height, _px(30.95));
      expect(layout.rules, isEmpty);
    });

    test(
      'rules sit in the last pixel inside each body row except the last and add no height',
      () {
        final layout = _oneLine(const [290.11, 300.47, 82.89, 72.53], 4);
        // B1: band 0-30.95, rows to 53.9, 76.85, 99.8, 122.75.
        expect(layout.height, _px(122.75));
        expect(layout.width, _px(746));
        final rules = layout.rules;
        expect(rules, hasLength(3));
        final ys = [52.9, 75.85, 98.8];
        for (var i = 0; i < 3; i++) {
          _expectRect(rules[i], 0, ys[i], 746, ys[i] + 1, reason: 'rule $i');
        }
        // Rules add no height: the table is the band plus its rows.
        expect(
          layout.height,
          _px(
            layout.bandHeight +
                _sum([for (var r = 1; r <= 4; r++) layout.rowHeight(r)]),
          ),
        );

        // One body row: no rule under the last (only) row.
        expect(_oneLine(const [100, 100], 1).rules, isEmpty);

        // Two rows of 2 and 1 lines (exact metrics): one rule at 32 + 48 - 1.
        final exact = TableLayout(
          columnWidths: const [100, 60],
          headerLines: const [1, 1],
          bodyLines: const [
            [2, 1],
            [1, 1],
          ],
          metrics: _exact,
        );
        expect(exact.rules, hasLength(1));
        _expectRect(exact.rules.single, 0, 79, 160, 80);
      },
    );

    test('a rule is as thick as the passed rule thickness', () {
      const thick = TableMetrics(
        lineHeight: 24,
        hiddenLineHeight: 8,
        cellPadding: 8,
        ruleThickness: 2,
      );
      final layout = _oneLine(const [100, 60], 3, metrics: thick);
      // Rows 32-56, 56-80, 80-104.
      expect(layout.rules, hasLength(2));
      _expectRect(layout.rules[0], 0, 54, 160, 56);
      _expectRect(layout.rules[1], 0, 78, 160, 80);
      expect(layout.height, 104);
    });
  });

  group('reveal delta (AC R18)', () {
    test('the reveal delta is 14.95 for 0, 1 and 5 one line body rows', () {
      expect(tableRevealDelta(_design), _px(14.95));
      for (final n in [0, 1, 5]) {
        final layout = _oneLine(const [200, 100], n);
        final revealed = (n + 2) * 22.95;
        final rendered = 30.95 + n * 22.95;
        expect(layout.height, _px(rendered), reason: 'N = $n');
        expect(revealed - layout.height, _px(14.95), reason: 'N = $n');
        expect(
          revealed - layout.height,
          _px(tableRevealDelta(_design)),
          reason: 'N = $n',
        );
      }
      expect(tableRevealDelta(_exact), 16);
    });
  });

  group('column widths (AC R19)', () {
    // Pack 203 worked examples: n and m in glyph columns, widths by the rule.
    final examples =
        <
          (
            String,
            double,
            List<int>,
            List<int>,
            List<bool>,
            List<double>,
            List<int>,
            double,
          )
        >[
          (
            'B1 Table',
            746,
            [26, 27, 6, 5],
            [13, 11, 4, 5],
            [false, false, true, true],
            [290.11, 300.47, 82.89, 72.53],
            [1, 1, 1, 1],
            122.75,
          ),
          (
            'B2 table 1',
            650,
            [26, 27, 6, 5],
            [13, 11, 4, 5],
            [false, false, true, true],
            [252.78, 261.81, 72.22, 63.19],
            [1, 1, 1, 1],
            122.75,
          ),
          (
            'B2 table 2',
            650,
            [27, 14, 25, 28, 5, 4],
            [9, 8, 13, 9, 5, 4],
            [false, false, false, false, true, true],
            [153.58, 88.94, 143.63, 158.55, 56.70, 48.60],
            [2, 2, 2],
            168.65,
          ),
          (
            'B3-G',
            602,
            [27, 14, 25, 28, 5, 4],
            [9, 8, 13, 9, 5, 4],
            [false, false, false, false, true, true],
            [139.71, 82.01, 130.83, 144.15, 56.70, 48.60],
            [2, 2, 2],
            168.65,
          ),
          (
            'B3-H card',
            578,
            [26, 27, 6, 5],
            [13, 8, 4, 5],
            [false, false, true, true],
            [224.25, 232.25, 64.80, 56.70],
            [2, 2, 1],
            145.7,
          ),
          (
            'B3-C',
            602,
            [13, 6, 5],
            [7, 6, 5],
            [false, false, false],
            [301.00, 160.53, 140.47],
            [1, 1, 1],
            99.8,
          ),
          (
            'B3-D rendered',
            291,
            [12, 6, 5],
            [6, 4, 5],
            [false, false, false],
            [140.48, 80.28, 70.24],
            [1, 1],
            76.85,
          ),
        ];

    for (final (name, w, n, m, noWrap, widths, rows, height) in examples) {
      test('design pack worked example $name', () {
        final got = tableColumnWidths(
          _glyphs(n, m, noWrap),
          availableWidth: w,
          cellPadding: 8.1,
        );
        _expectWidths(got, widths, eps: _packEps, reason: name);
        expect(_sum(got), _px(w), reason: '$name sums to W');
        final layout = TableLayout(
          columnWidths: got,
          headerLines: [for (final _ in n) 1],
          bodyLines: [
            for (final k in rows) [k, for (var j = 1; j < n.length; j++) 1],
          ],
          metrics: _design,
        );
        expect(layout.height, _px(height), reason: '$name height');
        expect(layout.width, _px(w), reason: '$name width');
      });
    }

    test(
      'natural widths that fit are widened in proportion to span the available width',
      () {
        // B1: sum N = 583.2, factor 746 / 583.2. No-wrap columns spread too.
        final got = tableColumnWidths(
          _glyphs(const [26, 27, 6, 5], const [13, 11, 4, 5], const [
            false,
            false,
            true,
            true,
          ]),
          availableWidth: 746,
          cellPadding: 8.1,
        );
        final natural = [28 * 8.1, 29 * 8.1, 8 * 8.1, 7 * 8.1];
        for (var i = 0; i < 4; i++) {
          expect(got[i] / natural[i], _px(746 / 583.2), reason: 'column $i');
        }
      },
    );

    test(
      'column widths at the fit boundary: natural sum equal to the available width and one unit over',
      () {
        const columns = [
          TableColumnMeasure(naturalWidth: 100, minWidth: 20),
          TableColumnMeasure(naturalWidth: 50, minWidth: 10),
        ];
        // N = 116, 66: sum 182. At W = 182 every column is its natural width.
        _expectWidths(
          tableColumnWidths(columns, availableWidth: 182, cellPadding: 8),
          const [116, 66],
        );
        // One unit over (W = 181): shrink from B = 24 toward N, f = 133 / 134
        // (a spread would give 115.36 / 65.64).
        const f = 133 / 134;
        _expectWidths(
          tableColumnWidths(columns, availableWidth: 181, cellPadding: 8),
          const [24 + 92 * f, 24 + 42 * f],
        );
      },
    );

    test(
      'widths that do not fit shrink but never below each column min width',
      () {
        // B2 table 2 walk-through: Pages and Read (no-wrap) freeze at N.
        final got = tableColumnWidths(
          _glyphs(
            const [27, 14, 25, 28, 5, 4],
            const [9, 8, 13, 9, 5, 4],
            const [false, false, false, false, true, true],
          ),
          availableWidth: 650,
          cellPadding: 8.1,
        );
        final floors = [
          11 * 8.1,
          10 * 8.1,
          15 * 8.1,
          11 * 8.1,
          7 * 8.1,
          6 * 8.1,
        ];
        final natural = [29, 16, 27, 30, 7, 6].map((g) => g * 8.1).toList();
        for (var i = 0; i < 6; i++) {
          expect(
            got[i],
            greaterThanOrEqualTo(floors[i] - _eps),
            reason: 'col $i',
          );
          expect(
            got[i],
            lessThanOrEqualTo(natural[i] + _eps),
            reason: 'col $i',
          );
        }
        expect(got[4], _px(7 * 8.1));
        expect(got[5], _px(6 * 8.1));
        expect(_sum(got), _px(650));
      },
    );

    test(
      'a no-wrap column keeps its natural width as its floor while the floors fit',
      () {
        // N = 176, 96; M = 56, 32; no-wrap F = 56, 96 (sum 152). W = 153:
        // column 1 freezes at 96, column 0 takes the rest.
        const columns = [
          TableColumnMeasure(naturalWidth: 160, minWidth: 40),
          TableColumnMeasure(naturalWidth: 80, minWidth: 16, noWrap: true),
        ];
        _expectWidths(
          tableColumnWidths(columns, availableWidth: 153, cellPadding: 8),
          const [57, 96],
        );
        // The same columns without no-wrap shrink together from B = 24.
        const wrapping = [
          TableColumnMeasure(naturalWidth: 160, minWidth: 40),
          TableColumnMeasure(naturalWidth: 80, minWidth: 16),
        ];
        const f = 105 / 224;
        _expectWidths(
          tableColumnWidths(wrapping, availableWidth: 153, cellPadding: 8),
          const [24 + 152 * f, 24 + 72 * f],
        );
      },
    );

    test(
      'the no-wrap floor is dropped when the floors sum to the available width',
      () {
        // Same columns, W = 152 = sum F: every floor falls back to M, so both
        // shrink from B: f = 104 / 224.
        const columns = [
          TableColumnMeasure(naturalWidth: 160, minWidth: 40),
          TableColumnMeasure(naturalWidth: 80, minWidth: 16, noWrap: true),
        ];
        const f = 104 / 224;
        _expectWidths(
          tableColumnWidths(columns, availableWidth: 152, cellPadding: 8),
          const [24 + 152 * f, 24 + 72 * f],
        );
      },
    );

    test('the freeze loop freezes columns over several passes', () {
      // N = 316, 116, 216; M = 26, 82, 160; B = 24. Pass 1 (f = 368/576)
      // freezes column 2 at 160; pass 2 (f = 232/384) freezes column 1 at
      // 82; pass 3: f = 174/292, column 0 = 24 + 292 f = 198.
      const columns = [
        TableColumnMeasure(naturalWidth: 300, minWidth: 10),
        TableColumnMeasure(naturalWidth: 100, minWidth: 66),
        TableColumnMeasure(naturalWidth: 200, minWidth: 144),
      ];
      _expectWidths(
        tableColumnWidths(columns, availableWidth: 440, cellPadding: 8),
        const [198, 82, 160],
      );
    });

    test(
      'when min widths alone exceed the available width the widths still sum to it',
      () {
        // N = 96, 48; M = 80, 48; B = 24. sum M = 128 >= 88 > sum B = 48:
        // g = 40 / 80, widths B + (M - B) g. Column 0 drops below its M
        // (its words break between characters).
        const columns = [
          TableColumnMeasure(naturalWidth: 80, minWidth: 64),
          TableColumnMeasure(naturalWidth: 32, minWidth: 32),
        ];
        final got = tableColumnWidths(
          columns,
          availableWidth: 88,
          cellPadding: 8,
        );
        _expectWidths(got, const [52, 36]);
        expect(_sum(got), _px(88));

        // sum B > W: widths are B scaled to W. N = 20, 56; B = 20, 24.
        const tiny = [
          TableColumnMeasure(naturalWidth: 4, minWidth: 4),
          TableColumnMeasure(naturalWidth: 40, minWidth: 40),
        ];
        _expectWidths(
          tableColumnWidths(tiny, availableWidth: 22, cellPadding: 8),
          const [10, 12],
        );
      },
    );

    test(
      'min widths at the break anywhere floor sum exactly to the available width',
      () {
        // N = 32, M = B = 24 per column: sum B = 48 = W. Every column is B.
        const columns = [
          TableColumnMeasure(naturalWidth: 16, minWidth: 8),
          TableColumnMeasure(naturalWidth: 16, minWidth: 8),
        ];
        final got = tableColumnWidths(
          columns,
          availableWidth: 48,
          cellPadding: 8,
        );
        _expectWidths(got, const [24, 24]);
        for (final w in got) {
          expect(w.isFinite, isTrue, reason: '$got');
        }
      },
    );

    test('an empty column is twice the cell padding wide', () {
      // Empty column: n = m = 0, so N = M = B = 2c = 16.
      const shrinking = [
        TableColumnMeasure(naturalWidth: 200, minWidth: 40),
        TableColumnMeasure(naturalWidth: 0, minWidth: 0),
      ];
      _expectWidths(
        tableColumnWidths(shrinking, availableWidth: 150, cellPadding: 8),
        const [134, 16],
      );
      const spreading = [
        TableColumnMeasure(naturalWidth: 100, minWidth: 20),
        TableColumnMeasure(naturalWidth: 0, minWidth: 0),
      ];
      _expectWidths(
        tableColumnWidths(spreading, availableWidth: 264, cellPadding: 8),
        const [232, 32],
      );
      expect(
        tableColumnWidths(const [], availableWidth: 300, cellPadding: 8),
        isEmpty,
      );
    });

    test('column widths sum to the available width in every case', () {
      final random = math.Random(203);
      final branches = <String, int>{};
      for (var i = 0; i < 2000; i++) {
        final c = 4 + random.nextDouble() * 8;
        final count = 1 + random.nextInt(7);
        final columns = <TableColumnMeasure>[];
        for (var j = 0; j < count; j++) {
          // Mono cell text: n and m are whole glyphs, and a non-empty
          // column's widest word is at least one glyph (so M >= B).
          final empty = random.nextInt(10) == 0;
          final glyphs = empty ? 0 : 1 + random.nextInt(50);
          final word = empty ? 0 : 1 + random.nextInt(glyphs);
          final n = glyphs * c;
          final m = word * c;
          columns.add(
            TableColumnMeasure(
              naturalWidth: n,
              minWidth: m,
              noWrap: random.nextBool(),
            ),
          );
        }
        final w = 20 + random.nextDouble() * 900;
        final got = tableColumnWidths(
          columns,
          availableWidth: w,
          cellPadding: c,
        );
        final why = 'case $i W $w c $c';
        expect(got, hasLength(count), reason: why);
        expect(_sum(got), closeTo(w, 1e-6), reason: why);
        final nat = [for (final col in columns) col.naturalWidth + 2 * c];
        final mins = [for (final col in columns) col.minWidth + 2 * c];
        var floors = [
          for (var j = 0; j < count; j++) columns[j].noWrap ? nat[j] : mins[j],
        ];
        if (_sum(floors) >= w) floors = mins;
        for (var j = 0; j < count; j++) {
          expect(got[j].isFinite, isTrue, reason: why);
          expect(got[j], greaterThan(0), reason: why);
        }
        if (_sum(nat) <= w) {
          branches.update('spread', (v) => v + 1, ifAbsent: () => 1);
          for (var j = 0; j < count; j++) {
            expect(got[j], closeTo(nat[j] * w / _sum(nat), 1e-6), reason: why);
          }
        } else if (_sum(floors) < w) {
          branches.update('shrink', (v) => v + 1, ifAbsent: () => 1);
          for (var j = 0; j < count; j++) {
            expect(got[j], greaterThanOrEqualTo(floors[j] - 1e-6), reason: why);
            expect(got[j], lessThanOrEqualTo(nat[j] + 1e-6), reason: why);
          }
        } else {
          branches.update('hopeless', (v) => v + 1, ifAbsent: () => 1);
          for (var j = 0; j < count; j++) {
            expect(got[j], lessThanOrEqualTo(mins[j] + 1e-6), reason: why);
          }
        }
      }
      // The sweep reaches every branch of the rule.
      for (final branch in ['spread', 'shrink', 'hopeless']) {
        expect(branches[branch] ?? 0, greaterThan(50), reason: '$branches');
      }
    });
  });

  group('cell rects (AC cell rects)', () {
    test(
      'each cell rect is its column x-range and its row y-range inset by the design pack padding',
      () {
        final layout = TableLayout(
          columnWidths: const [290.11, 300.47, 82.89, 72.53],
          headerLines: const [1, 1, 1, 1],
          bodyLines: const [
            [1, 1, 1, 1],
            [2, 1, 1, 1],
          ],
          metrics: _design,
        );
        final lefts = [0.0, 290.11, 590.58, 673.47];
        final rights = [290.11, 590.58, 673.47, 746.0];
        for (var j = 0; j < 4; j++) {
          expect(layout.columnLeft(j), _px(lefts[j]), reason: 'column $j');
          // Header: band 0-30.95; content inset 8.1 l/r and 4 t/b.
          _expectRect(layout.cellRect(0, j), lefts[j], 0, rights[j], 30.95);
          _expectRect(
            layout.contentRect(0, j),
            lefts[j] + 8.1,
            4,
            rights[j] - 8.1,
            26.95,
          );
          // Body row 1: 30.95-53.9; no vertical inset.
          _expectRect(layout.cellRect(1, j), lefts[j], 30.95, rights[j], 53.9);
          _expectRect(
            layout.contentRect(1, j),
            lefts[j] + 8.1,
            30.95,
            rights[j] - 8.1,
            53.9,
          );
          // Body row 2 is two lines (column 0): every cell shares its y-range.
          _expectRect(layout.cellRect(2, j), lefts[j], 53.9, rights[j], 99.8);
          _expectRect(
            layout.contentRect(2, j),
            lefts[j] + 8.1,
            53.9,
            rights[j] - 8.1,
            99.8,
          );
        }
      },
    );

    test('cells of one row share top and bottom', () {
      final layout = _hitFixture();
      for (var r = 0; r <= 3; r++) {
        final top = layout.cellRect(r, 0).top;
        final bottom = layout.cellRect(r, 0).bottom;
        expect(top, layout.rowTop(r), reason: 'row $r');
        expect(
          bottom,
          layout.rowTop(r) + layout.rowHeight(r),
          reason: 'row $r',
        );
        for (var j = 1; j < 3; j++) {
          expect(layout.cellRect(r, j).top, top, reason: 'row $r col $j');
          expect(layout.cellRect(r, j).bottom, bottom, reason: 'row $r col $j');
        }
      }
      // Header content rect inset by H / 2 = 4: 4..28.
      _expectRect(layout.contentRect(0, 1), 108, 4, 292, 28);
      _expectRect(layout.contentRect(1, 1), 108, 32, 292, 80);
    });

    test('line left follows the column alignment inside the content rect', () {
      final layout = _oneLine(const [290.11, 300.47, 82.89, 72.53], 1);
      // B1: `1.5` (3 glyphs) right-aligned ends at cell right - 8.1.
      expect(
        layout.lineLeft(2, lineWidth: 3 * 8.1, align: TextAlign.right),
        _px(673.47 - 8.1 - 3 * 8.1),
      );
      // `done` (4 glyphs) centred in 72.53.
      expect(
        layout.lineLeft(3, lineWidth: 4 * 8.1, align: TextAlign.center),
        _px(673.47 + (72.53 - 4 * 8.1) / 2),
      );
      expect(
        layout.lineLeft(1, lineWidth: 50, align: TextAlign.left),
        _px(290.11 + 8.1),
      );

      // Exact metrics: column 1 is 100..300 (c = 8), a 40 px line.
      final exact = _hitFixture();
      final cases = <(TextAlign, double)>[
        (TextAlign.left, 108),
        (TextAlign.start, 108),
        (TextAlign.justify, 108),
        (TextAlign.right, 252),
        (TextAlign.end, 252),
        (TextAlign.center, 180),
      ];
      for (final (align, x) in cases) {
        expect(
          exact.lineLeft(1, lineWidth: 40, align: align),
          x,
          reason: '$align',
        );
      }
    });
  });

  group('hit mapping (AC R21)', () {
    test('a point inside a cell text area maps to that cell', () {
      _expectHits(_hitFixture(), [
        (const Offset(50, 40), _cell(1, 0)),
        (const Offset(150, 60), _cell(1, 1)),
        (const Offset(320, 110), _cell(3, 2)),
        (const Offset(50, 10), _cell(0, 0)),
        (const Offset(150, 10), _cell(0, 1)),
        // Content x-range [8, 92) for column 0, [108, 292) for column 1.
        (const Offset(8, 40), _cell(1, 0)),
        (const Offset(91.5, 40), _cell(1, 0)),
        (const Offset(108, 40), _cell(1, 1)),
        // Row edges: y = 32 is body row 1, y = 80 row 2, y = 104 row 3.
        (const Offset(50, 32), _cell(1, 0)),
        (const Offset(50, 80), _cell(2, 0)),
        (const Offset(50, 104), _cell(3, 0)),
        // Header text block [4, 28).
        (const Offset(50, 4), _cell(0, 0)),
        (const Offset(50, 27.9), _cell(0, 0)),
      ]);
    });

    test(
      'a point in the left or right padding of a cell maps to that cell text end',
      () {
        _expectHits(_hitFixture(), [
          (const Offset(4, 40), _cell(1, 0, end: true)),
          (const Offset(7.9, 40), _cell(1, 0, end: true)),
          (const Offset(92, 40), _cell(1, 0, end: true)),
          (const Offset(96, 40), _cell(1, 0, end: true)),
          (const Offset(100, 40), _cell(1, 1, end: true)),
          (const Offset(104, 40), _cell(1, 1, end: true)),
          (const Offset(292, 60), _cell(1, 1, end: true)),
          (const Offset(300, 40), _cell(1, 2, end: true)),
          (const Offset(4, 10), _cell(0, 0, end: true)),
          (const Offset(296, 10), _cell(0, 1, end: true)),
        ]);
      },
    );

    test('a point in an empty cell maps to that cell text end', () {
      _expectHits(_hitFixture(), [
        // Body row 2, column 1 is empty.
        (const Offset(150, 90), _cell(2, 1, end: true)),
        (const Offset(150, 81), _cell(2, 1, end: true)),
        // Header column 2 is empty.
        (const Offset(320, 10), _cell(0, 2, end: true)),
      ]);
    });

    test('a point on a rule maps to the nearest cell text end', () {
      _expectHits(_hitFixture(), [
        // Row 1 (32-80) has its rule at 79-80; column 1 has 2 lines (32-80).
        (const Offset(150, 79), _cell(1, 1, end: true)),
        (const Offset(150, 79.5), _cell(1, 1, end: true)),
        (const Offset(150, 78.9), _cell(1, 1)),
        // Row 2 (80-104), rule at 103-104.
        (const Offset(50, 103), _cell(2, 0, end: true)),
        (const Offset(50, 102.9), _cell(2, 0)),
        // The last row has no rule: its last pixel is text.
        (const Offset(50, 127.5), _cell(3, 0)),
      ]);
      // A thicker rule covers more of the row: t = 2 is 78-80.
      const thick = TableMetrics(
        lineHeight: 24,
        hiddenLineHeight: 8,
        cellPadding: 8,
        ruleThickness: 2,
      );
      _expectHits(_hitFixture(metrics: thick), [
        (const Offset(150, 78.5), _cell(1, 1, end: true)),
        (const Offset(150, 77.9), _cell(1, 1)),
      ]);
    });

    test(
      'a point in the header band blank area maps to the nearest header cell text end',
      () {
        _expectHits(_hitFixture(), [
          // Top 4 px and bottom 4 px of the band (0-32; text 4-28).
          (const Offset(50, 0), _cell(0, 0, end: true)),
          (const Offset(50, 3.9), _cell(0, 0, end: true)),
          (const Offset(50, 28), _cell(0, 0, end: true)),
          (const Offset(150, 31.9), _cell(0, 1, end: true)),
        ]);
        // A two-line header band (0-56): column 1 has one line (text 4-28),
        // so below it is blank; column 0 has two (text 4-52).
        final tall = TableLayout(
          columnWidths: const [100, 200, 50],
          headerLines: const [2, 1, 1],
          bodyLines: const [
            [1, 1, 1],
          ],
          metrics: _exact,
        );
        _expectHits(tall, [
          (const Offset(50, 40), _cell(0, 0)),
          (const Offset(150, 40), _cell(0, 1, end: true)),
          (const Offset(150, 27.9), _cell(0, 1)),
          (const Offset(50, 52), _cell(0, 0, end: true)),
          (const Offset(50, 56), _cell(1, 0)),
        ]);
      },
    );

    test(
      'a point below its own text in a taller row maps to that cell text end',
      () {
        _expectHits(_hitFixture(), [
          // Row 1 is 48 high (column 1 has 2 lines); column 0 has 1 (32-56).
          (const Offset(50, 55.9), _cell(1, 0)),
          (const Offset(50, 56), _cell(1, 0, end: true)),
          (const Offset(50, 70), _cell(1, 0, end: true)),
          (const Offset(320, 60), _cell(1, 2, end: true)),
        ]);
      },
    );

    test(
      'points left of the grid and right of the last column clamp to the first and last column',
      () {
        _expectHits(_hitFixture(), [
          (const Offset(-10, 40), _cell(1, 0, end: true)),
          (const Offset(-0.5, 10), _cell(0, 0, end: true)),
          (const Offset(350, 40), _cell(1, 2, end: true)),
          (const Offset(1000, 110), _cell(3, 2, end: true)),
          (const Offset(349.9, 40), _cell(1, 2, end: true)),
          // Column edges: x = 100 is column 1, x = 300 column 2.
          (const Offset(99.9, 40), _cell(1, 0, end: true)),
          (const Offset(300, 110), _cell(3, 2, end: true)),
          (const Offset(299.9, 110), _cell(3, 1, end: true)),
        ]);
      },
    );

    test(
      'points above and below the grid clamp to the header and the last body row',
      () {
        _expectHits(_hitFixture(), [
          (const Offset(50, -5), _cell(0, 0, end: true)),
          (const Offset(50, 31.9), _cell(0, 0, end: true)),
          (const Offset(50, 128), _cell(3, 0, end: true)),
          (const Offset(150, 500), _cell(3, 1, end: true)),
        ]);
        // A header-only table clamps below to the header.
        final headerOnly = TableLayout(
          columnWidths: const [100, 200],
          headerLines: const [1, 1],
          bodyLines: const [],
          metrics: _exact,
        );
        _expectHits(headerOnly, [
          (const Offset(50, 32), _cell(0, 0, end: true)),
          (const Offset(150, 100), _cell(0, 1, end: true)),
          (const Offset(50, 10), _cell(0, 0)),
        ]);
      },
    );
  });

  group('offset mapping (AC D13)', () {
    // Header `one | two`, delimiter, a body row with two dropped cells and
    // a body row with fewer cells than the header.
    const text = 'one | two\n--- | ---\n| x | yy | extra | more |\n| z |';
    final src = _source(text);

    TableCellTarget at(int offset, {int headerCount = 2}) => tableOffsetTarget(
      offset,
      rowLines: src.rowLines,
      delimiterLine: src.delimiterLine,
      rowCells: src.rowCells,
      headerCount: headerCount,
    );

    const band = TableCellTarget(row: 0, column: 0, headerBand: true);

    test('an offset in the delimiter line maps to the header band', () {
      final delimiter = text.indexOf('---');
      for (final offset in [delimiter, delimiter + 4, delimiter + 9]) {
        expect(at(offset), band, reason: 'offset $offset');
      }
      // The header line's end is still the header row.
      expect(at(text.indexOf('two') + 3), _cell(0, 1));
      // The next line starts body row 1.
      expect(at(text.indexOf('| x')), _cell(1, 0));

      // The caret shows in the header band: the first header cell's content
      // rect, never zero-height.
      final layout = _hitFixture();
      final caret = layout.delimiterCaretRect;
      expect(caret, layout.contentRect(0, 0));
      expect(caret.height, greaterThan(0));
      expect(caret.top, greaterThanOrEqualTo(0));
      expect(caret.bottom, lessThanOrEqualTo(layout.bandHeight));
    });

    test(
      'an offset in a dropped cell maps to the end of that row last drawn cell',
      () {
        final extra = text.indexOf('extra');
        final more = text.indexOf('more');
        for (final offset in [extra, extra + 2, more, more + 4]) {
          expect(at(offset), _cell(1, 1, end: true), reason: 'offset $offset');
        }
        // The last drawn cell itself (column 1) is not flagged.
        final yy = text.indexOf('yy');
        expect(at(yy), _cell(1, 1));
        expect(at(yy + 2), _cell(1, 1));
        // With three header columns, `extra` is drawn and `more` is dropped.
        expect(at(extra, headerCount: 3), _cell(1, 2));
        expect(at(more, headerCount: 3), _cell(1, 2, end: true));
      },
    );

    test('an offset in a drawn cell maps to that cell', () {
      expect(at(text.indexOf('one')), _cell(0, 0));
      expect(at(text.indexOf('one') + 2), _cell(0, 0));
      expect(at(text.indexOf('two')), _cell(0, 1));
      expect(at(text.indexOf('x')), _cell(1, 0));
      expect(at(text.indexOf('z')), _cell(2, 0));
      // Past a short row last cell (on its closing pipe): that cell.
      expect(at(text.length), _cell(2, 0));
      // Before the first cell (on the leading pipe): cell 0.
      expect(at(text.indexOf('| z')), _cell(2, 0));
    });
  });

  group('metrics are parameters (AC D21)', () {
    test('non default metrics give results built from them', () {
      // Text scale 1.2, built at run time: L 27.54, H 9.6, c 9.72, t 1.
      final scale = [1.0, 1.2].last;
      final metrics = TableMetrics(
        lineHeight: 22.95 * scale,
        hiddenLineHeight: 8 * scale,
        cellPadding: 8.1 * scale,
        ruleThickness: 1,
      );
      expect(metrics.lineHeight, _px(27.54));

      // B2 table 2 at 1.2x: widths are 1.2x the text-scale-1 widths.
      final base = tableColumnWidths(
        _glyphs(const [27, 14, 25, 28, 5, 4], const [9, 8, 13, 9, 5, 4], const [
          false,
          false,
          false,
          false,
          true,
          true,
        ]),
        availableWidth: 650,
        cellPadding: 8.1,
      );
      final scaled = tableColumnWidths(
        _glyphs(const [27, 14, 25, 28, 5, 4], const [9, 8, 13, 9, 5, 4], const [
          false,
          false,
          false,
          false,
          true,
          true,
        ], c: metrics.cellPadding),
        availableWidth: 650 * scale,
        cellPadding: metrics.cellPadding,
      );
      _expectWidths(scaled, [for (final w in base) w * scale], eps: 1e-6);
      expect(scaled[4], _px(7 * 9.72));

      final layout = TableLayout(
        columnWidths: scaled,
        headerLines: const [1, 1, 1, 1, 1, 1],
        bodyLines: const [
          [2, 1, 1, 1, 1, 1],
          [1, 2, 1, 1, 1, 1],
          [1, 1, 2, 1, 1, 1],
        ],
        metrics: metrics,
      );
      expect(layout.bandHeight, _px(37.14));
      expect(layout.rowTop(1), _px(37.14));
      expect(layout.rowHeight(1), _px(55.08));
      expect(layout.height, _px(37.14 + 3 * 55.08));
      expect(layout.height, _px(168.65 * scale));
      expect(layout.width, _px(780));
      _expectRect(layout.rules.first, 0, 37.14 + 55.08 - 1, 780, 37.14 + 55.08);
      // Padding 9.72 left and right; header inset H / 2 = 4.8.
      final x = layout.columnLeft(1);
      _expectRect(
        layout.contentRect(0, 1),
        x + 9.72,
        4.8,
        x + scaled[1] - 9.72,
        37.14 - 4.8,
      );
      _expectRect(
        layout.contentRect(1, 1),
        x + 9.72,
        37.14,
        x + scaled[1] - 9.72,
        37.14 + 55.08,
      );
      expect(tableRevealDelta(metrics), _px(17.94));
      // Hit mapping uses the scaled inset: header top 4.8 px is blank.
      expect(layout.hitTest(Offset(x + 20, 4.7)), _cell(0, 1, end: true));
      expect(layout.hitTest(Offset(x + 20, 4.9)), _cell(0, 1));
      expect(layout.hitTest(Offset(x + 9.6, 50)), _cell(1, 1, end: true));
    });

    test(
      'table_geometry.dart has no literal design numbers and imports no Flutter',
      () {
        final file = File('lib/src/editor/table_geometry.dart');
        expect(file.existsSync(), isTrue);
        final lines = file.readAsLinesSync();
        final code = lines
            .map((l) => l.contains('//') ? l.substring(0, l.indexOf('//')) : l)
            .join('\n');
        final literal = RegExp(
          r'(?<![\w.])(22\.95|30\.95|14\.95|53\.9|8\.1|13\.5|0\.6|8(\.0+)?)(?![\w.])',
        );
        expect(
          literal.allMatches(code).map((m) => m.group(0)).toList(),
          isEmpty,
          reason: 'every number comes from a parameter (D21)',
        );
        // No ternary max/min (TD8): no `? a : b` comparisons of widths.
        final imports = lines
            .map((l) => l.trim())
            .where((l) => l.startsWith('import ') || l.startsWith('export '))
            .toList();
        for (final line in imports) {
          expect(
            line.startsWith("import 'dart:math'") ||
                line.startsWith("import 'dart:ui'"),
            isTrue,
            reason: 'only dart:math and dart:ui value types: $line',
          );
        }
      },
    );
  });
}
