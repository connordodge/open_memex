// WI #129 (Spec #122 Requirements 11, 17, 17a, 18, 19, 20, 21, 22, 36;
// Technical Decisions 2, 3, 4; rulings D6, D8, D10, D12): rebuild and paint
// isolation for editor rows.
//
// Count tests pump the real workspace (`pumpSpellingEditor`, or
// `pumpLiveWorkspace` for a daily note) on the #125 fixtures and read the
// #125 work counters (`PerfCounters`) around one event, after a stated
// warm-up. Bounds are counts, never times. Where an event legitimately works
// on a row (the edited row, the two rows an Arrow Down moves between) the
// bound is [_wi129PerRow] per such row: a row may run a step once per frame,
// and a test pumps at most two frames per event. Every bound is far below
// the fixture's row count, so a change that makes the step grow with the
// note again fails it.
//
// Layout is counted from the framework's own layout profile
// (`debugProfileLayoutsEnabled` blocks collected by `FlutterTimeline`): how
// many times any row field's `RenderEditable` was laid out.
//
// WI #129 also adds three link-region seams (skeleton): the note-titles
// lookup build counter (`debugNoteTitleLookupBuilds`, the shared lookup's
// file), the per-region titles update counter
// (`debugLinkRegionTitleUpdates`) and the `HardwareKeyboard` handler gauge
// (`debugLinkKeyHandlers`).
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_title_lookup.dart' as lookup;
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart' as link;
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';

import '../robots/segmented_editor_robot.dart' show fixtureRangeToken;
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_rows_probe.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/long_note_fixtures.dart';
import '../support/mac_editing.dart';
import '../support/perf_counters.dart';
import '../support/poll_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/spelling_editor_pump.dart';

/// On main one N2 keystroke runs ~20 s and an Enter ~30 s in the debug
/// runner: long enough to fail by assertion there, short of a timeout.
const _wi129Timeout = Timeout(Duration(minutes: 8));

/// How often one involved row may run a counted step for one event (once
/// per frame, at most two frames).
const _wi129PerRow = 2;

/// The bound on whole parses (`classifyLines`, `tokenizeInline`) for one
/// event: the involved rows' callers (span, decorations, find highlights,
/// links) plus the whole-segment passes a text change keeps (`splitRows`,
/// fenced lines); never one per row.
const _wi129Parses = 16;

final _wi129N2 = longNote(LongNoteKind.n2Bullets120k);

/// One counter's current value, by its [PerfCounters] name.
int _n(String name) => PerfCounters.snapshot()[name]!;

/// Fresh line measures (whole-text layouts) and whole-text line walks.
int _wi129Measures() =>
    _n('editableLineMeasures') +
    _n('paragraphLineMeasures') +
    _n('editableLineWalks') +
    _n('paragraphLineWalks');

/// Resets every counter this file reads.
void _wi129Reset() {
  PerfCounters.reset();
  link.debugLinkRegionTitleUpdates = 0;
  lookup.debugNoteTitleLookupBuilds = 0;
}

/// [note]'s text as a note body (a trailing line break).
String _wi129Body(LongNote note) => '${note.text}\n';

/// The first [lines] lines of [note] as a note body.
String _wi129Slice(LongNote note, int lines) =>
    '${note.lines.take(lines).join('\n')}\n';

/// The editor page's scroll position.
ScrollPosition _wi129Page(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .ancestor(
            of: find.byKey(textSegmentKey(0)),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// The index of the row of text segment 0 whose line (marker included)
/// starts with [prefix].
int _wi129RowOf(WidgetTester tester, String prefix) {
  final host = rowsHostOf(tester);
  for (var i = 0; i < host.rowCount; i++) {
    final spec = host.rowSpec(i)!;
    if (host.text.substring(spec.start, spec.textEnd).startsWith(prefix)) {
      return i;
    }
  }
  throw TestFailure('no row of text segment 0 starts with "$prefix"');
}

/// Types [text] into the focused row field as the platform's text input
/// does (it replaces the field's selection), then pumps.
Future<void> _wi129Type(WidgetTester tester, String text) async {
  final state = tester.testTextInput.editingState;
  if (state == null) throw TestFailure('no row field has an input connection');
  final value = TextEditingValue.fromJSON(state);
  final sel = value.selection;
  final next = TextEditingValue(
    text: value.text.replaceRange(sel.start, sel.end, text),
    selection: TextSelection.collapsed(offset: sel.start + text.length),
  );
  tester.testTextInput.editingState = next.toJSON();
  tester.testTextInput.updateEditingValue(next);
  await tester.pump();
}

/// Presses [key] as macOS delivers it, then pumps.
Future<void> _wi129Key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'macos');
  await tester.pump();
}

/// Enter as macOS delivers it: the key first; when nothing handles it, the
/// text system inserts a newline over the field's selection.
Future<void> _wi129Enter(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(
    LogicalKeyboardKey.enter,
    platform: 'macos',
  );
  await tester.pump();
  if (!handled) await _wi129Type(tester, '\n');
}

/// How many times a row field's `RenderEditable` was laid out while [body]
/// ran, from the framework's layout profile.
Future<int> _wi129EditableLayouts(Future<void> Function() body) async {
  debugProfileLayoutsEnabled = true;
  FlutterTimeline.debugCollectionEnabled = true;
  try {
    await body();
    return FlutterTimeline.debugCollect().getAggregated('RenderEditable').count;
  } finally {
    FlutterTimeline.debugCollectionEnabled = false;
    debugProfileLayoutsEnabled = false;
  }
}

/// Lets queued tab persistence finish before the harness deletes the temp
/// vault (`UiStateStore` writes are unawaited): alternates real IO with
/// pumps until the store's flush completes.
Future<void> _wi129Flush(WidgetTester tester, WorkspaceHarness h) async {
  await pumpFrames(tester);
  final store = h.read(tabsProvider.notifier).store;
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

/// Every D10 index Key of row [row] of text segment 0 (`editor-row-0-<r>`,
/// `find-highlights-0-<r>`, and for an item row `editor-row-marker-0-<r>`,
/// for a task row `task-checkbox-0-<r>`) sits on that row: its rect holds
/// the row's vertical centre and neither neighbour's.
void _wi129ExpectKeysName(WidgetTester tester, int row) {
  final host = rowsHostOf(tester);
  double centre(int r) => rowRectOf(tester, 0, r).center.dy;
  final mid = centre(row);
  final neighbours = [
    if (row > 0) row - 1,
    if (row + 1 < host.rowCount) row + 1,
  ];
  final spec = host.rowSpec(row)!;
  final keys = [
    'editor-row-0-$row',
    'find-highlights-0-$row',
    if (markerColumnKind(spec.kind) != null) 'editor-row-marker-0-$row',
    if (spec.kind == RowKind.task) 'task-checkbox-0-$row',
  ];
  for (final key in keys) {
    final finder = find.byKey(ValueKey<String>(key), skipOffstage: false);
    expect(finder, findsOneWidget, reason: key);
    final rect = tester.getRect(finder);
    expect(
      rect.top <= mid && mid <= rect.bottom,
      isTrue,
      reason: '$key covers row $row (centre $mid, rect $rect)',
    );
    for (final n in neighbours) {
      final c = centre(n);
      expect(
        rect.top <= c && c <= rect.bottom,
        isFalse,
        reason: '$key does not cover row $n (centre $c, rect $rect)',
      );
    }
  }
}

/// A daily note (today in [pumpLiveWorkspace]) whose person section is 200
/// bullet lines, an agent block (`a-bug`) and 100 more bullet lines.
Future<LiveRobot> _wi129Daily(WidgetTester tester) async {
  final n = _wi129N2;
  final db = FakeVaultDb.v5()
    ..seedLiveDaily(
      blocks: [
        SeedBlock('p-first', n.lines.skip(1).take(200).join('\n')),
        const SeedBlock(
          'a-bug',
          'Agent saw a bug.',
          source: 'agent',
          createdVersion: 2,
        ),
        SeedBlock('p-second', n.lines.skip(201).take(100).join('\n')),
      ],
    );
  final clock = FakeClock(DateTime(2026, 10, 3, 15));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  final r = await pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
  await r.settle();
  return r;
}

/// A paint pattern holding a done task's filled circle (`accentSoft`).
PaintPattern _wi129DoneCircle() => paints
  ..something(
    (method, args) =>
        method == #drawOval &&
        (args[1] as Paint).color.toARGB32() == OmColors.accentSoft.toARGB32(),
  );

void main() {
  holdFontFetches();

  setUp(_wi129Reset);

  // ------------------------------------------------------------- scrolling

  group('scroll paint isolation (AC1)', () {
    testWidgets(
      'a warm scroll step on N2 repaints no row and runs no layoutDecorations',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi129Body(_wi129N2));
        final page = _wi129Page(tester);
        // Warm-up: one scroll step.
        page.jumpTo(4000);
        await tester.pump();
        _wi129Reset();
        page.jumpTo(4400);
        await tester.pump();
        expect(page.pixels, 4400, reason: 'the page scrolled');
        expect(_n('rowSelectionPaints'), 0, reason: 'row paints');
        expect(_n('markerColumnPaints'), 0, reason: 'marker column paints');
        expect(_n('spellSquigglePaints'), 0, reason: 'squiggle paints');
        expect(_n('findHighlightPaints'), 0, reason: 'find highlight paints');
        expect(_n('layoutDecorations'), 0, reason: 'decoration layouts');
        await _wi129Flush(tester, e.workspace);
      },
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a warm scroll step on N1 decorated repaints no row and runs no layoutDecorations',
      (tester) async {
        final note = longNote(
          LongNoteKind.n1Plain120k,
          variant: LongNoteVariant.decorated,
        );
        final e = await pumpSpellingEditor(tester, body: _wi129Body(note));
        final page = _wi129Page(tester);
        page.jumpTo(4000);
        await tester.pump();
        _wi129Reset();
        page.jumpTo(4400);
        await tester.pump();
        expect(page.pixels, 4400, reason: 'the page scrolled');
        expect(_n('rowSelectionPaints'), 0, reason: 'row paints');
        expect(_n('markerColumnPaints'), 0, reason: 'marker column paints');
        expect(_n('spellSquigglePaints'), 0, reason: 'squiggle paints');
        expect(_n('findHighlightPaints'), 0, reason: 'find highlight paints');
        expect(_n('layoutDecorations'), 0, reason: 'decoration layouts');
        await _wi129Flush(tester, e.workspace);
      },
      timeout: _wi129Timeout,
    );
  });

  // ------------------------------------------------------------- keystrokes

  group('keystroke isolation (AC2, AC5)', () {
    testWidgets(
      'a keystroke in N2 builds spans lays out and measures only the edited row',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi129Body(_wi129N2));
        final row = _wi129RowOf(tester, '- Speaker 1525:');
        await activateRow(tester, 0, row, offset: 4);
        // Warm-up: a caret move inside the row.
        await _wi129Key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pump();
        final before = rowTextOf(tester, 0, row);
        _wi129Reset();
        final layouts = await _wi129EditableLayouts(() async {
          await _wi129Type(tester, 'q');
          await tester.pump();
        });
        expect(
          rowTextOf(tester, 0, row),
          before.replaceRange(5, 5, 'q'),
          reason: 'the keystroke landed in the row',
        );
        expect(_n('buildTextSpan'), lessThanOrEqualTo(_wi129PerRow));
        expect(layouts, lessThanOrEqualTo(_wi129PerRow), reason: 'layouts');
        expect(_wi129Measures(), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('rowBuilds'), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('rowSelectionPaints'), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('layoutDecorations'), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('markerColumnSetStates'), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('markerColumnPaints'), lessThanOrEqualTo(_wi129PerRow));
        expect(_n('spellSquigglePaints'), lessThanOrEqualTo(_wi129PerRow));
        // AC5: the edited row's callers parse it again; no other row does.
        expect(_n('classifyLines'), lessThanOrEqualTo(_wi129Parses));
        expect(_n('tokenizeInline'), lessThanOrEqualTo(_wi129Parses));
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );
  });

  // ----------------------------------------------------- Enter and a join

  group('splits and joins (AC3)', () {
    testWidgets(
      'enter in the middle of N2 builds lays out and measures no following row and its index keys still resolve',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi129Body(_wi129N2));
        final row = _wi129RowOf(tester, '- Speaker 1525:');
        final count = rowsHostOf(tester).rowCount;
        final text = rowTextOf(tester, 0, row);
        await activateRow(tester, 0, row, offset: 9);
        await _wi129Key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pump();
        _wi129Reset();
        final layouts = await _wi129EditableLayouts(() async {
          await _wi129Enter(tester);
          await tester.pump();
        });
        final host = rowsHostOf(tester);
        expect(host.rowCount, count + 1, reason: 'Enter split the row');
        expect(rowTextOf(tester, 0, row), text.substring(0, 10));
        expect(rowTextOf(tester, 0, row + 1), text.substring(10));
        // The split row and the new row, nothing below them.
        expect(_n('buildTextSpan'), lessThanOrEqualTo(2 * _wi129PerRow));
        expect(layouts, lessThanOrEqualTo(2 * _wi129PerRow), reason: 'layouts');
        expect(_wi129Measures(), lessThanOrEqualTo(2 * _wi129PerRow));
        // The rows below moved one index down; their Keys follow them.
        for (final r in [row, row + 1, row + 2, row + 3, row + 26, count - 1]) {
          _wi129ExpectKeysName(tester, r);
        }
        expect(
          rowTextOf(tester, 0, row + 2),
          startsWith('Speaker 1526:'),
          reason: 'the next row is the old row after the split one',
        );
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a join in N2 builds lays out and measures no following row and its index keys still resolve',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi129Body(_wi129N2));
        // A heading is a prose row: Backspace at its start joins its line
        // onto the item above.
        final row = _wi129RowOf(tester, '## Section 31');
        final count = rowsHostOf(tester).rowCount;
        final above = rowTextOf(tester, 0, row - 1);
        await activateRow(tester, 0, row);
        _wi129Reset();
        final layouts = await _wi129EditableLayouts(() async {
          await _wi129Key(tester, LogicalKeyboardKey.backspace);
          await tester.pump();
        });
        final host = rowsHostOf(tester);
        expect(host.rowCount, count - 1, reason: 'Backspace joined the rows');
        expect(rowTextOf(tester, 0, row - 1), '$above## Section 31');
        expect(rowTextOf(tester, 0, row), startsWith('Speaker 1501:'));
        // The joined row and the removed one, nothing below them.
        expect(_n('buildTextSpan'), lessThanOrEqualTo(2 * _wi129PerRow));
        expect(layouts, lessThanOrEqualTo(2 * _wi129PerRow), reason: 'layouts');
        expect(_wi129Measures(), lessThanOrEqualTo(2 * _wi129PerRow));
        for (final r in [row - 1, row, row + 1, row + 2, row + 49, count - 2]) {
          _wi129ExpectKeysName(tester, r);
        }
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );
  });

  // ------------------------------------------------------------ Arrow Down

  group('selection paint isolation (AC4)', () {
    testWidgets(
      'a warm arrow down in N2 repaints and rebuilds only the two rows whose selection or reveal changed',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: _wi129Body(_wi129N2));
        final row = _wi129RowOf(tester, '- Speaker 1524:');
        await activateRow(tester, 0, row, offset: 3);
        // Warm-up: one Arrow Down.
        await _wi129Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(rowsHostOf(tester).focusedRow, row + 1);
        _wi129Reset();
        await _wi129Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(rowsHostOf(tester).focusedRow, row + 2);
        const bound = 2 * _wi129PerRow;
        expect(_n('rowSelectionPaints'), lessThanOrEqualTo(bound));
        expect(_n('layoutDecorations'), lessThanOrEqualTo(bound));
        expect(_n('rowBuilds'), lessThanOrEqualTo(bound));
        expect(_n('markerColumnSetStates'), lessThanOrEqualTo(bound));
        expect(_n('markerColumnPaints'), lessThanOrEqualTo(bound));
        expect(_n('spellSquigglePaints'), lessThanOrEqualTo(bound));
        expect(_n('segmentSetStates'), 0, reason: 'no row was re-derived');
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );
  });

  // ---------------------------------------------------------- parse caches

  group('parse caches (AC5)', () {
    testWidgets(
      'a decorations repaint with unchanged text runs no classifyLines or tokenizeInline',
      (tester) async {
        final c = LivePreviewController(text: '***\nplain `code` line');
        addTearDown(c.dispose);
        final paragraph = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 200,
                child: LivePreviewDecorations(
                  controller: c,
                  boxes: () => RenderParagraphLineBoxes(
                    paragraph.currentContext!.findRenderObject()!
                        as RenderParagraph,
                  ),
                  child: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) => RichText(
                      key: paragraph,
                      text: TextSpan(
                        text: c.text,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        RenderObject decorations() =>
            tester.renderObject(find.byType(LivePreviewDecorations));

        // A selection move repaints the decorations over the same text.
        _wi129Reset();
        c.selection = const TextSelection.collapsed(offset: 5);
        await tester.pump();
        expect(_n('layoutDecorations'), 1, reason: 'the layer repainted');
        expect(_n('classifyLines'), 0, reason: 'line kinds are cached');
        expect(_n('tokenizeInline'), 0, reason: 'inline tokens are cached');
        // Still the pill of the code span and the rule.
        expect(
          decorations(),
          paints
            ..rrect(color: OmColors.surface4)
            ..rrect(color: OmColors.line2),
        );

        // A text change parses again: the rule is gone.
        c.text = 'plain line';
        await tester.pump();
        expect(decorations(), isNot(paints..rrect(color: OmColors.line2)));

        // The segment start is part of the key: the same text away from
        // it is two rules, not frontmatter.
        c.text = '---\nkey: v\n---\nbody';
        await tester.pump();
        expect(
          decorations(),
          isNot(paints..rrect(color: OmColors.line2)),
          reason: 'frontmatter at the segment start',
        );
        c.atSegmentStart = false;
        c.selection = const TextSelection.collapsed(offset: 1);
        await tester.pump();
        expect(
          decorations(),
          paints
            ..rrect(color: OmColors.line2)
            ..rrect(color: OmColors.line2),
          reason: 'away from the segment start the fences are rules',
        );
      },
    );

    testWidgets(
      'a reveal gate change reparses no row whose text did not change',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: _wi129Slice(_wi129N2, 600),
        );
        final row = _wi129RowOf(tester, '- Speaker 101:');
        _wi129Reset();
        // Focusing the segment flips every row's reveal gate.
        await activateRow(tester, 0, row, offset: 3);
        await tester.pump();
        expect(rowsHostOf(tester).focusedRow, row);
        expect(_n('classifyLines'), lessThanOrEqualTo(_wi129Parses));
        expect(_n('tokenizeInline'), lessThanOrEqualTo(_wi129Parses));
        await _wi129Flush(tester, e.workspace);
      },
      timeout: _wi129Timeout,
    );
  });

  // ------------------------------------------------- note-level rebuilds

  group('note level rebuilds (AC6, AC7)', () {
    testWidgets(
      'a save status change from dirty through saving to clean builds no editor row',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: _wi129Slice(_wi129N2, 600),
        );
        final statuses = <SaveStatus>[];
        final sub = e.container.listen<EditorStateValue>(
          editorControllerProvider,
          (_, next) => statuses.add(next.status),
        );
        addTearDown(sub.close);
        final row = _wi129RowOf(tester, '- Speaker 101:');
        await activateRow(tester, 0, row, offset: 3);
        await tester.pump();
        _wi129Reset();
        await _wi129Type(tester, 'q');
        await tester.pump();
        expect(
          e.container.read(editorControllerProvider).status,
          SaveStatus.dirty,
        );
        expect(
          _n('rowBuilds'),
          lessThanOrEqualTo(_wi129PerRow),
          reason:
              'the keystroke that made the note dirty builds the edited row',
        );
        _wi129Reset();
        statuses.clear();
        await e.robot.waitForSave();
        expect(
          statuses,
          containsAllInOrder([SaveStatus.saving, SaveStatus.clean]),
        );
        expect(
          e.container.read(editorControllerProvider).status,
          SaveStatus.clean,
        );
        expect(_n('rowBuilds'), 0, reason: 'row builds while saving');
        expect(_n('buildTextSpan'), 0, reason: 'span builds while saving');
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a note titles reload with no title change for the links builds and notifies no editor row',
      (tester) async {
        final note = longNote(
          LongNoteKind.n2Bullets120k,
          variant: LongNoteVariant.decorated,
        );
        final e = await pumpSpellingEditor(
          tester,
          body: _wi129Slice(note, 600),
        );
        await pumpFrames(tester);
        var loads = 0;
        final sub = e.container.listen(noteTitlesAsyncProvider, (_, next) {
          if (next.hasValue && !next.isLoading) loads++;
        });
        addTearDown(sub.close);
        _wi129Reset();
        e.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(loads, greaterThan(0), reason: 'the titles reloaded');
        expect(_n('rowBuilds'), 0, reason: 'row builds');
        expect(_n('buildTextSpan'), 0, reason: 'span builds');
        expect(
          link.debugLinkRegionTitleUpdates,
          0,
          reason: 'no row was notified',
        );
        expect(
          lookup.debugNoteTitleLookupBuilds,
          lessThanOrEqualTo(1),
          reason: 'one shared lookup per reload',
        );
        await _wi129Flush(tester, e.workspace);
      },
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a revision poller reload with unchanged text builds no editor row',
      (tester) async {
        final r = await _wi129Daily(tester);
        final text = r.bodyText;
        final revision = r.revision;
        _wi129Reset();
        // A write elsewhere in the vault moves its revision; this note's
        // text stays.
        r.db.db.execute(
          'UPDATE notes SET updated_at = updated_at + 1 WHERE id = ?',
          [liveZetaId],
        );
        await r.poll();
        expect(
          r.revision,
          greaterThan(revision),
          reason: 'the poller reloaded',
        );
        expect(r.bodyText, text);
        expect(_n('rowBuilds'), 0, reason: 'row builds');
        expect(_n('buildTextSpan'), 0, reason: 'span builds');
        await _wi129Flush(tester, r.h);
      },
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a note titles reload that resolves one link notifies only the row linking to it',
      (tester) async {
        final note = longNote(
          LongNoteKind.n2Bullets120k,
          variant: LongNoteVariant.decorated,
        );
        final e = await pumpSpellingEditor(
          tester,
          body: _wi129Slice(note, 600),
        );
        await pumpFrames(tester);
        final host = rowsHostOf(tester);
        final row = _wi129RowOf(tester, '- Speaker 75:');
        expect(rowTextOf(tester, 0, row), contains('[[Note 7]]'));
        final linking = host.rowController(row)!;
        expect(
          linking.isResolved?.call('Note 7'),
          isFalse,
          reason: 'a ghost before the note exists',
        );
        // Every row controller's notifications from here on.
        final notified = List.filled(host.rowCount, 0);
        final listeners = <(LivePreviewController, VoidCallback)>[];
        for (var i = 0; i < host.rowCount; i++) {
          final c = host.rowController(i)!;
          void count() => notified[i]++;
          c.addListener(count);
          listeners.add((c, count));
        }
        addTearDown(() {
          for (final (c, l) in listeners) {
            c.removeListener(l);
          }
        });
        e.workspace.db.seedTopicNote('topic-note-7', 'Note 7');
        _wi129Reset();
        e.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(linking.isResolved!('Note 7'), isTrue, reason: 'it resolves');
        expect(
          [
            for (final (i, n) in notified.indexed)
              if (n > 0) i,
          ],
          [row],
          reason: 'only the linking row is notified',
        );
        expect(
          link.debugLinkRegionTitleUpdates,
          1,
          reason: 'one link region handed the change',
        );
        expect(
          lookup.debugNoteTitleLookupBuilds,
          1,
          reason: 'one shared lookup per reload',
        );
        expect(_n('buildTextSpan'), lessThanOrEqualTo(_wi129PerRow));
        await _wi129Flush(tester, e.workspace);
      },
      timeout: _wi129Timeout,
    );
  });

  // ------------------------------------------------ shared key listener

  group('shared keyboard handler (AC8)', () {
    testWidgets(
      'one hardware keyboard handler serves every link region of the editor',
      (tester) async {
        // Two text segments around an excerpt card.
        final e = await pumpSpellingEditor(
          tester,
          body:
              '${_wi129Slice(_wi129N2, 300)}$fixtureRangeToken\n- tail item\n',
        );
        await pumpFrames(tester);
        expect(find.byKey(textSegmentKey(2)), findsOneWidget);
        expect(
          find.byType(link.LinkRegion, skipOffstage: false).evaluate().length,
          greaterThan(300),
        );
        expect(link.debugLinkKeyHandlers, 1, reason: 'one per editor');
        // More rows, more link regions, still one handler.
        await activateRow(tester, 0, 10, offset: 3);
        await _wi129Enter(tester);
        await pumpFrames(tester);
        expect(rowsHostOf(tester).rowCount, greaterThan(300));
        expect(link.debugLinkKeyHandlers, 1, reason: 'one per editor');
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );

    testWidgets('cmd hover link styling still follows the modifier key', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: '- see [[Other note]] here\n- second item\n',
      );
      await pumpFrames(tester);
      // The caret on the link's line: its markup shows, so a plain hover
      // styles nothing and Cmd does.
      await activateRow(tester, 0, 0);
      final controller = rowsHostOf(tester).rowController(0)!;
      final text = controller.text;
      final start = text.indexOf('Other note');
      final boxes = rowBoxesOf(tester, 0, 0);
      final shown = boxes
          .boxesFor(TextRange(start: start, end: start + 'Other note'.length))
          .first;
      final at = boxes.box.localToGlobal(shown.center);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at);
      await tester.pump();
      await mouse.moveTo(at);
      await tester.pump();
      expect(controller.cmdHover, isNull, reason: 'a plain hover');
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump();
      expect(
        controller.cmdHover,
        TextRange(start: text.indexOf('[['), end: text.indexOf(']]') + 2),
        reason: 'Cmd held styles the hovered link',
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump();
      expect(controller.cmdHover, isNull, reason: 'Cmd released');
      await mouse.removePointer();
      await tester.pump();
      await _wi129Flush(tester, e.workspace);
    }, variant: macOnly);
  });

  // --------------------------------------------------------- marker columns

  group('marker column updates (AC9)', () {
    testWidgets(
      'a keystroke sets no state on marker columns whose marker number and checkbox did not change',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: _wi129Slice(_wi129N2, 600),
        );
        final row = _wi129RowOf(tester, '- Speaker 101:');
        await activateRow(tester, 0, row, offset: 3);
        await _wi129Key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pump();
        _wi129Reset();
        await _wi129Type(tester, 'q');
        await tester.pump();
        expect(rowTextOf(tester, 0, row), contains('q'));
        // At most the edited row's own column, through its own row.
        expect(_n('markerColumnSetStates'), lessThanOrEqualTo(1));
        expect(_n('markerColumnBuilds'), lessThanOrEqualTo(_wi129PerRow));
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );

    testWidgets(
      'a marker column still updates when its checkbox or the selection over it changes',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '- [ ] first task\n- second\n- third\n- fourth\n',
        );
        await pumpFrames(tester);
        await activateRow(tester, 0, 3);
        final host = rowsHostOf(tester);
        RenderObject column(String key) => tester.renderObject(
          find.byKey(ValueKey<String>(key), skipOffstage: false),
        );
        expect(
          column('task-checkbox-0-0'),
          isNot(_wi129DoneCircle()),
          reason: 'open task',
        );
        // A segment edit from elsewhere toggles the task.
        host.applyEdit(toggleTask(host.text, host.rowSpec(0)!)!);
        await tester.pump();
        expect(
          column('task-checkbox-0-0'),
          _wi129DoneCircle(),
          reason: 'done task',
        );
        // A selection spanning rows 1 and 2 fills their columns.
        host.select(
          TextSelection(
            baseOffset: host.rowSpec(0)!.textStart,
            extentOffset: host.rowSpec(3)!.textEnd,
          ),
        );
        await tester.pump();
        expect(
          column('editor-row-marker-0-1'),
          paints..rect(color: OmColors.selection),
          reason: 'selected item',
        );
        host.select(TextSelection.collapsed(offset: host.rowSpec(3)!.textEnd));
        await tester.pump();
        expect(
          column('editor-row-marker-0-1'),
          isNot(paints..rect(color: OmColors.selection)),
          reason: 'selection gone',
        );
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
    );
  });

  // ---------------------------------------------------------- capture gutter

  group('capture gutter measures (AC10)', () {
    testWidgets(
      'a keystroke in a long daily note makes the capture gutter measure only the edited row',
      (tester) async {
        final r = await _wi129Daily(tester);
        expect(r.gutterRule('a-bug'), findsOneWidget);
        expect(rowsHostOf(tester).rowCount, greaterThan(250));
        await activateRow(tester, 0, 10, offset: 3);
        await _wi129Key(tester, LogicalKeyboardKey.arrowRight);
        await r.settle();
        _wi129Reset();
        await _wi129Type(tester, 'z');
        await tester.pump();
        await tester.pump();
        expect(rowTextOf(tester, 0, 10), contains('z'));
        expect(_wi129Measures(), lessThanOrEqualTo(2 * _wi129PerRow));
        expect(r.gutterRule('a-bug'), findsOneWidget);
        await _wi129Flush(tester, r.h);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );

    testWidgets(
      'the capture gutter rule still covers its block after an enter above it',
      (tester) async {
        final r = await _wi129Daily(tester);
        double agentLine() =>
            r.lineCenterY(r.bodyText.indexOf('Agent saw a bug.'));
        final before = agentLine();
        await activateRow(tester, 0, 10, offset: 3);
        await _wi129Enter(tester);
        await r.settle();
        final after = agentLine();
        expect(after, greaterThan(before), reason: 'the block moved down');
        final rule = tester.getRect(r.gutterRule('a-bug'));
        expect(
          rule.top <= after && after <= rule.bottom,
          isTrue,
          reason: 'rule $rule covers the block line at $after',
        );
        await _wi129Flush(tester, r.h);
      },
      variant: macOnly,
      timeout: _wi129Timeout,
    );
  });

  // ---------------------------------------------------------- index keys

  group('index keys (AC11)', () {
    testWidgets(
      'every index key names the row at its index after an insert and a join',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body:
              '- one\n- [ ] two task\n1. three\n- four\nplain prose line\n'
              '- five\n> a quote\n- six\n',
        );
        await pumpFrames(tester);
        void expectAll() {
          final host = rowsHostOf(tester);
          for (var i = 0; i < host.rowCount; i++) {
            if (rowTextOf(tester, 0, i).isEmpty) continue;
            _wi129ExpectKeysName(tester, i);
          }
        }

        expectAll();
        final count = rowsHostOf(tester).rowCount;
        // An insert: Enter at the end of the first item.
        await activateRow(tester, 0, 0, offset: 3);
        await _wi129Enter(tester);
        await _wi129Type(tester, 'new');
        await pumpFrames(tester);
        expect(rowsHostOf(tester).rowCount, count + 1);
        expect(rowTextOf(tester, 0, 1), 'new');
        expectAll();
        // A join: Backspace at the start of the prose row.
        final prose = _wi129RowOf(tester, 'plain prose line');
        await activateRow(tester, 0, prose);
        await _wi129Key(tester, LogicalKeyboardKey.backspace);
        await pumpFrames(tester);
        expect(rowsHostOf(tester).rowCount, count);
        expect(rowTextOf(tester, 0, prose - 1), 'fourplain prose line');
        expectAll();
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
    );
  });
}
