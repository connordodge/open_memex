import '../cli/echoes_cli.dart';
import '../memex_cli.dart';
import 'hosted/hosted_client.dart';

/// Echoes of the open note (Spec #391 req 20): passages of the person's own
/// writing in other notes that are close to it and not linked to it.
///
/// Frozen at merge (#424). Test doubles `extends LocalEchoesAccess` (D21).
abstract interface class EchoesAccess {
  /// The echoes of [noteId]. [allowDownload] is the download flow's flag
  /// (req 22: `memex echoes --allow-download`); a hosted vault ignores it.
  /// Anything other than a ready or unavailable answer is thrown.
  Future<EchoesResult> echoes(String noteId, {bool allowDownload = false});
}

/// One echo (req 14), as `memex echoes` and the vault server's echoes route
/// print it. It carries no score. Value equality on every field.
class Echo {
  const Echo({
    required this.noteId,
    required this.noteTitle,
    this.noteRole,
    this.day,
    required this.passage,
    this.startByte,
    required this.noteUpdatedAt,
  });

  /// Parses one V4 echo object: `note_id`, `note_title`, `note_role` (null,
  /// `daily` or `topic`), `day` (null or `YYYY-MM-DD`), `passage`,
  /// `start_byte` (int or null) and `note_updated_at` (ms epoch). A nullable
  /// key may be absent. A missing required key, or a value of the wrong
  /// type, throws [FormatException].
  factory Echo.fromJson(Map<String, Object?> json) => Echo(
    noteId: _required<String>(json, 'note_id'),
    noteTitle: _required<String>(json, 'note_title'),
    noteRole: _optional<String>(json, 'note_role'),
    day: _optional<String>(json, 'day'),
    passage: _required<String>(json, 'passage'),
    startByte: _optional<int>(json, 'start_byte'),
    noteUpdatedAt: _required<int>(json, 'note_updated_at'),
  );

  final String noteId;
  final String noteTitle;

  /// `daily`, `topic`, or null for a plain note.
  final String? noteRole;

  /// The ISO date of a daily note; null otherwise.
  final String? day;

  /// The best block's text.
  final String passage;

  /// The passage's byte offset in the full body; null for a chunk indexed
  /// before byte offsets existed.
  final int? startByte;

  /// The echoed note's `updated_at`, ms epoch.
  final int noteUpdatedAt;

  @override
  bool operator ==(Object other) =>
      other is Echo &&
      other.noteId == noteId &&
      other.noteTitle == noteTitle &&
      other.noteRole == noteRole &&
      other.day == day &&
      other.passage == passage &&
      other.startByte == startByte &&
      other.noteUpdatedAt == noteUpdatedAt;

  @override
  int get hashCode => Object.hash(
    noteId,
    noteTitle,
    noteRole,
    day,
    passage,
    startByte,
    noteUpdatedAt,
  );

  @override
  String toString() =>
      'Echo($noteId, $noteTitle, role: $noteRole, day: $day, '
      'startByte: $startByte, updatedAt: $noteUpdatedAt)';
}

/// [json]'s [key] as a [T]; a missing, null or other-typed value throws
/// [FormatException].
T _required<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('echo: "$key" is not a $T: $value');
}

/// [json]'s [key] as a [T], or null when it is absent or null; any other
/// type throws [FormatException].
T? _optional<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is T) return value as T?;
  throw FormatException('echo: "$key" is not a $T or null: $value');
}

/// What an echoes read answers (req 20). Value equality.
sealed class EchoesResult {
  const EchoesResult();
}

/// Echoes were read. [echoes] may be empty. [emptyNote] is the CLI's
/// `reason: "empty_note"` (the open note has no chunks); [pending] is the
/// count of passages still waiting for a vector.
class EchoesReady extends EchoesResult {
  const EchoesReady(
    this.echoes, {
    required this.emptyNote,
    required this.pending,
  });

  final List<Echo> echoes;
  final bool emptyNote;
  final int pending;

  @override
  bool operator ==(Object other) {
    if (other is! EchoesReady ||
        other.emptyNote != emptyNote ||
        other.pending != pending ||
        other.echoes.length != echoes.length) {
      return false;
    }
    for (var i = 0; i < echoes.length; i++) {
      if (other.echoes[i] != echoes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(EchoesReady, Object.hashAll(echoes), emptyNote, pending);

  @override
  String toString() =>
      'EchoesReady(${echoes.length} echoes, emptyNote: $emptyNote, '
      'pending: $pending)';
}

/// Echoes can't be read on this vault right now, for [reason].
class EchoesUnavailable extends EchoesResult {
  const EchoesUnavailable(this.reason);

  final EchoesUnavailableReason reason;

  @override
  bool operator ==(Object other) =>
      other is EchoesUnavailable && other.reason == reason;

  @override
  int get hashCode => Object.hash(EchoesUnavailable, reason);

  @override
  String toString() => 'EchoesUnavailable($reason)';
}

/// Why echoes are unavailable (req 20). Value equality.
sealed class EchoesUnavailableReason {
  const EchoesUnavailableReason();
}

/// A vault server running without `--with-embeddings` (409 `embeddings_off`).
class EmbeddingsOff extends EchoesUnavailableReason {
  const EmbeddingsOff();

  @override
  bool operator ==(Object other) => other is EmbeddingsOff;

  @override
  int get hashCode => (EmbeddingsOff).hashCode;

  @override
  String toString() => 'EmbeddingsOff()';
}

/// A local vault whose model isn't cached and no download was allowed
/// (`model_not_downloaded`).
class ModelNotDownloaded extends EchoesUnavailableReason {
  const ModelNotDownloaded();

  @override
  bool operator ==(Object other) => other is ModelNotDownloaded;

  @override
  int get hashCode => (ModelNotDownloaded).hashCode;

  @override
  String toString() => 'ModelNotDownloaded()';
}

/// The model can't be downloaded, loaded or run (`embedder_unavailable`, or
/// a timeout: `'timed out'`). [message] is the cause.
class EmbedderUnavailable extends EchoesUnavailableReason {
  const EmbedderUnavailable(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is EmbedderUnavailable && other.message == message;

  @override
  int get hashCode => Object.hash(EmbedderUnavailable, message);

  @override
  String toString() => 'EmbedderUnavailable($message)';
}

/// A local vault with no `memex` CLI (`canWrite == false`).
class NoCli extends EchoesUnavailableReason {
  const NoCli();

  @override
  bool operator ==(Object other) => other is NoCli;

  @override
  int get hashCode => (NoCli).hashCode;

  @override
  String toString() => 'NoCli()';
}

/// The `memex` binary or vault server predates echoes.
class Outdated extends EchoesUnavailableReason {
  const Outdated();

  @override
  bool operator ==(Object other) => other is Outdated;

  @override
  int get hashCode => (Outdated).hashCode;

  @override
  String toString() => 'Outdated()';
}

/// The echoes answer `{"echoes":[…],"pending":<n>,"reason":<null|string>}`
/// (the CLI's stdout and the route's 200 body alike) as an [EchoesReady].
/// `reason: "empty_note"` is [EchoesReady.emptyNote]; any other reason is
/// not. Anything that is not such an answer throws [MemexException] (never
/// [FormatException]).
EchoesReady echoesReadyFromJson(Object? decoded) {
  if (decoded is! Map<String, Object?>) {
    throw MemexException('echoes failed: the answer is not a JSON object');
  }
  final rows = decoded['echoes'];
  final pending = decoded['pending'];
  if (rows is! List<Object?> || pending is! int) {
    throw MemexException(
      'echoes failed: the answer has no echoes list or pending count',
    );
  }
  try {
    return EchoesReady(
      [
        for (final row in rows)
          Echo.fromJson(
            row is Map<String, Object?>
                ? row
                : throw const FormatException('echo: not an object'),
          ),
      ],
      emptyNote: decoded['reason'] == 'empty_note',
      pending: pending,
    );
  } on FormatException catch (e) {
    throw MemexException('echoes failed: ${e.message}');
  }
}

/// The [EchoesUnavailable] for a C1 failure [e] of a local `memex echoes`,
/// by its code, or null when the code is not one a local vault answers (the
/// caller throws [e]).
EchoesUnavailable? localEchoesUnavailableFor(MemexException e) =>
    switch (e.code) {
      'model_not_downloaded' => const EchoesUnavailable(ModelNotDownloaded()),
      _ => _embedderUnavailable(e),
    };

/// The [EchoesUnavailable] for a C1 failure [e] of the hosted echoes route,
/// by its code, or null when the code is not one a hosted vault answers.
EchoesUnavailable? hostedEchoesUnavailableFor(MemexException e) =>
    switch (e.code) {
      'embeddings_off' => const EchoesUnavailable(EmbeddingsOff()),
      _ => _embedderUnavailable(e),
    };

/// `embedder_unavailable` is [EmbedderUnavailable] with the C1 message (no
/// `echoes failed: ` prefix); any other code is null.
EchoesUnavailable? _embedderUnavailable(MemexException e) {
  if (e.code != 'embedder_unavailable') return null;
  const prefix = 'echoes failed: ';
  return EchoesUnavailable(
    EmbedderUnavailable(
      e.message.startsWith(prefix)
          ? e.message.substring(prefix.length)
          : e.message,
    ),
  );
}

/// [EchoesAccess] for a local vault: runs `memex echoes` through [cli]
/// (A1, #425). A null [cli] answers [NoCli] without running anything.
class LocalEchoesAccess implements EchoesAccess {
  LocalEchoesAccess({required this.vaultPath, this.cli});

  final String vaultPath;

  /// The `memex` CLI; null when none is configured (`noCli`).
  final MemexCli? cli;

  @override
  Future<EchoesResult> echoes(
    String noteId, {
    bool allowDownload = false,
  }) async {
    final cli = this.cli;
    if (cli == null) return const EchoesUnavailable(NoCli());
    return cli.echoes(
      vaultPath: vaultPath,
      noteId: noteId,
      allowDownload: allowDownload,
    );
  }
}

/// The exact message of the server's no-route 404 (D21a): a vault server that
/// predates the echoes route.
const _noRouteMessage = 'not found: no route for this path';

/// [EchoesAccess] for a hosted vault: `GET /notes/{note_id}/echoes?limit=8`
/// through [client] for [vaultName] (A1, #425), waiting up to 60 s. A
/// `vault_not_found` reaches the caller as the client's own exception.
class HostedEchoesAccess implements EchoesAccess {
  HostedEchoesAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  /// [allowDownload] is ignored: a hosted server never downloads for the
  /// app.
  @override
  Future<EchoesResult> echoes(
    String noteId, {
    bool allowDownload = false,
  }) async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        'GET',
        vaultName,
        '/notes/${Uri.encodeComponent(noteId)}/echoes',
        operation: 'echoes',
        query: {'limit': '8'},
        timeout: echoesTimeout,
      );
    } on HostedRequestTimeout {
      return const EchoesUnavailable(EmbedderUnavailable('timed out'));
    } on MemexException catch (e) {
      if (e.code == 'not_found' &&
          e.message == 'echoes failed: $_noRouteMessage') {
        return const EchoesUnavailable(Outdated());
      }
      final unavailable = hostedEchoesUnavailableFor(e);
      if (unavailable != null) return unavailable;
      rethrow;
    }
    return echoesReadyFromJson(body);
  }
}
