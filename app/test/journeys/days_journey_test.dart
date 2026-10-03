// WI #23 (A6): the sidebar Days mode and the Days/Topics switch (Req 20,
// 49, 50, 51, 53; TD8; Spec TS4). Robot journeys over the whole workspace
// with FakeVaultDb, FakeMemexCli and FakeClock seams.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/review_state_colors.dart';

import '../robots/days_robot.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

const _oct02 = 'daily-2026-10-02';
const _sep30 = 'daily-2026-09-30';
const _sep05 = 'daily-2026-09-05';
const _oct03 = 'daily-2026-10-03';
const _plain = 'n-plain';

/// Three past daily notes in two months, one per review state, and a
/// role-less note. Today (2026-10-03 at the default FakeClock) has no note.
FakeVaultDb _threeDays() {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-10-02', version: 2);
  db.seedBlock(
    _oct02,
    'b-oct02',
    ord: 0,
    text: 'Called the bank\nabout the loan',
  );
  db.seedDayReview(
    _oct02,
    contentVersion: 2,
    reviewedContentVersion: 2,
    reviewedAt: DateTime(2026, 10, 2, 18).millisecondsSinceEpoch,
  );

  db.seedDailyNote('2026-09-30', version: 3);
  db.seedBlock(_sep30, 'b-sep30', ord: 0, text: 'September wrap');
  db.seedDayReview(
    _sep30,
    contentVersion: 3,
    reviewedContentVersion: 2,
    reviewedAt: DateTime(2026, 9, 30, 18).millisecondsSinceEpoch,
  );

  db.seedDailyNote('2026-09-05');
  db.seedBlock(_sep05, 'b-sep05-2', ord: 1, text: 'Second block');
  db.seedBlock(_sep05, 'b-sep05-1', ord: 0, text: 'Garden');
  // No day_reviews row: Unreviewed.

  db.seedNote(id: _plain, title: 'Plain note', content: 'not a day');
  return db;
}

/// [db] plus the daily note of 2026-10-03 with a first block.
FakeVaultDb _withToday(FakeVaultDb db, {String text = 'Late thoughts'}) {
  db.seedDailyNote('2026-10-03');
  db.seedBlock(_oct03, 'b-oct03', ord: 0, text: text);
  return db;
}

void main() {
  group('the Days/Topics switch (AC1)', () {
    testWidgets(
      'the sidebar shows the Days and Topics switch and a vault with no stored mode opens in Days',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        expect(r.daysSwitch, findsOneWidget);
        expect(r.topicsSwitch, findsOneWidget);
        expect(
          r.textsUnder(r.daysSwitch).map((t) => t.trim()),
          contains('Days'),
        );
        expect(
          r.textsUnder(r.topicsSwitch).map((t) => t.trim()),
          contains('Topics'),
        );
        expect(r.textsUnder(r.daysSwitch), isNot(contains('Topics')));
        expect(r.h.read(sidebarModeProvider), SidebarMode.days);
        expect(r.daysPane, findsOneWidget);
        expect(r.notesRail, findsNothing);
        // The switch sits above the Days list.
        expect(r.top(r.daysSwitch), lessThan(r.top(r.daysPane)));
        expect(r.top(r.topicsSwitch), lessThan(r.top(r.daysPane)));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the mode persists per vault (AC2)', () {
    testWidgets(
      'a vault whose ui_state.json holds sidebar_mode topics opens in Topics',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(
          db: _threeDays(),
          uiState: {
            'tabs': <Object?>[],
            'active_tab_index': 0,
            'canvas_viewports': <String, Object?>{},
            'sidebar_mode': 'topics',
          },
        );

        expect(r.h.read(sidebarModeProvider), SidebarMode.topics);
        expect(r.notesRail, findsOneWidget);
        expect(r.daysPane, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a vault whose ui_state.json holds an unknown sidebar_mode opens in Days',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(
          db: _threeDays(),
          uiState: {
            'tabs': <Object?>[],
            'active_tab_index': 0,
            'canvas_viewports': <String, Object?>{},
            'sidebar_mode': 'graph',
          },
        );

        expect(r.h.read(sidebarModeProvider), SidebarMode.days);
        expect(r.daysPane, findsOneWidget);
        expect(r.notesRail, findsNothing);
      },
    );
  });

  group('month groups (AC3)', () {
    testWidgets(
      'the Days pane shows month headers and rows newest first with no rows for days without a note',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        r.expectMonthHeader('2026-10', 'October 2026');
        r.expectMonthHeader('2026-09', 'September 2026');
        expect(r.keyedWithPrefix('days-month-'), findsNWidgets(2));
        expect(r.datedRows, findsNWidgets(3));
        expect(r.row('2026-10-01'), findsNothing);
        expect(r.row('2026-10-03'), findsNothing);

        final order = [
          r.top(r.todayRow),
          r.top(r.month('2026-10')),
          r.top(r.row('2026-10-02')),
          r.top(r.month('2026-09')),
          r.top(r.row('2026-09-30')),
          r.top(r.row('2026-09-05')),
        ];
        for (var i = 1; i < order.length; i++) {
          expect(order[i], greaterThan(order[i - 1]), reason: 'item $i');
        }
      },
    );

    testWidgets(
      'a daily note saved elsewhere appears in the Days pane after a vault revision bump',
      (tester) async {
        final db = _threeDays();
        final r = DaysRobot(tester);
        await r.launch(db: db);
        expect(r.row('2026-10-01'), findsNothing);

        db.seedDailyNote('2026-10-01');
        db.seedBlock(
          'daily-2026-10-01',
          'b-oct01',
          ord: 0,
          text: 'Captured by agent',
        );
        await r.bumpRevision();

        r.expectDatedRow('2026-10-01', preview: 'Captured by agent');
        expect(
          r.top(r.row('2026-10-01')),
          greaterThan(r.top(r.row('2026-10-02'))),
        );
        expect(r.top(r.row('2026-10-01')), lessThan(r.top(r.month('2026-09'))));
      },
    );
  });

  group('the Today row (AC4)', () {
    testWidgets(
      'with the note of today saved the Days pane shows one Today row and no dated row for today',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _withToday(_threeDays()));

        r.expectTodayRowFirst();
        expect(r.todayRow, findsOneWidget);
        expect(r.row('2026-10-03'), findsNothing);
        expect(r.datedRows, findsNWidgets(3));
        expect(r.empty, findsNothing);
      },
    );

    testWidgets(
      'with no note for today the Today row comes first and has no review dot',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        r.expectTodayRowFirst();
        r.expectTodayRowHasNoDot();
        expect(r.dot('2026-10-03'), findsNothing);
      },
    );
  });

  group('dated rows (AC5)', () {
    testWidgets(
      'each dated row shows its ISO date, the first line of its first block and a dot labelled with its review state',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        r.expectDatedRow(
          '2026-10-02',
          preview: 'Called the bank',
          hidden: ['about the loan'],
        );
        r.expectDatedRow('2026-09-30', preview: 'September wrap');
        r.expectDatedRow(
          '2026-09-05',
          preview: 'Garden',
          hidden: ['Second block'],
        );

        r.expectDotLabel('2026-10-02', ReviewState.reviewed);
        r.expectDotLabel('2026-09-30', ReviewState.changedSinceReview);
        r.expectDotLabel('2026-09-05', ReviewState.unreviewed);

        // Each dot belongs to its own row.
        for (final date in ['2026-10-02', '2026-09-30', '2026-09-05']) {
          expect(
            find.descendant(of: r.row(date), matching: r.dot(date)),
            findsOneWidget,
          );
        }
        semantics.dispose();
      },
    );

    testWidgets(
      'the dot label follows a review of the day after a vault revision bump',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final db = _threeDays();
        final r = DaysRobot(tester);
        await r.launch(db: db);
        r.expectDotLabel('2026-09-05', ReviewState.unreviewed);

        db.seedDayReview(
          _sep05,
          contentVersion: 1,
          reviewedContentVersion: 1,
          reviewedAt: DateTime(2026, 10, 3, 8).millisecondsSinceEpoch,
        );
        await r.bumpRevision();

        r.expectDotLabel('2026-09-05', ReviewState.reviewed);
        semantics.dispose();
      },
    );
  });

  group('dot colours (AC6)', () {
    testWidgets(
      'each dot is painted in the review state colour from the theme helper',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        final expected = {
          '2026-10-02': ReviewState.reviewed,
          '2026-09-30': ReviewState.changedSinceReview,
          '2026-09-05': ReviewState.unreviewed,
        };
        expected.forEach((date, state) {
          final colors = r.colorsUnder(r.dot(date));
          expect(
            colors,
            contains(reviewStateColor(state)),
            reason: '$date is ${state.label}',
          );
          for (final other in ReviewState.values.where((s) => s != state)) {
            expect(
              colors,
              isNot(contains(reviewStateColor(other))),
              reason: '$date is not ${other.label}',
            );
          }
        });
      },
    );
  });

  group('empty Days (AC7)', () {
    testWidgets(
      'with no saved daily notes the Days pane shows the Today row followed by the empty copy',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: _plain, title: 'Plain note', content: 'not a day');
        final r = DaysRobot(tester);
        await r.launch(db: db);

        r.expectTodayRowFirst();
        r.expectTodayRowHasNoDot();
        expect(r.empty, findsOneWidget);
        expect(
          r.textsUnder(r.empty).map((t) => t.trim()),
          contains("Start typing in today's note."),
        );
        expect(r.top(r.empty), greaterThan(r.top(r.todayRow)));
        expect(r.datedRows, findsNothing);
        expect(r.keyedWithPrefix('days-month-'), findsNothing);
        expect(
          find.descendant(of: r.daysPane, matching: r.empty),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a vault whose only daily note is today shows the Today row without the empty copy',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _withToday(FakeVaultDb.v5()));

        r.expectTodayRowFirst();
        expect(r.empty, findsNothing);
        expect(r.datedRows, findsNothing);
      },
    );

    testWidgets(
      'the empty copy goes away once a daily note is saved and the vault revision bumps',
      (tester) async {
        final db = FakeVaultDb.v5();
        final r = DaysRobot(tester);
        await r.launch(db: db);
        expect(r.empty, findsOneWidget);

        _withToday(db, text: 'First words');
        await r.bumpRevision();

        expect(r.empty, findsNothing);
        expect(r.todayRow, findsOneWidget);
      },
    );
  });

  group('opening rows (AC8)', () {
    testWidgets('tapping a dated row opens the tab of that daily note', (
      tester,
    ) async {
      final r = DaysRobot(tester);
      await r.launch(db: _threeDays());
      expect(r.activeTab, const VirtualTodayTab('2026-10-03'));

      await r.openRow('2026-09-30');
      expect(r.activeTab, const NoteTab(_sep30));

      await r.openRow('2026-10-02');
      expect(r.activeTab, const NoteTab(_oct02));

      // Tapping an already open row focuses its tab; no duplicate.
      await r.openRow('2026-09-30');
      expect(r.activeTab, const NoteTab(_sep30));
      expect(
        r.tabs.tabs.where((t) => t == const NoteTab(_sep30)),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'tapping the Today row with no note for today focuses the virtual Today tab without a second tab',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        await r.openRow('2026-09-30');
        expect(r.activeTab, const NoteTab(_sep30));

        await r.openToday();
        expect(r.activeTab, isA<VirtualTodayTab>());
        expect((r.activeTab! as VirtualTodayTab).date, '2026-10-03');
        expect(r.tabs.tabs.whereType<VirtualTodayTab>(), hasLength(1));
        // Opening the virtual note writes nothing.
        expect(r.h.cli.callsFor('add'), isEmpty);
      },
    );

    testWidgets(
      'tapping the Today row after closing the virtual Today tab opens it again',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());
        await r.openRow('2026-09-30');
        r.h
            .read(tabsProvider.notifier)
            .close(const VirtualTodayTab('2026-10-03'));
        await tester.pump();
        expect(r.tabs.tabs.whereType<VirtualTodayTab>(), isEmpty);

        await r.openToday();

        expect(r.activeTab, const VirtualTodayTab('2026-10-03'));
        expect(r.tabs.tabs.whereType<VirtualTodayTab>(), hasLength(1));
      },
    );

    testWidgets('tapping the Today row opens the saved note of today', (
      tester,
    ) async {
      final r = DaysRobot(tester);
      await r.launch(db: _withToday(_threeDays()));

      await r.openRow('2026-09-30');
      expect(r.activeTab, const NoteTab(_sep30));

      await r.openToday();
      expect(r.activeTab, const NoteTab(_oct03));
      expect(r.activeTab, isNot(isA<VirtualTodayTab>()));
      expect(
        r.tabs.tabs.where((t) => t == const NoteTab(_oct03)),
        hasLength(1),
      );
      expect(r.tabs.tabs.whereType<VirtualTodayTab>(), isEmpty);
    });
  });

  group('midnight rollover (AC9)', () {
    testWidgets(
      'two minutes after 23:59 a new Today row for 2026-10-04 appears, the 2026-10-03 row shows its date and the active tab stays',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(
          db: _withToday(_threeDays()),
          clock: FakeClock(DateTime(2026, 10, 3, 23, 59)),
        );
        expect(r.activeTab, const NoteTab(_oct03));
        expect(r.row('2026-10-03'), findsNothing);
        final tabsBefore = List<WorkspaceTab>.of(r.tabs.tabs);
        final activeBefore = r.activeTab;

        await r.advanceClock(const Duration(minutes: 2));

        r.expectTodayRowFirst();
        r.expectTodayRowHasNoDot();
        expect(r.row('2026-10-04'), findsNothing);
        r.expectDatedRow('2026-10-03', preview: 'Late thoughts');
        expect(r.dot('2026-10-03'), findsOneWidget);
        expect(
          r.top(r.row('2026-10-03')),
          lessThan(r.top(r.row('2026-10-02'))),
        );
        r.expectMonthHeader('2026-10', 'October 2026');
        expect(r.datedRows, findsNWidgets(4));

        expect(r.activeTab, activeBefore);
        expect(r.tabs.tabs, tabsBefore);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'after midnight the Today row opens the virtual Today tab for 2026-10-04 and the 2026-10-03 row opens its note',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(
          db: _withToday(_threeDays()),
          clock: FakeClock(DateTime(2026, 10, 3, 23, 59)),
        );
        await r.advanceClock(const Duration(minutes: 2));

        await r.openToday();
        expect(r.activeTab, const VirtualTodayTab('2026-10-04'));

        await r.openRow('2026-10-03');
        expect(r.activeTab, const NoteTab(_oct03));
        expect(
          r.tabs.tabs.where((t) => t == const NoteTab(_oct03)),
          hasLength(1),
        );
      },
    );

    testWidgets(
      'at midnight into November the 2026-10-31 row appears under October 2026',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-10-31');
        db.seedBlock('daily-2026-10-31', 'b-oct31', ord: 0, text: 'Halloween');
        final r = DaysRobot(tester);
        await r.launch(
          db: db,
          clock: FakeClock(DateTime(2026, 10, 31, 23, 59)),
        );
        expect(r.row('2026-10-31'), findsNothing);

        await r.advanceClock(const Duration(minutes: 2));

        r.expectTodayRowFirst();
        r.expectDatedRow('2026-10-31', preview: 'Halloween');
        r.expectMonthHeader('2026-10', 'October 2026');
        expect(r.top(r.month('2026-10')), lessThan(r.top(r.row('2026-10-31'))));
      },
    );
  });

  group('Topics mode before #24 (AC10)', () {
    testWidgets(
      'in Topics mode the sidebar shows the existing notes pane with every note reachable',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        await r.chooseTopics();

        expect(r.h.read(sidebarModeProvider), SidebarMode.topics);
        expect(r.notesRail, findsOneWidget);
        expect(r.daysPane, findsNothing);
        expect(find.byKey(const Key('note-list-item-$_plain')), findsOneWidget);
        expect(find.byKey(const Key('note-list-item-$_oct02')), findsOneWidget);

        await tester.tap(find.byKey(const Key('note-list-item-$_plain')));
        await tester.pump();
        expect(r.activeTab, const NoteTab(_plain));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('choosing Days again brings back the Days pane', (
      tester,
    ) async {
      final r = DaysRobot(tester);
      await r.launch(db: _threeDays());

      await r.chooseTopics();
      expect(r.daysPane, findsNothing);

      await r.chooseDays();
      expect(r.h.read(sidebarModeProvider), SidebarMode.days);
      expect(r.daysPane, findsOneWidget);
      expect(r.notesRail, findsNothing);
      expect(r.row('2026-10-02'), findsOneWidget);
    });
  });

  // Implementer additions (#23): behaviour beyond the ACs.
  group('implementer additions', () {
    testWidgets(
      'the switch marks the chosen mode selected for screen readers and in colour',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        expect(
          tester.getSemantics(r.daysSwitch),
          isSemantics(isButton: true, isSelected: true),
        );
        expect(
          tester.getSemantics(r.topicsSwitch),
          isSemantics(isButton: true, isSelected: false),
        );
        expect(_fill(r.daysSwitch), OmColors.surface4);
        expect(_fill(r.topicsSwitch), isNot(OmColors.surface4));

        await r.chooseTopics();

        expect(
          tester.getSemantics(r.daysSwitch),
          isSemantics(isButton: true, isSelected: false),
        );
        expect(
          tester.getSemantics(r.topicsSwitch),
          isSemantics(isButton: true, isSelected: true),
        );
        expect(_fill(r.daysSwitch), isNot(OmColors.surface4));
        expect(_fill(r.topicsSwitch), OmColors.surface4);
        semantics.dispose();
      },
    );

    testWidgets(
      'the row of the active tab is highlighted and no other row is',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());
        // Launch: the virtual Today tab is active.
        expect(_fill(r.todayRow), OmColors.surface4);
        expect(_fill(r.row('2026-09-30')), isNot(OmColors.surface4));

        await r.openRow('2026-09-30');

        expect(_fill(r.todayRow), isNot(OmColors.surface4));
        expect(_fill(r.row('2026-09-30')), OmColors.surface4);
        expect(_fill(r.row('2026-10-02')), isNot(OmColors.surface4));
      },
    );

    testWidgets(
      'the Today row backed by the saved note of today is highlighted while its tab is active and carries its dot',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _withToday(_threeDays()));

        expect(r.activeTab, const NoteTab(_oct03));
        expect(_fill(r.todayRow), OmColors.surface4);
        expect(
          find.descendant(of: r.todayRow, matching: r.dot('2026-10-03')),
          findsOneWidget,
        );
        expect(
          r.textsUnder(r.todayRow).any((t) => t.contains('Late thoughts')),
          isTrue,
        );
      },
    );

    testWidgets(
      'in Topics mode the tree header sort action toggles between edited and a-z',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());
        await r.chooseTopics();
        expect(r.h.read(sidebarSortProvider), NoteSortMode.lastEdited);

        await r.tap(find.text('SORT: EDITED'));
        expect(r.h.read(sidebarSortProvider), NoteSortMode.alphabetical);

        await r.tap(find.text('SORT: A–Z'));
        expect(r.h.read(sidebarSortProvider), NoteSortMode.lastEdited);
      },
    );

    testWidgets(
      'with past daily notes and no note for today the empty copy is not shown',
      (tester) async {
        final r = DaysRobot(tester);
        await r.launch(db: _threeDays());

        expect(r.todayRow, findsOneWidget);
        expect(r.datedRows, findsNWidgets(3));
        expect(r.empty, findsNothing);
      },
    );
  });
}

/// The fill colour of the first decorated box under [f] (a Days row or a
/// mode switch segment).
Color? _fill(Finder f) {
  final box =
      find
              .descendant(
                of: f,
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.decoration is BoxDecoration,
                ),
              )
              .evaluate()
              .first
              .widget
          as Container;
  return (box.decoration! as BoxDecoration).color;
}
