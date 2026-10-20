import '../../db.dart';
import '../../memex_cli.dart';
import '../canvas_access.dart';
import 'write_guard.dart';

/// [CanvasAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `CanvasAccess`).
class LocalCanvasAccess implements CanvasAccess {
  LocalCanvasAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  MemexCli get _cli => requireLocalCli(cli);

  // ---------- reads ----------

  @override
  Future<List<CanvasRow>> listCanvases() async =>
      db?.listCanvases() ?? const [];

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async =>
      db?.getCanvasDetail(canvasId);

  // ---------- writes ----------

  @override
  Future<CanvasInfo> createCanvas({required String title}) async =>
      _cli.createCanvas(vaultPath: vaultPath, title: title);

  @override
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) async => _cli.addToCanvas(
    vaultPath: vaultPath,
    canvasId: canvasId,
    noteId: noteId,
    x: x,
    y: y,
  );

  @override
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) async => _cli.moveNode(
    vaultPath: vaultPath,
    canvasId: canvasId,
    noteId: noteId,
    x: x,
    y: y,
    zOrder: zOrder,
  );
}
