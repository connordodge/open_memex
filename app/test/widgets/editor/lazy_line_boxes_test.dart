// WI #126 (Spec #122 R14, R15, R35; TD1; rulings D1, D4): lazy, range-local
// line-box geometry.
//
// `RenderEditableLineBoxes` and `RenderParagraphLineBoxes` read the laid-out
// render object's own painter for the requested lines only, cache per line
// per render object (valid until it lays out again, under a `LineBoxEpoch`),
// and answer exactly what main's whole-text measurement answered. Main's
// measurement is the oracle (`test/support/line_box_oracle.dart`).
//
// Every row kind is measured in the real pumped editor (the theme's strut and
// even leading; adapter lesson), and again as a `RichText` replica of each
// row's span. Each check runs the range-local queries cold (no `lines` read
// first) and asserts they walked no line and laid out no fresh copy, then
// compares `lines` too.
//
// The font-load tests run last: a loaded font stays for the rest of the file.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';

import '../../support/app_harness.dart' show pumpFrames;
import '../../support/editor_rows_probe.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/line_box_oracle.dart';
import '../../support/long_note_fixtures.dart';
import '../../support/perf_counters.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';

// ------------------------------------------------------------------ notes

/// A wrapping N5 line (about 220 characters).
final String _wi126N5Line = longNote(
  LongNoteKind.n5PlainLongLines120k,
).lines[1];

const _wi126Heading = '## A heading line';
const _wi126Decorated =
    'Decorated `code span` and [[Linked note]] and **bold** text.';

/// One note holding every row kind. Rows (segment 0): 0 prose (with a
/// wrapping N5 line, a blank line and a heading), 1 item, 2 nested item,
/// 3 task, 4 numbered, 5 quote, 6 code, 7 table, 8 decorated prose, 9 empty
/// item, 10 prose.
String get _wi126KindsBody => [
  'Prose line one with words.',
  _wi126N5Line,
  '',
  _wi126Heading,
  'Prose after the heading.',
  '- an item line',
  '  - a nested item line',
  '- [ ] a task line',
  '1. a numbered line',
  '> a quote line',
  '```',
  'let x = 1;',
  '```',
  '| a | b |',
  '|---|---|',
  '| c | d |',
  _wi126Decorated,
  '- ',
  'Tail prose.',
].join('\n');

const _wi126KindsRows = [
  RowKind.prose,
  RowKind.bullet,
  RowKind.bullet,
  RowKind.task,
  RowKind.numbered,
  RowKind.quote,
  RowKind.code,
  RowKind.table,
  RowKind.prose,
  RowKind.bullet,
  RowKind.prose,
];

// ---------------------------------------------------------------- helpers

/// Pumps the editor on [body] and returns nothing; rows are read through
/// the rows host.
Future<SpellingEditorHarness> _wi126PumpEditor(
  WidgetTester tester,
  String body,
) async {
  final e = await pumpSpellingEditor(tester, body: body);
  await pumpFrames(tester);
  return e;
}

/// The laid-out field of row [row] of segment [segment]: the
/// [RenderEditable] under the segment whose text is the row's text (a
/// rendered table's field is mounted offstage and still laid out).
RenderEditable _wi126RowEditable(WidgetTester tester, int segment, int row) {
  final text = rowTextOf(tester, segment, row);
  final found = <RenderEditable>[];
  void visit(RenderObject node) {
    if (node is RenderEditable) {
      if (node.plainText == text && node.hasSize) found.add(node);
      return;
    }
    node.visitChildren(visit);
  }

  visit(tester.renderObject(find.byKey(textSegmentKey(segment))));
  if (found.length != 1) {
    throw TestFailure(
      'expected one laid-out field with row $segment-$row\'s text, '
      'found ${found.length}',
    );
  }
  return found.single;
}

/// The offset nearest [point] as main answered it, for either kind of box.
int _wi126MainOffsetAt(RenderBox box, Offset point) => switch (box) {
  final RenderEditable e =>
    e.getPositionForPoint(e.localToGlobal(point)).offset,
  final RenderParagraph p => p.getPositionForOffset(point).offset,
  _ => throw ArgumentError(box),
};

/// The queries a check makes over the oracle lines touching `[from, to)`.
({List<int> offsets, List<TextRange> ranges, List<Offset> points})
_wi126Queries(
  LineBoxOracle oracle,
  int length,
  double width,
  int from,
  int to,
) {
  final lines = [
    for (final l in oracle.lines)
      if (l.range.end >= from && l.range.start <= to) l,
  ];
  // A long text: its first, middle and last few lines.
  final sampled = lines.length <= 12
      ? lines
      : [
          ...lines.take(4),
          ...lines.skip(lines.length ~/ 2 - 2).take(4),
          ...lines.skip(lines.length - 4),
        ];
  final offsets = <int>{from, to};
  final ranges = <TextRange>{TextRange(start: from, end: to)};
  final points = <Offset>{};
  for (final (i, l) in sampled.indexed) {
    final s = l.range.start;
    final e = l.range.end;
    offsets.addAll({s, if (s + 1 <= e) s + 1, (s + e) ~/ 2, e});
    if (e > s) ranges.add(TextRange(start: s, end: e));
    if (e - s > 4) ranges.add(TextRange(start: s + 1, end: s + 4));
    if (e < length) {
      ranges.add(TextRange(start: math.max(s, e - 1), end: e + 1));
    }
    if (i + 1 < sampled.length) {
      final next = sampled[i + 1];
      final a = (s + e) ~/ 2;
      final b = (next.range.start + next.range.end) ~/ 2;
      if (b > a) ranges.add(TextRange(start: a, end: b));
    }
    final y = (l.top + l.bottom) / 2;
    points.addAll({Offset(2, y), Offset(width / 2, y), Offset(width + 40, y)});
  }
  if (to >= length) offsets.addAll({length, length + 3});
  ranges.add(TextRange(start: length > 2 ? length - 2 : 0, end: length + 5));
  return (
    offsets: offsets.toList(),
    ranges: [
      for (final r in ranges)
        if (r.start >= 0 && !r.isCollapsed) r,
    ],
    points: points.toList(),
  );
}

/// Asserts that [lazy] (a fresh source over [box]) answers every query over
/// `[from, to)` (default: the whole text) exactly as main's measurement did:
/// the range-local queries first, cold, with no line walk and no fresh text
/// layout ([walks] and [measures] are its counters' names), then `lines`.
void _wi126ExpectMatchesMain({
  required LineBoxSource Function() lazy,
  required LineBoxOracle oracle,
  required RenderBox box,
  required int length,
  required String walks,
  required String measures,
  int from = 0,
  int? to,
  String label = '',
  bool baselines = true,
}) {
  // Baselines of a strut or height behaviour other than the editor's may
  // differ from main's (the class docs), so those checks leave them out.
  Object key(LineBox l) => baselines
      ? lineKey(l)
      : (start: l.range.start, end: l.range.end, top: l.top, bottom: l.bottom);
  final q = _wi126Queries(oracle, length, box.size.width, from, to ?? length);
  final before = PerfCounters.snapshot();
  final source = lazy();
  for (final o in q.offsets) {
    expect(
      key(source.lineAt(o)),
      key(oracle.lineAt(o)),
      reason: '$label lineAt($o)',
    );
  }
  for (final r in q.ranges) {
    expect(
      lazy().boxesFor(r),
      oracle.boxesFor(r),
      reason: '$label boxesFor(${r.start}, ${r.end})',
    );
  }
  for (final o in q.offsets) {
    final caret = lazy().caretRect(o);
    expect(caret, oracle.caretRect(o), reason: '$label caretRect($o)');
    expect(caret.height, greaterThan(0), reason: '$label caret never flat');
  }
  for (final p in q.points) {
    expect(
      source.offsetAt(p),
      _wi126MainOffsetAt(box, p),
      reason: '$label offsetAt($p)',
    );
  }
  final d = PerfCounters.delta(before);
  expect(
    d[walks],
    0,
    reason: '$label range-local queries walked every line ($walks)',
  );
  expect(
    d[measures],
    0,
    reason: '$label range-local queries laid out a fresh copy ($measures)',
  );
  expect(
    [for (final l in lazy().lines) key(l)],
    [for (final l in oracle.lines) key(l)],
    reason: '$label lines',
  );
}

/// [_wi126ExpectMatchesMain] over a field.
void _wi126ExpectFieldMatchesMain(
  RenderEditable editable, {
  int from = 0,
  int? to,
  String label = '',
  bool baselines = true,
}) {
  final oracle = LineBoxOracle.editable(editable);
  try {
    _wi126ExpectMatchesMain(
      lazy: () => RenderEditableLineBoxes(editable),
      oracle: oracle,
      box: editable,
      length: editable.plainText.length,
      walks: 'editableLineWalks',
      measures: 'editableLineMeasures',
      from: from,
      to: to,
      label: label,
      baselines: baselines,
    );
  } finally {
    oracle.dispose();
  }
}

/// [_wi126ExpectMatchesMain] over a paragraph.
void _wi126ExpectParagraphMatchesMain(
  RenderParagraph paragraph, {
  String label = '',
  bool baselines = true,
}) {
  final oracle = LineBoxOracle.paragraph(paragraph);
  try {
    _wi126ExpectMatchesMain(
      lazy: () => RenderParagraphLineBoxes(paragraph),
      oracle: oracle,
      box: paragraph,
      length: paragraph.text.toPlainText().length,
      walks: 'paragraphLineWalks',
      measures: 'paragraphLineMeasures',
      label: label,
      baselines: baselines,
    );
  } finally {
    oracle.dispose();
  }
}

/// Pumps [child] at the top left of a [width] wide column.
Future<void> _wi126PumpAt(WidgetTester tester, double width, Widget child) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

/// A field under a [LineBoxEpoch], laid out as an editor row's field is
/// (multi-line, max-height selection boxes).
Widget _wi126Field(
  TextEditingController controller, {
  int? maxLines,
  ScrollController? scroll,
}) => LineBoxEpoch(
  child: TextField(
    controller: controller,
    maxLines: maxLines,
    scrollController: scroll,
    selectionHeightStyle: ui.BoxHeightStyle.max,
  ),
);

RenderEditable _wi126OnlyEditable(WidgetTester tester) =>
    findRenderEditable(tester.renderObject(find.byType(TextField)))!;

/// A controller whose span colour changes without its text: a paint-only
/// span swap.
class _Wi126TintController extends TextEditingController {
  _Wi126TintController({super.text});

  Color tint = const Color(0xFF101010);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => TextSpan(
    style: (style ?? const TextStyle()).copyWith(color: tint),
    text: text,
  );

  void retint(Color color) {
    tint = color;
    notifyListeners();
  }
}

/// Plain lines `<tag> <i>`.
String _wi126Lines(String tag, int count) => [
  for (var i = 0; i < count; i++) '$tag line $i with a few words',
].join('\n');

/// Every query's answer from a fresh source, for comparing two moments.
({List<Rect> rects, List<Rect> carets, List<Object> lines}) _wi126Answers(
  LineBoxSource Function() lazy,
  List<TextRange> ranges,
  List<int> offsets,
) => (
  rects: [for (final r in ranges) ...lazy().boxesFor(r)],
  carets: [for (final o in offsets) lazy().caretRect(o)],
  lines: [for (final o in offsets) lineKey(lazy().lineAt(o))],
);

/// Lines of different lengths, so alignment, direction and scale move the
/// boxes (and the last line wraps in a narrow box).
const _wi126Varied =
    'short\n'
    'a somewhat longer line of plain words here\n'
    'mid length line\n'
    'x\n'
    'a final line that is long enough to wrap in a narrow field box';

/// A field with the layout inputs that live outside its span and its
/// constraints (scaler, strut, alignment, direction, height behaviour), as a
/// row's field is laid out.
Widget _wi126InputField(
  TextEditingController controller, {
  double scale = 1,
  StrutStyle? strut,
  TextAlign align = TextAlign.start,
  TextDirection? direction,
  TextHeightBehavior behavior = const TextHeightBehavior(),
}) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: DefaultTextHeightBehavior(
      textHeightBehavior: behavior,
      child: LineBoxEpoch(
        child: TextField(
          controller: controller,
          maxLines: null,
          style: const TextStyle(fontSize: 14, height: 2),
          strutStyle: strut,
          textAlign: align,
          textDirection: direction,
          selectionHeightStyle: ui.BoxHeightStyle.max,
        ),
      ),
    ),
  ),
);

/// A paragraph with the same inputs, plus the width basis.
Widget _wi126InputParagraph({
  double scale = 1,
  StrutStyle? strut,
  TextAlign align = TextAlign.start,
  TextDirection direction = TextDirection.ltr,
  TextWidthBasis basis = TextWidthBasis.parent,
  TextHeightBehavior? behavior,
}) => LineBoxEpoch(
  child: Align(
    alignment: Alignment.topLeft,
    child: RichText(
      key: const Key('wi126-input-paragraph'),
      text: const TextSpan(
        text: _wi126Varied,
        style: TextStyle(fontSize: 14, height: 2, color: Color(0xFF101010)),
      ),
      textScaler: TextScaler.linear(scale),
      strutStyle: strut,
      textAlign: align,
      textDirection: direction,
      textWidthBasis: basis,
      textHeightBehavior: behavior,
    ),
  ),
);

/// The paragraph inputs of a field, kept after the field is gone.
typedef _Wi126Replica = ({
  InlineSpan span,
  StrutStyle? strut,
  TextScaler scaler,
  TextAlign align,
  TextDirection direction,
  Locale? locale,
});

_Wi126Replica _wi126ReplicaOf(RenderEditable e) => (
  span: e.text!,
  strut: e.strutStyle,
  scaler: e.textScaler,
  align: e.textAlign,
  direction: e.textDirection,
  locale: e.locale,
);

/// A [RichText] replica of a row's span, [width] wide (a replica of a
/// row's paragraph at another wrap).
Future<RenderParagraph> _wi126PumpReplica(
  WidgetTester tester,
  _Wi126Replica replica,
  double width,
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
              key: const Key('wi126-wrap-replica'),
              text: replica.span,
              strutStyle: replica.strut,
              textScaler: replica.scaler,
              textAlign: replica.align,
              textDirection: replica.direction,
              locale: replica.locale,
            ),
          ),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderParagraph>(
    find.byKey(const Key('wi126-wrap-replica')),
  );
}

/// A field in the platform's own selection height style (the Source
/// surface's field), or in max height (a row's field).
Widget _wi126StyledField(TextEditingController c, {required bool max}) =>
    LineBoxEpoch(
      child: TextField(
        controller: c,
        maxLines: null,
        selectionHeightStyle: max
            ? ui.BoxHeightStyle.max
            : ui.BoxHeightStyle.tight,
      ),
    );

const _wi126WrapLine =
    'A paragraph long enough to wrap over several lines in this narrow box.';

void main() {
  holdFontFetches();

  setUp(PerfCounters.reset);

  // -------------------------------------------------- every row kind (AC1)

  group('every row kind measures as main', () {
    for (final (name, row, part) in <(String, int, String?)>[
      ('a prose row measures exactly as main', 0, null),
      ('a heading line measures exactly as main', 0, _wi126Heading),
      ('a wrapped N5 line measures exactly as main', 0, '_n5'),
      ('an item row measures exactly as main', 1, null),
      ('a nested item row measures exactly as main', 2, null),
      ('a task row measures exactly as main', 3, null),
      ('a numbered row measures exactly as main', 4, null),
      ('a quote row measures exactly as main', 5, null),
      ('a code row measures exactly as main', 6, null),
      ('a table row field measures exactly as main', 7, null),
      ('a decorated row measures exactly as main', 8, null),
      ('an empty row measures exactly as main', 9, null),
    ]) {
      testWidgets(name, (tester) async {
        await _wi126PumpEditor(tester, _wi126KindsBody);
        final host = rowsHostOf(tester);
        expect(
          [for (var i = 0; i < host.rowCount; i++) host.rowSpec(i)!.kind],
          _wi126KindsRows,
          reason: 'the kinds note splits into the rows this file expects',
        );
        final editable = _wi126RowEditable(tester, 0, row);
        final text = editable.plainText;
        var from = 0;
        int? to;
        if (part != null) {
          final needle = part == '_n5' ? _wi126N5Line : part;
          from = text.indexOf(needle);
          expect(from, isNonNegative, reason: 'row $row holds $needle');
          to = from + needle.length;
        }
        if (part == '_n5') {
          final oracle = LineBoxOracle.editable(editable);
          addTearDown(oracle.dispose);
          final wrapped = oracle.lines.where(
            (l) => l.range.start >= from && l.range.end <= to!,
          );
          expect(
            wrapped.length,
            greaterThan(1),
            reason: 'the N5 line wraps in the reading column',
          );
        }
        _wi126ExpectFieldMatchesMain(editable, from: from, to: to, label: name);
      });
    }

    testWidgets('a row revealed by the caret measures exactly as main', (
      tester,
    ) async {
      await _wi126PumpEditor(tester, _wi126KindsBody);
      // The caret in the decorated row reveals its markers: a new layout.
      await activateRow(tester, 0, 8, offset: 12);
      await pumpFrames(tester);
      _wi126ExpectFieldMatchesMain(
        _wi126RowEditable(tester, 0, 8),
        label: 'revealed',
      );
    });

    testWidgets('every wrapped line of the N5 note measures exactly as main', (
      tester,
    ) async {
      final note = longNote(LongNoteKind.n5PlainLongLines120k);
      await _wi126PumpEditor(tester, note.text);
      final editable = _wi126RowEditable(tester, 0, 0);
      _wi126ExpectFieldMatchesMain(editable, label: 'N5');
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('a paragraph of every row kind span measures exactly as main', (
      tester,
    ) async {
      await _wi126PumpEditor(tester, _wi126KindsBody);
      final host = rowsHostOf(tester);
      final replicas = <Widget>[];
      for (var i = 0; i < host.rowCount; i++) {
        final e = _wi126RowEditable(tester, 0, i);
        replicas.add(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              // The field lays its text out 1 + cursorWidth narrower.
              width: e.constraints.maxWidth - 1 - e.cursorWidth,
              child: LineBoxEpoch(
                child: RichText(
                  key: ValueKey('wi126-replica-$i'),
                  text: e.text!,
                  strutStyle: e.strutStyle,
                  textScaler: e.textScaler,
                  textAlign: e.textAlign,
                  textDirection: e.textDirection,
                  locale: e.locale,
                ),
              ),
            ),
          ),
        );
      }
      final count = host.rowCount;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: replicas,
            ),
          ),
        ),
      );
      for (var i = 0; i < count; i++) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byKey(ValueKey('wi126-replica-$i')),
        );
        _wi126ExpectParagraphMatchesMain(
          paragraph,
          label: 'replica of row $i (${_wi126KindsRows[i].name})',
        );
      }
    });
  });

  // ---------------------------------------------------- invalidation (AC7)

  group('the per-line cache follows layout, not paint', () {
    testWidgets('a paint-only span change of a field performs no new measure', (
      tester,
    ) async {
      final c = _Wi126TintController(text: _wi126Lines('tint', 8));
      addTearDown(c.dispose);
      await _wi126PumpAt(tester, 260, _wi126Field(c));
      final editable = _wi126OnlyEditable(tester);
      final ranges = [
        const TextRange(start: 2, end: 9),
        const TextRange(start: 40, end: 70),
      ];
      const offsets = [0, 33, 90];
      lazy() => RenderEditableLineBoxes(editable);
      // Warm: every query once at this layout.
      lazy().lines;
      final warm = _wi126Answers(lazy, ranges, offsets);
      final size = editable.size;
      c.retint(const Color(0xFFD02020));
      await tester.pump();
      expect(
        (editable.text!.style!.color, editable.size),
        (const Color(0xFFD02020), size),
        reason: 'the span changed colour only',
      );
      final before = PerfCounters.snapshot();
      final again = _wi126Answers(lazy, ranges, offsets);
      lazy().lines;
      final d = PerfCounters.delta(before);
      expect(
        (
          d['editableLineWalks'],
          d['editableLineSpans'],
          d['editableLineMeasures'],
        ),
        (0, 0, 0),
        reason: 'walks, spans, measures after a paint-only change',
      );
      expect(again.rects, warm.rects);
      expect(again.carets, warm.carets);
      expect(again.lines, warm.lines);
    });

    testWidgets(
      'a paint-only span change of a paragraph performs no new measure',
      (tester) async {
        Widget paragraph(Color color) => LineBoxEpoch(
          child: RichText(
            key: const Key('wi126-tint-paragraph'),
            text: TextSpan(
              text: _wi126Lines('tint', 8),
              style: TextStyle(fontSize: 14, height: 1.5, color: color),
            ),
          ),
        );
        await _wi126PumpAt(tester, 260, paragraph(const Color(0xFF101010)));
        final p = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('wi126-tint-paragraph')),
        );
        final ranges = [
          const TextRange(start: 2, end: 9),
          const TextRange(start: 40, end: 70),
        ];
        const offsets = [0, 33, 90];
        lazy() => RenderParagraphLineBoxes(p);
        lazy().lines;
        final warm = _wi126Answers(lazy, ranges, offsets);
        await _wi126PumpAt(tester, 260, paragraph(const Color(0xFFD02020)));
        expect(p.text.style!.color, const Color(0xFFD02020));
        final before = PerfCounters.snapshot();
        final again = _wi126Answers(lazy, ranges, offsets);
        lazy().lines;
        final d = PerfCounters.delta(before);
        expect(
          (
            d['paragraphLineWalks'],
            d['paragraphLineSpans'],
            d['paragraphLineMeasures'],
          ),
          (0, 0, 0),
          reason: 'walks, spans, measures after a paint-only change',
        );
        expect(again.rects, warm.rects);
        expect(again.carets, warm.carets);
        expect(again.lines, warm.lines);
      },
    );

    testWidgets('a width change returns boxes from the new layout', (
      tester,
    ) async {
      final c = TextEditingController(text: _wi126Lines('width', 6));
      addTearDown(c.dispose);
      await _wi126PumpAt(tester, 320, _wi126Field(c));
      final editable = _wi126OnlyEditable(tester);
      final wide = RenderEditableLineBoxes(editable).lines.length;
      RenderEditableLineBoxes(
        editable,
      ).boxesFor(const TextRange(start: 3, end: 60));
      await _wi126PumpAt(tester, 180, _wi126Field(c));
      expect(identical(_wi126OnlyEditable(tester), editable), isTrue);
      _wi126ExpectFieldMatchesMain(editable, label: 'narrow');
      expect(
        RenderEditableLineBoxes(editable).lines.length,
        greaterThan(wide),
        reason: 'the narrower field wraps more',
      );
    });

    testWidgets('a text change returns boxes from the new layout', (
      tester,
    ) async {
      final c = TextEditingController(text: _wi126Lines('text', 6));
      addTearDown(c.dispose);
      await _wi126PumpAt(tester, 260, _wi126Field(c));
      final editable = _wi126OnlyEditable(tester);
      RenderEditableLineBoxes(editable).lines;
      RenderEditableLineBoxes(
        editable,
      ).boxesFor(const TextRange(start: 3, end: 60));
      c.text = 'inserted words at the start ${c.text}';
      await tester.pump();
      _wi126ExpectFieldMatchesMain(editable, label: 'after the edit');
    });

    testWidgets(
      'a keystroke in an editor row returns boxes from the new layout',
      (tester) async {
        final e = await _wi126PumpEditor(tester, _wi126KindsBody);
        final editable = _wi126RowEditable(tester, 0, 0);
        RenderEditableLineBoxes(editable).lines;
        await activateRow(tester, 0, 0, offset: 10);
        await e.robot.typeChars(' typed words that push the wrap further');
        await pumpFrames(tester);
        _wi126ExpectFieldMatchesMain(
          _wi126RowEditable(tester, 0, 0),
          label: 'after typing',
        );
      },
    );

    testWidgets(
      'a field scrolled inside its box shifts its boxes by the paint offset',
      (tester) async {
        final c = TextEditingController(text: _wi126Lines('scroll', 12));
        final scroll = ScrollController();
        addTearDown(c.dispose);
        addTearDown(scroll.dispose);
        await _wi126PumpAt(
          tester,
          260,
          _wi126Field(c, maxLines: 3, scroll: scroll),
        );
        final editable = _wi126OnlyEditable(tester);
        final top = RenderEditableLineBoxes(editable).lineAt(40).top;
        RenderEditableLineBoxes(
          editable,
        ).boxesFor(const TextRange(start: 35, end: 50));
        scroll.jumpTo(30);
        await tester.pump();
        expect(editable.offset.pixels, 30);
        _wi126ExpectFieldMatchesMain(editable, label: 'scrolled');
        expect(RenderEditableLineBoxes(editable).lineAt(40).top, top - 30);
      },
    );

    testWidgets(
      'a one-line field scrolled sideways shifts its rects by the paint offset',
      (tester) async {
        final c = TextEditingController(
          text: 'a single line far wider than its narrow field box here',
        );
        final scroll = ScrollController();
        addTearDown(c.dispose);
        addTearDown(scroll.dispose);
        await _wi126PumpAt(
          tester,
          120,
          _wi126Field(c, maxLines: 1, scroll: scroll),
        );
        final editable = _wi126OnlyEditable(tester);
        const range = TextRange(start: 20, end: 26);
        final left = RenderEditableLineBoxes(editable).boxesFor(range).single;
        scroll.jumpTo(40);
        await tester.pump();
        expect(editable.offset.pixels, 40);
        _wi126ExpectFieldMatchesMain(editable, label: 'sideways');
        expect(
          RenderEditableLineBoxes(editable).boxesFor(range).single.left,
          left.left - 40,
        );
      },
    );
  });

  // ------------------------- layout inputs besides the span (AC7, TD1)

  group('a changed layout input returns boxes from the new layout', () {
    for (final (name, build)
        in <(String, Widget Function(TextEditingController c, bool alt))>[
          (
            'a changed text scale returns boxes from the new layout for a field',
            (c, alt) => _wi126InputField(c, scale: alt ? 1.6 : 1),
          ),
          (
            'a changed strut returns boxes from the new layout for a field',
            (c, alt) => _wi126InputField(
              c,
              strut: alt
                  ? const StrutStyle(fontSize: 28, forceStrutHeight: true)
                  : null,
            ),
          ),
          (
            'a changed text alignment returns boxes from the new layout for a field',
            (c, alt) => _wi126InputField(
              c,
              align: alt ? TextAlign.right : TextAlign.start,
            ),
          ),
          (
            'a changed text direction returns boxes from the new layout for a field',
            (c, alt) => _wi126InputField(
              c,
              direction: alt ? TextDirection.rtl : TextDirection.ltr,
            ),
          ),
        ]) {
      testWidgets(name, (tester) async {
        final c = TextEditingController(text: _wi126Varied);
        addTearDown(c.dispose);
        await _wi126PumpAt(tester, 260, build(c, false));
        final editable = _wi126OnlyEditable(tester);
        final ranges = [
          TextRange(start: 0, end: c.text.length),
          const TextRange(start: 8, end: 30),
        ];
        final offsets = [0, 3, 20, 60, 100, c.text.length];
        lazy() => RenderEditableLineBoxes(editable);
        // Warm: every query once at this layout.
        lazy().lines;
        final warm = _wi126Answers(lazy, ranges, offsets);
        await _wi126PumpAt(tester, 260, build(c, true));
        expect(identical(_wi126OnlyEditable(tester), editable), isTrue);
        final oracle = LineBoxOracle.editable(editable);
        addTearDown(oracle.dispose);
        expect(
          [for (final r in ranges) ...oracle.boxesFor(r)],
          isNot(warm.rects),
          reason: 'the input moved the boxes, so a stale answer is wrong',
        );
        _wi126ExpectFieldMatchesMain(
          editable,
          label: name,
          baselines: !name.contains('strut'),
        );
      });
    }

    for (final (name, build) in <(String, Widget Function(bool alt))>[
      (
        'a changed text scale returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(scale: alt ? 1.6 : 1),
      ),
      (
        'a changed strut returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(
          strut: alt
              ? const StrutStyle(fontSize: 40, forceStrutHeight: true)
              : null,
        ),
      ),
      (
        'a changed text alignment returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(
          align: alt ? TextAlign.right : TextAlign.start,
        ),
      ),
      (
        'a changed text direction returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(
          direction: alt ? TextDirection.rtl : TextDirection.ltr,
        ),
      ),
      (
        'a changed height behaviour returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(
          behavior: alt
              ? const TextHeightBehavior(
                  applyHeightToFirstAscent: false,
                  applyHeightToLastDescent: false,
                )
              : null,
        ),
      ),
      (
        'a changed width basis returns boxes from the new layout for a paragraph',
        (alt) => _wi126InputParagraph(
          align: TextAlign.center,
          basis: alt ? TextWidthBasis.longestLine : TextWidthBasis.parent,
        ),
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _wi126PumpAt(tester, 260, build(false));
        final p = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('wi126-input-paragraph')),
        );
        final ranges = [
          const TextRange(start: 0, end: _wi126Varied.length),
          const TextRange(start: 8, end: 30),
        ];
        final offsets = [0, 3, 20, 60, 100, _wi126Varied.length];
        lazy() => RenderParagraphLineBoxes(p);
        lazy().lines;
        final warm = _wi126Answers(lazy, ranges, offsets);
        await _wi126PumpAt(tester, 260, build(true));
        expect(
          identical(
            tester.renderObject<RenderParagraph>(
              find.byKey(const Key('wi126-input-paragraph')),
            ),
            p,
          ),
          isTrue,
        );
        final oracle = LineBoxOracle.paragraph(p);
        addTearDown(oracle.dispose);
        expect(
          [for (final r in ranges) ...oracle.boxesFor(r)],
          isNot(warm.rects),
          reason: 'the input moved the boxes, so a stale answer is wrong',
        );
        _wi126ExpectParagraphMatchesMain(
          p,
          label: name,
          baselines: !name.contains('strut') && !name.contains('behaviour'),
        );
      });
    }
  });

  // -------------- the trickiest paths on varied text (AC1, TD1)

  group('the newest geometry paths measure as main on varied text', () {
    const wrapped = '$_wi126WrapLine $_wi126WrapLine';
    for (final (name, text, max) in <(String, String, bool)>[
      (
        'a field in the platform height style measures wrapped blank and trailing newline lines exactly as main',
        '# Title\n\n$wrapped\n\n\nTail line\n',
        false,
      ),
      (
        'a field in the platform height style ending in two blank lines measures exactly as main',
        'one\n\n',
        false,
      ),
      (
        'a field in the platform height style holding only a newline measures exactly as main',
        '\n',
        false,
      ),
      (
        'an empty field in the platform height style measures exactly as main',
        '',
        false,
      ),
      (
        'a row field ending in a newline measures exactly as main',
        '# Title\n\n$wrapped\n\n\nTail line\n',
        true,
      ),
      (
        'a row field ending in two blank lines measures exactly as main',
        'one\n\n',
        true,
      ),
      (
        'a row field holding only a newline measures exactly as main',
        '\n',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final c = TextEditingController(text: text);
        addTearDown(c.dispose);
        await _wi126PumpAt(tester, 200, _wi126StyledField(c, max: max));
        final editable = _wi126OnlyEditable(tester);
        final oracle = LineBoxOracle.editable(editable);
        addTearDown(oracle.dispose);
        if (text.contains(wrapped)) {
          expect(
            oracle.lines.length,
            greaterThan('\n'.allMatches(text).length + 1),
            reason: 'a long line wraps in the narrow box',
          );
        }
        if (text.endsWith('\n')) {
          expect(
            oracle.lines.last.range,
            TextRange.collapsed(text.length),
            reason: 'the empty last line is a line of its own',
          );
        }
        _wi126ExpectFieldMatchesMain(editable, label: name);
      });
    }

    testWidgets(
      'a Source mode note with wrapped blank and trailing newline lines measures exactly as main',
      (tester) async {
        final body = [
          '# Source title',
          '',
          List.filled(14, _wi126WrapLine).join(' '),
          '',
          '```',
          'let x = 1;',
          '```',
          '',
          'Tail line',
          '',
        ].join('\n');
        final e = await pumpSpellingEditor(tester, body: body, source: true);
        await pumpFrames(tester);
        final editable = findRenderEditable(
          tester.renderObject(e.sourceField),
        )!;
        expect(editable.plainText, endsWith('\n'));
        final oracle = LineBoxOracle.editable(editable);
        addTearDown(oracle.dispose);
        expect(
          oracle.lines.length,
          greaterThan('\n'.allMatches(editable.plainText).length + 1),
          reason: 'the long line wraps in the Source field',
        );
        _wi126ExpectFieldMatchesMain(editable, label: 'Source');
      },
    );

    testWidgets(
      'a decorated paragraph replica measures exactly as main at several wraps',
      (tester) async {
        await _wi126PumpEditor(
          tester,
          List.filled(3, _wi126Decorated).join(' '),
        );
        final replica = _wi126ReplicaOf(_wi126RowEditable(tester, 0, 0));
        final spans = <InlineSpan>[];
        replica.span.visitChildren((s) {
          spans.add(s);
          return true;
        });
        expect(
          spans.length,
          greaterThan(6),
          reason: 'the decorated row holds many styled and marker spans',
        );
        var wraps = 0;
        for (final width in <double>[
          70,
          110,
          150,
          190,
          230,
          270,
          330,
          400,
          520,
        ]) {
          final paragraph = await _wi126PumpReplica(tester, replica, width);
          final oracle = LineBoxOracle.paragraph(paragraph);
          wraps += oracle.lines.length;
          oracle.dispose();
          _wi126ExpectParagraphMatchesMain(
            paragraph,
            label: 'replica ${width}px',
          );
        }
        expect(wraps, greaterThan(9 * 2), reason: 'the replicas wrap');
      },
    );
  });

  // ------------------------------------------------------ placeholders (AC9)

  group('placeholders', () {
    testWidgets(
      'a test-only widget span in a paragraph gets a line box and rect of its laid-out placeholder',
      (tester) async {
        const placeholder = Key('wi126-placeholder');
        await _wi126PumpAt(
          tester,
          400,
          const LineBoxEpoch(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 14, height: 1.5),
                children: [
                  TextSpan(text: 'Before '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: SizedBox(key: placeholder, width: 40, height: 30),
                  ),
                  TextSpan(text: ' after\nsecond line'),
                ],
              ),
              key: Key('wi126-widget-span'),
            ),
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const Key('wi126-widget-span')),
            matching: find.byType(RichText),
          ),
        );
        final child = tester.renderObject<RenderBox>(find.byKey(placeholder));
        final laid = MatrixUtils.transformRect(
          child.getTransformTo(paragraph),
          Offset.zero & child.size,
        );
        expect(laid.size, const Size(40, 30));
        final boxes = RenderParagraphLineBoxes(paragraph);
        // 'Before ' is 0-6, the placeholder 7, ' after' 8-13, '\n' 14.
        final rects = boxes.boxesFor(const TextRange(start: 7, end: 8));
        final line = boxes.lineAt(7);
        expect(line.range, const TextRange(start: 0, end: 14));
        expect(rects, hasLength(1));
        expect(rects.single.left, moreOrLessEquals(laid.left));
        expect(rects.single.right, moreOrLessEquals(laid.right));
        expect(
          (rects.single.top, rects.single.bottom),
          (line.top, line.bottom),
        );
        expect(line.top, lessThanOrEqualTo(laid.top));
        expect(line.bottom, greaterThanOrEqualTo(laid.bottom));
        expect(boxes.caretRect(8).left, moreOrLessEquals(laid.right));
        expect(boxes.caretRect(7).left, moreOrLessEquals(laid.left));
        final lines = boxes.lines;
        expect(lines, hasLength(2));
        expect(lineKey(lines.first), lineKey(line));
        expect(lines.last.range, const TextRange(start: 15, end: 26));
        expect(lines.last.top, lines.first.bottom);
      },
    );
  });

  // ------------------------------------------------- every implementer (AC10)

  group('every line box source answers lineAt as its lines do', () {
    testWidgets('a segment of rows answers lineAt as its lines do', (
      tester,
    ) async {
      await _wi126PumpEditor(tester, _wi126KindsBody);
      final host = rowsHostOf(tester);
      final rows = host.lineBoxes()!;
      final lines = rows.lines;
      for (var o = 0; o <= host.text.length; o += 7) {
        expect(
          lineKey(rows.lineAt(o)),
          lineKey(lineHolding(lines, o)),
          reason: 'segment lineAt($o)',
        );
      }
      expect(lineKey(rows.lineAt(host.text.length)), lineKey(lines.last));
    });

    testWidgets('a rendered table grid answers lineAt as its lines do', (
      tester,
    ) async {
      await _wi126PumpEditor(tester, _wi126KindsBody);
      final grid = rowBoxesOf(tester, 0, 7);
      expect(grid, isNot(isA<RenderEditableLineBoxes>()));
      final lines = grid.lines;
      final length = rowTextOf(tester, 0, 7).length;
      for (var o = 0; o <= length; o++) {
        expect(
          lineKey(grid.lineAt(o)),
          lineKey(lineHolding(lines, o)),
          reason: 'grid lineAt($o)',
        );
      }
    });

    testWidgets('a block answers lineAt with its one line', (tester) async {
      await _wi126PumpAt(
        tester,
        200,
        const SizedBox(key: Key('wi126-block'), width: 120, height: 44),
      );
      final box = tester.renderObject<RenderBox>(
        find.byKey(const Key('wi126-block')),
      );
      final block = BlockLineBoxes(box, textLength: 5);
      for (final o in [0, 3, 5]) {
        expect(lineKey(block.lineAt(o)), lineKey(block.lines.single));
      }
      expect(block.lineAt(2).bottom, 44);
    });
  });

  // ------------------------------------------- font loads (AC7), run last

  group('a font load relays out and the next query follows it', () {
    testWidgets(
      'after a system fonts notification an editor row returns boxes from the new layout',
      (tester) async {
        await _wi126PumpEditor(tester, _wi126KindsBody);
        final editable = _wi126RowEditable(tester, 0, 0);
        const range = TextRange(start: 0, end: 5);
        final stale = RenderEditableLineBoxes(editable).boxesFor(range);
        RenderEditableLineBoxes(editable).lines;
        RenderEditableLineBoxes(editable).caretRect(9);
        final own = editable.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 5),
        );
        final family = editable.text!.style!.fontFamily!;
        final bytes = File(
          'assets/google_fonts/JetBrainsMono-Regular.ttf',
        ).readAsBytesSync();
        await tester.runAsync(
          () => (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load(),
        );
        await tester.pump();
        await pumpFrames(tester);
        expect(
          editable.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 5),
          ),
          isNot(own),
          reason: 'the field relaid out in the loaded font',
        );
        final fresh = RenderEditableLineBoxes(editable).boxesFor(range);
        expect(fresh, isNot(stale), reason: 'not the cached boxes');
        _wi126ExpectFieldMatchesMain(editable, label: 'after the font load');
      },
    );

    testWidgets(
      'after a system fonts notification a paragraph returns boxes from the new layout',
      (tester) async {
        await _wi126PumpAt(
          tester,
          300,
          LineBoxEpoch(
            child: RichText(
              key: const Key('wi126-late-font'),
              text: TextSpan(
                text: _wi126Lines('font', 5),
                style: const TextStyle(
                  fontFamily: 'Wi126LateFont',
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ),
        );
        final p = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('wi126-late-font')),
        );
        const range = TextRange(start: 0, end: 12);
        final stale = RenderParagraphLineBoxes(p).boxesFor(range);
        RenderParagraphLineBoxes(p).lines;
        final bytes = File(
          'assets/google_fonts/JetBrainsMono-Regular.ttf',
        ).readAsBytesSync();
        await tester.runAsync(
          () => (FontLoader(
            'Wi126LateFont',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load(),
        );
        await tester.pump();
        await tester.pump();
        final fresh = RenderParagraphLineBoxes(p).boxesFor(range);
        expect(fresh, isNot(stale), reason: 'not the cached boxes');
        _wi126ExpectParagraphMatchesMain(p, label: 'after the font load');
      },
    );
  });
}
