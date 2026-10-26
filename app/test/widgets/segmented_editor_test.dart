// WI #27 (A9): the segmented note editor. Text segments, excerpt cards,
// footer chips, the Source toggle, saving through join, focus moves and
// autocomplete in segments. Runs the whole workspace on FakeVaultDb +
// FakeMemexCli (D20); widgets are found by the Spec's TS4 Keys.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/excerpt_cli_fakes.dart';
import '../support/segment_editing_finder.dart';

/// The text field of text segment [i] (one per segment until rows, C1).
Finder _textFieldOf(int i) => find.descendant(
  of: find.byKey(textSegmentKey(i)),
  matching: find.byType(TextField),
);

void main() {
  // -------------------------------------------------------------------------
  // AC2: text segment, excerpt card, text segment
  // -------------------------------------------------------------------------
  group('topic note segments (AC2)', () {
    testWidgets(
      'a topic note with text, a transclusion and more text renders text segment, excerpt card, text segment',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        expect(r.textSegment(0), findsOneWidget);
        expect(r.card(1), findsOneWidget);
        expect(r.textSegment(2), findsOneWidget);
        expect(r.allCards, findsOneWidget);
        expect(r.allTextSegments, findsNWidgets(2));
        expect(r.segmentText(0), 'Intro line\n');
        expect(r.segmentText(2), 'Outro line\n');

        expect(r.top(r.textSegment(0)), lessThan(r.top(r.card(1))));
        expect(r.top(r.card(1)), lessThan(r.top(r.textSegment(2))));
      },
    );

    testWidgets(
      'the excerpt card shows the live text of the referenced blocks',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        expect(
          r.textIn(r.card(1), 'Fixed the jump arc.\n- tried coyote time'),
          findsWidgets,
        );
        expect(r.textIn(r.card(1), 'Sleep was bad.'), findsNothing);
      },
    );

    testWidgets(
      'no text segment holds the transclusion token in the segmented view',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        expect(r.allSegments, hasLength(2));
        for (final segment in r.allSegments) {
          expect(segment.text, isNot(contains('![[')), reason: segment.text);
        }
        for (final text in renderedEditableTexts(
          tester,
          under: find.byType(NoteEditor),
        )) {
          expect(text, isNot(contains('![[')), reason: text);
        }
      },
    );

    testWidgets(
      'a note that starts with a transclusion renders an empty text segment before the card',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: '![[2026-09-05#^c3d4e5]]\nAfter the card\n',
          ),
        );
        await r.open(fixtureTopicId);

        expect(r.segmentText(0), '');
        expect(r.textIn(r.card(1), '- tried coyote time'), findsWidgets);
        expect(r.segmentText(2), 'After the card\n');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: removed stub
  // -------------------------------------------------------------------------
  group('removed excerpt (AC3)', () {
    testWidgets(
      'an excerpt card whose blocks no longer exist shows removed from 2026-09-05',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: 'Intro line\n![[2026-09-05#^zzzzzz]]\nOutro line\n',
          ),
        );
        await r.open(fixtureTopicId);

        expect(r.card(1), findsOneWidget);
        expect(r.textIn(r.card(1), 'removed from 2026-09-05'), findsWidgets);
        expect(r.textIn(r.card(1), 'Fixed the jump arc.'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: caption opens the daily note
  // -------------------------------------------------------------------------
  group('excerpt caption (AC4)', () {
    testWidgets('the excerpt card caption shows the date 2026-09-05', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);

      expect(r.cardCaption(1), findsOneWidget);
      expect(
        find.descendant(of: r.card(1), matching: r.cardCaption(1)),
        findsOneWidget,
      );
      expect(r.textIn(r.cardCaption(1), '2026-09-05'), findsWidgets);
    });

    testWidgets(
      'tapping the excerpt card caption opens the 2026-09-05 daily note as the active tab',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        r.expectActiveNote(fixtureTopicId);

        await r.tapCaption(1);

        r.expectActiveNote(fixtureDailyId);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC5: × calls memex excerpt rm
  // -------------------------------------------------------------------------
  group('excerpt removal (AC5)', () {
    testWidgets(
      'tapping the remove button of a range card calls excerpt rm with both block ids and removes the card',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.tapRemove(1);

        expect(r.excerptRms, hasLength(1));
        final call = r.excerptRms.single;
        expect(call.args.take(2), ['excerpt', 'rm']);
        expect(call.flag('vault'), r.h.vaultPath);
        expect(call.flag('topic-note-id'), fixtureTopicId);
        expect(call.flag('date'), '2026-09-05');
        expect(call.flag('block-ids'), 'b7k2m9,c3d4e5');
        expect(r.allCards, findsNothing);
        expect(r.segmentText(0), startsWith('Intro line\n'));
      },
    );

    testWidgets(
      'tapping the remove button of a single block card calls excerpt rm with one block id',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: 'Intro line\n![[2026-09-05#^b7k2m9]]\nOutro line\n',
          ),
        );
        await r.open(fixtureTopicId);

        await r.tapRemove(1);

        expect(r.excerptRms, hasLength(1));
        expect(r.excerptRms.single.flag('block-ids'), 'b7k2m9');
        expect(r.excerptRms.single.flag('date'), '2026-09-05');
        expect(r.allCards, findsNothing);
      },
    );

    testWidgets(
      'removing the second of two cards sends that card ids and keeps the first card',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody:
                'A\n![[2026-09-05#^b7k2m9]]\nB\n'
                '![[2026-09-05#^c3d4e5..^f6g7h8]]\nC\n',
          ),
        );
        await r.open(fixtureTopicId);
        expect(r.allCards, findsNWidgets(2));
        expect(
          r.textIn(r.card(3), '- tried coyote time\nSleep was bad.'),
          findsWidgets,
        );

        await r.tapRemove(3);

        expect(r.excerptRms.single.flag('block-ids'), 'c3d4e5,f6g7h8');
        expect(r.allCards, findsOneWidget);
        expect(
          r.textIn(find.byType(NoteEditor), 'Fixed the jump arc.'),
          findsWidgets,
        );
        expect(
          r.textIn(find.byType(NoteEditor), 'Sleep was bad.'),
          findsNothing,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC6: failed removal keeps the card and shows an inline error
  // -------------------------------------------------------------------------
  group('failed excerpt removal (AC6)', () {
    testWidgets(
      'when excerpt rm fails the card stays and an inline error shows the CLI error message',
      (tester) async {
        final vault = seedSegmentedVault();
        vault.cli.onExcerptRmFails('not_found', 'no such transclusion here');
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        expect(r.inlineError, findsNothing);

        await r.tapRemove(1);

        expect(r.excerptRms, hasLength(1));
        expect(r.card(1), findsOneWidget);
        expect(
          r.textIn(r.card(1), 'Fixed the jump arc.\n- tried coyote time'),
          findsWidgets,
        );
        expect(r.inlineError, findsOneWidget);
        expect(
          find.descendant(
            of: r.inlineError,
            matching: find.textContaining('no such transclusion here'),
          ),
          findsOneWidget,
        );

        // Nothing is saved: the body still holds the token.
        await r.waitForSave();
        expect(r.updates, isEmpty);
        await r.toggleSource();
        expect(r.sourceText, fixtureTopicBody);
      },
    );

    testWidgets('the excerpt removal inline error can be dismissed', (
      tester,
    ) async {
      final vault = seedSegmentedVault();
      vault.cli.onExcerptRmFails('role_rule', 'topic note expected');
      final r = await launchSegmented(tester, vault: vault);
      await r.open(fixtureTopicId);
      await r.tapRemove(1);
      expect(r.inlineError, findsOneWidget);

      await tester.tap(
        find.descendant(of: r.inlineError, matching: r.inlineErrorDismiss),
      );
      await pumpFrames(tester);

      expect(r.inlineError, findsNothing);
      expect(r.card(1), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // AC7: daily note = person text field + footer chip row
  // -------------------------------------------------------------------------
  group('daily note segments (AC7)', () {
    testWidgets(
      'a daily note renders exactly one text field holding the person section',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        expect(r.allTextSegments, findsOneWidget);
        expect(r.segmentText(0), fixturePerson);
        expect(r.textSegment(1), findsNothing);
        expect(r.allCards, findsNothing);
        // The date header replaces the title: the person field is the only
        // editable text in the editor, so the footer is not a text field.
        expect(r.editorEditables, findsOneWidget);
        expect(r.segmentText(0), isNot(contains(topicsMarker)));
        expect(r.segmentText(0), isNot(contains('~about')));
      },
    );

    testWidgets(
      'footer chips render one chip per footer topic in footer order',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        expect(r.footerChip(fixtureZetaId), findsOneWidget);
        expect(r.footerChip(fixtureAlphaId), findsOneWidget);
        expect(
          r.labelIn(r.footerChip(fixtureZetaId), 'Zeta Game'),
          findsOneWidget,
        );
        expect(
          r.labelIn(r.footerChip(fixtureAlphaId), 'Alpha Topic'),
          findsOneWidget,
        );
        expect(r.footerChip('topic-other'), findsNothing);

        // Footer order (rowid): Zeta Game before Alpha Topic.
        final zeta = tester.getTopLeft(r.footerChip(fixtureZetaId));
        final alpha = tester.getTopLeft(r.footerChip(fixtureAlphaId));
        expect(
          zeta.dy < alpha.dy || (zeta.dy == alpha.dy && zeta.dx < alpha.dx),
          isTrue,
          reason: 'zeta $zeta must come before alpha $alpha',
        );
        // The chip row sits below the person field.
        expect(zeta.dy, greaterThan(r.top(r.textSegment(0))));
      },
    );

    testWidgets(
      'a transclusion line in a daily note person section stays text and renders no card',
      (tester) async {
        const person = 'Morning\n![[2026-09-05#^b7k2m9]]\nEvening\n';
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            dailyBody: assembleDailyBody(person, const [
              'Zeta Game',
              'Alpha Topic',
            ]),
          ),
        );
        await r.open(fixtureDailyId);

        expect(r.allCards, findsNothing);
        expect(r.allTextSegments, findsOneWidget);
        expect(r.segmentText(0), person);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC8: footer chip opens the topic note
  // -------------------------------------------------------------------------
  group('footer chip (AC8)', () {
    testWidgets(
      'tapping a footer chip opens that topic note as the active tab',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        await r.tapFooterChip(fixtureAlphaId);
        r.expectActiveNote(fixtureAlphaId);

        await r.open(fixtureDailyId);
        await r.tapFooterChip(fixtureZetaId);
        r.expectActiveNote(fixtureZetaId);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC9: Source toggle
  // -------------------------------------------------------------------------
  group('Source toggle (AC9)', () {
    testWidgets('a newly opened note shows the segmented view by default', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);

      expect(r.sourceToggle, findsOneWidget);
      expect(r.textSegment(0), findsOneWidget);
      expect(r.card(1), findsOneWidget);
      expect(r.sourceBody, findsNothing);
    });

    testWidgets(
      'the Source toggle shows one plain TextField with the full stored markdown including transclusion tokens',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.toggleSource();

        expect(r.sourceBody, findsOneWidget);
        expect(r.sourceText, fixtureTopicBody);
        expect(r.allTextSegments, findsNothing);
        expect(r.allCards, findsNothing);
      },
    );

    testWidgets(
      'the Source toggle shows the footer marker of a daily note in its single TextField',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        await r.toggleSource();

        expect(r.sourceBody, findsOneWidget);
        expect(r.editorEditables, findsOneWidget);
        expect(
          r.sourceText,
          assembleDailyBody(fixturePerson, const ['Zeta Game', 'Alpha Topic']),
        );
        expect(r.sourceText, contains(topicsMarker));
        expect(r.footerChip(fixtureZetaId), findsNothing);
      },
    );

    testWidgets('toggling Source off shows the segments again', (tester) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);

      await r.toggleSource();
      expect(r.allCards, findsNothing);
      await r.toggleSource();

      expect(r.sourceBody, findsNothing);
      expect(r.segmentText(0), 'Intro line\n');
      expect(r.card(1), findsOneWidget);
      expect(r.segmentText(2), 'Outro line\n');
    });

    testWidgets(
      'a note opened after toggling Source on another note starts in the segmented view',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.toggleSource();
        expect(r.sourceBody, findsOneWidget);

        await r.open(fixtureDailyId);

        expect(r.sourceBody, findsNothing);
        expect(r.textSegment(0), findsOneWidget);
        expect(r.footerChip(fixtureZetaId), findsOneWidget);
      },
    );

    testWidgets(
      'edits made in Source mode show in the segments after toggling back',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.toggleSource();

        await tester.enterText(
          r.sourceBody,
          '${fixtureTopicBody}Added in source\n',
        );
        await tester.pump();
        await r.toggleSource();

        expect(r.segmentText(2), 'Outro line\nAdded in source\n');
        expect(r.card(1), findsOneWidget);
        await r.waitForSave();
      },
    );

    testWidgets(
      'text typed below the marker in Source mode ends up at the end of the person segment',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);
        await r.toggleSource();

        await tester.enterText(
          r.sourceBody,
          '${assembleDailyBody(fixturePerson, const ['Zeta Game', 'Alpha Topic'])}stray words\n',
        );
        await tester.pump();
        await r.waitForSave();
        await r.toggleSource();

        expect(r.segmentText(0), '${fixturePerson}stray words\n');
        expect(r.segmentText(0), isNot(contains(topicsMarker)));
        expect(r.footerChip(fixtureZetaId), findsOneWidget);
        expect(r.footerChip(fixtureAlphaId), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC10: save = join of all segments, through the debounced save
  // -------------------------------------------------------------------------
  group('saving segments (AC10)', () {
    testWidgets(
      'editing a text segment saves the join of all segments with one update after the debounce',
      (tester) async {
        // Multi-byte text and a token line with trailing spaces: join must
        // give back the raw token line byte for byte.
        const body =
            'Café crème ☕ intro\n'
            '$fixtureRangeToken  \n'
            'naïve 🎉 outro\n';
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(topicBody: body),
        );
        await r.open(fixtureTopicId);
        expect(r.segmentText(2), 'naïve 🎉 outro\n');

        await r.typeInSegment(2, 'naïve 🎉 outro edited\n');
        await tester.pump(const Duration(milliseconds: 450));
        expect(r.updates, isEmpty, reason: 'debounced');

        await r.waitForSave();

        expect(r.updates, hasLength(1));
        final call = r.updates.single;
        expect(call.flag('note-id'), fixtureTopicId);
        expect(call.flag('expected-version'), '4');
        expect(
          call.stdinBody,
          'Café crème ☕ intro\n'
          '$fixtureRangeToken  \n'
          'naïve 🎉 outro edited\n',
        );
      },
    );

    testWidgets(
      'several edits inside the debounce window produce one update with the last text',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.typeInSegment(0, 'Intro line A\n');
        await tester.pump(const Duration(milliseconds: 200));
        await r.typeInSegment(0, 'Intro line AB\n');
        await tester.pump(const Duration(milliseconds: 200));
        await r.typeInSegment(0, 'Intro line ABC\n');
        await r.waitForSave();

        expect(r.updates, hasLength(1));
        expect(
          r.updates.single.stdinBody,
          'Intro line ABC\n$fixtureRangeToken\nOutro line\n',
        );
      },
    );

    testWidgets(
      'editing the daily person segment saves the person text with the footer unchanged',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        await r.typeInSegment(0, '${fixturePerson}Typed more.\n');
        await r.waitForSave();

        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('note-id'), fixtureDailyId);
        expect(r.updates.single.flag('expected-version'), '2');
        expect(
          r.updates.single.stdinBody,
          assembleDailyBody('${fixturePerson}Typed more.\n', const [
            'Zeta Game',
            'Alpha Topic',
          ]),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC11: no re-split per keystroke; re-split after save
  // -------------------------------------------------------------------------
  group('segment recompute (AC11)', () {
    testWidgets(
      'typing in a text segment keeps its focus and selection and the same field',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(0);
        final handleBefore = r.segment(0);
        final stateBefore = tester.state(_textFieldOf(0));

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Intro X line\n',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(r.segment(0), same(handleBefore));
        expect(tester.state(_textFieldOf(0)), same(stateBefore));
        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 7));

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Intro XY line\n',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(r.segment(0), same(handleBefore));
        expect(tester.state(_textFieldOf(0)), same(stateBefore));
        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 8));
        expect(r.segmentText(0), 'Intro XY line\n');
        expect(r.updates, isEmpty);

        await r.waitForSave();
        expect(r.updates, hasLength(1));
      },
    );

    testWidgets(
      'a transclusion typed into a text segment becomes a card only after the save completes',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.typeInSegment(0, 'Intro line\n![[2026-09-05#^f6g7h8]]\n');
        await tester.pump(const Duration(milliseconds: 300));

        // Before the save: still one card, the token is text in segment 0.
        expect(r.allCards, findsOneWidget);
        expect(r.segmentText(0), 'Intro line\n![[2026-09-05#^f6g7h8]]\n');
        expect(r.segmentHasFocus(0), isTrue);

        await r.waitForSave();

        expect(r.updates, hasLength(1));
        expect(
          r.updates.single.stdinBody,
          'Intro line\n![[2026-09-05#^f6g7h8]]\n$fixtureRangeToken\nOutro line\n',
        );
        expect(r.allCards, findsNWidgets(2));
        expect(r.textIn(r.card(1), 'Sleep was bad.'), findsWidgets);
        expect(
          r.textIn(r.card(3), 'Fixed the jump arc.\n- tried coyote time'),
          findsWidgets,
        );
        expect(r.segmentText(0), 'Intro line\n');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC12: arrow keys move focus between text segments
  // -------------------------------------------------------------------------
  group('arrow key focus (AC12)', () {
    testWidgets(
      'pressing Down at the end of a text segment moves focus to the next text segment past the card',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(0);
        expect(r.segmentHasFocus(0), isTrue);

        await r.pressKey(LogicalKeyboardKey.arrowDown);

        expect(r.segmentHasFocus(2), isTrue);
        expect(r.segmentHasFocus(0), isFalse);
      },
    );

    testWidgets(
      'pressing Up at the start of a text segment moves focus to the previous text segment past the card',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(2, offset: 0);
        expect(r.segmentHasFocus(2), isTrue);

        await r.pressKey(LogicalKeyboardKey.arrowUp);

        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentHasFocus(2), isFalse);
      },
    );

    testWidgets(
      'pressing Down away from the end of a text segment keeps focus in it',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody:
                'Intro line\nsecond line\n$fixtureRangeToken\nOutro line\n',
          ),
        );
        await r.open(fixtureTopicId);
        await r.focusSegment(0, offset: 0);

        await r.pressKey(LogicalKeyboardKey.arrowDown);

        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentHasFocus(2), isFalse);
      },
    );

    testWidgets(
      'pressing Up away from the start of a text segment keeps focus in it',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: 'Intro line\n$fixtureRangeToken\nOutro line\nlast line',
          ),
        );
        await r.open(fixtureTopicId);
        await r.focusSegment(2);

        await r.pressKey(LogicalKeyboardKey.arrowUp);

        expect(r.segmentHasFocus(2), isTrue);
        expect(r.segmentHasFocus(0), isFalse);
      },
    );

    testWidgets(
      'pressing Down at the end of the last text segment keeps focus there',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(2);

        await r.pressKey(LogicalKeyboardKey.arrowDown);

        expect(r.segmentHasFocus(2), isTrue);
        expect(r.segmentHasFocus(0), isFalse);
      },
    );

    testWidgets(
      'pressing Up at the start of the first text segment keeps focus there',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(0, offset: 0);

        await r.pressKey(LogicalKeyboardKey.arrowUp);

        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentHasFocus(2), isFalse);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC13: autocomplete and kind chip in every text segment
  // -------------------------------------------------------------------------
  group('autocomplete in segments (AC13)', () {
    testWidgets(
      'typing [[ in the text segment after a card opens autocomplete and inserts the chosen title there',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        expect(r.popover, findsNothing);

        await r.typeInSegment(2, 'Outro see [[Other');
        expect(r.popover, findsOneWidget);
        expect(
          find.byKey(const Key('wikilink-popover-item-Other note')),
          findsOneWidget,
        );

        await r.pressKey(LogicalKeyboardKey.enter);

        expect(r.segmentText(2), startsWith('Outro see [[Other note]]'));
        expect(r.segmentText(0), 'Intro line\n');
        expect(r.popover, findsNothing);
        await r.waitForSave();
        expect(
          r.updates.last.stdinBody,
          startsWith(
            'Intro line\n$fixtureRangeToken\nOutro see [[Other note]]',
          ),
        );
      },
    );

    testWidgets(
      'typing [[ in the first text segment opens autocomplete and inserts the chosen title there',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.typeInSegment(0, 'See [[Other');
        expect(r.popover, findsOneWidget);
        await r.pressKey(LogicalKeyboardKey.enter);

        expect(r.segmentText(0), startsWith('See [[Other note]]'));
        expect(r.segmentText(2), 'Outro line\n');
        await r.waitForSave();
      },
    );

    testWidgets(
      'typing [[ in the daily person segment opens autocomplete and inserts the chosen title there',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureDailyId);

        await r.typeInSegment(0, '${fixturePerson}Met [[Other');
        expect(r.popover, findsOneWidget);
        await r.pressKey(LogicalKeyboardKey.enter);

        expect(
          r.segmentText(0),
          startsWith('${fixturePerson}Met [[Other note]]'),
        );
        await r.waitForSave();
      },
    );

    testWidgets(
      'the inline kind chip appears after a wikilink is inserted in a text segment',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        expect(r.kindChip, findsNothing);

        await r.typeInSegment(2, 'Outro see [[Other');
        await r.pressKey(LogicalKeyboardKey.enter);

        expect(r.kindChip, findsOneWidget);
        await r.waitForSave();
      },
    );
  });
}
