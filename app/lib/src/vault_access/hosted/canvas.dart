import '../../db.dart';
import '../../memex_cli.dart';
import '../canvas_access.dart';
import 'hosted_client.dart';

/// [CanvasAccess] for a hosted vault (D11 V4, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
///
/// Errors carry the `MemexCli` wrapper's operation label (`canvas new`,
/// `canvas add`, `canvas move`; reads use `canvas ls` and `canvas get`).
/// Coordinates go out and come back as doubles. Writes leave
/// `vaultRevisionProvider` to their call sites.
class HostedCanvasAccess implements CanvasAccess {
  HostedCanvasAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    required String operation,
    Object? body,
  }) => client.vaultRequest(
    method,
    vaultName,
    path,
    operation: operation,
    body: body,
  );

  static String _canvas(String id) => '/canvases/${Uri.encodeComponent(id)}';

  static List<Map<String, Object?>> _rows(Object? list) =>
      (list as List).cast<Map<String, Object?>>();

  static int _int(Object? n) => (n as num).toInt();

  static double _double(Object? n) => (n as num).toDouble();

  /// An integer that `MemexCli` reads as 0 when absent.
  static int _intOr0(Object? n) => (n as num?)?.toInt() ?? 0;

  // ---------- reads ----------

  @override
  Future<List<CanvasRow>> listCanvases() async {
    final json = await _call('GET', '/canvases', operation: 'canvas ls');
    return [
      for (final r in _rows(json['canvases']))
        CanvasRow(
          canvasId: r['canvas_id'] as String,
          title: r['title'] as String,
          createdAt: _int(r['created_at']),
          updatedAt: _int(r['updated_at']),
          version: _int(r['version']),
          nodeCount: _int(r['node_count']),
        ),
    ];
  }

  /// The `memex canvas get` object as today's [CanvasDetailRow]. Null only
  /// for `not_found`, like the local read; every other error is thrown.
  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async {
    final Map<String, Object?> json;
    try {
      json = await _call('GET', _canvas(canvasId), operation: 'canvas get');
    } on MemexException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
    return CanvasDetailRow(
      canvasId: json['canvas_id'] as String,
      title: json['title'] as String,
      createdAt: _int(json['created_at']),
      updatedAt: _int(json['updated_at']),
      version: _int(json['version']),
      nodes: [
        for (final n in _rows(json['nodes']))
          CanvasNodeRow(
            noteId: n['note_id'] as String,
            noteTitle: n['note_title'] as String,
            x: _double(n['x']),
            y: _double(n['y']),
            zOrder: _int(n['z_order']),
            placedAt: _int(n['placed_at']),
          ),
      ],
      edges: [
        for (final e in _rows(json['edges']))
          CanvasEdgeRow(
            linkId: e['link_id'] as String,
            fromNoteId: e['from_note_id'] as String,
            toNoteId: e['to_note_id'] as String,
            linkText: e['link_text'] as String,
            kind: e['kind'] as String,
            label: e['label'] as String?,
            position: _int(e['position']),
            source: e['source'] as String,
          ),
      ],
    );
  }

  // ---------- writes ----------

  /// `POST /canvases {title}`: the `memex canvas new` object, with absent
  /// timestamps read as 0 (as `MemexCli.createCanvas` does).
  @override
  Future<CanvasInfo> createCanvas({required String title}) async {
    final json = await _call(
      'POST',
      '/canvases',
      operation: 'canvas new',
      body: {'title': title},
    );
    return CanvasInfo(
      canvasId: json['canvas_id'] as String,
      title: json['title'] as String,
      version: _int(json['version']),
      createdAt: _intOr0(json['created_at']),
      updatedAt: _intOr0(json['updated_at']),
    );
  }

  /// The `memex canvas add` / `memex canvas move` object as a
  /// [CanvasNodeInfo]; an absent `placed_at` (always, for a move) is 0.
  static CanvasNodeInfo _node(Map<String, Object?> j) => CanvasNodeInfo(
    canvasId: j['canvas_id'] as String,
    noteId: j['note_id'] as String,
    noteTitle: j['note_title'] as String,
    x: _double(j['x']),
    y: _double(j['y']),
    zOrder: _int(j['z_order']),
    placedAt: _intOr0(j['placed_at']),
  );

  @override
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) async => _node(
    await _call(
      'POST',
      '${_canvas(canvasId)}/nodes',
      operation: 'canvas add',
      body: {'note_id': noteId, 'x': x, 'y': y},
    ),
  );

  /// `z_order` is sent only when [zOrder] is given; omitted, the server
  /// keeps the node's z.
  @override
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) async => _node(
    await _call(
      'PATCH',
      '${_canvas(canvasId)}/nodes/${Uri.encodeComponent(noteId)}',
      operation: 'canvas move',
      body: {'x': x, 'y': y, 'z_order': ?zOrder},
    ),
  );
}
