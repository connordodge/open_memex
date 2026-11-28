// #69 (54-O3, Spec #58 R22-R26, R25a, R41, TD6; rulings D3h, D5): the
// Outline's current section, reported by the editor's section tracker into
// `outlineSectionProvider`, on the shared reveal pump. The current entry is
// the last heading whose heading LINE top (not its row top) has reached the
// viewport top + 16 px; none above the first heading and none in Source
// mode. Every position comes from the editor's own line boxes (`lineTopOf`),
// never from constants: #53 changes heading geometry in parallel.
//
// The work probe is `SectionTracker.debugPasses` (one per computation).
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart' show Note;
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/outline_section.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart'
    show EditorScrollScope;
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/outline/outline_jump.dart';
import 'package:open_memex_app/src/widgets/outline/section_tracker.dart';

import '../support/font_fetch_hold.dart';
import '../support/note_reveal_pump.dart';
import '../support/segment_editing_finder.dart';

/// The mark: the viewport top + this.
const _wi69Inset = 16.0;

/// The Outline entries of the live text the editor shows.
List<OutlineEntry> _wi69Entries(NoteRevealHarness h) =>
    outlineEntries(h.shownContent(), role: h.body().note.role);

/// The entry whose plain text starts with [text].
OutlineEntry _wi69Entry(NoteRevealHarness h, String text) =>
    _wi69Entries(h).firstWhere(
      (e) => e.text.startsWith(text),
      orElse: () => throw TestFailure('no entry "$text"'),
    );

/// Watches the current-section provider, as the Outline tab does while it
/// shows, and pumps two frames. Closed at teardown.
Future<ProviderSubscription<OutlineEntry?>> _wi69Watch(
  NoteRevealHarness h, {
  int frames = 2,
}) async {
  final sub = h.container.listen<OutlineEntry?>(
    outlineSectionProvider,
    (_, _) {},
  );
  addTearDown(sub.close);
  for (var i = 0; i < frames; i++) {
    await h.tester.pump();
  }
  return sub;
}

/// The global y of the visual line holding [local] of [segment], relative
/// to the viewport top.
double _wi69FromTop(NoteRevealHarness h, int local, {int segment = 0}) =>
    h.lineTopOf(segment, local) - h.viewport().top;

/// Scrolls so the visual line holding [local] of [segment] sits [fromTop]
/// px below the viewport top, checks it got there, and pumps a frame.
Future<void> _wi69Put(
  NoteRevealHarness h,
  int local,
  double fromTop, {
  int segment = 0,
}) async {
  await h.scrollContent(
    h.lineTopOf(segment, local),
    h.viewport().top + fromTop,
  );
  await h.tester.pump();
  expect(
    _wi69FromTop(h, local, segment: segment),
    fromTop,
    reason: 'the line sits exactly $fromTop px below the viewport top',
  );
}

/// The entry the line boxes say is current: the last whose heading line top
/// is at or above the mark (an oracle for states set up indirectly).
OutlineEntry? _wi69Expected(NoteRevealHarness h) {
  OutlineEntry? current;
  for (final e in _wi69Entries(h)) {
    if (_wi69FromTop(h, e.local, segment: e.segment) <= _wi69Inset + 1e-6) {
      current = e;
    }
  }
  return current;
}

/// Jumps to [entry] of the shown note, as the Outline tab does.
void _wi69Jump(WidgetTester tester, NoteRevealHarness h, OutlineEntry entry) =>
    jumpToOutlineEntry(
      tester.element(find.byType(NoteEditor)) as WidgetRef,
      h.body().note.id,
      entry,
      h.shownContent(),
    );

/// A bare note [id] for a hand-built editor tree.
Note _wi69Note(String id) => Note(
  id: id,
  title: id,
  contentMd: '',
  frontmatter: '',
  version: 1,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

void main() {
  holdFontFetches();

  setUp(() => SectionTracker.debugPasses = 0);

  group('the mark', () {
    testWidgets(
      'no entry is current while the viewport top is above the first heading',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final mid = _wi69Entry(h, 'Mid heading');
        expect(_wi69Entries(h).first, mid, reason: 'the first heading');

        expect(h.pixels(), 0);
        expect(sub.read(), isNull, reason: 'at the top of the note');
        await _wi69Put(h, mid.local, 300);
        await tester.pump();
        expect(sub.read(), isNull, reason: 'the first heading is below');
        await _wi69Put(h, mid.local, _wi69Inset + 1);
        await tester.pump();
        expect(sub.read(), isNull, reason: '1 px short of the mark');

        // Control: the tracker does report the first heading.
        await _wi69Put(h, mid.local, _wi69Inset);
        await tester.pump();
        expect(sub.read(), mid);
      },
    );

    testWidgets(
      'a heading is current exactly when its line top is at viewport top plus 16 and not when it is 1 px lower',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final mid = _wi69Entry(h, 'Mid heading');
        final wrapped = _wi69Entry(h, 'Wrapped');

        for (final (entry, fromTop, expected, why) in [
          (mid, _wi69Inset, mid, 'Mid exactly on the mark'),
          (mid, _wi69Inset + 1, null, 'Mid 1 px below the mark'),
          (mid, _wi69Inset - 1, mid, 'Mid 1 px above the mark'),
          (wrapped, _wi69Inset, wrapped, 'Wrapped exactly on the mark'),
          (wrapped, _wi69Inset + 1, mid, 'Wrapped 1 px below the mark'),
          (wrapped, _wi69Inset - 1, wrapped, 'Wrapped 1 px above the mark'),
        ]) {
          await _wi69Put(h, entry.local, fromTop);
          await tester.pump();
          expect(sub.read(), expected, reason: why);
        }
      },
    );

    testWidgets('between headings the last heading reached is current', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      final mid = _wi69Entry(h, 'Mid heading');
      final wrapped = _wi69Entry(h, 'Wrapped');
      final end = _wi69Entry(h, 'Near the end');

      await _wi69Put(h, h.offsetOf('line 200\n'), 0);
      await tester.pump();
      expect(sub.read(), mid, reason: 'between Mid and Wrapped');

      await _wi69Put(h, h.offsetOf('line 300\n'), 0);
      await tester.pump();
      expect(sub.read(), wrapped, reason: 'between Wrapped and the end');

      // At the end of the note the last heading shows but has not reached
      // the mark.
      await h.scrollTo(h.position().maxScrollExtent);
      await tester.pump();
      expect(_wi69FromTop(h, end.local), greaterThan(_wi69Inset + 1));
      expect(_wi69FromTop(h, end.local), lessThan(h.viewport().height));
      expect(sub.read(), wrapped, reason: 'visible is not reached');

      await _wi69Put(h, h.offsetOf('line 230\n'), 0);
      await tester.pump();
      expect(sub.read(), mid, reason: 'back up between Mid and Wrapped');
    });
  });

  group('the heading line', () {
    testWidgets(
      'a heading in the middle of a prose row becomes current when its own line reaches the mark and not when its row top does',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final mid = _wi69Entry(h, 'Mid heading');
        final before = h.offsetOf('para before');
        expect(h.rowOf(0, mid.local).index, h.rowOf(0, before).index);

        // The row's top and the paragraph line above the heading are past
        // the mark; the heading line is not.
        await _wi69Put(h, before, _wi69Inset);
        await tester.pump();
        expect(
          h.rowRectOf(0, mid.local).top - h.viewport().top,
          lessThan(_wi69Inset - 1000),
        );
        expect(_wi69FromTop(h, mid.local), greaterThan(_wi69Inset + 1));
        expect(sub.read(), isNull, reason: 'the row top does not count');

        await _wi69Put(h, mid.local, _wi69Inset);
        await tester.pump();
        expect(sub.read(), mid, reason: 'its own line reached the mark');
      },
    );

    testWidgets(
      'a wrapped heading becomes current when its first visual line reaches the mark',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final mid = _wi69Entry(h, 'Mid heading');
        final wrapped = _wi69Entry(h, 'Wrapped');
        final last = wrapped.local + revealWrappedHeading.length - 1;
        expect(h.lineCount(0, wrapped.local, last + 1), greaterThan(1));

        // Its first line 1 px short of the mark: the heading before it.
        await _wi69Put(h, wrapped.local, _wi69Inset + 1);
        await tester.pump();
        expect(sub.read(), mid, reason: 'its first line is 1 px short');

        await _wi69Put(h, wrapped.local, _wi69Inset);
        await tester.pump();
        expect(_wi69FromTop(h, last), greaterThan(_wi69Inset + 1));
        expect(sub.read(), wrapped, reason: 'its first line is on the mark');
      },
    );

    testWidgets(
      'in a daily note the stray heading becomes current when its line reaches the mark',
      (tester) async {
        final h = await pumpNoteReveal(tester, open: revealDailyId);
        final sub = await _wi69Watch(h);
        final stray = _wi69Entry(h, 'Stray heading');

        await _wi69Put(h, stray.local, _wi69Inset + 1, segment: stray.segment);
        await tester.pump();
        expect(sub.read(), isNull);

        await _wi69Put(h, stray.local, _wi69Inset, segment: stray.segment);
        await tester.pump();
        expect(sub.read(), stray);
      },
    );
  });

  group('jumps, typing and the caret', () {
    testWidgets('right after a jump the jumped-to entry is current', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      final mid = _wi69Entry(h, 'Mid heading');
      final wrapped = _wi69Entry(h, 'Wrapped');
      expect(sub.read(), isNull);

      _wi69Jump(tester, h, wrapped);
      await pumpFrames(tester);
      expect(_wi69FromTop(h, wrapped.local), closeTo(_wi69Inset, 0.01));
      expect(sub.read(), wrapped);

      // Up to the previous heading: it is current, not the one below.
      _wi69Jump(tester, h, mid);
      await pumpFrames(tester);
      expect(_wi69FromTop(h, mid.local), closeTo(_wi69Inset, 0.01));
      expect(sub.read(), mid);
    });

    testWidgets(
      'typing a heading above the viewport or deleting one updates the current entry',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        await _wi69Put(h, h.offsetOf('line 200\n'), 0);
        await tester.pump();
        expect(sub.read(), _wi69Entry(h, 'Mid heading'));
        final original = editorBodySegment(tester).text;

        // A new heading between Mid and the viewport top.
        editorBodySegment(tester).replaceText(
          original.replaceFirst('line 180\n', '## Typed above\nline 180\n'),
        );
        await pumpFrames(tester);
        final typed = _wi69Entry(h, 'Typed above');
        expect(_wi69FromTop(h, typed.local), lessThan(0), reason: 'above');
        expect(sub.read(), typed);

        // Deleting it: Mid again, at its (unchanged) position.
        editorBodySegment(tester).replaceText(original);
        await pumpFrames(tester);
        expect(sub.read(), _wi69Entry(h, 'Mid heading'));

        // Deleting Mid itself: no heading is above the viewport top now.
        editorBodySegment(
          tester,
        ).replaceText(original.replaceFirst('$revealMidHeading\n', ''));
        await pumpFrames(tester);
        expect(_wi69Entries(h).where((e) => e.text == 'Mid heading'), isEmpty);
        expect(sub.read(), isNull);
      },
    );

    testWidgets('the caret position has no effect on the current entry', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      await _wi69Put(h, h.offsetOf('line 200\n'), 0);
      await tester.pump();
      final mid = _wi69Entry(h, 'Mid heading');
      expect(sub.read(), mid);
      final pixels = h.pixels();

      for (final (caret, why) in [
        (h.offsetOf(revealEndHeading) + 4, 'in the last heading, below'),
        (h.offsetOf(revealWrappedHeading) + 4, 'in the next heading, below'),
        (h.offsetOf('line 5\n') + 2, 'in a body line above the first'),
        (h.offsetOf('line 205\n') + 2, 'in a body line on screen'),
      ]) {
        editorBodySegment(
          tester,
        ).select(TextSelection.collapsed(offset: caret));
        await pumpFrames(tester);
        expect(h.pixels(), pixels, reason: '$why: the page stays put');
        expect(sub.read(), mid, reason: 'caret $why');
      }
    });
  });

  group('modes and listeners', () {
    testWidgets('in Source mode no entry is current', (tester) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      final mid = _wi69Entry(h, 'Mid heading');
      await _wi69Put(h, h.offsetOf('line 200\n'), 0);
      await tester.pump();
      expect(sub.read(), mid);

      await h.toggleSource();
      expect(h.sourceSurface, findsOneWidget);
      expect(sub.read(), isNull, reason: 'none in Source mode');

      // Typing in Source still reports none.
      await tester.enterText(
        find.descendant(
          of: h.sourceSurface,
          matching: find.byKey(editorBodyKey),
        ),
        '## Source heading\n${h.editor.contentMd}',
      );
      await pumpFrames(tester);
      expect(sub.read(), isNull, reason: 'typing in Source: still none');

      // Back in live preview it is computed from the layout again.
      await h.toggleSource();
      await pumpFrames(tester);
      expect(h.sourceSurface, findsNothing);
      expect(sub.read(), _wi69Expected(h));
    });

    testWidgets(
      'when the provider gains a listener the current entry is computed after the next layout',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        // Scrolled while nothing watches.
        await _wi69Put(h, h.offsetOf('line 200\n'), 0);
        await pumpFrames(tester);

        final first = await _wi69Watch(h, frames: 1);
        expect(first.read(), _wi69Entry(h, 'Mid heading'));

        // Unwatched again (the tab is hidden), scrolled on, watched again:
        // never the earlier scroll position's entry.
        first.close();
        await pumpFrames(tester);
        await _wi69Put(h, h.offsetOf('line 300\n'), 0);
        await pumpFrames(tester);

        final second = await _wi69Watch(h, frames: 1);
        expect(second.read(), _wi69Entry(h, 'Wrapped'));
      },
    );

    testWidgets(
      'when the editor switches to another note the current entry is computed after the next layout and is never stale',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        await _wi69Put(h, h.offsetOf('line 200\n'), 0);
        await tester.pump();
        expect(sub.read(), _wi69Entry(h, 'Mid heading'));

        // A note with no headings: none, from the frame after it shows.
        h.tabs.navigate(const NoteTab(revealOtherId));
        String? shown() => find.byType(SegmentedBody).evaluate().isEmpty
            ? null
            : h.body().note.id;
        for (var i = 0; i < 20 && shown() != revealOtherId; i++) {
          await tester.pump();
        }
        expect(h.body().note.id, revealOtherId);
        await tester.pump();
        expect(sub.read(), isNull, reason: 'not the earlier note entry');
        await pumpFrames(tester);
        expect(sub.read(), isNull);

        // A note with a heading of its own, wherever it opens.
        await h.navigate(const NoteTab(revealDailyId));
        await pumpFrames(tester);
        expect(h.body().note.id, revealDailyId);
        final stray = _wi69Entry(h, 'Stray heading');
        await _wi69Put(h, stray.local, _wi69Inset, segment: stray.segment);
        await tester.pump();
        expect(sub.read(), stray);

        // Back to the first note: its restored offset, computed again.
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealOtherId);
        expect(sub.read(), isNull);
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.body().note.id, revealLongId);
        expect(sub.read(), _wi69Entry(h, 'Mid heading'));
      },
    );

    testWidgets(
      'a tracker whose note differs from the one its body shows reports no entry of the body',
      (tester) async {
        // The editor keeps building the previous note's body until the new
        // note hydrates (`SegmentedBody(note: _hydratedNote ?? note)`): the
        // tracker already holds the new note and must not report the old
        // body's headings.
        final h = await pumpNoteReveal(tester, open: null);
        final shown = _wi69Note('wi69-shown');
        final other = _wi69Note('wi69-other');
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final content = '## Head\n${revealLines('line', 0, 120)}';
        Widget tree(Note tracked) => UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            home: Material(
              child: SectionTracker(
                note: tracked,
                child: EditorScrollScope(
                  controller: controller,
                  child: SegmentedBody(
                    note: shown,
                    content: content,
                    savedVersion: 1,
                    onContentChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pumpWidget(tree(shown));
        final sub = h.container.listen<OutlineEntry?>(
          outlineSectionProvider,
          (_, _) {},
        );
        addTearDown(sub.close);
        await pumpFrames(tester);
        // The control: the heading line scrolled well above the viewport top.
        final head = outlineEntries(content).single;
        controller.jumpTo(100);
        await pumpFrames(tester);
        expect(sub.read(), head, reason: 'the note it shows: reported');

        await tester.pumpWidget(tree(other));
        await pumpFrames(tester);
        expect(sub.read(), isNull, reason: 'the body shows another note');

        await tester.pumpWidget(tree(shown));
        await pumpFrames(tester);
        expect(sub.read(), head, reason: 'shown again: reported again');
      },
    );
  });

  group('work', () {
    testWidgets(
      'with no listener scrolling and typing do no section computation',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        SectionTracker.debugPasses = 0;

        Future<void> scrollAndType(String tag) async {
          await h.scrollTo(1500);
          await h.scrollTo(2500);
          final segment = editorBodySegment(tester);
          segment.replaceText(
            segment.text.replaceFirst('line 10\n', 'line 10 $tag\n'),
          );
          await pumpFrames(tester);
        }

        await scrollAndType('a');
        expect(SectionTracker.debugPasses, 0, reason: 'nothing watches');

        // Watched: the probe counts its passes and it reports.
        final sub = await _wi69Watch(h);
        expect(SectionTracker.debugPasses, greaterThan(0));
        expect(sub.read(), _wi69Expected(h));
        expect(sub.read(), isNotNull);

        // Unwatched again: no more passes.
        sub.close();
        await pumpFrames(tester);
        final passes = SectionTracker.debugPasses;
        await scrollAndType('b');
        expect(SectionTracker.debugPasses, passes, reason: 'unwatched');
      },
    );

    testWidgets(
      'a scroll notification from a nested viewport does not start a pass and the page scroll notification does',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        await _wi69Watch(h);
        await pumpFrames(tester);
        final start = SectionTracker.debugPasses;
        final position = h.position();
        ScrollEndNotification nudge(BuildContext context) =>
            ScrollEndNotification(
              metrics: position.copyWith(),
              context: context,
            );

        // From inside the page viewport: it crossed a viewport, depth 1.
        final inner = tester.element(
          find
              .descendant(
                of: h.scrollable(),
                matching: find.byType(EditableText),
              )
              .first,
        );
        final notification = nudge(inner)..dispatch(inner);
        expect(notification.depth, 1, reason: 'came through the viewport');
        await tester.pump();
        await tester.pump();
        expect(SectionTracker.debugPasses, start, reason: 'nested: ignored');

        // From the page scrollable itself: depth 0, one pass.
        final scrollable = tester.element(h.scrollable());
        final own = nudge(scrollable)..dispatch(scrollable);
        expect(own.depth, 0);
        await tester.pump();
        expect(SectionTracker.debugPasses, start + 1, reason: 'the page');
      },
    );

    testWidgets('while watched the tracker computes at most once per frame', (
      tester,
    ) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      await pumpFrames(tester);
      final start = SectionTracker.debugPasses;
      final position = h.position();

      // Several scrolls and a text change in one frame: one pass, after
      // the layout of the final state.
      position.jumpTo(800);
      position.jumpTo(1500);
      position.jumpTo(2600);
      final segment = editorBodySegment(tester);
      segment.replaceText(
        segment.text.replaceFirst('line 10\n', 'line 10 typed\n'),
      );
      await tester.pump();
      expect(SectionTracker.debugPasses - start, 1, reason: 'one frame');
      expect(sub.read(), _wi69Expected(h));
      expect(sub.read(), isNotNull, reason: 'scrolled past a heading');

      // The next frame with scrolls computes again, once.
      position.jumpTo(1500);
      position.jumpTo(1600);
      await tester.pump();
      expect(SectionTracker.debugPasses - start, 2, reason: 'two frames');
      expect(sub.read(), _wi69Expected(h));
    });
  });

  group('a jump stays current while the page sits where it landed', () {
    // Lead ruling Q1 (Spec #58 R22): the jumped-to entry is current while
    // the page sits exactly where the jump put it, a clamped landing
    // included (the last heading never reaches the mark there). A scroll
    // the jump did not cause, a text change, an arrival or a note change
    // drops it: the normal rule decides again.
    Future<({NoteRevealHarness h, ProviderSubscription<OutlineEntry?> sub})>
    clamped(WidgetTester tester) async {
      final h = await pumpNoteReveal(tester);
      final sub = await _wi69Watch(h);
      final end = _wi69Entry(h, 'Near the end');
      final wrapped = _wi69Entry(h, 'Wrapped');
      _wi69Jump(tester, h, end);
      await pumpFrames(tester);
      expect(h.pixels(), h.position().maxScrollExtent, reason: 'clamped');
      expect(_wi69FromTop(h, end.local), greaterThan(_wi69Inset + 1));
      expect(sub.read(), end, reason: 'the jumped-to entry is current');
      expect(_wi69Expected(h), wrapped, reason: 'the normal rule says Wrapped');
      return (h: h, sub: sub);
    }

    testWidgets(
      'a clamped jump keeps its entry current until the page is scrolled by one pixel and then the normal rule decides',
      (tester) async {
        final (:h, :sub) = await clamped(tester);
        final end = _wi69Entry(h, 'Near the end');
        final max = h.position().maxScrollExtent;

        // Still current after more frames, with nothing moving.
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(sub.read(), end, reason: 'stays while the page does not move');

        // A person scrolls up by one pixel: the normal rule.
        await h.scrollTo(max - 1);
        await tester.pump();
        expect(sub.read(), _wi69Expected(h));
        expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'normal rule');

        // Back to the exact end: the pin does not come back.
        await h.scrollTo(max);
        await tester.pump();
        expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'pin is gone');
      },
    );

    testWidgets('a clamped jump is dropped by a text change', (tester) async {
      final (:h, :sub) = await clamped(tester);
      final max = h.position().maxScrollExtent;

      // Text typed near the top: the page stays at its end, the pin is
      // gone and the normal rule decides.
      final segment = editorBodySegment(tester);
      segment.replaceText(
        segment.text.replaceFirst('line 10\n', 'line 10 typed\n'),
      );
      await pumpFrames(tester);
      await pumpFrames(tester);
      expect(h.pixels(), max, reason: 'the page did not move');
      expect(sub.read(), _wi69Expected(h));
      expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'pin dropped');
    });

    testWidgets(
      'a clamped jump is dropped by an arrival that returns to the same note',
      (tester) async {
        final (:h, :sub) = await clamped(tester);
        final arrivals = h.tabState.arrivals;
        // Away and back before a frame shows the other note: the editor
        // never saw another note, but the tabs arrived twice.
        h.tabs.navigate(const NoteTab(revealOtherId));
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.tabState.arrivals, greaterThan(arrivals), reason: 'arrived');
        expect(h.body().note.id, revealLongId);
        expect(sub.read(), _wi69Expected(h), reason: 'the normal rule');
        expect(sub.read(), isNot(_wi69Entry(h, 'Near the end')));
      },
    );

    testWidgets(
      'a scroll before a jump has landed does not drop it so the jumped-to entry is current once it lands',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final end = _wi69Entry(h, 'Near the end');

        // The request is made and a person scrolls before any frame lands
        // it (a scroll outside a frame's end): the seam still lands it.
        _wi69Jump(tester, h, end);
        h.position().jumpTo(1200);
        await pumpFrames(tester);
        expect(h.pixels(), h.position().maxScrollExtent, reason: 'landed');
        expect(sub.read(), end, reason: 'the jumped-to entry is current');

        // Then the pin ends with the next scroll, as ever.
        await h.scrollTo(h.position().maxScrollExtent - 1);
        await tester.pump();
        expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'normal rule');
      },
    );

    testWidgets(
      'a clamped jump is dropped by a scroll away and back while nothing watches the provider',
      (tester) async {
        final (:h, :sub) = await clamped(tester);
        final max = h.position().maxScrollExtent;

        // The Outline is hidden: no pass runs while the page is scrolled
        // away and back onto the exact landing.
        sub.close();
        await pumpFrames(tester);
        await h.scrollTo(max - 300);
        await h.scrollTo(max);
        await pumpFrames(tester);

        final again = await _wi69Watch(h, frames: 1);
        expect(h.pixels(), max);
        expect(again.read(), _wi69Entry(h, 'Wrapped'), reason: 'pin is gone');
      },
    );

    testWidgets(
      'a clamped jump is dropped by a same length text change that leaves its entry where it was',
      (tester) async {
        final (:h, :sub) = await clamped(tester);
        final max = h.position().maxScrollExtent;
        final end = _wi69Entry(h, 'Near the end');

        // Nothing moves: the entry, the layout and the offset are the same,
        // only the text differs.
        final segment = editorBodySegment(tester);
        segment.replaceText(
          segment.text.replaceFirst('line 10\n', 'line 1x\n'),
        );
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.pixels(), max, reason: 'the page did not move');
        expect(_wi69Entries(h).contains(end), isTrue, reason: 'entry unmoved');
        expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'pin dropped');
      },
    );

    testWidgets(
      'a clamped jump is dropped by an arrival that restores the page to the landing while nothing watches the provider',
      (tester) async {
        final (:h, :sub) = await clamped(tester);
        final max = h.position().maxScrollExtent;
        final arrivals = h.tabState.arrivals;

        // Hidden Outline: away to another note and back; the tabs restore
        // the recorded landing offset, so the page sits exactly where the
        // jump put it, in a new arrival.
        sub.close();
        await pumpFrames(tester);
        await h.navigate(const NoteTab(revealOtherId));
        await pumpFrames(tester);
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.tabState.arrivals, greaterThan(arrivals), reason: 'arrived');
        expect(h.body().note.id, revealLongId);
        expect(h.pixels(), max, reason: 'restored to the landing');

        final again = await _wi69Watch(h, frames: 1);
        expect(again.read(), _wi69Entry(h, 'Wrapped'), reason: 'pin is gone');
      },
    );

    testWidgets(
      'a jump that has not landed is dropped when another reveal request replaces it',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final end = _wi69Entry(h, 'Near the end');

        // The jump is replaced in the same frame by a plain reveal that
        // also lands at the end of the note: the seam lands only the
        // latest request, so the Outline did not put the page there.
        _wi69Jump(tester, h, end);
        h.request(
          NoteRevealRequest(
            h.body().note.id,
            h.textAt(end.local, segment: end.segment),
            const RevealTop(_wi69Inset),
          ),
        );
        await pumpFrames(tester);
        expect(h.pixels(), h.position().maxScrollExtent, reason: 'clamped');
        expect(sub.read(), _wi69Entry(h, 'Wrapped'), reason: 'no pin');
      },
    );

    testWidgets(
      'a jump that has not landed is dropped when the provider loses its listener',
      (tester) async {
        final h = await pumpNoteReveal(tester);
        final sub = await _wi69Watch(h);
        final end = _wi69Entry(h, 'Near the end');

        // Hidden before the frame lands it: it lands unseen, is scrolled
        // away from and back onto unseen.
        _wi69Jump(tester, h, end);
        sub.close();
        await pumpFrames(tester);
        final max = h.position().maxScrollExtent;
        expect(h.pixels(), max, reason: 'the seam landed it');
        await h.scrollTo(max - 300);
        await h.scrollTo(max);
        await pumpFrames(tester);

        final again = await _wi69Watch(h, frames: 1);
        expect(again.read(), _wi69Entry(h, 'Wrapped'), reason: 'no pin');
      },
    );
  });
}
