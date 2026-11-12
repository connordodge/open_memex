// WI #439 (Spec #392 req 3, 20, 21; Testing Strategy: the keyboard and
// Check Document Now): Check Document Now on the focused note editor, in
// live preview rows and in Source mode.
//
// Check Document Now is simulated as the native side sends it:
// `FakeSpellingService.emitCheckDocumentNow()` (E1's stand-in for the
// `checkDocumentNow()` call SpellingMenuController makes on Cmd+;). The
// tests never call into the editor's state: they read what a person sees
// (the selection of the field holding an issue, the SpellingMenu and its
// guesses, the scroll position) and what the checker was asked.
//
// Each issue word has its own scripted guesses (`teh` -> `the`, `wrld` ->
// `world`, `smal` -> `small`), so the menu shown says which issue it is for.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../robots/spelling_robot.dart';
import '../../support/app_harness.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/spelling_editor_pump.dart';

// ------------------------------------------------------------------ bodies

/// Three spelling issues after a clean first line: `teh` and `smal` in prose
/// paragraphs, `wrld` in a list item (its own editor row).
const _wi439Three =
    'Start here.\n\nFirst teh word.\n\n- second wrld item\n\nThird smal line.\n';

/// The fake checker of every test: three misspellings, each with its own
/// guess.
FakeSpellingService _wi439Service() => FakeSpellingService()
  ..misspell('teh', corrections: const ['the'])
  ..misspell('wrld', corrections: const ['world'])
  ..misspell('smal', corrections: const ['small']);

/// The guess the menu of [word]'s issue lists first.
const _wi439Guess = {'teh': 'the', 'wrld': 'world', 'smal': 'small'};

/// A long note whose only issue, `wrld`, is in its last paragraph, far below
/// the first screen.
String _wi439FarBody() =>
    '${[..._wi439Lines(200), 'Far wrld end.'].join('\n\n')}\n';

/// [n] clean one-line paragraphs, `Line <i> is fine.`.
List<String> _wi439Lines(int n) => [
  for (var i = 0; i < n; i++) 'Line $i is fine.',
];

// ---------------------------------------------------------------- harness

/// One pumped note editor (live preview or Source mode) on [body].
class _Wi439Editor {
  _Wi439Editor(this.e);

  final SpellingEditorHarness e;

  WidgetTester get tester => e.tester;
  FakeSpellingService get spelling => e.spelling;
  SegmentedEditorRobot get robot => e.robot;
  bool get source => robot.sourceSurface.evaluate().isNotEmpty;

  /// The editor field (a live preview row, or Source mode's body) whose
  /// text contains [needle].
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

  /// Focuses the field holding [needle] and puts its caret at field offset
  /// [offset], as the platform text input does. The caret is set before the
  /// focus, so focusing never scrolls to wherever the field's caret was.
  Future<void> placeCaret(String needle, int offset) async {
    final f = field(needle);
    ctrl(needle).selection = TextSelection.collapsed(offset: offset);
    await tester.pump();
    await tester.showKeyboard(f);
    await tester.pump();
    final text = tester.widget<EditableText>(f).controller.text;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: offset),
      ),
    );
    await pumpFrames(tester);
  }

  /// Types into the field holding [needle] as the platform text input does:
  /// focuses it and gives it [text] with the caret at [caret].
  Future<void> input(String needle, String text, int caret) async {
    final f = field(needle);
    await tester.showKeyboard(f);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
    await tester.pump();
  }

  /// The note title field (a TextField of the note header, outside the
  /// editor's spell-checked fields).
  Finder get titleField =>
      find.descendant(of: e.editor, matching: find.byType(TextField)).first;

  /// The primary focus node, or null.
  FocusNode? get primaryFocus => FocusManager.instance.primaryFocus;

  /// Whether the title field holds the primary focus.
  bool get titleHasFocus {
    final focus = primaryFocus?.context;
    if (focus == null) return false;
    final title = titleField.evaluate().single;
    if (identical(focus, title)) return true;
    var inside = false;
    focus.visitAncestorElements((a) {
      if (!identical(a, title)) return true;
      inside = true;
      return false;
    });
    return inside;
  }

  /// The native side's `checkDocumentNow()` (Cmd+; through the Spelling
  /// submenu's key equivalent), then frames for the checks, the guesses and
  /// the menu.
  Future<void> checkNow() async {
    spelling.emitCheckDocumentNow();
    await pumpFrames(tester);
    await pumpFrames(tester);
  }

  /// The editor page's vertical scrollable.
  ScrollableState get scrollable => tester.state<ScrollableState>(
    find
        .ancestor(
          of: source ? e.sourceField : e.textSegment(0),
          matching: find.byType(Scrollable),
        )
        .first,
  );

  /// The editor viewport's global top and its height (one screen).
  ({double top, double height}) get viewport {
    final box = scrollable.context.findRenderObject()! as RenderBox;
    return (top: box.localToGlobal(Offset.zero).dy, height: box.size.height);
  }

  /// The global rect of the caret before field offset [offset] of the field
  /// holding [needle].
  Rect caretRect(String needle, int offset) {
    final editable = tester
        .state<EditableTextState>(field(needle))
        .renderEditable;
    final r = editable.getLocalRectForCaret(TextPosition(offset: offset));
    return r.shift(editable.localToGlobal(Offset.zero));
  }

  /// Where field offset [offset] of the field holding [needle] sits from the
  /// viewport's top, in px.
  double relTop(String needle, int offset) =>
      caretRect(needle, offset).top - viewport.top;

  /// Scrolls so field offset [offset] of the field holding [needle] sits
  /// [rel] px below the viewport's top, then lets the viewport checks run.
  Future<void> scrollTo(String needle, int offset, double rel) async {
    final position = scrollable.position;
    position.jumpTo(
      (position.pixels + relTop(needle, offset) - rel).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await e.advance(const Duration(seconds: 1));
    await e.advance(const Duration(seconds: 1));
  }

  /// The texts of every `check` the fake received, in order.
  List<String> get checked => [
    for (final c in spelling.callsFor('check')) c.args['text']! as String,
  ];
}

Future<_Wi439Editor> _wi439Pump(
  WidgetTester tester, {
  required String body,
  bool source = false,
  FakeSpellingService? spelling,
}) async {
  final e = await pumpSpellingEditor(
    tester,
    body: body,
    source: source,
    spelling: spelling ?? _wi439Service(),
  );
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
  return _Wi439Editor(e);
}

// ------------------------------------------------------------------- menu

final Finder _wi439Menu = find.byType(SpellingMenu);

Finder _wi439MenuText(String label) => find.descendant(
  of: _wi439Menu,
  matching: find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == label,
    description: 'menu text "$label"',
  ),
);

/// Whether the primary focus is on the SpellingMenu or below it.
bool _wi439MenuHasFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  final menus = _wi439Menu.evaluate().toList();
  if (ctx == null || menus.length != 1) return false;
  final menu = menus.single;
  if (identical(ctx, menu)) return true;
  var inside = false;
  (ctx as Element).visitAncestorElements((a) {
    if (!identical(a, menu)) return true;
    inside = true;
    return false;
  });
  if (inside) return true;
  // The menu's own Focus wraps it: the focused element is then an ancestor
  // of the menu that is not an ancestor of the note editor's fields.
  var wrapsMenu = false;
  menu.visitAncestorElements((a) {
    if (!identical(a, ctx)) return true;
    wrapsMenu = true;
    return false;
  });
  if (!wrapsMenu) return false;
  final editors = find.byType(EditableText).evaluate();
  for (final ed in editors) {
    var wrapsEditor = false;
    ed.visitAncestorElements((a) {
      if (!identical(a, ctx)) return true;
      wrapsEditor = true;
      return false;
    });
    if (wrapsEditor) return false;
  }
  return true;
}

/// Expects the editor to show exactly one SpellingMenu, for [word] (its
/// guess listed, the other words' guesses not), focused, and the field
/// holding [word] to select exactly [word]'s range.
void _wi439ExpectOn(_Wi439Editor m, String word, {String? reason}) {
  final why = reason ?? 'Check Document Now on $word';
  expect(_wi439Menu, findsOneWidget, reason: '$why: one SpellingMenu');
  for (final MapEntry(key: w, value: guess) in _wi439Guess.entries) {
    expect(
      _wi439MenuText(guess),
      w == word ? findsOneWidget : findsNothing,
      reason: '$why: the menu is for $word',
    );
  }
  final start = m.at(word, word);
  final sel = m.ctrl(word).selection;
  expect(
    (sel.start, sel.end),
    (start, start + word.length),
    reason: '$why: the field selects $word',
  );
  if (!m.source) {
    final segmentStart = m.robot.segmentText(0).indexOf(word);
    if (segmentStart >= 0) {
      final seg = m.robot.segmentSelection(0);
      expect(
        (seg.start, seg.end),
        (segmentStart, segmentStart + word.length),
        reason: '$why: the segment selection is $word',
      );
    }
  }
  expect(_wi439MenuHasFocus(), isTrue, reason: '$why: the menu has focus');
}

// --------------------------------------------------------------- the keys

/// Sends Cmd+; as macOS delivers it to Flutter first (meta held, then the
/// `;` key down and up). Returns whether Flutter handled the `;` key down
/// and its key up.
Future<({bool down, bool up})> _wi439CmdSemicolon(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
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
  return (down: down, up: up);
}

void main() {
  holdFontFetches();

  // A SpellingMenu still open when a test ends stays recorded as the shown
  // context menu (ContextMenuController is static); the next test's menu
  // would then update that stale entry instead of showing. A right click
  // clears it through the field's own toolbar; Check Document Now does not.
  setUp(ContextMenuController.removeAny);

  // ---------------------------------------------------- cycling (AC1)

  group('cycling through issues (AC1)', () {
    for (final (name, source) in [
      (
        'Check Document Now with the caret before three issues selects the first then the next and wraps after the last in live preview',
        false,
      ),
      (
        'Check Document Now with the caret before three issues selects the first then the next and wraps after the last in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(tester, body: _wi439Three, source: source);
        for (final w in ['teh', 'wrld', 'smal']) {
          expect(
            m.issues(w).map((i) => (i.kind, i.start, i.length)),
            contains((SpellIssueKind.spelling, m.at(w, w), w.length)),
            reason: '$w is flagged before Check Document Now',
          );
        }
        await m.placeCaret('Start here.', 0);
        expect(_wi439Menu, findsNothing);

        var guesses = m.spelling.count('guesses');
        for (final (i, word) in [
          'teh',
          'wrld',
          'smal',
          'teh',
          'wrld',
        ].indexed) {
          await m.checkNow();
          _wi439ExpectOn(m, word, reason: 'press ${i + 1}');
          expect(
            m.spelling.count('guesses'),
            guesses + 1,
            reason: 'press ${i + 1} opens the menu once',
          );
          guesses = m.spelling.count('guesses');
        }
        expect(tester.takeException(), isNull);
      }, variant: macOnly);
    }

    testWidgets(
      'Check Document Now from a caret between issues goes to the next issue after the caret and wraps to the top',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439Three);
        // The caret just after `First teh word.`: past teh, before wrld.
        final after = m.at('First teh', 'word.') + 'word.'.length;
        await m.placeCaret('First teh', after);

        for (final word in ['wrld', 'smal', 'teh', 'wrld']) {
          await m.checkNow();
          _wi439ExpectOn(m, word);
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now moves across an excerpt card into the next text segment and wraps back to the first',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start wrld here.\n$fixtureRangeToken\nLater teh line.\n',
        );
        expect(m.robot.card(1), findsOneWidget, reason: 'segment 1 is a card');
        // The caret at the start of text segment 2, before teh.
        await m.placeCaret('Later teh', 0);

        await m.checkNow();
        _wi439ExpectOn(m, 'teh');
        final seg2 = m.robot.segmentSelection(2);
        final tehAt = m.robot.segmentText(2).indexOf('teh');
        expect((seg2.start, seg2.end), (tehAt, tehAt + 3));

        await m.checkNow();
        _wi439ExpectOn(m, 'wrld', reason: 'wraps to the first text segment');

        await m.checkNow();
        _wi439ExpectOn(m, 'teh', reason: 'then on to the later segment');
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now also goes to a grammar issue and opens its menu',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start here.\n\nHe go home.\n',
          spelling: FakeSpellingService()
            ..flagGrammar(
              'go',
              description: 'Use goes here',
              corrections: const ['goes'],
            ),
        );
        await m.placeCaret('Start here.', 0);
        await m.checkNow();

        expect(_wi439Menu, findsOneWidget);
        expect(_wi439MenuText('Use goes here'), findsOneWidget);
        expect(_wi439MenuText('goes'), findsOneWidget);
        final start = m.at('He go', 'go');
        final sel = m.ctrl('He go').selection;
        expect((sel.start, sel.end), (start, start + 2));
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now goes to the spelling issue before the grammar issue that starts at the same offset',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start here.\n\nHe go home.\n',
          spelling: FakeSpellingService()
            ..misspell('go', corrections: const ['going'])
            ..flagGrammar(
              'go',
              description: 'Use goes here',
              corrections: const ['goes'],
            ),
        );
        await m.placeCaret('Start here.', 0);
        await m.checkNow();

        expect(_wi439Menu, findsOneWidget);
        expect(_wi439MenuText('going'), findsOneWidget);
        expect(_wi439MenuText('Use goes here'), findsNothing);
        expect(_wi439MenuText('goes'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc after Check Document Now returns focus to the row holding the issue with the issue selected',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start here.\n\n- second wrld item\n',
        );
        await m.placeCaret('Start here.', 0);
        expect(
          m.field('Start here.').evaluate().single,
          isNot(same(m.field('wrld').evaluate().single)),
          reason: 'the caret row and the issue row are different fields',
        );

        await m.checkNow();
        _wi439ExpectOn(m, 'wrld');

        await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
        await pumpFrames(tester);
        expect(_wi439Menu, findsNothing, reason: 'Esc closed the menu');
        expect(
          m.focusNode('wrld').hasFocus,
          isTrue,
          reason: 'focus is in the row holding wrld',
        );
        final start = m.at('wrld', 'wrld');
        final sel = m.ctrl('wrld').selection;
        expect((sel.start, sel.end), (start, start + 4));
      },
      variant: macOnly,
    );
  });

  // ---------------------- keyboard order: ties, boundaries, held (AC1)

  group('the next issue in order (AC1)', () {
    testWidgets(
      'Check Document Now reaches the grammar issue that starts at the same offset as the spelling issue on the next press and wraps back',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start here.\n\nHe go home.\n',
          spelling: FakeSpellingService()
            ..misspell('go', corrections: const ['going'])
            ..flagGrammar(
              'go home',
              description: 'Fix this phrase',
              corrections: const ['goes home'],
            ),
        );
        await m.placeCaret('Start here.', 0);
        final start = m.at('He go', 'go');

        await m.checkNow();
        expect(_wi439MenuText('going'), findsOneWidget, reason: 'press 1');
        expect(_wi439MenuText('Fix this phrase'), findsNothing);
        var sel = m.ctrl('He go').selection;
        expect((sel.start, sel.end), (start, start + 2));

        await m.checkNow();
        expect(_wi439Menu, findsOneWidget, reason: 'press 2: one menu');
        expect(_wi439MenuText('Fix this phrase'), findsOneWidget);
        expect(_wi439MenuText('going'), findsNothing);
        sel = m.ctrl('He go').selection;
        expect((sel.start, sel.end), (start, start + 7), reason: 'grammar');
        expect(_wi439MenuHasFocus(), isTrue);

        await m.checkNow();
        expect(_wi439MenuText('going'), findsOneWidget, reason: 'wrapped');
        expect(_wi439MenuText('Fix this phrase'), findsNothing);
        sel = m.ctrl('He go').selection;
        expect((sel.start, sel.end), (start, start + 2));
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now reaches a grammar issue that starts inside the selected spelling issue',
      (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'Start here.\n\nA wrld is here.\n',
          spelling: FakeSpellingService()
            ..misspell('wrld', corrections: const ['world'])
            ..flagGrammar(
              'rld is',
              description: 'Inner grammar',
              corrections: const ['rld are'],
            ),
        );
        await m.placeCaret('Start here.', 0);
        final start = m.at('A wrld', 'wrld');

        await m.checkNow();
        expect(_wi439MenuText('world'), findsOneWidget, reason: 'press 1');

        await m.checkNow();
        expect(_wi439MenuText('Inner grammar'), findsOneWidget);
        expect(_wi439MenuText('world'), findsNothing);
        final sel = m.ctrl('A wrld').selection;
        expect((sel.start, sel.end), (start + 1, start + 7));

        await m.checkNow();
        expect(_wi439MenuText('world'), findsOneWidget, reason: 'wrapped');
      },
      variant: macOnly,
    );

    // A caret exactly at an issue's start still selects that issue; one at
    // its end or inside it goes on to the next one.
    for (final (name, offsetIn, word) in [
      (
        'Check Document Now with the caret exactly at the start of an issue selects that issue first',
        0,
        'teh',
      ),
      (
        'Check Document Now with the caret inside an issue goes on to the next issue',
        1,
        'wrld',
      ),
      (
        'Check Document Now with the caret exactly at the end of an issue goes on to the next issue',
        3,
        'wrld',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(tester, body: _wi439Three);
        await m.placeCaret('First teh', m.at('First teh', 'teh') + offsetIn);
        await m.checkNow();
        _wi439ExpectOn(m, word);
      }, variant: macOnly);
    }

    for (final (name, source) in [
      (
        'Check Document Now reaches a misspelling just typed under the caret before its squiggle shows in live preview',
        false,
      ),
      (
        'Check Document Now reaches a misspelling just typed under the caret before its squiggle shows in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(tester, body: 'Good word.', source: source);
        final text = m
            .ctrl('Good word')
            .text
            .replaceFirst('Good word', 'Good teh word');
        await m.input('Good word', text, text.indexOf('teh') + 2);
        await m.e.advance(const Duration(milliseconds: 400));
        await m.e.advance(const Duration(seconds: 1));
        expect(m.checked, contains(text), reason: 'the typed text was checked');
        expect(
          m.issues('Good teh'),
          isEmpty,
          reason: 'the squiggle waits for the caret to leave the word',
        );
        expect(_wi439Menu, findsNothing);

        await m.checkNow();
        _wi439ExpectOn(m, 'teh');
      }, variant: macOnly);
    }

    for (final (name, source) in [
      (
        'Check Document Now reaches a grammar issue in the sentence being typed before its squiggle shows in live preview',
        false,
      ),
      (
        'Check Document Now reaches a grammar issue in the sentence being typed before its squiggle shows in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(
          tester,
          body: 'He go home. Then out.',
          source: source,
          spelling: FakeSpellingService()
            ..flagGrammar(
              'He go',
              description: 'Agreement',
              corrections: const ['He goes'],
            ),
        );
        // The first sentence is still being typed: home -> homes.
        final text = m.ctrl('He go').text.replaceFirst('home.', 'homes.');
        await m.input('He go', text, text.indexOf('homes') + 5);
        expect(m.issues('He go'), isEmpty, reason: 'held while typing');

        await m.checkNow();
        expect(_wi439Menu, findsOneWidget);
        expect(_wi439MenuText('Agreement'), findsOneWidget);
        final sel = m.ctrl('He go').selection;
        expect((sel.start, sel.end), (0, 5));
      }, variant: macOnly);
    }
  });

  // ---------------------------------------- pending checks (req 24)

  group('checks still pending (AC2)', () {
    testWidgets(
      'a second Check Document Now press while the checks are pending moves once and opens one menu',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439FarBody());
        await m.placeCaret('Line 0 is', 0);
        m.spelling.holdReplies = true;
        final guesses = m.spelling.count('guesses');

        m.spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        m.spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        expect(
          m.spelling.held.where((h) => h.text.contains('Far wrld')),
          isNotEmpty,
          reason: 'the far paragraph check is held',
        );
        expect(_wi439Menu, findsNothing, reason: 'nothing before the replies');

        m.spelling.holdReplies = false;
        m.spelling.releaseHeld();
        await pumpFrames(tester);
        await pumpFrames(tester);
        _wi439ExpectOn(m, 'wrld');
        expect(
          m.spelling.count('guesses'),
          guesses + 1,
          reason: 'two presses, one menu',
        );
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'a second Check Document Now press while the first move waits for its frame ends on the second issue with one menu',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439Three);
        await m.placeCaret('Start here.', 0);
        final guesses = m.spelling.count('guesses');

        // The first press selects teh and waits for the frame to open its
        // menu; the second press comes before that frame.
        m.spelling.emitCheckDocumentNow();
        await tester.idle();
        expect(_wi439Menu, findsNothing, reason: 'the first menu waits');
        final sel = m.ctrl('First teh').selection;
        final start = m.at('First teh', 'teh');
        expect((sel.start, sel.end), (start, start + 3), reason: 'moved');
        m.spelling.emitCheckDocumentNow();
        await tester.idle();
        await pumpFrames(tester);
        await pumpFrames(tester);

        _wi439ExpectOn(m, 'wrld');
        expect(
          m.spelling.count('guesses'),
          guesses + 1,
          reason: 'only the last press opens a menu',
        );
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'an edit in the issue paragraph before the move opens no menu and keeps the typed selection',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439FarBody());
        await m.placeCaret('Line 0 is', 0);
        m.spelling.holdReplies = true;
        final guesses = m.spelling.count('guesses');
        m.spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        expect(
          m.spelling.held.where((h) => h.text.contains('Far wrld')),
          isNotEmpty,
        );

        // The replies land; the move to wrld waits for the frame. The text
        // of the issue's paragraph changes before that frame ends.
        m.spelling.holdReplies = false;
        m.spelling.releaseHeld();
        await tester.idle();
        final ctrl = m.ctrl('Far wrld');
        final text = 'Z ${ctrl.text}';
        ctrl.value = TextEditingValue(
          text: text,
          selection: const TextSelection.collapsed(offset: 1),
        );
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(_wi439Menu, findsNothing, reason: 'no menu at stale offsets');
        expect(m.spelling.count('guesses'), guesses, reason: 'no guesses');
        expect(ctrl.text, text);
        expect(
          ctrl.selection,
          const TextSelection.collapsed(offset: 1),
          reason: 'the typed selection stays',
        );
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now stops when the focus left the note editor while the note was being checked',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439FarBody());
        await m.placeCaret('Line 0 is', 3);
        final selection = m.ctrl('Line 0 is').selection;
        m.spelling.holdReplies = true;
        final guesses = m.spelling.count('guesses');
        m.spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        expect(m.spelling.held, isNotEmpty);

        await tester.showKeyboard(m.titleField);
        await tester.pump();
        expect(m.titleHasFocus, isTrue);
        final pixels = m.scrollable.position.pixels;

        m.spelling.holdReplies = false;
        m.spelling.releaseHeld();
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(_wi439Menu, findsNothing, reason: 'no menu');
        expect(m.spelling.count('guesses'), guesses);
        expect(m.titleHasFocus, isTrue, reason: 'the focus stays in the title');
        expect(m.ctrl('Line 0 is').selection, selection, reason: 'no move');
        expect(m.scrollable.position.pixels, pixels, reason: 'no scroll');
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------ focus outside the editor

  group('focus outside the note editor (req 20)', () {
    testWidgets(
      'Check Document Now with the focus in the note title does nothing',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439FarBody());
        await m.placeCaret('Line 0 is', 3);
        final selection = m.ctrl('Line 0 is').selection;
        await tester.showKeyboard(m.titleField);
        await tester.pump();
        expect(m.titleHasFocus, isTrue);
        final pixels = m.scrollable.position.pixels;
        m.spelling.clearCalls();

        await m.checkNow();
        expect(_wi439Menu, findsNothing, reason: 'no menu');
        expect(m.spelling.count('check'), 0, reason: 'nothing was checked');
        expect(m.spelling.count('guesses'), 0, reason: 'no guesses');
        expect(m.titleHasFocus, isTrue, reason: 'the focus stays');
        expect(m.ctrl('Line 0 is').selection, selection, reason: 'no move');
        expect(m.scrollable.position.pixels, pixels, reason: 'no scroll');
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'Check Document Now after the focus left the editor does nothing',
      (tester) async {
        final m = await _wi439Pump(tester, body: _wi439FarBody());
        await m.placeCaret('Line 0 is', 3);
        expect(m.focusNode('Line 0 is').hasFocus, isTrue);
        final selection = m.ctrl('Line 0 is').selection;
        final pixels = m.scrollable.position.pixels;

        m.primaryFocus!.unfocus();
        await pumpFrames(tester);
        expect(m.focusNode('Line 0 is').hasFocus, isFalse);
        m.spelling.clearCalls();

        await m.checkNow();
        expect(_wi439Menu, findsNothing, reason: 'no menu');
        expect(m.spelling.count('check'), 0, reason: 'nothing was checked');
        expect(m.focusNode('Line 0 is').hasFocus, isFalse, reason: 'no focus');
        expect(m.ctrl('Line 0 is').selection, selection, reason: 'no move');
        expect(m.scrollable.position.pixels, pixels, reason: 'no scroll');
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );
  });

  // ----------------------------------------- whole note, viewport (AC2)

  group('the whole note from the caret (AC2)', () {
    for (final (name, paragraphs, sep, pattern) in [
      (
        'Check Document Now checks the unchecked prose paragraphs in order from the caret then wraps to the top',
        _wi439Lines(400),
        '\n\n',
        RegExp(r'Line (\d+) is fine'),
      ),
      (
        'Check Document Now checks the unchecked list item rows in order from the caret then wraps to the top',
        [for (var i = 0; i < 600; i++) '- Item $i is fine.'],
        '\n',
        RegExp(r'Item (\d+) is fine'),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(
          tester,
          body: '${paragraphs.join(sep)}\n',
          spelling: FakeSpellingService(),
        );
        int indexOf(String text) {
          final match = pattern.firstMatch(text);
          if (match == null) throw TestFailure('unexpected check of "$text"');
          return int.parse(match.group(1)!);
        }

        // The caret at the start of a paragraph three quarters down, in view.
        final k = paragraphs.length * 3 ~/ 4;
        final needle = paragraphs[k].replaceFirst('- ', '');
        final offset = m.at(needle, needle);
        await m.placeCaret(needle, offset);
        await m.scrollTo(needle, offset, 0.3 * m.viewport.height);
        expect(
          m.relTop(needle, offset),
          inInclusiveRange(0, m.viewport.height),
          reason: 'the caret paragraph is in view',
        );
        final before = {for (final t in m.checked) indexOf(t)};
        expect(before, contains(k), reason: 'the caret paragraph is checked');
        final unchecked = [
          for (var i = 0; i < paragraphs.length; i++)
            if (!before.contains(i)) i,
        ];
        expect(
          unchecked.where((i) => i > k),
          isNotEmpty,
          reason: 'some paragraphs after the caret are unchecked',
        );
        expect(
          unchecked.where((i) => i < k),
          isNotEmpty,
          reason: 'some paragraphs before the caret are unchecked',
        );

        m.spelling.clearCalls();
        await m.checkNow();
        expect(
          [for (final t in m.checked) indexOf(t)],
          [...unchecked.where((i) => i > k), ...unchecked.where((i) => i < k)],
          reason:
              'every unchecked paragraph once, from the caret to the end, '
              'then from the top',
        );
      });
    }

    for (final (name, source) in [
      (
        'an issue more than two screens below the caret is found selected and scrolled into view in live preview',
        false,
      ),
      (
        'an issue more than two screens below the caret is found selected and scrolled into view in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(
          tester,
          body: _wi439FarBody(),
          source: source,
        );
        await m.placeCaret('Line 0 is', 0);
        final h = m.viewport.height;
        expect(
          m.relTop('Far wrld', m.at('Far wrld', 'wrld')),
          greaterThan(2 * h),
          reason: 'the issue starts more than two screens below',
        );
        expect(
          m.checked.where((t) => t.contains('Far wrld')),
          isEmpty,
          reason: 'its paragraph is not checked yet',
        );

        await m.checkNow();
        expect(
          m.checked.where((t) => t.contains('Far wrld')),
          hasLength(1),
          reason: 'Check Document Now checked it',
        );
        _wi439ExpectOn(m, 'wrld');
        final start = m.at('Far wrld', 'wrld');
        final top = m.relTop('Far wrld', start);
        final bottom = m.caretRect('Far wrld', start).bottom - m.viewport.top;
        expect(top, greaterThanOrEqualTo(0), reason: 'scrolled into view');
        expect(bottom, lessThanOrEqualTo(h), reason: 'scrolled into view');
      }, variant: macOnly);
    }

    testWidgets(
      'an issue more than two screens above the caret is reached by wrapping and scrolled into view',
      (tester) async {
        final lines = _wi439Lines(200);
        final m = await _wi439Pump(
          tester,
          body: '${['Top wrld start.', ...lines].join('\n\n')}\n',
        );
        final last = lines.last;
        await m.placeCaret(last, m.at(last, last));
        await m.scrollTo(last, m.at(last, last), 0.5 * m.viewport.height);
        final h = m.viewport.height;
        expect(
          m.relTop('Top wrld', m.at('Top wrld', 'wrld')),
          lessThan(-2 * h),
          reason: 'the issue is more than two screens above',
        );

        await m.checkNow();
        _wi439ExpectOn(m, 'wrld');
        final top = m.relTop('Top wrld', m.at('Top wrld', 'wrld'));
        expect(top, inInclusiveRange(0, h), reason: 'scrolled into view');
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------ no issues (AC3)

  group('no issues (AC3)', () {
    for (final (name, source) in [
      (
        'with no issues Check Document Now checks the note and changes no selection opens no menu and shows no error in live preview',
        false,
      ),
      (
        'with no issues Check Document Now checks the note and changes no selection opens no menu and shows no error in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final lines = _wi439Lines(200);
        final m = await _wi439Pump(
          tester,
          body: '${lines.join('\n\n')}\n',
          source: source,
          spelling: FakeSpellingService(),
        );
        final sounds = <Object?>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemSound.play') sounds.add(call.arguments);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await m.placeCaret('Line 0 is', 3);
        final selection = m.ctrl('Line 0 is').selection;
        final pixels = m.scrollable.position.pixels;
        final body = m.e.bodyText;
        expect(m.checked.where((t) => t.contains(lines.last)), isEmpty);

        await m.checkNow();
        expect(
          m.checked.where((t) => t.contains(lines.last)),
          hasLength(1),
          reason: 'Check Document Now checked the whole note',
        );
        expect(m.ctrl('Line 0 is').selection, selection, reason: 'no move');
        expect(m.focusNode('Line 0 is').hasFocus, isTrue, reason: 'focus');
        expect(m.scrollable.position.pixels, pixels, reason: 'no scroll');
        expect(m.e.bodyText, body, reason: 'no edit');
        expect(_wi439Menu, findsNothing, reason: 'no menu');
        expect(m.robot.inlineError, findsNothing, reason: 'no error');
        expect(sounds, isEmpty, reason: 'no sound');
        expect(tester.takeException(), isNull);

        // A second press still does nothing.
        await m.checkNow();
        expect(m.ctrl('Line 0 is').selection, selection);
        expect(_wi439Menu, findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: macOnly);
    }
  });

  // ------------------------------------------------------- routing (AC4)

  group('Cmd semicolon routing (AC4)', () {
    for (final (name, source) in [
      (
        'Cmd semicolon in a focused live preview row is not handled by any Flutter handler',
        false,
      ),
      (
        'Cmd semicolon in the focused Source mode field is not handled by any Flutter handler',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _wi439Pump(tester, body: _wi439Three, source: source);
        await m.placeCaret('Start here.', 0);
        final value = m.ctrl('Start here.').value;

        final first = await _wi439CmdSemicolon(tester);
        expect(first.down, isFalse, reason: 'the key down bubbles to the menu');
        expect(first.up, isFalse, reason: 'the key up is not handled either');
        expect(m.ctrl('Start here.').value, value, reason: 'nothing typed');
        expect(m.focusNode('Start here.').hasFocus, isTrue);

        // Unhandled, it reaches the Spelling submenu's key equivalent, which
        // sends checkDocumentNow() to Dart.
        await m.checkNow();
        _wi439ExpectOn(m, 'teh');

        // With the SpellingMenu focused, Cmd+; still reaches the menu bar.
        final again = await m.robot.pressCheckDocumentNow(m.spelling);
        expect(again, isFalse, reason: 'the SpellingMenu leaves it');
        await pumpFrames(tester);
        _wi439ExpectOn(m, 'wrld');
      }, variant: macOnly);
    }
  });
}
