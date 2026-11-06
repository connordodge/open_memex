import '../../db.dart';
import '../../memex_cli.dart';
import '../../state/vault_state.dart' show requiredVaultSchemaVersion;
import '../vault_access.dart';
import 'canvas.dart';
import 'daily.dart';
import 'graph.dart';
import 'notes.dart';
import 'tags.dart';
import 'topics.dart';

export 'canvas.dart';
export 'daily.dart';
export 'graph.dart';
export 'notes.dart';
export 'tags.dart';
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
    LocalTagsAccess? tags,
  }) : notes =
           notes ?? LocalNotesAccess(vaultPath: vaultPath, db: db, cli: cli),
       daily =
           daily ?? LocalDailyAccess(vaultPath: vaultPath, db: db, cli: cli),
       topics =
           topics ?? LocalTopicsAccess(vaultPath: vaultPath, db: db, cli: cli),
       canvas =
           canvas ?? LocalCanvasAccess(vaultPath: vaultPath, db: db, cli: cli),
       graph = graph ?? LocalGraphAccess(vaultPath: vaultPath, db: db),
       tags = tags ?? LocalTagsAccess(vaultPath: vaultPath, db: db, cli: cli);

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
  @override
  final LocalTagsAccess tags;

  /// The revision of a local vault with no database handle. Constant: with no
  /// handle every read is empty, so there is nothing to reload.
  static const noDatabaseRevision = 'no-database';

  /// `VaultDb.dataVersion()`; [noDatabaseRevision] with no [db].
  @override
  Future<String> revision() async => db?.dataVersion() ?? noDatabaseRevision;

  /// `VaultDb.schemaVersion()`. With no [db] it is
  /// [requiredVaultSchemaVersion], so a missing handle never reads as an
  /// outdated schema (today's `vaultOpenProvider` treats it as not outdated).
  @override
  Future<int> schemaVersion() async =>
      db?.schemaVersion() ?? requiredVaultSchemaVersion;

  /// True when a `memex` CLI is configured.
  @override
  bool get canWrite => cli != null;
}
