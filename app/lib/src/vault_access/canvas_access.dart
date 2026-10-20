import '../db.dart';
import '../memex_cli.dart';

/// Canvases of the open vault (D13, D11 V4). Same rules as `NotesAccess`:
/// async mirrors of today's `VaultDb` canvas reads / `MemexCli` canvas
/// wrappers, today's empty values without a database, today's exceptions
/// from writes, [StateError] from a write when `VaultAccess.canWrite` is
/// false.
///
/// Frozen at merge (D13). Test doubles `extends LocalCanvasAccess` (D21).
abstract interface class CanvasAccess {
  // ---------- reads ----------

  /// `VaultDb.listCanvases`.
  Future<List<CanvasRow>> listCanvases();

  /// `VaultDb.getCanvasDetail`, or null.
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId);

  // ---------- writes ----------

  /// `memex canvas new` (`MemexCli.createCanvas`).
  Future<CanvasInfo> createCanvas({required String title});

  /// `memex canvas add` (`MemexCli.addToCanvas`).
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  });

  /// `memex canvas move` (`MemexCli.moveNode`).
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  });
}
