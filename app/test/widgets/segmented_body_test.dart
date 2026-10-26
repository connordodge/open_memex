// WI #27 (A9), beyond the ACs: the segmented body's own rules. A text that
// loses its line end before a card keeps the card a card, the caret and the
// field survive a save, focus follows a re-split, arrows keep working after
// one, unsaved edits survive an excerpt removal, and the inline error lives
// until another note opens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/excerpt_cli_fakes.dart';
import '../support/segment_editing_finder.dart';

const _hint = 'type [[ to link a note · write markdown…';

/// The text field of text segment [i] (one per segment until rows, C1).
Finder _textFieldOf(int i) => find.descendant(
  of: find.byKey(textSegmentKey(i)),
  matching: find.byType(TextField),
);

void main() {
  group('saving keeps cards and carets', () {
    testWidgets(
      'a text segment that loses its line end before a card saves with it so the card stays',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.focusSegment(0);
        final handle = r.segment(0);
        final field = tester.state(_textFieldOf(0));

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Intro lineX',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        await tester.pump();
        await r.waitForSave();

        expect(r.updates, hasLength(1));
        expect(
          r.updates.single.stdinBody,
          'Intro lineX\n$fixtureRangeToken\nOutro line\n',
        );
        expect(r.card(1), findsOneWidget);
        expect(r.segmentText(0), 'Intro lineX\n');
        // Same segment, same field, same focus, caret where it was.
        expect(r.segment(0), same(handle));
        expect(tester.state(_textFieldOf(0)), same(field));
        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 3));
      },
    );

    testWidgets('the last text segment saves without an added line end', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);

      await r.typeInSegment(2, 'Outro line');
      await r.waitForSave();

      expect(
        r.updates.single.stdinBody,
        'Intro line\n$fixtureRangeToken\nOutro line',
      );
    });

    testWidgets('the empty text segment before a leading card saves empty', (
      tester,
    ) async {
      final r = await launchSegmented(
        tester,
        vault: seedSegmentedVault(
          topicBody: '![[2026-09-05#^c3d4e5]]\nAfter the card\n',
        ),
      );
      await r.open(fixtureTopicId);

      await r.typeInSegment(2, 'After edited\n');
      await r.waitForSave();

      expect(
        r.updates.single.stdinBody,
        '![[2026-09-05#^c3d4e5]]\nAfter edited\n',
      );
    });
  });

  group('focus after a re-split', () {
    testWidgets(
      'when a save turns a typed token into a card the caret moves to the text segment after it',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.typeInSegment(0, 'Intro line\n![[2026-09-05#^f6g7h8]]\n');
        await r.waitForSave();

        expect(r.allCards, findsNWidgets(2));
        expect(r.segmentText(2), '');
        expect(r.segmentHasFocus(2), isTrue);
        expect(r.segmentHasFocus(0), isFalse);
        expect(r.segmentHasFocus(4), isFalse);
      },
    );

    testWidgets(
      'arrow keys still move between text segments after a re-split',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.typeInSegment(0, 'Intro line\n![[2026-09-05#^f6g7h8]]\n');
        await r.waitForSave();
        expect(r.allCards, findsNWidgets(2));

        await r.focusSegment(0);
        await r.pressKey(LogicalKeyboardKey.arrowDown);
        expect(r.segmentHasFocus(2), isTrue);

        await r.focusSegment(0, offset: 0);
        await r.pressKey(LogicalKeyboardKey.arrowUp);
        expect(r.segmentHasFocus(0), isTrue);
      },
    );

    testWidgets(
      'Down puts the caret at the start of the next text segment and Up at the end of the previous one',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        await r.focusSegment(0);
        await r.pressKey(LogicalKeyboardKey.arrowDown);
        expect(r.segmentHasFocus(2), isTrue);
        expect(r.segmentSelection(2), const TextSelection.collapsed(offset: 0));

        await r.pressKey(LogicalKeyboardKey.arrowUp);
        expect(r.segmentHasFocus(0), isTrue);
        expect(
          r.segmentSelection(0),
          TextSelection.collapsed(offset: 'Intro line\n'.length),
        );
      },
    );
  });

  group('the body field', () {
    testWidgets(
      'the first text segment is the editor-body field of a topic and a daily note',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        final body = find.byKey(editorBodyKey);

        expect(body, findsOneWidget);
        expect(editorBodySegment(tester), same(r.segment(0)));
        expect(
          find.descendant(of: r.textSegment(0), matching: body),
          findsOneWidget,
          reason: 'editor-body is inside text-segment-0',
        );

        await r.open(fixtureDailyId);
        expect(body, findsOneWidget);
        expect(editorBodySegment(tester), same(r.segment(0)));
        expect(
          find.descendant(of: r.textSegment(0), matching: body),
          findsOneWidget,
        );
      },
    );

    testWidgets('an empty note without excerpts shows the markdown hint', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open('topic-other');

      expect(r.allTextSegments, findsOneWidget);
      expect(
        r.textIn(find.byKey(const Key('text-segment-0')), _hint),
        findsOneWidget,
      );
    });

    testWidgets('opening another topic note shows that note in segments', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);
      expect(r.allCards, findsOneWidget);

      await r.open('topic-other');

      expect(r.allCards, findsNothing);
      expect(r.allTextSegments, findsOneWidget);
      expect(r.segmentText(0), '');
    });

    testWidgets(
      'the kind chip hides when the caret moves to the start of the text segment',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        await r.typeInSegment(2, 'Outro see [[Other');
        await r.pressKey(LogicalKeyboardKey.enter);
        expect(r.kindChip, findsOneWidget);

        r.segment(2).select(const TextSelection.collapsed(offset: 0));
        await tester.pump();

        expect(r.kindChip, findsNothing);
        await r.waitForSave();
      },
    );
  });

  group('excerpt removal edges', () {
    testWidgets(
      'unsaved edits survive an excerpt removal and save against the returned version',
      (tester) async {
        final vault = seedSegmentedVault(topicVersion: 4, rmVersion: 9);
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);

        await r.typeInSegment(0, 'Intro edited\n');
        await r.tapRemove(1);
        expect(r.allCards, findsNothing);
        expect(r.segmentText(0), 'Intro edited\nOutro line\n');
        await r.waitForSave();

        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('expected-version'), '9');
        expect(r.updates.single.stdinBody, 'Intro edited\nOutro line\n');
      },
    );

    testWidgets(
      'the excerpt removal error stays while typing and is gone after opening another note',
      (tester) async {
        final vault = seedSegmentedVault();
        vault.cli.onExcerptRmFails('not_found', 'no such transclusion here');
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        await r.tapRemove(1);
        expect(r.inlineError, findsOneWidget);

        await r.typeInSegment(0, 'Intro typed\n');
        await pumpFrames(tester);
        expect(r.inlineError, findsOneWidget);
        await r.waitForSave();
        expect(r.inlineError, findsOneWidget);

        await r.open('topic-other');
        expect(r.inlineError, findsNothing);
        await r.open(fixtureTopicId);
        expect(r.inlineError, findsNothing);
      },
    );

    testWidgets(
      'tapping the caption of a date without a daily note keeps the topic note open',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: 'Intro\n![[2026-09-06#^b7k2m9]]\nOutro\n',
          ),
        );
        await r.open(fixtureTopicId);
        expect(r.textIn(r.card(1), 'removed from 2026-09-06'), findsWidgets);

        await r.tapCaption(1);

        r.expectActiveNote(fixtureTopicId);
      },
    );
  });
}
