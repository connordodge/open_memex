// WI #131 (Spec #122 Requirements 13, 21, 25, 26, 36): the spelling
// viewport without whole-note work per scroll step.
//
// - A scroll pause is no viewport change for `spellCheckDebounce` (400 ms)
//   on the injected clock (`FakeClock`, moved by `SpellingEditorHarness
//   .advance`). `pumpFrames` moves only the binding's time, never the fake
//   clock, so frames alone are never a pause. A `ScrollEndNotification`
//   alone is not a pause: every wheel tick and every `jumpTo` ends with one.
// - An evaluation after a pause asks the field hosts for geometry only for
//   the rows within one screen above or below the viewport: the bound is
//   the rows the oracle ([_t131Near]) finds there from the rows' own line
//   boxes, plus a bisection's worth of probes.
// - Replies re-read only the rows holding their paragraph.
// - One `FocusManager` listener for spelling per editor, whatever the row
//   count: a counting `FocusManager` ([_T131CountingFocusManager]) stands in
//   for the binding's while the editor is pumped.
//
// Work is counted, never timed ([PerfCounters]). Count tests on N2 drive one
// event each under an explicit [_t131Timeout], so on main (an evaluation per
// scroll notification over every row) they fail by assertion.
//
// Helpers carry the `_t131` prefix. Text is invented (public repo).
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/tabs_state.dart' show NoteTab;
import 'package:open_memex_app/src/state/spell_check_controller.dart'
    show spellCheckDebounce;
import 'package:open_memex_app/src/widgets/editor/segment_view.dart'
    show SegmentViewState;
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/editor_rows_probe.dart';
import '../support/fake_spelling_service.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/long_note_fixtures.dart';
import '../support/mac_editing.dart';
import '../support/note_reveal_pump.dart' show pumpNoteReveal;
import '../support/perf_counters.dart';
import '../support/segment_editing_finder.dart';
import '../support/spelling_editor_pump.dart';

const _t131Timeout = Timeout(Duration(minutes: 8));

const _t131Ms = Duration(milliseconds: 1);

/// Slack on top of the rows within one screen: a bisection over N2's 3,000
/// row tops (12 probes), twice, plus the window's edge rows.
const _t131BisectSlack = 28;

// ---------------------------------------------------------------- notes

/// [n] bullet rows `Item <i> is fine.`; row [flagAt] (when given) reads
/// `Item <i> has wrld here.`.
String _t131Bullets(int n, {int? flagAt}) => [
  for (var i = 0; i < n; i++)
    i == flagAt ? '- Item $i has wrld here.' : '- Item $i is fine.',
].join('\n');

// ---------------------------------------------------------------- page

/// The editor page's vertical Scrollable.
ScrollableState _t131Scrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );

/// The editor viewport's global rect.
Rect _t131Viewport(WidgetTester tester) {
  final box = _t131Scrollable(tester).context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Row [r]'s global rect, from its line boxes through [host]'s accessor
/// (as `rowRectOf`, without finding the host again: a finder over N2's
/// rows costs a walk of every row).
Rect _t131RowRect(SegmentViewState host, int r) {
  final boxes = host.rowBoxes(r);
  if (boxes == null) throw TestFailure('row 0-$r is not laid out');
  final lines = boxes.lines;
  return Rect.fromPoints(
    boxes.box.localToGlobal(Offset(0, lines.first.top)),
    boxes.box.localToGlobal(Offset(boxes.box.size.width, lines.last.bottom)),
  );
}

/// Row [r]'s field text, as [host] holds it.
String _t131RowText(SegmentViewState host, int r) {
  final spec = host.rowSpec(r)!;
  return host.text.substring(spec.textStart, spec.textEnd);
}

/// The rows of text segment 0 whose laid-out rect meets the band
/// [top]..[bottom] (global), found by bisection over the rows' own line
/// boxes: (first, last), or null when none does.
(int, int)? _t131RowsIn(WidgetTester tester, double top, double bottom) {
  final host = rowsHostOf(tester);
  final count = host.rowCount;
  // The first row ending below [top].
  var lo = 0;
  var hi = count;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (_t131RowRect(host, mid).bottom > top) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  final first = lo;
  // The first row starting at or below [bottom].
  hi = count;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (_t131RowRect(host, mid).top >= bottom) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  final last = lo - 1;
  return first <= last ? (first, last) : null;
}

/// How many rows lie within one screen above or below the viewport.
int _t131Near(WidgetTester tester) {
  final v = _t131Viewport(tester);
  final rows = _t131RowsIn(tester, v.top - v.height, v.bottom + v.height);
  return rows == null ? 0 : rows.$2 - rows.$1 + 1;
}

/// One mouse wheel tick of [dy] px over the editor.
Future<void> _t131Tick(WidgetTester tester, double dy) async {
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(NoteEditor)),
      scrollDelta: Offset(0, dy),
    ),
  );
  await tester.pump();
}

/// Lets the editor open and its first checks go out and come back.
Future<void> _t131Settle(SpellingEditorHarness e) async {
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
}

/// The texts of every `check` the fake received.
List<String> _t131Checked(FakeSpellingService s) => [
  for (final c in s.callsFor('check')) c.args['text']! as String,
];

/// What the editor published for row [r] of text segment 0.
List<SpellIssue> _t131IssuesOf(
  WidgetTester tester,
  SegmentViewState host,
  int r,
) {
  final element = tester.element(
    find.byKey(ValueKey('editor-row-0-$r'), skipOffstage: false),
  );
  final registry = SpellIssueScope.maybeOf(element);
  expect(registry, isNotNull, reason: 'row $r has a SpellIssueRegistry');
  return registry!.issuesFor(host.rowController(r)!).value;
}

/// Focuses row [r]'s field and gives it [text] with the caret at [caret],
/// as the platform text input does.
Future<void> _t131Input(
  WidgetTester tester,
  SpellingEditorHarness e,
  int r,
  String text,
  int caret,
) async {
  // TEST-CHANGE (WI #132, Req 38): only the active row has a field.
  await activateSegmentRow(tester, 0, r);
  final field = e.rowFields(0).first;
  await tester.showKeyboard(field);
  await tester.pump();
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    ),
  );
  await tester.pump();
}

// ------------------------------------------------- counting FocusManager

/// A [FocusManager] that keeps its live listeners, so a test can count
/// them. It registers no global key or pointer handlers (the binding's own
/// manager keeps those), so a test using it sends no key events.
class _T131CountingFocusManager extends FocusManager {
  final listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

/// Puts a [_T131CountingFocusManager] in place of the binding's until the
/// test ends; the test unmounts its tree before then.
_T131CountingFocusManager _t131CountFocusListeners(WidgetTester tester) {
  final owner = tester.binding.buildOwner!;
  final original = owner.focusManager;
  final counting = _T131CountingFocusManager();
  owner.focusManager = counting;
  addTearDown(() => owner.focusManager = original);
  return counting;
}

void main() {
  holdFontFetches();

  setUp(PerfCounters.reset);

  // ------------------------------------------------------ the pause (AC6)

  group('evaluation once per scroll pause (AC6)', () {
    testWidgets(
      'a run of wheel ticks without a pause triggers no spell evaluation until 400 ms after the last tick',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _t131Bullets(300));
        await _t131Settle(e);
        final p = _t131Scrollable(tester).position;
        PerfCounters.reset();

        for (var i = 0; i < 5; i++) {
          final from = p.pixels;
          await _t131Tick(tester, 120);
          expect(p.pixels, greaterThan(from), reason: 'tick $i scrolled');
          await pumpFrames(tester);
          expect(
            PerfCounters.snapshot()['spellEvaluations'],
            0,
            reason: 'tick $i: frames alone are no pause',
          );
          await e.advance(const Duration(milliseconds: 100));
          expect(
            PerfCounters.snapshot()['spellEvaluations'],
            0,
            reason: 'tick $i: 100 ms is no pause',
          );
        }
        // 100 + 299 ms after the last tick.
        await e.advance(const Duration(milliseconds: 299));
        expect(
          PerfCounters.snapshot()['spellEvaluations'],
          0,
          reason: '399 ms after the last tick',
        );
        await e.advance(_t131Ms);
        expect(
          PerfCounters.snapshot()['spellEvaluations'],
          1,
          reason: '400 ms after the last tick: one evaluation',
        );
        await e.advance(const Duration(seconds: 1));
        expect(
          PerfCounters.snapshot()['spellEvaluations'],
          1,
          reason: 'one evaluation per pause',
        );
      },
      timeout: _t131Timeout,
    );

    testWidgets('a scroll end notification alone is not a spelling pause', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(tester, body: _t131Bullets(300));
      await _t131Settle(e);
      final p = _t131Scrollable(tester).position;
      PerfCounters.reset();

      // A jump starts, updates and ends a scroll: its ScrollEndNotification
      // goes out in this frame.
      p.jumpTo(p.pixels + 900);
      await tester.pump();
      await pumpFrames(tester, frames: 8);
      expect(
        PerfCounters.snapshot()['spellEvaluations'],
        0,
        reason: 'the scroll ended but no 400 ms passed',
      );

      // A second viewport change inside the pause restarts it.
      await e.advance(const Duration(milliseconds: 300));
      p.jumpTo(p.pixels + 50);
      await tester.pump();
      await e.advance(const Duration(milliseconds: 300));
      expect(
        PerfCounters.snapshot()['spellEvaluations'],
        0,
        reason: '300 ms after the last change',
      );
      await e.advance(const Duration(milliseconds: 100));
      expect(PerfCounters.snapshot()['spellEvaluations'], 1);
    }, timeout: _t131Timeout);

    testWidgets(
      'a spell evaluation after a scroll pause on N2 makes host geometry calls only for rows within one screen of the viewport',
      (tester) async {
        final note = longNote(LongNoteKind.n2Bullets120k);
        final e = await pumpSpellingEditor(tester, body: note.text);
        await _t131Settle(e);
        e.spelling.holdReplies = true;
        final p = _t131Scrollable(tester).position;
        final checksBefore = e.spelling.count('check');

        final before = PerfCounters.snapshot();
        p.jumpTo(p.maxScrollExtent / 2);
        await tester.pump();
        await e.advance(spellCheckDebounce);
        final d = PerfCounters.delta(before);

        final near = _t131Near(tester);
        expect(near, inInclusiveRange(30, 400), reason: 'one screen is rows');
        expect(d['spellEvaluations'], 1, reason: 'one evaluation per pause');
        expect(
          e.spelling.count('check'),
          greaterThan(checksBefore),
          reason: 'the pause checked the rows now near the viewport',
        );
        expect(
          d['spellHostEditableCalls'],
          lessThanOrEqualTo(near + _t131BisectSlack),
          reason: 'field geometry only for the $near rows within one screen',
        );
        expect(
          d['spellHostLineCalls'],
          lessThanOrEqualTo(near + _t131BisectSlack),
          reason: 'row lookups only for the $near rows within one screen',
        );
      },
      timeout: _t131Timeout,
    );
  });

  group('row top index (AC6)', () {
    testWidgets(
      'a spell evaluation after a scroll pause on N2 finds the rows near the viewport by a bisection of row boxes',
      (tester) async {
        final note = longNote(LongNoteKind.n2Bullets120k);
        final e = await pumpSpellingEditor(tester, body: note.text);
        await _t131Settle(e);
        e.spelling.holdReplies = true;
        final p = _t131Scrollable(tester).position;
        final count = rowsHostOf(tester).rowCount;
        expect(count, greaterThan(2000), reason: 'N2 is thousands of rows');

        p.jumpTo(p.maxScrollExtent / 2);
        await tester.pump();
        SegmentViewState.debugRowEdgeReads = 0;
        await e.advance(spellCheckDebounce);
        final reads = SegmentViewState.debugRowEdgeReads;

        expect(reads, greaterThan(0), reason: 'the evaluation read row boxes');
        // log2(count) + 1 reads for each of the two bisections, and the
        // evaluation asks for the window once or twice.
        final probes = (math.log(count) / math.ln2).ceil() + 1;
        expect(
          reads,
          lessThanOrEqualTo(4 * probes),
          reason: 'a bisection over $count rows, not a read of every row',
        );
      },
      timeout: _t131Timeout,
    );
  });

  // ---------------------------------------------------------- no miss (AC7)

  group('no visible miss (AC7)', () {
    testWidgets(
      'every row scrolled into view on N2 misspelled is checked once the pause elapses and its replies publish squiggles re-reading only their rows',
      (tester) async {
        final note = longNote(
          LongNoteKind.n2Bullets120k,
          variant: LongNoteVariant.misspelled,
        );
        // Replies wait until the test answers them: only the ones this test
        // measures are ever answered.
        final spelling = FakeSpellingService()..holdReplies = true;
        seedMisspellings(spelling, note);
        final e = await pumpSpellingEditor(
          tester,
          body: note.text,
          spelling: spelling,
        );
        await _t131Settle(e);
        final p = _t131Scrollable(tester).position;

        p.jumpTo(p.maxScrollExtent * 0.6);
        await tester.pump();
        await e.advance(spellCheckDebounce);

        final host = rowsHostOf(tester);
        final v = _t131Viewport(tester);
        final (first, last) = _t131RowsIn(tester, v.top, v.bottom)!;
        expect(last - first, greaterThan(10), reason: 'a screen of rows');
        expect(
          _t131RowText(host, first + 1),
          anyOf(contains('Speaker ${first + 1}:'), contains('Section')),
          reason: 'row i is line i of N2',
        );
        final checked = _t131Checked(spelling);
        for (var r = first; r <= last; r++) {
          // A heading row's paragraph is its text after the `## ` marker.
          final text = _t131RowText(
            host,
            r,
          ).replaceFirst(RegExp(r'^#+\s+'), '');
          expect(
            checked.any((t) => t.contains(text)),
            isTrue,
            reason: 'row $r in view ("$text") was checked after the pause',
          );
        }

        // The replies for the flagged rows in view.
        final flagged = [
          for (final (k, line) in note.flaggedLines.indexed)
            if (line >= first && line <= last) (line, note.flaggedWords[k]),
        ];
        expect(flagged, isNotEmpty, reason: 'a flagged row is in view');
        final replies = [
          for (final held in spelling.held)
            if (!held.isCompleted &&
                flagged.any(
                  (f) => held.text.contains(_t131RowText(host, f.$1)),
                ))
              held,
        ];
        expect(replies, hasLength(flagged.length));
        final before = PerfCounters.snapshot();
        for (final held in replies) {
          held.reply();
        }
        await tester.pump();
        await tester.pump();
        final d = PerfCounters.delta(before);

        expect(
          d['spellHostLineCalls'],
          lessThanOrEqualTo(4 * replies.length + 16),
          reason:
              '${replies.length} replies re-read only the rows holding '
              'their paragraphs',
        );
        for (final (r, word) in flagged) {
          final text = _t131RowText(host, r);
          final at = text.indexOf(word);
          expect(at, isNonNegative);
          expect(
            [
              for (final i in _t131IssuesOf(tester, host, r))
                (i.kind, i.start, i.length),
            ],
            contains((SpellIssueKind.spelling, at, word.length)),
            reason: 'row $r shows the squiggle under $word',
          );
        }
      },
      timeout: _t131Timeout,
    );
  });

  // ----------------------------------------------- focus listeners (AC8)

  group('one spelling focus listener per editor (AC8)', () {
    testWidgets(
      'the editor adds the same number of FocusManager listeners whatever its row count',
      (tester) async {
        final focus = _t131CountFocusListeners(tester);
        final db = FakeVaultDb.v5()
          ..seedNote(id: 't131-small', title: 'Small', content: _t131Bullets(5))
          ..seedNote(id: 't131-big', title: 'Big', content: _t131Bullets(300));
        final h = await pumpNoteReveal(tester, db: db, open: 't131-small');
        await pumpFrames(tester);
        expect(rowsHostOf(tester).rowCount, 5);
        final small = focus.listeners.length;

        await h.navigate(const NoteTab('t131-big'));
        await pumpFrames(tester);
        expect(h.body().note.id, 't131-big');
        expect(rowsHostOf(tester).rowCount, 300);
        final big = focus.listeners.length;

        expect(
          big,
          small,
          reason: '300 rows add ${big - small} listeners over 5 rows',
        );
        // Unmount while the counting manager is still in place.
        await tester.pumpWidget(const SizedBox());
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'a held misspelling at the caret in one row of a long bullet note shows once focus moves to another row',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: _t131Bullets(60),
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _t131Settle(e);
        const typed = 'Item 10 teh is fine.';
        await _t131Input(tester, e, 10, typed, 'Item 10 teh'.length);
        await e.advance(spellCheckDebounce);
        await e.advance(const Duration(seconds: 1));
        expect(_t131Checked(e.spelling), contains(contains('Item 10 teh')));
        expect(
          _t131IssuesOf(tester, rowsHostOf(tester), 10),
          isEmpty,
          reason: 'caret touches it',
        );

        await activateRow(tester, 0, 20);
        await pumpFrames(tester);
        expect(
          [
            for (final i in _t131IssuesOf(tester, rowsHostOf(tester), 10))
              (i.kind, i.start, i.length),
          ],
          [(SpellIssueKind.spelling, 'Item 10 '.length, 3)],
          reason: 'focus left row 10',
        );
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'Check Document Now from the first row of a long bullet note selects the misspelling in a far row and opens its menu',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: _t131Bullets(150, flagAt: 130),
          spelling: FakeSpellingService()
            ..misspell('wrld', corrections: const ['world']),
        );
        await _t131Settle(e);
        await _t131Input(tester, e, 0, 'Item 0 is fine.', 0);
        await pumpFrames(tester);

        e.spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        await pumpFrames(tester);

        final host = rowsHostOf(tester);
        final row = host.rowController(130)!;
        final at = row.text.indexOf('wrld');
        expect(at, isNonNegative);
        expect(
          (row.selection.start, row.selection.end),
          (at, at + 4),
          reason: 'the far row selects its misspelling',
        );
        final rect = _t131RowRect(host, 130);
        final v = _t131Viewport(tester);
        expect(
          rect.top >= v.top - 0.5 && rect.bottom <= v.bottom + 0.5,
          isTrue,
          reason: 'the far row scrolled into view',
        );
        expect(find.byType(SpellingMenu), findsOneWidget);
      },
      variant: macOnly,
      timeout: _t131Timeout,
    );
  });
}
