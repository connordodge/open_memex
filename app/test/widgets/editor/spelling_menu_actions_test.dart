// WI #438 (Spec #392 req 11, 12, 13b; Testing Strategy: actions, learn
// failure): what SpellingMenu's items do. A replacement goes through the
// editor's normal edit path (one undo step, saved like typing, the rest of
// the markdown byte-exact); Learn Spelling goes through
// learnedWordsActionsProvider and shows `Could not learn "<word>".` above
// the editor body when it fails; the ignores go through E3's
// SpellCheckController; two activations in one frame run one action.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/inline_error.dart';

import '../../support/app_harness.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi438_spelling_menu.dart';

const _prose = 'Good teh day.';

const _boldBody = 'Intro line.\n\nStart **teh** end.\n\n- item one';
const _boldRow = '**teh**';
const _boldFixed = 'Intro line.\n\nStart **the** end.\n\n- item one';

FakeSpellingService _teh([List<String> guesses = const ['the', 'ten']]) =>
    FakeSpellingService()
      ..misspell('teh', corrections: const ['zzz'])
      ..scriptGuesses('teh', guesses);

const _learnError = 'Could not learn "teh".';

/// Lets the 500 ms undo-history throttle of Source mode's field pass.
Future<void> _undoPause(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

void main() {
  holdFontFetches();

  // -------------------------------------------------- replacement (AC11)

  group('replacing a word (AC11)', () {
    testWidgets(
      'choosing a suggestion for teh inside bold gives the in one undo step with the rest of the body byte identical and saves it',
      (tester) async {
        final m = await wi438Pump(tester, body: _boldBody, spelling: _teh());
        expect(m.spans(_boldRow), isNotEmpty, reason: 'teh is flagged');
        await m.placeCaret(_boldRow, m.at(_boldRow, 'teh') + 1);
        await m.rightClickWord(_boldRow, 'teh');
        expect(wi438Menu, findsOneWidget);

        await m.choose('the');
        expect(wi438Menu, findsNothing, reason: 'choosing closes the menu');
        expect(m.body, _boldFixed);

        await m.e.robot.waitForSave();
        expect(m.e.robot.updates, isNotEmpty, reason: 'saved like typing');
        expect(m.e.robot.updates.last.stdinBody, _boldFixed);

        await m.focus('**the**');
        await m.undo();
        await pumpFrames(tester);
        expect(m.body, _boldBody, reason: 'one undo restores teh');
        await m.redo();
        await pumpFrames(tester);
        expect(m.body, _boldFixed, reason: 'one redo re-applies the');
      },
      variant: macOnly,
    );

    testWidgets(
      'choosing a suggestion in Source mode replaces teh inside bold in one undo step and saves it',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _boldBody,
          source: true,
          spelling: _teh(),
        );
        expect(m.spans(_boldRow), isNotEmpty, reason: 'teh is flagged');
        await m.placeCaret(_boldRow, m.at(_boldRow, 'teh') + 1);
        await _undoPause(tester);
        await m.rightClickWord(_boldRow, 'teh');
        expect(wi438Menu, findsOneWidget);

        await m.choose('the');
        expect(wi438Menu, findsNothing);
        expect(m.body, _boldFixed);

        await m.e.robot.waitForSave();
        expect(m.e.robot.updates.last.stdinBody, _boldFixed);

        await _undoPause(tester);
        await m.focus('**the**');
        await m.undo();
        await pumpFrames(tester);
        expect(m.body, _boldBody, reason: 'one undo restores teh');
        await _undoPause(tester);
        await m.redo();
        await pumpFrames(tester);
        expect(m.body, _boldFixed, reason: 'one redo re-applies the');
      },
      variant: macOnly,
    );

    testWidgets(
      'choosing a grammar correction replaces the flagged range in one undo step',
      (tester) async {
        const body = 'Intro.\n\nHe go home.';
        final m = await wi438Pump(
          tester,
          body: body,
          spelling: FakeSpellingService()
            ..flagGrammar(
              'go',
              description: 'Use goes here',
              corrections: const ['goes', 'went'],
            ),
        );
        expect(m.spans('He go'), isNotEmpty);
        await m.openAtCaret('He go', 'go');
        expect(wi438Menu, findsOneWidget);

        await m.choose('went');
        expect(m.body, 'Intro.\n\nHe went home.');
        await m.focus('He went');
        await m.undo();
        await pumpFrames(tester);
        expect(m.body, body);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------- learn (AC12)

  group('Learn Spelling (AC12)', () {
    testWidgets(
      'Learn Spelling calls learn once with the flagged word and shows no error when it succeeds',
      (tester) async {
        final actions = Wi438Actions(result: true);
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(),
          actions: actions,
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        expect(actions.learned, ['teh']);
        expect(wi438Menu, findsNothing);
        expect(wi438AnyText(_learnError), findsNothing);
        expect(
          m.spelling.count('learn'),
          0,
          reason: 'learnWord runs inside the actions seam, never here',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'when learn fails Could not learn teh shows above the editor body and the squiggle stays',
      (tester) async {
        final actions = Wi438Actions();
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(),
          actions: actions,
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        expect(actions.learned, ['teh'], reason: 'learn is called once');
        expect(m.spelling.count('learn'), 0);

        final error = wi438AnyText(_learnError);
        expect(error, findsOneWidget);
        expect(
          find.ancestor(of: error, matching: find.byType(InlineError)),
          findsOneWidget,
          reason: 'it is an InlineError',
        );
        expect(
          tester.getRect(error).bottom,
          lessThanOrEqualTo(tester.getRect(m.page).top + 0.5),
          reason: 'above the editor body',
        );
        expect(m.spans(_prose), [(wi438Sp, 5, 3)], reason: 'squiggle stays');
        await m.e.advance(const Duration(seconds: 1));
        expect(m.spans(_prose), [(wi438Sp, 5, 3)]);
      },
      variant: macOnly,
    );

    testWidgets(
      'when learn fails in Source mode the error shows above the body too',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: true,
          spelling: _teh(),
          actions: Wi438Actions(),
        );
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Learn Spelling');
        final error = wi438AnyText(_learnError);
        expect(error, findsOneWidget);
        expect(
          tester.getRect(error).bottom,
          lessThanOrEqualTo(tester.getRect(m.page).top + 0.5),
        );
        expect(m.spans(_prose), [(wi438Sp, 5, 3)]);
      },
      variant: macOnly,
    );

    testWidgets('the learn error goes when it is dismissed', (tester) async {
      final m = await wi438Pump(
        tester,
        body: _prose,
        spelling: _teh(),
        actions: Wi438Actions(),
      );
      await m.rightClickWord(_prose, 'teh');
      await m.choose('Learn Spelling');
      final error = wi438AnyText(_learnError);
      expect(error, findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: error, matching: find.byType(InlineError)),
          matching: find.byKey(const Key('inline-error-dismiss')),
        ),
      );
      await pumpFrames(tester);
      expect(wi438AnyText(_learnError), findsNothing);
    }, variant: macOnly);
  });

  // ------------------------------------------------------ ignore (AC13)

  group('ignore (AC13)', () {
    testWidgets(
      'Ignore Spelling hides the squiggle and it stays hidden after a tab switch and return',
      (tester) async {
        final m = await wi438Pump(tester, body: _prose, spelling: _teh());
        expect(m.spans(_prose), [(wi438Sp, 5, 3)]);
        await m.rightClickWord(_prose, 'teh');
        await m.choose('Ignore Spelling');
        expect(wi438Menu, findsNothing);
        expect(m.spans(_prose), isEmpty, reason: 'hidden at once');
        final ignores = m.spelling.callsFor('ignore');
        expect(ignores, hasLength(1));
        expect(ignores.single.args, {
          'word': 'teh',
          'documentTag': m.spelling.tags[spellingNoteId],
        });

        await m.e.robot.open('topic-other');
        await m.e.advance(const Duration(seconds: 1));
        await m.e.robot.open(spellingNoteId);
        await m.e.advance(const Duration(seconds: 1));
        await m.e.advance(const Duration(seconds: 1));
        expect(m.spans(_prose), isEmpty, reason: 'still hidden');
      },
      variant: macOnly,
    );

    testWidgets('Ignore Grammar hides the grammar squiggle', (tester) async {
      final m = await wi438Pump(
        tester,
        body: 'He go home.',
        spelling: FakeSpellingService()
          ..flagGrammar('go', description: 'Use goes here'),
      );
      expect(m.spans('He go'), [(wi438Gr, 3, 2)]);
      await m.openAtCaret('He go', 'go');
      await m.choose('Ignore Grammar');
      expect(wi438Menu, findsNothing);
      expect(m.spans('He go'), isEmpty);
      expect(m.spelling.count('ignore'), 0);
    }, variant: macOnly);
  });

  // -------------------------------------------------- busy guard (AC14)

  group('busy guard (AC14)', () {
    testWidgets(
      'two clicks on Learn Spelling in the same frame call learn once',
      (tester) async {
        final actions = Wi438Actions(hold: true);
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _teh(),
          actions: actions,
        );
        await m.rightClickWord(_prose, 'teh');
        final item = tester.getCenter(wi438Item('Learn Spelling'));
        await tester.tapAt(item);
        await tester.tapAt(item);
        await tester.pump();
        expect(actions.learned, ['teh']);
        actions.pending.first.complete(false);
        await pumpFrames(tester);
        expect(actions.learned, ['teh']);
      },
      variant: macOnly,
    );

    testWidgets(
      'two clicks on Ignore Spelling in the same frame call ignore once',
      (tester) async {
        final m = await wi438Pump(tester, body: _prose, spelling: _teh());
        await m.rightClickWord(_prose, 'teh');
        final item = tester.getCenter(wi438Item('Ignore Spelling'));
        await tester.tapAt(item);
        await tester.tapAt(item);
        await pumpFrames(tester);
        expect(m.spelling.count('ignore'), 1);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------- clipboard group (AC4)

  group('clipboard group (AC4)', () {
    testWidgets('Copy copies the selected flagged word', (tester) async {
      final m = await wi438Pump(tester, body: _prose, spelling: _teh());
      await m.rightClickWord(_prose, 'teh');
      await m.choose('Copy');
      expect(m.clip.writes, ['teh']);
      expect(m.body, _prose);
    }, variant: macOnly);

    testWidgets('Cut copies the selected flagged word and removes it', (
      tester,
    ) async {
      final m = await wi438Pump(tester, body: _prose, spelling: _teh());
      await m.rightClickWord(_prose, 'teh');
      await m.choose('Cut');
      expect(m.clip.writes, ['teh']);
      expect(m.body, 'Good  day.');
    }, variant: macOnly);

    testWidgets('Paste inserts the pasteboard text at the caret', (
      tester,
    ) async {
      final m = await wi438Pump(tester, body: _prose, spelling: _teh());
      await m.openAtCaret(_prose, 'teh');
      await m.choose('Paste');
      expect(m.body, 'Good t${wi438Clip}eh day.');
    }, variant: macOnly);

    testWidgets('Select All selects the whole body', (tester) async {
      final m = await wi438Pump(tester, body: _prose, spelling: _teh());
      await m.openAtCaret(_prose, 'teh');
      await m.choose('Select All');
      final s = m.segmentSelection;
      expect((s.start, s.end), (0, _prose.length));
    }, variant: macOnly);
  });
}
