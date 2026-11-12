import 'agents_access.dart';
import 'canvas_access.dart';
import 'daily_access.dart';
import 'echoes_access.dart';
import 'feedback_access.dart';
import 'graph_access.dart';
import 'notes_access.dart';
import 'tags_access.dart';
import 'topics_access.dart';
import 'words_access.dart';

export 'agents_access.dart';
export 'canvas_access.dart';
export 'daily_access.dart';
export 'echoes_access.dart';
export 'feedback_access.dart';
export 'graph_access.dart';
export 'notes_access.dart';
export 'tags_access.dart';
export 'words_access.dart';
export 'topics_access.dart';

/// The app's single async door to a vault (D13, Req 32): one composite of
/// per-domain interfaces, plus the vault-wide [revision] and [schemaVersion].
/// Providers and widgets reach the vault only through it.
///
/// Frozen at merge (D13). No test implements it (D21): doubles extend the
/// local domain classes and are passed to `LocalVaultAccess`. Spec #392 (D22) amends
/// it with [words], the learned-words domain, placed after [tags].
abstract interface class VaultAccess {
  NotesAccess get notes;
  AgentsAccess get agents;
  DailyAccess get daily;
  FeedbackAccess get feedback;
  TopicsAccess get topics;
  EchoesAccess get echoes;
  CanvasAccess get canvas;
  GraphAccess get graph;
  TagsAccess get tags;
  WordsAccess get words;

  /// The vault's opaque revision (Req 22, D9; D4). It changes after every
  /// committed write by any writer except vector-only writes; it may also
  /// change with no visible change, so reloads must be idempotent. Local:
  /// `VaultDb.dataVersion()`.
  Future<String> revision();

  /// `MAX(schema_version.version)`, 0 when missing (`VaultDb.schemaVersion`).
  Future<int> schemaVersion();

  /// False when this vault can't write right now (a local vault with no
  /// `memex` CLI configured). Lets a site tell "no CLI" apart without calling
  /// a write; a write while it is false throws [StateError] and runs nothing.
  bool get canWrite;
}
