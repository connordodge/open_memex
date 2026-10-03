// WI #29 (A11): the right panel's Activity tab becomes the per-note change
// log read from `agent_changes` (newest first, timestamp + day reviewed +
// bullets). Topic notes show their own entries; no entries shows the
// existing empty copy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/activity_seeds.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/review_fakes.dart';

const _dailyId = 'daily-2026-09-05';

// The shared Eyebrow atom renders its text upper-cased.
const _eyebrow = 'AGENT ACTIVITY · THIS NOTE';
const _emptyCopy =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

int _ms(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

Finder _entry(String id) => find.byKey(Key('activity-entry-$id'));

Finder _in(Finder entry, String text) =>
    find.descendant(of: entry, matching: find.textContaining(text));

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

/// Seed a daily note with three entries inserted out of display order.
FakeVaultDb _dbWithThreeEntries() {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-09-05', id: _dailyId);
  // Insert order: middle, oldest, newest. Id order differs from both.
  db.seedAgentChange(
    'ac-3',
    _dailyId,
    day: '2026-09-05',
    createdAt: _ms(2026, 9, 5, 14, 32),
    bullets: ['Tidied the morning list', 'Linked Gardening', 'Flagged a typo'],
  );
  db.seedAgentChange(
    'ac-1',
    _dailyId,
    day: '2026-09-02',
    createdAt: _ms(2026, 9, 3, 8, 5),
    bullets: ['Read the Sep 2 entry'],
  );
  db.seedAgentChange(
    'ac-2',
    _dailyId,
    day: '2026-09-04',
    createdAt: _ms(2026, 9, 6, 7, 40),
    bullets: ['Added a Topics chip', 'Moved a stray line'],
  );
  return db;
}

Future<WorkspaceHarness> _openActivity(
  WidgetTester tester,
  FakeVaultDb db,
  String noteId,
) async {
  final h = await pumpWorkspace(tester, db: db);
  await openNoteTab(tester, h, noteId);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.activity;
  await pumpFrames(tester);
  return h;
}

void main() {
  group('Activity tab entries (AC7)', () {
    testWidgets(
      'the Activity tab lists a note with three agent_changes rows newest first',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(_entry('ac-1'), findsOneWidget);
        expect(_entry('ac-2'), findsOneWidget);
        expect(_entry('ac-3'), findsOneWidget);
        // Newest (6 Sep) above 5 Sep above 3 Sep.
        expect(
          _top(tester, _entry('ac-2')),
          lessThan(_top(tester, _entry('ac-3'))),
        );
        expect(
          _top(tester, _entry('ac-3')),
          lessThan(_top(tester, _entry('ac-1'))),
        );
        expect(find.byKey(const Key('activity-empty')), findsNothing);
      },
    );

    testWidgets(
      'each Activity entry shows its timestamp as 5 Sep 2026, 14:32 and its day reviewed as 2026-09-05',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(_in(_entry('ac-3'), '5 Sep 2026, 14:32'), findsOneWidget);
        expect(_in(_entry('ac-3'), '2026-09-05'), findsOneWidget);
        // The other entries carry their own timestamp and day, zero padded.
        expect(_in(_entry('ac-1'), '3 Sep 2026, 08:05'), findsOneWidget);
        expect(_in(_entry('ac-1'), '2026-09-02'), findsOneWidget);
        expect(_in(_entry('ac-2'), '6 Sep 2026, 07:40'), findsOneWidget);
        expect(_in(_entry('ac-2'), '2026-09-04'), findsOneWidget);
        // The time is local, not the day reviewed: no cross-contamination.
        expect(_in(_entry('ac-3'), '2026-09-04'), findsNothing);
        expect(_in(_entry('ac-1'), '5 Sep 2026'), findsNothing);
      },
    );

    testWidgets('each Activity entry shows every bullet in stored order', (
      tester,
    ) async {
      await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

      final b1 = _in(_entry('ac-3'), 'Tidied the morning list');
      final b2 = _in(_entry('ac-3'), 'Linked Gardening');
      final b3 = _in(_entry('ac-3'), 'Flagged a typo');
      expect(b1, findsOneWidget);
      expect(b2, findsOneWidget);
      expect(b3, findsOneWidget);
      expect(_top(tester, b1), lessThan(_top(tester, b2)));
      expect(_top(tester, b2), lessThan(_top(tester, b3)));

      expect(_in(_entry('ac-2'), 'Added a Topics chip'), findsOneWidget);
      expect(_in(_entry('ac-2'), 'Moved a stray line'), findsOneWidget);
      expect(_in(_entry('ac-1'), 'Read the Sep 2 entry'), findsOneWidget);
      // A bullet belongs to its own entry only.
      expect(_in(_entry('ac-1'), 'Linked Gardening'), findsNothing);
    });

    testWidgets(
      'the Activity tab keeps the agent activity eyebrow when it lists entries',
      (tester) async {
        await _openActivity(tester, _dbWithThreeEntries(), _dailyId);

        expect(find.text(_eyebrow), findsOneWidget);
      },
    );

    testWidgets(
      'a new agent_changes row appears in the open Activity tab after a vault revision bump',
      (tester) async {
        final db = _dbWithThreeEntries();
        final h = await _openActivity(tester, db, _dailyId);
        expect(_entry('ac-4'), findsNothing);

        db.seedAgentChange(
          'ac-4',
          _dailyId,
          day: '2026-09-06',
          createdAt: _ms(2026, 9, 7, 10, 0),
          bullets: ['Fresh entry'],
        );
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(_entry('ac-4'), findsOneWidget);
        expect(_in(_entry('ac-4'), 'Fresh entry'), findsOneWidget);
        // Newest first: the new entry sits above the previous newest.
        expect(
          _top(tester, _entry('ac-4')),
          lessThan(_top(tester, _entry('ac-2'))),
        );
      },
    );
  });

  group('Activity tab for topic notes (AC8)', () {
    testWidgets(
      'the Activity tab for a topic note lists that topic note entries and not the daily note ones',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        db.seedTopicNote('topic-1', 'Gardening');
        db.seedAgentChange(
          'ac-daily',
          _dailyId,
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 14, 32),
          bullets: ['Daily only bullet'],
        );
        db.seedAgentChange(
          'ac-topic',
          'topic-1',
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 15, 0),
          bullets: ['Topic only bullet'],
        );
        final h = await _openActivity(tester, db, 'topic-1');

        expect(_entry('ac-topic'), findsOneWidget);
        expect(_in(_entry('ac-topic'), 'Topic only bullet'), findsOneWidget);
        expect(_entry('ac-daily'), findsNothing);
        expect(find.text('Daily only bullet'), findsNothing);

        // Switching to the daily note swaps the log.
        await openNoteTab(tester, h, _dailyId);

        expect(_entry('ac-daily'), findsOneWidget);
        expect(_entry('ac-topic'), findsNothing);
        expect(find.text('Topic only bullet'), findsNothing);
      },
    );
  });

  group('Activity tab empty states (AC9, AC11)', () {
    testWidgets(
      'the Activity tab for a note with no entries shows the empty copy under Key activity-empty',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        await _openActivity(tester, db, _dailyId);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
        expect(find.text(_eyebrow), findsOneWidget);
      },
    );

    testWidgets(
      'the Activity tab shows the empty copy for a note whose only entries belong to another note',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        db.seedTopicNote('topic-1', 'Gardening');
        db.seedAgentChange(
          'ac-topic',
          'topic-1',
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 15, 0),
          bullets: ['Topic only bullet'],
        );
        await _openActivity(tester, db, _dailyId);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(_entry('ac-topic'), findsNothing);
      },
    );

    testWidgets(
      'the Activity tab on a V4 vault shows the empty copy and does not throw',
      (tester) async {
        final db = FakeVaultDb.v4();
        db.seedNote(id: _dailyId, title: '2026-09-05', role: 'daily');
        await _openActivity(tester, db, _dailyId);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
      },
    );

    testWidgets(
      'the Activity tab drops the empty copy once the note has an entry',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.seedDailyNote('2026-09-05', id: _dailyId);
        final h = await _openActivity(tester, db, _dailyId);
        expect(find.byKey(const Key('activity-empty')), findsOneWidget);

        db.seedAgentChange(
          'ac-1',
          _dailyId,
          day: '2026-09-05',
          createdAt: _ms(2026, 9, 5, 14, 32),
          bullets: ['First entry'],
        );
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(find.byKey(const Key('activity-empty')), findsNothing);
        expect(_entry('ac-1'), findsOneWidget);
      },
    );
  });
}
