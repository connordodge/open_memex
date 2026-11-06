// WI #260 (F8): the `Filed from this day` section at the top of a daily
// note's Activity tab (Spec #233 R6-R10, R13-R16, R44, R45): where the blocks
// of the day are filed, with `Move to…`, `Remove` and `File in…` fixes.
//
// The `memex` binary is a FakeMemexCli over a F260Server (state that the
// filing and block commands read and write); the calls the app makes are
// recorded by RecordingFeedbackAccess / RecordingNotesAccess. `memex` is
// never run. Test names use no apostrophes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/activity/filed_section.dart';
import 'package:open_memex_app/src/widgets/activity_tab.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/filed_section_fakes.dart';
import '../support/footer_cli_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/topics_launch.dart';

const _longPreview =
    'a very long preview that keeps going and going so that it cannot fit on '
    'one line of the right panel however narrow the text is drawn, and then '
    'some more words to be sure about it';
const _longTitle = 'A very long topic title that goes on and on and on forever';

/// The text of the EditableText inside the field with [key].
String _fieldText(WidgetTester tester, Key key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(key),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
    )
    .controller
    .text;

/// The OmButton with [key] (or inside it).
OmButton _button(WidgetTester tester, Key key) => tester.widget<OmButton>(
  find.descendant(
    of: find.byKey(key),
    matching: find.byType(OmButton),
    matchRoot: true,
  ),
);

bool _enabled(WidgetTester tester, Key key) =>
    _button(tester, key).onPressed != null;

Finder _inSection(Finder what) => f260In(find.byKey(f260Section), what);

Future<void> _drain(WidgetTester tester, F260 f) async {
  f.h.clock.advance(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

int _filingCalls(F260 f) => f.cli.callsFor('filing').length;

void main() {
  group('visibility and grouping (AC1, AC2, AC3)', () {
    testWidgets(
      'a reviewed day shows the section above the agent entries with rows grouped under each topic note in filing order',
      (tester) async {
        final f = await pumpF260(tester);

        expect(find.byKey(f260Section), findsOneWidget);
        expect(_inSection(f260TextCI('Filed from this day')), findsOneWidget);
        // Rows under their topic, in the order filing returns.
        for (final k in [
          f260Row(f260Loop, f260B1),
          f260Row(f260Loop, f260B2),
          f260Row(f260Economy, f260B3),
          f260NotFiledRow(f260N1),
        ]) {
          expect(find.byKey(k), findsOneWidget, reason: '$k');
        }
        expect(
          _inSection(
            find.descendant(
              of: find.byKey(f260Row(f260Loop, f260B1)),
              matching: find.textContaining(f260B1Text),
            ),
          ),
          findsOneWidget,
        );
        final loopTitle = _inSection(f260TextCI('Player Loop'));
        final economyTitle = _inSection(f260TextCI('Economy'));
        final notFiled = _inSection(f260TextCI('Not filed'));
        expect(loopTitle, findsOneWidget);
        expect(economyTitle, findsOneWidget);
        expect(notFiled, findsOneWidget);
        double top(Finder x) => tester.getTopLeft(x).dy;
        final order = [
          top(loopTitle),
          f260Top(tester, f260Row(f260Loop, f260B1)),
          f260Top(tester, f260Row(f260Loop, f260B2)),
          top(economyTitle),
          f260Top(tester, f260Row(f260Economy, f260B3)),
          top(notFiled),
          f260Top(tester, f260NotFiledRow(f260N1)),
          f260Top(tester, const Key('activity-entry-ac-1')),
        ];
        expect(
          order,
          orderedEquals([...order]..sort()),
          reason: 'topics in filing order, Not filed last, entries below',
        );
        expect(order.toSet(), hasLength(order.length));
        expect(_filingCalls(f), greaterThan(0));
        expect(
          f.feedback.callsTo('filing').first.args['date'],
          f260Date,
          reason: 'the date is the daily note title',
        );
      },
    );

    testWidgets('a topic with no blocks gets no group', (tester) async {
      final f = await pumpF260(tester);
      f.server.topics.last.blocks.clear();
      f.h.container.read(vaultRevisionProvider.notifier).state++;
      await pumpFrames(tester);

      expect(find.byKey(f260Section), findsOneWidget);
      expect(_inSection(f260TextCI('Economy')), findsNothing);
      expect(_inSection(f260TextCI('Player Loop')), findsOneWidget);
    });

    testWidgets('a topic title is plain text that opens nothing', (
      tester,
    ) async {
      await pumpF260(tester);
      final before = tester.element(find.byType(ActivityTab));
      final container = ProviderScope.containerOf(before);
      final tabsBefore = container.read(tabsProvider).activeTab;

      expect(find.byKey(f260Section), findsOneWidget);
      await tester.tap(_inSection(f260TextCI('Player Loop')));
      await pumpFrames(tester);

      expect(tabsBefore, const NoteTab(f260DailyId));
      expect(container.read(tabsProvider).activeTab, tabsBefore);
      expect(find.byKey(f260Section), findsOneWidget);
    });

    testWidgets(
      'a reviewed day with no agent entries still shows the section',
      (tester) async {
        await pumpF260(tester, db: f260Db(agentEntry: false));

        expect(find.byKey(f260Section), findsOneWidget);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(const Key('activity-entry-ac-1')), findsNothing);
      },
    );

    testWidgets('a never reviewed day shows no section but keeps its entries', (
      tester,
    ) async {
      final db = f260Db();
      final f = await pumpF260(
        tester,
        db: db,
        server: f260DefaultServer(db)..reviewed = false,
      );

      expect(find.byKey(f260Section), findsNothing);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
      expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
      expect(
        _filingCalls(f),
        greaterThan(0),
        reason: 'reviewed comes from filing',
      );
    });

    testWidgets(
      'a day with nothing to list shows no section and the empty state',
      (tester) async {
        final db = f260Db(agentEntry: false);
        final server = F260Server(
          db,
          topics: [F260Topic(f260Economy, 'Economy')],
          notFiled: [],
        );
        final f = await pumpF260(tester, db: db, server: server);

        expect(
          _filingCalls(f),
          greaterThan(0),
          reason: 'the day is asked, then nothing is shown',
        );
        expect(find.byKey(f260Section), findsNothing);
        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
      },
    );

    testWidgets('a topic note shows no section and asks for no filing', (
      tester,
    ) async {
      final f = await pumpF260(tester, noteId: f260Loop);

      expect(find.byKey(f260Section), findsNothing);
      expect(f.cli.callsFor('filing'), isEmpty);
      expect(f.feedback.callsTo('filing'), isEmpty);
    });

    testWidgets('a vault below V6 shows no section and asks for no filing', (
      tester,
    ) async {
      final db = FakeVaultDb.v5Only()
        ..seedDailyNote(f260Date, id: f260DailyId)
        ..seedDayReview(
          f260DailyId,
          contentVersion: 4,
          reviewedContentVersion: 4,
          reviewedAt: 1762300000000,
        );
      db.db.execute(
        'INSERT INTO agent_changes (id, note_id, day, created_at, bullets_json) '
        "VALUES ('ac-1', ?, ?, 1762300000000, '[\"Filed two blocks\"]')",
        [f260DailyId, f260Date],
      );
      final f = await pumpF260(tester, db: db);

      expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
      expect(find.byKey(f260Section), findsNothing);
      expect(f.cli.callsFor('filing'), isEmpty);
    });
  });

  group('Not filed (AC3)', () {
    testWidgets(
      'the Not filed group holds the rows filing returns each with File in and comes last',
      (tester) async {
        final db = f260Db();
        final server = f260DefaultServer(db)
          ..notFiled.add(('n2', 'second loose block'));
        await pumpF260(tester, db: db, server: server);

        expect(find.byKey(f260NotFiledRow(f260N1)), findsOneWidget);
        expect(find.byKey(f260NotFiledRow('n2')), findsOneWidget);
        expect(find.byKey(f260FileIn(f260N1)), findsOneWidget);
        expect(find.byKey(f260FileIn('n2')), findsOneWidget);
        expect(
          f260Top(tester, f260NotFiledRow(f260N1)),
          lessThan(f260Top(tester, f260NotFiledRow('n2'))),
        );
        expect(
          f260Top(tester, f260NotFiledRow(f260N1)),
          greaterThan(f260Top(tester, f260Row(f260Economy, f260B3))),
        );
        // A filed row offers Move to and Remove, never File in.
        expect(find.byKey(f260Move(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260Remove(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260FileIn(f260B1)), findsNothing);
        expect(find.byKey(f260Move(f260Loop, f260N1)), findsNothing);
      },
    );

    testWidgets('the Not filed group is absent when empty', (tester) async {
      final db = f260Db();
      final server = f260DefaultServer(db)..notFiled.clear();
      await pumpF260(tester, db: db, server: server);

      expect(find.byKey(f260Section), findsOneWidget);
      expect(_inSection(f260TextCI('Not filed')), findsNothing);
      expect(find.byKey(f260NotFiledRow(f260N1)), findsNothing);
    });

    testWidgets(
      'a day with only unfiled blocks shows just the Not filed group',
      (tester) async {
        final db = f260Db();
        final server = F260Server(
          db,
          topics: [],
          notFiled: [(f260N1, f260N1Text)],
        );
        await pumpF260(tester, db: db, server: server);

        expect(find.byKey(f260Section), findsOneWidget);
        expect(_inSection(f260TextCI('Not filed')), findsOneWidget);
        expect(find.byKey(f260NotFiledRow(f260N1)), findsOneWidget);
      },
    );
  });

  group('previews and layout (AC15)', () {
    testWidgets(
      'long previews truncate to one line with the full text in a tooltip',
      (tester) async {
        final db = f260Db();
        final server = f260DefaultServer(db);
        server.topics.first.blocks[0] = (f260B1, _longPreview);
        await pumpF260(tester, db: db, server: server);

        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && (w.message ?? '').contains(_longPreview),
          ),
          findsOneWidget,
        );
        final long = tester.getSize(find.byKey(f260Row(f260Loop, f260B1)));
        final short = tester.getSize(find.byKey(f260Row(f260Loop, f260B2)));
        expect(long.height, short.height, reason: 'one line, not wrapped');
        expect(
          _inSection(find.textContaining('a very long preview')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'rows and buttons stay inside the panel width at text scale 1.5',
      (tester) async {
        final db = f260Db();
        final server = F260Server(
          db,
          topics: [
            F260Topic(f260Loop, _longTitle, [
              (f260B1, _longPreview),
              (f260B2, f260B2Text),
            ]),
          ],
          notFiled: [(f260N1, _longPreview)],
        );
        final cli = f260Cli(db, server);
        final note = db.getNote(f260DailyId)!;
        tester.view.physicalSize = const Size(800, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith(
              (_) => LocalVaultRef(Directory.systemTemp.path),
            ),
            vaultDbProvider.overrideWithValue(db),
            memexCliProvider.overrideWithValue(cli),
            clockProvider.overrideWithValue(FakeClock()),
            selectedNoteIdProvider.overrideWith((_) => f260DailyId),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 340,
                    height: 1000,
                    child: SingleChildScrollView(
                      child: FiledSection(note: note),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await pumpFrames(tester);

        expect(find.byKey(f260Section), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'rows at scale 1.5');
        for (final k in [
          f260Row(f260Loop, f260B1),
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260NotFiledRow(f260N1),
          f260FileIn(f260N1),
        ]) {
          final r = tester.getRect(find.byKey(k));
          expect(r.left, greaterThanOrEqualTo(0), reason: '$k');
          expect(r.right, lessThanOrEqualTo(340), reason: '$k');
        }
        for (final open in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260FileIn(f260N1),
        ]) {
          await f260Tap(tester, open);
          expect(find.byKey(f260Confirm), findsOneWidget, reason: '$open');
          expect(tester.takeException(), isNull, reason: 'dialog of $open');
          await f260Tap(tester, f260Cancel);
          expect(tester.takeException(), isNull);
        }
      },
    );
  });

  group('the topic dialog (AC4, AC7)', () {
    testWidgets(
      'Move to lists topic notes without the source topic note the daily note and role-less notes',
      (tester) async {
        await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));

        for (final t in [f260Economy, f260Level, f260Sleep, f260Orphan]) {
          expect(find.byKey(f260Option(t)), findsOneWidget, reason: t);
        }
        expect(
          find.byKey(f260Option(f260Loop)),
          findsNothing,
          reason: 'source',
        );
        expect(
          find.byKey(f260Option(f260Loose)),
          findsNothing,
          reason: 'role-less',
        );
        expect(
          find.byKey(f260Option(f260DailyId)),
          findsNothing,
          reason: 'daily',
        );
        expect(find.byKey(f260Create), findsNothing, reason: 'empty name');
      },
    );

    testWidgets(
      'File in lists every topic note including those the day already uses',
      (tester) async {
        await pumpF260(tester);
        await f260Tap(tester, f260FileIn(f260N1));

        for (final t in [
          f260Loop,
          f260Economy,
          f260Level,
          f260Sleep,
          f260Orphan,
        ]) {
          expect(find.byKey(f260Option(t)), findsOneWidget, reason: t);
        }
        expect(find.byKey(f260Option(f260Loose)), findsNothing);
      },
    );

    testWidgets(
      'typing filters the list by fuzzyScore ignoring case with the best match first',
      (tester) async {
        await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));

        // "sleep" starts with s (score 995), "level design" only contains it.
        await f260TypeTopic(tester, 's');
        expect(find.byKey(f260Option(f260Sleep)), findsOneWidget);
        expect(find.byKey(f260Option(f260Level)), findsOneWidget);
        expect(find.byKey(f260Option(f260Economy)), findsNothing);
        expect(find.byKey(f260Option(f260Orphan)), findsNothing);
        expect(
          f260Top(tester, f260Option(f260Sleep)),
          lessThan(f260Top(tester, f260Option(f260Level))),
        );

        await f260TypeTopic(tester, 'ECON');
        expect(find.byKey(f260Option(f260Economy)), findsOneWidget);
        expect(find.byKey(f260Option(f260Sleep)), findsNothing);
        expect(find.byKey(f260Option(f260Level)), findsNothing);

        await f260TypeTopic(tester, 'zzz');
        for (final t in [f260Economy, f260Level, f260Sleep, f260Orphan]) {
          expect(find.byKey(f260Option(t)), findsNothing, reason: t);
        }
      },
    );

    testWidgets(
      'a subsequence query matches a title that does not contain it',
      (tester) async {
        await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));

        await f260TypeTopic(tester, 'lvdsgn');

        expect(find.byKey(f260Option(f260Level)), findsOneWidget);
        expect(find.byKey(f260Option(f260Sleep)), findsNothing);
        expect(find.byKey(f260Option(f260Economy)), findsNothing);
      },
    );

    testWidgets('a topic among many topic notes is found by its name', (
      tester,
    ) async {
      final db = f260Db();
      for (var i = 0; i < 30; i++) {
        db.seedTopicNote('bulk-$i', 'Bulk topic $i');
      }
      await pumpF260(tester, db: db);
      await f260Tap(tester, f260Move(f260Loop, f260B1));

      await f260TypeTopic(tester, 'Bulk topic 29');

      expect(find.byKey(f260Option('bulk-29')), findsOneWidget);
    });

    testWidgets(
      'an unmatched name offers Create with that name and an exact title does not',
      (tester) async {
        await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));

        await f260TypeTopic(tester, 'Fresh Topic');
        expect(find.byKey(f260Create), findsOneWidget);
        expect(find.text('Create "Fresh Topic"'), findsOneWidget);

        await f260TypeTopic(tester, 'Econ');
        expect(find.byKey(f260Create), findsOneWidget);
        expect(find.text('Create "Econ"'), findsOneWidget);
        expect(find.byKey(f260Option(f260Economy)), findsOneWidget);

        await f260TypeTopic(tester, 'Economy');
        expect(find.byKey(f260Option(f260Economy)), findsOneWidget);
        expect(find.byKey(f260Create), findsNothing, reason: 'exact title');

        await f260TypeTopic(tester, 'Player Loop');
        expect(
          find.byKey(f260Create),
          findsNothing,
          reason: 'the source topic title is a title too',
        );
        expect(find.byKey(f260Option(f260Loop)), findsNothing);

        await f260TypeTopic(tester, '   ');
        expect(find.byKey(f260Create), findsNothing, reason: 'blank name');
      },
    );

    testWidgets('the dialogs carry their field and button labels', (
      tester,
    ) async {
      await pumpF260(tester);
      for (final (open, label, hasTopic) in <(Key, String, bool)>[
        (f260Move(f260Loop, f260B1), 'Move', true),
        (f260FileIn(f260N1), 'File', true),
        (f260Remove(f260Loop, f260B1), 'Remove', false),
      ]) {
        await f260Tap(tester, open);
        expect(
          find.descendant(
            of: find.byKey(f260Confirm),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: '$open confirm label',
        );
        expect(
          find.descendant(
            of: find.byKey(f260Cancel),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(find.text('Why? (optional)'), findsOneWidget);
        expect(find.byKey(f260WhyField), findsOneWidget);
        expect(
          find.byKey(f260TopicField),
          hasTopic ? findsOneWidget : findsNothing,
          reason: '$open topic field',
        );
        await f260Tap(tester, f260Cancel);
      }
    });
  });

  group('moving, removing and filing (AC5, AC6, AC9)', () {
    testWidgets(
      'choosing a target and confirming calls moveBlock once with the Why text then the row moves after the re-read',
      (tester) async {
        final f = await pumpF260(tester);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
          why: 'this is about pricing',
        );

        expect(f.moves, hasLength(1));
        expect(f.moves.single.args, {
          'fromTopicNoteId': f260Loop,
          'toTopicNoteId': f260Economy,
          'date': f260Date,
          'blockId': f260B1,
          'note': 'this is about pricing',
        });
        expect(f.removes, isEmpty);
        expect(f.files, isEmpty);
        expect(find.byKey(f260Confirm), findsNothing, reason: 'dialog closed');
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
        expect(find.byKey(f260Row(f260Loop, f260B2)), findsOneWidget);
        expect(f260Error, findsNothing);
      },
    );

    testWidgets('a blank Why sends no note', (tester) async {
      final f = await pumpF260(tester);

      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Economy,
      );

      expect(f.moves.single.args['note'], isNull);
      expect(f.cli.callsFor('excerpt move').single.hasFlag('note'), isFalse);
    });

    testWidgets('confirming with no target chosen calls nothing', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));

      await f260Tap(tester, f260Confirm);
      expect(f.writes, isEmpty);
      expect(find.byKey(f260Confirm), findsOneWidget, reason: 'still open');

      await f260TypeTopic(tester, 'zzz');
      await f260Tap(tester, f260Confirm);
      expect(f.writes, isEmpty, reason: 'a typed name alone is not a target');
      expect(f.notes.callsTo('addNote'), isEmpty);
    });

    testWidgets(
      'Remove with a Why calls removeBlock once and the row leaves its topic',
      (tester) async {
        final f = await pumpF260(tester);

        await f260Tap(tester, f260Remove(f260Loop, f260B2));
        await f260TypeWhy(tester, 'not a loop thing');
        await f260Tap(tester, f260Confirm);

        expect(f.removes, hasLength(1));
        expect(f.removes.single.args, {
          'topicNoteId': f260Loop,
          'date': f260Date,
          'blockId': f260B2,
          'note': 'not a loop thing',
        });
        expect(f.moves, isEmpty);
        expect(f.files, isEmpty);
        expect(find.byKey(f260Row(f260Loop, f260B2)), findsNothing);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
      },
    );

    testWidgets('Remove without a Why sends no note', (tester) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260Remove(f260Loop, f260B2));
      await f260Tap(tester, f260Confirm);

      expect(f.removes.single.args['note'], isNull);
    });

    testWidgets('File in calls fileBlock once and the row joins the topic', (
      tester,
    ) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260FileIn(f260N1));
      await f260Tap(tester, f260Option(f260Economy));
      await f260TypeWhy(tester, 'belongs to the economy');
      await f260Tap(tester, f260Confirm);

      expect(f.files, hasLength(1));
      expect(f.files.single.args, {
        'topicNoteId': f260Economy,
        'date': f260Date,
        'blockId': f260N1,
        'note': 'belongs to the economy',
      });
      expect(f.moves, isEmpty);
      expect(f.removes, isEmpty);
      expect(find.byKey(f260NotFiledRow(f260N1)), findsNothing);
      expect(find.byKey(f260Row(f260Economy, f260N1)), findsOneWidget);
      expect(_inSection(f260TextCI('Not filed')), findsNothing);
    });

    for (final (name, open, useEsc) in <(String, Key, bool)>[
      (
        'Cancel on Move to calls nothing and changes nothing',
        f260Move(f260Loop, f260B1),
        false,
      ),
      (
        'Esc on Move to calls nothing and changes nothing',
        f260Move(f260Loop, f260B1),
        true,
      ),
      (
        'Cancel on Remove calls nothing and changes nothing',
        f260Remove(f260Loop, f260B1),
        false,
      ),
      (
        'Esc on Remove calls nothing and changes nothing',
        f260Remove(f260Loop, f260B1),
        true,
      ),
      (
        'Cancel on File in calls nothing and changes nothing',
        f260FileIn(f260N1),
        false,
      ),
      (
        'Esc on File in calls nothing and changes nothing',
        f260FileIn(f260N1),
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final f = await pumpF260(tester);
        final rev = RevisionCounter(f.h);
        final filingBefore = _filingCalls(f);
        await f260Tap(tester, open);
        await f260TypeWhy(tester, 'typed reason');
        if (find.byKey(f260TopicField).evaluate().isNotEmpty) {
          await f260Tap(tester, f260Option(f260Economy));
        }

        if (useEsc) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await pumpFrames(tester);
        } else {
          await f260Tap(tester, f260Cancel);
        }

        expect(find.byKey(f260Confirm), findsNothing, reason: 'dialog closed');
        expect(f.writes, isEmpty);
        expect(f.notes.callsTo('addNote'), isEmpty);
        expect(f.cli.callsFor('add'), isEmpty);
        expect(rev.bumps, 0);
        expect(_filingCalls(f), filingBefore);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260NotFiledRow(f260N1)), findsOneWidget);
        expect(f260Error, findsNothing);
        // A reopened dialog starts empty.
        await f260Tap(tester, open);
        expect(_fieldText(tester, f260WhyField), isEmpty);
        if (find.byKey(f260TopicField).evaluate().isNotEmpty) {
          expect(_fieldText(tester, f260TopicField), isEmpty);
        }
      });
    }
  });

  group('keyboard (AC4)', () {
    // Query "s" lists Sleep (best match) then Level Design.
    for (final (name, keys, expected)
        in <(String, List<LogicalKeyboardKey>, String)>[
          (
            'Enter alone picks the best match in the Move to dialog',
            [LogicalKeyboardKey.enter],
            f260Sleep,
          ),
          (
            'ArrowDown then Enter picks the second match in the Move to dialog',
            [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.enter],
            f260Level,
          ),
          (
            'ArrowDown ArrowUp then Enter picks the first match again in the Move to dialog',
            [
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.enter,
            ],
            f260Sleep,
          ),
          (
            'ArrowUp on the first match stays on it in the Move to dialog',
            [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.enter],
            f260Sleep,
          ),
          (
            'ArrowDown past the last match stays on it in the Move to dialog',
            [
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.enter,
            ],
            f260Level,
          ),
        ]) {
      testWidgets(name, (tester) async {
        final f = await pumpF260(tester);
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 's');

        for (final k in keys) {
          await tester.sendKeyEvent(k);
          await pumpFrames(tester);
        }
        // Enter may choose the target and a second Enter confirm it, or
        // one Enter may do both: finish with the keyboard, then the button.
        for (
          var i = 0;
          i < 2 && find.byKey(f260Confirm).evaluate().isNotEmpty;
          i++
        ) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await pumpFrames(tester);
        }
        if (find.byKey(f260Confirm).evaluate().isNotEmpty) {
          await f260Tap(tester, f260Confirm);
        }

        expect(f.moves, hasLength(1));
        expect(f.moves.single.args['toTopicNoteId'], expected);
      });
    }
  });

  group('Create (AC7, AC8)', () {
    testWidgets(
      'confirming Create creates the topic note with role topic and topicNoteBody then moves into it',
      (tester) async {
        final f = await pumpF260(tester);
        final rev = RevisionCounter(f.h);

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');
        await f260Tap(tester, f260Create);
        await f260TypeWhy(tester, 'new home');
        await f260Tap(tester, f260Confirm);

        final add = f.notes.callsTo('addNote').single.args;
        expect(add['role'], 'topic');
        expect(add['contentMd'], topicNoteBody('Fresh Topic'));
        expect(f.cli.callsFor('add').single.flag('role'), 'topic');
        expect(f.moves.single.args, {
          'fromTopicNoteId': f260Loop,
          'toTopicNoteId': createdTopicId,
          'date': f260Date,
          'blockId': f260B1,
          'note': 'new home',
        });
        expect(
          f.cli.calls
              .map((c) => c.subcommand)
              .where((s) => s == 'add' || s == 'excerpt move'),
          ['add', 'excerpt move'],
          reason: 'create first, then move',
        );
        expect(find.byKey(f260Row(createdTopicId, f260B1)), findsOneWidget);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(rev.bumps, 1, reason: 'one bump for the create and the move');
      },
    );

    testWidgets(
      'a move that fails after Create keeps the created note and shows the inline error',
      (tester) async {
        final f = await pumpF260(tester);
        final rev = RevisionCounter(f.h);
        f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');
        await f260Tap(tester, f260Create);
        await f260Tap(tester, f260Confirm);

        expect(f.cli.callsFor('add'), hasLength(1));
        expect(f.moves, hasLength(1));
        expect(f.cli.callsFor('rm'), isEmpty, reason: 'the created note stays');
        final kept = f.db.db.select('SELECT id FROM notes WHERE title = ?', [
          'Fresh Topic',
        ]);
        expect(kept.single['id'], createdTopicId);
        expect(f260Error, findsOneWidget);
        expect(
          find.descendant(of: f260Error, matching: find.textContaining('boom')),
          findsOneWidget,
        );
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260Row(createdTopicId, f260B1)), findsNothing);
        expect(rev.bumps, 1);
      },
    );

    testWidgets(
      'a Create that fails moves nothing and shows the inline error',
      (tester) async {
        final f = await pumpF260(tester);
        f.cli.on(
          'add',
          (_) => FakeMemexCli.error('title_conflict', 'already titled so'),
        );

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');
        await f260Tap(tester, f260Create);
        await f260Tap(tester, f260Confirm);

        expect(f.moves, isEmpty);
        expect(
          find.descendant(
            of: f260Error,
            matching: find.textContaining('already titled so'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
      },
    );
  });

  group('in flight (AC10)', () {
    Future<F260> startGatedMove(WidgetTester tester) async {
      final f = await pumpF260(tester);
      f.feedback.gate('moveBlock');
      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Economy,
      );
      return f;
    }

    testWidgets(
      'while a fix is in flight its row controls are disabled and other rows are not',
      (tester) async {
        final f = await startGatedMove(tester);

        expect(f.moves, hasLength(1));
        expect(_enabled(tester, f260Move(f260Loop, f260B1)), isFalse);
        expect(_enabled(tester, f260Remove(f260Loop, f260B1)), isFalse);
        expect(_enabled(tester, f260Move(f260Loop, f260B2)), isTrue);
        expect(_enabled(tester, f260Remove(f260Loop, f260B2)), isTrue);
        expect(_enabled(tester, f260Move(f260Economy, f260B3)), isTrue);
        expect(_enabled(tester, f260FileIn(f260N1)), isTrue);

        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
        expect(_enabled(tester, f260Move(f260Economy, f260B1)), isTrue);
      },
    );

    testWidgets('a second press while a fix is in flight calls nothing', (
      tester,
    ) async {
      final f = await startGatedMove(tester);

      for (final key in [
        f260Move(f260Loop, f260B1),
        f260Remove(f260Loop, f260B1),
      ]) {
        await tester.tap(find.byKey(key), warnIfMissed: false);
        await pumpFrames(tester);
        if (find.byKey(f260Confirm).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(f260Confirm), warnIfMissed: false);
          await pumpFrames(tester);
        }
      }

      expect(f.moves, hasLength(1));
      expect(f.removes, isEmpty);
      expect(f.files, isEmpty);
      f.feedback.gates['moveBlock']!.single.complete();
      await pumpFrames(tester);
      expect(f.moves, hasLength(1));
      expect(f.cli.callsFor('excerpt move'), hasLength(1));
    });

    testWidgets('two presses of Confirm in one frame call once', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Economy));

      await tester.tap(find.byKey(f260Confirm));
      await tester.tap(find.byKey(f260Confirm), warnIfMissed: false);
      await pumpFrames(tester);

      expect(f.moves, hasLength(1));
      expect(f.cli.callsFor('excerpt move'), hasLength(1));
    });

    testWidgets(
      'a fix on one row does not stop a fix on another row at the same time',
      (tester) async {
        final f = await startGatedMove(tester);

        await f260Tap(tester, f260Remove(f260Economy, f260B3));
        await f260Tap(tester, f260Confirm);

        expect(f.moves, hasLength(1));
        expect(f.removes, hasLength(1));
        expect(f.removes.single.args['blockId'], f260B3);
        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
      },
    );
  });

  group('failures (AC11)', () {
    testWidgets(
      'a failed fix leaves the row shows the inline error and enables the controls again',
      (tester) async {
        final f = await pumpF260(tester);
        f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );

        expect(f260Error, findsOneWidget);
        expect(
          find.descendant(of: f260Error, matching: find.textContaining('boom')),
          findsOneWidget,
        );
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsNothing);
        expect(_enabled(tester, f260Move(f260Loop, f260B1)), isTrue);
        expect(_enabled(tester, f260Remove(f260Loop, f260B1)), isTrue);

        // Try again: the dialog opens and the second try works.
        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );
        expect(f.moves, hasLength(2));
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
      },
    );

    testWidgets('the inline error can be dismissed', (tester) async {
      final f = await pumpF260(tester);
      f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await f260Tap(tester, f260Confirm);
      expect(f260Error, findsOneWidget);

      await f260Tap(tester, const Key('inline-error-dismiss'));

      expect(f260Error, findsNothing);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
    });

    testWidgets(
      'block_not_found refreshes the section and keeps the other rows',
      (tester) async {
        final f = await pumpF260(tester);
        f.server.dropBlock(f260B1);
        final filingBefore = _filingCalls(f);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );

        expect(f.moves, hasLength(1));
        expect(_filingCalls(f), greaterThan(filingBefore), reason: 'refreshed');
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsNothing);
        expect(find.byKey(f260Row(f260Loop, f260B2)), findsOneWidget);
        expect(find.byKey(f260Row(f260Economy, f260B3)), findsOneWidget);
        expect(find.byKey(f260NotFiledRow(f260N1)), findsOneWidget);
        expect(find.byKey(f260Section), findsOneWidget);
      },
    );

    testWidgets('block_not_found on Remove and File in refreshes too', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.server.dropBlock(f260B2);

      await f260Tap(tester, f260Remove(f260Loop, f260B2));
      await f260Tap(tester, f260Confirm);
      expect(find.byKey(f260Row(f260Loop, f260B2)), findsNothing);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);

      f.server.dropBlock(f260N1);
      await f260Tap(tester, f260FileIn(f260N1));
      await f260Tap(tester, f260Option(f260Economy));
      await f260Tap(tester, f260Confirm);
      expect(find.byKey(f260NotFiledRow(f260N1)), findsNothing);
      expect(find.byKey(f260Row(f260Economy, f260N1)), findsNothing);
      expect(find.byKey(f260Row(f260Economy, f260B3)), findsOneWidget);
    });
  });

  group('revision and editor (AC12, AC13)', () {
    testWidgets(
      'a fix bumps vaultRevisionProvider once after the write returns',
      (tester) async {
        final f = await pumpF260(tester);
        final rev = RevisionCounter(f.h);
        f.feedback.gate('moveBlock');

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Economy));
        await f260Tap(tester, f260Confirm);
        expect(f.moves, hasLength(1));
        expect(rev.bumps, 0, reason: 'nothing bumps while the write runs');

        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        expect(rev.bumps, 1);
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
      },
    );

    testWidgets('each kind of fix bumps once and a failed fix bumps once', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      final rev = RevisionCounter(f.h);

      await f260Tap(tester, f260Remove(f260Loop, f260B2));
      await f260Tap(tester, f260Confirm);
      expect(rev.bumps, 1, reason: 'Remove');

      await f260Tap(tester, f260FileIn(f260N1));
      await f260Tap(tester, f260Option(f260Economy));
      await f260Tap(tester, f260Confirm);
      expect(rev.bumps, 2, reason: 'File in');

      f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await f260Tap(tester, f260Confirm);
      expect(rev.bumps, 3, reason: 'a failed Remove');
    });

    testWidgets('a fix does not change the Reviewed chip and saves nothing', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      Finder label(String t) => find.descendant(
        of: find.byKey(const Key('review-chip')),
        matching: find.text(t),
      );
      expect(label('Reviewed'), findsOneWidget);

      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Sleep,
      );
      await _drain(tester, f);

      expect(label('Reviewed'), findsOneWidget);
      expect(label('Changed since review'), findsNothing);
      expect(f.cli.callsFor('update'), isEmpty);
    });

    testWidgets(
      'a fix that adds a chip to the open daily note keeps a pending edit with no conflict banner',
      (tester) async {
        final f = await pumpF260(tester);
        await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
        await tester.pump();
        expect(f.h.read(editorControllerProvider).status, SaveStatus.dirty);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Sleep,
        );

        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 2, reason: 'the chip add version');
        expect(editor.contentMd, 'pending thought');
        expect(editor.status, SaveStatus.dirty);
        expect(find.text('conflict — reload'), findsNothing);
        expect(editorBodyText(tester), 'pending thought');

        await _drain(tester, f);

        final update = f.cli.callsFor('update').single;
        expect(update.flag('note-id'), f260DailyId);
        expect(update.flag('expected-version'), '2');
        expect(update.stdinBody, 'pending thought');
        expect(f.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(find.text('conflict — reload'), findsNothing);
        expect(find.byKey(const Key('inline-error')), findsNothing);
      },
    );

    testWidgets(
      'a fix that adds a chip to the open daily note rebases a clean editor so the next edit saves',
      (tester) async {
        final f = await pumpF260(tester);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B2,
          target: f260Orphan,
        );
        await _drain(tester, f);
        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 2);
        expect(editor.status, SaveStatus.clean);
        expect(f.cli.callsFor('update'), isEmpty, reason: 'no spurious save');

        await tester.enterText(find.byKey(editorBodyKey), 'typed after');
        await tester.pump();
        await _drain(tester, f);

        final update = f.cli.callsFor('update').single;
        expect(update.flag('expected-version'), '2');
        expect(update.stdinBody, 'typed after');
        expect(f.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(find.text('conflict — reload'), findsNothing);
      },
    );

    testWidgets(
      'a fix that leaves the daily note version alone keeps a pending edit on the same base',
      (tester) async {
        final f = await pumpF260(tester);
        f.server.chipBumpsDaily = false;
        await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
        await tester.pump();

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );

        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 1);
        expect(editor.contentMd, 'pending thought');
        expect(find.text('conflict — reload'), findsNothing);
        await _drain(tester, f);
        final update = f.cli.callsFor('update').single;
        expect(update.flag('expected-version'), '1');
        expect(update.stdinBody, 'pending thought');
      },
    );

    testWidgets('a fix that fails does not rebase or disturb a pending edit', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
      await tester.pump();
      f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');

      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Sleep,
      );

      final editor = f.h.read(editorControllerProvider);
      expect(editor.contentMd, 'pending thought');
      expect(editor.lastSavedVersion, 1);
      expect(editor.status, SaveStatus.dirty);
      expect(find.text('conflict — reload'), findsNothing);
      await _drain(tester, f);
      expect(f.cli.callsFor('update').single.flag('expected-version'), '1');
    });
  });
}
