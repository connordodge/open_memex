import '../../db.dart';
import '../../memex_cli.dart';
import '../../state/vault_state.dart' show requiredVaultSchemaVersion;
import '../vault_access.dart';
import 'agents.dart';
import 'canvas.dart';
import 'daily.dart';
import 'feedback.dart';
import 'graph.dart';
import 'notes.dart';
import 'tags.dart';
import 'topics.dart';
import 'words.dart';

export 'agents.dart';
export 'canvas.dart';
export 'daily.dart';
export 'feedback.dart';
export 'graph.dart';
export 'notes.dart';
export 'tags.dart';
export 'topics.dart';
export 'words.dart';

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
    LocalAgentsAccess? agents,
    LocalDailyAccess? daily,
    LocalFeedbackAccess? feedback,
    LocalTopicsAccess? topics,
    LocalEchoesAccess? echoes,
    LocalCanvasAccess? canvas,
    LocalGraphAccess? graph,
    LocalTagsAccess? tags,
    LocalWordsAccess? words,
  }) : notes =
           notes ?? LocalNotesAccess(vaultPath: vaultPath, db: db, cli: cli),
       agents = agents ?? LocalAgentsAccess(vaultPath: vaultPath, db: db),
       daily =
           daily ?? LocalDailyAccess(vaultPath: vaultPath, db: db, cli: cli),
       feedback =
           feedback ??
           LocalFeedbackAccess(vaultPath: vaultPath, db: db, cli: cli),
       topics =
           topics ?? LocalTopicsAccess(vaultPath: vaultPath, db: db, cli: cli),
       echoes = echoes ?? LocalEchoesAccess(vaultPath: vaultPath, cli: cli),
       canvas =
           canvas ?? LocalCanvasAccess(vaultPath: vaultPath, db: db, cli: cli),
       graph = graph ?? LocalGraphAccess(vaultPath: vaultPath, db: db),
       tags = tags ?? LocalTagsAccess(vaultPath: vaultPath, db: db, cli: cli),
       words =
           words ?? LocalWordsAccess(vaultPath: vaultPath, db: db, cli: cli);

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  @override
  final LocalNotesAccess notes;
  @override
  final LocalAgentsAccess agents;
  @override
  final LocalDailyAccess daily;
  @override
  final LocalFeedbackAccess feedback;
  @override
  final LocalTopicsAccess topics;
  @override
  final LocalEchoesAccess echoes;
  @override
  final LocalCanvasAccess canvas;
  @override
  final LocalGraphAccess graph;
  @override
  final LocalTagsAccess tags;
  @override
  final LocalWordsAccess words;

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
