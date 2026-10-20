// WI #84 (V4): HostedCanvasAccess over HostedClient (D13, D16, D17), against
// the `api_v1/canvas` fixture rows replayed by `fake_vault_server.dart`.
//
// Pinned wire shapes (under `/vaults/<vault>/api/v1`):
//   reads:  GET /canvases -> {vault_id, canvases:[{canvas_id, title,
//             created_at, updated_at, version, node_count}]}
//           GET /canvases/{canvas_id} -> the `memex canvas get` object;
//             C1 not_found reads as null, every other error is thrown
//   writes: POST /canvases {title} -> the `memex canvas new` object
//           POST /canvases/{canvas_id}/nodes {note_id, x, y} -> the
//             `memex canvas add` object (x and y default to 0.0)
//           PATCH /canvases/{canvas_id}/nodes/{note_id} {x, y, z_order?}
//             -> the `memex canvas move` object (no placed_at); z_order
//             is sent only when given
//   x and y go out and come back as doubles. `created_at`, `updated_at`
//   and `placed_at` default to 0 when absent (as `MemexCli` parses them).
// Write errors are MemexException.fromC1 with the CLI wrapper's operation
// label (`canvas new`, `canvas add`, `canvas move`). Writes leave
// `vaultRevisionProvider` to their call sites.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/canvas_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/canvas.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi84CanvasDir = '$apiV1FixturesDir/canvas';
const _wi84Base = '/vaults/seed/api/v1';
const _wi84Canvas = '01M5DQAYZJET989N2YR8341XAN';
const _wi84PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi84Economy = '01M5DQAYZ47QW55S90ZF0A56AH';
const _wi84Pacing = '01M5DQAYZ4YAPYMEDWXP8WCNGJ';
const _wi84Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi84Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

class _Wi84Env {
  _Wi84Env(this.container, this.server, this.canvas);

  final ProviderContainer container;
  final FakeVaultServer server;
  final HostedCanvasAccess canvas;

  http.Request get last => server.requests.last;

  Object? get lastBody => jsonDecode(last.body);
}

_Wi84Env _env({bool rows = true}) {
  final server = FakeVaultServer();
  if (rows) server.serveDomain('canvas');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi84Env(
    container,
    server,
    HostedCanvasAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
  );
}

/// The row of `canvas/index.json` that answers [response].
FixtureRow _row(String response) =>
    loadFixtureRows(_wi84CanvasDir).firstWhere((r) => r.response == response);

Object? _requestJson(String response) =>
    jsonDecode(utf8.decode(_row(response).readRequestBytes()!));

Object? _responseJson(String response) => _row(response).readResponseJson();

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// What `MemexCli` builds for a failed `memex <operation>` whose stderr is
/// the C1 [body].
MemexException _cliFailure(String operation, Object? body) =>
    MemexException.fromCliFailure(
      operation,
      MemexResult(exitCode: 1, stdout: '', stderr: '${jsonEncode(body)}\n'),
    );

void _expectSameException(Object? e, MemexException cli) {
  expect(e, isA<MemexException>());
  e as MemexException;
  expect(e.message, cli.message);
  expect(e.code, cli.code);
  expect(e.fields, cli.fields);
  expect(e.kind, cli.kind);
}

void main() {
  test('HostedCanvasAccess is a CanvasAccess', () {
    expect(_env().canvas, isA<CanvasAccess>());
  });

  group('reads', () {
    test('hosted canvas reads send GET to the documented paths', () async {
      final env = _env();
      await env.canvas.listCanvases();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi84Base/canvases');
      expect(env.last.url.query, isEmpty);

      await env.canvas.getCanvasDetail(_wi84Canvas);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi84Base/canvases/$_wi84Canvas');
      expect(env.last.url.query, isEmpty);
    });

    test(
      'hosted canvas reads parse whole-number coordinates as doubles',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'GET',
          '$_wi84Base/canvases/$_wi84Canvas',
          json: {
            'canvas_id': _wi84Canvas,
            'created_at': 11,
            'edges': <Object?>[],
            'nodes': [
              {
                'note_id': _wi84Economy,
                'note_title': 'Economy Design',
                'placed_at': 13,
                'x': 12,
                'y': -7,
                'z_order': 2,
              },
            ],
            'title': 'Prototype Map',
            'updated_at': 12,
            'vault_id': seedVaultId(),
            'version': 4,
          },
        );
        final d = (await env.canvas.getCanvasDetail(_wi84Canvas))!;
        final n = d.nodes.single;
        expect(n.x, isA<double>());
        expect(n.y, isA<double>());
        expect(vaultAccessShape(d), {
          'CanvasDetailRow': [
            _wi84Canvas,
            'Prototype Map',
            11,
            12,
            4,
            [
              {
                'CanvasNodeRow': [
                  _wi84Economy,
                  'Economy Design',
                  12.0,
                  -7.0,
                  2,
                  13,
                ],
              },
            ],
            <Object?>[],
          ],
        });
      },
    );

    test('hosted canvas reads ignore unknown response keys', () async {
      final env = _env(rows: false);
      final list = Map<String, Object?>.of(
        _responseJson('list_canvases.json')! as Map<String, Object?>,
      );
      list['next_cursor'] = 'later';
      (list['canvases']! as List).cast<Map<String, Object?>>().first['color'] =
          'teal';
      env.server.route('GET', '$_wi84Base/canvases', json: list);
      final detail = Map<String, Object?>.of(
        _responseJson('get_canvas.json')! as Map<String, Object?>,
      );
      detail['layout'] = 'grid';
      (detail['edges']! as List).cast<Map<String, Object?>>().first['weight'] =
          2;
      env.server.route('GET', '$_wi84Base/canvases/$_wi84Canvas', json: detail);
      final rows = await env.canvas.listCanvases();
      expect(vaultAccessShape(rows), [
        {
          'CanvasRow': [
            _wi84Canvas,
            'Prototype Map',
            1760000780000,
            1760000900000,
            3,
            2,
          ],
        },
      ]);
      final d = (await env.canvas.getCanvasDetail(_wi84Canvas))!;
      expect(d.nodes, hasLength(2));
      expect(d.edges, hasLength(2));
      expect(d.edges.first.linkId, '01M5DQAYZC5FQW4HVPK8ZE5SXW');
      expect(d.edges.first.label, isNull);
    });

    test('hosted getCanvasDetail rethrows every error but not_found', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi84Base/canvases/$_wi84Canvas',
        status: 500,
        json: {
          'error': {'code': 'internal', 'message': 'disk on fire'},
        },
      );
      final e = await _outcome(env.canvas.getCanvasDetail(_wi84Canvas));
      expect(e, isA<MemexException>());
      expect((e! as MemexException).code, 'internal');

      env.server.removeVault(seedVaultName);
      final gone = await _outcome(env.canvas.getCanvasDetail(_wi84Unknown));
      expect(gone, isA<MemexException>());
      expect((gone! as MemexException).code, 'vault_not_found');
    });
  });

  group('createCanvas', () {
    test(
      'hosted createCanvas posts the title and parses the canvas new object',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'POST',
          '$_wi84Base/canvases',
          status: 201,
          json: {
            'canvas_id': '01M5ZZZZZZZZZZZZZZZZZZZZZZ',
            'created_at': 1760001000000,
            'title': 'Level Flow',
            'updated_at': 1760001000001,
            'vault_id': seedVaultId(),
            'version': 1,
          },
        );
        final c = await env.canvas.createCanvas(title: 'Level Flow');
        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_wi84Base/canvases');
        expect(env.lastBody, _requestJson('create_canvas.json'));
        expect(env.lastBody, {'title': 'Level Flow'});
        expect(vaultAccessShape(c), {
          'CanvasInfo': [
            '01M5ZZZZZZZZZZZZZZZZZZZZZZ',
            'Level Flow',
            1,
            1760001000000,
            1760001000001,
          ],
        });
      },
    );

    test(
      'hosted createCanvas defaults absent timestamps to 0 like MemexCli',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'POST',
          '$_wi84Base/canvases',
          status: 201,
          json: {
            'canvas_id': '01M5ZZZZZZZZZZZZZZZZZZZZZY',
            'title': 'Bare',
            'version': 1,
          },
        );
        final c = await env.canvas.createCanvas(title: 'Bare');
        expect([c.createdAt, c.updatedAt], [0, 0]);
        expect(c.version, 1);
      },
    );

    test(
      'hosted createCanvas with a used title throws title_conflict with existing_id',
      () async {
        final env = _env();
        final e = await _outcome(
          env.canvas.createCanvas(title: 'Prototype Map'),
        );
        expect(env.lastBody, _requestJson('create_canvas_title_conflict.json'));
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'title_conflict');
        expect(e.fields, {'existing_id': _wi84Canvas});
        expect(e.kind, MemexErrorKind.other);
        expect(e.message, startsWith('canvas new failed: '));
      },
    );

    test(
      'a hosted createCanvas failure reads exactly like the CLI failure on the same body',
      () async {
        final env = _env();
        final e = await _outcome(
          env.canvas.createCanvas(title: 'Prototype Map'),
        );
        _expectSameException(
          e,
          _cliFailure(
            'canvas new',
            _responseJson('create_canvas_title_conflict.json'),
          ),
        );
      },
    );
  });

  group('addToCanvas', () {
    test(
      'hosted addToCanvas posts note_id x and y and returns the existing placement',
      () async {
        final env = _env();
        final n = await env.canvas.addToCanvas(
          canvasId: _wi84Canvas,
          noteId: _wi84PlayerLoop,
          x: 999.0,
          y: 999.0,
        );
        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_wi84Base/canvases/$_wi84Canvas/nodes');
        expect(env.lastBody, _requestJson('add_node_existing.json'));
        expect(vaultAccessShape(n), {
          'CanvasNodeInfo': [
            _wi84Canvas,
            _wi84PlayerLoop,
            'Player Loop',
            0.0,
            0.0,
            0,
            1760000840000,
          ],
        });
        expect(n.x, isA<double>());
      },
    );

    test(
      'hosted addToCanvas sends fractional coordinates and parses the new placement',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'POST',
          '$_wi84Base/canvases/$_wi84Canvas/nodes',
          json: {
            'canvas_id': _wi84Canvas,
            'note_id': _wi84Pacing,
            'note_title': 'Pacing Notes',
            'placed_at': 1760001000002,
            'vault_id': seedVaultId(),
            'x': 123.456789,
            'y': -64.5,
            'z_order': 0,
          },
        );
        final n = await env.canvas.addToCanvas(
          canvasId: _wi84Canvas,
          noteId: _wi84Pacing,
          x: 123.456789,
          y: -64.5,
        );
        expect(env.lastBody, _requestJson('add_node.json'));
        expect(vaultAccessShape(n), {
          'CanvasNodeInfo': [
            _wi84Canvas,
            _wi84Pacing,
            'Pacing Notes',
            123.456789,
            -64.5,
            0,
            1760001000002,
          ],
        });
      },
    );

    test(
      'hosted addToCanvas sends the origin as doubles when x and y are omitted',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'POST',
          '$_wi84Base/canvases/$_wi84Canvas/nodes',
          json: {
            'canvas_id': _wi84Canvas,
            'note_id': _wi84Loose,
            'note_title': 'Loose Thought',
            'x': 0,
            'y': 0,
            'z_order': 0,
          },
        );
        final n = await env.canvas.addToCanvas(
          canvasId: _wi84Canvas,
          noteId: _wi84Loose,
        );
        final body = env.lastBody! as Map<String, Object?>;
        expect(body, {'note_id': _wi84Loose, 'x': 0.0, 'y': 0.0});
        expect(body['x'], isA<double>());
        expect(body['y'], isA<double>());
        // An absent placed_at is 0, and whole numbers come back as doubles.
        expect(n.placedAt, 0);
        expect(n.x, isA<double>());
        expect(n.y, isA<double>());
      },
    );

    test(
      'hosted addToCanvas on an unknown canvas or note throws not_found',
      () async {
        final env = _env();
        for (final (canvasId, noteId, response) in [
          (_wi84Unknown, _wi84Pacing, 'add_node_unknown_canvas.json'),
          (_wi84Canvas, _wi84Unknown, 'add_node_unknown_note.json'),
        ]) {
          final e = await _outcome(
            env.canvas.addToCanvas(
              canvasId: canvasId,
              noteId: noteId,
              x: canvasId == _wi84Unknown ? 123.456789 : 10.0,
              y: canvasId == _wi84Unknown ? -64.5 : 20.0,
            ),
          );
          expect(env.last.url.path, '$_wi84Base/canvases/$canvasId/nodes');
          expect(env.lastBody, _requestJson(response), reason: response);
          _expectSameException(
            e,
            _cliFailure('canvas add', _responseJson(response)),
          );
          expect((e! as MemexException).code, 'not_found');
          expect(
            (e as MemexException).message,
            startsWith('canvas add failed: '),
          );
        }
      },
    );
  });

  group('moveNode', () {
    test(
      'hosted moveNode patches x and y without z_order and returns placedAt 0',
      () async {
        final env = _env();
        final n = await env.canvas.moveNode(
          canvasId: _wi84Canvas,
          noteId: _wi84Economy,
          x: 300.75,
          y: 80.5,
        );
        expect(env.last.method, 'PATCH');
        expect(
          env.last.url.path,
          '$_wi84Base/canvases/$_wi84Canvas/nodes/$_wi84Economy',
        );
        expect(env.lastBody, {'x': 300.75, 'y': 80.5});
        expect(env.lastBody, _requestJson('move_node.json'));
        expect(vaultAccessShape(n), {
          'CanvasNodeInfo': [
            _wi84Canvas,
            _wi84Economy,
            'Economy Design',
            300.75,
            80.5,
            0,
            0,
          ],
        });
      },
    );

    test('hosted moveNode sends z_order when given', () async {
      final env = _env();
      final n = await env.canvas.moveNode(
        canvasId: _wi84Canvas,
        noteId: _wi84PlayerLoop,
        x: -12.5,
        y: 48.0,
        zOrder: 3,
      );
      expect(
        env.last.url.path,
        '$_wi84Base/canvases/$_wi84Canvas/nodes/$_wi84PlayerLoop',
      );
      expect(env.lastBody, {'x': -12.5, 'y': 48.0, 'z_order': 3});
      expect(env.lastBody, _requestJson('move_node_z.json'));
      expect(vaultAccessShape(n), {
        'CanvasNodeInfo': [
          _wi84Canvas,
          _wi84PlayerLoop,
          'Player Loop',
          -12.5,
          48.0,
          3,
          0,
        ],
      });
    });

    test(
      'hosted moveNode of a note not on the canvas throws not_found like the CLI',
      () async {
        final env = _env();
        for (final (canvasId, noteId, x, y, response) in [
          (_wi84Canvas, _wi84Loose, 1.0, 2.0, 'move_node_not_placed.json'),
          (
            _wi84Unknown,
            _wi84Economy,
            300.75,
            80.5,
            'move_node_unknown_canvas.json',
          ),
        ]) {
          final e = await _outcome(
            env.canvas.moveNode(canvasId: canvasId, noteId: noteId, x: x, y: y),
          );
          expect(
            env.last.url.path,
            '$_wi84Base/canvases/$canvasId/nodes/$noteId',
          );
          expect(env.lastBody, _requestJson(response), reason: response);
          _expectSameException(
            e,
            _cliFailure('canvas move', _responseJson(response)),
          );
          expect((e! as MemexException).code, 'not_found');
          expect(
            (e as MemexException).message,
            startsWith('canvas move failed: '),
          );
        }
      },
    );
  });

  test(
    'hosted canvas writes leave the vault revision to the call sites',
    () async {
      final env = _env();
      final before = env.container.read(vaultRevisionProvider);
      await env.canvas.addToCanvas(
        canvasId: _wi84Canvas,
        noteId: _wi84PlayerLoop,
        x: 999.0,
        y: 999.0,
      );
      await env.canvas.moveNode(
        canvasId: _wi84Canvas,
        noteId: _wi84Economy,
        x: 300.75,
        y: 80.5,
      );
      await _outcome(env.canvas.createCanvas(title: 'Prototype Map'));
      expect(env.container.read(vaultRevisionProvider), before);
    },
  );
}
