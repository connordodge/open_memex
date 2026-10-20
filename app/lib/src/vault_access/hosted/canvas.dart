import '../../db.dart';
import '../../memex_cli.dart';
import '../canvas_access.dart';
import 'hosted_client.dart';

/// [CanvasAccess] for a hosted vault (D11 V4, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
class HostedCanvasAccess implements CanvasAccess {
  HostedCanvasAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  // ---------- reads ----------

  @override
  Future<List<CanvasRow>> listCanvases() => throw UnimplementedError('#84');

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) =>
      throw UnimplementedError('#84');

  // ---------- writes ----------

  @override
  Future<CanvasInfo> createCanvas({required String title}) =>
      throw UnimplementedError('#84');

  @override
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) => throw UnimplementedError('#84');

  @override
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) => throw UnimplementedError('#84');
}
