// WI #262 (F10) AC5, hosted half: the server excludes the Vault Guide from
// `GET /unsorted`, `GET /graph/notes` and `GET /graph/links` (core, #252), and
// the app passes those answers through. Served rows that omit the guide come
// out without it, and a link row is not filtered a second time.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/graph.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

const _base = '/vaults/seed/api/v1';

({FakeVaultServer server, HostedTopicsAccess topics, HostedGraphAccess graph})
_env() {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final client = server.connect(container);
  return (
    server: server,
    topics: HostedTopicsAccess(client: client, vaultName: seedVaultName),
    graph: HostedGraphAccess(client: client, vaultName: seedVaultName),
  );
}

void main() {
  test(
    'hosted unsortedNotes returns the rows the server served without the guide',
    () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/unsorted',
        json: {
          'notes': [
            {'note_id': 'n1', 'title': 'Loose', 'role': null},
            {'note_id': 't1', 'title': 'Topic', 'role': 'topic'},
          ],
        },
      );

      final rows = await env.topics.unsortedNotes();

      expect(rows.map((r) => r.noteId), ['n1', 't1']);
      expect(rows.map((r) => r.role), [null, 'topic']);
    },
  );

  test(
    'hosted graph reads return the rows the server served without the guide',
    () async {
      final env = _env();
      env.server
        ..route(
          'GET',
          '$_base/graph/notes',
          json: {
            'notes': [
              {'id': 'a', 'title': 'A', 'role': 'topic'},
              {'id': 'b', 'title': 'B', 'role': null},
            ],
          },
        )
        ..route(
          'GET',
          '$_base/graph/links',
          json: {
            'links': [
              {'from': 'a', 'to': 'b', 'kind': 'references', 'label': null},
            ],
          },
        );

      final notes = await env.graph.graphNotes();
      final links = await env.graph.graphLinks();

      expect(notes.map((n) => n.id), ['a', 'b']);
      expect(links.map((l) => '${l.from}>${l.to}'), ['a>b']);
    },
  );
}
