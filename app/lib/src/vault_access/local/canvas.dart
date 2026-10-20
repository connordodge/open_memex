import '../../db.dart';
import '../../memex_cli.dart';
import '../canvas_access.dart';

/// [CanvasAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `CanvasAccess`).
class LocalCanvasAccess implements CanvasAccess {
  LocalCanvasAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  // RED SKELETON (#70 test author): bodies are placeholders; the implementer
  // replaces every one with the delegation to [db] / [cli].

  static CanvasNodeInfo _placeholderNode() => CanvasNodeInfo(
    canvasId: '',
    noteId: '',
    noteTitle: '',
    x: 0,
    y: 0,
    zOrder: 0,
    placedAt: 0,
  );

  @override
  Future<List<CanvasRow>> listCanvases() async => const [];

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async => null;

  @override
  Future<CanvasInfo> createCanvas({required String title}) async => CanvasInfo(
    canvasId: '',
    title: '',
    version: 0,
    createdAt: 0,
    updatedAt: 0,
  );

  @override
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) async => _placeholderNode();

  @override
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) async => _placeholderNode();
}
