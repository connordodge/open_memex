// WI #85 (V5): HostedGraphAccess over HostedClient (D13, D17), against the
// `api_v1/graph` fixture rows (and #72's `api_v1/server` vault-info row)
// replayed by `fake_vault_server.dart`.
//
// Pinned wire shapes (under `/vaults/<vault>/api/v1`; reads only, no query,
// no body):
//   GET /graph/notes                 {"notes":[{id,title,role}]}  role: string|null
//   GET /graph/links                 {"links":[{from,to,kind,label}]}  label: string|null
//   GET /notes/{note_id}/agent-changes
//                                    {"changes":[{id,note_id,day,created_at,bullets}]}
//     (note_id is one encoded path segment; created_at is unix ms)
//   schemaVersion(): GET /info (#72) {"name","schema_version","vault_id"} ->
//     schema_version, unchecked (req 53).
// Errors are MemexException.fromC1 from HostedClient; unknown keys are
// ignored (req 21).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/graph_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/graph.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi85Base = '/vaults/seed/api/v1';
const _wi85PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi85Economy = '01M5DQAYZ47QW55S90ZF0A56AH';
const _wi85Pacing = '01M5DQAYZ4YAPYMEDWXP8WCNGJ';
const _wi85Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi85Day18 = '01M5DQAYZ4TAPTHDWE5PNWE4W5';
const _wi85Broken = '01M5DQAYZ5RH88SRZGPY15XXVM';
const _wi85Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

class _Wi85Env {
  _Wi85Env(this.container, this.server, this.graph);

  final ProviderContainer container;
  final FakeVaultServer server;
  final HostedGraphAccess graph;

  http.Request get last => server.requests.last;
}

_Wi85Env _env({bool rows = true, String vaultName = seedVaultName}) {
  final server = FakeVaultServer();
  if (rows) {
    server
      ..serveDomain('graph')
      ..serveDomain('server');
  }
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi85Env(
    container,
    server,
    HostedGraphAccess(client: server.connect(container), vaultName: vaultName),
  );
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// Every hosted graph read once, labelled.
Map<String, Future<Object?> Function()> _reads(HostedGraphAccess g) => {
  'graphNotes': g.graphNotes,
  'graphLinks': g.graphLinks,
  'agentChanges': () => g.agentChanges(_wi85Day18),
  'schemaVersion': g.schemaVersion,
};

void main() {
  test('HostedGraphAccess is a GraphAccess', () {
    expect(_env().graph, isA<GraphAccess>());
  });

  group('reads', () {
    test('hosted graph reads send the documented GET paths', () async {
      final env = _env();
      await env.graph.graphNotes();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi85Base/graph/notes');
      expect(env.last.url.query, isEmpty);

      await env.graph.graphLinks();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi85Base/graph/links');
      expect(env.last.url.query, isEmpty);

      await env.graph.agentChanges(_wi85Day18);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi85Base/notes/$_wi85Day18/agent-changes');
      expect(env.last.url.query, isEmpty);

      expect(env.server.requests, hasLength(3), reason: 'one request each');
      for (final r in env.server.requests) {
        expect(r.url.toString(), startsWith(fakeServerUrl));
        expect(r.headers['authorization'], 'Bearer $fakeServerToken');
        expect(r.body, isEmpty, reason: 'reads send no body');
      }
    });

    test(
      'hosted agentChanges sends the note id as one encoded segment',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'GET',
          '$_wi85Base/notes/a%2Fb%3Fc%20d/agent-changes',
          json: {'changes': <Object?>[]},
        );
        expect(await env.graph.agentChanges('a/b?c d'), isEmpty);
        expect(env.last.url.pathSegments, [
          'vaults',
          'seed',
          'api',
          'v1',
          'notes',
          'a/b?c d',
          'agent-changes',
        ]);
        expect(env.last.url.query, isEmpty);
      },
    );

    test('hosted reads go to the named vault', () async {
      final env = _env(rows: false, vaultName: 'my vault');
      env.server
        ..route(
          'GET',
          '/vaults/my%20vault/api/v1/graph/notes',
          json: {'notes': <Object?>[]},
        )
        ..route(
          'GET',
          '/vaults/my%20vault/api/v1/info',
          json: {'name': 'my vault', 'schema_version': 5, 'vault_id': 'V'},
        );
      expect(await env.graph.graphNotes(), isEmpty);
      expect(await env.graph.schemaVersion(), 5);
      expect(
        [for (final r in env.server.requests) r.url.pathSegments[1]],
        ['my vault', 'my vault'],
      );
    });

    test(
      'hosted graphNotes decodes id title and role and keeps null roles',
      () async {
        final env = _env();
        final notes = await env.graph.graphNotes();
        expect(notes, hasLength(10));
        expect(vaultAccessShape(notes.take(3).toList()), [
          {
            'GraphNoteRow': [_wi85PlayerLoop, 'Player Loop', 'topic'],
          },
          {
            'GraphNoteRow': [_wi85Economy, 'Economy Design', 'topic'],
          },
          {
            'GraphNoteRow': [_wi85Loose, 'Loose Thought', null],
          },
        ]);
        final broken = notes.singleWhere((n) => n.id == _wi85Broken);
        expect(broken.title, 'Broken Frontmatter');
        expect(broken.role, isNull);
        expect({for (final n in notes) n.role}, {'topic', 'daily', null});
      },
    );

    test('hosted graphLinks decodes null and string labels', () async {
      final env = _env();
      final links = await env.graph.graphLinks();
      expect(links, hasLength(7));
      expect(vaultAccessShape(links.first), {
        'GraphLinkRow': [_wi85PlayerLoop, _wi85Economy, 'references', null],
      });
      final labelled = links.singleWhere((l) => l.from == _wi85Pacing);
      expect(vaultAccessShape(labelled), {
        'GraphLinkRow': [
          _wi85Pacing,
          _wi85PlayerLoop,
          'references',
          'the loop',
        ],
      });
      expect(
        links.where((l) => l.from == _wi85PlayerLoop),
        hasLength(1),
        reason: 'the ghost link is not on the wire',
      );
    });

    test(
      'hosted agentChanges decodes every field and keeps row and bullet order',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'GET',
          '$_wi85Base/notes/$_wi85Loose/agent-changes',
          json: {
            'changes': [
              {
                'id': 'C2',
                'note_id': _wi85Loose,
                'day': '2026-10-19',
                'created_at': 1792535788530,
                'bullets': ['Second idea', 'First idea', 'Größe 🎲'],
              },
              {
                'id': 'C1',
                'note_id': _wi85Loose,
                'day': '2026-10-18',
                'created_at': 1760000960000,
                'bullets': <Object?>[],
              },
            ],
          },
        );
        final changes = await env.graph.agentChanges(_wi85Loose);
        expect(vaultAccessShape(changes), [
          {
            'AgentChangeRow': [
              'C2',
              _wi85Loose,
              '2026-10-19',
              1792535788530,
              ['Second idea', 'First idea', 'Größe 🎲'],
            ],
          },
          {
            'AgentChangeRow': [
              'C1',
              _wi85Loose,
              '2026-10-18',
              1760000960000,
              <String>[],
            ],
          },
        ]);
        expect(changes.first.bullets, isA<List<String>>());
      },
    );

    test('hosted agentChanges decodes the seed row', () async {
      final env = _env();
      final changes = await env.graph.agentChanges(_wi85Day18);
      expect(vaultAccessShape(changes), [
        {
          'AgentChangeRow': [
            '01M5DQAYZJJSN6WG9XFPXXFBNC',
            _wi85Day18,
            '2026-10-18',
            1760000960000,
            ['Filed the prototype notes'],
          ],
        },
      ]);
    });

    test(
      'hosted agentChanges for a note without changes or an unknown id is empty',
      () async {
        final env = _env();
        expect(await env.graph.agentChanges(_wi85PlayerLoop), isEmpty);
        expect(await env.graph.agentChanges(_wi85Loose), isEmpty);
        expect(await env.graph.agentChanges(_wi85Unknown), isEmpty);
        expect(env.server.requests.map((r) => r.url.path), [
          '$_wi85Base/notes/$_wi85PlayerLoop/agent-changes',
          '$_wi85Base/notes/$_wi85Loose/agent-changes',
          '$_wi85Base/notes/$_wi85Unknown/agent-changes',
        ]);
      },
    );

    test('hosted graph reads ignore unknown response keys', () async {
      final env = _env(rows: false);
      env.server
        ..route(
          'GET',
          '$_wi85Base/graph/notes',
          json: {
            'notes': [
              {'id': 'N1', 'title': 'One', 'role': null, 'future': 1},
            ],
            'next_cursor': 'x',
          },
        )
        ..route(
          'GET',
          '$_wi85Base/graph/links',
          json: {
            'links': [
              {
                'from': 'N1',
                'to': 'N2',
                'kind': 'about',
                'label': null,
                'weight': 0.5,
              },
            ],
            'total': 1,
          },
        )
        ..route(
          'GET',
          '$_wi85Base/notes/N1/agent-changes',
          json: {
            'changes': [
              {
                'id': 'C1',
                'note_id': 'N1',
                'day': '2026-10-18',
                'created_at': 5,
                'bullets': ['b'],
                'author': 'agent',
              },
            ],
            'more': false,
          },
        );
      expect(vaultAccessShape(await env.graph.graphNotes()), [
        {
          'GraphNoteRow': ['N1', 'One', null],
        },
      ]);
      expect(vaultAccessShape(await env.graph.graphLinks()), [
        {
          'GraphLinkRow': ['N1', 'N2', 'about', null],
        },
      ]);
      expect(vaultAccessShape(await env.graph.agentChanges('N1')), [
        {
          'AgentChangeRow': [
            'C1',
            'N1',
            '2026-10-18',
            5,
            ['b'],
          ],
        },
      ]);
    });

    test('hosted graph reads rethrow the server C1 error', () async {
      final env = _env(rows: false);
      for (final path in [
        '/graph/notes',
        '/graph/links',
        '/notes/$_wi85Day18/agent-changes',
        '/info',
      ]) {
        env.server.route(
          'GET',
          '$_wi85Base$path',
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': 'disk on fire'},
          },
        );
      }
      for (final MapEntry(key: name, value: read) in _reads(
        env.graph,
      ).entries) {
        final e = await _outcome(read());
        expect(e, isA<MemexException>(), reason: name);
        e as MemexException;
        expect(e.code, 'internal', reason: name);
        expect(e.message, endsWith('failed: disk on fire'), reason: name);
      }
    });

    test(
      'hosted graph reads of a vault gone from the server throw vault_not_found',
      () async {
        final env = _env()..server.removeVault(seedVaultName);
        for (final MapEntry(key: name, value: read) in _reads(
          env.graph,
        ).entries) {
          final e = await _outcome(read());
          expect(e, isA<MemexException>(), reason: name);
          expect((e! as MemexException).code, 'vault_not_found', reason: name);
        }
      },
    );

    test(
      'hosted graph reads with a rejected token throw unauthorized',
      () async {
        final env = _env()..server.token = 'rotated-on-the-server';
        for (final MapEntry(key: name, value: read) in _reads(
          env.graph,
        ).entries) {
          final e = await _outcome(read());
          expect(e, isA<MemexException>(), reason: name);
          expect((e! as MemexException).code, 'unauthorized', reason: name);
        }
        expect(
          env.container.read(hostedConnectionStatusProvider(fakeServerId)),
          HostedConnectionStatus.tokenRejected,
        );
      },
    );
  });

  group('schemaVersion', () {
    test(
      'hosted schemaVersion reads schema_version from the vault info route',
      () async {
        final env = _env();
        expect(await env.graph.schemaVersion(), 6);
        expect(env.server.requests, hasLength(1));
        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_wi85Base/info');
        expect(env.last.url.query, isEmpty);
        expect(env.last.body, isEmpty);
      },
    );

    test(
      'hosted schemaVersion returns what the server reports without checking it',
      () async {
        for (final version in [4, 6, 7, 0]) {
          final env = _env(rows: false);
          env.server.route(
            'GET',
            '$_wi85Base/info',
            json: {
              'name': 'seed',
              'schema_version': version,
              'vault_id': '01M5DK9Z8CWPQGFA893JX9VRZF',
              'future_field': {'x': 1},
            },
          );
          expect(await env.graph.schemaVersion(), version);
          expect(env.server.requests.map((r) => r.url.path), [
            '$_wi85Base/info',
          ], reason: 'no server info probe and no api_version check');
        }
      },
    );
  });
}
