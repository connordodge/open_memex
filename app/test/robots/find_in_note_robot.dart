// WI #85 (Spec #61 F6): the Find in note robot. It drives the real
// workspace the way a person does: Cmd+F, Cmd+G and Cmd+E arrive as the
// native menu's `find` window channel messages (TD5); the Find bar is driven
// by its stable Keys (TD8); the note body through the segmented editor
// robot.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

import '../support/note_reveal_pump.dart';
import '../support/wi85_find_editor.dart';
import 'segmented_editor_robot.dart';

class FindInNoteRobot {
  FindInNoteRobot(this.w);

  final Wi85 w;

  WidgetTester get tester => w.tester;
  SegmentedEditorRobot get editor => w.robot;

  /// Launches the workspace over the wi85 vault with [noteId] open.
  static Future<FindInNoteRobot> launch(
    WidgetTester tester, {
    String noteId = wi85TopicId,
  }) async => FindInNoteRobot(await pumpWi85(tester, open: noteId));

  // ------------------------------------------------------------ menu

  /// Edit > Find > Find... (Cmd+F).
  Future<void> pressCmdF() => w.send('show');

  /// Edit > Find > Find Next (Cmd+G).
  Future<void> pressCmdG() => w.send('next');

  // ------------------------------------------------------------ bar

  Future<void> typeQuery(String query) => w.typeQuery(query);

  /// Steps with the bar's down button until the current match is an
  /// excerpt card's.
  Future<FindMatch> stepToCardMatch() =>
      w.stepUntil((m) => m.kind == FindSourceKind.card);

  /// Steps with the bar's down button until the current match is the body
  /// match starting at [start] of text segment [segment].
  Future<FindMatch> stepToBodyMatch(int segment, int start) => w.stepUntil(
    (m) =>
        m.kind == FindSourceKind.body &&
        m.segment == segment &&
        m.start == start,
  );

  /// Clicks into the query field.
  Future<void> clickField() async {
    await tester.tap(w.field);
    await pumpFrames(tester);
  }

  /// Presses Esc wherever focus is.
  Future<void> pressEsc() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------ body

  /// Puts the caret at [offset] of text segment [segment] and types [text]
  /// there, one character at a time.
  Future<void> typeInBody(int segment, int offset, String text) async {
    await editor.focusSegment(segment, offset: offset);
    await editor.typeChars(text);
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------ checks

  void expectBarOpen({required String query, required int total}) {
    expect(w.bar, findsOneWidget);
    expect(w.state.query, query);
    expect(w.state.matches, hasLength(total));
    expect(w.counter, '${w.state.current! + 1} of $total');
  }

  void expectBarClosed() {
    expect(w.bar, findsNothing);
    expect(w.state.open, isFalse);
    expect(w.ranges(), isEmpty, reason: 'no highlights remain');
  }

  /// The body field of [m]'s segment has focus and [m] selected.
  void expectSelected(FindMatch m) {
    expect(m.kind, FindSourceKind.body);
    expect(editor.segmentHasFocus(m.segment), isTrue);
    expect(
      editor.segmentSelection(m.segment),
      TextSelection(baseOffset: m.start, extentOffset: m.end),
    );
  }
}
