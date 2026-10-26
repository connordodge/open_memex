// WI #171 (C4) test harness: a pumped SegmentedBody whose text segments are
// editor rows, with helpers to set a cross-row selection, type a key the way
// macOS delivers it (key event first, then the text input's insert), open
// the right-click menu and press Cmd chords. Private to WI #171's tests
// (segment_ops_test.dart, segment_undo_test.dart); mac_editing.dart is
// frozen (D16).
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import 'mac_editing.dart';
import 'segment_editing_finder.dart';

/// `para\n- a|b\n- c|d` without the bars: rows prose `para`, bullet `ab`,
/// bullet `cd` (the WI's AC text).
const wi171Text = 'para\n- ab\n- cd';

/// From after `a` (8) to after `c` (13): `b\n- c`.
const wi171Across = TextSelection(baseOffset: 8, extentOffset: 13);

/// The same range selected backward (the caret after `a`, in row 1).
const wi171AcrossBackward = TextSelection(baseOffset: 13, extentOffset: 8);

Note _wi171Note(String content) => Note(
  id: 'topic-171',
  title: 'Ops',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// A pumped [SegmentedBody] whose content the test can rewrite as a server
/// write would; its `onContentChanged` reports are recorded and fed back as
/// the editor's content, as `EditorController` does.
class Wi171Body {
  Wi171Body(this.tester, this.content, this.changes);

  final WidgetTester tester;
  final ValueNotifier<String> content;

  /// Every joined body `onContentChanged` reported, in order.
  final List<String> changes;

  /// The server's copy of the note changed to [text] (a poll, a merge).
  Future<void> serverWrite(String text) async {
    content.value = text;
    await tester.pump();
    await tester.pump();
  }
}

/// Pumps a note body of [text] in the segmented editor.
Future<Wi171Body> wi171Pump(WidgetTester tester, String text) async {
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
              Expanded(
                child: ListenableBuilder(
                  listenable: content,
                  builder: (context, _) => SegmentedBody(
                    note: _wi171Note(content.value),
                    content: content.value,
                    savedVersion: 3,
                    onContentChanged: (joined) {
                      changes.add(joined);
                      content.value = joined;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return Wi171Body(tester, content, changes);
}

Finder wi171Row(int s, int r) => find.byKey(Key('editor-row-$s-$r'));

Finder wi171FieldOf(int s, int r) =>
    find.descendant(of: wi171Row(s, r), matching: find.byType(EditableText));

LivePreviewController wi171Ctrl(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(wi171FieldOf(s, r)).controller
        as LivePreviewController;

/// How many `editor-row-<s>-<r>` Keys segment [s] shows.
int wi171RowKeys(int s) => find
    .byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          RegExp('^editor-row-$s-\\d+\$').hasMatch(k.value);
    })
    .evaluate()
    .length;

/// Every row text of segment [s], in order.
List<String> wi171Texts(WidgetTester tester, int s) => [
  for (var r = 0; r < wi171RowKeys(s); r++) wi171Ctrl(tester, s, r).text,
];

SegmentViewState wi171View(WidgetTester tester, int s) =>
    tester.state<SegmentViewState>(
      find.descendant(
        of: find.byKey(textSegmentKey(s)),
        matching: find.byType(SegmentView),
      ),
    );

/// Focus row [s]-[r]'s field and put its caret at local [local] (default:
/// the row text's end).
Future<void> wi171FocusRow(
  WidgetTester tester,
  int s,
  int r, {
  int? local,
}) async {
  await tester.showKeyboard(wi171Row(s, r));
  await tester.pump();
  final ctrl = wi171Ctrl(tester, s, r);
  ctrl.selection = TextSelection.collapsed(offset: local ?? ctrl.text.length);
  await tester.pump();
}

/// Focus row [s]-[focus] and select [selection] (segment offsets) in
/// segment [s], as a drag or Shift+arrow would leave it.
Future<void> wi171SelectAcross(
  WidgetTester tester, {
  int s = 0,
  required int focus,
  TextSelection selection = wi171Across,
}) async {
  await wi171FocusRow(tester, s, focus);
  segmentEditingAt(tester, s).select(selection);
  await tester.pump();
  expect(segmentEditingAt(tester, s).selection, selection);
  expect(segmentEditingAt(tester, s).focusedRow, focus);
}

/// The focused field's controller.
TextEditingController wi171FocusedController() {
  final context = FocusManager.instance.primaryFocus?.context;
  final editable = context == null
      ? null
      : context is StatefulElement && context.state is EditableTextState
      ? context.state as EditableTextState
      : context.findAncestorStateOfType<EditableTextState>();
  if (editable == null) throw TestFailure('no text field has focus');
  return editable.widget.controller;
}

/// The logical key that types [ch] (a lowercase letter).
LogicalKeyboardKey _wi171KeyFor(String ch) =>
    LogicalKeyboardKey.findKeyByKeyId(ch.codeUnitAt(0)) ??
    (throw ArgumentError('no key for $ch'));

/// Types [ch] as macOS delivers it: the key down event reaches Flutter
/// first (`FlutterKeyboardManager.mm`), then the text input inserts [ch] at
/// the focused field's selection as it is after the key event, then the key
/// goes up.
Future<void> wi171TypeKey(WidgetTester tester, String ch) async {
  final key = _wi171KeyFor(ch);
  await tester.sendKeyDownEvent(key, platform: 'macos', character: ch);
  await tester.pump();
  final value = wi171FocusedController().value;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  final text = value.text.replaceRange(selection.start, selection.end, ch);
  await tester.macEditingValue(
    text,
    selection: TextSelection.collapsed(offset: selection.start + ch.length),
  );
  await tester.sendKeyUpEvent(key, platform: 'macos');
  await tester.pump();
}

/// The global centre of the glyph at segment [offset] of segment [s].
Offset wi171GlyphCenter(WidgetTester tester, int s, int offset) {
  final handle = segmentEditingAt(tester, s);
  final left = handle.rectForOffset(offset);
  final right = handle.rectForOffset(offset + 1);
  return Offset((left.left + right.left) / 2, left.center.dy);
}

/// A right click (secondary mouse button) at global [at], then pump.
Future<void> wi171RightClick(WidgetTester tester, Offset at) async {
  final mouse = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
}

/// The context menu button labelled [label] (case is ignored: Material says
/// `Select all`, Cupertino `Select All`).
Finder wi171MenuButton(String label) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase() ==
          label.toLowerCase(),
  description: 'menu button "$label"',
);

/// Every text input client change logged since [log] was cleared.
Iterable<MethodCall> wi171ClientChanges(List<MethodCall> log) => log.where(
  (c) =>
      c.method == 'TextInput.setClient' || c.method == 'TextInput.clearClient',
);

/// Cmd+Z.
Future<void> wi171Undo(WidgetTester tester) =>
    tester.macCmdChord(LogicalKeyboardKey.keyZ);

/// Shift+Cmd+Z.
Future<void> wi171Redo(WidgetTester tester) =>
    tester.macCmdChord(LogicalKeyboardKey.keyZ, shift: true);
