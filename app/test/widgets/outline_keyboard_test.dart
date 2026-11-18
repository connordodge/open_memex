// WI #70 (54-O4, Spec #58 R14, R17-R18, R24, R25, R28, R30, R38; TD7, TD8;
// TS5): the Outline wired to the editor, and its keys once it has focus.
//
// - Wiring: a row click jumps through `jumpToOutlineEntry` with the live
//   text, the current section (#69's tracker) highlights its row, and the
//   Outline scrolls the least needed to keep the current row visible.
// - In-list keys: a roving focus ring moved by Up/Down (clamped, no wrap),
//   Enter/Space jump and keep focus, Esc returns focus to the editor field
//   that last had it (`editor_focus_memory.dart`), or to the body.
// - The ring and the current marks are independent (design pack 70).
//
// Focus gets into the Outline through Cmd+Shift+O (the chord itself is
// pinned in `outline_keys_test.dart`). Geometry comes from the editor's own
// line boxes (`lineTopOf`), never from constants. Keyboard and pointer tests
// run under macOnly. Never pumpAndSettle the workspace: pumpFrames only.
// Test names use no apostrophes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/outline/outline_row.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi70_outline.dart';

/// Line tops sit on half pixels; the jump lands them exactly.
const _wi70Px = 0.01;

const _up = LogicalKeyboardKey.arrowUp;
const _down = LogicalKeyboardKey.arrowDown;

SegmentEditing _wi70Body(WidgetTester tester) => editorBodySegment(tester);

/// The title field's EditableText.
EditableText _wi70Title(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: find.byKey(const Key('editor-title')),
    matching: find.byType(EditableText),
  ),
);

/// The RenderParagraph showing [text] in Outline row [i].
RenderParagraph _wi70RowParagraph(WidgetTester tester, int i, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: wi70Row(i), matching: find.text(text)),
    );

/// Whether row [i] paints a foreground painter (the focus ring).
bool _wi70RowHasRing(WidgetTester tester, int i) => find
    .descendant(
      of: wi70Row(i),
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.foregroundPainter != null,
      ),
    )
    .evaluate()
    .isNotEmpty;

/// Cmd+Shift+O, checked handled, then the focus ring on row [i].
Future<void> _wi70FocusOutline(WidgetTester tester, int i) async {
  expect(await wi70OutlineChord(tester), isTrue, reason: 'Cmd+Shift+O');
  await pumpFrames(tester);
  wi70ExpectOutlineFocus(tester, i, reason: 'after Cmd+Shift+O');
}

/// The editor field that has keyboard focus now, and its selection.
({FocusNode? node, TextSelection selection}) _wi70Snapshot(
  WidgetTester tester, {
  required bool title,
}) => (
  node: FocusManager.instance.primaryFocus,
  selection: title
      ? _wi70Title(tester).controller.selection
      : _wi70Body(tester).selection,
);

void main() {
  holdFontFetches();

  // ------------------------------------------------------------- wiring
  group('wiring', () {
    testWidgets(
      'clicking an Outline row jumps its heading 16 px below the body top with the arrival flash and leaves caret and focus unchanged',
      (tester) async {
        final h = await pumpWi70(tester, tab: RightPanelTab.outline);
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 30);
        _wi70Body(
          tester,
        ).select(const TextSelection(baseOffset: 30, extentOffset: 44));
        await tester.pump();
        final before = _wi70Snapshot(tester, title: false);
        expect(
          before.selection,
          const TextSelection(baseOffset: 30, extentOffset: 44),
        );
        final entry = wi70Entries(h)[6];
        expect(wi70FromTop(h, entry), greaterThan(h.viewport().height));

        await tester.tap(wi70Row(6));
        await pumpFrames(tester);

        expect(wi70FromTop(h, entry), closeTo(16, _wi70Px), reason: 'jumped');
        expect(h.highlight, findsOneWidget, reason: 'the arrival flash');
        expect(
          FocusManager.instance.primaryFocus,
          same(before.node),
          reason: 'the focused node did not move',
        );
        expect(_wi70Body(tester).selection, before.selection, reason: 'caret');
        expect(wi70CurrentRows(tester), [6], reason: 'the row is current');
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'clicking an Outline row after typing above its heading jumps to the heading where it now is',
      (tester) async {
        final h = await pumpWi70(tester, tab: RightPanelTab.outline);
        final text = _wi70Body(tester).text;
        await typeSegmentText(
          tester,
          find.byKey(editorBodyKey),
          '${List.filled(30, 'typed line\n').join()}$text',
        );
        await pumpFrames(tester);
        final entry = wi70Entries(h)[3];
        expect(entry.local, greaterThan(text.indexOf('## Section 3')));

        await tester.tap(wi70Row(3));
        await pumpFrames(tester);

        expect(wi70FromTop(h, entry), closeTo(16, _wi70Px));
        expect(h.highlight, findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'scrolling the editor moves the current row highlight in the Outline',
      (tester) async {
        final h = await pumpWi70(tester, tab: RightPanelTab.outline);
        expect(wi70CurrentRows(tester), isEmpty, reason: 'above the first');

        for (final i in [3, 8, 2, 13]) {
          await wi70PutCurrent(h, i);
          expect(wi70CurrentRows(tester), [i], reason: 'scrolled to $i');
        }
        await h.scrollTo(0);
        await pumpFrames(tester);
        expect(wi70CurrentRows(tester), isEmpty, reason: 'back at the top');
      },
    );

    testWidgets(
      'when the current row is below the visible Outline the list scrolls just enough to show it at the bottom',
      (tester) async {
        final h = await pumpWi70(
          tester,
          open: wi70TallId,
          tab: RightPanelTab.outline,
        );
        final list = wi70ListRect(tester);
        expect(wi70ListPosition(tester).pixels, 0);
        expect(wi70Row(90), findsNothing, reason: 'fixture: row 90 is below');

        await wi70PutCurrent(h, 90);
        await pumpFrames(tester);

        expect(wi70CurrentRows(tester), [90]);
        final row = tester.getRect(wi70Row(90));
        expect(row.top, greaterThanOrEqualTo(list.top - 0.5));
        expect(
          row.bottom,
          closeTo(list.bottom, 0.5),
          reason: 'scrolled the least needed: the row sits at the bottom',
        );

        // One heading further: the list moves on by exactly one row.
        final pixels = wi70ListPosition(tester).pixels;
        await wi70PutCurrent(h, 91);
        await pumpFrames(tester);
        final next = tester.getRect(wi70Row(91));
        expect(next.bottom, closeTo(list.bottom, 0.5));
        expect(
          wi70ListPosition(tester).pixels,
          closeTo(pixels + next.height, 0.5),
        );
      },
    );

    testWidgets(
      'when the current row is above the visible Outline the list scrolls just enough to show it at the top',
      (tester) async {
        final h = await pumpWi70(
          tester,
          open: wi70TallId,
          tab: RightPanelTab.outline,
        );
        final list = wi70ListRect(tester);
        await wi70PutCurrent(h, 110);
        await pumpFrames(tester);
        expect(
          wi70Row(30),
          findsNothing,
          reason: 'the list followed row 110 down: row 30 is above',
        );

        await wi70PutCurrent(h, 30);
        await pumpFrames(tester);

        expect(wi70CurrentRows(tester), [30]);
        final row = tester.getRect(wi70Row(30));
        expect(
          row.top,
          closeTo(list.top, 0.5),
          reason: 'scrolled the least needed: the row sits at the top',
        );
      },
    );

    testWidgets(
      'when the current row is already visible the Outline does not scroll',
      (tester) async {
        final h = await pumpWi70(
          tester,
          open: wi70TallId,
          tab: RightPanelTab.outline,
        );
        final list = wi70ListRect(tester);
        await wi70PutCurrent(h, 90);
        await pumpFrames(tester);
        final pixels = wi70ListPosition(tester).pixels;
        expect(pixels, greaterThan(0), reason: 'the list followed row 90 down');

        for (final i in [80, 70, 89]) {
          expect(
            tester.getRect(wi70Row(i)).top,
            greaterThanOrEqualTo(list.top),
            reason: 'fixture: row $i is visible',
          );
          await wi70PutCurrent(h, i);
          await pumpFrames(tester);
          expect(wi70CurrentRows(tester), [i]);
          expect(
            wi70ListPosition(tester).pixels,
            pixels,
            reason: 'row $i was visible: the list stays',
          );
        }
      },
    );

    testWidgets('the current row is semantics selected and no other row is', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        final h = await pumpWi70(tester, tab: RightPanelTab.outline);
        await wi70PutCurrent(h, 5);

        for (final i in [0, 4, 5, 6, 13]) {
          final d = tester
              .getSemantics(
                find
                    .descendant(
                      of: wi70Row(i),
                      matching: find.byType(MouseRegion),
                    )
                    .first,
              )
              .getSemanticsData();
          expect(d.flagsCollection.isButton, isTrue, reason: 'row $i');
          expect(
            d.flagsCollection.isSelected == ui.Tristate.isTrue,
            i == 5,
            reason: 'row $i selected',
          );
        }
      } finally {
        handle.dispose();
      }
    });
  });

  // ------------------------------------------------------------- arrows
  group('Up and Down', () {
    testWidgets(
      'from current row ten five Up presses move the focus ring to row five and the current row stays ten',
      (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 10);
        await _wi70FocusOutline(tester, 10);
        final pixels = h.pixels();

        for (var k = 1; k <= 5; k++) {
          await wi70Press(tester, _up);
          wi70ExpectOutlineFocus(tester, 10 - k, reason: 'Up $k');
          expect(wi70CurrentRows(tester), [10], reason: 'current stays');
        }
        expect(h.pixels(), pixels, reason: 'Up does not move the editor');
      },
      variant: macOnly,
    );

    testWidgets('Down moves the focus ring to the next entry', (tester) async {
      final h = await pumpWi70(tester);
      await wi70PutCurrent(h, 2);
      await _wi70FocusOutline(tester, 2);
      final text = _wi70Body(tester).text;

      await wi70Press(tester, _down);
      wi70ExpectOutlineFocus(tester, 3, reason: 'Down once');
      await wi70Press(tester, _down);
      wi70ExpectOutlineFocus(tester, 4, reason: 'Down twice');
      await wi70Press(tester, _up);
      wi70ExpectOutlineFocus(tester, 3, reason: 'then Up');
      expect(wi70CurrentRows(tester), [2], reason: 'current stays');
      expect(_wi70Body(tester).text, text, reason: 'nothing typed');
    }, variant: macOnly);

    testWidgets(
      'at the first entry Up keeps the focus ring on the first entry',
      (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 2);
        await _wi70FocusOutline(tester, 2);

        await wi70Press(tester, _up, times: 2);
        wi70ExpectOutlineFocus(tester, 0, reason: 'reached the first');
        await wi70Press(tester, _up);
        wi70ExpectOutlineFocus(tester, 0, reason: 'Up at the first stays');
        await wi70Press(tester, _up, times: 3);
        wi70ExpectOutlineFocus(tester, 0, reason: 'no wrap to the last');

        // Control: Down still moves.
        await wi70Press(tester, _down);
        wi70ExpectOutlineFocus(tester, 1, reason: 'control');
      },
      variant: macOnly,
    );

    testWidgets(
      'at the last entry Down keeps the focus ring on the last entry',
      (tester) async {
        final h = await pumpWi70(tester);
        const last = wi70KeysCount - 1;
        await wi70PutCurrent(h, last - 1);
        await _wi70FocusOutline(tester, last - 1);

        await wi70Press(tester, _down);
        wi70ExpectOutlineFocus(tester, last, reason: 'reached the last');
        await wi70Press(tester, _down);
        wi70ExpectOutlineFocus(tester, last, reason: 'Down at the last stays');
        await wi70Press(tester, _down, times: 3);
        wi70ExpectOutlineFocus(tester, last, reason: 'no wrap to the first');

        // Control: Up still moves.
        await wi70Press(tester, _up);
        wi70ExpectOutlineFocus(tester, last - 1, reason: 'control');
      },
      variant: macOnly,
    );

    testWidgets(
      'Down past the bottom of the Outline scrolls the list just enough to keep the focused row visible',
      (tester) async {
        await pumpWi70(tester, open: wi70TallId, tab: RightPanelTab.outline);
        final list = wi70ListRect(tester);
        await _wi70FocusOutline(tester, 0);

        await wi70Press(tester, _down, times: 70);

        wi70ExpectOutlineFocus(tester, 70, reason: 'Down 70 times');
        final row = tester.getRect(wi70Row(70));
        expect(row.top, greaterThanOrEqualTo(list.top - 0.5));
        expect(
          row.bottom,
          closeTo(list.bottom, 0.5),
          reason: 'the focused row is shown, the list scrolled the least',
        );
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------- activate
  group('Enter and Space', () {
    for (final (name, key) in <(String, LogicalKeyboardKey)>[
      (
        'Enter on the focused entry jumps to its heading and focus stays on that entry',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on the focused entry jumps to its heading and focus stays on that entry',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 3);
        await _wi70FocusOutline(tester, 3);
        await wi70Press(tester, _down, times: 4);
        wi70ExpectOutlineFocus(tester, 7, reason: 'fixture');
        final text = _wi70Body(tester).text;
        final selection = _wi70Body(tester).selection;
        final entry = wi70Entries(h)[7];

        await wi70Press(tester, key);

        expect(wi70FromTop(h, entry), closeTo(16, _wi70Px), reason: 'jumped');
        expect(h.highlight, findsOneWidget, reason: 'the arrival flash');
        wi70ExpectOutlineFocus(tester, 7, reason: 'focus stays on the entry');
        expect(wi70CurrentRows(tester), [7], reason: 'it is now current');
        expect(_wi70Body(tester).text, text, reason: 'nothing typed');
        expect(_wi70Body(tester).selection, selection, reason: 'caret kept');
      }, variant: macOnly);
    }
  });

  // ------------------------------------------------------------- contracts
  group('in-list key contracts', () {
    testWidgets('Up and Down repeats keep moving the focus ring', (
      tester,
    ) async {
      final h = await pumpWi70(tester);
      await wi70PutCurrent(h, 5);
      await _wi70FocusOutline(tester, 5);

      await tester.sendKeyDownEvent(_down, platform: 'macos');
      await tester.sendKeyRepeatEvent(_down, platform: 'macos');
      await tester.sendKeyRepeatEvent(_down, platform: 'macos');
      await tester.sendKeyUpEvent(_down, platform: 'macos');
      await pumpFrames(tester);
      wi70ExpectOutlineFocus(tester, 8, reason: 'down plus two repeats');

      await tester.sendKeyDownEvent(_up, platform: 'macos');
      await tester.sendKeyRepeatEvent(_up, platform: 'macos');
      await tester.sendKeyUpEvent(_up, platform: 'macos');
      await pumpFrames(tester);
      wi70ExpectOutlineFocus(tester, 6, reason: 'up plus a repeat');
    }, variant: macOnly);

    for (final (name, key) in <(String, LogicalKeyboardKey)>[
      (
        'holding Enter jumps once and its repeats do not jump again',
        LogicalKeyboardKey.enter,
      ),
      (
        'holding Space jumps once and its repeats do not jump again',
        LogicalKeyboardKey.space,
      ),
      (
        'holding numpad Enter jumps once and its repeats do not jump again',
        LogicalKeyboardKey.numpadEnter,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 3);
        await _wi70FocusOutline(tester, 3);
        await wi70Press(tester, _down, times: 4);
        final entry = wi70Entries(h)[7];

        await tester.sendKeyDownEvent(key, platform: 'macos');
        await pumpFrames(tester);
        expect(wi70FromTop(h, entry), closeTo(16, _wi70Px), reason: 'jumped');

        await h.scrollTo(0);
        await pumpFrames(tester);
        expect(
          wi70FromTop(h, entry),
          greaterThan(h.viewport().height),
          reason: 'fixture: scrolled away from the heading',
        );
        await tester.sendKeyRepeatEvent(key, platform: 'macos');
        await tester.sendKeyRepeatEvent(key, platform: 'macos');
        await tester.sendKeyUpEvent(key, platform: 'macos');
        await pumpFrames(tester);

        expect(
          wi70FromTop(h, entry),
          greaterThan(h.viewport().height),
          reason: 'a held key jumps once',
        );
        wi70ExpectOutlineFocus(tester, 7, reason: 'focus stays');
      }, variant: macOnly);
    }

    for (final (name, mod) in <(String, LogicalKeyboardKey)>[
      (
        'with Cmd held Up Down Enter and Esc are left alone by the Outline',
        wi70Meta,
      ),
      (
        'with Ctrl held Up Down Enter and Esc are left alone by the Outline',
        wi70Ctrl,
      ),
      (
        'with Alt held Up Down Enter and Esc are left alone by the Outline',
        wi70Alt,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 3);
        await _wi70FocusOutline(tester, 3);
        final pixels = h.pixels();
        final list = wi70ListPosition(tester).pixels;

        await tester.sendKeyDownEvent(mod, platform: 'macos');
        for (final key in [
          _down,
          _up,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.escape,
        ]) {
          await tester.sendKeyEvent(key, platform: 'macos');
          await pumpFrames(tester);
        }
        await tester.sendKeyUpEvent(mod, platform: 'macos');
        await pumpFrames(tester);

        wi70ExpectOutlineFocus(tester, 3, reason: 'ring and focus stay');
        expect(h.pixels(), pixels, reason: 'no jump');
        expect(wi70ListPosition(tester).pixels, list);
      }, variant: macOnly);
    }
  });

  // ------------------------------------------------------------- Esc
  group('Esc', () {
    testWidgets(
      'Esc returns focus to the body field that last had focus with its selection unchanged',
      (tester) async {
        final h = await pumpWi70(tester);
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 20);
        // The focus starts a caret-reveal scroll toward the note end (the
        // selection is still at the segment end): let it finish, then return.
        await pumpFrames(tester);
        await h.scrollTo(0);
        await pumpFrames(tester);
        _wi70Body(
          tester,
        ).select(const TextSelection(baseOffset: 20, extentOffset: 35));
        await tester.pump();
        final before = _wi70Snapshot(tester, title: false);
        await _wi70FocusOutline(tester, 0);
        await wi70Press(tester, _down, times: 2);
        await wi70Press(tester, LogicalKeyboardKey.enter);
        final pixels = h.pixels();

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(
          FocusManager.instance.primaryFocus,
          same(before.node),
          reason: 'the body field that last had focus has it again',
        );
        expect(_wi70Body(tester).selection, before.selection);
        expect(wi70FocusInOutline(), isFalse);
        expect(wi70FocusedRows(tester), isEmpty, reason: 'the ring is gone');
        // Design pack 70: Esc removes the ring, the rows keep their current
        // marks, so the page stays where the jump put it.
        expect(wi70CurrentRows(tester), [2], reason: 'current marks stay');
        expect(h.pixels(), pixels, reason: 'the page does not move');
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc returns focus to the note title field with its selection unchanged',
      (tester) async {
        await pumpWi70(tester);
        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await tester.pump();
        _wi70Title(tester).controller.selection = const TextSelection(
          baseOffset: 1,
          extentOffset: 3,
        );
        await tester.pump();
        final before = _wi70Snapshot(tester, title: true);
        expect(
          wi70FocusWithin(tester, find.byKey(const Key('editor-title'))),
          isTrue,
        );
        await _wi70FocusOutline(tester, 0);
        await wi70Press(tester, _down);

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(FocusManager.instance.primaryFocus, same(before.node));
        expect(
          _wi70Title(tester).controller.selection,
          const TextSelection(baseOffset: 1, extentOffset: 3),
        );
        expect(wi70FocusedRows(tester), isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc returns focus to the field focused last when the title and then the body had focus',
      (tester) async {
        final h = await pumpWi70(tester);
        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await tester.pump();
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 9);
        // The focus starts a caret-reveal scroll toward the note end (the
        // selection is still at the segment end): let it finish, then return.
        await pumpFrames(tester);
        await h.scrollTo(0);
        await pumpFrames(tester);
        final before = _wi70Snapshot(tester, title: false);
        // Focus leaves the editor for the sidebar before the Outline.
        await wi70FocusSidebar(tester);
        await _wi70FocusOutline(tester, 0);

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(
          FocusManager.instance.primaryFocus,
          same(before.node),
          reason: 'the body, focused after the title',
        );
        expect(wi70FocusWithin(tester, find.byKey(editorBodyKey)), isTrue);
        expect(_wi70Body(tester).selection, before.selection);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc with no editor field focused since the note opened focuses the body without placing a caret',
      (tester) async {
        final h = await pumpWi70(tester);
        wi70Unfocus();
        await tester.pump();
        final selection = _wi70Body(tester).selection;
        await wi70PutCurrent(h, 4);
        await _wi70FocusOutline(tester, 4);
        final pixels = h.pixels();

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(
          wi70FocusWithin(tester, find.byKey(editorBodyKey)),
          isTrue,
          reason:
              'the body has focus '
              '(primary: ${FocusManager.instance.primaryFocus})',
        );
        expect(wi70FocusInOutline(), isFalse);
        expect(
          _wi70Body(tester).selection,
          selection,
          reason: 'no caret is placed',
        );
        expect(wi70FocusedRows(tester), isEmpty);
        // Design pack 70: the rows keep their current marks after Esc.
        expect(h.pixels(), pixels, reason: 'the page does not move');
        expect(wi70CurrentRows(tester), [4]);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc after switching notes ignores the field focused in the previous note',
      (tester) async {
        final h = await pumpWi70(tester);
        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await tester.pump();
        wi70Unfocus();
        await tester.pump();
        await h.navigate(const NoteTab(wi70TallId));
        await pumpFrames(tester);
        expect(h.body().note.id, wi70TallId);
        final selection = _wi70Body(tester).selection;
        await _wi70FocusOutline(tester, 0);

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(
          wi70FocusWithin(tester, find.byKey(editorBodyKey)),
          isTrue,
          reason: 'the new note body, not the old note title',
        );
        expect(
          wi70FocusWithin(tester, find.byKey(const Key('editor-title'))),
          isFalse,
        );
        expect(_wi70Body(tester).selection, selection);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc with the find bar open returns focus to the editor and the find bar stays open',
      (tester) async {
        final h = await pumpWi70(tester);
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 4);
        // The focus starts a caret-reveal scroll toward the note end (the
        // selection is still at the segment end): let it finish, then return.
        await pumpFrames(tester);
        await h.scrollTo(0);
        await pumpFrames(tester);
        final before = _wi70Snapshot(tester, title: false);
        h.read(findInNoteProvider.notifier).show();
        await pumpFrames(tester);
        expect(h.read(findInNoteProvider).open, isTrue, reason: 'fixture');
        await _wi70FocusOutline(tester, 0);
        expect(h.read(findInNoteProvider).open, isTrue, reason: 'in Outline');

        await wi70Press(tester, LogicalKeyboardKey.escape);

        expect(FocusManager.instance.primaryFocus, same(before.node));
        expect(
          h.read(findInNoteProvider).open,
          isTrue,
          reason: 'Esc from an entry does not close the find bar (D13)',
        );
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------- ring
  group('focus ring and current marks', () {
    testWidgets(
      'a focused row that is not current shows only the focus ring and the current row keeps its marks',
      (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 10);
        await _wi70FocusOutline(tester, 10);

        await wi70Press(tester, _up, times: 5);

        final focused = tester.widget<OutlineRow>(wi70Row(5));
        expect(focused.focused, isTrue);
        expect(focused.current, isFalse, reason: 'the ring alone');
        expect(_wi70RowHasRing(tester, 5), isTrue, reason: 'row 5 ring');
        final text5 = _wi70RowParagraph(tester, 5, 'Section 5');
        expect(text5.text.style?.color, isNot(OmColors.accent));
        expect(
          _wi70RowParagraph(tester, 5, 'h2').text.style?.color,
          OmColors.fg2,
        );

        final current = tester.widget<OutlineRow>(wi70Row(10));
        expect(current.current, isTrue, reason: 'row 10 stays current');
        expect(current.focused, isFalse, reason: 'no ring on row 10');
        expect(_wi70RowHasRing(tester, 10), isFalse);
        expect(
          _wi70RowParagraph(tester, 10, 'Section 10').text.style?.color,
          OmColors.accent,
        );
        expect(
          _wi70RowParagraph(tester, 10, 'h2').text.style?.color,
          OmColors.accentSoft,
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the focused current row shows the focus ring and the current marks together',
      (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 8);

        await _wi70FocusOutline(tester, 8);

        final row = tester.widget<OutlineRow>(wi70Row(8));
        expect(row.focused, isTrue);
        expect(row.current, isTrue);
        expect(_wi70RowHasRing(tester, 8), isTrue);
        expect(
          _wi70RowParagraph(tester, 8, 'Section 8').text.style?.color,
          OmColors.accent,
        );
        for (final i in [0, 7, 9, 13]) {
          final other = tester.widget<OutlineRow>(wi70Row(i));
          expect(other.focused || other.current, isFalse, reason: 'row $i');
          expect(_wi70RowHasRing(tester, i), isFalse, reason: 'row $i');
        }
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------- menu
  test(
    'MainMenu.xib has no Outline menu item and no Cmd+Shift+O key equivalent',
    () {
      final xib = File(
        'macos/Runner/Base.lproj/MainMenu.xib',
      ).readAsStringSync();
      // One chunk per menu item: its tag and the children up to the next.
      final chunks = xib.split('<menuItem ').skip(1).toList();
      expect(chunks.length, greaterThan(20), reason: 'fixture: items read');
      for (final chunk in chunks) {
        final tag = chunk.substring(0, chunk.indexOf('>'));
        final title =
            RegExp(r'title="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
        expect(title.toLowerCase(), isNot(contains('outline')), reason: tag);
        final key = RegExp(
          r'keyEquivalent="([^"]*)"',
        ).firstMatch(tag)?.group(1);
        final mask = RegExp(
          r'<modifierMask key="keyEquivalentModifierMask"[^>]*>',
        ).firstMatch(chunk)?.group(0);
        final shift = key == 'O' || (mask?.contains('shift="YES"') ?? false);
        expect(
          (key == 'o' || key == 'O') && shift,
          isFalse,
          reason: 'no Shift+Cmd+O key equivalent: $tag',
        );
      }
    },
  );
}
