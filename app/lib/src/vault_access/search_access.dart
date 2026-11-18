import '../memex_cli.dart';

/// Vault search for the Command palette's Passages group (Spec #59 req 39):
/// the passages of the person's notes that match a query by words or by
/// meaning.
///
/// Test doubles `extends LocalSearchAccess` (D21).
abstract interface class SearchAccess {
  /// The passages matching [query]. [allowDownload] is the palette's download
  /// flow (`memex search --allow-download`); a hosted vault ignores it.
  /// Anything other than a ready or unavailable answer is thrown.
  Future<SearchResult> search(String query, {bool allowDownload = false});
}

/// Whether the meaning arm of a search ran (req 34's `semantic`).
enum Semantic {
  /// `on`: the query was embedded and the vector arm ran.
  on,

  /// `model_not_downloaded`: a local vault whose model isn't cached.
  modelNotDownloaded,

  /// `embeddings_off`: a vault server running without `--with-embeddings`.
  embeddingsOff,

  /// `unavailable`: the embedder failed to load or run.
  unavailable,

  /// Any other value; the palette treats it as keyword only.
  unknown,
}

/// One passage hit (req 34), as `memex search` and the vault server's
/// search route print it.
class SearchHit {
  const SearchHit({
    required this.noteId,
    required this.noteTitle,
    this.noteRole,
    this.day,
    required this.chunkId,
    required this.snippet,
    this.startByte,
    this.via,
    required this.noteUpdatedAt,
  });

  /// Parses one req 34 hit object. A missing required key, or a value of
  /// the wrong type, throws [FormatException].
  // TODO(#74): skeleton only.
  factory SearchHit.fromJson(Map<String, Object?> json) => const SearchHit(
    noteId: '',
    noteTitle: '',
    chunkId: '',
    snippet: '',
    noteUpdatedAt: 0,
  );

  final String noteId;
  final String noteTitle;

  /// `daily`, `topic`, or null for a plain note.
  final String? noteRole;

  /// The ISO date of a daily note; null otherwise.
  final String? day;

  final String chunkId;

  /// The passage text (the wire's `snippet`).
  final String snippet;

  /// The passage's byte offset in the full body; null for a chunk indexed
  /// before byte offsets existed.
  final int? startByte;

  /// The ISO date of the daily note this hit was transcluded into, or null.
  final String? via;

  /// The note's `updated_at`, ms epoch.
  final int noteUpdatedAt;
}

/// What a search answers (req 39). Value equality.
sealed class SearchResult {
  const SearchResult();
}

/// The search ran. [hits] may be empty.
class SearchReady extends SearchResult {
  const SearchReady(
    this.hits, {
    required this.semantic,
    required this.truncated,
  });

  final List<SearchHit> hits;
  final Semantic semantic;
  final bool truncated;
}

/// Search can't run on this vault right now, for [reason].
class SearchUnavailable extends SearchResult {
  const SearchUnavailable(this.reason);

  final SearchUnavailableReason reason;
}

/// Why search is unavailable (req 39). Value equality.
sealed class SearchUnavailableReason {
  const SearchUnavailableReason();
}

/// A local vault with no `memex` CLI configured.
class SearchNoCli extends SearchUnavailableReason {
  const SearchNoCli();
}

/// The local `memex` predates `memex search` (exit 2, non-JSON stderr).
class MemexOutdated extends SearchUnavailableReason {
  const MemexOutdated();
}

/// The vault server predates the search route (404 no route).
class ServerOutdated extends SearchUnavailableReason {
  const ServerOutdated();
}

/// [SearchAccess] for a local vault: runs `memex search` through [cli]. A
/// null [cli] answers [SearchNoCli] without running anything.
class LocalSearchAccess implements SearchAccess {
  LocalSearchAccess({required this.vaultPath, this.cli});

  final String vaultPath;

  /// The `memex` CLI; null when none is configured.
  final MemexCli? cli;

  // TODO(#74): skeleton only.
  @override
  Future<SearchResult> search(
    String query, {
    bool allowDownload = false,
  }) async =>
      const SearchReady([], semantic: Semantic.unknown, truncated: false);
}
