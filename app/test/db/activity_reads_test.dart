// WI #29 (A11): the `agent_changes` read (D21 extension on VaultDb) and the
// `agentChangesAsyncProvider` over it. Seeds are raw inserts against the real V5
// schema fixture, so nothing here trusts production code to build its input.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/state/activity_state.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/activity_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v4() {
  final db = FakeVaultDb.v4();
  addTearDown(db.close);
  return db;
}

ProviderContainer _container(VaultDb? db) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => LocalVaultRef('/tmp/om-fake-vault'),
      ),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// What `agentChangesAsyncProvider` loaded for [noteId], unwrapped from its
/// vault stamp (WI #90).
Future<List<AgentChangeRow>> _agentChanges(
  ProviderContainer c,
  String noteId,
) async => (await c.read(agentChangesAsyncProvider(noteId).future)).value;

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

void main() {
  group('ActivityReads.agentChanges (AC7, AC11)', () {
    test(
      'agentChanges returns the note entries newest created_at first regardless of insert order',
      () {
        final db = _v5();
        db.seedDailyNote('2026-09-05', id: 'n1');
        // Insert order: middle, oldest, newest. Ids sort differently again.
        db.seedAgentChange(
          'ac-3',
          'n1',
          day: '2026-09-05',
          createdAt: 2000,
          bullets: ['middle'],
        );
        db.seedAgentChange(
          'ac-1',
          'n1',
          day: '2026-09-04',
          createdAt: 1000,
          bullets: ['oldest'],
        );
        db.seedAgentChange(
          'ac-2',
          'n1',
          day: '2026-09-06',
          createdAt: 3000,
          bullets: ['newest'],
        );

        final rows = db.agentChanges('n1');

        expect(rows.map((r) => r.id).toList(), ['ac-2', 'ac-3', 'ac-1']);
        expect(rows.map((r) => r.createdAt).toList(), [3000, 2000, 1000]);
      },
    );

    test(
      'agentChanges maps id, note id, day and created_at and decodes bullets_json in stored order',
      () {
        final db = _v5();
        db.seedDailyNote('2026-09-05', id: 'n1');
        db.seedAgentChange(
          'ac-1',
          'n1',
          day: '2026-09-05',
          createdAt: 1757082720000,
          bullets: [
            'zebra first',
            'alpha second',
            'quote " and, comma third é',
          ],
        );

        final row = db.agentChanges('n1').single;

        expect(row.id, 'ac-1');
        expect(row.noteId, 'n1');
        expect(row.day, '2026-09-05');
        expect(row.createdAt, 1757082720000);
        expect(row.bullets, [
          'zebra first',
          'alpha second',
          'quote " and, comma third é',
        ]);
      },
    );

    test('agentChanges decodes a single bullet to a one-item list', () {
      final db = _v5();
      db.seedDailyNote('2026-09-05', id: 'n1');
      db.seedAgentChange(
        'ac-1',
        'n1',
        day: '2026-09-05',
        createdAt: 1000,
        bullets: ['only one'],
      );

      expect(db.agentChanges('n1').single.bullets, ['only one']);
    });

    test('agentChanges returns only the asked note entries', () {
      final db = _v5();
      db.seedDailyNote('2026-09-05', id: 'daily');
      db.seedTopicNote('topic', 'Gardening');
      db.seedAgentChange(
        'ac-d',
        'daily',
        day: '2026-09-05',
        createdAt: 1000,
        bullets: ['daily change'],
      );
      db.seedAgentChange(
        'ac-t',
        'topic',
        day: '2026-09-05',
        createdAt: 2000,
        bullets: ['topic change'],
      );

      expect(db.agentChanges('daily').map((r) => r.id).toList(), ['ac-d']);
      expect(db.agentChanges('topic').map((r) => r.id).toList(), ['ac-t']);
    });

    test('agentChanges is empty for a note with no entries', () {
      final db = _v5();
      db.seedDailyNote('2026-09-05', id: 'n1');

      expect(db.agentChanges('n1'), isEmpty);
      expect(db.agentChanges('no-such-note'), isEmpty);
    });

    test(
      'agentChanges returns the empty list on a V4 vault and does not throw',
      () {
        final db = _v4();
        db.seedNote(id: 'n1', title: '2026-09-05');

        late List<AgentChangeRow> rows;
        expect(() => rows = db.agentChanges('n1'), returnsNormally);
        expect(rows, isEmpty);
      },
    );

    test(
      'agentChanges returns the empty list when only the agent_changes table is missing and does not throw',
      () {
        final db = _v5();
        db.seedDailyNote('2026-09-05', id: 'n1');
        db.db.execute('DROP TABLE agent_changes');

        late List<AgentChangeRow> rows;
        expect(() => rows = db.agentChanges('n1'), returnsNormally);
        expect(rows, isEmpty);
      },
    );
  });

  group('the agent changes read (AC7, AC11)', () {
    test(
      'the agent changes read yields the note entries newest first',
      () async {
        final db = _v5();
        db.seedDailyNote('2026-09-05', id: 'n1');
        db.seedAgentChange(
          'ac-old',
          'n1',
          day: '2026-09-04',
          createdAt: 1000,
          bullets: ['old'],
        );
        db.seedAgentChange(
          'ac-new',
          'n1',
          day: '2026-09-05',
          createdAt: 2000,
          bullets: ['new a', 'new b'],
        );
        final c = _container(db);

        final rows = await _agentChanges(c, 'n1');

        expect(rows.map((r) => r.id).toList(), ['ac-new', 'ac-old']);
        expect(rows.first.bullets, ['new a', 'new b']);
      },
    );

    test(
      'the agent changes read is empty on a V4 vault and does not throw',
      () async {
        final db = _v4();
        final c = _container(db);

        expect(await _agentChanges(c, 'n1'), isEmpty);
      },
    );

    test(
      'the agent changes read is empty when there is no open vault database',
      () async {
        final c = _container(null);

        expect(await _agentChanges(c, 'n1'), isEmpty);
      },
    );

    test(
      'the agent changes read re-reads after a vault revision bump',
      () async {
        final db = _v5();
        db.seedDailyNote('2026-09-05', id: 'n1');
        final c = _container(db);
        expect(await _agentChanges(c, 'n1'), isEmpty);

        db.seedAgentChange(
          'ac-1',
          'n1',
          day: '2026-09-05',
          createdAt: 1000,
          bullets: ['appeared'],
        );
        _bump(c);

        expect((await _agentChanges(c, 'n1')).single.id, 'ac-1');
      },
    );

    test(
      'the agent changes read picks up the entries once a V4 vault migrates to V5',
      () async {
        final db = _v4();
        final c = _container(db);
        expect(await _agentChanges(c, 'n1'), isEmpty);

        db.migrateToV5();
        db.seedNote(id: 'n1', title: '2026-09-05', role: 'daily');
        db.seedAgentChange(
          'ac-1',
          'n1',
          day: '2026-09-05',
          createdAt: 1000,
          bullets: ['after migration'],
        );
        _bump(c);

        expect((await _agentChanges(c, 'n1')).single.bullets, [
          'after migration',
        ]);
      },
    );
  });
}
