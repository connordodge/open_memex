// WI #84 (V4): the canvas fixtures against the local reads, and the hosted
// reads against the local reads.
//
// AC 2: `LocalCanvasAccess` over `seededFakeVaultDb()` returns exactly the
// parsed `api_v1/canvas` read fixtures (which the `memex` CLI made), with the
// detail's ghost and off-canvas links absent.
// AC 3 and 4: `HostedCanvasAccess`, driven through `fake_vault_server.dart`
// on the fixture rows, returns models equal to the local reads, and null for
// an unknown canvas like the local read.
//
// API under test:
//   HostedCanvasAccess({required HostedClient client, required String vaultName})
//     .listCanvases / getCanvasDetail
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/canvas.dart';
import 'package:open_memex_app/src/vault_access/local/canvas.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi84CanvasDir = '$apiV1FixturesDir/canvas';
const _wi84Base = '/vaults/seed/api/v1';
const _wi84Canvas = '01M5DQAYZJET989N2YR8341XAN';
const _wi84Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

/// Player Loop -> Economy Design and back: the two edges.
const _wi84Edges = ['01M5DQAYZC5FQW4HVPK8ZE5SXW', '01M5DQAYZFCB2T0ECN4HG7XFQM'];

/// Links that touch a placed note but are never edges: the ghost link
/// (no target), Economy Design -> 2026-10-19 (off the canvas), and links
/// into placed notes from unplaced ones.
const _wi84NotEdges = [
  '01M5DQAYZCV1DXWK1CFVDNP0SS',
  '01M5DQAYZFCJGDA345T48TPSH3',
  '01M5DQAYZDBGZSDQ7X3PJT783V',
  '01M5DQAYZHCFX0P4QP3718HC8N',
  '01M5DQAYZGM1C68ZDC9FR3KTCH',
];

class _Wi84Pair {
  _Wi84Pair(this.hosted, this.local, this.server);

  final HostedCanvasAccess hosted;
  final LocalCanvasAccess local;
  final FakeVaultServer server;
}

_Wi84Pair _pair() {
  final server = FakeVaultServer()..serveDomain('canvas');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final db = seededFakeVaultDb();
  addTearDown(db.close);
  return _Wi84Pair(
    HostedCanvasAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
    LocalCanvasAccess(vaultPath: '/unused/wi84', db: db),
    server,
  );
}

FixtureRow _row(String response) =>
    loadFixtureRows(_wi84CanvasDir).singleWhere((r) => r.response == response);

Map<String, Object?> _fixture(String response) =>
    _row(response).readResponseJson()! as Map<String, Object?>;

List<Map<String, Object?>> _list(Object? v) =>
    (v! as List).cast<Map<String, Object?>>();

int _int(Object? v) => (v! as num).toInt();

double _double(Object? v) => (v! as num).toDouble();

/// The `memex canvas ls` fixture as today's rows, built field by field here
/// (not by the code under test).
List<CanvasRow> _wi84ListFromFixture(Map<String, Object?> json) => [
  for (final c in _list(json['canvases']))
    CanvasRow(
      canvasId: c['canvas_id']! as String,
      title: c['title']! as String,
      createdAt: _int(c['created_at']),
      updatedAt: _int(c['updated_at']),
      version: _int(c['version']),
      nodeCount: _int(c['node_count']),
    ),
];

/// The `memex canvas get` fixture as today's detail row.
CanvasDetailRow _wi84DetailFromFixture(Map<String, Object?> json) =>
    CanvasDetailRow(
      canvasId: json['canvas_id']! as String,
      title: json['title']! as String,
      createdAt: _int(json['created_at']),
      updatedAt: _int(json['updated_at']),
      version: _int(json['version']),
      nodes: [
        for (final n in _list(json['nodes']))
          CanvasNodeRow(
            noteId: n['note_id']! as String,
            noteTitle: n['note_title']! as String,
            x: _double(n['x']),
            y: _double(n['y']),
            zOrder: _int(n['z_order']),
            placedAt: _int(n['placed_at']),
          ),
      ],
      edges: [
        for (final e in _list(json['edges']))
          CanvasEdgeRow(
            linkId: e['link_id']! as String,
            fromNoteId: e['from_note_id']! as String,
            toNoteId: e['to_note_id']! as String,
            linkText: e['link_text']! as String,
            kind: e['kind']! as String,
            label: e['label'] as String?,
            position: _int(e['position']),
            source: e['source']! as String,
          ),
      ],
    );

void main() {
  group('fixtures against the local reads', () {
    test(
      'the local listCanvases on the seed equals the list fixture',
      () async {
        final p = _pair();
        final row = _row('list_canvases.json');
        expect(
          [row.method, row.path, row.status],
          ['GET', '$_wi84Base/canvases', 200],
        );
        final json = _fixture('list_canvases.json');
        expect(json['vault_id'], seedVaultId());
        final local = await p.local.listCanvases();
        expect(local, hasLength(1));
        expect(
          vaultAccessShape(local),
          vaultAccessShape(_wi84ListFromFixture(json)),
        );
      },
    );

    test(
      'the local getCanvasDetail on the seed equals the detail fixture without ghost or off-canvas links',
      () async {
        final p = _pair();
        final row = _row('get_canvas.json');
        expect(
          [row.method, row.path, row.status],
          ['GET', '$_wi84Base/canvases/$_wi84Canvas', 200],
        );
        final json = _fixture('get_canvas.json');
        expect(json['vault_id'], seedVaultId());
        final local = (await p.local.getCanvasDetail(_wi84Canvas))!;
        expect(
          vaultAccessShape(local),
          vaultAccessShape(_wi84DetailFromFixture(json)),
        );
        expect(local.nodes, hasLength(2));
        final edgeIds = [for (final e in local.edges) e.linkId];
        expect(edgeIds, _wi84Edges);
        for (final id in _wi84NotEdges) {
          expect(edgeIds, isNot(contains(id)), reason: id);
        }
      },
    );

    test('the unknown-canvas fixture is the not_found body', () async {
      final p = _pair();
      final row = _row('get_canvas_not_found.json');
      expect(
        [row.method, row.path, row.status],
        ['GET', '$_wi84Base/canvases/$_wi84Unknown', 404],
      );
      expect(
        (_fixture('get_canvas_not_found.json')['error']!
            as Map<String, Object?>)['code'],
        'not_found',
      );
      expect(await p.local.getCanvasDetail(_wi84Unknown), isNull);
    });
  });

  group('hosted against the local reads', () {
    test(
      'hosted listCanvases equals the local listCanvases on the seed',
      () async {
        final p = _pair();
        final hosted = await p.hosted.listCanvases();
        expect(p.server.requests.last.method, 'GET');
        expect(p.server.requests.last.url.path, '$_wi84Base/canvases');
        expect(
          vaultAccessShape(hosted),
          vaultAccessShape(await p.local.listCanvases()),
        );
      },
    );

    test(
      'hosted getCanvasDetail equals the local getCanvasDetail on the seed',
      () async {
        final p = _pair();
        final hosted = await p.hosted.getCanvasDetail(_wi84Canvas);
        expect(p.server.requests.last.method, 'GET');
        expect(
          p.server.requests.last.url.path,
          '$_wi84Base/canvases/$_wi84Canvas',
        );
        expect(hosted, isNotNull);
        expect(
          vaultAccessShape(hosted),
          vaultAccessShape(await p.local.getCanvasDetail(_wi84Canvas)),
        );
        for (final n in hosted!.nodes) {
          expect(n.x, isA<double>());
          expect(n.y, isA<double>());
        }
      },
    );

    test(
      'hosted getCanvasDetail of an unknown id is null like the local read',
      () async {
        final p = _pair();
        expect(await p.local.getCanvasDetail(_wi84Unknown), isNull);
        expect(await p.hosted.getCanvasDetail(_wi84Unknown), isNull);
        // The fixture row answered (not the no-route fallback).
        expect(
          p.server.requests.last.url.path,
          '$_wi84Base/canvases/$_wi84Unknown',
        );
      },
    );
  });
}
