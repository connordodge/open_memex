import '../../db.dart';
import '../../memex_cli.dart';
import '../vault_access.dart';
import 'canvas.dart';
import 'daily.dart';
import 'graph.dart';
import 'notes.dart';
import 'topics.dart';

export 'canvas.dart';
export 'daily.dart';
export 'graph.dart';
export 'notes.dart';
export 'topics.dart';

/// [VaultAccess] for a local vault at [vaultPath]: reads from the app's
/// read-only [db] handle, writes through [cli] (D13). Either may be null:
/// no [db] gives today's empty reads, no [cli] makes [canWrite] false.
///
/// A domain argument (e.g. [notes]) replaces that domain's default
/// `Local<D>Access`; tests pass doubles that extend it (D21).
class LocalVaultAccess implements VaultAccess {
  LocalVaultAccess({
    required this.vaultPath,
    this.db,
    this.cli,
    LocalNotesAccess? notes,
    LocalDailyAccess? daily,
    LocalTopicsAccess? topics,
    LocalCanvasAccess? canvas,
    LocalGraphAccess? graph,
  }) : notes =
           notes ?? LocalNotesAccess(vaultPath: vaultPath, db: db, cli: cli),
       daily =
           daily ?? LocalDailyAccess(vaultPath: vaultPath, db: db, cli: cli),
       topics =
           topics ?? LocalTopicsAccess(vaultPath: vaultPath, db: db, cli: cli),
       canvas =
           canvas ?? LocalCanvasAccess(vaultPath: vaultPath, db: db, cli: cli),
       graph = graph ?? LocalGraphAccess(vaultPath: vaultPath, db: db);

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  @override
  final LocalNotesAccess notes;
  @override
  final LocalDailyAccess daily;
  @override
  final LocalTopicsAccess topics;
  @override
  final LocalCanvasAccess canvas;
  @override
  final LocalGraphAccess graph;

  // RED SKELETON (#70 test author): placeholders until the implementer
  // delegates to [db] / [cli].

  @override
  Future<String> revision() async => '';

  @override
  Future<int> schemaVersion() async => 0;

  @override
  bool get canWrite => false;
}
