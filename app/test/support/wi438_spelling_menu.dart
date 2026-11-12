// WI #438 (Spec #392 req 10, 11, 12, 13b, 21): helpers of the SpellingMenu
// tests (test/widgets/editor/spelling_menu_test.dart and
// spelling_menu_actions_test.dart). Private to WI #438's tests.
//
// Every test pumps the real note editor through `pumpSpellingEditor` (live
// preview rows or Source mode's field) with a FakeSpellingService and a fake
// macOS pasteboard, and runs under macOS ([macOnly]): a right click on macOS
// selects the word under it unless it lands on the selection (a caret
// included), as `TextSelectionGestureDetectorBuilder.onSecondaryTap` does.
//
// The menu is found by its type ([wi438Menu]) and its items by their text
// ([wi438Item]); its item order is the vertical order of its texts. Its
// divider is a [Divider], an [OmHairline] or a widget keyed
// `spelling-menu-divider`.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoDesktopTextSelectionToolbar;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart'
    show EditorPage;
import 'package:open_memex_app/src/widgets/note_editor.dart';

import 'app_harness.dart';
import 'fake_spelling_service.dart';
import 'mac_editing.dart';
import 'segment_editing_finder.dart';
import 'spelling_editor_pump.dart';

typedef Wi438Span = (SpellIssueKind, int, int);

const wi438Sp = SpellIssueKind.spelling;
const wi438Gr = SpellIssueKind.grammar;

/// What the pasteboard holds when a test starts.
const wi438Clip = 'clip';

/// A [LearnedWordsActions] that records every call. `learn` answers
/// [result], or (with [hold]) waits until the test completes it.
class Wi438Actions implements LearnedWordsActions {
  Wi438Actions({this.result = false, this.hold = false});

  final bool result;
  final bool hold;

  final List<String> learned = [];
  final List<String> unlearned = [];
  final List<Completer<bool>> pending = [];

  @override
  Future<bool> learn(String word) {
    learned.add(word);
    if (!hold) return Future.value(result);
    final c = Completer<bool>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<bool> unlearn(String word) async {
    unlearned.add(word);
    return result;
  }
}

/// The SpellingMenu on screen.
final Finder wi438Menu = find.byType(SpellingMenu);

/// The SpellingMenu text reading exactly [label].
Finder wi438Item(String label) => find.descendant(
  of: wi438Menu,
  matching: find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == label,
    description: 'menu text "$label"',
  ),
);

/// Any widget under the editor or its menus reading exactly [label] (the
/// field's default menu or the selection ops menu included).
Finder wi438AnyText(String label) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText() == label,
  description: 'text "$label"',
);

/// The field's default context menu (macOS: Cupertino desktop toolbar).
final Finder wi438DefaultMenu = find.byType(
  CupertinoDesktopTextSelectionToolbar,
);

/// The texts of the SpellingMenu, top to bottom.
List<String> wi438Labels(WidgetTester tester) {
  final entries = <(Offset, String)>[];
  for (final e
      in find
          .descendant(of: wi438Menu, matching: find.byType(RichText))
          .evaluate()) {
    final box = e.renderObject! as RenderBox;
    entries.add((
      box.localToGlobal(Offset.zero),
      (e.widget as RichText).text.toPlainText(),
    ));
  }
  entries.sort((a, b) {
    final dy = a.$1.dy.compareTo(b.$1.dy);
    return dy != 0 ? dy : a.$1.dx.compareTo(b.$1.dx);
  });
  return [for (final e in entries) e.$2];
}

/// The SpellingMenu's divider(s).
Finder get wi438Divider => find.descendant(
  of: wi438Menu,
  matching: find.byWidgetPredicate(
    (w) =>
        w is Divider ||
        w is OmHairline ||
        w.key == const Key('spelling-menu-divider'),
    description: 'menu divider',
  ),
);

/// Expects one divider line in the menu, below [above]'s text and above
/// [below]'s text.
void wi438ExpectDividerBetween(
  WidgetTester tester,
  String above,
  String below,
) {
  final dividers = wi438Divider.evaluate().toList();
  expect(dividers, isNotEmpty, reason: 'the menu has a divider');
  final top = tester.getRect(wi438Item(above)).bottom;
  final bottom = tester.getRect(wi438Item(below)).top;
  for (final d in dividers) {
    final r = (d.renderObject! as RenderBox).localToGlobal(Offset.zero);
    expect(
      r.dy,
      inInclusiveRange(top, bottom),
      reason: 'the divider sits between "$above" and "$below"',
    );
  }
}

/// The colour [label]'s text is painted in.
Color? wi438TextColor(WidgetTester tester, String label) =>
    tester.renderObject<RenderParagraph>(wi438Item(label)).text.style?.color;

/// Whether the primary focus is in the SpellingMenu: on a node below it, or
/// on a node wrapping it that does not also wrap the note editor.
bool wi438MenuHasFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  final menus = wi438Menu.evaluate().toList();
  if (ctx == null || menus.length != 1) return false;
  final menu = menus.single;
  bool isAncestor(Element ancestor, Element of) {
    var found = false;
    of.visitAncestorElements((a) {
      if (!identical(a, ancestor)) return true;
      found = true;
      return false;
    });
    return found;
  }

  if (identical(ctx, menu) || isAncestor(menu, ctx as Element)) return true;
  if (!isAncestor(ctx, menu)) return false;
  return !find
      .byType(NoteEditor)
      .evaluate()
      .any((editor) => isAncestor(ctx, editor));
}

/// What the menu's overlay entry paints (its own subtree only): every
/// canvas call with its paints' colours, then every text's colour. Equal
/// logs mean nothing in the menu looks different.
List<String> wi438PaintLog(WidgetTester tester) {
  final menu = tester.renderObject(wi438Menu);
  RenderObject root = menu;
  while (root.parent != null &&
      !root.parent.runtimeType.toString().contains('Theater')) {
    root = root.parent!;
  }
  if (root.parent == null) root = menu;
  final canvas = TestRecordingCanvas();
  root.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  String describe(Object? a) => switch (a) {
    final Paint p => 'paint(${p.color}, ${p.style}, ${p.shader != null})',
    ui.Paragraph _ => 'paragraph',
    Path _ => 'path',
    _ => '$a',
  };
  return [
    for (final i in canvas.invocations)
      '${i.invocation.memberName}'
          '(${i.invocation.positionalArguments.map(describe).join(', ')})',
    for (final e
        in find
            .descendant(of: wi438Menu, matching: find.byType(RichText))
            .evaluate())
      'text ${(e.widget as RichText).text.toPlainText()} '
          '${(e.renderObject! as RenderParagraph).text.style?.color}',
  ];
}

/// A mouse added away from the menu and moved onto [at], then pumped.
Future<TestGesture> wi438MouseIn(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  await tester.pump();
  await mouse.moveTo(at);
  await pumpFrames(tester);
  return mouse;
}

/// Moves [mouse] off the menu, pumps and removes it.
Future<void> wi438MouseOut(WidgetTester tester, TestGesture mouse) async {
  await mouse.moveTo(const Offset(1, 1));
  await pumpFrames(tester);
  await mouse.removePointer();
  await tester.pump();
}

/// Sends [key] down and up as macOS delivers it, then pumps.
Future<void> wi438Key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'macos');
  await tester.pump();
}

/// Presses each of [keys] in turn (see [wi438Key]).
Future<void> wi438Keys(
  WidgetTester tester,
  List<LogicalKeyboardKey> keys,
) async {
  for (final k in keys) {
    await wi438Key(tester, k);
  }
}

const wi438Up = LogicalKeyboardKey.arrowUp;
const wi438Down = LogicalKeyboardKey.arrowDown;
const wi438Enter = LogicalKeyboardKey.enter;
const wi438Esc = LogicalKeyboardKey.escape;

/// Expects [node] to be one leaf button node labelled [label]: enabled
/// (with a tap action) or disabled.
void wi438ExpectButtonNode(
  SemanticsNode node,
  String label, {
  required bool enabled,
}) {
  expect(
    node,
    enabled
        ? isSemantics(label: label, isButton: true, hasTapAction: true)
        : isSemantics(
            label: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
    reason: '"$label" is a${enabled ? 'n enabled' : ' disabled'} button',
  );
  expect(node.childrenCount, 0, reason: '"$label" is one leaf node');
}

/// One pumped spelling editor with a fake pasteboard, and its fields.
class Wi438Editor {
  Wi438Editor(this.e, this.clip);

  final SpellingEditorHarness e;
  final MacClipboard clip;

  WidgetTester get tester => e.tester;
  FakeSpellingService get spelling => e.spelling;

  /// The editor field (a live preview row, or Source mode's body) whose text
  /// contains [needle].
  Finder field(String needle) => find.descendant(
    of: e.editor,
    matching: find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text.contains(needle),
      description: 'editor field holding "$needle"',
    ),
  );

  TextEditingController ctrl(String needle) =>
      tester.widget<EditableText>(field(needle)).controller;

  FocusNode focusNode(String needle) =>
      tester.widget<EditableText>(field(needle)).focusNode;

  /// The field-local offset of [word] in the field holding [needle].
  int at(String needle, String word) {
    final i = ctrl(needle).text.indexOf(word);
    if (i < 0) throw TestFailure('"$word" is not in the field of "$needle"');
    return i;
  }

  /// What the editor published for the field holding [needle].
  List<SpellIssue> issues(String needle) {
    final registry = SpellIssueScope.maybeOf(tester.element(field(needle)));
    expect(registry, isNotNull, reason: 'the field has a SpellIssueRegistry');
    return registry!.issuesFor(ctrl(needle)).value;
  }

  List<Wi438Span> spans(String needle) => [
    for (final i in issues(needle)) (i.kind, i.start, i.length),
  ];

  /// The global point of the caret before field offset [offset] (its left
  /// edge, line centre) in the field holding [needle].
  Offset caretPoint(String needle, int offset) {
    final editable = tester
        .state<EditableTextState>(field(needle))
        .renderEditable;
    final r = editable.getLocalRectForCaret(TextPosition(offset: offset));
    return editable.localToGlobal(Offset(r.left, r.center.dy));
  }

  /// The global centre of the glyph at field offset [offset].
  Offset glyphPoint(String needle, int offset) {
    final a = caretPoint(needle, offset);
    final b = caretPoint(needle, offset + 1);
    return Offset((a.dx + b.dx) / 2, a.dy);
  }

  /// Focuses the field holding [needle] and gives it [selection] as the
  /// platform text input does (a click or drag would leave it).
  Future<void> select(String needle, TextSelection selection) async {
    final f = field(needle);
    await tester.showKeyboard(f);
    await tester.pump();
    final text = tester.widget<EditableText>(f).controller.text;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(text: text, selection: selection),
    );
    await pumpFrames(tester);
  }

  /// [select] with the caret at field offset [offset].
  Future<void> placeCaret(String needle, int offset) =>
      select(needle, TextSelection.collapsed(offset: offset));

  /// Focuses the field holding [needle] without moving its selection.
  Future<void> focus(String needle) async {
    focusNode(needle).requestFocus();
    await tester.pump();
    await tester.pump();
  }

  /// A right click on the glyph [word] starts with (its second character)
  /// in the field holding [needle]. Unfocused, or with the caret elsewhere,
  /// it selects [word].
  Future<void> rightClickWord(String needle, String word) =>
      wi438RightClick(tester, glyphPoint(needle, at(needle, word) + 1));

  /// A right click exactly at the caret before field offset [offset]: on a
  /// collapsed selection there, it keeps it.
  Future<void> rightClickCaret(String needle, int offset) =>
      wi438RightClick(tester, caretPoint(needle, offset));

  /// Opens the menu over a caret inside [word] (after its first character),
  /// so the selection stays collapsed.
  Future<void> openAtCaret(String needle, String word) async {
    final offset = at(needle, word) + 1;
    await placeCaret(needle, offset);
    await rightClickCaret(needle, offset);
  }

  /// Taps the menu item [label] and lets its action run.
  Future<void> choose(String label) async {
    await tester.tap(wi438Item(label));
    await pumpFrames(tester);
  }

  /// The body the editor holds (all segments, or Source mode's field).
  String get body => e.bodyText;

  /// The live preview segment 0's selection (segment offsets).
  TextSelection get segmentSelection => segmentEditingAt(tester, 0).selection;

  /// The editor page (header and body; Key `editor-source-surface` in Source
  /// mode).
  Finder get page => find.byType(EditorPage);

  Future<void> undo() => tester.macCmdChord(LogicalKeyboardKey.keyZ);

  Future<void> redo() =>
      tester.macCmdChord(LogicalKeyboardKey.keyZ, shift: true);
}

/// Pumps the note editor on [body] (Source mode with [source]), installs a
/// pasteboard holding [wi438Clip] and lets the first checks come back.
Future<Wi438Editor> wi438Pump(
  WidgetTester tester, {
  required String body,
  bool source = false,
  FakeSpellingService? spelling,
  LearnedWordsActions? actions,
}) async {
  final clip = MacClipboard.install(tester, initial: wi438Clip);
  final e = await pumpSpellingEditor(
    tester,
    body: body,
    source: source,
    spelling: spelling,
    actions: actions,
  );
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
  return Wi438Editor(e, clip);
}

/// A right click (secondary mouse button) at global [at]. The mouse is
/// removed afterwards so it hovers nothing in the menu.
Future<void> wi438RightClick(WidgetTester tester, Offset at) async {
  final mouse = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await tester.pump();
  await mouse.up();
  await tester.pump();
  await mouse.removePointer();
  await pumpFrames(tester);
}
