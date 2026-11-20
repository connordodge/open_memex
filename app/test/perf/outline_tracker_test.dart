// WI #131 (Spec #122 Requirements 13, 14, 23, 24, 30a, 36; Spec #58 R22-R26,
// TD6, rulings D3h, D5): the Outline current-section tracker, the shared
// Outline entries and the reveal row lookup on the long-note fixtures
// (#125), without whole-note work per frame or per keystroke.
//
// The contract stays exact: the current entry is the last heading whose
// heading LINE top (not its row top) is at or above the viewport top + 16
// px; none above the first heading. The oracle ([_t131Oracle]) reads every
// heading line top from the editor's own line boxes through the rows host's
// row-geometry accessor, never from constants.
//
// Work is counted, never timed ([PerfCounters]): tracker passes, whole-text
// line walks, whole-text layout copies and per-line measures. A probe of the
// tracker reads one heading line through the cached geometry
// (`LineBoxSource.lineAt`, #126), so it walks no row's lines; on N1 every
// heading sits in the single 120k prose row.
//
// The element-tree probe ([_T131VisitProbe]) is a transparent widget in
// every text row whose element counts the child visits asked of it: a
// lookup that walks every row's subtree visits each probe once.
//
// Count tests drive one event each under an explicit [_t131Timeout], so on
// main (whole-row geometry per probe) they fail by assertion, not by
// timeout. Never pumpAndSettle the workspace (OmDot pulses forever).
//
// Helpers carry the `_t131` prefix. Text is invented (public repo).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/outline_section.dart';
import 'package:open_memex_app/src/state/outline_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart'
    show locateInSegment;
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/note_reveal.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart'
    show editorBodyStyle;
import 'package:open_memex_app/src/widgets/find/find_in_note_host.dart'
    show findRevealInset;
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/outline/outline_jump.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/editor_rows_probe.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/long_note_fixtures.dart';
import '../support/note_reveal_pump.dart';
import '../support/perf_counters.dart';
import '../support/wi85_find_editor.dart';

const _t131Timeout = Timeout(Duration(minutes: 8));

/// The id the long note is seeded under.
const _t131Id = 't131-long';

/// The mark: the viewport top + this (Spec #58 R22).
const double _t131Mark = outlineJumpInset;

/// How many per-line measures one tracker pass may make on a cold layout:
/// a probe reads one heading line, a bisection over 60 entries makes about
/// 6 probes; four times that as slack. Measuring every heading line (60)
/// is a whole-Outline pass, not a bisection.
const _t131ProbeSpans = 24;

// ------------------------------------------------------------------ pump

/// A vault holding [note] as [_t131Id].
FakeVaultDb _t131Vault(LongNote note) =>
    FakeVaultDb.v5()
      ..seedNote(id: _t131Id, title: 'Long note', content: note.text);

/// Opens [note] in the reveal pump (live preview, 1600x1000).
Future<NoteRevealHarness> _t131Open(
  WidgetTester tester,
  LongNote note, {
  List<Override> overrides = const [],
}) => pumpNoteReveal(
  tester,
  db: _t131Vault(note),
  open: _t131Id,
  overrides: overrides,
);

/// Watches the current section as the Outline tab does while it shows.
/// Pumps nothing. Closed at teardown.
ProviderSubscription<OutlineEntry?> _t131WatchSection(NoteRevealHarness h) {
  final sub = h.container.listen<OutlineEntry?>(
    outlineSectionProvider,
    (_, _) {},
  );
  addTearDown(sub.close);
  return sub;
}

/// Watches the Outline panel's entries as the Outline tab does. Pumps
/// nothing. Closed at teardown.
void _t131WatchPanel(NoteRevealHarness h) {
  final sub = h.container.listen(outlineProvider, (_, _) {});
  addTearDown(sub.close);
}

/// Whole-text line walks of fields and paragraphs in [d].
int _t131Walks(Map<String, int> d) =>
    d['editableLineWalks']! + d['paragraphLineWalks']!;

/// Whole-text layout copies of fields and paragraphs in [d].
int _t131Measures(Map<String, int> d) =>
    d['editableLineMeasures']! + d['paragraphLineMeasures']!;

/// Per-line measures of fields and paragraphs in [d].
int _t131Spans(Map<String, int> d) =>
    d['editableLineSpans']! + d['paragraphLineSpans']!;

// ---------------------------------------------------------------- oracle

/// The global top of entry [e]'s heading line, from the row's line boxes
/// through the rows host's accessor. With [lazy] the line comes from
/// `lineAt` (no walk of the row's lines); else from `lines`.
double _t131HeadingTop(
  WidgetTester tester,
  NoteRevealHarness h,
  OutlineEntry e, {
  bool lazy = false,
}) {
  final text = (h.shownSegments()[e.segment] as TextSegment).text;
  final specs = splitRows(text, atSegmentStart: true);
  final r = specs.lastIndexWhere((s) => s.start <= e.local);
  final boxes = rowsHostOf(tester, e.segment).rowBoxes(r);
  if (boxes == null) throw TestFailure('row ${e.segment}-$r is not laid out');
  final local = specs[r].toLocal(e.local);
  final line = lazy ? boxes.lineAt(local) : lineHolding(boxes.lines, local);
  return boxes.box.localToGlobal(Offset(0, line.top)).dy;
}

/// The entry the line boxes say is current: the last whose heading line
/// top is at or above the viewport top + 16 px; null above the first.
OutlineEntry? _t131Oracle(WidgetTester tester, NoteRevealHarness h) {
  final content = h.shownContent();
  final segments = h.shownSegments();
  final entries = outlineEntries(content, role: h.body().note.role);
  final top = h.viewport().top;
  final hosts = <int, SegmentViewState>{};
  final specsOf = <int, List<RowSpec>>{};
  OutlineEntry? current;
  for (final e in entries) {
    final specs = specsOf.putIfAbsent(
      e.segment,
      () => splitRows(
        (segments[e.segment] as TextSegment).text,
        atSegmentStart: true,
      ),
    );
    final host = hosts.putIfAbsent(
      e.segment,
      () => rowsHostOf(tester, e.segment),
    );
    final r = specs.lastIndexWhere((s) => s.start <= e.local);
    final boxes = host.rowBoxes(r);
    if (boxes == null) throw TestFailure('row ${e.segment}-$r not laid out');
    final line = lineHolding(boxes.lines, specs[r].toLocal(e.local));
    final y = boxes.box.localToGlobal(Offset(0, line.top)).dy - top;
    if (y <= _t131Mark + 1e-6) current = e;
  }
  return current;
}

// ------------------------------------------------------- tree visit probe

/// A transparent widget whose element counts the child visits asked of it
/// ([_T131VisitProbeElement.visits]).
class _T131VisitProbe extends StatelessWidget {
  const _T131VisitProbe({required this.child});

  final Widget child;

  @override
  StatelessElement createElement() => _T131VisitProbeElement(this);

  @override
  Widget build(BuildContext context) => child;
}

class _T131VisitProbeElement extends StatelessElement {
  _T131VisitProbeElement(super.widget);

  /// Child visits asked of every probe element since the last reset.
  static int visits = 0;

  @override
  void visitChildren(ElementVisitor visitor) {
    visits++;
    super.visitChildren(visitor);
  }
}

/// The built-in text presenter with a [_T131VisitProbe] around each row's
/// body: it lays out, paints and edits as the built-in one does.
class _T131ProbedTextPresenter extends TextRowPresenter {
  const _T131ProbedTextPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) =>
      _T131VisitProbe(child: super.build(context, row, textSlot));
}

/// Puts a [_T131VisitProbe] in every text row until the test ends.
void _t131ProbeRows() {
  debugRowKindPresenterOverride = (kind) =>
      kind == RowKind.table || kind == RowKind.attachment
      ? null
      : const _T131ProbedTextPresenter();
  addTearDown(() => debugRowKindPresenterOverride = null);
}

// ------------------------------------------------------- RichText text slot

/// A test-only text slot (never the real idle row, #132): a `RichText` of
/// the span the row's own `LivePreviewController` builds, at the field's
/// style and strut, under the row's own layout epoch, standing in for the
/// row's field under the text slot's Key `editor-row-<s>-<r>`.
class _T131RichSlot extends StatelessWidget {
  const _T131RichSlot({required this.controller});

  final LivePreviewController controller;

  @override
  Widget build(BuildContext context) => Padding(
    // The field's caret margin: it lays its text out this much narrower.
    padding: const EdgeInsets.only(right: 3),
    child: ListenableBuilder(
      listenable: Listenable.merge([controller, controller.revealGate]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final style = (theme.textTheme.bodyLarge ?? const TextStyle()).merge(
          editorBodyStyle(),
        );
        final strut = controller.strutStyle;
        return LineBoxEpoch(
          child: RichText(
            text: controller.buildTextSpan(
              context: context,
              style: style,
              withComposing: false,
            ),
            strutStyle: strut == null
                ? StrutStyle.fromTextStyle(style, forceStrutHeight: true)
                : strut.inheritFromTextStyle(style),
            textScaler: MediaQuery.textScalerOf(context),
            textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
          ),
        );
      },
    ),
  );
}

/// Shows every prose row as a [_T131RichSlot].
class _T131RichPresenter extends RowKindPresenter {
  const _T131RichPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) =>
      KeyedSubtree(
        key: ValueKey('editor-row-${row.segment}-${row.index}'),
        child: _T131RichSlot(controller: row.controller),
      );

  @override
  bool textHidden(PresentedRow row) => false;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) => null;

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}

/// Presents every prose row as a RichText text slot until the test ends.
void _t131PresentRichText() {
  debugRowKindPresenterOverride = (kind) =>
      kind == RowKind.prose ? const _T131RichPresenter() : null;
  addTearDown(() => debugRowKindPresenterOverride = null);
}

/// Jumps to [entry] of the shown note, as the Outline tab does.
void _t131Jump(WidgetTester tester, NoteRevealHarness h, OutlineEntry entry) =>
    jumpToOutlineEntry(
      tester.element(find.byType(NoteEditor)) as WidgetRef,
      h.body().note.id,
      entry,
      h.shownContent(),
    );

/// The entry of the shown note whose text is [text].
OutlineEntry _t131Entry(NoteRevealHarness h, String text) =>
    outlineEntries(h.shownContent(), role: h.body().note.role).firstWhere(
      (e) => e.text == text,
      orElse: () => throw TestFailure('no entry "$text"'),
    );

void main() {
  holdFontFetches();

  setUp(PerfCounters.reset);

  // ------------------------------------------------------- scroll (AC1)

  group('a scroll step with the Outline open (AC1)', () {
    for (final (name, kind) in [
      (
        'a scroll step on N1 as the Outline opens runs one tracker pass with no row layout and no line walk',
        LongNoteKind.n1Plain120k,
      ),
      (
        'a scroll step on N2 as the Outline opens runs one tracker pass with no row layout and no line walk',
        LongNoteKind.n2Bullets120k,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _t131Open(tester, longNote(kind));
        final p = h.position();
        // Priming step with the Outline closed: the rows it brings in are
        // laid out and painted once.
        p.jumpTo(p.pixels + 600);
        await pumpFrames(tester);

        final before = PerfCounters.snapshot();
        final sub = _t131WatchSection(h);
        // One step far down the note: the bisection probes headings it
        // never read before.
        p.jumpTo(p.maxScrollExtent * 0.4);
        await tester.pump();
        final d = PerfCounters.delta(before);

        expect(d['sectionTrackerPasses'], 1, reason: 'one pass per frame');
        expect(
          _t131Walks(d),
          0,
          reason: 'a probe reads its heading line, never every line of a row',
        );
        expect(_t131Measures(d), 0, reason: 'no whole-text layout copy');
        expect(
          _t131Spans(d),
          lessThanOrEqualTo(_t131ProbeSpans),
          reason: 'one line per bisection probe',
        );
        expect(sub.read(), isNotNull, reason: 'a heading is above the mark');
        expect(sub.read(), _t131Oracle(tester, h));
      }, timeout: _t131Timeout);
    }

    testWidgets(
      'a far scroll step on N2 with the Outline open probes cold heading rows with no line walk',
      (tester) async {
        final h = await _t131Open(tester, longNote(LongNoteKind.n2Bullets120k));
        final sub = _t131WatchSection(h);
        await pumpFrames(tester);
        final p = h.position();

        final before = PerfCounters.snapshot();
        p.jumpTo(p.maxScrollExtent * 0.7);
        await tester.pump();
        final d = PerfCounters.delta(before);

        expect(d['sectionTrackerPasses'], 1, reason: 'one pass per frame');
        expect(_t131Walks(d), 0, reason: 'no heading row line walk');
        expect(_t131Measures(d), 0, reason: 'no whole-text layout copy');
        expect(_t131Spans(d), lessThanOrEqualTo(_t131ProbeSpans));
        expect(sub.read(), isNotNull);
        expect(sub.read(), _t131Oracle(tester, h));
      },
      timeout: _t131Timeout,
    );
  });

  // ---------------------------------------------------- the oracle (AC2)

  group('the current section follows the line boxes (AC2)', () {
    for (final (name, kind) in [
      (
        'after each scroll step on N1 the current section equals the line box oracle once per frame with no lag',
        LongNoteKind.n1Plain120k,
      ),
      (
        'after each scroll step on N2 the current section equals the line box oracle once per frame with no lag',
        LongNoteKind.n2Bullets120k,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final note = longNote(kind);
        final h = await _t131Open(tester, note);
        final sub = _t131WatchSection(h);
        await pumpFrames(tester);
        expect(
          sub.read(),
          _t131Oracle(tester, h),
          reason: 'at the top of the note',
        );
        final p = h.position();
        final max = p.maxScrollExtent;

        for (final to in [
          700.0,
          1333.5,
          max * 0.25,
          max * 0.25 - 37,
          max * 0.6,
          max * 0.1,
          max,
          0.0,
          max * 0.45,
        ]) {
          final before = PerfCounters.snapshot();
          p.jumpTo(to);
          await tester.pump();
          expect(
            PerfCounters.delta(before)['sectionTrackerPasses'],
            lessThanOrEqualTo(1),
            reason: 'at most one pass in the frame of a step to $to',
          );
          expect(
            sub.read(),
            _t131Oracle(tester, h),
            reason: 'the frame after a step to $to',
          );
        }

        // A burst of steps inside one frame: one pass, on the final place.
        final burst = PerfCounters.snapshot();
        p.jumpTo(max * 0.3);
        p.jumpTo(max * 0.8);
        p.jumpTo(max * 0.55);
        await tester.pump();
        expect(PerfCounters.delta(burst)['sectionTrackerPasses'], 1);
        expect(sub.read(), _t131Oracle(tester, h), reason: 'no lag');

        // Scrolling stopped: quiet frames change nothing and run no pass.
        final shown = sub.read();
        final quiet = PerfCounters.snapshot();
        await tester.pump();
        await tester.pump();
        expect(PerfCounters.delta(quiet)['sectionTrackerPasses'], 0);
        expect(sub.read(), shown);
      }, timeout: _t131Timeout);
    }
  });

  // ---------------------------------------------------- keystroke (AC3)

  group('a keystroke with the Outline open (AC3)', () {
    /// Opens N1 with the caret at the start of line 510 (Section 11's
    /// body), the page scrolled to show it.
    Future<NoteRevealHarness> openAtLine510(
      WidgetTester tester, {
      List<Override> overrides = const [],
    }) async {
      final note = longNote(LongNoteKind.n1Plain120k);
      final h = await _t131Open(tester, note, overrides: overrides);
      final offset = note.text.indexOf('Speaker 510:');
      expect(offset, greaterThan(0));
      await activateRow(tester, 0, 0, offset: offset);
      await pumpFrames(tester);
      return h;
    }

    /// Types one character at the caret and lets the tracker's pass run.
    Future<void> type(WidgetTester tester, NoteRevealHarness h) async {
      await SegmentedEditorRobot(tester, h.workspace).typeChars('x');
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'a keystroke in N1 with the Outline open performs no whole-text line walk',
      (tester) async {
        final h = await openAtLine510(tester);
        final sub = _t131WatchSection(h);
        _t131WatchPanel(h);
        await pumpFrames(tester);
        expect(sub.read(), isNotNull, reason: 'a heading is current');

        final before = PerfCounters.snapshot();
        await type(tester, h);
        final d = PerfCounters.delta(before);

        expect(
          rowTextOf(tester, 0, 0),
          contains('xSpeaker 510:'),
          reason: 'the keystroke landed',
        );
        expect(
          d['sectionTrackerPasses'],
          greaterThanOrEqualTo(1),
          reason: 'the text change ran the tracker',
        );
        expect(_t131Walks(d), 0, reason: 'no whole-text line walk');
        expect(_t131Measures(d), 0, reason: 'no whole-text layout copy');
        expect(sub.read(), _t131Oracle(tester, h));
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'a keystroke in N1 with the Outline open parses the note no more than with it closed apart from one shared entries pass',
      (tester) async {
        final h = await openAtLine510(tester);
        // Warm-up keystroke: the first edit's one-off work is not counted.
        await type(tester, h);
        await pumpFrames(tester);

        final closedBefore = PerfCounters.snapshot();
        await type(tester, h);
        final closed = PerfCounters.delta(closedBefore);
        await pumpFrames(tester);

        final sub = _t131WatchSection(h);
        _t131WatchPanel(h);
        await pumpFrames(tester);
        expect(sub.read(), isNotNull, reason: 'a heading is current');

        final openBefore = PerfCounters.snapshot();
        await type(tester, h);
        final open = PerfCounters.delta(openBefore);

        final textSegments = h.shownSegments().whereType<TextSegment>().length;
        // The shared entries computation classifies each text segment once
        // (Req 24). The tracker re-parses nothing: at most one row split
        // to place headings, like the editor's own splitRows.
        expect(
          open['classifyLines']!,
          lessThanOrEqualTo(closed['classifyLines']! + textSegments + 1),
          reason:
              'Outline open ${open['classifyLines']} vs closed '
              '${closed['classifyLines']} line classifications',
        );
        expect(
          open['splitRows']!,
          lessThanOrEqualTo(closed['splitRows']! + 1),
          reason:
              'Outline open ${open['splitRows']} vs closed '
              '${closed['splitRows']} row splits',
        );
        expect(sub.read(), _t131Oracle(tester, h));
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'the Outline panel and the tracker share one entries computation per keystroke in N1',
      (tester) async {
        var computed = 0;
        List<OutlineEntry> last = const [];
        final h = await openAtLine510(
          tester,
          overrides: [
            outlineEntriesFnProvider.overrideWithValue((text, {role}) {
              computed++;
              return last = outlineEntries(text, role: role);
            }),
          ],
        );
        final sub = _t131WatchSection(h);
        _t131WatchPanel(h);
        await pumpFrames(tester);

        computed = 0;
        await type(tester, h);
        await pumpFrames(tester);

        expect(computed, 1, reason: 'one entries computation per text change');
        final current = sub.read();
        expect(current, isNotNull, reason: 'a heading is current');
        expect(
          last.any((e) => identical(e, current)),
          isTrue,
          reason: 'the tracker reports an entry of the shared computation',
        );
        expect(current, _t131Oracle(tester, h));
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'with only the current section watched a keystroke in N1 computes the Outline entries once through the shared computation',
      (tester) async {
        var computed = 0;
        final h = await openAtLine510(
          tester,
          overrides: [
            outlineEntriesFnProvider.overrideWithValue((text, {role}) {
              computed++;
              return outlineEntries(text, role: role);
            }),
          ],
        );
        final sub = _t131WatchSection(h);
        await pumpFrames(tester);

        computed = 0;
        await type(tester, h);
        await pumpFrames(tester);

        expect(
          computed,
          1,
          reason: 'the tracker takes its entries from the shared computation',
        );
        expect(sub.read(), isNotNull);
        expect(sub.read(), _t131Oracle(tester, h));
      },
      timeout: _t131Timeout,
    );
  });

  // ------------------------------------------------------ reveal row (AC4)

  group('reveal on N2 (AC4)', () {
    testWidgets(
      'revealRow on N2 finds a row without walking the whole element tree',
      (tester) async {
        _t131ProbeRows();
        final note = longNote(LongNoteKind.n2Bullets120k);
        final h = await _t131Open(tester, note);
        final content = h.shownContent();
        final host = rowsHostOf(tester);
        expect(host.rowCount, 3000, reason: 'every N2 line is a row');
        final context = tester.element(find.byType(NoteEditor));

        for (final (r, needle) in [
          (2401, 'Speaker 2401:'),
          (2400, '## Section 49'),
          (7, 'Speaker 7:'),
        ]) {
          final arrival = locateInSegment(content, 0, h.offsetOf(needle));
          expect(arrival, isNotNull, reason: needle);
          expect(arrival!.key, ValueKey('editor-row-0-$r'), reason: needle);

          _T131VisitProbeElement.visits = 0;
          final found = revealRow(context, _t131Id, content, arrival);
          final visits = _T131VisitProbeElement.visits;

          expect(found, isNotNull, reason: '$needle: row $r is laid out');
          expect(
            visits,
            lessThanOrEqualTo(2),
            reason: '$needle: the lookup visited $visits of 3000 rows',
          );
          expect(found!.element.widget.key, ValueKey('editor-row-0-$r'));
          expect(
            identical(
              found.row,
              tester.renderObject(
                find.byKey(ValueKey('editor-row-0-$r'), skipOffstage: false),
              ),
            ),
            isTrue,
            reason: '$needle: the row of its key',
          );
          expect(
            identical(
              found.column,
              tester.renderObject(
                find.byKey(
                  const ValueKey('text-segment-0'),
                  skipOffstage: false,
                ),
              ),
            ),
            isTrue,
            reason: '$needle: its text segment',
          );
        }
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'on N2 an Outline jump lands its heading line at the inset and Find current match reveals its line within the viewport',
      (tester) async {
        final note = longNote(LongNoteKind.n2Bullets120k);
        final w = await pumpWi85(tester, db: _t131Vault(note), open: _t131Id);
        final h = w.h;
        final sub = _t131WatchSection(h);
        await pumpFrames(tester);

        final entry = _t131Entry(h, 'Section 41');
        _t131Jump(tester, h, entry);
        await pumpFrames(tester);
        expect(h.pixels(), greaterThan(0), reason: 'the page scrolled');
        expect(
          _t131HeadingTop(tester, h, entry) - h.viewport().top,
          moreOrLessEquals(_t131Mark, epsilon: 0.5),
          reason: 'the heading line at the jump inset',
        );
        expect(sub.read(), entry, reason: 'the jumped-to entry is current');

        final at = h.offsetOf('Speaker 2777:');
        await w.openOn('Speaker 2777:');
        final match = await w.stepUntil((m) => m.start == at);
        await pumpFrames(tester);
        final line = h.lineBoxOf(0, match.start);
        final viewport = h.viewport();
        expect(
          line.top,
          greaterThanOrEqualTo(viewport.top + findRevealInset - 0.5),
          reason: 'below the Find bar inset',
        );
        expect(
          line.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'on screen',
        );
      },
      timeout: _t131Timeout,
    );
  });

  // ------------------------------------------- RichText prose row (AC5)

  group('a multi-line RichText prose row (AC5)', () {
    testWidgets(
      'the current section in a multi-line RichText prose row follows its heading line k with no line walk',
      (tester) async {
        _t131PresentRichText();
        final h = await pumpNoteReveal(tester);
        final mid = _t131Entry(h, 'Mid heading');
        // The heading sits in the middle of the note's first prose row.
        expect(h.rowOf(0, mid.local).index, 0);
        expect(h.rowOf(0, mid.local).spec.start, 0);
        final p = h.position();
        // The heading line exactly on the mark (read lazily: no line walk).
        p.jumpTo(
          p.pixels +
              _t131HeadingTop(tester, h, mid, lazy: true) -
              (h.viewport().top + _t131Mark),
        );
        await tester.pump();
        expect(
          _t131HeadingTop(tester, h, mid, lazy: true) - h.viewport().top,
          moreOrLessEquals(_t131Mark, epsilon: 1e-3),
        );

        final before = PerfCounters.snapshot();
        final sub = _t131WatchSection(h);
        await tester.pump();
        await tester.pump();
        expect(sub.read(), mid, reason: 'line k is on the mark');
        expect(
          PerfCounters.delta(before)['paragraphLineWalks'],
          0,
          reason: 'the tracker reads line k, never every line of the row',
        );

        // One px down: line k is just below the mark; nothing above it.
        p.jumpTo(p.pixels - 1);
        await tester.pump();
        expect(sub.read(), isNull, reason: 'line k 1 px below the mark');
        expect(PerfCounters.delta(before)['paragraphLineWalks'], 0);
        expect(_t131Measures(PerfCounters.delta(before)), 0);
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'an Outline jump to a heading on line k of a multi-line RichText prose row lands that line at the inset',
      (tester) async {
        _t131PresentRichText();
        final h = await pumpNoteReveal(tester);
        final sub = _t131WatchSection(h);
        await pumpFrames(tester);
        final mid = _t131Entry(h, 'Mid heading');
        final rowTop = h.rowRectOf(0, mid.local).top;
        expect(
          _t131HeadingTop(tester, h, mid) - rowTop,
          greaterThan(100),
          reason: 'line k is far below the row top',
        );

        _t131Jump(tester, h, mid);
        await pumpFrames(tester);
        expect(h.pixels(), greaterThan(0), reason: 'the page scrolled');
        expect(
          _t131HeadingTop(tester, h, mid) - h.viewport().top,
          moreOrLessEquals(_t131Mark, epsilon: 0.5),
          reason: 'line k, not the row top, at the jump inset',
        );
        expect(sub.read(), mid);
      },
      timeout: _t131Timeout,
    );

    testWidgets(
      'Find current match on line k of a multi-line RichText prose row reveals that line within the viewport',
      (tester) async {
        _t131PresentRichText();
        final w = await pumpWi85(tester, open: wi85LongId);
        final h = w.h;
        await w.openOn(wi85LongQuery);
        final second = h.offsetOf('second marker line') + 'second '.length;
        final match = await w.stepUntil((m) => m.start == second);
        await pumpFrames(tester);

        expect(h.pixels(), greaterThan(0), reason: 'the page scrolled');
        final rowTop = h.rowRectOf(0, match.start).top;
        final line = h.lineBoxOf(0, match.start);
        expect(line.top - rowTop, greaterThan(0), reason: 'line k of the row');
        final viewport = h.viewport();
        expect(
          line.top,
          greaterThanOrEqualTo(viewport.top + findRevealInset - 0.5),
          reason: 'below the Find bar inset',
        );
        expect(
          line.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'line k on screen',
        );
      },
      timeout: _t131Timeout,
    );
  });
}
