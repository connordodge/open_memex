// WI #413 (Spec #394 req 15-16, 38, 40, 43): the embedding coverage and
// model status the Semantic recall tab shows, and how reading it went. The
// wire shape is R1's (#403): `memex embeddings status --vault <path>` and
// `GET /vaults/{name}/api/v1/embeddings` both answer
// `{server_embeddings, chunks, embedded, model_cached, model_bytes}`.

/// One embeddings status read.
class EmbeddingsStatus {
  const EmbeddingsStatus({
    required this.serverEmbeddings,
    required this.chunks,
    required this.embedded,
    required this.modelCached,
    required this.modelBytes,
  });

  /// Reads the wire shape. `server_embeddings` may be absent or null (the
  /// local CLI); otherwise it is a bool. Throws [FormatException] when the
  /// shape is wrong: not an object; `chunks`, `embedded` or `model_bytes`
  /// missing or not an integer; `model_cached` missing or not a bool; or
  /// `server_embeddings` present and neither null nor a bool.
  factory EmbeddingsStatus.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('embeddings status is not a JSON object');
    }
    final server = json['server_embeddings'];
    if (server != null && server is! bool) {
      throw const FormatException('server_embeddings is not a bool or null');
    }
    final modelCached = json['model_cached'];
    if (modelCached is! bool) {
      throw const FormatException('model_cached is missing or not a bool');
    }
    return EmbeddingsStatus(
      serverEmbeddings: server as bool?,
      chunks: _int(json, 'chunks'),
      embedded: _int(json, 'embedded'),
      modelCached: modelCached,
      modelBytes: _int(json, 'model_bytes'),
    );
  }

  static int _int(Map<dynamic, dynamic> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw FormatException('$key is missing or not an integer');
    }
    return value;
  }

  /// Whether the vault server runs with `--with-embeddings`; null from the
  /// local CLI.
  final bool? serverEmbeddings;

  /// Passages (chunks) in the vault.
  final int chunks;

  /// Chunks with a vector (orphaned vectors excluded, #391).
  final int embedded;

  /// The complete model files are in the cache that process would use.
  final bool modelCached;

  /// The model cache's size on disk, or 0.
  final int modelBytes;

  /// `chunks − embedded`.
  int get waiting => chunks - embedded;
}

/// What reading the embeddings status gave. Reads never throw for an
/// expected failure: those are results.
sealed class EmbeddingsStatusResult {
  const EmbeddingsStatusResult();
}

/// The status.
final class EmbeddingsStatusOk extends EmbeddingsStatusResult {
  const EmbeddingsStatusOk(this.status);

  final EmbeddingsStatus status;
}

/// Local vault and no `memex` binary (none configured, or it cannot start).
final class EmbeddingsBinaryNotFound extends EmbeddingsStatusResult {
  const EmbeddingsBinaryNotFound();
}

/// `memex embeddings status` exited with a usage error (clap exit 2): the
/// memex is older than the app.
final class EmbeddingsTooOld extends EmbeddingsStatusResult {
  const EmbeddingsTooOld();
}

/// Hosted vault: the server answered `404 not_found` (no such route), so it
/// is older than the app.
final class EmbeddingsServerTooOld extends EmbeddingsStatusResult {
  const EmbeddingsServerTooOld();
}

/// Any other failure. [message] is the CLI's or the server's own message,
/// without the `<operation> failed: ` prefix.
final class EmbeddingsStatusError extends EmbeddingsStatusResult {
  const EmbeddingsStatusError(this.message);

  final String message;
}
