// WI #70 (54-O4, Spec #58 TS6): the Outline robot journey. A person opens a
// long note, opens the Outline with Cmd+Shift+O, arrows to an entry, jumps
// with Enter, scrolls on, goes back to the editor with Esc and types a new
// heading. The robot drives the app through stable Keys only
// (`outline-tab-chip`, `outline-list`, `outline-entry-<i>`, `editor-body`);
// geometry comes from the editor's own line boxes (`lineTopOf`).
//
// Never pumpAndSettle the workspace: pumpFrames only. Test names use no
// apostrophes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi70_outline.dart';

/// Drives the Outline the way a person does.
class _Wi70OutlineRobot {
  _Wi70OutlineRobot(this.h);

  final NoteRevealHarness h;
  WidgetTester get tester => h.tester;

  Future<void> pressOutlineChord() async {
    expect(await wi70OutlineChord(tester), isTrue, reason: 'Cmd+Shift+O');
    await pumpFrames(tester);
  }

  Future<void> press(LogicalKeyboardKey key, {int times = 1}) =>
      wi70Press(tester, key, times: times);

  /// Scrolls the editor so heading [index] has just passed the top.
  Future<void> scrollToHeading(int index) => wi70PutCurrent(h, index);

  /// Types [line] at the end of the note body.
  Future<void> typeAtEnd(String line) async {
    final body = find.byKey(editorBodyKey);
    final text = editorBodySegment(tester).text;
    await typeSegmentText(tester, body, '$text$line');
    await pumpFrames(tester);
  }

  // ---------------------------------------------------------- expectations

  void expectOutlineShowing() {
    expect(find.byKey(const Key('outline-tab-chip')), findsOneWidget);
    expect(find.byKey(const Key('outline-list')), findsOneWidget);
    expect(h.read(rightPanelOpenProvider), isTrue);
    expect(h.read(rightPanelTabProvider), RightPanelTab.outline);
  }

  void expectFocusOn(int i) => wi70ExpectOutlineFocus(tester, i);

  void expectCurrent(int i) =>
      expect(wi70CurrentRows(tester), [i], reason: 'row $i is current');

  void expectHeadingAtTop(int i) => expect(
    wi70FromTop(h, wi70Entries(h)[i]),
    closeTo(16, 0.01),
    reason: 'heading $i sits 16 px below the body top',
  );

  void expectFocusInEditor() {
    expect(wi70FocusInOutline(), isFalse, reason: 'focus left the Outline');
    expect(
      wi70FocusWithin(tester, find.byKey(editorBodyKey)),
      isTrue,
      reason: 'focus is back in the editor',
    );
  }

  void expectEntry(int i, String text) => expect(
    find.descendant(of: wi70Row(i), matching: find.text(text)),
    findsOneWidget,
    reason: 'row $i reads $text',
  );
}

void main() {
  holdFontFetches();

  testWidgets(
    'outline journey from Cmd+Shift+O through Down Down Enter then scroll Esc and a typed heading',
    (tester) async {
      // Open a long note, the right panel closed.
      final h = await pumpWi70(tester, panelOpen: false);
      final robot = _Wi70OutlineRobot(h);
      wi70Unfocus();
      await tester.pump();

      // Cmd+Shift+O: the Outline opens with focus on the first entry (the
      // page is above the first heading).
      await robot.pressOutlineChord();
      robot.expectOutlineShowing();
      robot.expectFocusOn(0);

      // Down twice, then Enter: heading 2 is 16 px below the body top and
      // current, and focus stays on it.
      await robot.press(LogicalKeyboardKey.arrowDown, times: 2);
      robot.expectFocusOn(2);
      await robot.press(LogicalKeyboardKey.enter);
      robot.expectHeadingAtTop(2);
      robot.expectCurrent(2);
      robot.expectFocusOn(2);

      // Scroll on: the current entry changes.
      await robot.scrollToHeading(5);
      robot.expectCurrent(5);

      // Esc: focus is back in the editor.
      await robot.press(LogicalKeyboardKey.escape);
      robot.expectFocusInEditor();

      // Type a new level two heading: a new entry appears.
      await robot.typeAtEnd('## Fresh heading\n');
      robot.expectEntry(wi70KeysCount, 'Fresh heading');
      expect(wi70Row(wi70KeysCount + 1), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: macOnly,
  );
}
