// WI #85 (V5), AC 2, 3, 6 and 7: the graph, activity and schema-version reads
// hold one contract on both sides.
//
// - AC 2: the local `GraphReads` / `ActivityReads` (`LocalGraphAccess` over
//   `seededFakeVaultDb()`) on the frozen seed equal the `api_v1/graph`
//   fixture rows, parsed into the app's models.
// - AC 3: every hosted graph read, driven through `fake_vault_server.dart`
//   on the same rows, returns equal models.
// - AC 6: a note without changes, or an unknown id, has no changes on both
//   sides.
// - AC 7: hosted `schemaVersion()` (#72's vault-info row) equals the local
//   `VaultDb.schemaVersion()` on the seed.
//
// The edge rows the seed has no room for are pinned on the local side here
// with the same values `crates/memex-core/tests/app_reads_graph.rs` pins on
// the Rust side, so the two copies of the read rules can't drift apart.
//
// API under test:
//   HostedGraphAccess({required HostedClient client, required String vaultName})
//     .graphNotes / graphLinks / agentChanges / schemaVersion
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show requiredVaultSchemaVersion;
import 'package:open_memex_app/src/vault_access/graph_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/graph.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_db.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi85GraphDir = '$apiV1FixturesDir/graph';
const _wi85Base = '/vaults/seed/api/v1';
const _wi85PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi85Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi85Day19 = '01M5DQAYZ51PF87XFZWSV5PWXK';
const _wi85Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _wi85GhostLink = '01M5DQAYZCV1DXWK1CFVDNP0SS';

class _Wi85Pair {
  _Wi85Pair(this.hosted, this.local, this.db, this.server);

  final HostedGraphAccess hosted;
  final LocalGraphAccess local;
  final FakeVaultDb db;
  final FakeVaultServer server;
}

_Wi85Pair _pair() {
  final server = FakeVaultServer()
    ..serveDomain('graph')
    ..serveDomain('server');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final db = seededFakeVaultDb();
  addTearDown(db.close);
  return _Wi85Pair(
    HostedGraphAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
    LocalGraphAccess(vaultPath: '/unused/wi85', db: db),
    db,
    server,
  );
}

/// The read kinds of the graph routes.
enum _Wi85Read { notes, links, changes }

/// A graph row: its kind, its note id (for agent changes) and its fixture.
class _Wi85ReadRow {
  _Wi85ReadRow(this.kind, this.arg, this.row);

  final _Wi85Read kind;
  final String arg;
  final FixtureRow row;

  Map<String, Object?> get json =>
      row.readResponseJson()! as Map<String, Object?>;
}

List<_Wi85ReadRow> _readRows() {
  final out = <_Wi85ReadRow>[];
  for (final row in loadFixtureRows(_wi85GraphDir)) {
    expect(row.method, 'GET', reason: row.path);
    final uri = Uri.parse(row.path);
    expect(uri.path.startsWith(_wi85Base), isTrue, reason: row.path);
    final seg = uri.pathSegments.sublist(4);
    final (kind, arg) = switch (seg) {
      ['graph', 'notes'] => (_Wi85Read.notes, ''),
      ['graph', 'links'] => (_Wi85Read.links, ''),
      ['notes', final id, 'agent-changes'] => (_Wi85Read.changes, id),
      _ => throw StateError('unknown graph row ${row.path}'),
    };
    out.add(_Wi85ReadRow(kind, arg, row));
  }
  return out;
}

/// The fixture response of [r] parsed into the models the read returns.
List<Object> _wi85Parsed(_Wi85ReadRow r) {
  List<Map<String, Object?>> rows(String key) =>
      (r.json[key]! as List).cast<Map<String, Object?>>();
  return switch (r.kind) {
    _Wi85Read.notes => [
      for (final n in rows('notes'))
        GraphNoteRow(
          id: n['id']! as String,
          title: n['title']! as String,
          role: n['role'] as String?,
        ),
    ],
    _Wi85Read.links => [
      for (final l in rows('links'))
        GraphLinkRow(
          from: l['from']! as String,
          to: l['to']! as String,
          kind: l['kind']! as String,
          label: l['label'] as String?,
        ),
    ],
    _Wi85Read.changes => [
      for (final c in rows('changes'))
        AgentChangeRow(
          id: c['id']! as String,
          noteId: c['note_id']! as String,
          day: c['day']! as String,
          createdAt: c['created_at']! as int,
          bullets: (c['bullets']! as List).cast<String>(),
        ),
    ],
  };
}

Future<List<Object>> _wi85Read(GraphAccess access, _Wi85ReadRow r) =>
    switch (r.kind) {
      _Wi85Read.notes => access.graphNotes(),
      _Wi85Read.links => access.graphLinks(),
      _Wi85Read.changes => access.agentChanges(Uri.decodeComponent(r.arg)),
    };

void main() {
  test('the graph fixture has a row for every read route', () {
    final rows = _readRows();
    expect({for (final r in rows) r.kind}, _Wi85Read.values.toSet());
    // 1 notes, 1 links, 10 seed notes plus an unknown id.
    expect(rows.length, 13);
  });

  test('local graph reads on the seed equal the parsed fixture rows', () async {
    final p = _pair();
    for (final r in _readRows()) {
      expect(
        vaultAccessShape(await _wi85Read(p.local, r)),
        vaultAccessShape(_wi85Parsed(r)),
        reason: r.row.path,
      );
    }
  });

  test(
    'hosted graph reads through the fake server equal the local reads',
    () async {
      final p = _pair();
      for (final r in _readRows()) {
        expect(
          vaultAccessShape(await _wi85Read(p.hosted, r)),
          vaultAccessShape(await _wi85Read(p.local, r)),
          reason: r.row.path,
        );
      }
      expect(
        [for (final q in p.server.requests) q.url.path],
        [for (final r in _readRows()) Uri.parse(r.row.path).path],
        reason: 'one request per read, on the fixture path',
      );
    },
  );

  test('hosted graph reads equal the parsed fixture rows', () async {
    final p = _pair();
    for (final r in _readRows()) {
      expect(
        vaultAccessShape(await _wi85Read(p.hosted, r)),
        vaultAccessShape(_wi85Parsed(r)),
        reason: r.row.path,
      );
    }
  });

  test(
    'the seed ghost link is in the seed but in neither graphLinks read',
    () async {
      final p = _pair();
      final ghost = p.db.db.select(
        'SELECT from_note_id, to_note_id FROM links WHERE id = ?',
        [_wi85GhostLink],
      );
      expect(ghost.single['from_note_id'], _wi85PlayerLoop);
      expect(ghost.single['to_note_id'], isNull);
      final total =
          p.db.db.select('SELECT COUNT(*) AS n FROM links').single['n'] as int;
      for (final links in [
        await p.local.graphLinks(),
        await p.hosted.graphLinks(),
      ]) {
        expect(links, hasLength(total - 1));
        expect(
          [
            for (final l in links)
              if (l.from == _wi85PlayerLoop) l.to,
          ],
          ['01M5DQAYZ47QW55S90ZF0A56AH'],
        );
      }
    },
  );

  test(
    'agentChanges for a note without changes or an unknown id is empty on both sides',
    () async {
      final p = _pair();
      for (final id in [
        _wi85PlayerLoop,
        _wi85Loose,
        _wi85Day19,
        _wi85Unknown,
      ]) {
        expect(await p.local.agentChanges(id), isEmpty, reason: id);
        expect(await p.hosted.agentChanges(id), isEmpty, reason: id);
      }
    },
  );

  test(
    'hosted schemaVersion on the seed equals the local VaultDb schemaVersion',
    () async {
      final p = _pair();
      final local = p.db.schemaVersion();
      expect(local, requiredVaultSchemaVersion);
      expect(await p.hosted.schemaVersion(), local);
      expect(
        await LocalVaultAccess(
          vaultPath: '/unused/wi85',
          db: p.db,
        ).schemaVersion(),
        local,
      );
      expect(p.server.requests.map((r) => r.url.path), ['$_wi85Base/info']);
    },
  );

  test(
    'local graph and activity reads hold the edge rules the Rust app_reads tests pin',
    () async {
      final db = FakeVaultDb.v5();
      addTearDown(db.close);
      void note(String id, String frontmatter) => db.db.execute(
        'INSERT INTO notes (id, title, content_md, frontmatter, version, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, 1, 1, 1)',
        [id, 'Title $id', '', frontmatter],
      );
      // Roles: the same cases as app_reads_graph.rs.
      note('R01', '{"role": "topic"');
      note('R02', '{"role":5}');
      note('R03', '{"role":true}');
      note('R04', '{"role":null}');
      note('R05', '{}');
      note('R06', '["daily"]');
      note('R07', '{"role":"daily"}');
      note('R08', '{"role":"Daily"}');
      note('R09', '{"role": ["daily", "topic"]}');
      note('R10', '{"role": {"a": 1}}');
      final local = LocalGraphAccess(vaultPath: '/unused/wi85', db: db);
      expect(
        {for (final n in await local.graphNotes()) n.id: n.role},
        {
          'R01': null,
          'R02': null,
          'R03': null,
          'R04': null,
          'R05': null,
          'R06': null,
          'R07': 'daily',
          'R08': 'Daily',
          'R09': '["daily","topic"]',
          'R10': '{"a":1}',
        },
      );

      // Agent changes: equal created_at by insertion order, newest first;
      // bad bullets decode to [], non-string items to their Dart strings.
      void change(String id, int createdAt, Object bullets) => db.db.execute(
        'INSERT INTO agent_changes (id, note_id, day, created_at, '
        'bullets_json) VALUES (?, ?, ?, ?, ?)',
        [id, 'R05', '2026-10-18', createdAt, bullets],
      );
      change('Z', 1000, '["z"]');
      change('A', 1000, 'not json');
      change('M', 1000, '{"a":1}');
      change('NEW', 2000, '["b","a"]');
      change('MIX', 1, '[1, true, false, null, "x", -3]');
      final changes = await local.agentChanges('R05');
      expect(
        [
          for (final c in changes) [c.id, c.bullets],
        ],
        [
          [
            'NEW',
            ['b', 'a'],
          ],
          ['M', <String>[]],
          ['A', <String>[]],
          [
            'Z',
            ['z'],
          ],
          [
            'MIX',
            ['1', 'true', 'false', 'null', 'x', '-3'],
          ],
        ],
      );
      expect(await local.agentChanges('r05'), isEmpty);
    },
  );
}
