// WI #169 (C2, Spec #157 R15-R20, R22, R23, R26, R27, TS2, TS7, TS8;
// rulings D2, D6, D8, TD6): the keys that edit and move across a text
// segment's editor rows.
// - Enter splits an item (R15), removes the marker of an empty item (R16);
//   Shift+Enter adds a plain line (R17); Backspace at an item's text start
//   removes its marker (R18) and at a plain line's start joins it onto the
//   line above (R19); forward Delete at a row's end joins the next line
//   (R20). Option+Backspace and Cmd+Backspace at offset 0 act as Backspace.
//   Each is one edit applied through the host (one report, one undo record).
// - With a selection across rows, Backspace and Delete delete the range,
//   and Enter deletes it then splits at its start (R27).
// - Tab and Shift+Tab do nothing in a row (R22).
// - Arrows, Option+arrows, Cmd+arrows cross row edges (R23); Up and Down
//   keep the nearest x through the rows' LineBoxSource (D6); Shift+arrows
//   extend the segment selection across rows (R26).
// - While the IME composes, the keys go to the IME unchanged (TS8); the [[
//   popover keeps Enter.
//
// Keys are sent as macOS delivers them: the key event reaches Flutter
// first; when nothing handles it, the text system sends the key's selector
// (`deleteBackward:`, `moveUp:`, ...; flutter_test's macOS key handler does
// this for an unhandled key event) or, for Enter, inserts a newline
// ([_wi169Press] does this).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/editor/segment_undo.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';

/// A card token: text segment 0, card 1, text segment 2.
const _wi169Token = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// Words long enough to wrap at least twice in the test column.
const _wi169Long =
    'wrapped item text that keeps going well past the right edge of the '
    'text column so the field has to lay it out on a second line and a third';

Note _wi169Note(String content) => Note(
  id: 'topic-169',
  title: 'Keys',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// A pumped [SegmentedBody] whose `onContentChanged` reports are recorded
/// and fed back as the editor content, as `EditorController` does.
class _Wi169Body {
  _Wi169Body(this.changes);

  final List<String> changes;
}

Future<_Wi169Body> _wi169Pump(WidgetTester tester, String text) async {
  final content = ValueNotifier(text);
  final changes = <String>[];
  addTearDown(content.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Column(
            children: [
              // Focusable fields around the body, as the editor page has
              // (the title above, other panes after): a Tab that moves
              // focus would land in one of them.
              const TextField(key: Key('wi169-before')),
              Expanded(
                child: ListenableBuilder(
                  listenable: content,
                  builder: (context, _) => SegmentedBody(
                    note: _wi169Note(content.value),
                    content: content.value,
                    savedVersion: 3,
                    onContentChanged: (joined) {
                      changes.add(joined);
                      content.value = joined;
                    },
                  ),
                ),
              ),
              const TextField(key: Key('wi169-after')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Wi169Body(changes);
}

/// A segment undo recorder that remembers what the host told it.
class _Wi169Recorder extends SegmentUndoRecorder {
  final records = <({String before, SegmentEdit edit})>[];

  @override
  void record(SegmentEdit edit, {required String before}) =>
      records.add((before: before, edit: edit));
}

/// Every recorder the host makes from now on lands in the returned list.
/// Restored at teardown.
List<_Wi169Recorder> _wi169Recorders() {
  final made = <_Wi169Recorder>[];
  final previous = segmentUndoRecorderFactory;
  segmentUndoRecorderFactory = () {
    final r = _Wi169Recorder();
    made.add(r);
    return r;
  };
  addTearDown(() => segmentUndoRecorderFactory = previous);
  return made;
}

List<({String before, SegmentEdit edit})> _wi169Records(
  List<_Wi169Recorder> made,
) => [for (final r in made) ...r.records];

SegmentEditing _wi169Seg(WidgetTester tester, [int s = 0]) =>
    segmentEditingAt(tester, s);

SegmentViewState _wi169View(WidgetTester tester, [int s = 0]) =>
    tester.state<SegmentViewState>(
      find.descendant(
        of: find.byKey(textSegmentKey(s)),
        matching: find.byType(SegmentView),
      ),
    );

/// Focus segment [s]'s row holding [offset] and put the caret there.
Future<void> _wi169Focus(WidgetTester tester, int offset, {int s = 0}) =>
    focusSegmentAt(tester, find.byKey(textSegmentKey(s)), offset: offset);

/// The [EditableTextState] that has focus.
EditableTextState _wi169FocusedField() {
  final context = FocusManager.instance.primaryFocus?.context;
  final state = context == null
      ? null
      : context is StatefulElement && context.state is EditableTextState
      ? context.state as EditableTextState
      : context.findAncestorStateOfType<EditableTextState>();
  if (state == null) throw TestFailure('no text field has focus');
  return state;
}

/// The local selection of the focused row field.
TextSelection _wi169FieldSelection() =>
    _wi169FocusedField().textEditingValue.selection;

/// Press [key] (with the modifiers held) as macOS delivers it: the key
/// event goes to Flutter; when Flutter leaves it unhandled, flutter_test's
/// macOS key handler sends the key's selector to the focused field (as
/// NSTextInputContext does), and for Enter, when [platform] is true, the
/// text system inserts a newline over the focused field's selection.
/// Returns whether Flutter handled the key event.
Future<bool> _wi169Press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
  bool meta = false,
  bool platform = true,
}) async {
  final mods = [
    if (meta) LogicalKeyboardKey.metaLeft,
    if (alt) LogicalKeyboardKey.altLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final m in mods) {
    await tester.sendKeyDownEvent(m, platform: 'macos');
  }
  final bool handled;
  try {
    handled = await tester.sendKeyEvent(key, platform: 'macos');
    await tester.pump();
    if (!handled && platform && key == LogicalKeyboardKey.enter) {
      final value = _wi169FocusedField().textEditingValue;
      final sel = value.selection;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(sel.start, sel.end, '\n'),
          selection: TextSelection.collapsed(offset: sel.start + 1),
        ),
      );
      await tester.pump();
    }
  } finally {
    for (final m in mods.reversed) {
      await tester.sendKeyUpEvent(m, platform: 'macos');
    }
    await tester.pump();
  }
  return handled;
}

/// Segment [s]'s rows as A1 derives them from its text.
List<RowSpec> _wi169Rows(WidgetTester tester, [int s = 0]) =>
    splitRows(_wi169Seg(tester, s).text, atSegmentStart: true);

/// Segment [s]'s caret, failing when the selection isn't collapsed.
int _wi169Caret(WidgetTester tester, [int s = 0]) {
  final sel = _wi169Seg(tester, s).selection;
  expect(sel.isCollapsed, isTrue, reason: 'expected a caret, got $sel');
  return sel.extentOffset;
}

/// The visual lines of row [r] in the rows' LineBoxSource.
List<_Wi169Line> _wi169RowLines(WidgetTester tester, int r, [int s = 0]) {
  final boxes = _wi169View(tester, s).lineBoxes()!;
  final row = _wi169Rows(tester, s)[r];
  return [
    for (final line in boxes.lines)
      if (line.range.start >= row.start && line.range.start < row.end)
        _Wi169Line(line.range, line.top, line.bottom),
  ];
}

/// One visual line: its segment range and its vertical extent in the rows'
/// box.
class _Wi169Line {
  _Wi169Line(this.range, this.top, this.bottom);
  final TextRange range;
  final double top;
  final double bottom;
  double get middle => (top + bottom) / 2;
}

/// The segment offset nearest the caret x of [from] on [line] (D6).
int _wi169NearestOn(WidgetTester tester, int from, _Wi169Line line) {
  final boxes = _wi169View(tester).lineBoxes()!;
  final x = boxes.caretRect(from).left;
  return boxes.offsetAt(Offset(x, line.middle));
}

/// Invokes [intent] from the focused row field, as a platform shortcut or
/// text system selector does (macOS sends only some of the intents' shapes;
/// the overrides take every shape the field can receive).
Future<void> _wi169Invoke(WidgetTester tester, Intent intent) async {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) throw TestFailure('no text field has focus');
  Actions.invoke(context, intent);
  await tester.pump();
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: Enter splits an item
  // -------------------------------------------------------------------------
  group('Enter in an item row (AC1)', () {
    for (final (name, text, caret, after, at) in [
      (
        'Enter inside a bullet item splits it into two bullets with the caret at the new item text start',
        '- ab',
        3,
        '- a\n- b',
        6,
      ),
      (
        'Enter at the end of item 9 continues the list with item 10',
        '9. x',
        4,
        '9. x\n10. ',
        9,
      ),
      (
        'Enter at the end of a done task continues with an unchecked task',
        '- [x] t',
        7,
        '- [x] t\n- [ ] ',
        14,
      ),
      (
        'Enter inside an item on a CRLF line ends the new line with CRLF',
        '- ab\r\nz',
        3,
        '- a\r\n- b\r\nz',
        7,
      ),
      (
        'Enter at an item text start moves the whole text into the new item',
        '- ab',
        2,
        '- \n- ab',
        5,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, text);
        await _wi169Focus(tester, caret);

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        final seg = _wi169Seg(tester);
        expect(seg.text, after);
        expect(seg.selection, TextSelection.collapsed(offset: at));
        expect(seg.focusedRow, 1, reason: 'focus is in the new row');
        expect(
          _wi169FieldSelection(),
          const TextSelection.collapsed(offset: 0),
        );
        expect(body.changes, [after], reason: 'one report for one edit');
        final records = _wi169Records(recorders);
        expect(records, hasLength(1), reason: 'one undo step');
        expect(records.single.before, text);
        expect(records.single.edit.apply(text), after);
      }, variant: macOnly);
    }

    testWidgets(
      'Enter in a prose row inserts a plain newline and adds no marker',
      (tester) async {
        final body = await _wi169Pump(tester, '- a\nbc');
        await _wi169Focus(tester, 5);

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        expect(_wi169Seg(tester).text, '- a\nb\nc');
        expect(_wi169Caret(tester), 6);
        expect(body.changes, ['- a\nb\nc']);

        // The item above still splits.
        await _wi169Focus(tester, 3);
        await _wi169Press(tester, LogicalKeyboardKey.enter);
        expect(_wi169Seg(tester).text, '- a\n- \nb\nc');
        expect(_wi169Caret(tester), 6);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: Enter in an empty item
  // -------------------------------------------------------------------------
  group('Enter in an empty item (AC2)', () {
    for (final (name, text, after) in [
      (
        'Enter in an empty bullet after an item leaves an empty prose line with the caret on it',
        '- one\n- ',
        '- one\n',
      ),
      (
        'Enter in an empty task leaves an empty prose line with the caret on it',
        '- [ ] call\n- [ ] ',
        '- [ ] call\n',
      ),
      (
        'Enter in an empty numbered item leaves an empty prose line with the caret on it',
        '1. a\n2. ',
        '1. a\n',
      ),
      (
        'Enter in a lone empty bullet leaves an empty segment with the caret in it',
        '- ',
        '',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, text);
        await _wi169Focus(tester, text.length);

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        final seg = _wi169Seg(tester);
        expect(seg.text, after);
        expect(seg.selection, TextSelection.collapsed(offset: after.length));
        final rows = _wi169Rows(tester);
        expect(rows.last.kind, RowKind.prose);
        expect(seg.focusedRow, segmentRowHolding(seg, after.length));
        expect(seg.focusedRow, rows.length - 1);
        expect(body.changes, [after]);
        expect(_wi169Records(recorders), hasLength(1));
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC3: Shift+Enter
  // -------------------------------------------------------------------------
  group('Shift+Enter (AC3)', () {
    testWidgets(
      'Shift Enter inside a bullet item adds a plain line with the caret before its text in a prose row',
      (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, '- ab');
        await _wi169Focus(tester, 3);

        await _wi169Press(tester, LogicalKeyboardKey.enter, shift: true);

        final seg = _wi169Seg(tester);
        expect(seg.text, '- a\nb');
        expect(seg.selection, const TextSelection.collapsed(offset: 4));
        expect(seg.focusedRow, 1);
        expect(_wi169Rows(tester)[1].kind, RowKind.prose);
        expect(
          _wi169FieldSelection(),
          const TextSelection.collapsed(offset: 0),
        );
        expect(body.changes, ['- a\nb']);
        expect(_wi169Records(recorders), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Enter in a task item on a CRLF line adds a plain CRLF line',
      (tester) async {
        await _wi169Pump(tester, '- [ ] ab\r\nz');
        await _wi169Focus(tester, 7);

        await _wi169Press(tester, LogicalKeyboardKey.enter, shift: true);

        expect(_wi169Seg(tester).text, '- [ ] a\r\nb\r\nz');
        expect(_wi169Caret(tester), 9);
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: Backspace at a row start
  // -------------------------------------------------------------------------
  group('Backspace at a row start (AC4)', () {
    testWidgets(
      'Backspace at a done task text start turns it into its plain text with the caret before it',
      (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, '- [x] t');
        await _wi169Focus(tester, 6);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        final seg = _wi169Seg(tester);
        expect(seg.text, 't');
        expect(seg.selection, const TextSelection.collapsed(offset: 0));
        expect(seg.focusedRow, 0);
        expect(body.changes, ['t']);
        expect(_wi169Records(recorders), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace at an item text start below a paragraph makes it a line of that paragraph keeping focus',
      (tester) async {
        await _wi169Pump(tester, 'intro\n- [x] t\nend');
        await _wi169Focus(tester, 12);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        final seg = _wi169Seg(tester);
        expect(seg.text, 'intro\nt\nend');
        expect(seg.selection, const TextSelection.collapsed(offset: 6));
        expect(seg.rowCount, 1);
        expect(seg.focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace at a plain line start joins it onto the item above with the caret at the join',
      (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, '- a\nb');
        await _wi169Focus(tester, 4);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        final seg = _wi169Seg(tester);
        expect(seg.text, '- ab');
        expect(seg.selection, const TextSelection.collapsed(offset: 3));
        expect(seg.focusedRow, 0);
        expect(
          _wi169FieldSelection(),
          const TextSelection.collapsed(offset: 1),
        );
        expect(body.changes, ['- ab']);
        expect(_wi169Records(recorders), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace at a plain line start after a CRLF item removes the whole CRLF',
      (tester) async {
        await _wi169Pump(tester, '- a\r\nb');
        await _wi169Focus(tester, 5);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        expect(_wi169Seg(tester).text, '- ab');
        expect(_wi169Caret(tester), 3);
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace at a line start joins prose lines and changes nothing at the segment first line',
      (tester) async {
        final body = await _wi169Pump(tester, 'a\nb\n- c');
        // A plain line under a prose line joins it (inside one prose row).
        await _wi169Focus(tester, 2);
        await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(_wi169Seg(tester).text, 'ab\n- c');
        expect(_wi169Caret(tester), 1);

        // The segment first line: nothing changes.
        await _wi169Focus(tester, 0);
        await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(_wi169Seg(tester).text, 'ab\n- c');
        expect(_wi169Caret(tester), 0);
        expect(body.changes, ['ab\n- c']);

        // The item below still loses its marker.
        await _wi169Focus(tester, 5);
        await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(_wi169Seg(tester).text, 'ab\nc');
        expect(_wi169Caret(tester), 3);
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace at the first line of a segment below an excerpt card changes nothing',
      (tester) async {
        final body = await _wi169Pump(tester, 'top\n$_wi169Token\nb\n- c');
        expect(_wi169Seg(tester, 2).text, 'b\n- c');
        await _wi169Focus(tester, 0, s: 2);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        expect(_wi169Seg(tester, 2).text, 'b\n- c');
        expect(_wi169Seg(tester).text, 'top\n');
        expect(body.changes, isEmpty);

        // Its item row still loses its marker.
        await _wi169Focus(tester, 4, s: 2);
        await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(_wi169Seg(tester, 2).text, 'b\nc');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: forward Delete at a row end
  // -------------------------------------------------------------------------
  group('Delete at a row end (AC5)', () {
    testWidgets(
      'Delete at the end of a prose line joins the next item text without its marker',
      (tester) async {
        final recorders = _wi169Recorders();
        final body = await _wi169Pump(tester, 'a\n- b');
        await _wi169Focus(tester, 1);

        await _wi169Press(tester, LogicalKeyboardKey.delete);

        final seg = _wi169Seg(tester);
        expect(seg.text, 'ab');
        expect(seg.selection, const TextSelection.collapsed(offset: 1));
        expect(seg.focusedRow, 0);
        expect(body.changes, ['ab']);
        expect(_wi169Records(recorders), hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Delete at the end of an item joins the next item text and a following plain line',
      (tester) async {
        await _wi169Pump(tester, '- a\r\n- b\nc');
        await _wi169Focus(tester, 3);

        await _wi169Press(tester, LogicalKeyboardKey.delete);
        expect(_wi169Seg(tester).text, '- ab\nc');
        expect(_wi169Caret(tester), 3);

        await _wi169Focus(tester, 4);
        await _wi169Press(tester, LogicalKeyboardKey.delete);
        expect(_wi169Seg(tester).text, '- abc');
        expect(_wi169Caret(tester), 4);
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets('Delete at the segment end changes nothing', (tester) async {
      final body = await _wi169Pump(tester, 'a\n- b');
      await _wi169Focus(tester, 5);

      await _wi169Press(tester, LogicalKeyboardKey.delete);

      expect(_wi169Seg(tester).text, 'a\n- b');
      expect(_wi169Caret(tester), 5);
      expect(body.changes, isEmpty);

      // The row end above still joins.
      await _wi169Focus(tester, 1);
      await _wi169Press(tester, LogicalKeyboardKey.delete);
      expect(_wi169Seg(tester).text, 'ab');
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC6: Option+Backspace and Cmd+Backspace at offset 0
  // -------------------------------------------------------------------------
  group('Option and Cmd Backspace at offset 0 (AC6)', () {
    for (final (name, alt, meta) in [
      (
        'Option Backspace at a done task text start removes its marker like Backspace',
        true,
        false,
      ),
      (
        'Cmd Backspace at a done task text start removes its marker like Backspace',
        false,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final recorders = _wi169Recorders();
        await _wi169Pump(tester, 'x\n- [x] t');
        await _wi169Focus(tester, 8);

        await _wi169Press(
          tester,
          LogicalKeyboardKey.backspace,
          alt: alt,
          meta: meta,
        );

        expect(_wi169Seg(tester).text, 'x\nt');
        expect(_wi169Caret(tester), 2);
        expect(_wi169Records(recorders), hasLength(1));
      }, variant: macOnly);
    }

    for (final (name, alt, meta) in [
      (
        'Option Backspace at a plain line start joins it onto the item above',
        true,
        false,
      ),
      (
        'Cmd Backspace at a plain line start joins it onto the item above',
        false,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _wi169Pump(tester, '- a\nbc');
        await _wi169Focus(tester, 4);

        await _wi169Press(
          tester,
          LogicalKeyboardKey.backspace,
          alt: alt,
          meta: meta,
        );

        expect(_wi169Seg(tester).text, '- abc');
        expect(_wi169Caret(tester), 3);
      }, variant: macOnly);
    }

    testWidgets(
      'Option Backspace inside an item text deletes the word before the caret and keeps the marker',
      (tester) async {
        await _wi169Pump(tester, 'x\n- foo bar');
        await _wi169Focus(tester, 11);

        await _wi169Press(tester, LogicalKeyboardKey.backspace, alt: true);
        expect(_wi169Seg(tester).text, 'x\n- foo ');
        expect(_wi169Caret(tester), 8);

        // At the text start it now removes the marker.
        await _wi169Focus(tester, 4);
        await _wi169Press(tester, LogicalKeyboardKey.backspace, alt: true);
        expect(_wi169Seg(tester).text, 'x\nfoo ');
        expect(_wi169Caret(tester), 2);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: Backspace, Delete and Enter over a selection across rows
  // -------------------------------------------------------------------------
  group('keys over a selection across rows (AC7)', () {
    for (final (name, key, base, extent) in [
      (
        'Backspace with a selection across rows deletes the range with the caret at its start',
        LogicalKeyboardKey.backspace,
        3,
        8,
      ),
      (
        'Delete with a selection across rows deletes the range with the caret at its start',
        LogicalKeyboardKey.delete,
        3,
        8,
      ),
      (
        'Backspace with a backward selection across rows deletes the range with the caret at its start',
        LogicalKeyboardKey.backspace,
        8,
        3,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await _wi169Pump(tester, '- ab\n- cd\ne');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(TextSelection(baseOffset: base, extentOffset: extent));
        await tester.pump();

        await _wi169Press(tester, key);

        final seg = _wi169Seg(tester);
        expect(seg.text, '- ad\ne');
        expect(seg.selection, const TextSelection.collapsed(offset: 3));
        expect(seg.focusedRow, 0);
        expect(body.changes, ['- ad\ne']);
      }, variant: macOnly);
    }

    testWidgets(
      'Backspace with a selection from a prose row into an item deletes the markers inside the range',
      (tester) async {
        await _wi169Pump(tester, 'ab\n- cd\n- ef');
        await _wi169Focus(tester, 1);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 1, extentOffset: 11));
        await tester.pump();

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        expect(_wi169Seg(tester).text, 'af');
        expect(_wi169Caret(tester), 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Enter with a selection across item rows deletes the range then splits the item at its start',
      (tester) async {
        final body = await _wi169Pump(tester, '- ab\n- cd\ne');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 3, extentOffset: 8));
        await tester.pump();

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        final seg = _wi169Seg(tester);
        expect(seg.text, '- a\n- d\ne');
        expect(seg.selection, const TextSelection.collapsed(offset: 6));
        expect(seg.focusedRow, 1);
        expect(body.changes.last, '- a\n- d\ne');
      },
      variant: macOnly,
    );

    testWidgets(
      'Enter with a selection from a prose row into an item deletes the range then inserts a plain newline',
      (tester) async {
        await _wi169Pump(tester, 'ab\n- cd');
        await _wi169Focus(tester, 1);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 1, extentOffset: 6));
        await tester.pump();

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        expect(_wi169Seg(tester).text, 'a\nd');
        expect(_wi169Caret(tester), 2);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: Tab and Shift+Tab do nothing in rows
  // -------------------------------------------------------------------------
  group('Tab in rows (AC8)', () {
    for (final (name, shift, caret, row) in [
      (
        'Tab in an item row changes no text and leaves focus and caret in that row',
        false,
        3,
        0,
      ),
      (
        'Shift Tab in a middle item row changes no text and leaves focus and caret in that row',
        true,
        8,
        1,
      ),
      (
        'Tab in the last prose row changes no text and leaves focus and caret in that row',
        false,
        11,
        2,
      ),
      (
        'Shift Tab in the last prose row changes no text and leaves focus and caret in that row',
        true,
        11,
        2,
      ),
    ]) {
      testWidgets(name, (tester) async {
        const text = '- ab\n- cd\nef';
        final body = await _wi169Pump(tester, text);
        await _wi169Focus(tester, caret);
        final node = FocusManager.instance.primaryFocus;

        await _wi169Press(tester, LogicalKeyboardKey.tab, shift: shift);

        final seg = _wi169Seg(tester);
        expect(seg.text, text);
        expect(seg.focusedRow, row);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(seg.selection, TextSelection.collapsed(offset: caret));
        expect(body.changes, isEmpty);
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC9: navigation across rows
  // -------------------------------------------------------------------------
  group('navigation across rows (AC9)', () {
    testWidgets(
      'Left at a row text start goes to the end of the previous row and Right at a row end to the next row start',
      (tester) async {
        // Rows: prose `ab` 0..2, bullet `cd` text 5..7, prose `ef` 8..10.
        await _wi169Pump(tester, 'ab\n- cd\nef');
        await _wi169Focus(tester, 8);

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 7);
        expect(_wi169Seg(tester).focusedRow, 1);

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 5);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 2, reason: 'skips the marker');
        expect(_wi169Seg(tester).focusedRow, 0);

        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 5);
        expect(_wi169Seg(tester).focusedRow, 1);
        expect(
          _wi169FieldSelection(),
          const TextSelection.collapsed(offset: 0),
        );

        await _wi169Focus(tester, 7);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 8);
        expect(_wi169Seg(tester).focusedRow, 2);
      },
      variant: macOnly,
    );

    testWidgets(
      'Left at the segment first row start and Right at its last row end stay put',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cd');
        await _wi169Focus(tester, 2);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 2);
        expect(_wi169Seg(tester).focusedRow, 0);

        await _wi169Focus(tester, 9);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 9);
        expect(_wi169Seg(tester).focusedRow, 1);

        // Inside the rows the arrows cross the edge between them.
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 4);
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Option Left and Option Right cross row edges and step by words inside a row',
      (tester) async {
        // Rows: bullet `foo bar` text 2..9, bullet `baz` text 12..15.
        await _wi169Pump(tester, '- foo bar\n- baz');
        await _wi169Focus(tester, 12);

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, alt: true);
        expect(_wi169Caret(tester), 9);
        expect(_wi169Seg(tester).focusedRow, 0);

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, alt: true);
        expect(_wi169Caret(tester), 6, reason: 'a word step inside the row');

        await _wi169Focus(tester, 9);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, alt: true);
        expect(_wi169Caret(tester), 12);
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd Left and Cmd Right stay within the visual line while Cmd Up and Cmd Down reach the segment start and end',
      (tester) async {
        const text = 'top\n- ab\n- $_wi169Long\nend';
        await _wi169Pump(tester, text);
        final rows = _wi169Rows(tester);
        final long = rows[2];

        // Cmd+Left at an item text start doesn't cross into the row above.
        await _wi169Focus(tester, rows[1].textStart);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, meta: true);
        expect(_wi169Caret(tester), rows[1].textStart);
        expect(_wi169Seg(tester).focusedRow, 1);

        // Cmd+Right on a wrapped row's first visual line ends on that line.
        final lines = _wi169RowLines(tester, 2);
        expect(lines.length, greaterThanOrEqualTo(2));
        await _wi169Focus(tester, long.textStart + 3);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, meta: true);
        final end = _wi169Caret(tester);
        expect(_wi169Seg(tester).focusedRow, 2);
        expect(end, greaterThan(long.textStart + 3));
        expect(end, lessThanOrEqualTo(lines.first.range.end));
        expect(end, lessThan(long.textEnd));

        // Cmd+Right at an item end doesn't cross into the row below.
        await _wi169Focus(tester, rows[1].textEnd);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, meta: true);
        expect(_wi169Caret(tester), rows[1].textEnd);
        expect(_wi169Seg(tester).focusedRow, 1);

        await _wi169Press(tester, LogicalKeyboardKey.arrowUp, meta: true);
        expect(_wi169Caret(tester), 0);
        expect(_wi169Seg(tester).focusedRow, 0);

        await _wi169Press(tester, LogicalKeyboardKey.arrowDown, meta: true);
        expect(_wi169Caret(tester), text.length);
        expect(_wi169Seg(tester).focusedRow, rows.length - 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Up from a row first visual line lands on the previous row last visual line at the same column and Down goes back',
      (tester) async {
        await _wi169Pump(tester, '- $_wi169Long\n- abcdefgh');
        final rows = _wi169Rows(tester);
        final lines = _wi169RowLines(tester, 0);
        expect(lines.length, greaterThanOrEqualTo(2));
        final last = lines.last;
        expect(last.range.end - last.range.start, greaterThan(4));

        await _wi169Focus(tester, rows[1].textStart + 4);
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);

        // Both bullets put their text at the same x: same column.
        expect(_wi169Caret(tester), last.range.start + 4);
        expect(_wi169Seg(tester).focusedRow, 0);

        // Up again moves inside the wrapped row (native line step).
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Seg(tester).focusedRow, 0);
        expect(_wi169Caret(tester), lessThan(last.range.start));
        expect(_wi169Caret(tester), greaterThanOrEqualTo(rows[0].textStart));

        // From the last visual line, Down lands in the next row.
        await _wi169Focus(tester, last.range.start + 3);
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Caret(tester), rows[1].textStart + 3);
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Up and Down between a prose row and an item row land at the nearest x not the same column',
      (tester) async {
        await _wi169Pump(tester, 'abcdefgh\n- wxyz');
        final rows = _wi169Rows(tester);
        final proseLine = _wi169RowLines(tester, 0).single;
        final itemLine = _wi169RowLines(tester, 1).single;
        final up = _wi169NearestOn(tester, rows[1].textStart, proseLine);
        expect(
          up,
          greaterThan(0),
          reason: 'the item text sits right of the prose text start',
        );

        await _wi169Focus(tester, rows[1].textStart);
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Caret(tester), up);
        expect(_wi169Seg(tester).focusedRow, 0);

        final down = _wi169NearestOn(tester, 5, itemLine);
        await _wi169Focus(tester, 5);
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Caret(tester), down);
        expect(down, greaterThanOrEqualTo(rows[1].textStart));
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Left and Right step over an emoji cluster at a row edge as one character',
      (tester) async {
        // Rows: bullet `a` + thumbs up with skin tone (4 units) text 2..7,
        // bullet with a family emoji (8 units) then `b`, text 10..19.
        const thumbs = '\u{1F44D}\u{1F3FD}';
        const family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
        await _wi169Pump(tester, '- a$thumbs\n- ${family}b');
        await _wi169Focus(tester, 10);

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 7);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Caret(tester), 3, reason: 'before the whole cluster');

        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 7);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 10);
        expect(_wi169Seg(tester).focusedRow, 1);
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight);
        expect(_wi169Caret(tester), 18, reason: 'after the whole family');

        // Shift+Left from the next row start: the same steps.
        await _wi169Focus(tester, 10);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 10, extentOffset: 3),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC10: Up and Down across an excerpt card
  // -------------------------------------------------------------------------
  group('Up and Down across an excerpt card (AC10)', () {
    testWidgets(
      'Up from the second row of a segment below an excerpt card reaches its first row then the segment above',
      (tester) async {
        await _wi169Pump(tester, 'top\n$_wi169Token\n- a\n- b');
        expect(_wi169Seg(tester, 2).text, '- a\n- b');
        await _wi169Focus(tester, 6, s: 2);

        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Seg(tester, 2).focusedRow, 0);
        expect(_wi169Caret(tester, 2), 2);

        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Seg(tester, 2).focusedRow, isNull);
        expect(_wi169Seg(tester).focusedRow, isNotNull);
        expect(_wi169Caret(tester), _wi169Seg(tester).text.length);
      },
      variant: macOnly,
    );

    testWidgets(
      'Down from the end of the segment above an excerpt card reaches the segment below then its next row',
      (tester) async {
        await _wi169Pump(tester, 'top\n$_wi169Token\n- a\n- b');
        await _wi169Focus(tester, _wi169Seg(tester).text.length);

        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Seg(tester).focusedRow, isNull);
        expect(_wi169Seg(tester, 2).focusedRow, 0);

        _wi169Seg(tester, 2).select(const TextSelection.collapsed(offset: 2));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Seg(tester, 2).focusedRow, 1);
        expect(_wi169Caret(tester, 2), 6);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC11: Shift+arrows extend across rows
  // -------------------------------------------------------------------------
  group('Shift arrows across rows (AC11)', () {
    testWidgets(
      'Shift Right from the end of one row extends the selection into the next row',
      (tester) async {
        final body = await _wi169Pump(tester, '- ab\n- cd');
        await _wi169Focus(tester, 4);

        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 7),
        );

        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 8),
        );
        expect(_wi169Seg(tester).text, '- ab\n- cd');
        expect(body.changes, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Down extends the selection to the next row at the nearest x',
      (tester) async {
        await _wi169Pump(tester, '- abcd\n- efgh');
        await _wi169Focus(tester, 4);

        await _wi169Press(tester, LogicalKeyboardKey.arrowDown, shift: true);

        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 11),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Left from a row start and Shift Up from a row first line extend the selection into the previous row',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cd');
        await _wi169Focus(tester, 7);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 7, extentOffset: 4),
        );
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 7, extentOffset: 3),
        );

        await _wi169Focus(tester, 9);
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 9, extentOffset: 4),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Option Right and Shift Cmd Down extend the selection across rows',
      (tester) async {
        const text = '- ab\n- cd ef\n- gh';
        await _wi169Pump(tester, text);
        await _wi169Focus(tester, 4);

        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowRight,
          shift: true,
          alt: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 7),
        );

        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowDown,
          shift: true,
          meta: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: text.length),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC12: the IME keeps its keys while composing
  // -------------------------------------------------------------------------
  group('keys while composing (AC12)', () {
    testWidgets(
      'Enter and Shift Enter while composing in an item go to the IME and Enter after the commit splits it',
      (tester) async {
        await _wi169Pump(tester, '- ab');
        await _wi169Focus(tester, 4);
        await tester.macCompose('abか', const TextRange(start: 2, end: 3));
        expect(_wi169Seg(tester).text, '- abか');

        for (final shift in [false, true]) {
          final handled = await _wi169Press(
            tester,
            LogicalKeyboardKey.enter,
            shift: shift,
            platform: false,
          );
          expect(handled, isFalse, reason: 'shift $shift goes to the IME');
          expect(_wi169Seg(tester).text, '- abか');
          expect(_wi169Seg(tester).rowCount, 1);
        }

        await tester.macEditingValue('abか');
        await _wi169Press(tester, LogicalKeyboardKey.enter);
        expect(_wi169Seg(tester).text, '- abか\n- ');
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Backspace while composing at an item text start keeps the marker and after the commit removes it',
      (tester) async {
        await _wi169Pump(tester, '- x\nend');
        await _wi169Focus(tester, 3);
        await tester.macEditingValue(
          'か',
          selection: const TextSelection.collapsed(offset: 0),
          composing: const TextRange(start: 0, end: 1),
        );
        expect(_wi169Seg(tester).text, '- か\nend');

        final handled = await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(handled, isFalse, reason: 'Backspace goes to the IME');
        expect(_wi169Seg(tester).text, '- か\nend');

        await tester.macEditingValue(
          'か',
          selection: const TextSelection.collapsed(offset: 0),
        );
        await _wi169Press(tester, LogicalKeyboardKey.backspace);
        expect(_wi169Seg(tester).text, 'か\nend');
        expect(_wi169Caret(tester), 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Delete while composing at an item end joins nothing and after the commit joins the next row',
      (tester) async {
        await _wi169Pump(tester, '- a\n- b');
        await _wi169Focus(tester, 3);
        await tester.macCompose('aか', const TextRange(start: 1, end: 2));
        expect(_wi169Seg(tester).text, '- aか\n- b');

        final handled = await _wi169Press(tester, LogicalKeyboardKey.delete);
        expect(handled, isFalse, reason: 'Delete goes to the IME');
        expect(_wi169Seg(tester).text, '- aか\n- b');

        await tester.macEditingValue('aか');
        await _wi169Press(tester, LogicalKeyboardKey.delete);
        expect(_wi169Seg(tester).text, '- aかb');
      },
      variant: macOnly,
    );

    testWidgets(
      'arrows while composing stay in the row and after the commit cross to the adjacent row',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cd');
        await _wi169Focus(tester, 4);
        await tester.macCompose('abか', const TextRange(start: 2, end: 3));
        expect(_wi169Seg(tester).text, '- abか\n- cd');

        for (final key in [
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowDown,
        ]) {
          final handled = await _wi169Press(tester, key);
          expect(handled, isFalse, reason: '$key goes to the IME');
          expect(_wi169Seg(tester).focusedRow, 0, reason: '$key');
          expect(_wi169Seg(tester).selection.extentOffset, lessThan(6));
        }

        // A composition at the next row text start: Left and Up stay too.
        await _wi169Focus(tester, 8);
        await tester.macEditingValue(
          'かcd',
          selection: const TextSelection.collapsed(offset: 0),
          composing: const TextRange(start: 0, end: 1),
        );
        expect(_wi169Seg(tester).text, '- abか\n- かcd');
        for (final key in [
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowUp,
        ]) {
          final handled = await _wi169Press(tester, key);
          expect(handled, isFalse, reason: '$key goes to the IME');
          expect(_wi169Seg(tester).focusedRow, 1, reason: '$key');
        }

        await tester.macEditingValue(
          'かcd',
          selection: const TextSelection.collapsed(offset: 0),
        );
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_wi169Seg(tester).focusedRow, 0);
        expect(_wi169Caret(tester), 5);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC13: the [[ popover keeps Enter
  // -------------------------------------------------------------------------
  group('the wikilink popover keeps Enter (AC13)', () {
    testWidgets(
      'Enter with the wikilink popover open in an item row accepts the suggestion without splitting and the next Enter splits',
      (tester) async {
        const body = 'Intro line\n- see \nOutro line\n';
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(topicBody: body),
        );
        await r.open(fixtureTopicId);
        await r.focusSegment(0, offset: 'Intro line\n- see '.length);
        for (final typed in ['see [', 'see [[', 'see [[Other']) {
          await tester.macEditingValue(typed);
        }
        await tester.pump();
        expect(r.popover, findsOneWidget);

        await _wi169Press(tester, LogicalKeyboardKey.enter);

        expect(r.popover, findsNothing);
        expect(
          r.segmentText(0),
          'Intro line\n- see [[Other note]]\nOutro line\n',
        );
        expect(r.segment(0).rowCount, 3);
        expect(r.segment(0).focusedRow, 1);

        await _wi169Press(tester, LogicalKeyboardKey.enter);
        expect(
          r.segmentText(0),
          'Intro line\n- see [[Other note]]\n- \nOutro line\n',
        );
        expect(r.segment(0).focusedRow, 2);
        await r.waitForSave();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Contracts the implementer handoff listed as unpinned (verify mode)
  // -------------------------------------------------------------------------
  group('unpinned contracts (verify)', () {
    for (final (name, key, alt, offset, row) in [
      (
        'Left over a selection across rows collapses it to its start in the row it started in',
        LogicalKeyboardKey.arrowLeft,
        false,
        3,
        0,
      ),
      (
        'Right over a selection across rows collapses it to its end and focuses that row',
        LogicalKeyboardKey.arrowRight,
        false,
        8,
        1,
      ),
      (
        'Option Left over a selection across rows collapses it to its start',
        LogicalKeyboardKey.arrowLeft,
        true,
        3,
        0,
      ),
      (
        'Option Right over a selection across rows collapses it to its end',
        LogicalKeyboardKey.arrowRight,
        true,
        8,
        1,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final body = await _wi169Pump(tester, '- ab\n- cd\ne');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 3, extentOffset: 8));
        await tester.pump();

        await _wi169Press(tester, key, alt: alt);

        expect(
          _wi169Seg(tester).selection,
          TextSelection.collapsed(offset: offset),
        );
        expect(_wi169Seg(tester).focusedRow, row);
        expect(
          _wi169FieldSelection(),
          TextSelection.collapsed(offset: offset - (row == 0 ? 2 : 7)),
        );
        expect(_wi169Seg(tester).text, '- ab\n- cd\ne');
        expect(body.changes, isEmpty);
      }, variant: macOnly);
    }

    testWidgets(
      'Left over a selection inside one row collapses it to its start natively',
      (tester) async {
        await _wi169Pump(tester, '- abcd\n- ef');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 3, extentOffset: 5));
        await tester.pump();

        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft);

        expect(_wi169Caret(tester), 3);
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Up and Down over a selection across rows collapse from its start and end and stop at the segment edges',
      (tester) async {
        // Rows: bullet `abcd` text 2..6, `efgh` 9..13, `ijkl` 16..20.
        await _wi169Pump(tester, '- abcd\n- efgh\n- ijkl');
        final third = _wi169RowLines(tester, 2).single;
        final down = _wi169NearestOn(tester, 11, third);
        expect(down, inInclusiveRange(16, 20));

        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 11));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Caret(tester), down);
        expect(_wi169Seg(tester).focusedRow, 2);

        // Over a selection reaching the first line, Up goes to the segment
        // start; reaching the last line, Down goes to the segment end.
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 11, extentOffset: 4));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Caret(tester), 2);
        expect(_wi169Seg(tester).focusedRow, 0);

        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 11, extentOffset: 18));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Caret(tester), 20);
        expect(_wi169Seg(tester).focusedRow, 2);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Down and Shift Up over a selection across rows extend from its extent and stop at the segment edges keeping focus',
      (tester) async {
        await _wi169Pump(tester, '- abcd\n- efgh\n- ijkl');
        final third = _wi169RowLines(tester, 2).single;
        final down = _wi169NearestOn(tester, 11, third);
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 11));
        await tester.pump();

        await _wi169Press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        expect(
          _wi169Seg(tester).selection,
          TextSelection(baseOffset: 4, extentOffset: down),
        );
        expect(_wi169Seg(tester).focusedRow, 0, reason: 'spans rows');

        await _wi169Press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 20),
        );
        expect(_wi169Seg(tester).focusedRow, 0);

        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 11, extentOffset: 4));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 11, extentOffset: 2),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Down over a selection across rows ending at a wrapped line start goes to the line below that line',
      (tester) async {
        await _wi169Pump(tester, '- top\n- $_wi169Long\n- end');
        final lines = _wi169RowLines(tester, 1);
        expect(lines.length, greaterThanOrEqualTo(3));
        final from = lines[1].range.start;
        final expected = _wi169NearestOn(tester, from, lines[2]);
        expect(expected, greaterThanOrEqualTo(lines[2].range.start));

        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(TextSelection(baseOffset: 3, extentOffset: from));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);

        expect(_wi169Caret(tester), expected);
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Up and Down in a single line row with no row beyond move the caret natively to the row text start and end',
      (tester) async {
        await _wi169Pump(tester, '- abcd');
        await _wi169Focus(tester, 4);
        await _wi169Press(tester, LogicalKeyboardKey.arrowUp);
        expect(_wi169Caret(tester), 2);
        await _wi169Press(tester, LogicalKeyboardKey.arrowDown);
        expect(_wi169Caret(tester), 6);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd Left and Cmd Right over a selection across rows collapse to the visual line start of its start and end of its end',
      (tester) async {
        // Rows: bullet `ab cd` text 2..7, bullet `ef gh` text 10..15.
        await _wi169Pump(tester, '- ab cd\n- ef gh');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 12));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, meta: true);
        expect(_wi169Caret(tester), 2);
        expect(_wi169Seg(tester).focusedRow, 0);

        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 12));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, meta: true);
        expect(_wi169Caret(tester), 15);
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd Right over a selection across rows ending at a wrapped line start goes to the end of that line',
      (tester) async {
        await _wi169Pump(tester, '- top\n- $_wi169Long\n- end');
        final lines = _wi169RowLines(tester, 1);
        expect(lines.length, greaterThanOrEqualTo(3));
        final from = lines[1].range.start;

        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(TextSelection(baseOffset: 3, extentOffset: from));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, meta: true);

        final end = _wi169Caret(tester);
        expect(end, greaterThan(from));
        expect(end, lessThanOrEqualTo(lines[1].range.end));
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Cmd Left and Shift Cmd Right over a selection across rows expand it to the visual line edges',
      (tester) async {
        await _wi169Pump(tester, '- ab cd\n- ef gh');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 12, extentOffset: 4));
        await tester.pump();
        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowRight,
          shift: true,
          meta: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 15),
        );
        expect(_wi169Seg(tester).focusedRow, 0, reason: 'spans rows');

        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 12));
        await tester.pump();
        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowLeft,
          shift: true,
          meta: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 12, extentOffset: 2),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Cmd Left inside one row expands natively to the row text start',
      (tester) async {
        await _wi169Pump(tester, '- ab cd\n- ef gh');
        await _wi169Focus(tester, 5);
        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowLeft,
          shift: true,
          meta: true,
        );
        final sel = _wi169Seg(tester).selection;
        expect((sel.start, sel.end), (2, 5));
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Cmd Up over a forward selection across rows expands it from its end to the segment start',
      (tester) async {
        await _wi169Pump(tester, '- ab cd\n- ef gh');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 12));
        await tester.pump();
        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowUp,
          shift: true,
          meta: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 12, extentOffset: 2),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Option Right and Shift Option Left over a selection across rows step by words inside the extent row',
      (tester) async {
        // Rows: bullet `ab` text 2..4, `cdxy ef` text 7..14, `gh` 17..19.
        await _wi169Pump(tester, '- ab\n- cdxy ef\n- gh');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 8));
        await tester.pump();

        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowRight,
          shift: true,
          alt: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 11),
        );

        await _wi169Press(
          tester,
          LogicalKeyboardKey.arrowLeft,
          shift: true,
          alt: true,
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 7),
        );
        expect(_wi169Seg(tester).focusedRow, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Right over a selection across rows steps one character inside the extent row',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cdxy ef');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 8));
        await tester.pump();
        await _wi169Press(tester, LogicalKeyboardKey.arrowRight, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 9),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift Left from a row text start extends into the previous row and keeps focus in the row it started in',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cd');
        await _wi169Focus(tester, 7);
        await _wi169Press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 7, extentOffset: 4),
        );
        expect(_wi169Seg(tester).focusedRow, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'the extend by word intent of other platforms over a selection across rows steps by a word inside the extent row',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cdxy ef');
        await _wi169Focus(tester, 4);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 4, extentOffset: 8));
        await tester.pump();
        await _wi169Invoke(
          tester,
          const ExtendSelectionToNextWordBoundaryIntent(
            forward: true,
            collapseSelection: false,
          ),
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 11),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the extend to document end intent of other platforms keeps the base of a backward selection across rows',
      (tester) async {
        await _wi169Pump(tester, '- ab\n- cd\n- ef');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 8, extentOffset: 3));
        await tester.pump();
        await _wi169Invoke(
          tester,
          const ExtendSelectionToDocumentBoundaryIntent(
            forward: true,
            collapseSelection: false,
          ),
        );
        expect(
          _wi169Seg(tester).selection,
          const TextSelection(baseOffset: 8, extentOffset: 14),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the extend to line end intent of other platforms over a selection across rows extends from its extent to the end of its visual line',
      (tester) async {
        await _wi169Pump(tester, '- $_wi169Long\n- end');
        final rows = _wi169Rows(tester);
        final lines = _wi169RowLines(tester, 0);
        expect(lines.length, greaterThanOrEqualTo(2));
        await _wi169Focus(tester, rows[1].textStart);
        _wi169Seg(tester).select(
          TextSelection(baseOffset: rows[1].textStart + 1, extentOffset: 4),
        );
        await tester.pump();
        await _wi169Invoke(
          tester,
          const ExtendSelectionToLineBreakIntent(
            forward: true,
            collapseSelection: false,
          ),
        );
        final sel = _wi169Seg(tester).selection;
        expect(sel.baseOffset, rows[1].textStart + 1);
        expect(sel.extentOffset, greaterThan(4));
        expect(sel.extentOffset, lessThanOrEqualTo(lines.first.range.end));
        expect(sel.extentOffset, lessThan(rows[0].textEnd));
      },
      variant: macOnly,
    );

    for (final (name, alt, meta) in [
      ('Cmd Enter in an item row does not split it', false, true),
      ('Option Enter in an item row does not split it', true, false),
    ]) {
      testWidgets(name, (tester) async {
        final body = await _wi169Pump(tester, '- ab');
        await _wi169Focus(tester, 3);
        await _wi169Press(
          tester,
          LogicalKeyboardKey.enter,
          alt: alt,
          meta: meta,
          platform: false,
        );
        expect(_wi169Seg(tester).text, '- ab');
        expect(_wi169Seg(tester).rowCount, 1);
        expect(body.changes, isEmpty);
      }, variant: macOnly);
    }

    testWidgets('numpad Enter inside a bullet item splits it like Enter', (
      tester,
    ) async {
      await _wi169Pump(tester, '- ab');
      await _wi169Focus(tester, 3);
      final handled = await _wi169Press(tester, LogicalKeyboardKey.numpadEnter);
      expect(handled, isTrue);
      expect(_wi169Seg(tester).text, '- a\n- b');
      expect(_wi169Caret(tester), 6);
      expect(_wi169Seg(tester).focusedRow, 1);
    }, variant: macOnly);

    testWidgets(
      'Enter with a selection inside one item deletes it then splits the item at its start',
      (tester) async {
        final body = await _wi169Pump(tester, '- abcd');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 3, extentOffset: 5));
        await tester.pump();

        final handled = await _wi169Press(tester, LogicalKeyboardKey.enter);

        expect(handled, isTrue);
        expect(_wi169Seg(tester).text, '- a\n- d');
        expect(_wi169Caret(tester), 6);
        expect(_wi169Seg(tester).focusedRow, 1);
        expect(body.changes.last, '- a\n- d');
      },
      variant: macOnly,
    );

    testWidgets(
      'Enter with a selection inside one prose row leaves the platform newline over it',
      (tester) async {
        await _wi169Pump(tester, 'abcd\n- x');
        await _wi169Focus(tester, 1);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 1, extentOffset: 3));
        await tester.pump();

        final handled = await _wi169Press(tester, LogicalKeyboardKey.enter);

        expect(handled, isFalse);
        expect(_wi169Seg(tester).text, 'a\nd\n- x');
        expect(_wi169Caret(tester), 2);
      },
      variant: macOnly,
    );

    for (final (name, key) in [
      (
        'Backspace with a selection inside one item deletes only it natively and keeps the marker',
        LogicalKeyboardKey.backspace,
      ),
      (
        'Delete with a selection inside one item deletes only it natively and keeps the marker',
        LogicalKeyboardKey.delete,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _wi169Pump(tester, '- abcd\n- ef');
        await _wi169Focus(tester, 3);
        _wi169Seg(
          tester,
        ).select(const TextSelection(baseOffset: 3, extentOffset: 5));
        await tester.pump();

        await _wi169Press(tester, key);

        expect(_wi169Seg(tester).text, '- ad\n- ef');
        expect(_wi169Caret(tester), 3);
        expect(_wi169Seg(tester).focusedRow, 0);
      }, variant: macOnly);
    }

    testWidgets(
      'Backspace at an item text start after a leading frontmatter block removes that item marker',
      (tester) async {
        // Leading frontmatter is one prose row (A1 atSegmentStart): its
        // `- a` line is not an item.
        const text = '---\n- a\n---\n- bc';
        await _wi169Pump(tester, text);
        final rows = _wi169Rows(tester);
        expect(rows.length, 2);
        expect(rows[1].isItem, isTrue);
        await _wi169Focus(tester, rows[1].textStart);

        await _wi169Press(tester, LogicalKeyboardKey.backspace);

        expect(_wi169Seg(tester).text, '---\n- a\n---\nbc');
        expect(_wi169Caret(tester), 12);
      },
      variant: macOnly,
    );
  });
}
