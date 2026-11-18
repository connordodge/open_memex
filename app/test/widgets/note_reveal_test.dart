// #66 (54-R0, rulings D3, D5, D6): `NoteEditor._reveal` lands every
// `NoteRevealRequest` under the D3 landing rules, on the shared reveal pump.
// Geometry comes from the editor's own line boxes (`lineTopOf`, `lineBoxOf`),
// never from constants: #53 changes heading geometry in parallel. Tests that
// pin a no-op end with a control request that does land, so they cannot pass
// on a seam that never lands anything.
//
// The D4 call counts are in `note_reveal_counts_test.dart`; the pure row
// lookup is in `locate_in_segment_test.dart`.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/byte_offsets.dart';
import 'package:open_memex_app/src/state/echo_scroll_target.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/note_reveal.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart'
    show fixtureRangeToken, fixtureTopicId, seedSegmentedVault;
import '../support/font_fetch_hold.dart';
import '../support/note_reveal_pump.dart';
import '../support/segment_editing_finder.dart';

const _wi66Top16 = RevealTop(16);
const _wi66Within60 = RevealWithin(60);

/// The editor's geometry is exact to this (line tops sit on half pixels).
const _wi66Px = 0.01;

/// The offset of `line <i>` in the long note's segment 0.
int _wi66Line(NoteRevealHarness h, int i) => h.offsetOf('line $i\n');

/// A request on the long note for [start] (to [end]) of segment 0.
NoteRevealRequest _wi66Req(
  NoteRevealHarness h,
  int start, {
  int? end,
  RevealPlacement placement = _wi66Top16,
  bool flash = false,
  bool leaveSource = false,
  String noteId = revealLongId,
}) => NoteRevealRequest(
  noteId,
  h.textAt(start, end: end),
  placement,
  flash: flash,
  leaveSource: leaveSource,
);

/// A request on the long note for [start] of its stored text (usable before
/// the note shows, and in Source mode).
NoteRevealRequest _wi66Stored(
  int start, {
  RevealPlacement placement = _wi66Top16,
  bool flash = false,
  bool leaveSource = false,
}) => NoteRevealRequest(
  revealLongId,
  RevealAtText(segment: 0, start: start, content: revealLongBody),
  placement,
  flash: flash,
  leaveSource: leaveSource,
);

int get _wi66StoredMid => revealLongBody.indexOf(revealMidHeading);

/// The global y of line [local]'s top, relative to the viewport top.
double _wi66FromTop(NoteRevealHarness h, int local, {int segment = 0}) =>
    h.lineTopOf(segment, local) - h.viewport().top;

/// Pumps zero-length frames until the highlight shows, at most [frames].
Future<bool> _wi66UntilHighlight(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    if (find.byType(EchoArrivalHighlight).evaluate().isNotEmpty) return true;
  }
  return false;
}

/// The page stays at [pixels] and shows no highlight over [frames] frames.
Future<void> _wi66ExpectStill(
  WidgetTester tester,
  NoteRevealHarness h,
  double pixels, {
  int frames = 12,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    expect(h.pixels(), pixels, reason: 'frame $i: nothing scrolls');
    expect(h.highlight, findsNothing, reason: 'frame $i: no highlight');
  }
}

/// After an arrival that landed at the top, a user scroll is reported again
/// (the arrival released the held reports).
Future<void> _wi66ExpectReportsResume(NoteRevealHarness h) async {
  await h.scrollTo(200);
  expect(h.recorded.last, (
    noteId: revealLongId,
    offset: 200.0,
  ), reason: 'the scroll after the arrival is recorded');
}

/// A control after a no-op: a request for the mid heading lands it.
Future<void> _wi66ExpectControlLands(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  final mid = h.offsetOf(revealMidHeading);
  h.request(_wi66Req(h, mid));
  await pumpFrames(tester);
  expect(
    _wi66FromTop(h, mid),
    closeTo(16, _wi66Px),
    reason: 'control: a request that is valid lands',
  );
}

/// A body with a bullet row, a table and an excerpt card (segment 1).
String get _wi66RowsBody =>
    '${revealLines('line', 0, 100)}'
    '- bullet target\n'
    '${revealLines('after bullet', 0, 100)}'
    '| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n'
    '${revealLines('after table', 0, 100)}'
    '$fixtureRangeToken\n'
    '${revealLines('after card', 0, 100)}';

Future<NoteRevealHarness> _wi66PumpRows(WidgetTester tester) {
  final v = seedSegmentedVault(topicBody: _wi66RowsBody);
  seedRevealNotes(v.db);
  return pumpNoteReveal(tester, db: v.db, cli: v.cli, open: fixtureTopicId);
}

RenderBox _wi66RowBox(NoteRevealHarness h, int segment, int row) =>
    h.tester.renderObject<RenderBox>(h.rowFinder(segment, row));

RenderBox _wi66Column(NoteRevealHarness h, int segment) => h.tester
    .renderObject<RenderBox>(find.byKey(ValueKey('text-segment-$segment')));

/// The echo arrival for segment-0 offset [at] of the shown (non-daily) note,
/// whose segment 0 starts the body.
EchoArrival _wi66Echo(NoteRevealHarness h, int at) {
  final content = h.shownContent();
  final arrival = locateEchoArrival(content, utf16ToUtf8(content, at));
  expect(arrival, isNotNull);
  return arrival!;
}

void main() {
  holdFontFetches();

  group('the reveal pump', () {
    testWidgets(
      'the reveal pump shows a long note in a sized viewport and reads line tops from line boxes',
      (tester) async {
        final h = await pumpNoteReveal(tester);

        expect(h.body().note.id, revealLongId);
        expect(h.shownContent(), revealLongBody);
        expect(h.viewport().height, greaterThan(500));
        expect(
          h.position().maxScrollExtent,
          greaterThan(2 * h.viewport().height),
        );
        final first = h.lineTopOf(0, 0);
        final second = h.lineTopOf(0, _wi66Line(h, 1));
        expect(second, greaterThan(first));
        final mid = h.offsetOf(revealMidHeading);
        final midTop = h.lineTopOf(0, mid);
        expect(midTop, greaterThan(second));

        await h.scrollTo(100);

        expect(h.lineTopOf(0, 0), closeTo(first - 100, _wi66Px));
        expect(h.lineTopOf(0, mid), closeTo(midTop - 100, _wi66Px));
        expect(tester.takeException(), isNull);
      },
    );
  });

  // ------------------------------------------------------------------ D3a
  group('when a request lands', () {
    testWidgets('a request for the shown note lands on the next frame', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final mid = h.offsetOf(revealMidHeading);
      expect(h.pixels(), 0);

      h.request(_wi66Req(h, mid));
      await tester.pump();

      expect(h.pixels(), greaterThan(0), reason: 'jumped on the next frame');
      await tester.pump();
      expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));
      expect(h.pending, isNull, reason: 'the request is used up');
      await pumpFrames(tester);
      expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px), reason: 'it stays');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'navigating to the shown note then requesting lands on the next frame',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final arrivals = h.tabState.arrivals;
        final mid = h.offsetOf(revealMidHeading);

        // Callers navigate first (D3b); onto the shown note that is a no-op.
        h.tabs.navigate(const NoteTab(revealLongId));
        h.request(_wi66Req(h, mid));
        expect(h.tabState.arrivals, arrivals, reason: 'no arrival');
        await tester.pump();

        expect(h.pixels(), greaterThan(0));
        await tester.pump();
        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));
      },
    );

    testWidgets('a request for a note not yet shown lands on its hydrate', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester, open: revealOtherId);

      h.tabs.navigate(const NoteTab(revealLongId));
      h.request(_wi66Stored(_wi66StoredMid));
      await pumpFrames(tester);
      await pumpFrames(tester);

      expect(h.body().note.id, revealLongId);
      expect(_wi66FromTop(h, _wi66StoredMid), closeTo(16, _wi66Px));
      expect(h.pending, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a hydrate with an echo target and a reveal request takes both and lands once',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);
        final jumps = h.jumps();
        final echoByte = utf16ToUtf8(
          revealLongBody,
          revealLongBody.indexOf('line 300\n'),
        );

        h
            .read(echoScrollTargetProvider.notifier)
            .set(EchoScrollTarget(revealLongId, echoByte));
        h.tabs.navigate(const NoteTab(revealLongId));
        h.request(_wi66Stored(_wi66StoredMid));
        expect(h.pending, isNotNull, reason: 'held until the hydrate');
        expect(h.read(echoScrollTargetProvider), isNotNull);
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(h.body().note.id, revealLongId);
        expect(h.read(echoScrollTargetProvider), isNull, reason: 'taken');
        expect(h.pending, isNull, reason: 'taken after the echo target');
        expect(jumps.count, 1, reason: 'one landing: ${jumps.values}');

        // The echo's landing is the one that ran: its passage a third of the
        // way down and highlighted, not the request's heading at the inset.
        final echoAt = _wi66Line(h, 300);
        final vh = h.position().viewportDimension;
        expect(
          _wi66FromTop(h, echoAt),
          closeTo(vh / 3 - h.lineBoxOf(0, echoAt).height / 2, _wi66Px),
          reason: 'the echo passage sits a third of the way down',
        );
        expect(h.highlight, findsOneWidget, reason: 'the echo flashes');
        expect(
          _wi66FromTop(h, h.offsetOf(revealMidHeading)),
          isNot(closeTo(16, 1)),
          reason: 'the request did not land',
        );
      },
    );

    testWidgets(
      'focusing a tab on the shown note then requesting lands the request and not the restore',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(300);
        h.tabs.openOrFocus(const NoteTab(revealOtherId));
        await pumpFrames(tester);
        await h.navigate(const NoteTab(revealLongId));
        expect(h.tabState.tabs, const [
          NoteTab(revealLongId),
          NoteTab(revealLongId),
        ]);
        expect(h.tabState.activeIndex, 1);
        final mid = h.offsetOf(revealMidHeading);

        // The focus arrives on the note already shown: its restore is due.
        h.tabs.openOrFocus(const NoteTab(revealLongId));
        h.request(_wi66Req(h, mid));
        await pumpFrames(tester);

        expect(h.tabState.activeIndex, 0);
        expect(h.pixels(), isNot(300.0));
        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));
      },
    );
  });

  // ------------------------------------------------------------------ D3b
  group('validity', () {
    testWidgets(
      'a request made before navigating to its note dies at that arrival',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);

        // The wrong order: the navigate's arrival comes after the stamp.
        h.request(_wi66Stored(_wi66StoredMid, flash: true));
        await _wi66ExpectStill(tester, h, 0.0);
        expect(h.body().note.id, revealOtherId, reason: 'not the shown note');
        h.tabs.navigate(const NoteTab(revealLongId));
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealLongId);
        await _wi66ExpectStill(tester, h, 0.0);

        await _wi66ExpectControlLands(tester, h);
      },
    );
  });

  // ------------------------------------------------------------------ D3c
  group('anchors', () {
    testWidgets(
      'a text request for a heading in the middle of a prose row lands that heading line and not the row top',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final mid = h.offsetOf(revealMidHeading);
        final row = h.rowOf(0, mid);
        // One prose row holds the paragraph, the heading and the next line.
        expect(row.index, 0);
        expect(row.spec.start, 0);
        expect(h.rowOf(0, h.offsetOf('para before')).index, 0);
        expect(h.rowOf(0, h.offsetOf('para after')).index, 0);

        h.request(_wi66Req(h, mid));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));
        expect(
          h.rowRectOf(0, mid).top,
          lessThan(h.viewport().top - 1000),
          reason: 'the row starts far above',
        );
        expect(
          _wi66FromTop(h, h.offsetOf('para before')),
          lessThan(16),
          reason: 'the paragraph line above the heading is above the inset',
        );
      },
    );

    testWidgets(
      'a text request for a wrapped heading anchors on its first visual line',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = h.offsetOf(revealWrappedHeading);
        final end = at + revealWrappedHeading.length;
        expect(h.lineCount(0, at, end), greaterThan(1), reason: 'it wraps');

        h.request(_wi66Req(h, at));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, at), closeTo(16, _wi66Px));
        expect(
          _wi66FromTop(h, end - 1),
          greaterThan(16 + 1),
          reason: 'the last visual line sits lower',
        );
      },
    );

    testWidgets(
      'a text request with an end anchors on the line boxes holding the range',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final start = _wi66Line(h, 300);
        final end = _wi66Line(h, 303);
        final height = h.linesOf(0, start, end).height;
        expect(
          height,
          greaterThan(h.lineBoxOf(0, start).height * 2),
          reason: 'three lines',
        );

        h.request(_wi66Req(h, start, end: end, placement: const RevealThird()));
        await pumpFrames(tester);

        final vh = h.position().viewportDimension;
        expect(
          h.linesOf(0, start, end).top - h.viewport().top,
          closeTo(vh / 3 - height / 2, _wi66Px),
        );
      },
    );

    testWidgets(
      'a text request with an end in a prose row that starts after the segment start anchors on the line boxes holding the range',
      (tester) async {
        final h = await _wi66PumpRows(tester);
        final start = h.offsetOf('after bullet 40\n');
        final end = h.offsetOf('after bullet 43\n');
        final spec = h.rowOf(0, start).spec;
        // The prose row after the bullet row starts well past offset 0, so a
        // segment offset used as a row offset would land far past the range.
        expect(spec.start, greaterThan(end - start));
        expect(h.rowOf(0, end).spec.start, spec.start, reason: 'one row');
        final height = h.linesOf(0, start, end).height;
        expect(
          height,
          greaterThan(h.lineBoxOf(0, start).height * 2),
          reason: 'three lines',
        );

        h.request(
          NoteRevealRequest(
            fixtureTopicId,
            h.textAt(start, end: end),
            const RevealThird(),
          ),
        );
        await pumpFrames(tester);

        final vh = h.position().viewportDimension;
        final lines = h.linesOf(0, start, end);
        expect(lines.height, closeTo(height, _wi66Px));
        expect(
          lines.top - h.viewport().top,
          closeTo(vh / 3 - height / 2, _wi66Px),
          reason: 'the anchor is the three lines, not the rest of the row',
        );
      },
    );

    testWidgets('a text request flashes the echoArrivalRects band of its row', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final mid = h.offsetOf(revealMidHeading);

      h.request(_wi66Req(h, mid, flash: true));
      expect(await _wi66UntilHighlight(tester), isTrue);
      await tester.pump();

      final shown = tester.widget<EchoArrivalHighlight>(h.highlight);
      final row = _wi66RowBox(h, 0, 0);
      final expected = echoArrivalRects(
        row,
        _wi66Echo(h, mid),
        column: _wi66Column(h, 0),
      );
      expect(shown.target, same(row));
      expect(shown.band, expected.band);
      expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));
    });

    testWidgets('a text request in a bullet row anchors on the whole row', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester, open: revealItemsId);
      final at = h.offsetOf('item 150\n');
      final line = h.lineBoxOf(0, at);
      final whole = h.rowRectOf(0, at);
      expect(
        (whole.top - line.top).abs(),
        greaterThan(5 * _wi66Px),
        reason: 'the row and its line box start apart',
      );

      h.request(_wi66Req(h, at, noteId: revealItemsId));
      await pumpFrames(tester);

      expect(h.rowRectOf(0, at).top - h.viewport().top, closeTo(16, _wi66Px));
    });

    testWidgets('a text request in a table anchors on the whole table row', (
      tester,
    ) async {
      final h = await _wi66PumpRows(tester);
      final at = h.offsetOf('| 3 | 4 |');
      expect(
        find.byKey(ValueKey('editor-table-0-${h.rowOf(0, at).index}')),
        findsOneWidget,
      );

      h.request(_wi66Req(h, at + 2, noteId: fixtureTopicId));
      await pumpFrames(tester);

      expect(h.rowRectOf(0, at).top - h.viewport().top, closeTo(16, _wi66Px));
    });

    testWidgets('a card request anchors on the whole excerpt card', (
      tester,
    ) async {
      final h = await _wi66PumpRows(tester);
      expect(find.byKey(const Key('excerpt-card-1')), findsOneWidget);

      h.request(
        NoteRevealRequest(
          fixtureTopicId,
          RevealAtCard(segment: 1, content: h.shownContent()),
          _wi66Top16,
        ),
      );
      await pumpFrames(tester);

      expect(h.rowRectOf(1, 0).top - h.viewport().top, closeTo(16, _wi66Px));
    });

    testWidgets(
      'a text request in a daily note lands on stray text past the shared prefix',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealDailyId);
        final at = h.offsetOf(revealStrayHeading);
        expect(
          h.shownContent().indexOf(revealStrayHeading),
          isNot(at),
          reason: 'the stray heading is not at its body offset',
        );
        await h.scrollTo(0);

        h.request(_wi66Req(h, at, noteId: revealDailyId));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, at), closeTo(16, _wi66Px));
      },
    );
  });

  group('byte anchors', () {
    testWidgets('a byte request lands exactly where an echo arrival lands', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester, open: revealOtherId);
      final byte = utf16ToUtf8(
        revealItemsBody,
        revealItemsBody.indexOf('  passage 150\n') + 2,
      );

      // The echo: target, then follow (echoes_tab.dart, unchanged).
      h
          .read(echoScrollTargetProvider.notifier)
          .set(EchoScrollTarget(revealItemsId, byte));
      h.tabs.follow(const NoteTab(revealItemsId));
      expect(await _wi66UntilHighlight(tester), isTrue);
      await pumpFrames(tester);
      final echoPixels = h.pixels();
      final echoBand = tester.widget<EchoArrivalHighlight>(h.highlight).band;
      expect(echoPixels, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1300));
      await h.scrollTo(0);

      h.request(
        NoteRevealRequest(
          revealItemsId,
          RevealAtByte(byte),
          const RevealThird(),
          flash: true,
        ),
      );
      expect(await _wi66UntilHighlight(tester), isTrue);
      await pumpFrames(tester);

      expect(h.pixels(), echoPixels);
      expect(tester.widget<EchoArrivalHighlight>(h.highlight).band, echoBand);
    });

    testWidgets(
      'a byte request with a top placement anchors on the echo arrival rects anchor',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealItemsId);
        final at = h.offsetOf('  passage 150\n') + 2;
        final row = h.rowOf(0, at).index;

        h.request(
          NoteRevealRequest(
            revealItemsId,
            RevealAtByte(utf16ToUtf8(h.shownContent(), at)),
            _wi66Top16,
          ),
        );
        await pumpFrames(tester);

        final box = _wi66RowBox(h, 0, row);
        final anchor = echoArrivalRects(
          box,
          _wi66Echo(h, at),
          column: _wi66Column(h, 0),
        ).anchor;
        expect(
          box.localToGlobal(anchor.topLeft).dy - h.viewport().top,
          closeTo(16, _wi66Px),
        );
      },
    );
  });

  // ------------------------------------------------------------------ D3d
  group('placements', () {
    testWidgets(
      'RevealTop puts the anchor top 16 px below the viewport top even when it is already in view',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = _wi66Line(h, 200);
        await h.scrollContent(h.lineTopOf(0, at), h.viewport().top + 100);
        expect(_wi66FromTop(h, at), closeTo(100, _wi66Px));

        h.request(_wi66Req(h, at));
        await pumpFrames(tester);

        expect(
          _wi66FromTop(h, at),
          closeTo(16, _wi66Px),
          reason: 'always jumps',
        );
      },
    );

    testWidgets('RevealTop scrolls up to an anchor above the viewport', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(3000);
      final at = _wi66Line(h, 10);
      expect(_wi66FromTop(h, at), lessThan(0));

      h.request(_wi66Req(h, at));
      await pumpFrames(tester);

      expect(_wi66FromTop(h, at), closeTo(16, _wi66Px));
    });

    testWidgets(
      'RevealTop near the end of the note clamps to the max scroll extent',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = h.offsetOf(revealEndHeading);

        h.request(_wi66Req(h, at));
        await pumpFrames(tester);

        expect(h.pixels(), h.position().maxScrollExtent);
        expect(_wi66FromTop(h, at), greaterThan(16 + 1));
      },
    );

    testWidgets('RevealTop clamps to the start of the scroll extent', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);

      h.request(_wi66Req(h, _wi66Line(h, 1), placement: const RevealTop(500)));
      await pumpFrames(tester);

      expect(h.pixels(), 0.0);
    });

    testWidgets('RevealWithin does not scroll an anchor inside the band', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final at = _wi66Line(h, 200);
      await h.scrollContent(h.lineTopOf(0, at), h.viewport().top + 200);
      final pixels = h.pixels();

      h.request(_wi66Req(h, at, placement: _wi66Within60));
      await _wi66ExpectStill(tester, h, pixels);
      expect(h.pending, isNull, reason: 'taken');

      // Control: below the viewport it scrolls.
      final below = _wi66Line(h, 330);
      h.request(_wi66Req(h, below, placement: _wi66Within60));
      await pumpFrames(tester);
      expect(
        h.lineBoxOf(0, below).bottom,
        closeTo(h.viewport().bottom, _wi66Px),
      );
    });

    testWidgets(
      'RevealWithin keeps an anchor exactly at top plus inset and scrolls one 1 px above it',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = _wi66Line(h, 200);
        await h.scrollContent(h.lineTopOf(0, at), h.viewport().top + 60);
        expect(h.lineTopOf(0, at), h.viewport().top + 60, reason: 'the edge');
        final pixels = h.pixels();

        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await _wi66ExpectStill(tester, h, pixels);

        await h.scrollContent(h.lineTopOf(0, at), h.viewport().top + 59);
        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await pumpFrames(tester);
        expect(_wi66FromTop(h, at), closeTo(60, _wi66Px));
      },
    );

    testWidgets(
      'RevealWithin keeps an anchor whose bottom is exactly at the viewport bottom and scrolls one 1 px below it',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = _wi66Line(h, 200);
        await h.scrollContent(h.lineBoxOf(0, at).bottom, h.viewport().bottom);
        expect(h.lineBoxOf(0, at).bottom, h.viewport().bottom);
        final pixels = h.pixels();

        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await _wi66ExpectStill(tester, h, pixels);

        await h.scrollContent(
          h.lineBoxOf(0, at).bottom,
          h.viewport().bottom + 1,
        );
        final displaced = h.pixels();
        expect(displaced, closeTo(pixels - 1, _wi66Px), reason: 'moved 1 px');
        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await pumpFrames(tester);
        expect(
          h.lineBoxOf(0, at).bottom,
          closeTo(h.viewport().bottom, _wi66Px),
        );
        expect(
          h.pixels(),
          closeTo(displaced + 1, _wi66Px),
          reason: 'scrolled by 1 px, back to the bottom edge',
        );
      },
    );

    testWidgets(
      'RevealWithin scrolls the smallest distance to bring an anchor below the viewport into the band',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = _wi66Line(h, 250);
        expect(h.lineTopOf(0, at), greaterThan(h.viewport().bottom));

        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await pumpFrames(tester);

        expect(
          h.lineBoxOf(0, at).bottom,
          closeTo(h.viewport().bottom, _wi66Px),
        );
      },
    );

    testWidgets(
      'RevealWithin scrolls the smallest distance to bring an anchor above the viewport into the band',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(3000);
        final at = _wi66Line(h, 100);
        expect(_wi66FromTop(h, at), lessThan(0));

        h.request(_wi66Req(h, at, placement: _wi66Within60));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, at), closeTo(60, _wi66Px));
      },
    );

    testWidgets(
      'RevealWithin lands an anchor taller than the band at top plus inset',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final start = _wi66Line(h, 100);
        final end = _wi66Line(h, 250);
        expect(
          h.linesOf(0, start, end).height,
          greaterThan(h.viewport().height - 60),
        );
        await h.scrollContent(h.lineTopOf(0, start), h.viewport().top + 100);

        h.request(_wi66Req(h, start, end: end, placement: _wi66Within60));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, start), closeTo(60, _wi66Px));
      },
    );

    testWidgets(
      'RevealThird puts the anchor centre a third of the way down the viewport',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final at = _wi66Line(h, 200);
        final height = h.lineBoxOf(0, at).height;

        h.request(_wi66Req(h, at, placement: const RevealThird()));
        await pumpFrames(tester);

        final vh = h.position().viewportDimension;
        expect(_wi66FromTop(h, at), closeTo(vh / 3 - height / 2, _wi66Px));
      },
    );

    testWidgets(
      'RevealThird puts an anchor taller than two thirds of the viewport at the viewport top',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final start = _wi66Line(h, 100);
        final end = _wi66Line(h, 250);
        expect(
          h.linesOf(0, start, end).height,
          greaterThan(h.position().viewportDimension * 2 / 3),
        );

        h.request(_wi66Req(h, start, end: end, placement: const RevealThird()));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, start), closeTo(0, _wi66Px));
      },
    );
  });

  // ------------------------------------------------------------------ D3e
  group('after a landing', () {
    testWidgets(
      'a landing records its offset and later user scrolls are reported',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final mid = h.offsetOf(revealMidHeading);

        h.request(_wi66Req(h, mid));
        await pumpFrames(tester);

        final landed = h.pixels();
        expect(landed, greaterThan(0));
        expect(h.recorded.last, (noteId: revealLongId, offset: landed));
        await h.scrollTo(landed + 50);
        expect(h.recorded.last, (noteId: revealLongId, offset: landed + 50));
        await h.scrollTo(landed);

        // The entry holds the landing: Back then Forward returns to it.
        await h.navigate(const NoteTab(revealOtherId));
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), landed);
      },
    );

    testWidgets(
      'a landing leaves the selection the focus and the tabs history unchanged',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);
        await h.navigate(const NoteTab(revealLongId));
        await pumpFrames(tester);
        final caret = _wi66Line(h, 3) + 2;
        editorBodySegment(
          tester,
        ).select(TextSelection.collapsed(offset: caret));
        await pumpFrames(tester);
        final focus = FocusManager.instance.primaryFocus;
        expect(focus, isNotNull);
        final before = h.tabState;
        final selection = editorBodySegment(tester).selection;
        expect(selection, TextSelection.collapsed(offset: caret));
        final mid = h.offsetOf(revealMidHeading);

        h.request(_wi66Req(h, mid, flash: true));
        await pumpFrames(tester);

        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px), reason: 'it landed');
        expect(editorBodySegment(tester).selection, selection);
        expect(FocusManager.instance.primaryFocus, same(focus));
        final after = h.tabState;
        expect(after.tabs, before.tabs);
        expect(after.activeIndex, before.activeIndex);
        expect(after.arrivals, before.arrivals);
        expect(after.canGoBack, isTrue);
        expect(after.canGoBack, before.canGoBack);
        expect(after.canGoForward, before.canGoForward);
      },
    );

    testWidgets('a landing does not take focus when the editor body has none', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      expect(editorBodySegment(tester).focusedRow, isNull);
      final mid = h.offsetOf(revealMidHeading);

      h.request(_wi66Req(h, mid, flash: true));
      await pumpFrames(tester);

      expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px), reason: 'it landed');
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(editorBodySegment(tester).focusedRow, isNull);
    });
  });

  // ------------------------------------------------------------------ D3f
  group('not found', () {
    testWidgets('a byte request with a null start lands at the top', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);

      h.request(
        const NoteRevealRequest(
          revealLongId,
          RevealAtByte(null),
          RevealThird(),
        ),
      );
      await pumpFrames(tester);

      expect(h.pixels(), 0.0);
      expect(h.pending, isNull);
    });

    testWidgets('an unlocatable byte request does nothing on the shown note', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);

      h.request(
        const NoteRevealRequest(
          revealLongId,
          RevealAtByte(10000000),
          RevealThird(),
          flash: true,
        ),
      );
      await _wi66ExpectStill(tester, h, 1500);
      expect(h.pending, isNull);

      await _wi66ExpectControlLands(tester, h);
    });

    testWidgets('an unlocatable byte request lands at the top on arrival', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      await h.navigate(const NoteTab(revealOtherId));

      // Back would restore 1500.
      h.tabs.back();
      h.request(
        const NoteRevealRequest(
          revealLongId,
          RevealAtByte(10000000),
          RevealThird(),
          flash: true,
        ),
      );
      await pumpFrames(tester);
      await pumpFrames(tester);

      expect(h.body().note.id, revealLongId);
      expect(h.pixels(), 0.0);
      expect(h.highlight, findsNothing);
      expect(h.pending, isNull);
    });

    testWidgets('an unlocatable text request lands at the top on arrival', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      await h.navigate(const NoteTab(revealOtherId));
      final content = revealLongBody;

      // Back would restore 1500.
      h.tabs.back();
      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtText(segment: 4, start: 0, content: content),
          _wi66Top16,
          flash: true,
        ),
      );
      await pumpFrames(tester);
      await pumpFrames(tester);

      expect(h.body().note.id, revealLongId);
      expect(h.pixels(), 0.0);
      expect(h.highlight, findsNothing);
      expect(h.pending, isNull);
      await _wi66ExpectReportsResume(h);
    });

    testWidgets('an unlocatable card request lands at the top on arrival', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      await h.navigate(const NoteTab(revealOtherId));

      h.tabs.back();
      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtCard(segment: 0, content: revealLongBody),
          _wi66Top16,
          flash: true,
        ),
      );
      await pumpFrames(tester);
      await pumpFrames(tester);

      expect(h.body().note.id, revealLongId);
      expect(h.pixels(), 0.0);
      expect(h.highlight, findsNothing);
      expect(h.pending, isNull);
      await _wi66ExpectReportsResume(h);
    });

    testWidgets(
      'a text request whose content differs from the text shown lands at the top on arrival',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(1500);
        await h.navigate(const NoteTab(revealOtherId));

        h.tabs.back();
        h.request(
          NoteRevealRequest(
            revealLongId,
            RevealAtText(
              segment: 0,
              start: _wi66StoredMid,
              content: '${revealLongBody}stale',
            ),
            _wi66Top16,
            flash: true,
          ),
        );
        for (var i = 0; i < 8; i++) {
          await pumpFrames(tester);
        }

        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), 0.0);
        expect(h.highlight, findsNothing);
        expect(h.pending, isNull);
        await _wi66ExpectReportsResume(h);
      },
    );

    // The same arrivals on the note already shown (a focused second tab): the
    // arrival's restore runs before the request is made (D3b: a request made
    // before an arrival dies at it), so the request reaches a note that is
    // shown and does nothing. The restore, 700, differs from the top and from
    // the editor's own scroll, 1500, so what the page keeps is observable.
    for (final (name, at) in <(String, RevealAt Function())>[
      (
        'an unlocatable text request after a same note arrival keeps the restored scroll',
        () => RevealAtText(segment: 4, start: 0, content: revealLongBody),
      ),
      (
        'an unlocatable card request after a same note arrival keeps the restored scroll',
        () => RevealAtCard(segment: 0, content: revealLongBody),
      ),
      (
        'a stale text request after a same note arrival keeps the restored scroll',
        () => RevealAtText(
          segment: 0,
          start: _wi66StoredMid,
          content: '${revealLongBody}stale',
        ),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(700);
        h.tabs.openOrFocus(const NoteTab(revealOtherId));
        await pumpFrames(tester);
        await h.navigate(const NoteTab(revealLongId));
        expect(h.tabState.activeIndex, 1);
        await h.scrollTo(1500);

        h.tabs.openOrFocus(const NoteTab(revealLongId));
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 0);
        expect(h.pixels(), 700.0, reason: 'the arrival restored tab 0');
        h.request(
          NoteRevealRequest(revealLongId, at(), _wi66Top16, flash: true),
        );
        for (var i = 0; i < 8; i++) {
          await pumpFrames(tester);
        }

        expect(h.pixels(), 700.0, reason: 'the request did nothing');
        expect(h.highlight, findsNothing);
        expect(h.pending, isNull);
        await h.scrollTo(900);
        expect(h.recorded.last, (
          noteId: revealLongId,
          offset: 900.0,
        ), reason: 'the scroll after the request is recorded');

        await _wi66ExpectControlLands(tester, h);
      });
    }

    testWidgets('an unlocatable text request does nothing', (tester) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      final content = h.shownContent();

      for (final at in [
        RevealAtText(segment: 0, start: content.length + 40, content: content),
        RevealAtText(segment: 4, start: 0, content: content),
      ]) {
        h.request(NoteRevealRequest(revealLongId, at, _wi66Top16, flash: true));
        await _wi66ExpectStill(tester, h, 1500);
        expect(h.pending, isNull);
      }

      await _wi66ExpectControlLands(tester, h);
    });

    testWidgets('an unlocatable card request does nothing', (tester) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      final content = h.shownContent();

      for (final segment in [0, 3]) {
        h.request(
          NoteRevealRequest(
            revealLongId,
            RevealAtCard(segment: segment, content: content),
            _wi66Top16,
            flash: true,
          ),
        );
        await _wi66ExpectStill(tester, h, 1500);
        expect(h.pending, isNull);
      }

      await _wi66ExpectControlLands(tester, h);
    });

    testWidgets(
      'a text request whose content still differs from the shown text after 8 frames does nothing',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.scrollTo(1500);
        final mid = h.offsetOf(revealMidHeading);

        h.request(
          NoteRevealRequest(
            revealLongId,
            RevealAtText(
              segment: 0,
              start: mid,
              content: '${h.shownContent()}stale',
            ),
            _wi66Top16,
            flash: true,
          ),
        );
        await _wi66ExpectStill(tester, h, 1500, frames: 16);
        expect(h.pending, isNull);

        await _wi66ExpectControlLands(tester, h);
      },
    );
  });

  // ----------------------------------------------- arrival landings still due
  group('arrival landings still due', () {
    /// Back onto the long note (restore 1500 due) with a hydrate-time request
    /// whose text is not the text shown: its landing retries for 8 frames,
    /// then gives up and opens at the top. Pumps the hydrate frame only.
    Future<NoteRevealHarness> retryingArrival(WidgetTester tester) async {
      final h = await pumpNoteReveal(tester);
      await h.scrollTo(1500);
      await h.navigate(const NoteTab(revealOtherId));
      h.tabs.back();
      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtText(
            segment: 0,
            start: _wi66StoredMid,
            content: '${revealLongBody}stale',
          ),
          _wi66Top16,
          flash: true,
        ),
      );
      // Frame by frame until the long note shows: the landing retries from
      // there.
      for (var i = 0; i < 10 && h.pending != null; i++) {
        await tester.pump();
      }
      expect(h.body().note.id, revealLongId, reason: 'the arrival hydrated');
      expect(h.pending, isNull, reason: 'the arrival took its request');
      return h;
    }

    testWidgets(
      'a shown note request that gives up leaves a retrying arrival landing to finish and release the reports',
      (tester) async {
        final h = await retryingArrival(tester);
        final mid = h.offsetOf(revealMidHeading);

        // A request for the note shown while the arrival still retries; its
        // text is not shown either, so it gives up after its own 8 frames.
        h.request(
          NoteRevealRequest(
            revealLongId,
            RevealAtText(
              segment: 0,
              start: mid,
              content: '${h.shownContent()}stale',
            ),
            _wi66Top16,
          ),
        );
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(h.pending, isNull);
        expect(h.pixels(), 0.0, reason: 'the arrival opened at the top');
        expect(h.highlight, findsNothing);
        await _wi66ExpectReportsResume(h);
        await _wi66ExpectControlLands(tester, h);
      },
    );

    testWidgets(
      'a shown note request that lands cancels an arrival landing still retrying',
      (tester) async {
        final h = await retryingArrival(tester);
        final mid = h.offsetOf(revealMidHeading);
        final jumps = h.jumps();

        h.request(_wi66Req(h, mid));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px), reason: 'landed');
        final landed = h.pixels();
        expect(jumps.count, 1);

        // The arrival's 8 frames run out; it must not jump to the top.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(h.pixels(), landed, reason: 'the arrival gave way');
        expect(jumps.count, 1, reason: 'no second jump: ${jumps.values}');
        expect(h.recorded.last, (noteId: revealLongId, offset: landed));
        await h.scrollTo(landed + 50);
        expect(h.recorded.last, (noteId: revealLongId, offset: landed + 50));
      },
    );
  });

  // ------------------------------------------------------------------ D3g
  group('Source mode', () {
    testWidgets(
      'a leaveSource request in Source mode switches to live preview and then lands',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await h.toggleSource();
        expect(h.sourceSurface, findsOneWidget);

        h.request(_wi66Stored(_wi66StoredMid, flash: true, leaveSource: true));
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(h.sourceSurface, findsNothing);
        expect(find.byType(SegmentedBody), findsOneWidget);
        expect(_wi66FromTop(h, _wi66StoredMid), closeTo(16, _wi66Px));
        expect(h.pending, isNull);
      },
    );

    testWidgets('a request without leaveSource in Source mode is dropped', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      await h.toggleSource();

      h.request(_wi66Stored(_wi66StoredMid, flash: true));
      await pumpFrames(tester);

      expect(h.sourceSurface, findsOneWidget, reason: 'stays in Source');
      expect(h.pending, isNull, reason: 'dropped');
      await h.toggleSource();
      await _wi66ExpectStill(tester, h, h.pixels());
      expect(_wi66FromTop(h, _wi66StoredMid), isNot(closeTo(16, 1)));

      await _wi66ExpectControlLands(tester, h);
    });
  });

  // ------------------------------------------------------------------ D3h
  group('revealAnchorRect', () {
    testWidgets(
      'revealAnchorRect returns the anchor rect the text landing uses',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final mid = h.offsetOf(revealMidHeading);
        h.request(_wi66Req(h, mid));
        await pumpFrames(tester);
        expect(_wi66FromTop(h, mid), closeTo(16, _wi66Px));

        final row = _wi66RowBox(h, 0, 0);
        final rect = revealAnchorRect(row, _wi66Echo(h, mid));

        final line = h.lineBoxOf(0, mid);
        expect(
          row.localToGlobal(rect.topLeft).dy - h.viewport().top,
          closeTo(16, _wi66Px),
        );
        expect(rect.height, closeTo(line.height, _wi66Px));
      },
    );

    testWidgets('revealAnchorRect takes the real top of a row first line', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final row = _wi66RowBox(h, 0, 0);
      final arrival = _wi66Echo(h, 0);
      final line = h.lineBoxOf(0, 0);
      final echoTop = row
          .localToGlobal(
            echoArrivalRects(
              row,
              arrival,
              column: _wi66Column(h, 0),
            ).anchor.topLeft,
          )
          .dy;
      expect(
        (echoTop - line.top).abs(),
        greaterThan(_wi66Px),
        reason: 'the echo anchor starts at the row top, not the line top',
      );

      final rect = revealAnchorRect(row, arrival);

      expect(row.localToGlobal(rect.topLeft).dy, closeTo(line.top, _wi66Px));
      expect(
        row.localToGlobal(rect.bottomLeft).dy,
        closeTo(line.bottom, _wi66Px),
      );
    });

    testWidgets(
      'revealAnchorRect with an end spans the line boxes holding the range',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final start = _wi66Line(h, 50);
        final end = _wi66Line(h, 53);
        final row = _wi66RowBox(h, 0, 0);
        final spec = h.rowOf(0, start).spec;

        final rect = revealAnchorRect(
          row,
          _wi66Echo(h, start),
          end: spec.toLocal(end),
        );

        final lines = h.linesOf(0, start, end);
        expect(row.localToGlobal(rect.topLeft).dy, closeTo(lines.top, _wi66Px));
        expect(
          row.localToGlobal(rect.bottomLeft).dy,
          closeTo(lines.bottom, _wi66Px),
        );
        expect(
          h.lineBoxOf(0, end).bottom,
          greaterThan(lines.bottom),
          reason: 'line 53 is not part of it',
        );
      },
    );

    testWidgets(
      'revealAnchorRect with an end in a prose row that starts after the segment start spans the line boxes holding the range',
      (tester) async {
        final h = await _wi66PumpRows(tester);
        final start = h.offsetOf('after bullet 40\n');
        final end = h.offsetOf('after bullet 43\n');
        final index = h.rowOf(0, start).index;
        final spec = h.rowOf(0, start).spec;
        expect(spec.start, greaterThan(0));
        final row = _wi66RowBox(h, 0, index);
        final arrival = locateInSegment(
          h.shownContent(),
          0,
          start,
          role: h.body().note.role,
        );
        expect(arrival, isNotNull);

        final rect = revealAnchorRect(row, arrival!, end: spec.toLocal(end));

        final lines = h.linesOf(0, start, end);
        expect(row.localToGlobal(rect.topLeft).dy, closeTo(lines.top, _wi66Px));
        expect(
          row.localToGlobal(rect.bottomLeft).dy,
          closeTo(lines.bottom, _wi66Px),
        );
      },
    );

    testWidgets(
      'revealAnchorRect with an empty or inverted range is the first line only',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final start = _wi66Line(h, 50);
        final row = _wi66RowBox(h, 0, 0);
        final spec = h.rowOf(0, start).spec;
        final line = h.lineBoxOf(0, start);

        for (final end in [spec.toLocal(start), spec.toLocal(start) - 6]) {
          final rect = revealAnchorRect(row, _wi66Echo(h, start), end: end);

          expect(
            row.localToGlobal(rect.topLeft).dy,
            closeTo(line.top, _wi66Px),
            reason: 'end $end',
          );
          expect(
            rect.height,
            closeTo(line.height, _wi66Px),
            reason: 'end $end',
          );
        }
      },
    );

    testWidgets('revealAnchorRect of a bullet row is the whole row', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester, open: revealItemsId);
      final at = h.offsetOf('item 10\n');
      final row = _wi66RowBox(h, 0, h.rowOf(0, at).index);

      final rect = revealAnchorRect(row, _wi66Echo(h, at));

      expect(rect, Offset.zero & row.size);
    });
  });

  // ------------------------------------------------------------------ D6
  group('editor slots', () {
    /// The nearest Positioned above [body] and the Stack holding it.
    (Positioned, Stack) slot(WidgetTester tester, Finder body) {
      final positioned = find.ancestor(
        of: body,
        matching: find.byWidgetPredicate((w) => w is Positioned),
      );
      expect(positioned, findsWidgets, reason: 'the body sits in a Stack');
      final element = positioned.evaluate().first;
      Stack? stack;
      element.visitAncestorElements((e) {
        if (e.widget is Stack) {
          stack = e.widget as Stack;
          return false;
        }
        return true;
      });
      expect(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byWidget(stack!),
        ),
        findsOneWidget,
        reason: 'inside the editor',
      );
      return (element.widget as Positioned, stack!);
    }

    testWidgets(
      'the editor body sits in a stack under its overlays slot with no overlays',
      (tester) async {
        final h = await pumpNoteReveal(tester);

        for (final body in [
          find.byType(SegmentedBody),
          find.byKey(const Key('editor-source-surface')),
        ]) {
          final (positioned, stack) = slot(tester, body);
          expect(
            [
              positioned.left,
              positioned.top,
              positioned.right,
              positioned.bottom,
            ],
            [0.0, 0.0, 0.0, 0.0],
            reason: 'Positioned.fill',
          );
          // The body is the first child; overlays (#61) stack above it.
          expect(stack.children.first, same(positioned));
          if (h.sourceSurface.evaluate().isEmpty) await h.toggleSource();
        }
      },
    );

    test(
      'note_editor.dart declares the body overlays and track sections stubs',
      () {
        final source = File(
          'lib/src/widgets/note_editor.dart',
        ).readAsStringSync();

        // The stubs' bodies are not pinned: #61 fills `_bodyOverlays` and
        // #58 fills `_trackSections` later. Their declarations and call
        // sites are the seam.
        expect(
          RegExp(r'List<Widget>\s+_bodyOverlays\(Note note\)').hasMatch(source),
          isTrue,
          reason: '_bodyOverlays is declared',
        );
        expect(
          RegExp(
            r'Widget\s+_trackSections\(Note note,\s*Widget body\)',
          ).hasMatch(source),
          isTrue,
          reason: '_trackSections is declared',
        );
        expect(
          RegExp(r'_trackSections\(').allMatches(source).length,
          greaterThanOrEqualTo(2),
          reason: 'the segmented body goes through it',
        );
        expect(RegExp(r'Positioned\.fill\(').hasMatch(source), isTrue);
        expect(RegExp(r'\.\.\._bodyOverlays\(note\)').hasMatch(source), isTrue);
      },
    );

    test(
      'note_editor.dart no longer holds the echo landing and its row lookup',
      () {
        final source = File(
          'lib/src/widgets/note_editor.dart',
        ).readAsStringSync();

        expect(source, isNot(contains('_landAtEcho')));
        expect(source, isNot(contains('_echoRow')));
        expect(source, contains('_reveal('));
      },
    );
  });
}
