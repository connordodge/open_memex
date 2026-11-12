// WI #438 (Spec #392 req 10, 21; Testing Strategy: opening SpellingMenu,
// menu contents and keyboard): where SpellingMenu opens, what it lists, how
// it looks, its keyboard and its semantics. Its actions are in
// spelling_menu_actions_test.dart.
//
// Keyboard tests never assume which item (if any) is focused when the menu
// opens: Up from the open menu reaches the last enabled item either way
// (from none, or wrapping from the first), so every sequence starts with Up.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart'
    show spellingIssueAtSelection;

import '../../support/app_harness.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/table_harness.dart';
import '../../support/wi438_spelling_menu.dart';

const _prose = 'Good teh day.';
const _grammar = 'He go home.';

FakeSpellingService _withGuesses(List<String> guesses) => FakeSpellingService()
  ..misspell('teh', corrections: const ['zzz'])
  ..scriptGuesses('teh', guesses);

FakeSpellingService _grammarIssue(List<String> corrections) =>
    FakeSpellingService()..flagGrammar(
      'go',
      description: 'Use goes here',
      corrections: corrections,
    );

/// The menu of a caret inside `teh` in [_prose] (live preview).
Future<Wi438Editor> _openSpelling(
  WidgetTester tester,
  List<String> guesses, {
  bool source = false,
  Wi438Actions? actions,
}) async {
  final m = await wi438Pump(
    tester,
    body: _prose,
    source: source,
    spelling: _withGuesses(guesses),
    actions: actions,
  );
  expect(m.spans(_prose), [(wi438Sp, 5, 3)], reason: 'teh is flagged');
  await m.openAtCaret(_prose, 'teh');
  expect(wi438Menu, findsOneWidget, reason: 'SpellingMenu opened');
  return m;
}

/// The menu of a caret inside `go` in [_grammar] (live preview).
Future<Wi438Editor> _openGrammar(
  WidgetTester tester,
  List<String> corrections,
) async {
  final m = await wi438Pump(
    tester,
    body: _grammar,
    spelling: _grammarIssue(corrections),
  );
  expect(m.spans(_grammar), [(wi438Gr, 3, 2)], reason: 'go is flagged');
  await m.openAtCaret(_grammar, 'go');
  expect(wi438Menu, findsOneWidget, reason: 'SpellingMenu opened');
  return m;
}

void _expectSelectedAll(Wi438Editor m, String text) {
  final s = m.segmentSelection;
  expect((s.start, s.end), (0, text.length), reason: 'Select All ran');
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------- contents (AC1-4)

  group('contents (AC1-AC4)', () {
    testWidgets(
      'a spelling issue with guesses lists the first five in checker order then Learn Spelling and Ignore Spelling a divider then Paste and Select All',
      (tester) async {
        final m = await _openSpelling(tester, [
          'ten',
          'the',
          'tea',
          'tech',
          'toe',
          'tel',
        ]);
        expect(wi438Labels(tester), [
          'ten',
          'the',
          'tea',
          'tech',
          'toe',
          'Learn Spelling',
          'Ignore Spelling',
          'Paste',
          'Select All',
        ]);
        wi438ExpectDividerBetween(tester, 'Ignore Spelling', 'Paste');
        expect(
          m.ctrl(_prose).selection,
          const TextSelection.collapsed(offset: 6),
          reason: 'the right click kept the caret',
        );
        final asked = m.spelling.callsFor('guesses');
        expect(asked, isNotEmpty, reason: 'guesses come from the checker');
        final args = asked.last.args;
        final text = args['text']! as String;
        final start = args['start']! as int;
        final length = args['length']! as int;
        expect(text.substring(start, start + length), 'teh');
        expect(args['documentTag'], m.spelling.tags[spellingNoteId]);
      },
      variant: macOnly,
    );

    testWidgets('exactly five guesses are all listed', (tester) async {
      await _openSpelling(tester, ['ten', 'the', 'tea', 'tech', 'toe']);
      expect(wi438Labels(tester).take(6), [
        'ten',
        'the',
        'tea',
        'tech',
        'toe',
        'Learn Spelling',
      ]);
    }, variant: macOnly);

    testWidgets(
      'with no guesses a disabled No Guesses Found comes first and the issue corrections are not offered',
      (tester) async {
        await _openSpelling(tester, const []);
        expect(wi438Labels(tester), [
          'No Guesses Found',
          'Learn Spelling',
          'Ignore Spelling',
          'Paste',
          'Select All',
        ]);
        expect(wi438Item('zzz'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a grammar issue lists its description then three corrections then Ignore Grammar a divider and the clipboard group',
      (tester) async {
        await _openGrammar(tester, ['goes', 'went', 'gone', 'going']);
        expect(wi438Labels(tester), [
          'Use goes here',
          'goes',
          'went',
          'gone',
          'Ignore Grammar',
          'Paste',
          'Select All',
        ]);
        wi438ExpectDividerBetween(tester, 'Ignore Grammar', 'Paste');
      },
      variant: macOnly,
    );

    testWidgets(
      'a grammar issue with exactly three corrections lists all three',
      (tester) async {
        await _openGrammar(tester, ['goes', 'went', 'gone']);
        expect(wi438Labels(tester).take(5), [
          'Use goes here',
          'goes',
          'went',
          'gone',
          'Ignore Grammar',
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'over a selection equal to the flagged word Copy and Cut come before Paste and Select All',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _withGuesses(['ten']),
        );
        await m.rightClickWord(_prose, 'teh');
        expect(
          m.ctrl(_prose).selection,
          const TextSelection(baseOffset: 5, extentOffset: 8),
          reason: 'the right click selected the flagged word',
        );
        expect(wi438Labels(tester), [
          'ten',
          'Learn Spelling',
          'Ignore Spelling',
          'Copy',
          'Cut',
          'Paste',
          'Select All',
        ]);
        wi438ExpectDividerBetween(tester, 'Ignore Spelling', 'Copy');
      },
      variant: macOnly,
    );

    testWidgets('over a caret the menu offers no Copy and no Cut', (
      tester,
    ) async {
      await _openSpelling(tester, ['ten']);
      expect(wi438Item('Copy'), findsNothing);
      expect(wi438Item('Cut'), findsNothing);
      expect(wi438Item('Paste'), findsOneWidget);
      expect(wi438Item('Select All'), findsOneWidget);
    }, variant: macOnly);
  });

  // ------------------------------------------------------ disabled (AC5)

  group('disabled items (AC5)', () {
    testWidgets(
      'No Guesses Found renders in fg3 and an enabled item does not',
      (tester) async {
        await _openSpelling(tester, const []);
        expect(wi438TextColor(tester, 'No Guesses Found'), OmColors.fg3);
        expect(wi438TextColor(tester, 'Learn Spelling'), isNot(OmColors.fg3));
        expect(wi438TextColor(tester, 'Paste'), isNot(OmColors.fg3));
      },
      variant: macOnly,
    );

    testWidgets(
      'a grammar description renders in fg3 and a correction does not',
      (tester) async {
        await _openGrammar(tester, ['goes']);
        expect(wi438TextColor(tester, 'Use goes here'), OmColors.fg3);
        expect(wi438TextColor(tester, 'goes'), isNot(OmColors.fg3));
      },
      variant: macOnly,
    );

    testWidgets(
      'hovering No Guesses Found changes nothing in the menu while the mouse is in or after it leaves',
      (tester) async {
        await _openSpelling(tester, const []);
        final before = wi438PaintLog(tester);
        final mouse = await wi438MouseIn(
          tester,
          tester.getCenter(wi438Item('No Guesses Found')),
        );
        expect(wi438PaintLog(tester), before, reason: 'no hover highlight');
        expect(wi438TextColor(tester, 'No Guesses Found'), OmColors.fg3);
        await wi438MouseOut(tester, mouse);
        expect(wi438PaintLog(tester), before);
      },
      variant: macOnly,
    );

    testWidgets(
      'hovering a grammar description changes nothing in the menu while the mouse is in or after it leaves',
      (tester) async {
        await _openGrammar(tester, ['goes']);
        final before = wi438PaintLog(tester);
        final mouse = await wi438MouseIn(
          tester,
          tester.getCenter(wi438Item('Use goes here')),
        );
        expect(wi438PaintLog(tester), before, reason: 'no hover highlight');
        await wi438MouseOut(tester, mouse);
        expect(wi438PaintLog(tester), before);
      },
      variant: macOnly,
    );

    testWidgets(
      'hovering an enabled item highlights it until the mouse leaves',
      (tester) async {
        await _openSpelling(tester, const ['ten', 'the']);
        final before = wi438PaintLog(tester);
        final mouse = await wi438MouseIn(
          tester,
          tester.getCenter(wi438Item('Ignore Spelling')),
        );
        expect(
          wi438PaintLog(tester),
          isNot(before),
          reason: 'the hovered item is highlighted',
        );
        await wi438MouseOut(tester, mouse);
        expect(
          wi438PaintLog(tester),
          before,
          reason: 'the highlight goes when the mouse leaves',
        );
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------ keyboard (AC6)

  group('keyboard (AC6)', () {
    testWidgets('the menu takes focus when a right click opens it', (
      tester,
    ) async {
      final m = await _openSpelling(tester, const ['ten']);
      expect(wi438MenuHasFocus(), isTrue, reason: 'the menu has focus');
      expect(m.focusNode(_prose).hasPrimaryFocus, isFalse);
    }, variant: macOnly);

    testWidgets(
      'Up from the open menu reaches the last item and Enter activates it',
      (tester) async {
        final m = await _openSpelling(tester, const ['ten', 'the']);
        await wi438Keys(tester, [wi438Up, wi438Enter]);
        await pumpFrames(tester);
        _expectSelectedAll(m, _prose);
        expect(wi438Menu, findsNothing, reason: 'activating closes the menu');
      },
      variant: macOnly,
    );

    testWidgets('Down from the last item wraps to the first suggestion', (
      tester,
    ) async {
      final m = await _openSpelling(tester, const ['ten', 'the']);
      await wi438Keys(tester, [wi438Up, wi438Down, wi438Enter]);
      await pumpFrames(tester);
      expect(m.body, 'Good ten day.');
    }, variant: macOnly);

    testWidgets('Up from the first item wraps to the last', (tester) async {
      final m = await _openSpelling(tester, const ['ten', 'the']);
      await wi438Keys(tester, [wi438Up, wi438Down, wi438Up, wi438Enter]);
      await pumpFrames(tester);
      _expectSelectedAll(m, _prose);
      expect(m.body, _prose);
    }, variant: macOnly);

    testWidgets('Down moves one enabled item at a time', (tester) async {
      final m = await _openSpelling(tester, const ['ten', 'the', 'tea']);
      await wi438Keys(tester, [wi438Up, wi438Down, wi438Down, wi438Enter]);
      await pumpFrames(tester);
      expect(m.body, 'Good the day.');
    }, variant: macOnly);

    testWidgets('Up moves one enabled item at a time', (tester) async {
      final m = await _openSpelling(tester, const ['ten']);
      await wi438Keys(tester, [wi438Up, wi438Up, wi438Enter]);
      await pumpFrames(tester);
      expect(m.body, 'Good t${wi438Clip}eh day.', reason: 'Paste ran');
    }, variant: macOnly);

    testWidgets('Down from the last item skips a disabled No Guesses Found', (
      tester,
    ) async {
      final actions = Wi438Actions();
      await _openSpelling(tester, const [], actions: actions);
      await wi438Keys(tester, [wi438Up, wi438Down, wi438Enter]);
      await pumpFrames(tester);
      expect(actions.learned, ['teh'], reason: 'Learn Spelling ran');
    }, variant: macOnly);

    testWidgets(
      'Up past the first enabled item skips No Guesses Found and wraps to Select All',
      (tester) async {
        final actions = Wi438Actions();
        final m = await _openSpelling(tester, const [], actions: actions);
        // Select All, Paste, Ignore Spelling, Learn Spelling, then wrap.
        await wi438Keys(tester, [
          wi438Up,
          wi438Up,
          wi438Up,
          wi438Up,
          wi438Up,
          wi438Enter,
        ]);
        await pumpFrames(tester);
        _expectSelectedAll(m, _prose);
        expect(actions.learned, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'Down from the last item skips a disabled grammar description to the first correction',
      (tester) async {
        final m = await _openGrammar(tester, ['goes', 'went']);
        await wi438Keys(tester, [wi438Up, wi438Down, wi438Enter]);
        await pumpFrames(tester);
        expect(m.body, 'He goes home.');
      },
      variant: macOnly,
    );

    testWidgets(
      'a held Enter activates the focused item once and a key repeat alone activates nothing',
      (tester) async {
        final actions = Wi438Actions();
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: true,
          spelling: _withGuesses(const []),
          actions: actions,
        );
        await m.placeCaret(_prose, 6);
        // Enter goes down in the body (a plain line: nothing handles it)
        // and stays held while the menu opens.
        await tester.sendKeyDownEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        await m.rightClickCaret(_prose, 6);
        expect(wi438Menu, findsOneWidget);
        await wi438Keys(tester, [wi438Up, wi438Down]);
        await tester.sendKeyRepeatEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        await tester.sendKeyRepeatEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        expect(actions.learned, isEmpty, reason: 'a repeat activates nothing');
        expect(wi438Menu, findsOneWidget);
        await tester.sendKeyUpEvent(wi438Enter, platform: 'macos');
        await tester.pump();

        await tester.sendKeyDownEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        await tester.sendKeyRepeatEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        await tester.sendKeyRepeatEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        await tester.sendKeyUpEvent(wi438Enter, platform: 'macos');
        await pumpFrames(tester);
        expect(actions.learned, ['teh'], reason: 'one press, one learn');
      },
      variant: macOnly,
    );

    testWidgets(
      'two Enter presses in the same frame activate the focused item once',
      (tester) async {
        final actions = Wi438Actions(hold: true);
        await _openSpelling(tester, const [], actions: actions);
        await wi438Keys(tester, [wi438Up, wi438Down]);
        await tester.sendKeyEvent(wi438Enter, platform: 'macos');
        await tester.sendKeyEvent(wi438Enter, platform: 'macos');
        await tester.pump();
        expect(actions.learned, ['teh']);
        await pumpFrames(tester);
        expect(actions.learned, ['teh']);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc closes the menu and returns focus to the row with the caret where it was',
      (tester) async {
        final m = await _openSpelling(tester, const ['ten']);
        expect(m.focusNode(_prose).hasPrimaryFocus, isFalse);
        await wi438Key(tester, wi438Esc);
        await pumpFrames(tester);
        expect(wi438Menu, findsNothing);
        expect(m.focusNode(_prose).hasPrimaryFocus, isTrue);
        expect(
          m.ctrl(_prose).selection,
          const TextSelection.collapsed(offset: 6),
        );
        expect(m.body, _prose);
      },
      variant: macOnly,
    );

    testWidgets(
      'Esc in Source mode returns focus to the body with the flagged word still selected',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: true,
          spelling: _withGuesses(const ['ten']),
        );
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsOneWidget);
        expect(wi438MenuHasFocus(), isTrue);
        await wi438Key(tester, wi438Esc);
        await pumpFrames(tester);
        expect(wi438Menu, findsNothing);
        expect(m.focusNode(_prose).hasPrimaryFocus, isTrue);
        expect(
          m.ctrl(_prose).selection,
          const TextSelection(baseOffset: 5, extentOffset: 8),
        );
      },
      variant: macOnly,
    );
  });

  // ----------------------------------------------------- semantics (AC7)

  group('semantics (AC7)', () {
    testWidgets('every spelling menu item is one button node with its label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final m = await wi438Pump(
        tester,
        body: _prose,
        spelling: _withGuesses(const ['ten', 'the']),
      );
      await m.rightClickWord(_prose, 'teh');
      expect(wi438Menu, findsOneWidget);
      for (final label in [
        'ten',
        'the',
        'Learn Spelling',
        'Ignore Spelling',
        'Copy',
        'Cut',
        'Paste',
        'Select All',
      ]) {
        wi438ExpectButtonNode(
          tester.getSemantics(wi438Item(label)),
          label,
          enabled: true,
        );
      }
      handle.dispose();
    }, variant: macOnly);

    testWidgets('No Guesses Found is one disabled button node', (tester) async {
      final handle = tester.ensureSemantics();
      await _openSpelling(tester, const []);
      wi438ExpectButtonNode(
        tester.getSemantics(wi438Item('No Guesses Found')),
        'No Guesses Found',
        enabled: false,
      );
      handle.dispose();
    }, variant: macOnly);

    testWidgets(
      'every grammar menu item is one button node with its label and the description is disabled',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _openGrammar(tester, ['goes', 'went']);
        wi438ExpectButtonNode(
          tester.getSemantics(wi438Item('Use goes here')),
          'Use goes here',
          enabled: false,
        );
        for (final label in [
          'goes',
          'went',
          'Ignore Grammar',
          'Paste',
          'Select All',
        ]) {
          wi438ExpectButtonNode(
            tester.getSemantics(wi438Item(label)),
            label,
            enabled: true,
          );
        }
        handle.dispose();
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------ opening (AC8-10)

  group('opening (AC8-AC10)', () {
    testWidgets(
      'a right click on a squiggled word in a live preview row opens SpellingMenu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: '$_prose\n\n- item two',
          spelling: _withGuesses(const ['ten']),
        );
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsOneWidget);
        expect(wi438Item('Learn Spelling'), findsOneWidget);
        expect(wi438DefaultMenu, findsNothing, reason: 'in place of it');
        expect(wi438MenuHasFocus(), isTrue);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a squiggled word in Source mode opens SpellingMenu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: '$_prose\n\n- item two',
          source: true,
          spelling: _withGuesses(const ['ten']),
        );
        expect(m.spans(_prose), [(wi438Sp, 5, 3)]);
        await m.rightClickWord(_prose, 'teh');
        expect(wi438Menu, findsOneWidget);
        expect(wi438Item('ten'), findsOneWidget);
        expect(wi438Item('Learn Spelling'), findsOneWidget);
        expect(wi438DefaultMenu, findsNothing, reason: 'in place of it');
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on an unsquiggled word in a live preview row shows the field default menu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _withGuesses(const ['ten']),
        );
        await m.rightClickWord(_prose, 'day');
        expect(wi438Menu, findsNothing);
        expect(wi438DefaultMenu, findsOneWidget);
        expect(wi438AnyText('Copy'), findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on an unsquiggled word in Source mode shows the field default menu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          source: true,
          spelling: _withGuesses(const ['ten']),
        );
        await m.rightClickWord(_prose, 'Good');
        expect(wi438Menu, findsNothing);
        expect(wi438DefaultMenu, findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a squiggled word inside a wider selection shows the field default menu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _withGuesses(const ['ten']),
        );
        // `Good teh`: not collapsed, and not the flagged range.
        await m.select(
          _prose,
          const TextSelection(baseOffset: 0, extentOffset: 8),
        );
        await m.rightClickWord(_prose, 'teh');
        expect(
          m.ctrl(_prose).selection,
          const TextSelection(baseOffset: 0, extentOffset: 8),
          reason: 'the right click landed on the selection',
        );
        expect(wi438Menu, findsNothing);
        expect(wi438DefaultMenu, findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row selection right click shows the existing menu with no spelling items',
      (tester) async {
        // Rows: `Good day.`, `ab`, `teh cd` (list markers are not row text);
        // teh is flagged in row 2.
        const body = 'Good day.\n- ab\n- teh cd';
        final m = await wi438Pump(
          tester,
          body: body,
          spelling: _withGuesses(const ['ten']),
        );
        expect(m.spans('teh cd'), [(wi438Sp, 0, 3)]);
        final segment = segmentEditingAt(tester, 0);
        // From inside `Good` to the end: the focused row is the last one.
        await m.focus('teh cd');
        segment.select(TextSelection(baseOffset: 2, extentOffset: body.length));
        await tester.pump();
        await m.rightClickWord('teh cd', 'teh');
        expect(
          m.segmentSelection,
          TextSelection(baseOffset: 2, extentOffset: body.length),
          reason: 'the selection still spans rows',
        );
        expect(wi438Menu, findsNothing);
        expect(wi438AnyText('Copy'), findsOneWidget);
        expect(wi438AnyText('Cut'), findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
        expect(wi438AnyText('Ignore Spelling'), findsNothing);
        expect(wi438AnyText('ten'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row selection ending exactly after the flagged word right click shows the existing menu with no spelling items',
      (tester) async {
        // The focused row `teh cd` sees the selection as 0..3, equal to the
        // flagged range, while the segment selection starts in row 0.
        const body = 'Good day.\n- ab\n- teh cd';
        final m = await wi438Pump(
          tester,
          body: body,
          spelling: _withGuesses(const ['ten']),
        );
        expect(m.spans('teh cd'), [(wi438Sp, 0, 3)]);
        final segment = segmentEditingAt(tester, 0);
        await m.focus('teh cd');
        final end = body.indexOf('teh') + 3;
        segment.select(TextSelection(baseOffset: 2, extentOffset: end));
        await tester.pump();
        await m.rightClickWord('teh cd', 'teh');
        expect(
          m.ctrl('teh cd').selection,
          const TextSelection(baseOffset: 0, extentOffset: 3),
          reason: 'the focused row sees exactly the flagged range',
        );
        // The field's own menu (not the pointer layer's) offers no issue.
        expect(
          spellingIssueAtSelection(
            tester.state<EditableTextState>(m.field('teh cd')),
          ),
          isNull,
        );
        expect(
          m.segmentSelection,
          TextSelection(baseOffset: 2, extentOffset: end),
          reason: 'the selection still spans rows',
        );
        expect(wi438Menu, findsNothing);
        expect(wi438AnyText('Copy'), findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
        expect(wi438AnyText('ten'), findsNothing);
      },
      variant: macOnly,
    );

    const table =
        'Intro line\n| A | B |\n| --- | --- |\n| teh | ok |\nBelow line';

    /// Checks the table once (revealed), then renders it again with the
    /// caret in the intro row.
    Future<Wi438Editor> pumpTableChecked(WidgetTester tester) async {
      final m = await wi438Pump(
        tester,
        body: table,
        spelling: _withGuesses(const ['ten', 'the']),
      );
      final segment = segmentEditingAt(tester, 0);
      await tester.showKeyboard(tableRowField(0, 1));
      await tester.pump();
      segment.select(TextSelection.collapsed(offset: table.indexOf('teh') + 1));
      await m.e.advance(const Duration(seconds: 1));
      await m.e.advance(const Duration(seconds: 1));
      await tester.showKeyboard(tableRowField(0, 0));
      await tester.pump();
      segment.select(const TextSelection.collapsed(offset: 2));
      await m.e.advance(const Duration(seconds: 1));
      expectTableRendered(0, 1);
      return m;
    }

    /// The global centre of the rendered glyph at segment [offset].
    Offset gridGlyph(WidgetTester tester, int offset) {
      final segment = segmentEditingAt(tester, 0);
      final a = segment.rectForOffset(offset);
      final b = segment.rectForOffset(offset + 1);
      return Offset((a.left + b.left) / 2, a.center.dy);
    }

    testWidgets(
      'a right click on a squiggled word in a rendered table grid opens SpellingMenu over a caret',
      (tester) async {
        await pumpTableChecked(tester);
        await wi438RightClick(
          tester,
          gridGlyph(tester, table.indexOf('teh') + 1),
        );
        expect(segmentEditingAt(tester, 0).selection.isCollapsed, isTrue);
        expect(wi438Menu, findsOneWidget);
        expect(wi438Labels(tester), [
          'ten',
          'the',
          'Learn Spelling',
          'Ignore Spelling',
          'Paste',
          'Select All',
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on an unsquiggled word in a rendered table grid shows the existing menu',
      (tester) async {
        await pumpTableChecked(tester);
        await wi438RightClick(
          tester,
          gridGlyph(tester, table.indexOf('ok') + 1),
        );
        expect(wi438Menu, findsNothing);
        expect(wi438AnyText('Paste'), findsOneWidget);
        expect(wi438AnyText('Learn Spelling'), findsNothing);
      },
      variant: macOnly,
    );
  });

  // ---------------------------------- a selection inside a grammar issue (D55)

  group('a selection inside a grammar issue (AC8b, ruling D55)', () {
    // `This are` is the grammar issue 0..8 of the row; `This` is 0..4, `are`
    // is 5..8, the space is 4..5.
    const row = 'This are fine.';
    const rowSource = '$row\n\n- item two';

    FakeSpellingService twoWords() => FakeSpellingService()
      ..flagGrammar(
        'This are',
        description: 'Use these',
        corrections: const ['These are', 'This is'],
      );

    /// Pumps the row (flagged `This are` at 0..8; Source mode with [source]),
    /// selects [selection] and right clicks the glyph of [word] inside it.
    Future<Wi438Editor> rightClickInside(
      WidgetTester tester,
      TextSelection selection,
      String word, {
      bool source = false,
    }) async {
      final m = await wi438Pump(
        tester,
        body: source ? rowSource : row,
        source: source,
        spelling: twoWords(),
      );
      expect(m.spans(row), [(wi438Gr, 0, 8)], reason: 'This are is flagged');
      await m.select(row, selection);
      await m.rightClickWord(row, word);
      expect(
        m.ctrl(row).selection,
        selection,
        reason: 'the right click landed on the selection',
      );
      return m;
    }

    void expectSpellingMenu(WidgetTester tester) {
      expect(wi438Menu, findsOneWidget, reason: 'SpellingMenu opened');
      expect(wi438DefaultMenu, findsNothing, reason: 'in place of the default');
      expect(wi438Labels(tester), contains('Ignore Grammar'));
    }

    void expectDefaultMenu() {
      expect(wi438Menu, findsNothing);
      expect(wi438DefaultMenu, findsOneWidget);
      expect(wi438AnyText('Copy'), findsOneWidget);
      expect(wi438AnyText('Ignore Grammar'), findsNothing);
      expect(wi438AnyText('These are'), findsNothing);
    }

    testWidgets(
      'a right click on the selected word are inside a two word grammar issue opens SpellingMenu',
      (tester) async {
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 8),
          'are',
        );
        expectSpellingMenu(tester);
        expect(wi438Labels(tester), [
          'Use these',
          'These are',
          'This is',
          'Ignore Grammar',
          'Copy',
          'Cut',
          'Paste',
          'Select All',
        ]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on the selected word This inside a two word grammar issue opens SpellingMenu',
      (tester) async {
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 0, extentOffset: 4),
          'This',
        );
        expectSpellingMenu(tester);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a selection equal to the grammar issue still opens SpellingMenu',
      (tester) async {
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 0, extentOffset: 8),
          'are',
        );
        expectSpellingMenu(tester);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a backwards selection of are inside the grammar issue opens SpellingMenu',
      (tester) async {
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 8, extentOffset: 5),
          'are',
        );
        expectSpellingMenu(tester);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a selection running past the end of the grammar issue shows the field default menu',
      (tester) async {
        final m = await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 10),
          'are',
        );
        expectDefaultMenu();
        expect(
          spellingIssueAtSelection(
            tester.state<EditableTextState>(m.field(row)),
          ),
          isNull,
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a selection ending one character past the grammar issue shows the field default menu',
      (tester) async {
        // One past the range end: pins the end edge from the other side.
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 0, extentOffset: 9),
          'are',
        );
        expectDefaultMenu();
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a selection starting before the grammar issue shows the field default menu',
      (tester) async {
        // `So This are fine.`: the issue is 3..11; the selection is 1..6.
        final m = await wi438Pump(
          tester,
          body: 'So This are fine.',
          spelling: twoWords(),
        );
        expect(m.spans('So This'), [(wi438Gr, 3, 8)]);
        const selection = TextSelection(baseOffset: 1, extentOffset: 6);
        await m.select('So This', selection);
        await m.rightClickWord('So This', 'This');
        expect(m.ctrl('So This').selection, selection);
        expectDefaultMenu();
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a selection inside a spelling issue but not equal to it shows the field default menu',
      (tester) async {
        final m = await wi438Pump(
          tester,
          body: _prose,
          spelling: _withGuesses(const ['ten']),
        );
        expect(m.spans(_prose), [(wi438Sp, 5, 3)]);
        // `te` of teh (5..7) and `eh` (6..8): inside it, not equal to it.
        for (final selection in const [
          TextSelection(baseOffset: 5, extentOffset: 7),
          TextSelection(baseOffset: 6, extentOffset: 8),
        ]) {
          await m.select(_prose, selection);
          await m.rightClickWord(_prose, 'teh');
          expect(m.ctrl(_prose).selection, selection);
          expect(wi438Menu, findsNothing, reason: '$selection');
          expect(wi438DefaultMenu, findsOneWidget, reason: '$selection');
          expect(wi438AnyText('Learn Spelling'), findsNothing);
          await tester.tapAt(const Offset(2, 2));
          await pumpFrames(tester);
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'choosing a correction after a right click on the word are replaces the whole grammar issue in one undo step',
      (tester) async {
        final m = await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 8),
          'are',
        );
        await m.choose('These are');
        expect(wi438Menu, findsNothing, reason: 'choosing closes the menu');
        expect(m.body, 'These are fine.', reason: 'range 0..8 replaced');
        await m.focus('These are');
        await m.undo();
        await pumpFrames(tester);
        expect(m.body, row, reason: 'one undo restores the whole range');
      },
      variant: macOnly,
    );

    testWidgets(
      'choosing a correction after a right click on the word This replaces the whole grammar issue in one undo step',
      (tester) async {
        final m = await rightClickInside(
          tester,
          const TextSelection(baseOffset: 0, extentOffset: 4),
          'This',
        );
        await m.choose('This is');
        expect(m.body, 'This is fine.', reason: 'range 0..8 replaced');
        await m.focus('This is');
        await m.undo();
        await pumpFrames(tester);
        expect(m.body, row);
      },
      variant: macOnly,
    );

    testWidgets(
      'Ignore Grammar after a right click on the word are ignores the whole grammar issue',
      (tester) async {
        final m = await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 8),
          'are',
        );
        await m.choose('Ignore Grammar');
        expect(wi438Menu, findsNothing);
        expect(m.spans(row), isEmpty, reason: 'the whole issue is ignored');
        expect(m.body, row, reason: 'the text is untouched');
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode a right click on the selected word are inside a grammar issue opens SpellingMenu and a correction replaces the whole range',
      (tester) async {
        final m = await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 8),
          'are',
          source: true,
        );
        expectSpellingMenu(tester);
        await m.choose('These are');
        expect(m.body, 'These are fine.\n\n- item two');
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode a right click on a selection running past the grammar issue shows the field default menu',
      (tester) async {
        await rightClickInside(
          tester,
          const TextSelection(baseOffset: 5, extentOffset: 10),
          'are',
          source: true,
        );
        expectDefaultMenu();
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection inside the grammar issue that runs into another live preview row shows the field default menu',
      (tester) async {
        // Rows `Good day.` and `This are fine.`: the segment selection runs
        // from row 0 to the end of `This`, so the focused row sees 0..4, wholly
        // inside the issue, while the segment selection spans past the row.
        const body = 'Good day.\n- This are fine.';
        final m = await wi438Pump(tester, body: body, spelling: twoWords());
        expect(m.spans(row), [(wi438Gr, 0, 8)]);
        final segment = segmentEditingAt(tester, 0);
        await m.focus(row);
        final end = body.indexOf('This') + 4;
        segment.select(TextSelection(baseOffset: 2, extentOffset: end));
        await tester.pump();
        await m.rightClickWord(row, 'This');
        expect(
          m.ctrl(row).selection,
          const TextSelection(baseOffset: 0, extentOffset: 4),
          reason: 'the focused row sees a selection inside the issue',
        );
        expect(
          spellingIssueAtSelection(
            tester.state<EditableTextState>(m.field(row)),
          ),
          isNull,
        );
        expect(
          m.segmentSelection,
          TextSelection(baseOffset: 2, extentOffset: end),
          reason: 'the selection still spans rows',
        );
        expectDefaultMenu();
      },
      variant: macOnly,
    );
  });
}
