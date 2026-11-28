// #66 (54-R0, ruling D4): a count per path of the one-shot reveal. Jumps are
// counted with a listener on the editor's scroll controller (`RevealJumps`: a
// `jumpTo` that moves the page counts once), `recordScrollOffset` through the
// recording tabs double (`RevealTabs`), highlights as distinct
// `EchoArrivalHighlight` states. Every counted landing starts away from its
// target, so it moves the page. Zero counts end with a control request that
// lands, so they cannot pass on a seam that never lands anything.
//
// Callers navigate first and request second (D3b).
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';

import '../support/canvas_seeds.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/note_reveal_pump.dart';

const _wi66cTop16 = RevealTop(16);

/// Line tops sit on half pixels: the editor's geometry is exact to this.
const _wi66cPx = 0.01;

int get _wi66cMid => revealLongBody.indexOf(revealMidHeading);

/// A request for the long note's mid heading, from its stored text.
NoteRevealRequest _wi66cMidRequest({
  String noteId = revealLongId,
  RevealPlacement placement = _wi66cTop16,
  bool flash = false,
}) => NoteRevealRequest(
  noteId,
  RevealAtText(segment: 0, start: _wi66cMid, content: revealLongBody),
  placement,
  flash: flash,
);

/// Pumps [frames] zero-length frames, then 50 ms ones; returns how many
/// distinct arrival highlights showed meanwhile.
Future<int> _wi66cPumpCountingHighlights(
  WidgetTester tester, {
  int frames = 10,
}) async {
  final seen = <State>{};
  void look() {
    for (final e in find.byType(EchoArrivalHighlight).evaluate()) {
      seen.add((e as StatefulElement).state);
    }
  }

  for (var i = 0; i < frames; i++) {
    await tester.pump();
    look();
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    look();
  }
  return seen.length;
}

double _wi66cFromTop(NoteRevealHarness h, int local, {Finder? under}) =>
    h.lineTopOf(0, local, under: under) - h.viewport(under: under).top;

/// Control after a zero count: a valid request on the shown long note lands
/// with exactly one jump.
Future<void> _wi66cExpectControl(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  final jumps = h.jumps();
  h.request(_wi66cMidRequest());
  await pumpFrames(tester);
  expect(jumps.count, 1, reason: 'control: a valid request lands once');
  expect(_wi66cFromTop(h, _wi66cMid), closeTo(16, _wi66cPx));
}

void main() {
  holdFontFetches();

  group('D4 call counts', () {
    testWidgets(
      'one flash request on the shown note gives one jump one recorded offset and one highlight',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        expect(h.shownContent(), revealLongBody);
        final jumps = h.jumps();
        final recorded = h.recorded.length;

        h.request(_wi66cMidRequest(flash: true));
        final highlights = await _wi66cPumpCountingHighlights(tester);

        expect(jumps.count, 1, reason: 'jumps: ${jumps.values}');
        expect(h.recorded.length - recorded, 1, reason: '${h.recorded}');
        expect(h.recorded.last, (noteId: revealLongId, offset: h.pixels()));
        expect(highlights, 1);
        expect(h.highlight, findsOneWidget);
      },
    );

    testWidgets(
      'one request without flash on the shown note gives one jump one recorded offset and no highlight',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final jumps = h.jumps();
        final recorded = h.recorded.length;

        h.request(_wi66cMidRequest());
        final highlights = await _wi66cPumpCountingHighlights(tester);

        expect(jumps.count, 1, reason: 'jumps: ${jumps.values}');
        expect(h.recorded.length - recorded, 1, reason: '${h.recorded}');
        expect(highlights, 0);
      },
    );

    testWidgets(
      'a request for another note then navigating there gives no jump in the old editor and one in the new',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);
        final controller = h.controller();
        final events = <(String, double)>[];
        void moved() => events.add((h.body().note.id, controller.offset));
        controller.addListener(moved);
        addTearDown(() => controller.removeListener(moved));

        // A request for a note the editor does not show: nothing happens
        // there (R21), and it dies at the next arrival (D3b).
        h.request(_wi66cMidRequest(flash: true));
        expect(await _wi66cPumpCountingHighlights(tester), 0);
        expect(events, isEmpty, reason: 'the old editor does not jump');

        h.tabs.navigate(const NoteTab(revealLongId));
        h.request(_wi66cMidRequest(flash: true));
        final highlights = await _wi66cPumpCountingHighlights(tester);
        await pumpFrames(tester);

        expect(events, hasLength(1), reason: 'one jump: $events');
        expect(events.single.$1, revealLongId, reason: 'in the new note');
        expect(highlights, 1);
        expect(_wi66cFromTop(h, _wi66cMid), closeTo(16, _wi66cPx));
      },
    );

    testWidgets(
      'a request then an unrelated arrival without navigating to its note then a visit gives no jump',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);

        h.request(_wi66cMidRequest(flash: true));
        // An arrival elsewhere: the graph, so no editor is there to take it.
        await h.navigate(GraphTab(const GraphScope.vault()));
        await pumpFrames(tester);
        await h.navigate(const NoteTab(revealLongId));
        expect(await _wi66cPumpCountingHighlights(tester), 0);
        await pumpFrames(tester);

        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), 0.0, reason: 'no jump: the visit lands on top');
        await _wi66cExpectControl(tester, h);
      },
    );

    testWidgets(
      'a request then an unrelated note arrival then a visit gives no jump',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealOtherId);

        h.request(_wi66cMidRequest(flash: true));
        await h.navigate(const NoteTab(revealItemsId));
        await pumpFrames(tester);
        await h.navigate(const NoteTab(revealLongId));
        expect(await _wi66cPumpCountingHighlights(tester), 0);
        await pumpFrames(tester);

        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), 0.0, reason: 'no jump: the visit lands on top');
        await _wi66cExpectControl(tester, h);
      },
    );

    testWidgets('two equal requests in a row give two jumps', (tester) async {
      final h = await pumpNoteReveal(tester);
      expect(h.shownContent(), revealLongBody);
      final r = _wi66cMidRequest(flash: true);
      final jumps = h.jumps();
      final recorded = h.recorded.length;

      h.request(r);
      await pumpFrames(tester);
      expect(jumps.count, 1);
      expect(h.recorded.length - recorded, 1);
      final landed = h.pixels();
      await tester.pump(const Duration(milliseconds: 1300));
      await h.scrollTo(0);
      jumps.clear();
      final second = h.recorded.length;

      h.request(r);
      final highlights = await _wi66cPumpCountingHighlights(tester);

      expect(jumps.count, 1, reason: 'the equal request lands again');
      expect(h.recorded.length - second, 1);
      expect(h.pixels(), landed);
      expect(highlights, 1);
    });

    testWidgets('two requests in the same frame land only the later one', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final jumps = h.jumps();
      final early = revealLongBody.indexOf('line 300\n');

      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtText(segment: 0, start: early, content: revealLongBody),
          _wi66cTop16,
          flash: true,
        ),
      );
      h.request(_wi66cMidRequest(flash: true));
      final highlights = await _wi66cPumpCountingHighlights(tester);

      expect(jumps.count, 1, reason: 'jumps: ${jumps.values}');
      expect(highlights, 1);
      expect(_wi66cFromTop(h, _wi66cMid), closeTo(16, _wi66cPx));
    });

    testWidgets('an outgoing zoomed canvas editor gives no jump', (
      tester,
    ) async {
      const duration = Duration(milliseconds: 300);
      const canvas = CanvasTab(C89.newer);
      const zoomedAlpha = CanvasTab(C89.newer, zoomedNoteId: C89.alpha);
      const zoomedBeta = CanvasTab(C89.newer, zoomedNoteId: C89.beta);
      Finder zoomed(String id) => find.byKey(Key('zoomed-$id'));
      final db = seedRevealNotes(seedCanvasFixture(FakeVaultDb.v5()));
      for (final id in [C89.alpha, C89.beta]) {
        db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          revealLongBody,
          id,
        ]);
      }
      final h = await pumpNoteReveal(
        tester,
        db: db,
        open: null,
        zoom: duration,
      );
      Future<void> finishSwitch() async {
        await tester.pump(duration);
        await tester.pump(duration);
        await pumpFrames(tester);
      }

      await h.navigate(canvas);
      await pumpFrames(tester);
      await h.navigate(zoomedAlpha);
      await finishSwitch();
      final alphaJumps = h.jumps(under: zoomed(C89.alpha));
      final recorded = h.recorded.length;

      h.tabs.navigate(zoomedBeta);
      h.request(_wi66cMidRequest(noteId: C89.beta, flash: true));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(zoomed(C89.alpha), findsOneWidget, reason: 'still switching');
      expect(zoomed(C89.beta), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      expect(alphaJumps.count, 0, reason: 'the outgoing editor never jumps');
      await finishSwitch();

      expect(zoomed(C89.alpha), findsNothing);
      expect(alphaJumps.count, 0);
      expect(
        _wi66cFromTop(h, _wi66cMid, under: zoomed(C89.beta)),
        closeTo(16, _wi66cPx),
        reason: 'the incoming editor landed it',
      );
      expect(
        h.recorded.skip(recorded).where((r) => r.noteId == C89.beta),
        hasLength(1),
        reason: 'one landing recorded: ${h.recorded.skip(recorded)}',
      );
    });

    testWidgets(
      'a request for the outgoing zoomed canvas editor note gives no jump there',
      (tester) async {
        const duration = Duration(milliseconds: 300);
        const canvas = CanvasTab(C89.newer);
        const zoomedAlpha = CanvasTab(C89.newer, zoomedNoteId: C89.alpha);
        const zoomedBeta = CanvasTab(C89.newer, zoomedNoteId: C89.beta);
        Finder zoomed(String id) => find.byKey(Key('zoomed-$id'));
        final db = seedRevealNotes(seedCanvasFixture(FakeVaultDb.v5()));
        for (final id in [C89.alpha, C89.beta]) {
          db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
            revealLongBody,
            id,
          ]);
        }
        final h = await pumpNoteReveal(
          tester,
          db: db,
          open: null,
          zoom: duration,
        );
        await h.navigate(canvas);
        await pumpFrames(tester);
        await h.navigate(zoomedAlpha);
        await tester.pump(duration);
        await tester.pump(duration);
        await pumpFrames(tester);
        final alphaJumps = h.jumps(under: zoomed(C89.alpha));
        final recorded = h.recorded.length;

        // The switch has begun: alpha is outgoing when the request is made.
        h.tabs.navigate(zoomedBeta);
        h.request(_wi66cMidRequest(noteId: C89.alpha, flash: true));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(zoomed(C89.alpha), findsOneWidget, reason: 'still switching');
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(duration);
        await tester.pump(duration);
        await pumpFrames(tester);

        expect(alphaJumps.count, 0, reason: 'the outgoing editor never lands');
        expect(h.highlight, findsNothing);
        expect(
          h.recorded.skip(recorded).where((r) => r.noteId == C89.alpha),
          isEmpty,
        );
      },
    );

    testWidgets('RevealWithin with the anchor already in band gives no jump', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final at = revealLongBody.indexOf('line 200\n');
      await h.scrollContent(h.lineTopOf(0, at), h.viewport().top + 300);
      final jumps = h.jumps();

      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtText(segment: 0, start: at, content: revealLongBody),
          const RevealWithin(60),
          flash: true,
        ),
      );
      await pumpFrames(tester);

      expect(jumps.count, 0);
      expect(h.pending, isNull, reason: 'taken');
      await _wi66cExpectControl(tester, h);
    });

    testWidgets(
      'Source mode without leaveSource gives no jump and drops the request',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final jumps = h.jumps();
        await h.toggleSource();

        h.request(_wi66cMidRequest(flash: true));
        expect(await _wi66cPumpCountingHighlights(tester), 0);
        expect(h.pending, isNull, reason: 'dropped');
        await h.toggleSource();
        expect(await _wi66cPumpCountingHighlights(tester), 0);
        await pumpFrames(tester);

        expect(jumps.count, 0, reason: 'no later landing: ${jumps.values}');
        await _wi66cExpectControl(tester, h);
      },
    );
  });
}
