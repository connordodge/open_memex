// Spelling helpers of the #392 spelling journey (WI #439), kept out of
// segmented_editor_robot.dart: the finder-migration hygiene test (WI #159
// AC10) bans reading text segments through EditableText in that file, and
// these helpers address one field by the text it holds, which a
// SegmentEditing handle cannot do for the rows of one segment.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/fake_spelling_service.dart';
import '../support/app_harness.dart' show pumpFrames;
import 'segmented_editor_robot.dart';

// ------------------------------------------------- spelling (WI #439)

/// Spelling helpers of the #392 spelling journey (WI #439): the issues the
/// note editor published for a field, its row semantics hints, the
/// SpellingMenu, a right click on a word and Cmd+; as macOS delivers it.
///
/// Fields are found by a needle their text contains: a live preview row's
/// field, or Source mode's body field.
extension SpellingEditorRobot on SegmentedEditorRobot {
  /// The note editor field whose text contains [needle].
  Finder spellingField(String needle) => find.descendant(
    of: find.byType(NoteEditor),
    matching: find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text.contains(needle),
      description: 'editor field holding "$needle"',
    ),
  );

  TextEditingController spellingCtrl(String needle) {
    return tester.widget<EditableText>(spellingField(needle)).controller;
  }

  /// What the note editor published for the field holding [needle]
  /// (field-local offsets).
  List<SpellIssue> spellIssues(String needle) {
    final field = spellingField(needle);
    final registry = SpellIssueScope.maybeOf(tester.element(field));
    if (registry == null) {
      throw TestFailure('the field of "$needle" has no SpellIssueRegistry');
    }
    return registry.issuesFor(spellingCtrl(needle)).value;
  }

  /// The words of the field holding [needle] flagged as misspelled.
  List<String> misspelledIn(String needle) {
    final text = spellingCtrl(needle).text;
    return [
      for (final i in spellIssues(needle))
        if (i.kind == SpellIssueKind.spelling &&
            i.start >= 0 &&
            i.start + i.length <= text.length)
          text.substring(i.start, i.start + i.length),
    ];
  }

  /// Every non-empty semantics hint on the row of the field holding
  /// [needle]: its node, its descendants and its ancestors (the squiggle
  /// layer's `misspelled: <word>` hint).
  List<String> spellingHints(String needle) {
    final node = tester.getSemantics(spellingField(needle));
    final hints = <String>[];
    void down(SemanticsNode n) {
      hints.add(n.getSemanticsData().hint);
      n.visitChildren((c) {
        down(c);
        return true;
      });
    }

    down(node);
    for (var p = node.parent; p != null; p = p.parent) {
      hints.add(p.getSemanticsData().hint);
    }
    return hints.where((h) => h.isNotEmpty).toList();
  }

  /// The SpellingMenu on screen.
  Finder get spellingMenu => find.byType(SpellingMenu);

  /// The SpellingMenu item reading exactly [label].
  Finder spellingMenuItem(String label) => find.descendant(
    of: spellingMenu,
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == label,
      description: 'menu text "$label"',
    ),
  );

  /// A right click (secondary mouse button) on [word]'s second character in
  /// the field holding [needle]. On macOS it selects [word] unless it lands
  /// on the selection.
  Future<void> rightClickWord(String needle, String word) async {
    final field = spellingField(needle);
    final at = spellingCtrl(needle).text.indexOf(word);
    if (at < 0) throw TestFailure('"$word" is not in the field of "$needle"');
    final editable = tester.state<EditableTextState>(field).renderEditable;
    Offset caret(int offset) {
      final r = editable.getLocalRectForCaret(TextPosition(offset: offset));
      return editable.localToGlobal(Offset(r.left, r.center.dy));
    }

    final a = caret(at + 1);
    final b = caret(at + 2);
    final mouse = await tester.startGesture(
      Offset((a.dx + b.dx) / 2, a.dy),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await mouse.up();
    await tester.pump();
    await mouse.removePointer();
    await pumpFrames(tester);
  }

  /// Taps the SpellingMenu item [label] and lets its action run.
  Future<void> chooseSpellingItem(String label) async {
    await tester.tap(spellingMenuItem(label));
    await pumpFrames(tester);
  }

  /// Presses Cmd+; as macOS delivers it: the key events reach Flutter
  /// first; when Flutter leaves them unhandled, the Spelling submenu's key
  /// equivalent sends `checkDocumentNow()`, which [spelling] stands in for.
  /// Returns whether Flutter handled the `;` key down or up.
  Future<bool> pressCheckDocumentNow(FakeSpellingService spelling) async {
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.metaLeft,
      platform: 'macos',
    );
    final down = await tester.sendKeyDownEvent(
      LogicalKeyboardKey.semicolon,
      platform: 'macos',
      character: ';',
    );
    final up = await tester.sendKeyUpEvent(
      LogicalKeyboardKey.semicolon,
      platform: 'macos',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await tester.pump();
    final handled = down || up;
    if (!handled) spelling.emitCheckDocumentNow();
    await pumpFrames(tester);
    return handled;
  }
}
