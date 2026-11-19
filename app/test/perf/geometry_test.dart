// WI #126 (Spec #122 R10, R14, R15, R16, R36; TD1, TD2): count gates for
// lazy, range-local line-box geometry on the long-note fixtures (#125).
//
// Each test pumps the real note editor (`pumpSpellingEditor`, the shared
// spelling seams and `FakeClock`) on one fixture, warms it as its bound
// states, drives one event and asserts work counters (never wall time):
// - a whole-text line walk is `editableLineWalks` / `paragraphLineWalks`;
// - a fresh whole-text layout copy is `editableLineMeasures` /
//   `paragraphLineMeasures` (none at all once geometry is lazy);
// - a per-line measure is `editableLineSpans` / `paragraphLineSpans`.
//
// Warm-up: spelling replies arrived (two 1 s advances of the fake clock and
// the binding) and each newly visible row was painted once.
//
// Red on main: with whole-text geometry, opening N1-misspelled or
// N1-decorated and then one event takes minutes in debug (one ~0.7 s whole
// copy per squiggle or pill). Those tests first check, on a tiny field, that
// a range read walks no line ([_wi126RequireRangeLocalGeometry]), so on main
// they fail by assertion in a second instead of by timeout.
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/editor_rows_probe.dart';
import '../support/fake_spelling_service.dart';
import '../support/font_fetch_hold.dart';
import '../support/line_box_oracle.dart';
import '../support/long_note_fixtures.dart';
import '../support/perf_counters.dart';
import '../support/segment_editing_finder.dart';
import '../support/spelling_editor_pump.dart';

const _wi126Timeout = Timeout(Duration(minutes: 4));

// ---------------------------------------------------------------- helpers

/// Fails fast, by assertion, while a range read or a caret rect still lays
/// out a fresh whole-text copy and walks every line (main): the long-note
/// pump after it would take minutes there. A tiny field, so it costs
/// nothing once geometry is range-local.
Future<void> _wi126RequireRangeLocalGeometry(WidgetTester tester) async {
  final c = TextEditingController(
    text: [for (var i = 0; i < 40; i++) 'probe line $i'].join('\n'),
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: LineBoxEpoch(
            child: TextField(
              controller: c,
              maxLines: null,
              selectionHeightStyle: ui.BoxHeightStyle.max,
            ),
          ),
        ),
      ),
    ),
  );
  final editable = findRenderEditable(
    tester.renderObject(find.byType(TextField)),
  )!;
  final before = PerfCounters.snapshot();
  RenderEditableLineBoxes(editable).boxesFor(const TextRange(start: 3, end: 8));
  RenderEditableLineBoxes(editable).caretRect(30);
  final d = PerfCounters.delta(before);
  expect(
    (d['editableLineWalks'], d['editableLineMeasures']),
    (0, 0),
    reason:
        'a range read and a caret rect walk every line and lay out a '
        'whole-text copy (whole-text geometry); the long-note pump would '
        'take minutes',
  );
  // Tear the probe down now: the editor pumped next must not meet this
  // MaterialApp's deactivated field (EditorFocusMemory reads primaryFocus).
  await tester.pumpWidget(const SizedBox());
}

/// Pumps the editor on [note] (live preview, or Source mode with [source]),
/// with the fake checker flagging the note's flagged words, and waits for
/// the spelling replies.
Future<SpellingEditorHarness> _wi126Open(
  WidgetTester tester,
  LongNote note, {
  bool source = false,
}) async {
  final spelling = FakeSpellingService();
  seedMisspellings(spelling, note);
  final e = await pumpSpellingEditor(
    tester,
    body: note.text,
    spelling: spelling,
    source: source,
  );
  await _wi126Replies(e);
  return e;
}

/// Lets a spelling pass and its replies land (scroll pause, debounce).
Future<void> _wi126Replies(SpellingEditorHarness e) async {
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
}

/// The editor page's scroll position.
ScrollPosition _wi126Scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// One scroll step of [by] px, then the replies for what it brought in.
Future<void> _wi126Step(
  WidgetTester tester,
  SpellingEditorHarness e, {
  double by = 600,
}) async {
  final position = _wi126Scroll(tester);
  position.jumpTo(position.pixels + by);
  await tester.pump();
  await _wi126Replies(e);
}

/// Asserts the work [d] did no whole-text line walk and laid out no
/// whole-text copy, for fields and paragraphs.
void _wi126ExpectNoWalk(Map<String, int> d, String what) {
  expect(
    (
      walks: d['editableLineWalks'],
      paragraphWalks: d['paragraphLineWalks'],
      copies: d['editableLineMeasures'],
      paragraphCopies: d['paragraphLineMeasures'],
    ),
    (walks: 0, paragraphWalks: 0, copies: 0, paragraphCopies: 0),
    reason: '$what: whole-text line walks and whole-text layout copies',
  );
}

/// The laid-out field of text segment 0's row [row].
RenderEditable _wi126Field(WidgetTester tester, int row) {
  final source = rowBoxesOf(tester, 0, row);
  if (source is RenderEditableLineBoxes) return source.editable;
  throw TestFailure('row $row is not a field ($source)');
}

/// The Source mode body field.
RenderEditable _wi126SourceField(SpellingEditorHarness e) =>
    findRenderEditable(e.tester.renderObject(e.sourceField))!;

/// How many painted items a keystroke may re-measure in [note]: one line
/// each for every flagged word, code span, quote line and rule it holds,
/// plus the caret's line and slack for a wrapped item.
int _wi126ItemBound(LongNote note) {
  final codeSpans = RegExp('`[^`]+`').allMatches(note.text).length;
  final quotes = note.lines.where((l) => l.startsWith('> ')).length;
  final rules = note.lines.where((l) => l == '***').length;
  return note.flaggedLines.length + codeSpans + quotes + rules + 4;
}

/// Records one paint of [object] (a repaint of that layer alone).
List<RecordedInvocation> _wi126Record(RenderObject object) {
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  object.paint(context, Offset.zero);
  return canvas.invocations;
}

Color? _wi126PaintColor(RecordedInvocation call) {
  for (final arg in call.invocation.positionalArguments) {
    if (arg is Paint) return arg.color;
  }
  return null;
}

/// The vertical centres of [calls] drawing [member] (in [colors], when
/// given), rounded, without repeats: one per painted item line.
Set<int> _wi126Rows(
  List<RecordedInvocation> calls,
  Set<Symbol> members, {
  Set<Color>? colors,
}) => {
  for (final call in calls)
    if (members.contains(call.invocation.memberName) &&
        (colors == null ||
            colors
                .map((c) => c.toARGB32())
                .contains(_wi126PaintColor(call)?.toARGB32())))
      switch (call.invocation.positionalArguments.first) {
        final Path p => p.getBounds().center.dy.round(),
        final RRect r => r.outerRect.center.dy.round(),
        final Rect r => r.center.dy.round(),
        _ => -1,
      },
};

void main() {
  holdFontFetches();

  setUp(PerfCounters.reset);

  // ------------------------------------------------------- scroll (AC2)

  group('a warm scroll step walks no line', () {
    for (final (name, kind, variant, slowOnMain) in [
      (
        'a warm scroll step on N1 misspelled performs no whole-text line walk',
        LongNoteKind.n1Plain120k,
        LongNoteVariant.misspelled,
        true,
      ),
      (
        'a warm scroll step on N1 decorated performs no whole-text line walk',
        LongNoteKind.n1Plain120k,
        LongNoteVariant.decorated,
        true,
      ),
      (
        'a warm scroll step on N5 performs no whole-text line walk',
        LongNoteKind.n5PlainLongLines120k,
        LongNoteVariant.plain,
        false,
      ),
      (
        'a warm scroll step on N2 performs no whole-text line walk',
        LongNoteKind.n2Bullets120k,
        LongNoteVariant.plain,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        if (slowOnMain) await _wi126RequireRangeLocalGeometry(tester);
        final e = await _wi126Open(tester, longNote(kind, variant: variant));
        // Priming step: the rows it brings in are measured once.
        await _wi126Step(tester, e);
        final before = PerfCounters.snapshot();
        await _wi126Step(tester, e);
        _wi126ExpectNoWalk(PerfCounters.delta(before), 'scroll step');
      }, timeout: _wi126Timeout);
    }
  });

  // ---------------------------------------------------- keystroke (AC3)

  group('a keystroke walks no line', () {
    for (final (name, variant, slowOnMain) in [
      (
        'a keystroke in N1 performs no whole-text line walk',
        LongNoteVariant.plain,
        false,
      ),
      (
        'a keystroke in N1 misspelled performs no whole-text line walk',
        LongNoteVariant.misspelled,
        true,
      ),
      (
        'a keystroke in N1 decorated performs no whole-text line walk',
        LongNoteVariant.decorated,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        if (slowOnMain) await _wi126RequireRangeLocalGeometry(tester);
        final note = longNote(LongNoteKind.n1Plain120k, variant: variant);
        final e = await _wi126Open(tester, note);
        // The caret at the end of line 3, in the first screen.
        final offset = note.lines.take(4).join('\n').length;
        await activateRow(tester, 0, 0, offset: offset);
        await _wi126Replies(e);
        final before = PerfCounters.snapshot();
        await e.robot.typeChars('x');
        final d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'keystroke');
        expect(
          d['editableLineSpans']! + d['paragraphLineSpans']!,
          lessThanOrEqualTo(_wi126ItemBound(note)),
          reason:
              'per-line measures only for the lines the repainted '
              'squiggles, decorations and caret cover',
        );
        expect(
          rowTextOf(tester, 0, 0).substring(offset, offset + 1),
          'x',
          reason: 'the keystroke landed',
        );
      }, timeout: _wi126Timeout);
    }
  });

  // -------------------------------------------------- first Arrow Down (AC4)

  testWidgets(
    'the first Arrow Down after opening N1 performs no whole-text line walk',
    (tester) async {
      final note = longNote(LongNoteKind.n1Plain120k);
      await _wi126Open(tester, note);
      await activateRow(tester, 0, 0, offset: 5);
      await pumpFrames(tester);
      final before = PerfCounters.snapshot();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      _wi126ExpectNoWalk(PerfCounters.delta(before), 'first Arrow Down');
      final caret = segmentEditingAt(tester, 0).selection;
      final second = note.lines.first.length + 1;
      expect(caret.isCollapsed, isTrue);
      expect(
        caret.extentOffset,
        inInclusiveRange(second, second + note.lines[1].length),
        reason: 'Arrow Down moved the caret to the second line',
      );
    },
    timeout: _wi126Timeout,
  );

  // ---------------------------------------------------- Source mode (AC5)

  group('Source mode walks no line', () {
    testWidgets(
      'in Source mode a warm scroll step on N1 misspelled performs no whole-text line walk',
      (tester) async {
        await _wi126RequireRangeLocalGeometry(tester);
        final e = await _wi126Open(
          tester,
          longNote(
            LongNoteKind.n1Plain120k,
            variant: LongNoteVariant.misspelled,
          ),
          source: true,
        );
        expect(e.sourceSurface, findsOneWidget);
        await _wi126Step(tester, e);
        final before = PerfCounters.snapshot();
        await _wi126Step(tester, e);
        _wi126ExpectNoWalk(PerfCounters.delta(before), 'Source scroll step');
      },
      timeout: _wi126Timeout,
    );

    testWidgets(
      'in Source mode a keystroke on N1 misspelled performs no whole-text line walk',
      (tester) async {
        await _wi126RequireRangeLocalGeometry(tester);
        final note = longNote(
          LongNoteKind.n1Plain120k,
          variant: LongNoteVariant.misspelled,
        );
        final e = await _wi126Open(tester, note, source: true);
        expect(e.sourceSurface, findsOneWidget);
        final before = PerfCounters.snapshot();
        await e.typeAtEnd('x');
        final d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'Source keystroke');
        expect(
          d['editableLineSpans'],
          lessThanOrEqualTo(_wi126ItemBound(note)),
          reason: 'per-line measures only for the repainted squiggles',
        );
        expect(e.bodyText, endsWith('x'));
      },
      timeout: _wi126Timeout,
    );

    testWidgets(
      'Source mode squiggle geometry on N1 misspelled measures exactly as main',
      (tester) async {
        await _wi126RequireRangeLocalGeometry(tester);
        final note = longNote(
          LongNoteKind.n1Plain120k,
          variant: LongNoteVariant.misspelled,
        );
        final e = await _wi126Open(tester, note, source: true);
        final field = _wi126SourceField(e);
        final oracle = LineBoxOracle.editable(field);
        addTearDown(oracle.dispose);
        final before = PerfCounters.snapshot();
        for (final (i, line) in note.flaggedLines.take(12).indexed) {
          final start =
              note.lines.take(line).fold(0, (n, l) => n + l.length + 1) +
              note.lines[line].indexOf(note.flaggedWords[i]);
          final range = TextRange(
            start: start,
            end: start + note.flaggedWords[i].length,
          );
          expect(
            RenderEditableLineBoxes(field).boxesFor(range),
            oracle.boxesFor(range),
            reason: 'flagged word $i',
          );
          expect(
            lineKey(RenderEditableLineBoxes(field).lineAt(start)),
            lineKey(oracle.lineAt(start)),
            reason: 'flagged word $i line (its baseline)',
          );
        }
        _wi126ExpectNoWalk(PerfCounters.delta(before), 'Source range reads');
      },
      timeout: _wi126Timeout,
    );
  });

  // ------------------------------------------- range-local on N1 (AC6)

  group('a range read on N1 measures only its lines', () {
    testWidgets(
      'a range on one line of N1s single row measures only that line',
      (tester) async {
        final note = longNote(LongNoteKind.n1Plain120k);
        await _wi126Open(tester, note);
        expect(rowsHostOf(tester).rowCount, 1, reason: 'N1 is one prose row');
        final field = _wi126Field(tester, 0);
        final oracle = LineBoxOracle.editable(field);
        addTearDown(oracle.dispose);
        final lineStart = note.lines
            .take(1500)
            .fold(0, (n, l) => n + l.length + 1);
        final one = TextRange(start: lineStart + 3, end: lineStart + 12);
        var before = PerfCounters.snapshot();
        final rects = RenderEditableLineBoxes(field).boxesFor(one);
        var d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'one-line range');
        expect(d['editableLineSpans'], lessThanOrEqualTo(1));
        expect(rects, oracle.boxesFor(one));
        // A range over three lines measures at most those three.
        final three = TextRange(
          start: lineStart + 5,
          end:
              lineStart + note.lines[1500].length + note.lines[1501].length + 6,
        );
        before = PerfCounters.snapshot();
        final threeRects = RenderEditableLineBoxes(field).boxesFor(three);
        d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'three-line range');
        expect(d['editableLineSpans'], lessThanOrEqualTo(3));
        expect(threeRects, hasLength(3));
        expect(threeRects, oracle.boxesFor(three));
        before = PerfCounters.snapshot();
        final caret = RenderEditableLineBoxes(field).caretRect(lineStart + 7);
        d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'caret rect');
        expect(d['editableLineSpans'], lessThanOrEqualTo(1));
        expect(caret, oracle.caretRect(lineStart + 7));
      },
      timeout: _wi126Timeout,
    );

    testWidgets(
      'the first range read after a keystroke in N1 measures only the lines it touches',
      (tester) async {
        final note = longNote(LongNoteKind.n1Plain120k);
        final e = await _wi126Open(tester, note);
        final offset = note.lines.take(3).join('\n').length;
        await activateRow(tester, 0, 0, offset: offset);
        await e.robot.typeChars('x');
        final field = _wi126Field(tester, 0);
        final oracle = LineBoxOracle.editable(field);
        addTearDown(oracle.dispose);
        final range = TextRange(start: offset - 6, end: offset + 1);
        final before = PerfCounters.snapshot();
        final rects = RenderEditableLineBoxes(field).boxesFor(range);
        final d = PerfCounters.delta(before);
        _wi126ExpectNoWalk(d, 'first range read after a keystroke');
        expect(d['editableLineSpans'], lessThanOrEqualTo(1));
        expect(rects, oracle.boxesFor(range));
      },
      timeout: _wi126Timeout,
    );
  });

  // ----------------------------------- overlays paint every item (AC8)

  testWidgets(
    'a rows squiggles find highlights and decorations all paint when it repaints and show on scroll without a further measure',
    (tester) async {
      // One prose row of 200 lines; a flagged word, a code span and a Find
      // match near the top and again ~190 lines down, far outside the
      // viewport.
      final lines = [
        for (var i = 0; i < 200; i++)
          switch (i) {
            2 || 188 => 'Line $i holds a qwerblat word.',
            3 || 189 => 'Line $i runs `step$i` here.',
            4 || 190 => 'Line $i finds zzmatch here.',
            _ => 'Line $i plain words only.',
          },
      ];
      final spelling = FakeSpellingService()..misspell('qwerblat');
      final e = await pumpSpellingEditor(
        tester,
        body: lines.join('\n'),
        spelling: spelling,
      );
      await _wi126Replies(e);
      e.container.read(findInNoteProvider.notifier)
        ..show()
        ..setQuery('zzmatch');
      await pumpFrames(tester);
      _wi126Scroll(tester).jumpTo(0);
      await tester.pump();
      await _wi126Replies(e);
      expect(rowsHostOf(tester).rowCount, 1);

      final segment = find.byKey(textSegmentKey(0));
      final squiggles = tester.renderObject(
        find
            .descendant(
              of: segment,
              matching: find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_SquiggleLayer',
              ),
            )
            .first,
      );
      final finds = tester.renderObject(
        find
            .descendant(of: segment, matching: find.byType(FindHighlights))
            .first,
      );
      final decorations = tester.renderObject(
        find
            .descendant(
              of: segment,
              matching: find.byType(LivePreviewDecorations),
            )
            .first,
      );
      final viewport = _wi126Scroll(tester).viewportDimension;

      void expectEveryItem(String when) {
        final before = PerfCounters.snapshot();
        final paths = _wi126Rows(_wi126Record(squiggles), {#drawPath});
        final boxes = _wi126Rows(_wi126Record(finds), {
          #drawRRect,
          #drawDRRect,
        });
        final pills = _wi126Rows(
          _wi126Record(decorations),
          {#drawRRect},
          colors: {OmColors.surface4},
        );
        final d = PerfCounters.delta(before);
        for (final (what, rows) in [
          ('squiggles', paths),
          ('find highlights', boxes),
          ('code pills', pills),
        ]) {
          expect(rows, hasLength(2), reason: '$when: both $what paint');
          expect(
            rows.reduce((a, b) => a > b ? a : b) -
                rows.reduce((a, b) => a < b ? a : b),
            greaterThan(viewport),
            reason: '$when: the second of the $what is far from the first',
          );
        }
        _wi126ExpectNoWalk(d, '$when repaint');
        expect(
          (d['editableLineSpans'], d['paragraphLineSpans']),
          (0, 0),
          reason: '$when: the repaint re-measures no line',
        );
      }

      expectEveryItem('at the top');
      final field = _wi126Field(tester, 0);
      final far = lines.take(188).fold(0, (n, l) => n + l.length + 1);
      final y = RenderEditableLineBoxes(field).lineAt(far).top;
      _wi126Scroll(tester).jumpTo(y - 100);
      await tester.pump();
      await _wi126Replies(e);
      expectEveryItem('scrolled to the far items');
    },
    timeout: _wi126Timeout,
  );
}
