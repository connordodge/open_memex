// WI #146 (Spec #123 A4, Testing Strategy robot journey): open a note,
// choose "Attach file…" in its ⋯ menu, pick a PNG and a PDF, see both
// lines appear in the body separated by blank lines, and undo them with
// Cmd+Z while the files stay stored.
//
// Stable Keys only: `note-menu-button`, `note-menu`, `note-menu-attach-file`
// and the editor's `text-segment-<i>` (read through its handle). The picker
// is `FakeFilePicker`; stores go to `FakeAttachmentsAccess`.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/editor_rows_probe.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi146_attach_harness.dart';

/// The attach journey's robot: one method per step a person takes.
class _Wi146AttachRobot {
  _Wi146AttachRobot(this.r);

  final Wi146Harness r;
  WidgetTester get tester => r.tester;

  Future<void> openNote() async {
    await r.open();
    expect(r.robot.textSegment(0), findsOneWidget);
  }

  Future<void> putCaretAfter(String text) => r.caretAfter(text);

  /// Opens the ⋯ menu, chooses Attach file…, and picks [paths] in the
  /// picker.
  Future<void> attachFiles(List<String> paths) async {
    r.picker.fileLists.add(paths);
    await r.chooseMenuAttach();
    await r.releaseAll();
  }

  /// The body text the editor shows.
  String get bodyText => editorBodyText(tester);

  Future<void> undo() async {
    rowsHostOf(tester).widget.focusNode.requestFocus();
    await tester.pump(const Duration(seconds: 1));
    await tester.macCmdChord(LogicalKeyboardKey.keyZ);
    await pumpFrames(tester);
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'open a note then Attach file picks a PNG and a PDF whose lines appear separated by blank lines and Cmd Z removes both while the files stay stored',
    (tester) async {
      final r = await wi146Pump(tester);
      final robot = _Wi146AttachRobot(r);

      await robot.openNote();
      expect(robot.bodyText, wi146Example);
      await robot.putCaretAfter('Review the draft');

      await robot.attachFiles(const [wi146MockPath, wi146SpecPath]);

      expect(r.pickCalls, hasLength(1));
      expect(r.pickCalls.single.allowMultiple, isTrue);
      final png = wi146Line('mock.png');
      final pdf = wi146Line('spec.pdf');
      expect(
        robot.bodyText,
        'Review the draft\n\n$png\n$pdf\n\nNext steps',
        reason: 'two lines, in pick order, with a blank line on each side',
      );
      expect(r.body, robot.bodyText, reason: 'the note body holds them');

      await robot.undo();
      expect(robot.bodyText, wi146Example, reason: 'one Cmd+Z removes both');
      expect(r.body, wi146Example);
      expect(
        [for (final c in r.attachments.addCalls) c.filePath],
        [wi146MockPath, wi146SpecPath],
        reason: 'both files were stored once and nothing removed them',
      );
      expect(r.attachments.openCalls, isEmpty);
      expect(r.attachments.revealCalls, isEmpty);
    },
    variant: macOnly,
  );
}
