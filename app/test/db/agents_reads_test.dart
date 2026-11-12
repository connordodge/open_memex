// WI #453 (390-A2): AgentsReads.recentAgentActivity against the real app
// schema fixture (vault_schema_v5.sql, V7 since #415), and against older
// schemas without an `agent_activity` table (FakeVaultDb.v6Only/v5Only/v4).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/agents_reads.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';

import '../support/fake_vault_db.dart';

/// Base `created_at`, ms epoch (2026-11-11).
const _t0 = 1762880000000;

FakeVaultDb _track(FakeVaultDb db) {
  addTearDown(db.close);
  return db;
}

/// Insert one `agent_activity` row with every column given at run time.
void _seed(
  FakeVaultDb db, {
  required String id,
  required int createdAt,
  String? sessionId,
  String? clientName,
  String? tool,
  String? summary,
  String? noteId,
}) {
  db.db.execute(
    'INSERT INTO agent_activity (id, session_id, client_name, tool, summary, '
    'note_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      id,
      sessionId ?? 'session-$id',
      clientName ?? 'client-$id',
      tool ?? 'tool-$id',
      summary ?? 'summary of $id',
      noteId,
      createdAt,
    ],
  );
}

List<String> _ids(List<AgentActivityEntry> entries) => [
  for (final e in entries) e.id,
];

void main() {
  test(
    'recentAgentActivity on the V7 fixture with 25 rows returns the newest 20 newest first',
    () {
      final db = _track(FakeVaultDb());
      // Inserted in a scrambled order so rowid order is not the sort order.
      final order = [
        for (var i = 0; i < 25; i++) (i * 7) % 25,
      ]; // a permutation of 0..24
      for (final i in order) {
        _seed(
          db,
          id: 'E${i.toString().padLeft(2, '0')}',
          createdAt: _t0 + i * 1000,
        );
      }

      final recent = db.recentAgentActivity();

      expect(_ids(recent), [
        for (var i = 24; i >= 5; i--) 'E${i.toString().padLeft(2, '0')}',
      ]);
    },
  );

  test(
    'recentAgentActivity with fewer than 20 rows returns all of them newest first',
    () {
      final db = _track(FakeVaultDb());
      _seed(db, id: 'B', createdAt: 999);
      _seed(db, id: 'C', createdAt: 1000);
      _seed(db, id: 'A', createdAt: 10);

      expect(_ids(db.recentAgentActivity()), ['C', 'B', 'A']);
    },
  );

  test('recentAgentActivity breaks a created_at tie by id descending', () {
    final db = _track(FakeVaultDb());
    _seed(db, id: '01JB', createdAt: _t0);
    _seed(db, id: '01JC', createdAt: _t0);
    _seed(db, id: '01JZ', createdAt: _t0 - 1);
    _seed(db, id: '01JA', createdAt: _t0);
    _seed(db, id: '01JY', createdAt: _t0 + 1);

    expect(_ids(db.recentAgentActivity()), [
      '01JY',
      '01JC',
      '01JB',
      '01JA',
      '01JZ',
    ]);
  });

  test(
    'recentAgentActivity cuts a created_at tie at the 20th row by id descending',
    () {
      final db = _track(FakeVaultDb());
      for (var i = 0; i < 18; i++) {
        _seed(
          db,
          id: 'N${i.toString().padLeft(2, '0')}',
          createdAt: _t0 + 100 + i,
        );
      }
      // Three rows tie for places 19 to 21: only the two highest ids fit.
      _seed(db, id: 'T1', createdAt: _t0);
      _seed(db, id: 'T3', createdAt: _t0);
      _seed(db, id: 'T2', createdAt: _t0);

      final ids = _ids(db.recentAgentActivity());

      expect(ids, hasLength(20));
      expect(ids.sublist(18), ['T3', 'T2']);
    },
  );

  test('recentAgentActivity maps every column of a row', () {
    final db = _track(FakeVaultDb());
    final createdAt = DateTime.utc(2026, 11, 11, 9, 30).millisecondsSinceEpoch;
    final note = 'note-${createdAt % 97}';
    _seed(
      db,
      id: '01JAGENTENTRY00000000000ZZ',
      sessionId: '01JAGENTSESSION0000000000Q',
      clientName: 'claude-desktop',
      tool: 'add_excerpt',
      summary: 'filed 4 blocks → Rest & Recharge',
      noteId: note,
      createdAt: createdAt,
    );

    final recent = db.recentAgentActivity();
    expect(recent, hasLength(1));
    final e = recent.single;

    expect(e.id, '01JAGENTENTRY00000000000ZZ');
    expect(e.sessionId, '01JAGENTSESSION0000000000Q');
    expect(e.clientName, 'claude-desktop');
    expect(e.tool, 'add_excerpt');
    expect(e.summary, 'filed 4 blocks → Rest & Recharge');
    expect(e.noteId, note);
    expect(e.createdAt, createdAt);
  });

  test('recentAgentActivity keeps a null note_id null', () {
    final db = _track(FakeVaultDb());
    _seed(db, id: 'X1', createdAt: _t0, tool: 'create_smart_folder');

    final recent = db.recentAgentActivity();
    expect(recent, hasLength(1));
    final e = recent.single;

    expect(e.id, 'X1');
    expect(e.tool, 'create_smart_folder');
    expect(e.noteId, isNull);
  });

  test('recentAgentActivity on an empty V7 table returns no entries', () {
    final db = _track(FakeVaultDb());
    expect(db.recentAgentActivity(), isEmpty);
  });

  for (final (name, make) in <(String, FakeVaultDb Function())>[
    (
      'recentAgentActivity on a V6 vault without agent_activity returns no entries',
      FakeVaultDb.v6Only,
    ),
    (
      'recentAgentActivity on a V5 vault without agent_activity returns no entries',
      FakeVaultDb.v5Only,
    ),
    (
      'recentAgentActivity on a V4 vault without agent_activity returns no entries',
      FakeVaultDb.v4,
    ),
  ]) {
    test(name, () {
      final db = _track(make());
      expect(db.hasTables(const ['agent_activity']), isFalse);
      expect(db.recentAgentActivity(), isEmpty);
    });
  }

  test(
    'recentAgentActivity sees agent_activity once the CLI migrates the open V6 handle to V7',
    () {
      final db = _track(FakeVaultDb.v6Only());
      expect(db.recentAgentActivity(), isEmpty);

      db.migrateToV6(); // replays the V7 fixture on the same handle
      _seed(db, id: 'M1', createdAt: _t0);

      expect(_ids(db.recentAgentActivity()), ['M1']);
    },
  );

  test(
    'recentAgentActivity throws when agent_activity exists but the read fails',
    () {
      final db = _track(FakeVaultDb());
      // A table by that name the query cannot read (no summary column).
      db.db.execute('DROP TABLE agent_activity');
      db.db.execute(
        'CREATE TABLE agent_activity (id TEXT PRIMARY KEY, created_at INTEGER)',
      );
      db.db.execute(
        "INSERT INTO agent_activity (id, created_at) VALUES ('R1', 1)",
      );

      expect(db.recentAgentActivity, throwsA(anything));
    },
  );

  test('recentAgentActivity leaves no read transaction open', () {
    final db = _track(FakeVaultDb());
    _seed(db, id: 'Q1', createdAt: _t0);

    expect(_ids(db.recentAgentActivity()), ['Q1']);
    expect(db.db.autocommit, isTrue);
  });
}
