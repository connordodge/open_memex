// WI #438 (Spec #392 req 10, 11, 12, 21): contracts of SpellingMenu the
// doc comments promise beyond the AC happy paths: nothing highlighted when
// the menu opens (Enter then closes it like Esc), a grammar issue without a
// description, which selections open the menu, what a replacement leaves,
// dismissals, key repeats, hover onto a disabled item and the opener.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/spell_session_state.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';

import '../../support/app_harness.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi438_spelling_menu.dart';

const _prose = 'Good teh day.';
const _grammar = 'He go home.';
const _desc = 'Use goes here';
const _learnError = 'Could not learn "teh".';

FakeSpellingService _teh(List<String> guesses) => FakeSpellingService()
  ..misspell('teh', corrections: const ['zzz'])
  ..scriptGuesses('teh', guesses);

/// A [LearnedWordsActions] whose `learn` answer a test changes.
class _Wi438Toggle implements LearnedWordsActions {
  bool result = false;
  final List<String> learned = [];

  @override
  Future<bool> learn(String word) async {
    learned.add(word);
    return result;
  }

  @override
  Future<bool> unlearn(String word) async => result;
}

Future<Wi438Editor> _open(
  WidgetTester tester,
  List<String> guesses, {
  bool source = false,
  LearnedWordsActions? actions,
  double? textScale,
}) async {
  final m = await wi438Pump(
    tester,
    body: _prose,
    source: source,
    spelling: _teh(guesses),
    actions: actions,
  );
  if (textScale != null) {
    _scaleText(tester, textScale);
    await pumpFrames(tester);
  }
  expect(m.spans(_prose), [(wi438Sp, 5, 3)], reason: 'teh is flagged');
  await m.openAtCaret(_prose, 'teh');
  expect(wi438Menu, findsOneWidget, reason: 'SpellingMenu opened');
  return m;
}

Future<Wi438Editor> _openGrammar(
  WidgetTester tester, {
  String? description,
  List<String> corrections = const [],
}) async {
  final m = await wi438Pump(
    tester,
    body: _grammar,
    spelling: FakeSpellingService()
      ..flagGrammar('go', description: description, corrections: corrections),
  );
  expect(m.spans(_grammar), [(wi438Gr, 3, 2)], reason: 'go is flagged');
  await m.openAtCaret(_grammar, 'go');
  expect(wi438Menu, findsOneWidget, reason: 'SpellingMenu opened');
  return m;
}

/// The spell session the editor's checker ignores into.
SpellSession _session(Wi438Editor m) => ProviderScope.containerOf(
  m.tester.element(m.e.editor),
).read(spellSessionProvider);

EditableTextState _fieldState(Wi438Editor m, String needle) =>
    m.tester.state<EditableTextState>(m.field(needle));

/// A [FakeSpellingService] whose `guesses` answer waits for the test.
class _Wi438HeldGuesses extends FakeSpellingService {
  final Completer<List<String>> gate = Completer();

  @override
  Future<List<String>> guesses({
    required String text,
    required int start,
    required int length,
    required int documentTag,
  }) {
    super.guesses(
      text: text,
      start: start,
      length: length,
      documentTag: documentTag,
    );
    return gate.future;
  }
}

/// The row of the menu item [label]: the tap target around its text.
Rect _wi438Row(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(of: wi438Item(label), matching: find.byType(GestureDetector))
      .first,
);

/// The lines of every menu text reading [label], and whether each was cut.
List<(int, bool)> _wi438Lines(WidgetTester tester, String label) => [
  for (final p in wi438Item(
    label,
  ).evaluate().map((e) => e.renderObject! as RenderParagraph))
    (
      p
          .getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: label.length),
          )
          .map((b) => b.top.round())
          .toSet()
          .length,
      p.didExceedMaxLines,
    ),
];

/// Sets the text scale. The rest of the app chrome overflows at it (the harness
/// runs at 0.5), so overflows outside the menu are not failures here.
void _scaleText(WidgetTester tester, double scale) {
  final onError = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.toString();
    if (text.contains('overflowed') && !text.contains('spelling_menu.dart')) {
      return;
    }
    onError?.call(details);
  };
  addTearDown(() => FlutterError.onError = onError);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  holdFontFetches();

  group('nothing highlighted when the menu opens', () {
    testWidgets(
      'Enter over an unhighlighted menu runs no action and closes it with the caret restored',
      (tester) async {
        final actions = Wi438Actions();
        final m = await _open(tester, const ['ten'], actions: actions);
        await wi438Key(tester, wi438Enter);
        await pumpFrames(tester);
        expect(wi438Menu, findsNothing, reason: 'Enter closes the menu');
        expect(actions.learned, isEmpty);
        expect(m.spelling.count('ignore'), 0);
        expect(m.body, _prose, reason: 'no suggestion, no paste');
        expect(m.focusNode(_prose).hasPrimaryFocus, isTrue);
        expect(
          m.ctrl(_prose).selection,
          const TextSelection.collapsed(offset: 6),
        );
      },
      variant: macOnly,
    );

    testWidgets('Down from the open menu reaches the first suggestion', (
      tester,
    ) async {
      final m = await _open(tester, const ['ten', 'the']);
      await wi438Keys(tester, [wi438Down, wi438Enter]);
      await pumpFrames(tester);
      expect(m.body, 'Good ten day.');
    }, variant: macOnly);

    testWidgets(
      'Down from the open menu skips a disabled No Guesses Found to Learn Spelling',
      (tester) async {
        final actions = Wi438Actions();
        await _open(tester, const [], actions: actions);
        await wi438Keys(tester, [wi438Down, wi438Enter]);
        await pumpFrames(tester);
        expect(actions.learned, ['teh']);
      },
      variant: macOnly,
    );

    testWidgets('an arrow key repeat moves the highlight like a key press', (
      tester,
    ) async {
      final m = await _open(tester, const ['ten']);
      // Up reaches Select All; its repeat reaches Paste.
      await tester.sendKeyDownEvent(wi438Up, platform: 'macos');
      await tester.pump();
      await tester.sendKeyRepeatEvent(wi438Up, platform: 'macos');
      await tester.pump();
      await tester.sendKeyUpEvent(wi438Up, platform: 'macos');
      await tester.pump();
      await wi438Key(tester, wi438Enter);
      await pumpFrames(tester);
      expect(m.body, 'Good t${wi438Clip}eh day.', reason: 'Paste ran');
    }, variant: macOnly);
  });

  group('grammar issue without a description', () {
    testWidgets(
      'a grammar issue with no description lists no description item',
      (tester) async {
        await _openGrammar(tester, corrections: const ['goes', 'went']);
        expect(wi438Labels(tester), [
          'goes',
          'went',
          'Ignore Grammar',
          'Paste',
          'Select All',
        ]);
        wi438ExpectDividerBetween(tester, 'Ignore Grammar', 'Paste');
      },
      variant: macOnly,
    );

    testWidgets(
      'a grammar issue with neither description nor corrections lists Ignore Grammar and the clipboard group',
      (tester) async {
        await _openGrammar(tester);
        expect(wi438Labels(tester), ['Ignore Grammar', 'Paste', 'Select All']);
      },
      variant: macOnly,
    );

    testWidgets('a grammar issue with a description lists it first', (
      tester,
    ) async {
      await _openGrammar(
        tester,
        description: 'Use goes here',
        corrections: const ['goes'],
      );
      expect(wi438Labels(tester).first, 'Use goes here');
    }, variant: macOnly);
  });

  group('which selections open the menu', () {
    testWidgets(
      'a caret at either end of the flagged word counts and a caret just outside does not',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(const ['ten']),
        );
        final state = _fieldState(m, _prose);
        final expected = {4: false, 5: true, 6: true, 8: true, 9: false};
        for (final e in expected.entries) {
          await m.placeCaret(_prose, e.key);
          expect(
            spellingIssueAtSelection(state) != null,
            e.value,
            reason: 'caret at ${e.key}',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection equal to the flagged word counts and a partial selection does not',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(const ['ten']),
        );
        final state = _fieldState(m, _prose);
        await m.select(
          _prose,
          const TextSelection(baseOffset: 5, extentOffset: 8),
        );
        expect(spellingIssueAtSelection(state)?.length, 3);
        await m.select(
          _prose,
          const TextSelection(baseOffset: 5, extentOffset: 7),
        );
        expect(spellingIssueAtSelection(state), isNull);
        await m.select(
          _prose,
          const TextSelection(baseOffset: 6, extentOffset: 8),
        );
        expect(spellingIssueAtSelection(state), isNull);
      },
      variant: macOnly,
    );

    testWidgets('a spelling issue wins over an overlapping grammar issue', (
      tester,
    ) async {
      final spelling = _teh(const ['ten'])
        ..flagGrammar('teh day', description: 'Odd phrase');
      final m = await wi438Pump(tester, body: _prose, spelling: spelling);
      expect(m.issues(_prose).map((i) => i.kind).toSet(), {wi438Sp, wi438Gr});
      await m.placeCaret(_prose, 6);
      final issue = spellingIssueAtSelection(_fieldState(m, _prose));
      expect(issue?.kind, wi438Sp);
      expect(issue?.length, 3);
    }, variant: macOnly);
  });

  group('what an item leaves', () {
    testWidgets(
      'a suggestion leaves the caret collapsed after the replacement in a live preview row',
      (tester) async {
        final m = await _open(tester, const ['there']);
        await m.choose('there');
        expect(m.body, 'Good there day.');
        expect(m.segmentSelection, const TextSelection.collapsed(offset: 10));
      },
      variant: macOnly,
    );

    testWidgets(
      'a suggestion leaves the caret collapsed after the replacement in Source mode',
      (tester) async {
        final m = await _open(tester, const ['there'], source: true);
        await m.choose('there');
        expect(m.body, 'Good there day.');
        expect(
          m.ctrl('Good there').selection,
          const TextSelection.collapsed(offset: 10),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a suggestion does nothing once the flagged text changed while the menu was open',
      (tester) async {
        final m = await _open(tester, const ['ten'], source: true);
        final ctrl = m.ctrl(_prose);
        ctrl.value = const TextEditingValue(
          text: 'Good xyz day.',
          selection: TextSelection.collapsed(offset: 6),
        );
        await tester.pump();
        await m.choose('ten');
        expect(ctrl.text, 'Good xyz day.');
      },
      variant: macOnly,
    );

    testWidgets(
      'a successful Learn Spelling clears the learn error an earlier failure showed',
      (tester) async {
        final actions = _Wi438Toggle();
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(const ['ten']),
          actions: actions,
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        expect(wi438AnyText(_learnError), findsOneWidget);

        actions.result = true;
        await m.placeCaret(_prose, 0);
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        expect(actions.learned, ['teh', 'teh']);
        expect(wi438AnyText(_learnError), findsNothing);
      },
      variant: macOnly,
    );
  });

  group('opening again', () {
    for (final (name, source) in [
      (
        'a right click on the same flagged word after Esc opens the menu again',
        false,
      ),
      (
        'a right click on the same flagged word after Esc opens the menu again in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: source,
          spelling: _teh(const ['ten']),
        );
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsOneWidget);
        await wi438Key(tester, wi438Esc);
        await pumpFrames(tester);
        expect(wi438Menu, findsNothing);
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsOneWidget, reason: 'the second click opens it');
        expect(wi438Item('ten'), findsOneWidget);
      }, variant: macOnly);
    }
  });

  group('opening again after an action', () {
    for (final (name, source) in [
      (
        'a right click on the same flagged word after a failed Learn Spelling opens the menu again',
        false,
      ),
      (
        'a right click on the same flagged word after a failed Learn Spelling opens the menu again in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: source,
          spelling: _teh(const ['ten']),
          actions: Wi438Actions(),
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        expect(wi438Menu, findsNothing);
        expect(wi438AnyText(_learnError), findsOneWidget);
        await m.rightClickWord(_prose, 'teh');
        expect(
          wi438Menu,
          findsOneWidget,
          reason: 'the squiggle stayed, so the second click opens it',
        );
        expect(wi438Item('ten'), findsOneWidget);
      }, variant: macOnly);
    }

    for (final (name, source) in [
      (
        'a right click on the word after Ignore Spelling shows the field default menu',
        false,
      ),
      (
        'a right click on the word after Ignore Spelling shows the field default menu in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: source,
          spelling: _teh(const ['ten']),
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Ignore Spelling');
        expect(wi438Menu, findsNothing);
        expect(m.spans(_prose), isEmpty, reason: 'the squiggle is gone');
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsNothing, reason: 'no squiggle, no spelling');
        expect(
          wi438DefaultMenu,
          findsOneWidget,
          reason: 'the click reached the field, so focus came back',
        );
      }, variant: macOnly);
    }

    for (final (name, source) in [
      ('focus is back on the field after a suggestion is chosen', false),
      (
        'focus is back on the field after a suggestion is chosen in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: source,
          spelling: _teh(const ['the']),
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('the');
        expect(wi438Menu, findsNothing);
        expect(m.body, 'Good the day.');
        expect(m.focusNode('Good the day.').hasPrimaryFocus, isTrue);
      }, variant: macOnly);
    }
  });

  group('dismissing', () {
    testWidgets(
      'a click outside the menu closes it without running an action',
      (tester) async {
        final actions = Wi438Actions();
        final m = await _open(tester, const ['ten'], actions: actions);
        await tester.tapAt(const Offset(2, 2));
        await pumpFrames(tester);
        expect(wi438Menu, findsNothing);
        expect(actions.learned, isEmpty);
        expect(m.body, _prose);
      },
      variant: macOnly,
    );

    testWidgets('hovering a disabled item clears the highlight a key set', (
      tester,
    ) async {
      final actions = Wi438Actions();
      final m = await _open(tester, const [], actions: actions);
      await wi438Key(tester, wi438Up); // Select All
      final mouse = await wi438MouseIn(
        tester,
        tester.getCenter(wi438Item('No Guesses Found')),
      );
      await wi438Key(tester, wi438Enter);
      await pumpFrames(tester);
      await wi438MouseOut(tester, mouse);
      expect(wi438Menu, findsNothing);
      expect(
        m.segmentSelection,
        const TextSelection.collapsed(offset: 6),
        reason: 'Select All did not run: nothing was highlighted',
      );
      expect(actions.learned, isEmpty);
    }, variant: macOnly);
  });

  group('showSpellingMenu', () {
    testWidgets(
      'it shows the menu for a published issue and refuses one outside the text',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(const ['ten']),
        );
        await m.focus(_prose);
        final state = _fieldState(m, _prose);
        const anchor = Offset(100, 100);

        for (final bad in const [
          SpellIssue(kind: SpellIssueKind.spelling, start: 5, length: 0),
          SpellIssue(kind: SpellIssueKind.spelling, start: -1, length: 3),
          SpellIssue(kind: SpellIssueKind.spelling, start: 11, length: 5),
        ]) {
          bool? shown;
          showSpellingMenu(
            state,
            issue: bad,
            anchor: anchor,
          ).then((v) => shown = v);
          await pumpFrames(tester);
          expect(
            shown,
            isFalse,
            reason: 'start ${bad.start} len ${bad.length}',
          );
          expect(wi438Menu, findsNothing);
        }

        bool? shown;
        showSpellingMenu(
          state,
          issue: m.issues(_prose).single,
          anchor: anchor,
        ).then((v) => shown = v);
        await pumpFrames(tester);
        expect(shown, isTrue);
        expect(wi438Menu, findsOneWidget);
        expect(wi438Item('ten'), findsOneWidget);
        expect(wi438MenuHasFocus(), isTrue);
        await wi438Key(tester, wi438Esc); // leave no menu behind
        await pumpFrames(tester);
      },
      variant: macOnly,
    );

    testWidgets(
      'a newer call wins over one still waiting for its guesses and replaces the menu shown',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(const ['ten']),
        );
        await m.focus(_prose);
        final state = _fieldState(m, _prose);
        final issue = m.issues(_prose).single;
        bool? first;
        bool? second;
        showSpellingMenu(
          state,
          issue: issue,
          anchor: const Offset(100, 100),
        ).then((v) => first = v);
        showSpellingMenu(
          state,
          issue: issue,
          anchor: const Offset(120, 120),
        ).then((v) => second = v);
        await pumpFrames(tester);
        expect(first, isFalse, reason: 'superseded while asking for guesses');
        expect(second, isTrue);
        expect(wi438Menu, findsOneWidget);

        // A later call replaces the menu shown with one fresh menu.
        await wi438Key(tester, wi438Down); // highlight the first item
        showSpellingMenu(
          state,
          issue: issue,
          anchor: const Offset(100, 100),
        ).then((v) => second = v);
        await pumpFrames(tester);
        expect(wi438Menu, findsOneWidget);
        await wi438Key(tester, wi438Enter);
        await pumpFrames(tester);
        expect(m.body, _prose, reason: 'a fresh menu starts unhighlighted');
      },
      variant: macOnly,
    );
  });

  group('menu rows scale with the text size', () {
    testWidgets('a menu row is 24 high at the text size 1', (tester) async {
      await _open(tester, const ['ten', 'the'], textScale: 1);
      for (final label in const ['ten', 'Learn Spelling', 'Select All']) {
        expect(_wi438Row(tester, label).height, 24, reason: label);
      }
    }, variant: macOnly);

    testWidgets('no menu row clips its text at twice the text size', (
      tester,
    ) async {
      await _open(tester, const ['ten', 'the'], textScale: 2);
      for (final label in const ['ten', 'Learn Spelling', 'Select All']) {
        final row = _wi438Row(tester, label);
        final text = tester.getRect(wi438Item(label));
        expect(row.height, greaterThan(24), reason: '$label grows');
        expect(
          row.height,
          greaterThanOrEqualTo(text.height + 4),
          reason: '$label keeps its 2px padding above and below',
        );
      }
    }, variant: macOnly);
  });

  group('a long item', () {
    testWidgets(
      'a grammar description wraps to at most three lines while a correction stays on one',
      (tester) async {
        final long = List.filled(40, 'word').join(' ');
        final m = await wi438Pump(
          tester,
          body: _grammar,
          spelling: FakeSpellingService()
            ..flagGrammar('go', description: long, corrections: [long]),
        );
        _scaleText(tester, 1);
        await pumpFrames(tester);
        await m.openAtCaret(_grammar, 'go');
        expect(wi438Menu, findsOneWidget);
        // The description and the correction read the same text: the first
        // (disabled) wraps, the second (enabled) does not.
        expect(_wi438Lines(tester, long), [
          (3, true),
          (1, true),
        ], reason: 'description first, then correction');
      },
      variant: macOnly,
    );

    testWidgets(
      'a grammar description of a few lines shows whole and its row grows around it',
      (tester) async {
        final desc = List.filled(9, 'word').join(' ');
        final m = await wi438Pump(
          tester,
          body: _grammar,
          spelling: FakeSpellingService()
            ..flagGrammar('go', description: desc, corrections: const ['goes']),
        );
        _scaleText(tester, 1);
        await pumpFrames(tester);
        await m.openAtCaret(_grammar, 'go');
        final (lines, cut) = _wi438Lines(tester, desc).single;
        expect(lines, greaterThan(1), reason: 'wrapped');
        expect(lines, lessThanOrEqualTo(3));
        expect(cut, isFalse, reason: 'shown whole');
        final row = _wi438Row(tester, desc);
        expect(row.height, greaterThan(24));
        expect(
          row.height,
          greaterThanOrEqualTo(tester.getRect(wi438Item(desc)).height + 4),
        );
        expect(_wi438Row(tester, 'goes').height, 24);
      },
      variant: macOnly,
    );
  });

  group('the text changed while the menu was open', () {
    for (final (name, source) in const [
      ('Ignore Spelling does nothing once the flagged text moved', false),
      (
        'Ignore Spelling does nothing once the flagged text moved in Source mode',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final m = await _open(tester, const ['ten'], source: source);
        final ctrl = m.ctrl(_prose);
        ctrl.value = ctrl.value.copyWith(text: 'Hi ${ctrl.text}');
        await tester.pump();
        expect(wi438Menu, findsOneWidget, reason: 'the menu stayed open');
        await m.choose('Ignore Spelling');
        expect(
          m.spelling.count('ignore'),
          0,
          reason: 'nothing was ignored: Hi was never the flagged word',
        );
        expect(m.spelling.ignoredByTag.values.expand((w) => w), isEmpty);
        expect(wi438Menu, findsNothing, reason: 'the item still closes it');
      }, variant: macOnly);
    }

    testWidgets(
      'Ignore Spelling still ignores the flagged word when the text is unchanged',
      (tester) async {
        final m = await _open(tester, const ['ten'], source: true);
        await m.choose('Ignore Spelling');
        expect(m.spelling.callsFor('ignore').single.args['word'], 'teh');
      },
      variant: macOnly,
    );

    testWidgets('Ignore Grammar does nothing once the flagged text moved', (
      tester,
    ) async {
      final m = await _openGrammar(
        tester,
        description: _desc,
        corrections: const ['goes'],
      );
      final ctrl = m.ctrl(_grammar);
      ctrl.value = ctrl.value.copyWith(text: 'Hi ${ctrl.text}');
      await tester.pump();
      expect(wi438Menu, findsOneWidget);
      await m.choose('Ignore Grammar');
      expect(wi438Menu, findsNothing);
      final session = _session(m);
      // Hi He go home.: the old range 3..5 is now He, never flagged.
      for (final text in const ['He', 'go', ' g']) {
        expect(
          session.isGrammarIgnored(spellingNoteId, text, _desc),
          isFalse,
          reason: 'nothing was ignored: $text',
        );
      }
    }, variant: macOnly);

    testWidgets(
      'Ignore Grammar ignores the flagged phrase when the text is unchanged',
      (tester) async {
        final m = await _openGrammar(
          tester,
          description: _desc,
          corrections: const ['goes'],
        );
        await m.choose('Ignore Grammar');
        expect(_session(m).isGrammarIgnored(spellingNoteId, 'go', _desc), true);
        await m.e.advance(const Duration(seconds: 1));
        await m.e.advance(const Duration(seconds: 1));
        expect(m.issues(_grammar).where((i) => i.kind == wi438Gr), isEmpty);
      },
      variant: macOnly,
    );
  });

  group('showSpellingMenu while the guesses are asked for', () {
    testWidgets('it shows nothing when the field text changed meanwhile', (
      tester,
    ) async {
      final held = _Wi438HeldGuesses()
        ..misspell('teh', corrections: const ['zzz']);
      final m = await wi438Pump(tester, body: _prose, spelling: held);
      await m.focus(_prose);
      final state = _fieldState(m, _prose);
      final ctrl = m.ctrl(_prose);
      bool? shown;
      showSpellingMenu(
        state,
        issue: m.issues(_prose).single,
        anchor: const Offset(100, 100),
      ).then((v) => shown = v);
      await tester.pump();
      expect(held.count('guesses'), 1, reason: 'the guesses were asked for');
      ctrl.value = ctrl.value.copyWith(text: 'Hi ${ctrl.text}');
      held.gate.complete(const ['ten']);
      await pumpFrames(tester);
      expect(shown, isFalse);
      expect(wi438Menu, findsNothing);
    }, variant: macOnly);

    testWidgets('it shows nothing when the field is gone meanwhile', (
      tester,
    ) async {
      final held = _Wi438HeldGuesses()
        ..misspell('teh', corrections: const ['zzz']);
      final m = await wi438Pump(tester, body: _prose, spelling: held);
      await m.focus(_prose);
      final state = _fieldState(m, _prose);
      bool? shown;
      showSpellingMenu(
        state,
        issue: m.issues(_prose).single,
        anchor: const Offset(100, 100),
      ).then((v) => shown = v);
      await tester.pump();
      expect(held.count('guesses'), 1);
      await m.e.toggleSource(); // the live preview row field is disposed
      expect(state.mounted, isFalse, reason: 'the row field was disposed');
      held.gate.complete(const ['ten']);
      await pumpFrames(tester);
      expect(shown, isFalse);
      expect(wi438Menu, findsNothing);
    }, variant: macOnly);
  });
}
