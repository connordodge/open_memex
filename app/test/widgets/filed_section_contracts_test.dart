// WI #260 (F8), verify mode: contracts of the `Filed from this day` section
// and its topic dialog that `filed_section_test.dart` leaves unpinned: the
// order of equal matches, the Why trimming, the Enter / arrow-key state
// machine, the choice marks, a role-less note in a Smart Folder, failures
// that are not a MemexException, and a rebase that must not go backwards.
// Test names use no apostrophes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/widgets/activity/topic_pick_dialog.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/filed_section_fakes.dart';
import '../support/footer_cli_fakes.dart';
import '../support/segment_editing_finder.dart';

TopicChoice _t(String id, String title) => TopicChoice(id: id, title: title);

List<String> _ids(List<TopicChoice> l) => [for (final t in l) t.id];

/// The option ids of the dialog's list, top to bottom.
List<String> _shown(WidgetTester tester, List<String> ids) {
  final found = [
    for (final id in ids)
      if (find.byKey(f260Option(id)).evaluate().isNotEmpty) id,
  ];
  found.sort(
    (a, b) => f260Top(
      tester,
      f260Option(a),
    ).compareTo(f260Top(tester, f260Option(b))),
  );
  return found;
}

const _allTopics = [f260Economy, f260Level, f260Sleep, f260Orphan];

Color? _background(WidgetTester tester, Key option) => tester
    .widget<Container>(
      find
          .descendant(
            of: find.byKey(option),
            matching: find.byType(Container),
            matchRoot: true,
          )
          .first,
    )
    .color;

bool _marked(Key option) => find
    .descendant(
      of: find.byKey(option),
      matching: find.byIcon(LucideIcons.check),
    )
    .evaluate()
    .isNotEmpty;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await pumpFrames(tester);
}

void main() {
  group('matchTopics', () {
    test('matchTopics orders equal scores by title ignoring case then id', () {
      final all = [
        _t('b', 'beta'),
        _t('a2', 'Alpha'),
        _t('c', 'Charlie'),
        _t('a1', 'alpha'),
      ];

      expect(_ids(matchTopics(all, '')), ['a1', 'a2', 'b', 'c']);
      expect(_ids(matchTopics(all, '   ')), ['a1', 'a2', 'b', 'c']);
    });

    test('matchTopics puts the best fuzzyScore first', () {
      final all = [
        _t('sub', 'xaxbx'), // subsequence of "ab"
        _t('has', 'xabx'), // contains "ab"
        _t('start', 'abxx'), // starts with "ab"
      ];

      expect(_ids(matchTopics(all, 'ab')), ['start', 'has', 'sub']);
    });

    test('matchTopics trims and lowercases the query', () {
      final all = [_t('e', 'Economy'), _t('s', 'Sleep')];

      expect(_ids(matchTopics(all, '  ECON ')), ['e']);
      expect(_ids(matchTopics(all, 'Sl')), ['s']);
    });

    test('matchTopics drops titles without a match and the excluded id', () {
      final all = [_t('e', 'Economy'), _t('s', 'Sleep'), _t('x', 'Xylophone')];

      expect(_ids(matchTopics(all, 'zzz')), isEmpty);
      expect(_ids(matchTopics(all, 'e', excludeId: 'e')), ['s', 'x']);
      expect(_ids(matchTopics(all, '', excludeId: 's')), ['e', 'x']);
      expect(matchTopics(const [], 'e'), isEmpty);
    });
  });

  group('the Why text', () {
    testWidgets(
      'the Why text is trimmed and a whitespace only Why is no note',
      (tester) async {
        final f = await pumpF260(tester);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
          why: '   because it fits  ',
        );
        expect(f.moves.single.args['note'], 'because it fits');

        await f260Tap(tester, f260Remove(f260Loop, f260B2));
        await f260TypeWhy(tester, '   ');
        await f260Tap(tester, f260Confirm);
        expect(f.removes.single.args['note'], isNull);
        expect(
          f.cli.callsFor('excerpt remove-block').single.hasFlag('note'),
          false,
        );
      },
    );
  });

  group('topic list sources', () {
    testWidgets('a role-less note in a Smart Folder is not offered', (
      tester,
    ) async {
      final db = f260Db()..seedFolderMember('f-games', f260Loose);
      await pumpF260(tester, db: db);
      await f260Tap(tester, f260Move(f260Loop, f260B1));

      expect(find.byKey(f260Option(f260Level)), findsOneWidget);
      expect(find.byKey(f260Option(f260Loose)), findsNothing);
      for (final t in [f260Economy, f260Sleep, f260Orphan]) {
        expect(find.byKey(f260Option(t)), findsOneWidget, reason: t);
      }
    });
  });

  group('the dialog keyboard', () {
    testWidgets(
      'the first Enter chooses the best match and the second confirms',
      (tester) async {
        final f = await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 's');

        await _key(tester, LogicalKeyboardKey.enter);
        expect(f.writes, isEmpty, reason: 'the first Enter only chooses');
        expect(find.byKey(f260Confirm), findsOneWidget);
        expect(_marked(f260Option(f260Sleep)), isTrue);
        expect(_marked(f260Option(f260Level)), isFalse);

        await _key(tester, LogicalKeyboardKey.enter);
        expect(f.moves, hasLength(1));
        expect(f.moves.single.args['toTopicNoteId'], f260Sleep);
        expect(find.byKey(f260Confirm), findsNothing);
      },
    );

    testWidgets(
      'Enter with no match chooses the Create row and the next Enter creates',
      (tester) async {
        final f = await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');

        await _key(tester, LogicalKeyboardKey.enter);
        expect(f.notes.callsTo('addNote'), isEmpty);
        expect(f.writes, isEmpty);
        expect(find.byKey(f260Confirm), findsOneWidget);
        expect(_marked(f260Create), isTrue);

        await _key(tester, LogicalKeyboardKey.enter);
        expect(f.notes.callsTo('addNote').single.args['role'], 'topic');
        expect(f.moves.single.args['toTopicNoteId'], createdTopicId);
      },
    );

    testWidgets('ArrowDown once moves to the second of three matches', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'e');
      final order = _shown(tester, _allTopics);
      expect(order, [f260Economy, f260Sleep, f260Level]);

      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.enter);

      expect(f.moves.single.args['toTopicNoteId'], order[1]);
    });

    testWidgets(
      'ArrowDown twice then ArrowUp lands on the second of three matches',
      (tester) async {
        final f = await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'e');
        final order = _shown(tester, _allTopics);

        await _key(tester, LogicalKeyboardKey.arrowDown);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        await _key(tester, LogicalKeyboardKey.arrowUp);
        await _key(tester, LogicalKeyboardKey.enter);
        await _key(tester, LogicalKeyboardKey.enter);

        expect(f.moves.single.args['toTopicNoteId'], order[1]);
      },
    );

    testWidgets('typing puts the highlight back on the best match', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'e');
      await _key(tester, LogicalKeyboardKey.arrowDown);

      await f260TypeTopic(tester, 'le');
      expect(_shown(tester, _allTopics), [f260Level, f260Sleep]);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.enter);

      expect(f.moves.single.args['toTopicNoteId'], f260Level);
    });

    testWidgets('arrow keys in the Why field leave the highlight alone', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'e');
      await tester.tap(find.byKey(f260WhyField));
      await tester.pump();

      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.enter);

      expect(f.moves.single.args['toTopicNoteId'], f260Economy);
    });

    testWidgets(
      'Enter in the Why field confirms a chosen target with that Why',
      (tester) async {
        final f = await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Sleep));
        await f260Tap(tester, f260WhyField);
        await tester.enterText(find.byKey(f260WhyField), 'rest matters');
        await pumpFrames(tester);

        await _key(tester, LogicalKeyboardKey.enter);

        expect(f.moves.single.args['toTopicNoteId'], f260Sleep);
        expect(f.moves.single.args['note'], 'rest matters');
      },
    );

    testWidgets('Enter in the Remove dialog confirms it', (tester) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Remove(f260Loop, f260B2));
      await tester.enterText(find.byKey(f260WhyField), 'wrong topic');
      await pumpFrames(tester);

      await _key(tester, LogicalKeyboardKey.enter);

      expect(f.removes.single.args['blockId'], f260B2);
      expect(f.removes.single.args['note'], 'wrong topic');
      expect(find.byKey(f260Confirm), findsNothing);
    });

    testWidgets('arrow keys do nothing in the Remove dialog', (tester) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Remove(f260Loop, f260B2));

      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowUp);

      expect(f.writes, isEmpty);
      expect(find.byKey(f260Confirm), findsOneWidget);
    });
  });

  group('the dialog choice', () {
    testWidgets('the highlight marks the best match and follows the arrows', (
      tester,
    ) async {
      await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 's');

      expect(_background(tester, f260Option(f260Sleep)), OmColors.surface4);
      expect(_background(tester, f260Option(f260Level)), isNull);

      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_background(tester, f260Option(f260Sleep)), isNull);
      expect(_background(tester, f260Option(f260Level)), OmColors.surface4);

      await f260TypeTopic(tester, 'Econ');
      expect(_background(tester, f260Option(f260Economy)), OmColors.surface4);
      expect(_background(tester, f260Create), isNull, reason: 'a match exists');

      await f260TypeTopic(tester, 'Fresh');
      expect(_background(tester, f260Create), OmColors.surface4);
    });

    testWidgets('choosing an option marks it and replaces an earlier choice', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'Econ');

      await f260Tap(tester, f260Create);
      expect(_marked(f260Create), isTrue);
      expect(_marked(f260Option(f260Economy)), isFalse);

      await f260Tap(tester, f260Option(f260Economy));
      expect(_marked(f260Create), isFalse);
      expect(_marked(f260Option(f260Economy)), isTrue);
      await f260Tap(tester, f260Confirm);

      expect(f.moves.single.args['toTopicNoteId'], f260Economy);
      expect(f.notes.callsTo('addNote'), isEmpty, reason: 'Create was dropped');

      await f260Tap(tester, f260Move(f260Economy, f260B3));
      await f260TypeTopic(tester, 'Sle');
      await f260Tap(tester, f260Option(f260Sleep));
      await f260Tap(tester, f260Create);
      expect(_marked(f260Option(f260Sleep)), isFalse);
      await f260Tap(tester, f260Confirm);

      expect(f.notes.callsTo('addNote').single.args['title'], 'Sle');
      expect(f.moves, hasLength(2));
      expect(f.moves.last.args['toTopicNoteId'], createdTopicId);
    });

    testWidgets('typing again drops the chosen target', (tester) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 's');
      await f260Tap(tester, f260Option(f260Sleep));
      expect(_marked(f260Option(f260Sleep)), isTrue);

      await f260TypeTopic(tester, 'sl');
      expect(_marked(f260Option(f260Sleep)), isFalse);
      await f260Tap(tester, f260Confirm);

      expect(f.writes, isEmpty);
      expect(find.byKey(f260Confirm), findsOneWidget);
    });

    testWidgets('a chosen Create is dropped when the name changes', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'Fresh');
      await f260Tap(tester, f260Create);

      await f260TypeTopic(tester, 'Fresher');
      await f260Tap(tester, f260Confirm);

      expect(f.notes.callsTo('addNote'), isEmpty);
      expect(find.byKey(f260Confirm), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('a failure that is not a MemexException shows its text', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.feedback.failNext('removeBlock', StateError('kaput'));

      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await f260Tap(tester, f260Confirm);

      expect(
        find.descendant(of: f260Error, matching: find.textContaining('kaput')),
        findsOneWidget,
      );
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
      expect(find.byKey(f260Remove(f260Loop, f260B1)), findsOneWidget);
    });

    testWidgets('a retry clears the earlier inline error while it runs', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.feedback.failNext('removeBlock', StateError('kaput'));
      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await f260Tap(tester, f260Confirm);
      expect(f260Error, findsOneWidget);

      f.feedback.gate('removeBlock');
      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await f260Tap(tester, f260Confirm);

      expect(f.removes, hasLength(2));
      expect(f260Error, findsNothing, reason: 'cleared when the retry starts');
      f.feedback.gates['removeBlock']!.single.complete();
      await pumpFrames(tester);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
    });

    testWidgets('block_not_found shows no inline error', (tester) async {
      final f = await pumpF260(tester);
      f.server.dropBlock(f260B1);

      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Economy,
      );

      expect(f.moves, hasLength(1));
      expect(f260Error, findsNothing);
    });

    testWidgets(
      'an unreachable server leaves the row, a snackbar and no inline error',
      (tester) async {
        final f = await pumpF260(tester);
        await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
        await tester.pump();
        f.feedback.failNext(
          'moveBlock',
          const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: false,
          ),
        );

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );

        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(f260Error, findsNothing);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        final move = tester.widget<OmButton>(
          find.byKey(f260Move(f260Loop, f260B1)),
        );
        expect(move.onPressed, isNotNull, reason: 'enabled again');
        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 1);
        expect(editor.contentMd, 'pending thought');
      },
    );

    testWidgets('a Create that cannot reach the server moves nothing', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.notes.failNext(
        'addNote',
        const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        ),
      );

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'Fresh Topic');
      await f260Tap(tester, f260Create);
      await f260Tap(tester, f260Confirm);

      expect(f.moves, isEmpty);
      expect(find.text("couldn't reach nas. try again."), findsOneWidget);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
    });
  });

  group('rebase', () {
    testWidgets(
      'a stored daily note version below the editor base is not adopted',
      (tester) async {
        final f = await pumpF260(tester);
        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Sleep,
        );
        expect(f.h.read(editorControllerProvider).lastSavedVersion, 2);

        f.server.chipBumpsDaily = false;
        f.db.db.execute('UPDATE notes SET version = 1 WHERE id = ?', [
          f260DailyId,
        ]);
        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B2,
          target: f260Orphan,
        );

        expect(
          f.h.read(editorControllerProvider).lastSavedVersion,
          2,
          reason: 'the base never moves back',
        );
        expect(find.text('conflict — reload'), findsNothing);
      },
    );
  });
}
