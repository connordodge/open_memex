// WI #255 (A7, Spec #234 Testing Strategy; L1, L8, L14): one journey through
// the whole Tags feature, in the real workspace over fakes for
// `memexCliProvider` and `vaultDbProvider` (no `memex` binary, no real vault):
//
//   type `#work` on a saved daily note and accept it from the type-ahead
//   -> click it in the editor -> Tags mode shows `work` expanded
//   -> click a note row -> `follow` records that note
//   -> go back to the daily note -> remove a footer tag with its x
//   -> the tag is gone and the note's text is unchanged.
//
// Everything is found by Key except one step: a rendered inline tag is text in
// a segment and has no Key of its own, so the tag is found by its position in
// the segment's line boxes, as tag_click_test.dart does.
//
// The fakes do not re-derive tags: the daily note never gets a `work` row, so
// nothing here asserts one. The `update` and `tag rm` fakes act on the stored
// body as the server does.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/mac_editing.dart';
import '../support/note_footer_harness.dart';
import '../support/recording_tabs.dart';
import '../support/segment_editing_finder.dart' show textSegmentKey;

/// The saved daily note the journey writes on. Not Virtual Today: that tab has
/// no tag rows, so it has no footer tags.
const _dailyId = 'daily-2026-10-02';

/// A note that already carries `work`, so the type-ahead offers the tag and the
/// Tags pane has a note row to click.
const _callId = 'note-call';

const _person = 'Slept well\n';

// ------------------------------------------------------------ editor geometry

LineBoxSource _segmentBoxes(WidgetTester tester, [int seg = 0]) {
  final view = tester.state<SegmentViewState>(
    find.descendant(
      of: find.byKey(textSegmentKey(seg)),
      matching: find.byType(SegmentView),
    ),
  );
  return view.lineBoxes() ?? (throw TestFailure('segment $seg has no layout'));
}

/// The middle of the shown text [needle] in text segment [seg].
Offset _on(SegmentedEditorRobot r, String needle, {int seg = 0}) {
  final text = r.segmentText(seg);
  final at = text.indexOf(needle);
  expect(at, isNonNegative, reason: 'segment $seg holds "$needle"');
  final boxes = _segmentBoxes(r.tester, seg);
  final rects = boxes.boxesFor(TextRange(start: at, end: at + needle.length));
  expect(rects, isNotEmpty, reason: '"$needle" has a glyph box');
  final local = rects.first;
  return Rect.fromPoints(
    boxes.box.localToGlobal(local.topLeft),
    boxes.box.localToGlobal(local.bottomRight),
  ).center;
}

/// A plain mouse click at [at], then frames and past the double-click window.
Future<void> _click(WidgetTester tester, Offset at) async {
  await tester.macClick(at);
  await pumpFrames(tester, frames: 8);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));
}

/// Removes the mouse a click leaves added, so [addMouse] can add its own.
Future<void> _dropClickMouse(WidgetTester tester) async {
  final stale = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await stale.removePointer();
  await tester.pump();
}

void main() {
  testWidgets(
    'tags journey: accept a work tag from the type-ahead, open it in Tags mode, follow a note row, then remove a footer tag with the x',
    (tester) async {
      // ---------------------------------------------------------------- seed
      final vault = seedFooterVault();
      seedFooterNote(
        vault.db,
        id: _callId,
        title: 'Call notes',
        body: 'Call with Sam about pricing #work\n',
        bodyTags: ['work'],
      );
      // The daily note holds a footer tag the agent wrote (origin agent).
      seedFooterNote(
        vault.db,
        id: _dailyId,
        title: '2026-10-02',
        role: 'daily',
        body: footerBody(_person, tags: ['pricing']),
        footerTags: ['pricing'],
      );
      final tabs = TabsRecorder();
      final h = await pumpWorkspace(
        tester,
        db: vault.db,
        cli: vault.cli,
        overrides: [tabs.override],
      );
      final r = SegmentedEditorRobot(tester, h);
      await r.open(_dailyId);
      expect(r.segmentText(0), _person, reason: 'the daily note is open');
      expect(footerTag('pricing'), findsOneWidget);
      expect(railTag('pricing'), findsOneWidget);
      expect(find.byKey(const Key('days-pane')), findsOneWidget);
      expect(find.byKey(const Key('tags-pane')), findsNothing);

      // ------------------------------------- type #work, accept from type-ahead
      await r.typeInSegment(0, '${_person}Went for a #wo');
      await pumpFrames(tester);
      expect(
        find.byKey(const Key('tag-autocomplete')),
        findsOneWidget,
        reason: 'typing a hash and letters opens the type-ahead',
      );
      expect(
        find.byKey(const Key('tag-autocomplete-item-work')),
        findsOneWidget,
        reason: 'the tag that exists on another note is offered',
      );

      await r.pressKey(LogicalKeyboardKey.enter);
      final typed = '${_person}Went for a #work ';
      expect(r.segmentText(0), typed, reason: 'Enter completes the tag');
      expect(find.byKey(const Key('tag-autocomplete')), findsNothing);

      // The edit reaches the vault before anything else happens to the note.
      await r.waitForSave();
      expect(r.updates, hasLength(1));
      expect(r.updates.single.stdinBody, contains('Went for a #work'));

      // ---------------------------------------------- click the tag in the text
      // The caret is on the tag's line right after accepting, and a plain click
      // there only places the caret. Move it to the first line, then click.
      await r.pressKey(LogicalKeyboardKey.arrowUp);
      expect(
        r.segmentSelection(0).baseOffset,
        lessThan(_person.length),
        reason: 'the caret left the tag line',
      );
      expect(h.read(sidebarModeProvider), isNot(SidebarMode.tags));

      await _click(tester, _on(r, '#work'));
      await _dropClickMouse(tester);

      expect(find.byKey(const Key('tags-pane')), findsOneWidget);
      expect(find.byKey(const Key('days-pane')), findsNothing);
      expect(find.byKey(const Key('sidebar-mode-tags')), findsOneWidget);
      expect(
        find.byKey(const Key('tag-row-work')),
        findsOneWidget,
        reason: 'the work tag is listed',
      );
      expect(
        find.byKey(const Key('tag-note-row-work-$_callId')),
        findsOneWidget,
        reason: 'work is expanded: its note is listed under it',
      );
      expect(tabs.followed, isEmpty, reason: 'opening a tag follows nothing');

      // -------------------------------------------------- click a note row
      await tester.tap(find.byKey(const Key('tag-note-row-work-$_callId')));
      await pumpFrames(tester, frames: 8);

      expect(tabs.followed, [const NoteTab(_callId)]);

      // ----------------------------- back to the daily note, remove a footer tag
      await tester.tap(find.byKey(const Key('nav-back-button')));
      await pumpFrames(tester, frames: 8);
      r.expectActiveNote(_dailyId);
      expect(footerTag('pricing'), findsOneWidget);
      expect(railTag('pricing'), findsOneWidget);
      final personBefore = r.segmentText(0);
      // The stored daily body ends its person section with a newline.
      expect(
        personBefore.trimRight(),
        typed.trimRight(),
        reason: 'the typed text is still there',
      );

      final mouse = await addMouse(tester);
      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester, frames: 8);

      expect(h.cli.callsFor('tag rm'), hasLength(1));
      expect(
        footerTag('pricing'),
        findsNothing,
        reason: 'the footer tag is gone',
      );
      expect(railTag('pricing'), findsNothing, reason: 'and the rail tag');
      expect(
        r.segmentText(0),
        personBefore,
        reason: 'the text as the editor shows it is unchanged',
      );
      expect(r.segmentText(0), contains('#work'));
      final stored = vault.db.getNote(_dailyId)!.contentMd;
      expect(stored, startsWith(personBefore));
      expect(stored, isNot(contains('#pricing')));
    },
    variant: macOnly,
  );
}
