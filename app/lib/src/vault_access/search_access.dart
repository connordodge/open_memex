import '../cli/search_cli.dart';
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
    this.attachment,
  });

  /// Parses one req 34 hit object: `note_id`, `note_title`, `note_role`
  /// (null, `daily` or `topic`), `day` (null or `YYYY-MM-DD`), `chunk_id`,
  /// `snippet`, `start_byte` (int or null), `via` (null or `YYYY-MM-DD`) and
  /// `note_updated_at` (ms epoch). A nullable key may be absent. A missing
  /// or null required key, or a value of the wrong type, throws
  /// [FormatException].
  factory SearchHit.fromJson(Map<String, Object?> json) => SearchHit(
    noteId: _required<String>(json, 'note_id'),
    noteTitle: _required<String>(json, 'note_title'),
    noteRole: _optional<String>(json, 'note_role'),
    day: _optional<String>(json, 'day'),
    chunkId: _required<String>(json, 'chunk_id'),
    snippet: _required<String>(json, 'snippet'),
    startByte: _optional<int>(json, 'start_byte'),
    via: _optional<String>(json, 'via'),
    noteUpdatedAt: _required<int>(json, 'note_updated_at'),
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

  /// The attachment this hit came from (Spec #123 R46, R48), or null for a
  /// hit on the note's own text (and from a `memex` or server that predates
  /// attachments).
  final SearchHitAttachment? attachment;

  @override
  bool operator ==(Object other) =>
      other is SearchHit &&
      other.noteId == noteId &&
      other.noteTitle == noteTitle &&
      other.noteRole == noteRole &&
      other.day == day &&
      other.chunkId == chunkId &&
      other.snippet == snippet &&
      other.startByte == startByte &&
      other.via == via &&
      other.noteUpdatedAt == noteUpdatedAt;

  @override
  int get hashCode => Object.hash(
    noteId,
    noteTitle,
    noteRole,
    day,
    chunkId,
    snippet,
    startByte,
    via,
    noteUpdatedAt,
  );

  @override
  String toString() =>
      'SearchHit($noteId, $noteTitle, role: $noteRole, day: $day, '
      'chunk: $chunkId, startByte: $startByte, via: $via, '
      'updatedAt: $noteUpdatedAt)';
}

/// A hit's `attachment: {name, path}` (Spec #123 R48). Value equality.
class SearchHitAttachment {
  const SearchHitAttachment({required this.name, required this.path});

  /// The stored name.
  final String name;

  /// The vault-relative `objects/<h2>/<hash>/<name>` path.
  final String path;
}

/// One referencing note of a [SearchAttachment]: `{id, title}`. Value
/// equality.
class SearchAttachmentNote {
  const SearchAttachmentNote({required this.id, required this.title});

  final String id;
  final String title;
}

/// One entry of the answer's top-level `attachments` list (Spec #123 R48):
/// `{name, path, type, size, snippet?, notes: [{id, title}]}`. [snippet] is
/// the matching text of a content match, null for a name-only match. Value
/// equality.
class SearchAttachment {
  const SearchAttachment({
    required this.name,
    required this.path,
    required this.size,
    required this.type,
    this.snippet,
    this.notes = const [],
  });

  final String name;
  final String path;

  /// Bytes.
  final int size;

  /// The media type, e.g. `text/plain`.
  final String type;

  /// The matching text (content match), or null (name-only match).
  final String? snippet;

  /// The notes that reference it, in the answer's order.
  final List<SearchAttachmentNote> notes;
}

/// [json]'s [key] as a [T]; a missing, null or other-typed value throws
/// [FormatException].
T _required<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('search hit: "$key" is not a $T: $value');
}

/// [json]'s [key] as a [T], or null when it is absent or null; any other
/// type throws [FormatException].
T? _optional<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is T) return value as T?;
  throw FormatException('search hit: "$key" is not a $T or null: $value');
}

/// The [Semantic] for req 34's `semantic` string; any other string is
/// [Semantic.unknown].
Semantic semanticFromWire(String wire) => switch (wire) {
  'on' => Semantic.on,
  'model_not_downloaded' => Semantic.modelNotDownloaded,
  'embeddings_off' => Semantic.embeddingsOff,
  'unavailable' => Semantic.unavailable,
  _ => Semantic.unknown,
};

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
    this.attachments = const [],
  });

  final List<SearchHit> hits;

  /// The matching attachments (Spec #123 R47, R48), in fused order; empty
  /// when the answer has none (or predates attachments).
  final List<SearchAttachment> attachments;
  final Semantic semantic;
  final bool truncated;

  @override
  bool operator ==(Object other) {
    if (other is! SearchReady ||
        other.semantic != semantic ||
        other.truncated != truncated ||
        other.hits.length != hits.length) {
      return false;
    }
    for (var i = 0; i < hits.length; i++) {
      if (other.hits[i] != hits[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(SearchReady, Object.hashAll(hits), semantic, truncated);

  @override
  String toString() =>
      'SearchReady(${hits.length} hits, semantic: ${semantic.name}, '
      'truncated: $truncated)';
}

/// Search can't run on this vault right now, for [reason].
class SearchUnavailable extends SearchResult {
  const SearchUnavailable(this.reason);

  final SearchUnavailableReason reason;

  @override
  bool operator ==(Object other) =>
      other is SearchUnavailable && other.reason == reason;

  @override
  int get hashCode => Object.hash(SearchUnavailable, reason);

  @override
  String toString() => 'SearchUnavailable($reason)';
}

/// Why search is unavailable (req 39). Value equality.
sealed class SearchUnavailableReason {
  const SearchUnavailableReason();
}

/// A local vault with no `memex` CLI configured.
class SearchNoCli extends SearchUnavailableReason {
  const SearchNoCli();

  @override
  bool operator ==(Object other) => other is SearchNoCli;

  @override
  int get hashCode => (SearchNoCli).hashCode;

  @override
  String toString() => 'SearchNoCli()';
}

/// The local `memex` predates `memex search` (exit 2, non-JSON stderr).
class MemexOutdated extends SearchUnavailableReason {
  const MemexOutdated();

  @override
  bool operator ==(Object other) => other is MemexOutdated;

  @override
  int get hashCode => (MemexOutdated).hashCode;

  @override
  String toString() => 'MemexOutdated()';
}

/// The vault server predates the search route (404 no route).
class ServerOutdated extends SearchUnavailableReason {
  const ServerOutdated();

  @override
  bool operator ==(Object other) => other is ServerOutdated;

  @override
  int get hashCode => (ServerOutdated).hashCode;

  @override
  String toString() => 'ServerOutdated()';
}

/// The search answer `{"query":…,"semantic":…,"hits":[…],"truncated":…}`
/// (req 34: the CLI's stdout and the route's 200 body alike) as a
/// [SearchReady]. `query` is not read. Anything that is not such an answer
/// throws [MemexException] (never [FormatException]).
SearchReady searchReadyFromJson(Object? decoded) {
  if (decoded is! Map<String, Object?>) {
    throw MemexException('search failed: the answer is not a JSON object');
  }
  final semantic = decoded['semantic'];
  final rows = decoded['hits'];
  final truncated = decoded['truncated'];
  if (semantic is! String || rows is! List<Object?> || truncated is! bool) {
    throw MemexException(
      'search failed: the answer has no semantic, hits list or truncated flag',
    );
  }
  try {
    return SearchReady(
      [
        for (final row in rows)
          SearchHit.fromJson(
            row is Map<String, Object?>
                ? row
                : throw const FormatException('search hit: not an object'),
          ),
      ],
      semantic: semanticFromWire(semantic),
      truncated: truncated,
    );
  } on FormatException catch (e) {
    throw MemexException('search failed: ${e.message}');
  }
}

/// [SearchAccess] for a local vault: runs `memex search` through [cli]. A
/// null [cli] answers [SearchNoCli] without running anything.
class LocalSearchAccess implements SearchAccess {
  LocalSearchAccess({required this.vaultPath, this.cli});

  final String vaultPath;

  /// The `memex` CLI; null when none is configured.
  final MemexCli? cli;

  @override
  Future<SearchResult> search(
    String query, {
    bool allowDownload = false,
  }) async {
    final cli = this.cli;
    if (cli == null) return const SearchUnavailable(SearchNoCli());
    return cli.search(
      vaultPath: vaultPath,
      query: query,
      allowDownload: allowDownload,
    );
  }
}
