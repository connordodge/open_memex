// #69 (54-O3, Spec #58 R17-R21, R34; rulings D3, D5): `jumpToOutlineEntry`
// lands an Outline entry's heading through the note reveal seam, pinned from
// the Outline's side on the shared reveal pump. Entries come from
// `outlineEntries` over the live text the editor shows, as the Outline tab
// computes them. Geometry comes from the editor's own line boxes
// (`lineTopOf`), never from constants: #53 changes heading geometry. Tests
// that pin a no-op end with a control jump that does land.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/outline/outline_jump.dart';

import '../support/font_fetch_hold.dart';
import '../support/note_reveal_pump.dart';
import '../support/segment_editing_finder.dart';

/// Line tops sit on half pixels; the jump lands them exactly.
const _wi69Px = 0.01;

/// A WidgetRef in the workspace (the editor's element), as the Outline
/// tab's own ref would be.
WidgetRef _wi69Ref(WidgetTester tester) =>
    tester.element(find.byType(NoteEditor)) as WidgetRef;

/// The Outline entries of the live text the editor shows.
List<OutlineEntry> _wi69Entries(NoteRevealHarness h) =>
    outlineEntries(h.shownContent(), role: h.body().note.role);

/// The entry whose plain text starts with [text].
OutlineEntry _wi69Entry(NoteRevealHarness h, String text) =>
    _wi69Entries(h).firstWhere(
      (e) => e.text.startsWith(text),
      orElse: () => throw TestFailure('no entry "$text"'),
    );

/// Jumps to [entry] of the shown note with the shown text, as the tab does.
void _wi69Jump(NoteRevealHarness h, OutlineEntry entry, {String? content}) =>
    jumpToOutlineEntry(
      _wi69Ref(h.tester),
      h.body().note.id,
      entry,
      content ?? h.shownContent(),
    );

/// The heading line top of [entry], relative to the viewport top.
double _wi69FromTop(NoteRevealHarness h, OutlineEntry entry) =>
    h.lineTopOf(entry.segment, entry.local) - h.viewport().top;

/// The page stays at [pixels] and shows no highlight over [frames] frames
/// (more than the seam's 8 tries).
Future<void> _wi69ExpectStill(
  WidgetTester tester,
  NoteRevealHarness h,
  double pixels, {
  int frames = 14,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    expect(h.pixels(), pixels, reason: 'frame $i: nothing scrolls');
    expect(h.highlight, findsNothing, reason: 'frame $i: no highlight');
  }
  expect(tester.takeException(), isNull, reason: 'no error');
}

/// A control after a no-op: a jump to a freshly computed Mid heading entry
/// lands it.
Future<void> _wi69ExpectControlLands(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  final mid = _wi69Entry(h, 'Mid heading');
  _wi69Jump(h, mid);
  await pumpFrames(tester);
  expect(
    _wi69FromTop(h, mid),
    closeTo(16, _wi69Px),
    reason: 'control: a jump to a current entry lands',
  );
}

/// The widths of the boxes laid out for [entry]'s `#` marker and its space.
List<double> _wi69MarkerWidths(NoteRevealHarness h, OutlineEntry entry) {
  final row = h.rowOf(entry.segment, entry.local);
  final editable = findRenderEditable(
    h.tester.renderObject(h.rowFinder(entry.segment, row.index)),
  )!;
  final start = row.spec.toLocal(entry.local);
  return [
    for (final b in editable.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + entry.level + 1),
    ))
      b.right - b.left,
  ];
}

void main() {
  holdFontFetches();

  group('the jump', () {
    testWidgets(
      'jumpToOutlineEntry on a long note lands the heading line top 16 px below the visible editor body top with no animation',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final wrapped = _wi69Entry(h, 'Wrapped');
        expect(wrapped.local, h.offsetOf(revealWrappedHeading));
        expect(h.pixels(), 0);
        final jumps = h.jumps();

        _wi69Jump(h, wrapped);
        await tester.pump();
        await tester.pump();

        expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
        expect(jumps.count, 1, reason: 'one jump, no animation: $jumps');
        final landed = h.pixels();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 200));
        expect(h.pixels(), landed, reason: 'nothing animates after it');

        // Up: a heading above the viewport lands the same way.
        final mid = _wi69Entry(h, 'Mid heading');
        expect(_wi69FromTop(h, mid), lessThan(0));
        jumps.clear();
        _wi69Jump(h, mid);
        await tester.pump();
        await tester.pump();

        expect(_wi69FromTop(h, mid), closeTo(16, _wi69Px));
        expect(jumps.count, 1, reason: 'one jump up: ${jumps.values}');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a jump to a heading near the end of the note clamps to the max scroll extent',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final end = _wi69Entry(h, 'Near the end');
        final max = h.position().maxScrollExtent;
        final unclamped = h.pixels() + _wi69FromTop(h, end) - 16;
        expect(unclamped, greaterThan(max + 1), reason: 'cannot scroll so far');

        _wi69Jump(h, end);
        await pumpFrames(tester);

        expect(h.pixels(), max);
        expect(_wi69FromTop(h, end), greaterThan(16 + 1));
        expect(h.highlight, findsOneWidget, reason: 'it still flashes');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('anchors', () {
    testWidgets(
      'a jump to a heading in the middle of a multi line prose row lands that heading line',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final mid = _wi69Entry(h, 'Mid heading');
        expect(mid.local, h.offsetOf(revealMidHeading));
        final row = h.rowOf(0, mid.local);
        expect(row.index, h.rowOf(0, h.offsetOf('para before')).index);
        expect(row.index, h.rowOf(0, h.offsetOf('para after')).index);

        _wi69Jump(h, mid);
        await pumpFrames(tester);

        expect(_wi69FromTop(h, mid), closeTo(16, _wi69Px));
        expect(
          h.rowRectOf(0, mid.local).top,
          lessThan(h.viewport().top - 1000),
          reason: 'its row starts far above',
        );
        expect(
          h.lineTopOf(0, h.offsetOf('para before')) - h.viewport().top,
          lessThan(16),
          reason: 'the paragraph line above it is above the mark',
        );
      },
    );

    testWidgets('a jump to a wrapped heading lands its first visual line', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final wrapped = _wi69Entry(h, 'Wrapped');
      final end = wrapped.local + revealWrappedHeading.length;
      expect(h.lineCount(0, wrapped.local, end), greaterThan(1));

      _wi69Jump(h, wrapped);
      await pumpFrames(tester);

      expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
      expect(
        h.lineTopOf(0, end - 1) - h.viewport().top,
        greaterThan(16 + 1),
        reason: 'its last visual line sits lower',
      );
    });

    testWidgets(
      'a jump in a daily note lands a heading of stray text past the shared prefix',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealDailyId);
        await h.scrollTo(0);
        final stray = _wi69Entry(h, 'Stray heading');
        expect(
          stray.local,
          h.offsetOf(revealStrayHeading, segment: stray.segment),
        );
        expect(
          h.shownContent().indexOf(revealStrayHeading),
          isNot(stray.local),
          reason: 'not at its body offset',
        );

        _wi69Jump(h, stray);
        await pumpFrames(tester);

        expect(_wi69FromTop(h, stray), closeTo(16, _wi69Px));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('after a jump', () {
    testWidgets(
      'after a jump the caret selection focus and history are unchanged the marker stays hidden the heading flashes and the offset is recorded',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);
        await h.navigate(const NoteTab(revealLongId));
        await pumpFrames(tester);
        // A caret on a plain body line, focused.
        final caret = h.offsetOf('line 3\n') + 2;
        editorBodySegment(
          tester,
        ).select(TextSelection.collapsed(offset: caret));
        await pumpFrames(tester);
        final focus = FocusManager.instance.primaryFocus;
        expect(focus, isNotNull);
        final selection = editorBodySegment(tester).selection;
        expect(selection, TextSelection.collapsed(offset: caret));
        final before = h.tabState;
        final wrapped = _wi69Entry(h, 'Wrapped');

        _wi69Jump(h, wrapped);
        await tester.pump();
        await tester.pump();

        expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
        // Caret, selection and focus.
        expect(editorBodySegment(tester).selection, selection);
        expect(FocusManager.instance.primaryFocus, same(focus));
        // The heading's marker stays hidden: it lays out no width.
        final widths = _wi69MarkerWidths(h, wrapped);
        for (final w in widths) {
          expect(w, lessThan(0.01), reason: 'the # marker stays hidden');
        }
        // The arrival highlight shows on the heading's line.
        expect(h.highlight, findsOneWidget);
        final shown = tester.widget<EchoArrivalHighlight>(h.highlight);
        final row = tester.renderObject<RenderBox>(
          h.rowFinder(0, h.rowOf(0, wrapped.local).index),
        );
        expect(shown.target, same(row));
        final band = MatrixUtils.transformRect(
          row.getTransformTo(null),
          shown.band,
        );
        final line = h.lineBoxOf(0, wrapped.local);
        expect(band.top, lessThanOrEqualTo(line.top + _wi69Px));
        expect(band.bottom, greaterThanOrEqualTo(line.bottom - _wi69Px));
        // No history arrival; the entry holds the new offset.
        final after = h.tabState;
        expect(after.tabs, before.tabs);
        expect(after.activeIndex, before.activeIndex);
        expect(after.arrivals, before.arrivals);
        expect(after.canGoBack, before.canGoBack);
        expect(after.canGoForward, before.canGoForward);
        expect(h.recorded.last, (noteId: revealLongId, offset: h.pixels()));
        // Back then Forward returns to the jumped-to offset.
        final landed = h.pixels();
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealOtherId);
        h.tabs.forward();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), landed);
      },
    );

    testWidgets(
      'a jump leaves an unfocused editor unfocused and places no caret',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final focus = FocusManager.instance.primaryFocus;
        expect(editorBodySegment(tester).focusedRow, isNull);
        final mid = _wi69Entry(h, 'Mid heading');

        _wi69Jump(h, mid);
        await pumpFrames(tester);

        expect(_wi69FromTop(h, mid), closeTo(16, _wi69Px));
        expect(FocusManager.instance.primaryFocus, same(focus));
        expect(editorBodySegment(tester).focusedRow, isNull);
        for (final w in _wi69MarkerWidths(h, mid)) {
          expect(w, lessThan(0.01), reason: 'the # marker stays hidden');
        }
      },
    );
  });

  group('stale entries', () {
    testWidgets(
      'a jump for an entry whose heading moved since the entries were computed does not scroll and shows no error',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(1500);
        final stale = _wi69Entry(h, 'Mid heading');
        final staleContent = h.shownContent();
        // The text changes after the entries were computed: lines above the
        // heading go, so nothing at its old position is that heading.
        final segment = editorBodySegment(tester);
        segment.replaceText(
          segment.text.replaceFirst(revealLines('line', 0, 40), ''),
        );
        await pumpFrames(tester);
        expect(h.shownContent(), isNot(staleContent));
        final pixels = h.pixels();

        _wi69Jump(h, stale, content: staleContent);
        await _wi69ExpectStill(tester, h, pixels);

        await _wi69ExpectControlLands(tester, h);
      },
    );

    testWidgets(
      'a jump for a note the editor no longer shows does not scroll and shows no error',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(1500);
        final entry = _wi69Entry(h, 'Mid heading');
        final content = h.shownContent();
        await h.navigate(const NoteTab(revealOtherId));
        expect(h.body().note.id, revealOtherId);
        await h.scrollTo(400);

        jumpToOutlineEntry(_wi69Ref(tester), revealLongId, entry, content);
        await _wi69ExpectStill(tester, h, 400);

        // Going back to the note later restores its offset; the jump died.
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), 1500);
        expect(h.highlight, findsNothing);
        expect(_wi69FromTop(h, entry), isNot(closeTo(16, 1)));

        await _wi69ExpectControlLands(tester, h);
      },
    );
  });

  group('repeats', () {
    testWidgets(
      'two jumps in a row to the same entry both land after a scroll between them',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final wrapped = _wi69Entry(h, 'Wrapped');

        _wi69Jump(h, wrapped);
        await pumpFrames(tester);
        expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
        final landed = h.pixels();
        await tester.pump(const Duration(milliseconds: 1300));

        await h.scrollTo(landed - 900);
        expect(_wi69FromTop(h, wrapped), closeTo(16 + 900, _wi69Px));
        _wi69Jump(h, wrapped);
        await pumpFrames(tester);

        expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
        expect(h.pixels(), landed);
        expect(h.highlight, findsOneWidget, reason: 'the second one flashes');
        expect(h.recorded.last, (noteId: revealLongId, offset: landed));
      },
    );

    testWidgets('two jumps in the same frame land once on the later entry', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final mid = _wi69Entry(h, 'Mid heading');
      final wrapped = _wi69Entry(h, 'Wrapped');
      final jumps = h.jumps();

      _wi69Jump(h, mid);
      _wi69Jump(h, wrapped);
      await pumpFrames(tester);

      expect(_wi69FromTop(h, wrapped), closeTo(16, _wi69Px));
      expect(jumps.count, 1, reason: 'one landing: ${jumps.values}');
      expect(h.highlight, findsOneWidget);
    });
  });

  group('Source mode', () {
    testWidgets(
      'a jump from Source mode switches the editor to live preview and lands the heading 16 px below the top',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.toggleSource();
        expect(h.sourceSurface, findsOneWidget);
        // In Source the live text is the editor's; the tab's entries come
        // from it.
        final content = h.editor.contentMd;
        final entry = outlineEntries(
          content,
        ).firstWhere((e) => e.text == 'Mid heading');

        jumpToOutlineEntry(_wi69Ref(tester), revealLongId, entry, content);
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(h.sourceSurface, findsNothing);
        expect(find.byType(SegmentedBody), findsOneWidget);
        expect(_wi69FromTop(h, entry), closeTo(16, _wi69Px));
        expect(h.highlight, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
