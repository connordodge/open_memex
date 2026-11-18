// WI #83 (Spec #61 F3): the find highlight layers mounted on every surface
// find searches, in the real workspace (support/spelling_editor_pump.dart):
// body rows (`find-highlights-<s>-<r>`), excerpt card rows
// (`find-highlights-card-<s>-<r>`), table grid cells
// (`find-highlights-grid-<s>-<row>-<cell>`) and the Source field
// (`find-highlights-source`).
//
// Find state is driven through F1's public commands (setSources,
// useSelection, next, setQuery, close) on sources built from the shown
// note's own text. D20: boxes are checked through recorded paint calls
// only. Expected x and width come from each surface's own line boxes; the
// box is 17 px (times the workspace's text scale) tall, centred on its line
// box. Clicks land on plain body lines (53-C).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/editor/markdown_table.dart' as md;
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi83_find_paint.dart';

const _other = FindPaintStyle.other;
const _current = FindPaintStyle.current;
const _outline = FindPaintStyle.outline;

// ------------------------------------------------------------------ pump

/// Pumps the note editor on [body] in live preview with nothing focused.
Future<SpellingEditorHarness> _wi83Pump(
  WidgetTester tester,
  String body,
) async {
  final e = await pumpSpellingEditor(tester, body: body);
  await _wi83Unfocus(tester);
  return e;
}

Future<void> _wi83Unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pump();
}

FindInNoteNotifier _wi83Find(SpellingEditorHarness e) =>
    e.container.read(findInNoteProvider.notifier);

FindInNoteState _wi83State(SpellingEditorHarness e) =>
    e.container.read(findInNoteProvider);

/// Opens find on [sources] with [query] at match [current], then pumps.
Future<void> _wi83Open(
  SpellingEditorHarness e,
  List<FindSource> sources,
  String query, {
  int current = 0,
}) async {
  wi83Open(e.container, sources, query, current: current);
  await e.tester.pump();
  await e.tester.pump();
}

// ------------------------------------------------------------------ rows

SegmentViewState _wi83Segment(SpellingEditorHarness e, int s) =>
    e.tester.state<SegmentViewState>(
      find.descendant(of: e.textSegment(s), matching: find.byType(SegmentView)),
    );

/// The row of segment [s] whose field text holds segment offset [offset].
int _wi83RowAt(SpellingEditorHarness e, int s, int offset) {
  final seg = _wi83Segment(e, s);
  for (var r = 0; r < seg.rowCount; r++) {
    final spec = seg.rowSpec(r)!;
    if (offset >= spec.textStart && offset <= spec.textEnd) return r;
  }
  throw TestFailure('fixture: no row of segment $s holds $offset');
}

RowSpec _wi83Spec(SpellingEditorHarness e, int s, int r) =>
    _wi83Segment(e, s).rowSpec(r)!;

RenderEditable _wi83RowEditable(WidgetTester tester, int s, int r) =>
    findRenderEditable(
      tester.renderObject(find.byKey(ValueKey('editor-row-$s-$r'))),
    )!;

/// The design boxes of segment range [range] (segment offsets) in row [r]
/// of segment [s], in that row's layer.
List<Wi83Box> _wi83RowBoxes(
  SpellingEditorHarness e,
  int s,
  int r,
  TextRange range,
  FindPaintStyle style,
) {
  final start = _wi83Spec(e, s, r).textStart;
  final editable = _wi83RowEditable(e.tester, s, r);
  return wi83BoxesOf(
    RenderEditableLineBoxes(editable),
    TextRange(start: range.start - start, end: range.end - start),
    style,
    wi83Layer(e.tester, findHighlightsKey(s, r)),
    scale: wi83ScaleOf(editable),
  );
}

void _wi83ExpectRow(
  SpellingEditorHarness e,
  int s,
  int r,
  List<Wi83Box> boxes, {
  String reason = '',
}) => wi83ExpectBoxes(
  wi83LayerOps(e.tester, findHighlightsKey(s, r)),
  boxes,
  reason: reason.isEmpty ? 'row $s-$r' : reason,
);

/// Expects every row layer of segment [s] to paint exactly the boxes of
/// [want] (segment ranges and styles) that lie in that row, and nothing
/// else.
void _wi83ExpectSegment(
  SpellingEditorHarness e,
  int s,
  List<(TextRange, FindPaintStyle)> want,
) {
  final seg = _wi83Segment(e, s);
  for (var r = 0; r < seg.rowCount; r++) {
    final spec = seg.rowSpec(r)!;
    final mine = [
      for (final (range, style) in want)
        if (range.start >= spec.textStart && range.end <= spec.textEnd)
          ..._wi83RowBoxes(e, s, r, range, style),
    ];
    final key = findHighlightsKey(s, r);
    if (mine.isEmpty && find.byKey(key).evaluate().isEmpty) continue;
    _wi83ExpectRow(e, s, r, mine);
  }
}

/// Every find op of every find highlight layer now mounted.
List<Wi83Op> _wi83AllFindOps(WidgetTester tester) => [
  for (final element in find.byType(FindHighlights).evaluate())
    ...wi83Record(element.renderObject!).find,
];

// ------------------------------------------------------------------ cells

/// The paragraph of grid cell ([g], [c]) of the table row [r] of segment
/// [s].
RenderParagraph _wi83CellParagraph(
  WidgetTester tester,
  int s,
  int r,
  int g,
  int c,
) => tester.renderObject<RenderParagraph>(
  find.descendant(
    of: find.byKey(ValueKey('editor-table-cell-$s-$r-$g-$c')),
    matching: find.byType(RichText),
  ),
);

/// Cell ([g], [c])'s source range in its table row's text.
md.TableCell _wi83Cell(String rowText, int g, int c) {
  final table = md.parseTable(rowText)!;
  final cells = g == 0 ? table.header.cells : table.body[g - 1].cells;
  return cells[c];
}

/// The design boxes of segment range [range] clipped to grid cell ([g],
/// [c]) of table row [r] of segment [s], in that cell's layer.
List<Wi83Box> _wi83CellBoxes(
  SpellingEditorHarness e,
  int s,
  int r,
  int g,
  int c,
  TextRange range,
  FindPaintStyle style,
) {
  final spec = _wi83Spec(e, s, r);
  final rowText = e.robot
      .segmentText(s)
      .substring(spec.textStart, spec.textEnd);
  final cell = _wi83Cell(rowText, g, c);
  final from = range.start - spec.textStart - cell.start;
  final to = range.end - spec.textStart - cell.start;
  final paragraph = _wi83CellParagraph(e.tester, s, r, g, c);
  return wi83BoxesOf(
    RenderParagraphLineBoxes(paragraph),
    TextRange(
      start: from.clamp(0, cell.end - cell.start).toInt(),
      end: to.clamp(0, cell.end - cell.start).toInt(),
    ),
    style,
    wi83Layer(e.tester, findGridHighlightsKey(s, g, c)),
    scale: wi83ScaleOf(paragraph),
  );
}

void _wi83ExpectCell(
  SpellingEditorHarness e,
  int s,
  int g,
  int c,
  List<Wi83Box> boxes,
) => wi83ExpectBoxes(
  wi83LayerOps(e.tester, findGridHighlightsKey(s, g, c)),
  boxes,
  reason: 'grid cell $s-$g-$c',
);

/// The table row of segment [s].
int _wi83TableRow(SpellingEditorHarness e, int s) {
  final seg = _wi83Segment(e, s);
  for (var r = 0; r < seg.rowCount; r++) {
    if (seg.rowSpec(r)!.kind == RowKind.table) return r;
  }
  throw TestFailure('fixture: no table row in segment $s');
}

/// Expects table row [r] of segment [s] to show as its grid.
void _wi83ExpectGrid(SpellingEditorHarness e, int s, int r) {
  expect(find.byKey(ValueKey('editor-table-$s-$r')), findsOneWidget);
  final field = e.tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(ValueKey('editor-row-$s-$r'), skipOffstage: false),
      matching: find.byType(EditableText, skipOffstage: false),
      skipOffstage: false,
    ),
  );
  final controller = field.controller as LivePreviewController;
  expect(controller.tableRow, isTrue);
  expect(controller.tableRevealed, isFalse, reason: 'the grid stays a grid');
}

// ------------------------------------------------------------------ texts

const _wi83Link = 'see [bread notes](https://example.org/rye) daily';
const _wi83LinkBody = 'Intro\n$_wi83Link\nrye at end\n';

const _wi83Table =
    '| Kind | Notes | More |\n'
    '| --- | --- | --- |\n'
    '| Wet | too much rye here | a lot |\n'
    '| Dry | see [flour](https://x.org/rye) | rye b |';
const _wi83TableBody = 'Intro\n\n$_wi83Table\n';

/// The link markup of `[flour](https://x.org/rye)` in [text] as hidden
/// ranges (a grid cell hides it).
List<FindRange> _wi83TableHidden(String text) {
  final open = text.indexOf('[flour]');
  final close = text.indexOf('](https://x.org/rye)');
  return [
    FindRange(open, open + 1),
    FindRange(close, close + '](https://x.org/rye)'.length),
  ];
}

void main() {
  holdFontFetches();

  group('body rows', () {
    testWidgets(
      'a body row with three matches of rye and the second current paints two other boxes and one current box at their line box rects',
      (tester) async {
        const line = 'Sift the rye, fold the rye, proof the rye.';
        final e = await _wi83Pump(tester, '$line\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        _wi83ExpectSegment(e, 0, [
          (wi83Find(text, 'rye'), _other),
          (wi83Find(text, 'rye', 1), _current),
          (wi83Find(text, 'rye', 2), _other),
        ]);
      },
    );

    testWidgets(
      'a hidden non current match in a link URL paints only a border around the link label',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83LinkBody);
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        final s = _wi83State(e);
        final label = wi83Find(text, 'bread notes');
        expect(s.matches.first.hidden, isTrue, reason: 'fixture');
        expect(
          s.matches.first.outline,
          FindRange(label.start, label.end),
          reason: 'fixture: F1 gives the label as the outline',
        );
        _wi83ExpectSegment(e, 0, [
          (label, _outline),
          (wi83Find(text, 'rye', 1), _current),
        ]);
      },
    );

    testWidgets(
      'a hidden non current match in a link URL paints an other box on its own range while the caret reveals its line and the label outline while it does not',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83LinkBody);
        final text = e.robot.segmentText(0);
        final url = wi83Find(text, 'rye');
        final label = wi83Find(text, 'bread notes');
        final plain = wi83Find(text, 'rye', 1);
        // The caret on another line: the link markup is hidden.
        await e.robot.focusSegment(0, offset: plain.start);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        expect(_wi83State(e).matches.first.hidden, isTrue, reason: 'fixture');
        _wi83ExpectSegment(e, 0, [(label, _outline), (plain, _current)]);
        // The caret on the link line reveals it: the URL shows, and its
        // match is an ordinary other match on its own range.
        await e.robot.focusSegment(0, offset: wi83Find(text, 'see').start);
        expect(
          _wi83RowBoxes(e, 0, _wi83RowAt(e, 0, url.start), url, _other),
          hasLength(1),
          reason: 'fixture: the revealed URL has width',
        );
        _wi83ExpectSegment(e, 0, [(url, _other), (plain, _current)]);
        // The caret leaves: the outline is back.
        await e.robot.focusSegment(0, offset: plain.start);
        _wi83ExpectSegment(e, 0, [(label, _outline), (plain, _current)]);
      },
    );

    testWidgets(
      'a hidden non current match in a link URL goes back to the label outline when the segment loses focus with the caret still on the link line',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83LinkBody);
        final text = e.robot.segmentText(0);
        final url = wi83Find(text, 'rye');
        final label = wi83Find(text, 'bread notes');
        final plain = wi83Find(text, 'rye', 1);
        // The caret on the link line: the segment has focus and its markup
        // shows, so the URL match is an other box on its own range.
        await e.robot.focusSegment(0, offset: wi83Find(text, 'see').start);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        expect(_wi83State(e).matches.first.hidden, isTrue, reason: 'fixture');
        _wi83ExpectSegment(e, 0, [(url, _other), (plain, _current)]);
        final selection = _wi83Segment(e, 0).selection;
        // Cmd+F moves focus to the find field: the segment loses focus, its
        // selection stays on the link line, and its markup hides again.
        final paints = debugFindHighlightPaints;
        await _wi83Unfocus(tester);
        expect(
          _wi83Segment(e, 0).selection,
          selection,
          reason: 'fixture: the selection stays on the link line',
        );
        expect(
          debugFindHighlightPaints,
          greaterThan(paints),
          reason: 'the closed gate repaints the layers',
        );
        _wi83ExpectSegment(e, 0, [(label, _outline), (plain, _current)]);
        // Focus back: the markup shows and the URL match is an other box.
        await e.robot.focusSegment(0, offset: selection.baseOffset);
        _wi83ExpectSegment(e, 0, [(url, _other), (plain, _current)]);
      },
    );

    testWidgets(
      'a hidden non current match on a bold run marker paints a border around the bold text',
      (tester) async {
        final e = await _wi83Pump(
          tester,
          'Bake it **hot** today.\n\nBulk until **domed**.\n',
        );
        final text = e.robot.segmentText(0);
        // Current: line 3's first marker. Find reveals the current match's
        // line (Req 27), so line 3's markers show: the current one paints
        // the current fill and the other one an other box on its own range
        // (lead ruling #83 Q1). Line 1 stays unrevealed: its two markers
        // share one outline around `hot`.
        await _wi83Open(e, [wi83Body(0, text)], '**', current: 2);
        expect(_wi83State(e).matches, hasLength(4), reason: 'fixture');
        expect(_wi83State(e).matches.every((m) => m.hidden), isTrue);
        final hot = wi83Find(text, 'hot');
        final r = _wi83RowAt(e, 0, hot.start);
        final current = _wi83RowBoxes(
          e,
          0,
          r,
          wi83Find(text, '**', 2),
          _current,
        );
        final other = _wi83RowBoxes(e, 0, r, wi83Find(text, '**', 3), _other);
        expect(
          current,
          hasLength(1),
          reason: 'line 3 shows the current marker',
        );
        expect(other, hasLength(1), reason: 'line 3 shows the other marker');
        _wi83ExpectRow(e, 0, r, [
          ..._wi83RowBoxes(e, 0, r, hot, _outline),
          ...current,
          ...other,
        ]);
      },
    );

    testWidgets(
      'a hidden current body match paints a solid current fill on its own range',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83LinkBody);
        final text = e.robot.segmentText(0);
        final url = wi83Find(text, 'rye');
        // The caret on the link line reveals its markup, so the URL has
        // width (F4 reveals it the same way once F6 wires it).
        await e.robot.focusSegment(0, offset: wi83Find(text, 'see').start);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 0);
        expect(_wi83State(e).matches.first.hidden, isTrue, reason: 'fixture');
        final r = _wi83RowAt(e, 0, url.start);
        expect(
          _wi83RowBoxes(e, 0, r, url, _current),
          hasLength(1),
          reason: 'fixture: the URL shows',
        );
        _wi83ExpectSegment(e, 0, [
          (url, _current),
          (wi83Find(text, 'rye', 1), _other),
        ]);
      },
    );

    testWidgets(
      'on the line of a hidden current bold marker the other marker paints an other box and other lines keep their outline',
      (tester) async {
        // Pack 83 B3.12.
        final e = await _wi83Pump(
          tester,
          'Bake it **hot** today.\n\nBulk until **domed** now.\n',
        );
        final text = e.robot.segmentText(0);
        await e.robot.focusSegment(0, offset: wi83Find(text, 'Bulk').start);
        await _wi83Open(e, [wi83Body(0, text)], '**', current: 2);
        expect(
          _wi83RowBoxes(
            e,
            0,
            _wi83RowAt(e, 0, wi83Find(text, 'Bulk').start),
            wi83Find(text, '**', 2),
            _current,
          ),
          hasLength(1),
          reason: 'fixture: the caret line shows its markers',
        );
        _wi83ExpectSegment(e, 0, [
          (wi83Find(text, 'hot'), _outline),
          (wi83Find(text, '**', 2), _current),
          (wi83Find(text, '**', 3), _other),
        ]);
      },
    );
  });

  group('excerpt cards', () {
    testWidgets('a card row match paints in that card rows paragraph boxes', (
      tester,
    ) async {
      final e = await _wi83Pump(tester, fixtureTopicBody);
      final card = tester.widget<CardRows>(
        find.descendant(of: e.robot.card(1), matching: find.byType(CardRows)),
      );
      final cardText = card.text;
      expect(cardText, contains('Fixed the jump arc.'), reason: 'fixture');
      final sources = [
        wi83Body(0, e.robot.segmentText(0)),
        FindSource(segment: 1, kind: FindSourceKind.card, text: cardText),
        wi83Body(2, e.robot.segmentText(2)),
      ];
      // Matches of `e`: segment 0's first, then the card's in order.
      final seg0 = 'e'.allMatches(e.robot.segmentText(0)).length;
      await _wi83Open(e, sources, 'e', current: seg0 + 1);
      final specs = splitRows(cardText, atSegmentStart: true);
      for (final (r, spec) in specs.indexed) {
        final rowText = cardText.substring(spec.textStart, spec.textEnd);
        if (!rowText.contains('e')) continue;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.descendant(
              of: e.robot.card(1),
              matching: find.byKey(ValueKey('card-row-text-$r')),
            ),
            matching: find.byType(RichText),
          ),
        );
        final layer = wi83Layer(tester, findCardHighlightsKey(1, r));
        final boxes = <Wi83Box>[];
        var n = 0;
        for (final m in _wi83State(e).matches) {
          if (m.kind != FindSourceKind.card) continue;
          final local = m.start - spec.textStart;
          if (m.start >= spec.textStart && m.end <= spec.textEnd) {
            final index = _wi83State(e).matches.indexOf(m);
            boxes.addAll(
              wi83BoxesOf(
                RenderParagraphLineBoxes(paragraph),
                TextRange(start: local, end: local + 1),
                index == _wi83State(e).current ? _current : _other,
                layer,
                scale: wi83ScaleOf(paragraph),
              ),
            );
            n++;
          }
        }
        expect(n, greaterThan(0), reason: 'fixture: row $r has matches');
        wi83ExpectBoxes(
          wi83LayerOps(tester, findCardHighlightsKey(1, r)),
          boxes,
          reason: 'card row $r',
        );
      }
      expect(
        wi83LayerOps(
          tester,
          findCardHighlightsKey(1, 0),
        ).where((op) => wi83SameColor(op.color, wi83Current)),
        isNotEmpty,
        reason: 'the current match is in card row 0',
      );
    });
  });

  group('table grid', () {
    testWidgets(
      'a match in a table showing as a grid paints in its cell and the grid stays a grid when it is current',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83TableBody);
        final text = e.robot.segmentText(0);
        await _wi83Open(
          e,
          [wi83Body(0, text, hidden: _wi83TableHidden(text))],
          'rye',
          current: 0,
        );
        final r = _wi83TableRow(e, 0);
        _wi83ExpectGrid(e, 0, r);
        final wet = wi83Find(text, 'rye');
        _wi83ExpectCell(
          e,
          0,
          1,
          1,
          _wi83CellBoxes(e, 0, r, 1, 1, wet, _current),
        );
        final dry = wi83Find(text, 'rye b');
        _wi83ExpectCell(
          e,
          0,
          2,
          2,
          _wi83CellBoxes(
            e,
            0,
            r,
            2,
            2,
            TextRange(start: dry.start, end: dry.start + 3),
            _other,
          ),
        );
        // Other cells paint nothing.
        expect(_wi83FindOps(tester, findGridHighlightsKey(0, 1, 0)), isEmpty);
        expect(_wi83FindOps(tester, findGridHighlightsKey(0, 0, 1)), isEmpty);
      },
    );

    for (final (name, current) in [
      (
        'a match wholly in hidden markup inside a grid cell paints an outline',
        0,
      ),
      (
        'a match wholly in hidden markup inside a grid cell paints an outline when it is current',
        1,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final e = await _wi83Pump(tester, _wi83TableBody);
        final text = e.robot.segmentText(0);
        await _wi83Open(
          e,
          [wi83Body(0, text, hidden: _wi83TableHidden(text))],
          'rye',
          current: current,
        );
        final url = _wi83State(e).matches[1];
        final flour = wi83Find(text, 'flour');
        expect(url.hidden, isTrue, reason: 'fixture: the URL match is hidden');
        expect(url.outline, FindRange(flour.start, flour.end));
        final r = _wi83TableRow(e, 0);
        _wi83ExpectGrid(e, 0, r);
        _wi83ExpectCell(
          e,
          0,
          2,
          1,
          _wi83CellBoxes(e, 0, r, 2, 1, flour, _outline),
        );
      });
    }

    testWidgets(
      'a table the caret reveals stops showing its grid and its row layer paints the matches while the grid layers go',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83TableBody);
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [
          wi83Body(0, text, hidden: _wi83TableHidden(text)),
        ], 'rye');
        final r = _wi83TableRow(e, 0);
        _wi83ExpectGrid(e, 0, r);
        // As a grid the row layer paints nothing: the cells paint.
        expect(
          _wi83FindOps(tester, findHighlightsKey(0, r)),
          isEmpty,
          reason: 'a grid row paints in its cells only',
        );
        expect(
          _wi83FindOps(tester, findGridHighlightsKey(0, 1, 1)),
          isNotEmpty,
        );
        // The caret in the table reveals its source.
        final wet = wi83Find(text, 'rye');
        // Focus the Intro row (opens the reveal gate), then move the caret
        // into the table row.
        await tester.showKeyboard(
          find.descendant(
            of: find.byKey(const ValueKey('editor-row-0-0')),
            matching: find.byType(EditableText),
          ),
        );
        await tester.pump();
        e.robot.segment(0).select(TextSelection.collapsed(offset: wet.start));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(ValueKey('editor-table-0-$r')), findsNothing);
        expect(
          find.byKey(findGridHighlightsKey(0, 1, 1)),
          findsNothing,
          reason: 'the cell layers leave with the grid',
        );
        // Every `rye` of the table paints in the row layer: the revealed
        // source shows the URL too.
        final url = wi83Find(text, 'rye', 1);
        final dry = wi83Find(text, 'rye', 2);
        expect(_wi83State(e).matches, hasLength(3), reason: 'fixture');
        _wi83ExpectRow(e, 0, r, [
          ..._wi83RowBoxes(e, 0, r, wet, _current),
          ..._wi83RowBoxes(e, 0, r, url, _other),
          ..._wi83RowBoxes(e, 0, r, dry, _other),
        ]);
      },
    );

    testWidgets(
      'a table row shorter than its header paints in the cells it has and mounts no layer for the missing one',
      (tester) async {
        const body =
            'Intro\n\n| A | B | C |\n| --- | --- | --- |\n| rye | x |\n';
        final e = await _wi83Pump(tester, body);
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye');
        final r = _wi83TableRow(e, 0);
        _wi83ExpectGrid(e, 0, r);
        _wi83ExpectCell(
          e,
          0,
          1,
          0,
          _wi83CellBoxes(e, 0, r, 1, 0, wi83Find(text, 'rye'), _current),
        );
        expect(find.byKey(findGridHighlightsKey(0, 1, 1)), findsOneWidget);
        expect(find.byKey(findGridHighlightsKey(0, 1, 2)), findsNothing);
      },
    );

    testWidgets(
      'a match spanning two grid cells paints its visible part in each cell',
      (tester) async {
        final e = await _wi83Pump(tester, _wi83TableBody);
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [
          wi83Body(0, text, hidden: _wi83TableHidden(text)),
        ], 'here | a');
        final match = wi83Find(text, 'here | a');
        final r = _wi83TableRow(e, 0);
        _wi83ExpectGrid(e, 0, r);
        final notes = _wi83CellBoxes(e, 0, r, 1, 1, match, _current);
        final more = _wi83CellBoxes(e, 0, r, 1, 2, match, _current);
        expect(notes, hasLength(1), reason: 'fixture: `here` in Notes');
        expect(more, hasLength(1), reason: 'fixture: `a` in More');
        _wi83ExpectCell(e, 0, 1, 1, notes);
        _wi83ExpectCell(e, 0, 1, 2, more);
      },
    );
  });

  group('Source mode', () {
    testWidgets(
      'in Source mode every match paints a fill on the Source field and none an outline',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Intro rye\n$_wi83Link\n',
          source: true,
        );
        await _wi83Unfocus(tester);
        final text = e.robot.sourceText;
        await _wi83Open(
          e,
          [FindSource(segment: 0, kind: FindSourceKind.source, text: text)],
          'rye',
          current: 1,
        );
        final editable = findRenderEditable(
          tester.renderObject(e.sourceField),
        )!;
        final layer = wi83Layer(tester, findSourceHighlightsKey);
        final source = RenderEditableLineBoxes(editable);
        final scale = wi83ScaleOf(editable);
        wi83ExpectBoxes(wi83LayerOps(tester, findSourceHighlightsKey), [
          ...wi83BoxesOf(
            source,
            wi83Find(text, 'rye'),
            _other,
            layer,
            scale: scale,
          ),
          ...wi83BoxesOf(
            source,
            wi83Find(text, 'rye', 1),
            _current,
            layer,
            scale: scale,
          ),
        ], reason: 'Source field');
      },
    );
  });

  group('empty query and closed bar', () {
    const body =
        'Intro the line\n$fixtureRangeToken\n| A | B |\n| --- | --- |\n| the | x |\n';

    List<FindSource> sourcesOf(SpellingEditorHarness e) => [
      wi83Body(0, e.robot.segmentText(0)),
      FindSource(
        segment: 1,
        kind: FindSourceKind.card,
        text: e.tester
            .widget<CardRows>(
              find.descendant(
                of: e.robot.card(1),
                matching: find.byType(CardRows),
              ),
            )
            .text,
      ),
      wi83Body(2, e.robot.segmentText(2)),
    ];

    void expectEverySurfacePaints(SpellingEditorHarness e) {
      final tester = e.tester;
      expect(
        wi83LayerOps(tester, findHighlightsKey(0, 0)),
        isNotEmpty,
        reason: 'body row',
      );
      expect(
        wi83LayerOps(tester, findCardHighlightsKey(1, 0)),
        isNotEmpty,
        reason: 'card row',
      );
      expect(
        wi83LayerOps(tester, findGridHighlightsKey(2, 1, 0)),
        isNotEmpty,
        reason: 'grid cell',
      );
    }

    testWidgets(
      'an empty query or a closed bar paints no find boxes on any live preview surface',
      (tester) async {
        final e = await _wi83Pump(tester, body);
        await _wi83Open(e, sourcesOf(e), 'the');
        expectEverySurfacePaints(e);
        _wi83Find(e).setQuery('');
        await tester.pump();
        expect(_wi83AllFindOps(tester), isEmpty, reason: 'empty query');
        _wi83Find(e).setQuery('the');
        await tester.pump();
        expectEverySurfacePaints(e);
        _wi83Find(e).close();
        await tester.pump();
        expect(_wi83State(e).lastQuery, 'the', reason: 'fixture: kept');
        expect(_wi83AllFindOps(tester), isEmpty, reason: 'closed bar');
      },
    );

    testWidgets(
      'an empty query or a closed bar paints no find boxes on the Source field',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'rye and rye\n',
          source: true,
        );
        await _wi83Unfocus(tester);
        final text = e.robot.sourceText;
        await _wi83Open(e, [
          FindSource(segment: 0, kind: FindSourceKind.source, text: text),
        ], 'rye');
        expect(wi83LayerOps(tester, findSourceHighlightsKey), isNotEmpty);
        _wi83Find(e).setQuery('');
        await tester.pump();
        expect(_wi83AllFindOps(tester), isEmpty, reason: 'empty query');
        _wi83Find(e).setQuery('rye');
        await tester.pump();
        expect(wi83LayerOps(tester, findSourceHighlightsKey), isNotEmpty);
        _wi83Find(e).close();
        await tester.pump();
        expect(_wi83AllFindOps(tester), isEmpty, reason: 'closed bar');
      },
    );
  });

  group('stacking', () {
    testWidgets(
      'the overlay paints below the selection fill and below the spelling squiggle of a selected misspelt match',
      (tester) async {
        final e = await _wi83Pump(tester, 'ryee flour\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'ryee');
        // Select exactly the match (its squiggle stays: the selection
        // equals the flagged range) and flag it misspelt.
        _wi83Segment(
          e,
          0,
        ).select(const TextSelection(baseOffset: 0, extentOffset: 4));
        await tester.pump();
        final field = find.descendant(
          of: find.byKey(const ValueKey('editor-row-0-0')),
          matching: find.byType(EditableText),
        );
        final registry = SpellIssueScope.maybeOf(tester.element(field))!;
        registry.setIssues(tester.widget<EditableText>(field).controller, [
          const SpellIssue(
            kind: SpellIssueKind.spelling,
            start: 0,
            length: 4,
            corrections: ['rye'],
          ),
        ]);
        await tester.pump();
        final colors = wi83Record(tester.renderObject(e.textSegment(0))).colors;
        final findAt = colors.indexWhere(
          (c) => c != null && wi83IsFindColor(c),
        );
        final selectionAt = colors.indexWhere(
          (c) => c != null && wi83SameColor(c, OmColors.selection),
        );
        final squiggleAt = colors.indexWhere(
          (c) => c != null && wi83SameColor(c, OmColors.danger),
        );
        expect(findAt, isNonNegative, reason: 'the match box paints');
        expect(selectionAt, isNonNegative, reason: 'the selection paints');
        expect(squiggleAt, isNonNegative, reason: 'the squiggle paints');
        expect(findAt, lessThan(selectionAt), reason: 'below the selection');
        expect(findAt, lessThan(squiggleAt), reason: 'below the squiggle');
        final lastFind = colors.lastIndexWhere(
          (c) => c != null && wi83IsFindColor(c),
        );
        expect(lastFind, lessThan(selectionAt), reason: 'all of it');
      },
    );

    testWidgets(
      'the Source field overlay paints below the selection fill and the field text',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'ryee flour and ryee\n',
          source: true,
        );
        await _wi83Unfocus(tester);
        final text = e.robot.sourceText;
        await _wi83Open(e, [
          FindSource(segment: 0, kind: FindSourceKind.source, text: text),
        ], 'ryee');
        final field = tester.widget<EditableText>(e.sourceField);
        final controller = field.controller;
        field.focusNode.requestFocus();
        await tester.pump();
        // Select the first match, so the field paints a selection fill over
        // the box.
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 4,
        );
        await tester.pump();
        final stack = tester.renderObject(
          find
              .ancestor(
                of: find.byKey(findSourceHighlightsKey),
                matching: find.byType(Stack),
              )
              .first,
        );
        final colors = wi83Record(stack).colors;
        final firstFind = colors.indexWhere(
          (c) => c != null && wi83IsFindColor(c),
        );
        final lastFind = colors.lastIndexWhere(
          (c) => c != null && wi83IsFindColor(c),
        );
        final selectionAt = colors.indexWhere(
          (c) => c != null && wi83SameColor(c, OmColors.selection),
        );
        final textAt = colors.indexWhere((c) => c == null);
        expect(firstFind, isNonNegative, reason: 'the match boxes paint');
        expect(selectionAt, isNonNegative, reason: 'the selection paints');
        expect(textAt, isNonNegative, reason: 'the field text paints');
        expect(lastFind, lessThan(selectionAt), reason: 'below the selection');
        expect(lastFind, lessThan(textAt), reason: 'below the field text');
      },
    );
  });

  group('field moves inside its row', () {
    // The row layer is a repaint boundary beside the whole row, and works out
    // where the field sits only when it paints: a field that moves sideways
    // under equal ranges must still repaint it. Real layers, no inline
    // recorder: after a layout-only pump a layer that needs no paint would
    // keep its old picture.
    String numbered(int n) => [
      for (var i = 1; i <= n; i++) '$i. item${i == 1 ? ' rye' : ''}\n',
    ].join();

    Future<void> expectRepaints(
      SpellingEditorHarness e,
      String after, {
      required int row,
      List<FindSource>? sources,
    }) async {
      final tester = e.tester;
      final layer = wi83Layer(tester, findHighlightsKey(0, row));
      expect(layer.debugNeedsPaint, isFalse, reason: 'fixture: painted');
      _wi83Segment(e, 0).replaceText(after);
      // The matches move with their text, as Find re-derives them.
      if (sources != null) _wi83Find(e).setSources(sources);
      await tester.pump(Duration.zero, EnginePhase.layout);
      expect(
        wi83Layer(tester, findHighlightsKey(0, row)).debugNeedsPaint,
        isTrue,
        reason: 'the field moved in its row: the layer must repaint',
      );
    }

    testWidgets(
      'a numbered run growing from 9 to 10 items repaints the layer of a row whose ranges are unchanged',
      (tester) async {
        final e = await _wi83Pump(tester, numbered(9));
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye');
        final r = _wi83RowAt(e, 0, wi83Find(text, 'rye').start);
        expect(r, 0, reason: 'fixture');
        final textX = _wi83RowEditable(
          tester,
          0,
          r,
        ).localToGlobal(Offset.zero).dx;
        await expectRepaints(e, numbered(10), row: r);
        await tester.pump();
        expect(
          _wi83RowEditable(tester, 0, r).localToGlobal(Offset.zero).dx,
          greaterThan(textX),
          reason: 'fixture: the wider marker column moved the field',
        );
        _wi83ExpectSegment(e, 0, [(wi83Find(text, 'rye'), _current)]);
      },
    );

    testWidgets(
      'indenting a list item repaints the layer of a row whose ranges are unchanged',
      (tester) async {
        final e = await _wi83Pump(tester, '- one\n- bake rye\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye');
        final r = _wi83RowAt(e, 0, wi83Find(text, 'rye').start);
        expect(r, 1, reason: 'fixture');
        final textX = _wi83RowEditable(
          tester,
          0,
          r,
        ).localToGlobal(Offset.zero).dx;
        const after = '- one\n  - bake rye\n';
        await expectRepaints(e, after, row: r, sources: [wi83Body(0, after)]);
        // The field-local range is unchanged: the match moved with the
        // indent.
        expect(_wi83State(e).matches.single.start, text.indexOf('rye') + 2);
        await tester.pump();
        expect(
          _wi83RowEditable(tester, 0, r).localToGlobal(Offset.zero).dx,
          greaterThan(textX),
          reason: 'fixture: the indent moved the field',
        );
        _wi83ExpectSegment(e, 0, [(wi83Find(after, 'rye'), _current)]);
      },
    );
  });

  group('pointers and scroll', () {
    testWidgets(
      'a click on a highlighted word places the caret there as without find',
      (tester) async {
        const line = 'Sift the rye flour';
        final e = await _wi83Pump(tester, '$line\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye');
        final rye = wi83Find(text, 'rye');
        final r = _wi83RowAt(e, 0, rye.start);
        final box = _wi83RowBoxes(e, 0, r, rye, _current).single.rect;
        _wi83ExpectRow(e, 0, r, [(rect: box, style: _current)]);
        final layer = wi83Layer(tester, findHighlightsKey(0, r));
        final global = layer.localToGlobal(
          Offset(box.left + box.width / 3, box.center.dy),
        );
        expect(
          tester
              .hitTestOnBinding(global)
              .path
              .any((entry) => identical(entry.target, layer)),
          isFalse,
          reason: 'the overlay is never hit (D14)',
        );
        final want =
            _wi83RowEditable(tester, 0, r).getPositionForPoint(global).offset +
            _wi83Spec(e, 0, r).textStart;
        await tester.tapAt(global);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          e.robot.segmentSelection(0),
          TextSelection.collapsed(offset: want),
        );
        expect(want, inInclusiveRange(rye.start, rye.end));
      },
    );

    testWidgets('scrolling the body moves the boxes with the text', (
      tester,
    ) async {
      final lines = [
        for (var i = 0; i < 160; i++) i == 120 ? 'the rye line' : 'line $i',
      ];
      final e = await _wi83Pump(tester, '${lines.join('\n')}\n');
      final text = e.robot.segmentText(0);
      await _wi83Open(e, [wi83Body(0, text)], 'rye');
      final rye = wi83Find(text, 'rye');
      final r = _wi83RowAt(e, 0, rye.start);
      final scrollable = find
          .descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(Scrollable),
          )
          .evaluate()
          .map((el) => (el as StatefulElement).state as ScrollableState)
          .firstWhere(
            (s) =>
                s.position.axis == Axis.vertical &&
                s.position.maxScrollExtent > 200,
          );
      Rect paintedGlobal() {
        final layer = wi83Layer(tester, findHighlightsKey(0, r));
        final op = wi83LayerOps(
          tester,
          findHighlightsKey(0, r),
        ).firstWhere((op) => op.isFill);
        return MatrixUtils.transformRect(layer.getTransformTo(null), op.outer);
      }

      Rect textGlobal() {
        final editable = _wi83RowEditable(tester, 0, r);
        final start = _wi83Spec(e, 0, r).textStart;
        final rect = RenderEditableLineBoxes(editable)
            .boxesFor(TextRange(start: rye.start - start, end: rye.end - start))
            .single;
        return MatrixUtils.transformRect(editable.getTransformTo(null), rect);
      }

      scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
      await tester.pump();
      final before = paintedGlobal();
      expect(
        before.center.dx,
        moreOrLessEquals(textGlobal().center.dx, epsilon: 0.05),
      );
      expect(
        before.center.dy,
        moreOrLessEquals(textGlobal().center.dy, epsilon: 1.5),
      );
      scrollable.position.jumpTo(scrollable.position.pixels + 60);
      await tester.pump();
      final after = paintedGlobal();
      expect(after.top, moreOrLessEquals(before.top - 60, epsilon: 0.05));
      expect(
        after.center.dy,
        moreOrLessEquals(textGlobal().center.dy, epsilon: 1.5),
      );
    });
  });

  group('repaint', () {
    testWidgets(
      'changing the current match repaints the old current as other and the new one as current',
      (tester) async {
        const line = 'rye one rye two rye';
        final e = await _wi83Pump(tester, '$line\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        final r = _wi83RowAt(e, 0, 0);
        List<Wi83Box> styled(List<FindPaintStyle> styles) => [
          for (var i = 0; i < 3; i++)
            ..._wi83RowBoxes(e, 0, r, wi83Find(text, 'rye', i), styles[i]),
        ];
        _wi83ExpectRow(e, 0, r, styled([_other, _current, _other]));
        final paints = debugFindHighlightPaints;
        _wi83Find(e).next();
        await tester.pump();
        expect(debugFindHighlightPaints, greaterThan(paints));
        _wi83ExpectRow(e, 0, r, styled([_other, _other, _current]));
      },
    );

    testWidgets(
      'an unrelated rebuild with unchanged ranges does not repaint the layers',
      (tester) async {
        const line = 'rye one rye two rye';
        final e = await _wi83Pump(tester, '$line\nmore\n');
        final text = e.robot.segmentText(0);
        await _wi83Open(e, [wi83Body(0, text)], 'rye', current: 1);
        expect(wi83LayerOps(tester, findHighlightsKey(0, 0)), isNotEmpty);
        final paints = debugFindHighlightPaints;
        // A new state with equal matches and current: every mount rebuilds
        // with equal ranges.
        _wi83Find(e).setSources([wi83Body(0, '$line\nmore\n')]);
        await tester.pump();
        expect(_wi83State(e).current, 1, reason: 'fixture: same current');
        expect(debugFindHighlightPaints, paints);
        // And a real change still repaints.
        _wi83Find(e).previous();
        await tester.pump();
        expect(debugFindHighlightPaints, greaterThan(paints));
      },
    );
  });
}

/// The find ops under [key], or none when no layer is mounted there.
List<Wi83Op> _wi83FindOps(WidgetTester tester, Key key) =>
    find.byKey(key).evaluate().isEmpty ? const [] : wi83LayerOps(tester, key);
