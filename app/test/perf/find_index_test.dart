// WI #130 (Spec #122 Requirements 8, 22a, 36; Ledger L11): Find in note
// match index. Work for a Find change scales with the matches that changed,
// not rows x matches:
//
// - a per-segment match index (`FindMatchIndex`, binary search by offset)
//   serves `findFieldDecoration` and `findPaintRanges`;
// - a row's find decoration notifies only when that row's matches or the
//   current match in it change;
// - a Find-bar keystroke on N1's one 120k row walks no whole-text lines.
//
// Count tests pump the real workspace (`pumpSpellingEditor`) on the #125
// fixtures and read the #125 counters (`PerfCounters`) plus this WI's
// `debugFindMatchReads` around one event, after a stated warm-up. Bounds are
// counts, never times. A row may run a step once per frame, and a test pumps
// two frames per event ([_wi130PerRow]).
//
// The rows' decorations are read through each row field's controller
// (`LivePreviewController.findDecoration`): #132 (idle rows) mounts a field
// for the active row only and must move [_wi130Decorations] onto the rows
// host then.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_in_note_host.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../support/app_harness.dart';
import '../support/editor_rows_probe.dart';
import '../support/font_fetch_hold.dart';
import '../support/long_note_fixtures.dart';
import '../support/mac_editing.dart';
import '../support/perf_counters.dart';
import '../support/segment_editing_finder.dart';
import '../support/spelling_editor_pump.dart';

/// On main one N2 Find-bar keystroke runs ~10-15 s in the debug runner:
/// long enough to fail by assertion there, short of a timeout.
const _wi130Timeout = Timeout(Duration(minutes: 8));

/// How often one involved row may run a counted step for one event (once
/// per frame, two frames).
const _wi130PerRow = 2;

final _wi130N1 = longNote(LongNoteKind.n1Plain120k);
final _wi130N2 = longNote(LongNoteKind.n2Bullets120k);

/// [note]'s text as a note body (a trailing line break).
String _wi130Body(LongNote note) => '${note.text}\n';

/// One counter's current value, by its [PerfCounters] name.
int _n(String name) => PerfCounters.snapshot()[name]!;

/// Resets every counter this file reads.
void _wi130Reset() {
  PerfCounters.reset();
  debugFindMatchReads = 0;
}

/// `ceil(log2(n + 1))`: the depth of a binary search over [n] items.
int _wi130Log(int n) => (math.log(n + 1) / math.ln2).ceil();

/// The most matches one index lookup over [n] matches may read: two binary
/// searches and a few boundary reads.
int _wi130LookupBound(int n) => 2 * _wi130Log(n) + 4;

/// The most matches one Find change may read over [rows] rows and [n]
/// matches: per frame (two) and per lookup kind (decoration and paint
/// ranges), every row's lookups (one for its matches, one for outlines)
/// plus each match it returns, twice over. Far below `rows * n`.
int _wi130ReadBound(int rows, int n) =>
    4 * (rows * 2 * _wi130LookupBound(n) + 2 * n);

/// The Find bar's query field.
final Finder _wi130Field = find.descendant(
  of: find.byKey(findBarFieldKey),
  matching: find.byType(EditableText),
);

FindInNoteState _wi130State(SpellingEditorHarness e) =>
    e.container.read(findInNoteProvider);

/// Opens the Find bar as the native menu does (Cmd+F), then types [query]
/// into its field.
Future<void> _wi130Open(SpellingEditorHarness e, String query) async {
  e.container
      .read(findMenuActionsProvider.notifier)
      .dispatch(FindMenuAction.show);
  await pumpFrames(e.tester);
  expect(find.byKey(findBarKey), findsOneWidget, reason: 'the bar opened');
  if (query.isNotEmpty) {
    await e.tester.enterText(_wi130Field, query);
    await pumpFrames(e.tester);
  }
  expect(_wi130State(e).query, query);
}

/// One Find-bar keystroke: the field's text becomes [query], then two
/// frames.
Future<void> _wi130Key(WidgetTester tester, String query) async {
  await tester.enterText(_wi130Field, query);
  await tester.pump();
  await tester.pump();
}

/// Every row spec of text segment 0, in row order.
List<RowSpec> _wi130Specs(WidgetTester tester) {
  final host = rowsHostOf(tester);
  return [for (var i = 0; i < host.rowCount; i++) host.rowSpec(i)!];
}

/// The matches of text segment 0 (body) in [state], with their indices
/// into `state.matches`, in order.
List<(int, FindMatch)> _wi130Body0(FindInNoteState state) => [
  for (final (i, m) in state.matches.indexed)
    if (m.segment == 0 && m.kind == FindSourceKind.body) (i, m),
];

/// For each of [specs], the body matches of segment 0 touching the row's
/// `[textStart, textEnd)` (a sweep: rows and matches are both in order).
List<List<(int, FindMatch)>> _wi130PerRowMatches(
  FindInNoteState state,
  List<RowSpec> specs,
) {
  final matches = _wi130Body0(state);
  final out = <List<(int, FindMatch)>>[];
  var j = 0;
  for (final spec in specs) {
    while (j < matches.length && matches[j].$2.end <= spec.textStart) {
      j++;
    }
    final row = <(int, FindMatch)>[];
    for (var k = j; k < matches.length; k++) {
      final m = matches[k].$2;
      if (m.start >= spec.textEnd) break;
      if (m.end > spec.textStart) row.add(matches[k]);
    }
    out.add(row);
  }
  return out;
}

/// What row [spec]'s highlight layer paints for [state] on a note with no
/// hidden matches: every match touching the row, clipped and row-local,
/// current or other.
List<FindPaintRange> _wi130ExpectedPaint(
  FindInNoteState state,
  RowSpec spec,
  List<(int, FindMatch)> touching,
) {
  if (!state.open || state.query.isEmpty) return const [];
  return [
    for (final (i, m) in touching)
      if (!m.hidden)
        FindPaintRange(
          math.max(m.start, spec.textStart) - spec.textStart,
          math.min(m.end, spec.textEnd) - spec.textStart,
          i == state.current ? FindPaintStyle.current : FindPaintStyle.other,
        ),
  ];
}

/// Row [spec]'s find decoration for [state] (D7): ink on every match
/// touching it, the current match's range, its reveal when hidden.
FindDecoration? _wi130ExpectedDecoration(
  FindInNoteState state,
  RowSpec spec,
  List<(int, FindMatch)> touching,
) {
  if (!state.open || state.query.isEmpty || touching.isEmpty) return null;
  TextRange? current;
  TextRange? reveal;
  final ink = <TextRange>[];
  for (final (i, m) in touching) {
    final range = TextRange(
      start: math.max(m.start, spec.textStart) - spec.textStart,
      end: math.min(m.end, spec.textEnd) - spec.textStart,
    );
    ink.add(range);
    if (i == state.current) {
      current = range;
      if (m.hidden) reveal = range;
    }
  }
  return FindDecoration(revealRange: reveal, inkRanges: ink, current: current);
}

/// Every row highlight layer of text segment 0 (Key
/// `find-highlights-0-<r>`), by row index.
Map<int, FindHighlights> _wi130Layers(WidgetTester tester, int rows) {
  final byKey = {
    for (final w in tester.widgetList<FindHighlights>(
      find.descendant(
        of: find.byKey(textSegmentKey(0), skipOffstage: false),
        matching: find.byType(FindHighlights, skipOffstage: false),
        skipOffstage: false,
      ),
    ))
      w.key: w,
  };
  return {for (var r = 0; r < rows; r++) r: ?byKey[findHighlightsKey(0, r)]};
}

/// Every row field's find decoration in text segment 0, by row index (see
/// the file comment: #132 moves this onto the rows host).
Map<int, FindDecoration?> _wi130Decorations(
  WidgetTester tester,
  List<RowSpec> specs,
) {
  final host = rowsHostOf(tester);
  final rowAt = {for (final (r, spec) in specs.indexed) spec.textStart: r};
  final out = <int, FindDecoration?>{};
  for (final field in tester.widgetList<EditableText>(
    find.descendant(
      of: find.byKey(textSegmentKey(0), skipOffstage: false),
      matching: find.byType(EditableText, skipOffstage: false),
      skipOffstage: false,
    ),
  )) {
    final controller = field.controller;
    if (controller is! LivePreviewController) continue;
    final start = host.rowTextStartOf(controller);
    if (start == null) continue;
    if (rowAt[start] case final r?) {
      out[r] = controller.findDecoration?.value;
    }
  }
  return out;
}

/// Every row of text segment 0 paints and decorates exactly [state]'s
/// matches in it ([_wi130ExpectedPaint], [_wi130ExpectedDecoration]).
void _wi130ExpectRows(
  WidgetTester tester,
  FindInNoteState state,
  List<RowSpec> specs, {
  required String when,
}) {
  final touching = _wi130PerRowMatches(state, specs);
  final layers = _wi130Layers(tester, specs.length);
  final decorations = _wi130Decorations(tester, specs);
  expect(layers, hasLength(specs.length), reason: '$when: a layer per row');
  expect(
    decorations,
    hasLength(specs.length),
    reason: '$when: a field per row',
  );
  for (final (r, spec) in specs.indexed) {
    final paint = _wi130ExpectedPaint(state, spec, touching[r]);
    final ranges = layers[r]!.ranges;
    if (!_wi130SameRanges(ranges, paint)) {
      fail('$when: row $r paints $ranges, not $paint');
    }
    final decoration = _wi130ExpectedDecoration(state, spec, touching[r]);
    if (decorations[r] != decoration) {
      fail(
        '$when: row $r is decorated ${_wi130Show(decorations[r])}, '
        'not ${_wi130Show(decoration)}',
      );
    }
  }
}

bool _wi130SameRanges(List<FindPaintRange> a, List<FindPaintRange> b) =>
    a.length == b.length && a.toSet().containsAll(b);

String _wi130Show(FindDecoration? d) => d == null
    ? 'null'
    : 'ink ${d.inkRanges} current ${d.current} reveal ${d.revealRange}';

/// How many of [specs] paint or decorate differently in [after] than in
/// [before].
int _wi130Changed(
  FindInNoteState before,
  FindInNoteState after,
  List<RowSpec> specs,
) {
  final was = _wi130PerRowMatches(before, specs);
  final now = _wi130PerRowMatches(after, specs);
  var changed = 0;
  for (final (r, spec) in specs.indexed) {
    final paintBefore = _wi130ExpectedPaint(before, spec, was[r]);
    final paintAfter = _wi130ExpectedPaint(after, spec, now[r]);
    if (!_wi130SameRanges(paintBefore, paintAfter) ||
        _wi130ExpectedDecoration(before, spec, was[r]) !=
            _wi130ExpectedDecoration(after, spec, now[r])) {
      changed++;
    }
  }
  return changed;
}

/// The index of the row of [specs] holding [m]'s start.
int _wi130RowOf(List<RowSpec> specs, FindMatch m) =>
    specs.lastIndexWhere((s) => s.textStart <= m.start);

/// Lets queued tab persistence finish before the harness deletes the temp
/// vault (`UiStateStore` writes are unawaited).
Future<void> _wi130Flush(WidgetTester tester, SpellingEditorHarness e) async {
  await pumpFrames(tester);
  final store = e.workspace.read(tabsProvider.notifier).store;
  var flushed = false;
  unawaited(store.flush().then((_) => flushed = true));
  for (var i = 0; i < 5000 && !flushed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
  expect(flushed, isTrue, reason: 'tab persistence finished');
}

// ------------------------------------------------------------ pure fixtures

FindMatch _wi130Match(
  int segment,
  int start,
  int end, {
  FindSourceKind kind = FindSourceKind.body,
}) => FindMatch(segment: segment, kind: kind, start: start, end: end);

/// The indices `[from, to)` [index] returns for one lookup, as a list.
List<int> _wi130Touching(
  FindMatchIndex index, {
  int segment = 0,
  FindSourceKind kind = FindSourceKind.body,
  required int start,
  required int end,
}) {
  final run = index.touching(
    segment: segment,
    kind: kind,
    start: start,
    end: end,
  );
  return [for (var i = run.from; i < run.to; i++) i];
}

/// The indices of [matches] of source ([segment], [kind]) touching
/// `[start, end)`, by a scan of every match.
List<int> _wi130Scan(
  List<FindMatch> matches, {
  int segment = 0,
  FindSourceKind kind = FindSourceKind.body,
  required int start,
  required int end,
}) => [
  for (final (i, m) in matches.indexed)
    if (m.segment == segment &&
        m.kind == kind &&
        m.start < end &&
        m.end > start)
      i,
];

/// N2's text as one body source (segment 0) and its matches of [query],
/// with the current match in the middle.
FindInNoteState _wi130N2State(String query) {
  final text = _wi130Body(_wi130N2);
  final sources = [
    FindSource(segment: 0, kind: FindSourceKind.body, text: text),
  ];
  final matches = findMatches(sources, query);
  return FindInNoteState(
    open: true,
    query: query,
    lastQuery: query,
    sources: sources,
    matches: matches,
    current: matches.length ~/ 2,
  );
}

void main() {
  holdFontFetches();

  setUp(_wi130Reset);

  // ------------------------------------------------------ the index (AC5)

  group('the match index (AC5)', () {
    // Segment 0's rows: r0 [0, 10), r1 [11, 20), r2 [21, 21) empty,
    // r3 [22, 40), r4 [41, 50) (the segment's last row). b spans the r0/r1
    // boundary; c ends where r2 starts; d starts after r2. Then a card
    // (segment 1) and another text segment (2).
    final matches = [
      _wi130Match(0, 2, 5), // 0 a
      _wi130Match(0, 8, 13), // 1 b
      _wi130Match(0, 15, 21), // 2 c
      _wi130Match(0, 22, 25), // 3 d
      _wi130Match(0, 41, 44), // 4 e
      _wi130Match(0, 46, 50), // 5 f
      _wi130Match(1, 0, 3, kind: FindSourceKind.card), // 6
      _wi130Match(2, 5, 8), // 7
    ];

    test(
      'the match index returns exactly the matches touching rows at the start middle and end of a segment including empty rows and a match spanning a row boundary',
      () {
        final index = FindMatchIndex(matches);
        for (final (what, start, end, expected) in [
          ('the first row', 0, 10, [0, 1]),
          ('the middle row after the spanning match', 11, 20, [1, 2]),
          ('the empty row where a match ends', 21, 21, <int>[]),
          ('the row after the empty row', 22, 40, [3]),
          ('the last row', 41, 50, [4, 5]),
          ('an empty row before every match', 0, 0, <int>[]),
          ('an empty row at the segment end', 50, 50, <int>[]),
          ('a range between matches', 5, 8, <int>[]),
          ('a range past every match', 60, 70, <int>[]),
          ('the whole segment', 0, 50, [0, 1, 2, 3, 4, 5]),
        ]) {
          expect(
            _wi130Touching(index, start: start, end: end),
            expected,
            reason: what,
          );
          expect(
            _wi130Touching(index, start: start, end: end),
            _wi130Scan(matches, start: start, end: end),
            reason: '$what agrees with a scan',
          );
        }
        expect(_wi130Touching(index, segment: 2, start: 0, end: 10), [
          7,
        ], reason: 'a later text segment');
        expect(
          _wi130Touching(
            index,
            segment: 1,
            kind: FindSourceKind.card,
            start: 0,
            end: 3,
          ),
          [6],
          reason: 'a card',
        );
        expect(
          _wi130Touching(index, segment: 1, start: 0, end: 3),
          isEmpty,
          reason: 'segment 1 has no body matches',
        );
        expect(
          _wi130Touching(index, segment: 3, start: 0, end: 50),
          isEmpty,
          reason: 'a segment with no matches',
        );
      },
    );

    test('the match index agrees with a scan for every row of N2', () {
      final state = _wi130N2State('e');
      final text = state.sources.single.text;
      final specs = splitRows(text, atSegmentStart: true);
      expect(specs.length, greaterThan(2900), reason: 'fixture: N2 rows');
      final index = FindMatchIndex(state.matches);
      for (final (r, spec) in specs.indexed) {
        final got = _wi130Touching(
          index,
          start: spec.textStart,
          end: spec.textEnd,
        );
        final want = _wi130Scan(
          state.matches,
          start: spec.textStart,
          end: spec.textEnd,
        );
        if (!listEquals(got, want)) {
          fail('row $r [${spec.textStart}, ${spec.textEnd}): $got, not $want');
        }
      }
    });

    test(
      'one match index lookup reads O(log n) matches, never every match',
      () {
        final state = _wi130N2State('e');
        final n = state.matches.length;
        expect(n, greaterThan(10000), reason: 'fixture: matches of e');
        final index = FindMatchIndex(state.matches);
        final text = state.sources.single.text;
        for (final (what, start, end) in [
          ('the first row', 0, 20),
          ('a middle row', text.length ~/ 2, text.length ~/ 2 + 30),
          ('the last row', text.length - 30, text.length),
        ]) {
          debugFindMatchReads = 0;
          final run = index.touching(
            segment: 0,
            kind: FindSourceKind.body,
            start: start,
            end: end,
          );
          expect(run.to, greaterThan(run.from), reason: '$what has matches');
          expect(
            debugFindMatchReads,
            inInclusiveRange(1, _wi130LookupBound(n)),
            reason: '$what: a lookup counts its reads and reads O(log n)',
          );
        }
      },
    );

    test(
      'findFieldDecoration and findPaintRanges over every row of N2 read matches by index not rows times matches',
      () {
        final state = _wi130N2State('e');
        final specs = splitRows(
          state.sources.single.text,
          atSegmentStart: true,
        );
        final n = state.matches.length;
        final touching = _wi130PerRowMatches(state, specs);
        debugFindMatchReads = 0;
        for (final (r, spec) in specs.indexed) {
          final decoration = findFieldDecoration(
            state,
            segment: 0,
            kind: FindSourceKind.body,
            start: spec.textStart,
            end: spec.textEnd,
          );
          final want = _wi130ExpectedDecoration(state, spec, touching[r]);
          if (decoration != want) {
            fail(
              'row $r decoration ${_wi130Show(decoration)}, '
              'not ${_wi130Show(want)}',
            );
          }
          final paint = findPaintRanges(
            state,
            segment: 0,
            kind: FindSourceKind.body,
            start: spec.textStart,
            end: spec.textEnd,
          );
          final wantPaint = _wi130ExpectedPaint(state, spec, touching[r]);
          if (!_wi130SameRanges(paint, wantPaint)) {
            fail('row $r paints $paint, not $wantPaint');
          }
        }
        // One pass of each over every row: within a quarter of
        // [_wi130ReadBound]'s two frames; rows x matches is ~3,000 x 10,000.
        expect(
          debugFindMatchReads,
          lessThanOrEqualTo(_wi130ReadBound(specs.length, n) ~/ 2),
          reason: 'reads for ${specs.length} rows over $n matches',
        );
      },
    );
  });

  // ------------------------------------------- Find-bar keystrokes (AC1)

  group('Find-bar keystrokes on N2 (AC1)', () {
    testWidgets(
      'a Find-bar keystroke on N2 updates find decorations only for the rows whose matches changed',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi130Body(_wi130N2));
        // Warm-up: the bar opened on a query, then one priming keystroke.
        await _wi130Open(e, 'Speaker 2');
        await _wi130Key(tester, 'Speaker 29');
        await pumpFrames(tester);
        final specs = _wi130Specs(tester);
        final before = _wi130State(e);
        _wi130Reset();
        await _wi130Key(tester, 'Speaker 299');
        final updates = _n('findHighlightUpdates');
        final spans = _n('buildTextSpan');
        final after = _wi130State(e);
        expect(after.query, 'Speaker 299', reason: 'the keystroke landed');
        final changed = _wi130Changed(before, after, specs);
        // Speaker 29, 290-299 and 2900-2999 (no headings): their matches
        // change; no other row has one before or after.
        expect(changed, inInclusiveRange(100, 120), reason: 'fixture');
        expect(
          updates,
          lessThanOrEqualTo(_wi130PerRow * changed),
          reason:
              'find decoration updates for $changed changed rows of '
              '${specs.length}',
        );
        expect(
          spans,
          lessThanOrEqualTo(_wi130PerRow * changed),
          reason: 'spans rebuilt for the changed rows only',
        );
        _wi130ExpectRows(tester, after, specs, when: 'after the keystroke');
        await _wi130Flush(tester, e);
      },
      timeout: _wi130Timeout,
    );

    testWidgets(
      'a Find-bar keystroke on N2 with a query matching every line reads matches by index not rows times matches',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi130Body(_wi130N2));
        // Warm-up: the bar opened (on the empty last query).
        await _wi130Open(e, '');
        await pumpFrames(tester);
        final specs = _wi130Specs(tester);
        _wi130Reset();
        await _wi130Key(tester, 'e');
        final updates = _n('findHighlightUpdates');
        final reads = debugFindMatchReads;
        final after = _wi130State(e);
        final n = after.matches.length;
        final touching = _wi130PerRowMatches(after, specs);
        expect(
          [
            for (final (r, row) in touching.indexed)
              if (row.isEmpty && specs[r].textEnd > specs[r].textStart) r,
          ],
          isEmpty,
          reason: 'fixture: e matches every line (the empty last row aside)',
        );
        expect(
          updates,
          lessThanOrEqualTo(_wi130PerRow * specs.length),
          reason: 'every row changed: at most one update per frame each',
        );
        expect(
          reads,
          lessThanOrEqualTo(_wi130ReadBound(specs.length, n)),
          reason:
              'matches read for ${specs.length} rows over $n matches '
              '(rows x matches is ${specs.length * n})',
        );
        _wi130ExpectRows(tester, after, specs, when: 'after the keystroke');
        await _wi130Flush(tester, e);
      },
      timeout: _wi130Timeout,
    );
  });

  // ------------------------------------------------------ next match (AC2)

  group('next match on N2 (AC2)', () {
    for (final (name, how, step) in [
      (
        'enter in the Find bar on N2 updates find decorations only for the old and the new current match rows',
        'enter in the Find bar',
        (WidgetTester tester, SpellingEditorHarness e) async {
          await tester.sendKeyEvent(
            LogicalKeyboardKey.enter,
            platform: 'macos',
          );
        },
      ),
      (
        'cmd g on N2 updates find decorations only for the old and the new current match rows',
        'cmd g',
        (WidgetTester tester, SpellingEditorHarness e) async {
          e.container
              .read(findMenuActionsProvider.notifier)
              .dispatch(FindMenuAction.next);
        },
      ),
    ]) {
      testWidgets(name, (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi130Body(_wi130N2));
        await _wi130Open(e, 'Speaker 29');
        // Warm-up: one step.
        await step(tester, e);
        await pumpFrames(tester);
        final specs = _wi130Specs(tester);
        final before = _wi130State(e);
        final oldRow = _wi130RowOf(specs, before.currentMatch!);
        _wi130Reset();
        await step(tester, e);
        await tester.pump();
        await tester.pump();
        final updates = _n('findHighlightUpdates');
        final spans = _n('buildTextSpan');
        final after = _wi130State(e);
        expect(
          after.current,
          before.current! + 1,
          reason: '$how stepped to the next match',
        );
        final newRow = _wi130RowOf(specs, after.currentMatch!);
        expect(newRow, isNot(oldRow), reason: 'fixture: one match per row');
        expect(
          updates,
          inInclusiveRange(2, 2 * _wi130PerRow),
          reason: 'find decoration updates: the old and the new row only',
        );
        expect(
          spans,
          lessThanOrEqualTo(2 * _wi130PerRow),
          reason: 'spans rebuilt for the old and the new row only',
        );
        final layers = _wi130Layers(tester, specs.length);
        expect(layers[oldRow]!.ranges.map((r) => r.style), [
          FindPaintStyle.other,
        ], reason: 'the old row no longer paints the current match');
        expect(layers[newRow]!.ranges.map((r) => r.style), [
          FindPaintStyle.current,
        ], reason: 'the new row paints the current match');
        _wi130ExpectRows(tester, after, specs, when: 'after $how');
        await _wi130Flush(tester, e);
      }, timeout: _wi130Timeout);
    }
  });

  // ------------------------------------------------------ N1's row (AC3)

  group('Find-bar keystrokes on N1 (AC3)', () {
    testWidgets('a Find-bar keystroke on N1 walks no whole text lines', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(tester, body: _wi130Body(_wi130N1));
      final specs = _wi130Specs(tester);
      expect(specs, hasLength(1), reason: 'fixture: N1 is one prose row');
      // Warm-up: the bar opened on a query, then one priming keystroke.
      await _wi130Open(e, 'Speaker 2');
      await _wi130Key(tester, 'Speaker 29');
      await pumpFrames(tester);
      _wi130Reset();
      await _wi130Key(tester, 'Speaker 299');
      await pumpFrames(tester);
      final after = _wi130State(e);
      expect(after.query, 'Speaker 299', reason: 'the keystroke landed');
      expect(after.matches, hasLength(11), reason: 'fixture: 299, 2990-2999');
      expect(
        (_n('editableLineWalks'), _n('paragraphLineWalks')),
        (0, 0),
        reason: 'whole-text line walks (field, paragraph)',
      );
      expect(
        (_n('editableLineMeasures'), _n('paragraphLineMeasures')),
        (0, 0),
        reason: 'whole-text measures (field, paragraph)',
      );
      _wi130ExpectRows(tester, after, specs, when: 'after the keystroke');
      await _wi130Flush(tester, e);
    }, timeout: _wi130Timeout);
  });

  // --------------------------------------- rendering as on main (AC4)

  group('find rendering stays as on main (AC4)', () {
    const linkLine =
        'See [one](https://example.com/rye) and [two](https://example.com/rye-two) here.';
    const short =
        '- rye one\n'
        '- plain two\n'
        '- rye three and rye again\n'
        '$linkLine\n'
        '- last rye\n';

    testWidgets(
      'a step and a close on a short note keep every rows find highlights and decorations exact',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: short);
        await _wi130Open(e, 'rye');
        final specs = _wi130Specs(tester);
        // The link line's URL matches are hidden: compare the other rows.
        final link = specs.indexWhere(
          (s) => rowsHostOf(
            tester,
          ).text.substring(s.textStart, s.textEnd).startsWith('See '),
        );
        expect(link, greaterThan(0), reason: 'fixture: the link row');
        void expectPlainRows(String when) {
          final state = _wi130State(e);
          final touching = _wi130PerRowMatches(state, specs);
          final layers = _wi130Layers(tester, specs.length);
          final decorations = _wi130Decorations(tester, specs);
          for (final (r, spec) in specs.indexed) {
            if (r == link) continue;
            expect(
              layers[r]!.ranges.toSet(),
              _wi130ExpectedPaint(state, spec, touching[r]).toSet(),
              reason: '$when: row $r paints',
            );
            expect(
              decorations[r],
              _wi130ExpectedDecoration(state, spec, touching[r]),
              reason: '$when: row $r decoration',
            );
          }
        }

        expectPlainRows('opened');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
        await pumpFrames(tester);
        expect(_wi130State(e).current, 1, reason: 'stepped');
        expectPlainRows('after a step');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
        await pumpFrames(tester);
        expect(_wi130State(e).open, isFalse, reason: 'closed');
        final layers = _wi130Layers(tester, specs.length);
        final decorations = _wi130Decorations(tester, specs);
        for (var r = 0; r < specs.length; r++) {
          expect(layers[r]!.ranges, isEmpty, reason: 'closed: row $r paints');
          expect(decorations[r], isNull, reason: 'closed: row $r decoration');
        }
      },
    );

    testWidgets(
      'typing a match into the body keeps every rows find highlights on its own matches',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: short);
        await _wi130Open(e, 'rye');
        final total = _wi130State(e).matches.length;
        // Row 1 (`- plain two`): its field takes the caret; then `rye `
        // arrives as the platform's text input types it.
        await activateRow(tester, 0, 1);
        final state = tester.testTextInput.editingState!;
        final value = TextEditingValue.fromJSON(state);
        final next = TextEditingValue(
          text: value.text.replaceRange(0, 0, 'rye '),
          selection: const TextSelection.collapsed(offset: 4),
        );
        tester.testTextInput.updateEditingValue(next);
        await pumpFrames(tester);
        final after = _wi130State(e);
        expect(after.matches, hasLength(total + 1), reason: 'a new match');
        final specs = _wi130Specs(tester);
        final touching = _wi130PerRowMatches(after, specs);
        final layers = _wi130Layers(tester, specs.length);
        final decorations = _wi130Decorations(tester, specs);
        expect(touching[1], hasLength(1), reason: 'row 1 holds the new one');
        for (final (r, spec) in specs.indexed) {
          if (rowsHostOf(
            tester,
          ).text.substring(spec.textStart, spec.textEnd).startsWith('See ')) {
            continue;
          }
          expect(
            layers[r]!.ranges.toSet(),
            _wi130ExpectedPaint(after, spec, touching[r]).toSet(),
            reason: 'row $r paints',
          );
          expect(
            decorations[r],
            _wi130ExpectedDecoration(after, spec, touching[r]),
            reason: 'row $r decoration',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a hidden current match reveals its line and a hidden match on that line paints as visible',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: short);
        await _wi130Open(e, 'rye');
        final specs = _wi130Specs(tester);
        final host = rowsHostOf(tester);
        final link = specs.indexWhere(
          (s) => host.text.substring(s.textStart, s.textEnd) == linkLine,
        );
        expect(link, greaterThan(0), reason: 'fixture: the link row');
        final url1 = linkLine.indexOf('rye');
        final url2 = linkLine.indexOf('rye', url1 + 3);
        final label1 = linkLine.indexOf('one');
        final label2 = linkLine.indexOf('two');
        // Step to the first URL match (hidden).
        for (var i = 0; i < 10 && !_wi130State(e).currentMatch!.hidden; i++) {
          await tester.sendKeyEvent(
            LogicalKeyboardKey.enter,
            platform: 'macos',
          );
          await pumpFrames(tester);
        }
        expect(_wi130State(e).currentMatch!.hidden, isTrue, reason: 'stepped');
        var layer = _wi130Layers(tester, specs.length)[link]!;
        expect(layer.ranges.toSet(), {
          FindPaintRange(url1, url1 + 3, FindPaintStyle.current),
          FindPaintRange(url2, url2 + 3, FindPaintStyle.other),
        }, reason: 'the current line reveals: both URL matches show');
        expect(
          _wi130Decorations(tester, specs)[link]?.revealRange,
          TextRange(start: url1, end: url1 + 3),
          reason: 'the row field reveals the current match',
        );
        // Two steps on: the plain match of the next row is current.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
        await pumpFrames(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
        await pumpFrames(tester);
        expect(_wi130State(e).currentMatch!.hidden, isFalse);
        layer = _wi130Layers(tester, specs.length)[link]!;
        expect(layer.ranges.toSet(), {
          FindPaintRange(label1, label1 + 3, FindPaintStyle.outline),
          FindPaintRange(label2, label2 + 3, FindPaintStyle.outline),
        }, reason: 'not revealed: both URL matches outline their labels');
        expect(
          _wi130Decorations(tester, specs)[link]?.revealRange,
          isNull,
          reason: 'nothing reveals the link row now',
        );
      },
    );

    testWidgets(
      'a table showing its grid paints no find highlights in its row and its cells paint the matches',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body:
              '- rye before\n'
              '| Grain | Note |\n'
              '| --- | --- |\n'
              '| rye | dark rye |\n'
              '- rye after\n',
        );
        await _wi130Open(e, 'rye');
        final specs = _wi130Specs(tester);
        final table = specs.indexWhere((s) => s.kind == RowKind.table);
        expect(table, greaterThan(0), reason: 'fixture: the table row');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
        await pumpFrames(tester);
        final layers = _wi130Layers(tester, specs.length);
        expect(
          layers[table]!.ranges,
          isEmpty,
          reason: 'the grid row layer paints nothing',
        );
        expect(layers[0]!.ranges, isNotEmpty, reason: 'the row above paints');
        final cells = tester
            .widgetList<FindHighlights>(
              find.byWidgetPredicate((w) {
                final k = w.key;
                return w is FindHighlights &&
                    k is ValueKey<String> &&
                    k.value.startsWith('find-highlights-grid-0-');
              }),
            )
            .expand((w) => w.ranges)
            .toList();
        expect(cells, hasLength(2), reason: 'both cell matches paint');
        expect(
          cells.where((r) => r.style == FindPaintStyle.current),
          hasLength(1),
          reason: 'the current match is a cell match',
        );
      },
    );

    testWidgets(
      'a rows find highlights paint under its selection fill squiggles and text',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: short);
        await _wi130Open(e, 'rye');
        final layer = find.byKey(findHighlightsKey(0, 0));
        final stack = find
            .ancestor(of: layer, matching: find.byType(Stack))
            .first;
        final row = find.descendant(
          of: stack,
          matching: find.byType(EditorRow),
        );
        expect(row, findsOneWidget, reason: 'the row sits in the same stack');
        final children = tester
            .renderObject<RenderStack>(stack)
            .getChildrenAsList();
        int slot(RenderObject o) => children.indexWhere((c) {
          RenderObject? node = o;
          while (node != null && !identical(node, c)) {
            node = node.parent;
          }
          return node != null;
        });
        final under = slot(tester.renderObject(layer));
        final over = slot(tester.renderObject(row));
        expect(under, isNonNegative);
        expect(
          under,
          lessThan(over),
          reason: 'the highlights paint before (under) the row',
        );
      },
    );
  });
}
