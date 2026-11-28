// WI #132 (Spec #122 Req 28, 29, TD5; ruling D7): an idle row lays out and
// renders exactly as its field would.
//
// Every test pumps the real note editor (`pumpSpellingEditor`, the theme's
// real strut and even leading) and compares one row in two states that
// differ only in which row is active:
// - with the segment unfocused, the row holding the caret is the active
//   row (Req 27), so putting the caret in row r makes r active and putting
//   it in the anchor row makes r idle, at the same (hidden) reveal state;
// - with the segment focused, a selection across rows keeps the active row
//   in the row it started from, so a selection from r into the next row and
//   the same selection reversed show r active and r idle at the same reveal
//   state and selection.
// Line boxes, glyph boxes, the text slot rect, every row's rect, the scroll
// offset, the span, strut and text scaler, the selection fill, squiggles,
// Find highlights and the marker column must be equal in both states.
//
// The widths: the window is resized (the text column follows it) to 3 px
// either side of the width where a row's wrapped line drops its last word
// (found by bisection on the real layout), skipping the knife edge itself.
//
// Rows are read through `wi132_idle_rows.dart` (the rows host's accessor);
// helpers carry the `_t132`/`wi132` prefix. Text is synthetic.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/note_reveal_pump.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi132_idle_rows.dart';
import '../../support/wi83_find_paint.dart';

// ------------------------------------------------------------------ text

const _t132Words = [
  'amber', 'birch', 'cedar', 'delta', 'ember', 'fjord', 'grove', 'heron', //
  'inlet', 'juniper', 'kelp', 'larch', 'maple', 'nectar', 'orchid', 'pebble',
];

/// [n] synthetic words, starting at word [from].
String _t132Run(int n, {int from = 0}) => [
  for (var i = 0; i < n; i++) _t132Words[(from + i) % _t132Words.length],
].join(' ');

/// One row of every kind the parity covers, separated by item rows so each
/// prose-kind line is its own row, ending in the anchor row.
final _t132Body = [
  'Prose line ${_t132Run(40)}',
  'Prose second line ${_t132Run(8, from: 3)}',
  '- Bullet item ${_t132Run(40, from: 1)}',
  '## Heading ${_t132Run(30, from: 2)}',
  '- [ ] Task item ${_t132Run(40, from: 3)}',
  '  - Nested item ${_t132Run(40, from: 4)}',
  '> Quote line ${_t132Run(40, from: 5)}',
  '```',
  'code line ${_t132Run(40, from: 6)}',
  '```',
  '- Separator one',
  '| Col a | Col b |',
  '|---|---|',
  '| cell one | cell two |',
  '- Separator two',
  'Decorated **bold words** and `code span` and [[Zeta Game]] then '
      '${_t132Run(30, from: 7)}',
  '- Separator three',
  '',
  '- Anchor item',
  '',
].join('\n');

/// The prefix of the anchor row (an item row that is never measured).
const _t132Anchor = '- Anchor item';

/// The prefix of the prose row, whose first line wraps.
const _t132Prose = 'Prose line';

// ---------------------------------------------------------------- pumping

Future<SpellingEditorHarness> _t132Pump(
  WidgetTester tester, {
  String? body,
  FakeSpellingService? spelling,
}) async {
  final e = await pumpSpellingEditor(
    tester,
    body: body ?? _t132Body,
    spelling: spelling,
  );
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
  return e;
}

/// The row holding the empty line before the anchor.
int _t132EmptyRow(WidgetTester tester) {
  final host = wi132Host(tester);
  final anchor = wi132RowOf(tester, _t132Anchor);
  final row = anchor - 1;
  final spec = host.rowSpec(row)!;
  expect(
    spec.kind,
    RowKind.prose,
    reason: 'fixture: the blank line is a prose row',
  );
  expect(
    spec.textEnd - spec.textStart,
    0,
    reason: 'fixture: the blank line row is empty',
  );
  return row;
}

/// Sets the window width to [width] (the height stays) and pumps.
Future<void> _t132Width(WidgetTester tester, double width) async {
  final size = tester.view.physicalSize;
  tester.view.physicalSize = Size(width, size.height);
  await tester.pump();
  await tester.pump();
}

/// The first visual line of row [row] that ends by wrapping (not at a line
/// break), or null when none does.
int? _t132WrappedLine(WidgetTester tester, int row) {
  final text = wi132RowText(tester, row);
  final lines = wi132Host(tester).rowBoxes(row)!.lines;
  for (var i = 0; i + 1 < lines.length; i++) {
    final end = lines[i].range.end;
    if (end < text.length && text[end] != '\n' && text[end] != '\r') return i;
  }
  return null;
}

/// The window width at which wrapped line [line] of row [row] drops its
/// last word: at or above it the line holds that word, below it the word
/// moves to the next line. Found by bisection on the laid-out row.
Future<double> _t132WrapWidth(WidgetTester tester, int row, int line) async {
  int endAt() => wi132Host(tester).rowBoxes(row)!.lines[line].range.end;
  var hi = tester.view.physicalSize.width;
  final full = endAt();
  var lo = hi;
  // Never below 1,000 px, where the editor toolbar starts to overflow.
  for (var i = 0; i < 7; i++) {
    lo -= 40;
    await _t132Width(tester, lo);
    if (endAt() < full) break;
  }
  expect(endAt(), lessThan(full), reason: 'fixture: the line wraps narrower');
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    await _t132Width(tester, mid);
    if (endAt() < full) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  await _t132Width(tester, hi);
  expect(endAt(), full, reason: 'fixture: the line holds its word at hi');
  return hi;
}

/// Puts the editor where the text column follows the window width (below
/// the 760 px reading width cap, above the width where the toolbar
/// overflows) and checks that it does.
Future<void> _t132Uncap(WidgetTester tester, int row) async {
  await _t132Width(tester, 1300);
  final before = wi132SlotRect(tester, row).width;
  await _t132Width(tester, 1290);
  final after = wi132SlotRect(tester, row).width;
  expect(
    after,
    moreOrLessEquals(before - 10, epsilon: 0.01),
    reason: 'fixture: the text column follows the window width',
  );
  await _t132Width(tester, 1300);
}

// ---------------------------------------------------------- the two states

/// What the row's text slot lays out with besides geometry: its span, strut
/// and text scaler (null for a block).
typedef _T132Text = ({
  InlineSpan span,
  StrutStyle? strut,
  TextScaler scaler,
  String plain,
});

_T132Text? _t132TextOf(WidgetTester tester, int row) {
  final boxes = wi132Host(tester).rowBoxes(row);
  return switch (boxes) {
    final RenderEditableLineBoxes f => (
      span: f.editable.text!,
      strut: f.editable.strutStyle,
      scaler: f.editable.textScaler,
      plain: f.editable.text!.toPlainText(),
    ),
    final RenderParagraphLineBoxes p => (
      span: p.paragraph.text,
      strut: p.paragraph.strutStyle,
      scaler: p.paragraph.textScaler,
      plain: p.paragraph.text.toPlainText(),
    ),
    _ => null,
  };
}

void _t132ExpectSameText(_T132Text? idle, _T132Text? active, String what) {
  expect(idle, isNotNull, reason: '$what: the idle row lays out text');
  expect(active, isNotNull, reason: '$what: the field lays out text');
  expect(idle!.plain, active!.plain, reason: '$what: the same text');
  expect(
    idle.span.compareTo(active.span),
    anyOf(RenderComparison.identical, RenderComparison.metadata),
    reason: '$what: the same spans and styles',
  );
  expect(idle.strut, active.strut, reason: '$what: the same strut');
  expect(idle.scaler, active.scaler, reason: '$what: the same text scaler');
}

/// With the segment unfocused: the caret in row [row] (it is the active
/// row) and then in the anchor row (it is idle); expects both states to lay
/// out row [row] alike. [table]: the row shows its grid.
Future<void> _t132ExpectUnfocusedParity(
  WidgetTester tester,
  int row,
  String what, {
  bool table = false,
}) async {
  final anchor = wi132RowOf(tester, _t132Anchor);
  await wi132Select(tester, wi132CaretIn(tester, row));
  wi132ExpectActive(
    tester,
    row,
    reason: '$what: unfocused, the row holding the caret',
  );
  final active = wi132Geometry(tester, row, table: table);
  final activeText = table ? null : _t132TextOf(tester, row);

  await wi132Select(tester, wi132CaretIn(tester, anchor));
  wi132ExpectActive(tester, anchor, reason: '$what: the caret left the row');
  if (table) {
    expect(
      wi132Host(tester).rowField(row),
      isNull,
      reason: '$what: an idle table row has no field',
    );
  } else {
    wi132ExpectIdle(tester, row, reason: what);
  }
  final idle = wi132Geometry(tester, row, table: table);
  wi132ExpectSameGeometry(idle, active, what);
  if (!table) _t132ExpectSameText(_t132TextOf(tester, row), activeText, what);
}

// ------------------------------------------------------------------ tests

void main() {
  holdFontFetches();

  group('idle row layout parity at a wrap point (AC2)', () {
    for (final (name, prefix, kind) in [
      (
        'an idle prose row lays out as its field at widths within 3 px of a wrap point',
        _t132Prose,
        RowKind.prose,
      ),
      (
        'an idle heading row lays out as its field at widths within 3 px of a wrap point',
        '## Heading',
        RowKind.prose,
      ),
      (
        'an idle item row lays out as its field at widths within 3 px of a wrap point',
        '- Bullet item',
        RowKind.bullet,
      ),
      (
        'an idle nested item row lays out as its field at widths within 3 px of a wrap point',
        '- Nested item',
        RowKind.bullet,
      ),
      (
        'an idle task row lays out as its field at widths within 3 px of a wrap point',
        '- [ ] Task item',
        RowKind.task,
      ),
      (
        'an idle quote row lays out as its field at widths within 3 px of a wrap point',
        '> Quote line',
        RowKind.quote,
      ),
      (
        'an idle code row lays out as its field at widths within 3 px of a wrap point',
        '```',
        RowKind.code,
      ),
      (
        'an idle table row lays out as its active row at widths within 3 px of a wrap point',
        '| Col a',
        RowKind.table,
      ),
      (
        'an idle decorated row lays out as its field at widths within 3 px of a wrap point',
        'Decorated',
        RowKind.prose,
      ),
      (
        'an idle empty row lays out as its field at widths within 3 px of a wrap point',
        '',
        RowKind.prose,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final row = prefix.isEmpty
            ? _t132EmptyRow(tester)
            : wi132RowOf(tester, prefix);
        expect(
          wi132Spec(tester, row).kind,
          kind,
          reason: 'fixture: "$prefix" is a ${kind.name} row',
        );
        final table = kind == RowKind.table;
        final prose = wi132RowOf(tester, _t132Prose);
        await wi132Unfocus(tester);
        await _t132Uncap(tester, prose);
        // The row's own wrapped line, else the prose row's (a grid or an
        // empty row has none): the whole note relays out at that width.
        final own = table ? null : _t132WrappedLine(tester, row);
        final wrapRow = own == null ? prose : row;
        final line = own ?? _t132WrappedLine(tester, prose);
        expect(line, isNotNull, reason: 'fixture: the prose row wraps');
        final wrap = await _t132WrapWidth(tester, wrapRow, line!);
        for (final d in const [-3.0, -2.0, -1.0, 1.0, 2.0, 3.0]) {
          await _t132Width(tester, wrap + d);
          await _t132ExpectUnfocusedParity(
            tester,
            row,
            '$name at ${d > 0 ? '+' : ''}$d px',
            table: table,
          );
        }
      });
    }

    testWidgets(
      'a table row keeps its block height whether idle or active (D7)',
      (tester) async {
        await _t132Pump(tester);
        final table = wi132RowOf(tester, '| Col a');
        final after = table + 1;
        await wi132Unfocus(tester);
        await wi132Select(tester, wi132CaretIn(tester, table));
        wi132ExpectActive(tester, table, reason: 'the caret row');
        final grid = tester.getRect(
          find.byKey(ValueKey('editor-table-0-$table')),
        );
        final next = wi132RowRect(tester, after);

        await wi132Select(
          tester,
          wi132CaretIn(tester, wi132RowOf(tester, _t132Anchor)),
        );
        expect(
          wi132Host(tester).rowField(table),
          isNull,
          reason: 'the table row is idle',
        );
        expect(
          tester.getRect(find.byKey(ValueKey('editor-table-0-$table'))),
          grid,
          reason: 'the grid keeps its rect',
        );
        expect(
          wi132RowRect(tester, after),
          next,
          reason: 'the row below does not move',
        );
      },
    );
  });

  group('changing a row between idle and active (AC2)', () {
    testWidgets(
      'changing a row between idle and active leaves the scroll offset and every row place unchanged',
      (tester) async {
        final body = [
          for (var i = 0; i < 160; i++)
            i.isEven
                ? '- Item $i ${_t132Run(6, from: i)}'
                : 'Prose $i ${_t132Run(20, from: i)}',
          '',
        ].join('\n');
        await _t132Pump(tester, body: body);
        final page = wi132Page(tester);
        page.jumpTo(page.maxScrollExtent / 2);
        await tester.pump();
        // A row near the viewport's middle and the one after it.
        final viewport = tester.getRect(
          find
              .ancestor(
                of: find.byKey(const ValueKey('text-segment-0')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final host = wi132Host(tester);
        var a = 0;
        for (var i = 0; i < host.rowCount; i++) {
          if (wi132RowRect(tester, i).top >= viewport.center.dy) {
            a = i;
            break;
          }
        }
        final b = a + 1;
        await wi132Activate(tester, a, wi132CaretIn(tester, a));
        wi132ExpectOnlyActive(tester, a);
        final pixels = page.pixels;
        final rows = [
          for (var i = 0; i < host.rowCount; i++) wi132RowRect(tester, i),
        ];
        final aGeometry = wi132Geometry(tester, a);

        await wi132Activate(tester, b, wi132CaretIn(tester, b));
        wi132ExpectOnlyActive(tester, b);
        expect(page.pixels, pixels, reason: 'the scroll offset is unchanged');
        for (var i = 0; i < host.rowCount; i++) {
          expect(
            wi132RowRect(tester, i),
            rows[i],
            reason: 'row $i keeps its place',
          );
        }
        wi132ExpectSameGeometry(
          wi132Geometry(tester, a),
          aGeometry,
          'the row that went idle',
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('markup and selection in idle rows (AC3)', () {
    testWidgets('an idle row shows its markup hidden', (tester) async {
      await _t132Pump(tester);
      final anchor = wi132RowOf(tester, _t132Anchor);
      final row = wi132RowOf(tester, 'Decorated');
      await wi132Activate(tester, anchor, wi132CaretIn(tester, anchor));
      wi132ExpectOnlyActive(tester, anchor);
      final text = wi132RowText(tester, row);
      final boxes = wi132Boxes(tester, row) as RenderParagraphLineBoxes;
      expect(
        boxes.paragraph.text.toPlainText(),
        text,
        reason: 'the idle row lays out its whole text',
      );
      double width(String part, {int from = 0}) {
        final at = text.indexOf(part, from);
        expect(at, isNonNegative, reason: 'fixture: "$part" in the row');
        var w = 0.0;
        for (final r in boxes.boxesFor(
          TextRange(start: at, end: at + part.length),
        )) {
          w += r.width;
        }
        return w;
      }

      expect(width('**'), lessThan(0.01), reason: 'bold markers hidden');
      expect(width('`'), lessThan(0.01), reason: 'code ticks hidden');
      expect(width('[['), lessThan(0.01), reason: 'wikilink brackets hidden');
      expect(width('bold words'), greaterThan(1), reason: 'the text shows');
    });

    testWidgets(
      'with a cross-row selection an idle row shows revealed markup and its part of the selection highlight as the field painted them',
      (tester) async {
        await _t132Pump(tester);
        final row = wi132RowOf(tester, 'Decorated');
        final next = row + 1;
        final spec = wi132Spec(tester, row);
        final nextSpec = wi132Spec(tester, next);
        final forward = TextSelection(
          baseOffset: spec.textStart + 2,
          extentOffset: nextSpec.textStart + 4,
        );
        final backward = TextSelection(
          baseOffset: forward.extentOffset,
          extentOffset: forward.baseOffset,
        );

        // From the row into the next one: focus and the active row stay in
        // the row the selection started from.
        await wi132Activate(tester, row, forward);
        wi132ExpectOnlyActive(tester, row);
        final rowActive = wi132Geometry(tester, row);
        final rowActiveText = _t132TextOf(tester, row);
        final rowActiveFill = wi132SelectionRects(tester, row);
        final nextIdle = wi132Geometry(tester, next);
        final nextIdleText = _t132TextOf(tester, next);
        final nextIdleFill = wi132SelectionRects(tester, next);
        wi132ExpectIdle(tester, next, reason: 'the next row');

        // The same range from the next row back: that row is active now.
        await wi132Activate(tester, next, backward);
        wi132ExpectOnlyActive(tester, next);
        wi132ExpectIdle(tester, row, reason: 'the decorated row');
        wi132ExpectSameGeometry(
          wi132Geometry(tester, row),
          rowActive,
          'the decorated row',
        );
        _t132ExpectSameText(
          _t132TextOf(tester, row),
          rowActiveText,
          'the decorated row',
        );
        final fill = wi132SelectionRects(tester, row);
        expect(fill, isNotEmpty, reason: 'the idle row fills its part');
        expect(fill, rowActiveFill, reason: 'the field painted this fill');
        // Its selected line shows its markup.
        final text = wi132RowText(tester, row);
        final at = text.indexOf('**');
        final markers = wi132Boxes(
          tester,
          row,
        ).boxesFor(TextRange(start: at, end: at + 2));
        expect(
          markers.fold<double>(0, (w, r) => w + r.width),
          greaterThan(1),
          reason: 'the selected line reveals its bold markers',
        );

        wi132ExpectSameGeometry(
          wi132Geometry(tester, next),
          nextIdle,
          'the next row',
        );
        _t132ExpectSameText(
          nextIdleText,
          _t132TextOf(tester, next),
          'the next row',
        );
        expect(nextIdleFill, isNotEmpty, reason: 'the idle part is filled');
        expect(
          wi132SelectionRects(tester, next),
          nextIdleFill,
          reason: 'the idle row painted the fill its field paints',
        );
      },
    );
  });

  group('decorations of idle rows (AC4)', () {
    const body =
        'Spelling row with teh word and more\n'
        '- [ ] Task row open words\n'
        '- [x] Task row done words\n'
        'Find row with needle here\n'
        '- Anchor item\n';

    testWidgets('an idle row shows its spelling squiggles as its field does', (
      tester,
    ) async {
      final spelling = FakeSpellingService()
        ..misspell('teh', corrections: ['the']);
      await _t132Pump(tester, body: body, spelling: spelling);
      await wi132Unfocus(tester);
      final row = wi132RowOf(tester, 'Spelling row');
      final anchor = wi132RowOf(tester, _t132Anchor);
      RenderObject layer() => tester.renderObject(
        find.descendant(
          of: find.byKey(ValueKey('editor-row-0-$row')),
          matching: find.byType(SpellSquiggles),
        ),
      );

      await wi132Select(tester, wi132CaretIn(tester, row));
      wi132ExpectActive(tester, row, reason: 'unfocused caret row');
      final active = wi132PaintLog(layer());

      await wi132Select(tester, wi132CaretIn(tester, anchor));
      wi132ExpectIdle(tester, row);
      final idle = wi132PaintLog(layer());
      expect(
        idle.where(
          (op) => op.$1 == #drawPath && op.$3 == OmColors.danger.toARGB32(),
        ),
        isNotEmpty,
        reason: 'a danger squiggle under `teh`',
      );
      wi132ExpectSamePaint(idle, active, 'the squiggle layer');
    });

    testWidgets(
      'an idle row shows its Find highlights and the current match as its field does',
      (tester) async {
        await _t132Pump(tester, body: body);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SegmentView).first),
        );
        final text = wi132Host(tester).text;
        container.read(findInNoteProvider.notifier)
          ..setSources([
            FindSource(segment: 0, kind: FindSourceKind.body, text: text),
          ])
          ..setQuery('Task row')
          ..show();
        await tester.pump();
        await tester.pump();
        expect(
          container.read(findInNoteProvider).matches,
          hasLength(2),
          reason: 'fixture: one match per task row',
        );
        await wi132Unfocus(tester);
        final current = wi132RowOf(tester, '- [ ] Task row');
        final other = wi132RowOf(tester, '- [x] Task row');
        final anchor = wi132RowOf(tester, _t132Anchor);

        await wi132Select(tester, wi132CaretIn(tester, current));
        wi132ExpectActive(tester, current, reason: 'unfocused caret row');
        final active = wi83LayerOps(tester, findHighlightsKey(0, current));

        await wi132Select(tester, wi132CaretIn(tester, anchor));
        wi132ExpectIdle(tester, current, reason: 'the current match row');
        wi132ExpectIdle(tester, other, reason: 'the other match row');
        final idle = wi83LayerOps(tester, findHighlightsKey(0, current));
        expect(
          idle.any((op) => wi83SameColor(op.color, wi83Current)),
          isTrue,
          reason: 'the current match paints in the idle row: $idle',
        );
        expect(
          [for (final op in idle) (op.outer, op.inner, op.color.toARGB32())],
          [for (final op in active) (op.outer, op.inner, op.color.toARGB32())],
          reason: 'as its field row painted it',
        );
        expect(
          wi83LayerOps(tester, findHighlightsKey(0, other)),
          isNotEmpty,
          reason: 'the other match paints in its idle row',
        );
      },
    );

    for (final (name, prefix) in [
      (
        'an idle open task row shows its checkbox as its field row does',
        '- [ ] Task row',
      ),
      (
        'an idle done task row shows its checked box as its field row does',
        '- [x] Task row',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester, body: body);
        await wi132Unfocus(tester);
        final row = wi132RowOf(tester, prefix);
        final anchor = wi132RowOf(tester, _t132Anchor);
        final marker = find.byKey(ValueKey('editor-row-marker-0-$row'));

        await wi132Select(tester, wi132CaretIn(tester, row));
        wi132ExpectActive(tester, row, reason: 'unfocused caret row');
        final active = wi132PaintLog(tester.renderObject(marker));

        await wi132Select(tester, wi132CaretIn(tester, anchor));
        wi132ExpectIdle(tester, row);
        expect(marker, findsOneWidget, reason: 'the idle row has its marker');
        final idle = wi132PaintLog(tester.renderObject(marker));
        expect(idle, isNotEmpty, reason: 'the checkbox paints');
        wi132ExpectSamePaint(idle, active, 'the checkbox');
      });
    }

    testWidgets('an idle row shows the echo arrival band on its arrival line', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester, open: revealItemsId);
      // Focus sits in the first row; the passage row is idle.
      await wi132Activate(tester, 0, wi132CaretIn(tester, 0));
      final at = h.offsetOf('  passage 200\n');
      final row = h.rowOf(0, at).index;
      wi132ExpectIdle(tester, row, reason: 'the arrival row');

      h.request(
        NoteRevealRequest(
          revealItemsId,
          h.textAt(at),
          const RevealTop(16),
          flash: true,
        ),
      );
      for (var i = 0; i < 20 && h.highlight.evaluate().isEmpty; i++) {
        await tester.pump();
      }
      expect(h.highlight, findsOneWidget, reason: 'the arrival flashes');
      wi132ExpectIdle(tester, row, reason: 'the arrival row stays idle');
      final highlight = tester.widget<EchoArrivalHighlight>(h.highlight);
      final line = h.lineBoxOf(0, at);
      final top = highlight.target.globalToLocal(line.topLeft).dy;
      final bottom = highlight.target.globalToLocal(line.bottomLeft).dy;
      expect(
        highlight.band.top,
        moreOrLessEquals(top, epsilon: 0.5),
        reason: 'the band starts on the passage line',
      );
      expect(
        highlight.band.bottom,
        greaterThanOrEqualTo(bottom - 0.5),
        reason: 'the band covers the passage line',
      );
      await pumpFrames(tester, frames: 40);
    });
  });
}
