import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thin wrapper around the `memex` CLI binary.
class MemexCli {
  MemexCli({required this.binaryPath});

  final String binaryPath;

  /// Find a `memex` binary. Order: the Bundled memex beside the executable,
  /// then [picked] if it exists, then `~/.cargo/bin`, `/usr/local/bin` and
  /// `/opt/homebrew/bin`. A missing or empty [picked] is skipped.
  ///
  /// The Bundled memex always matches the app's schema, so it wins over a
  /// picked path: a path picked once ("locate memex binary…") outlives the
  /// binary it named, and an older picked memex refuses every write on a
  /// vault the newer app has migrated ("schema version unsupported"; v0.3.0,
  /// Learn Spelling failed). [picked] still applies to a build with no
  /// Bundled memex, such as a `flutter run` dev build.
  /// Seams (production defaults): [executablePath]
  /// (`Platform.resolvedExecutable`), [exists] (`File(path).existsSync()`),
  /// [home] (`$HOME`) and [picked] (a user-picked path).
  static String? autodiscover({
    String? executablePath,
    bool Function(String path)? exists,
    String? home,
    String? picked,
  }) {
    final fileExists = exists ?? (path) => File(path).existsSync();
    final homeDir = home ?? Platform.environment['HOME'];
    final exe = executablePath ?? Platform.resolvedExecutable;
    final candidates = <String>[
      p.join(p.dirname(exe), 'memex'),
      if (picked != null && picked.isNotEmpty) picked,
      if (homeDir != null) p.join(homeDir, '.cargo', 'bin', 'memex'),
      '/usr/local/bin/memex',
      '/opt/homebrew/bin/memex',
    ];
    for (final c in candidates) {
      if (fileExists(c)) return c;
    }
    return null;
  }

  /// Run `memex <args>`, writing [stdinBody] to stdin when given. Public for
  /// CLI wrapper extensions (`lib/src/cli/<area>_cli.dart`) and test fakes;
  /// every wrapper in this class goes through it.
  ///
  /// With a [timeout], a process still running when it passes is killed
  /// (and reaped) and the call throws [MemexCliTimeout]. Without one it
  /// waits for the process however long it runs.
  Future<MemexResult> run(
    List<String> args, {
    String? stdinBody,
    Duration? timeout,
  }) async {
    final proc = await Process.start(binaryPath, args, runInShell: false);
    if (timeout != null) {
      return _runWithTimeout(proc, args, stdinBody, timeout);
    }
    if (stdinBody != null) {
      proc.stdin.write(stdinBody);
      await proc.stdin.flush();
    }
    await proc.stdin.close();
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final outFut = proc.stdout.transform(utf8.decoder).forEach(stdoutBuf.write);
    final errFut = proc.stderr.transform(utf8.decoder).forEach(stderrBuf.write);
    final code = await proc.exitCode;
    await Future.wait([outFut, errFut]);
    return MemexResult(
      exitCode: code,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  /// [run] with a [timeout]: everything after the start (the stdin write,
  /// the exit, the output) must finish before [timeout] passes. Otherwise
  /// the process is SIGKILLed and reaped, its output streams are dropped (a
  /// grandchild holding a pipe can't hold the call), and it throws
  /// [MemexCliTimeout].
  Future<MemexResult> _runWithTimeout(
    Process proc,
    List<String> args,
    String? stdinBody,
    Duration timeout,
  ) async {
    // A killed child closes its stdin pipe; a write still pending then
    // fails on `done`, which nobody else awaits.
    unawaited(proc.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final subs = [
      _collect(proc.stdout, stdoutBuf, outDone),
      _collect(proc.stderr, stderrBuf, errDone),
    ];
    final outputs = Future.wait([outDone.future, errDone.future]);
    // Listened to now, so an output error that lands before [finish] awaits
    // it (or after the kill) is not an uncaught one.
    unawaited(outputs.then<void>((_) {}, onError: (Object _) {}));
    Future<MemexResult> finish() async {
      // A child that closes its stdin or exits early fails the write with
      // EPIPE. The run then still waits (inside [timeout]) for its exit and
      // output, so a failed write never skips the kill.
      if (stdinBody != null) {
        try {
          proc.stdin.write(stdinBody);
          await proc.stdin.flush();
        } on IOException {
          // Fall through to the close, the exit and the output.
        }
      }
      try {
        await proc.stdin.close();
      } on IOException {
        // As above.
      }
      final code = await proc.exitCode;
      await outputs;
      return MemexResult(
        exitCode: code,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
      );
    }

    try {
      return await finish().timeout(timeout);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode;
      for (final sub in subs) {
        unawaited(sub.cancel());
      }
      throw MemexCliTimeout(args, timeout);
    }
  }

  /// Decodes [stream] into [buf]; [done] completes at its end or first error.
  static StreamSubscription<String> _collect(
    Stream<List<int>> stream,
    StringBuffer buf,
    Completer<void> done,
  ) => stream
      .transform(utf8.decoder)
      .listen(
        buf.write,
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );

  Future<void> initVault(String vaultPath) async {
    final r = await run(['init', vaultPath]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('init', r);
    }
  }

  Future<String> addNote({
    required String vaultPath,
    String? title,
    List<String> tags = const [],
    required String contentMd,
    bool withEmbeddings = false,
    String? role,
  }) async {
    final args = <String>[
      'add',
      '--vault',
      vaultPath,
      if (title != null && title.isNotEmpty) ...['--title', title],
      if (tags.isNotEmpty) ...['--tags', tags.join(',')],
      if (withEmbeddings) '--with-embeddings',
      if (role != null) ...['--role', role],
    ];
    final r = await run(args, stdinBody: contentMd);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('add', r);
    }
    final m = RegExp(r'note_id:\s*([0-9A-Z]{26})').firstMatch(r.stdout);
    if (m == null) {
      throw MemexException(
        'add: could not parse note_id from output: ${r.stdout}',
      );
    }
    return m.group(1)!;
  }

  Future<NoteUpdateResult> updateNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool withEmbeddings = false,
    bool noRenameLinks = false,
  }) async {
    final args = <String>[
      'update',
      '--vault',
      vaultPath,
      '--note-id',
      noteId,
      '--expected-version',
      expectedVersion.toString(),
      if (title != null && title.isNotEmpty) ...['--title', title],
      if (noRenameLinks) '--no-rename-links',
      if (withEmbeddings) '--with-embeddings',
    ];
    final r = await run(args, stdinBody: contentMd);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('update', r);
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    return NoteUpdateResult(
      noteId: json['note_id'] as String,
      version: (json['version'] as num).toInt(),
      updatedAt: (json['updated_at'] as num).toInt(),
    );
  }

  /// `memex tag add`: a body-less `person` tag on [noteId] (#242 T4b).
  Future<TagAddResult> tagAdd({
    required String vaultPath,
    required String noteId,
    required String tag,
  }) => _tagCall('add', vaultPath, noteId, tag, parseTagAddResult);

  /// `memex tag rm`: removes [tag] from [noteId] (#242 T4b). A tag already
  /// gone is a success with [TagRmResult.removed] false.
  Future<TagRmResult> tagRm({
    required String vaultPath,
    required String noteId,
    required String tag,
  }) => _tagCall('rm', vaultPath, noteId, tag, parseTagRmResult);

  /// `memex tag <verb>` with [parse] over its stdout. A CLI failure keeps its
  /// C1 code and fields; stdout that is not the contract shape throws a
  /// [MemexException] with a null code.
  Future<T> _tagCall<T>(
    String verb,
    String vaultPath,
    String noteId,
    String tag,
    T? Function(Map<String, Object?> json) parse,
  ) async {
    final operation = 'tag $verb';
    final r = await run([
      'tag',
      verb,
      '--vault',
      vaultPath,
      '--note-id',
      noteId,
      '--tag',
      tag,
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure(operation, r);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(r.stdout.trim());
    } on FormatException {
      decoded = null;
    }
    final parsed = decoded is Map<String, Object?> ? parse(decoded) : null;
    if (parsed == null) {
      throw MemexException('$operation: could not parse output: ${r.stdout}');
    }
    return parsed;
  }

  /// Add a wikilink from one note to another. Mirrors the `memex add-link`
  /// CLI subcommand. Idempotent — if the link already exists, the returned
  /// [AddLinkResult.wasExisting] is true and no markdown mutation occurs.
  Future<AddLinkResult> addLink({
    required String vaultPath,
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
    bool withEmbeddings = false,
  }) async {
    final args = <String>[
      'add-link',
      '--vault',
      vaultPath,
      '--from',
      fromNoteId,
      '--to',
      toNoteId,
      '--kind',
      kind,
      if (label != null && label.isNotEmpty) ...['--label', label],
      if (withEmbeddings) '--with-embeddings',
    ];
    final r = await run(args);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('add-link', r);
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    return AddLinkResult(
      linkId: json['link_id'] as String?,
      fromNoteId: json['from'] as String,
      toNoteId: json['to'] as String,
      kind: json['kind'] as String,
      source: json['source'] as String,
      wasExisting: json['was_existing'] as bool,
      noteVersion: (json['note_version'] as num).toInt(),
    );
  }

  /// Rewrite the kind/label of an existing wikilink in place.
  Future<UpdateLinkResult> updateLink({
    required String vaultPath,
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) async {
    final args = <String>[
      'update-link',
      '--vault',
      vaultPath,
      '--link-id',
      linkId,
      if (kind != null && kind.isNotEmpty) ...['--kind', kind],
      if (label != null && !clearLabel) ...['--label', label],
      if (clearLabel) '--clear-label',
    ];
    final r = await run(args);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('update-link', r);
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    return UpdateLinkResult(
      linkId: json['link_id'] as String,
      fromNoteId: json['from_note_id'] as String,
      toNoteId: json['to_note_id'] as String?,
      kind: json['kind'] as String,
      label: json['label'] as String?,
      source: json['source'] as String,
      position: (json['position'] as num).toInt(),
    );
  }

  // ---------- canvas wrappers ----------

  Future<CanvasInfo> createCanvas({
    required String vaultPath,
    required String title,
  }) async {
    final r = await run([
      'canvas',
      'new',
      '--vault',
      vaultPath,
      '--title',
      title,
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas new', r);
    }
    return CanvasInfo._fromJson(
      jsonDecode(r.stdout.trim()) as Map<String, dynamic>,
    );
  }

  Future<List<CanvasSummary>> listCanvases({required String vaultPath}) async {
    final r = await run(['canvas', 'ls', '--vault', vaultPath]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas ls', r);
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    final arr = (json['canvases'] as List).cast<Map<String, dynamic>>();
    return arr.map(CanvasSummary._fromJson).toList();
  }

  Future<CanvasDetail> getCanvas({
    required String vaultPath,
    required String canvasId,
  }) async {
    final r = await run([
      'canvas',
      'get',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas get', r);
    }
    return CanvasDetail._fromJson(
      jsonDecode(r.stdout.trim()) as Map<String, dynamic>,
    );
  }

  Future<CanvasInfo> renameCanvas({
    required String vaultPath,
    required String canvasId,
    required String title,
    required int expectedVersion,
  }) async {
    final r = await run([
      'canvas',
      'rename',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
      '--title',
      title,
      '--expected-version',
      expectedVersion.toString(),
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas rename', r);
    }
    return CanvasInfo._fromJson(
      jsonDecode(r.stdout.trim()) as Map<String, dynamic>,
    );
  }

  Future<void> deleteCanvas({
    required String vaultPath,
    required String canvasId,
    required int expectedVersion,
  }) async {
    final r = await run([
      'canvas',
      'rm',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
      '--expected-version',
      expectedVersion.toString(),
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas rm', r);
    }
  }

  Future<CanvasNodeInfo> addToCanvas({
    required String vaultPath,
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) async {
    final r = await run([
      'canvas',
      'add',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
      '--note-id',
      noteId,
      '--x',
      x.toString(),
      '--y',
      y.toString(),
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas add', r);
    }
    return CanvasNodeInfo._fromJson(
      jsonDecode(r.stdout.trim()) as Map<String, dynamic>,
    );
  }

  Future<void> removeFromCanvas({
    required String vaultPath,
    required String canvasId,
    required String noteId,
  }) async {
    final r = await run([
      'canvas',
      'remove',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
      '--note-id',
      noteId,
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas remove', r);
    }
  }

  Future<CanvasNodeInfo> moveNode({
    required String vaultPath,
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) async {
    final r = await run([
      'canvas',
      'move',
      '--vault',
      vaultPath,
      '--canvas-id',
      canvasId,
      '--note-id',
      noteId,
      '--x',
      x.toString(),
      '--y',
      y.toString(),
      if (zOrder != null) ...['--z', zOrder.toString()],
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('canvas move', r);
    }
    return CanvasNodeInfo._fromJson(
      jsonDecode(r.stdout.trim()) as Map<String, dynamic>,
    );
  }

  /// Fetch a single note as JSON via `memex get`. Optionally include the
  /// outgoing/incoming links maps.
  Future<NoteFetchResult> getNote({
    required String vaultPath,
    required String noteId,
    bool includeLinks = false,
  }) async {
    final args = <String>[
      'get',
      '--vault',
      vaultPath,
      '--note-id',
      noteId,
      if (includeLinks) '--include-links',
    ];
    final r = await run(args);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('get', r);
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    return NoteFetchResult(
      noteId: json['note_id'] as String,
      title: json['title'] as String,
      contentMd: json['content_md'] as String,
      version: (json['version'] as num).toInt(),
      tags: ((json['tags'] as List?) ?? const []).cast<String>(),
      links: json['links'] as Map<String, dynamic>?,
      backlinks: json['backlinks'] as Map<String, dynamic>?,
    );
  }
}

class MemexResult {
  MemexResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
  final int exitCode;
  final String stdout;
  final String stderr;
}

class NoteUpdateResult {
  NoteUpdateResult({
    required this.noteId,
    required this.version,
    required this.updatedAt,
  });
  final String noteId;
  final int version;
  final int updatedAt;
}

class AddLinkResult {
  AddLinkResult({
    required this.linkId,
    required this.fromNoteId,
    required this.toNoteId,
    required this.kind,
    required this.source,
    required this.wasExisting,
    required this.noteVersion,
  });
  final String? linkId;
  final String fromNoteId;
  final String toNoteId;
  final String kind;
  final String source;
  final bool wasExisting;
  final int noteVersion;
}

class NoteFetchResult {
  NoteFetchResult({
    required this.noteId,
    required this.title,
    required this.contentMd,
    required this.version,
    required this.tags,
    required this.links,
    required this.backlinks,
  });
  final String noteId;
  final String title;
  final String contentMd;
  final int version;
  final List<String> tags;
  final Map<String, dynamic>? links;
  final Map<String, dynamic>? backlinks;
}

enum MemexErrorKind { other, versionConflict }

/// The parsed `memex tag add` output, and `POST /notes/{note_id}/tags`'s
/// response (#242 T4b).
class TagAddResult {
  TagAddResult({
    required this.noteId,
    required this.tag,
    required this.origin,
    required this.changed,
    required this.version,
  });
  final String noteId;
  final String tag;
  final String origin;
  final bool changed;
  final int version;
}

/// The `memex tag add` object, or null for any other shape.
TagAddResult? parseTagAddResult(Map<String, Object?> json) {
  if (json case {
    'note_id': final String noteId,
    'tag': final String tag,
    'origin': final String origin,
    'changed': final bool changed,
    'version': final int version,
  }) {
    return TagAddResult(
      noteId: noteId,
      tag: tag,
      origin: origin,
      changed: changed,
      version: version,
    );
  }
  return null;
}

/// The parsed `memex tag rm` output, and `DELETE /notes/{note_id}/tags/{tag}`'s
/// response (#242 T4b).
class TagRmResult {
  TagRmResult({
    required this.noteId,
    required this.tag,
    required this.removed,
    required this.correctionId,
    required this.version,
  });
  final String noteId;
  final String tag;

  /// False when the tag was already gone: still a success, with a [version].
  final bool removed;

  /// The recorded `tag_corrections` row; null when nothing was recorded.
  final int? correctionId;
  final int version;
}

/// The `memex tag rm` object, or null for any other shape. Shared by the CLI
/// wrapper and the hosted `DELETE /notes/{note_id}/tags/{tag}` call.
TagRmResult? parseTagRmResult(Map<String, Object?> json) {
  if (json case {
    'note_id': final String noteId,
    'tag': final String tag,
    'removed': final bool removed,
    'version': final int version,
  }) {
    if (json['correction_id'] case final int? correctionId) {
      return TagRmResult(
        noteId: noteId,
        tag: tag,
        removed: removed,
        correctionId: correctionId,
        version: version,
      );
    }
  }
  return null;
}

/// [MemexCli.run] killed `memex <args>` after [timeout] passed (Spec #391
/// req 21). Its `toString` names the args and the timeout.
class MemexCliTimeout implements Exception {
  const MemexCliTimeout(this.args, this.timeout);

  final List<String> args;
  final Duration timeout;

  @override
  String toString() =>
      'MemexCliTimeout: memex ${args.join(' ')} still ran after $timeout';
}

class MemexException implements Exception {
  MemexException(
    this.message, {
    this.kind = MemexErrorKind.other,
    this.code,
    this.fields = const {},
  });

  /// Build the exception for a C1 error object (D17), the one C1 parser for
  /// CLI stderr and vault-server error bodies alike. [error] is the object
  /// under `"error"`: `{"code": <string>, "message": …, …fields}`. The
  /// message is `'<operation> failed: <message>'` (the code when there is no
  /// string message), [fields] are the object's keys other than `code` and
  /// `message`, and [kind] is [MemexErrorKind.versionConflict] exactly for
  /// `version_conflict`. Unknown codes give a plain exception with that code.
  factory MemexException.fromC1(String operation, Map<String, Object?> error) {
    final code = error['code'] as String;
    final message = error['message'];
    return MemexException(
      '$operation failed: ${message is String ? message : code}',
      kind: code == 'version_conflict'
          ? MemexErrorKind.versionConflict
          : MemexErrorKind.other,
      code: code,
      fields: Map.unmodifiable({
        for (final e in error.entries)
          if (e.key != 'code' && e.key != 'message') e.key: e.value,
      }),
    );
  }

  /// Build the exception for a failed `memex <operation>` call from its
  /// result: parses the C1 stderr line `{"error":{"code":…,"message":…,…}}`
  /// into [code] and [fields]; non-JSON stderr keeps the legacy message
  /// `'<operation> failed: <stderr>'` with a null [code].
  ///
  /// [kind] is [MemexErrorKind.versionConflict] for the C1 code
  /// `version_conflict`, and, for non-JSON stderr from an older `memex`, when
  /// stderr mentions `VersionConflict` or `version conflict`.
  factory MemexException.fromCliFailure(String operation, MemexResult result) {
    final stderr = result.stderr;
    final error = _parseErrorLine(stderr);
    if (error == null) {
      final legacyConflict =
          stderr.contains('VersionConflict') ||
          stderr.contains('version conflict');
      return MemexException(
        '$operation failed: $stderr',
        kind: legacyConflict
            ? MemexErrorKind.versionConflict
            : MemexErrorKind.other,
      );
    }
    return MemexException.fromC1(operation, error);
  }

  /// The C1 error object from the last stderr line of the form
  /// `{"error":{"code":"<code>",…}}` (log lines may precede it), or null.
  static Map<String, Object?>? _parseErrorLine(String stderr) {
    for (final line in stderr.split('\n').reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final error = decoded['error'];
      if (error is Map<String, Object?> && error['code'] is String) {
        return error;
      }
    }
    return null;
  }

  final String message;
  final MemexErrorKind kind;

  /// The C1 error code (`version_conflict`, `daily_note_exists`, …), or null
  /// when stderr was not a JSON error line.
  final String? code;

  /// The fields of the C1 error object (rule fields such as `existing_id`).
  final Map<String, Object?> fields;
  @override
  String toString() => message;
}

class UpdateLinkResult {
  UpdateLinkResult({
    required this.linkId,
    required this.fromNoteId,
    required this.toNoteId,
    required this.kind,
    required this.label,
    required this.source,
    required this.position,
  });
  final String linkId;
  final String fromNoteId;
  final String? toNoteId;
  final String kind;
  final String? label;
  final String source;
  final int position;
}

class CanvasInfo {
  CanvasInfo({
    required this.canvasId,
    required this.title,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });
  final String canvasId;
  final String title;
  final int version;
  final int createdAt;
  final int updatedAt;

  static CanvasInfo _fromJson(Map<String, dynamic> j) => CanvasInfo(
    canvasId: j['canvas_id'] as String,
    title: j['title'] as String,
    version: (j['version'] as num).toInt(),
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
  );
}

class CanvasSummary {
  CanvasSummary({
    required this.canvasId,
    required this.title,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.nodeCount,
  });
  final String canvasId;
  final String title;
  final int version;
  final int createdAt;
  final int updatedAt;
  final int nodeCount;

  static CanvasSummary _fromJson(Map<String, dynamic> j) => CanvasSummary(
    canvasId: j['canvas_id'] as String,
    title: j['title'] as String,
    version: (j['version'] as num).toInt(),
    createdAt: (j['created_at'] as num).toInt(),
    updatedAt: (j['updated_at'] as num).toInt(),
    nodeCount: (j['node_count'] as num).toInt(),
  );
}

class CanvasNodeInfo {
  CanvasNodeInfo({
    required this.canvasId,
    required this.noteId,
    required this.noteTitle,
    required this.x,
    required this.y,
    required this.zOrder,
    required this.placedAt,
  });
  final String canvasId;
  final String noteId;
  final String noteTitle;
  final double x;
  final double y;
  final int zOrder;
  final int placedAt;

  static CanvasNodeInfo _fromJson(Map<String, dynamic> j) => CanvasNodeInfo(
    canvasId: j['canvas_id'] as String,
    noteId: j['note_id'] as String,
    noteTitle: j['note_title'] as String,
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    zOrder: (j['z_order'] as num).toInt(),
    placedAt: (j['placed_at'] as num?)?.toInt() ?? 0,
  );
}

class CanvasEdgeInfo {
  CanvasEdgeInfo({
    required this.linkId,
    required this.fromNoteId,
    required this.toNoteId,
    required this.linkText,
    required this.kind,
    required this.label,
    required this.source,
    required this.position,
  });
  final String linkId;
  final String fromNoteId;
  final String toNoteId;
  final String linkText;
  final String kind;
  final String? label;
  final String source;
  final int position;

  static CanvasEdgeInfo _fromJson(Map<String, dynamic> j) => CanvasEdgeInfo(
    linkId: j['link_id'] as String,
    fromNoteId: j['from_note_id'] as String,
    toNoteId: j['to_note_id'] as String,
    linkText: j['link_text'] as String,
    kind: j['kind'] as String,
    label: j['label'] as String?,
    source: j['source'] as String,
    position: (j['position'] as num).toInt(),
  );
}

class CanvasDetail {
  CanvasDetail({
    required this.canvasId,
    required this.title,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.nodes,
    required this.edges,
  });
  final String canvasId;
  final String title;
  final int version;
  final int createdAt;
  final int updatedAt;
  final List<CanvasNodeInfo> nodes;
  final List<CanvasEdgeInfo> edges;

  static CanvasDetail _fromJson(Map<String, dynamic> j) => CanvasDetail(
    canvasId: j['canvas_id'] as String,
    title: j['title'] as String,
    version: (j['version'] as num).toInt(),
    createdAt: (j['created_at'] as num).toInt(),
    updatedAt: (j['updated_at'] as num).toInt(),
    nodes: ((j['nodes'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CanvasNodeInfo._fromJson)
        .toList(),
    edges: ((j['edges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CanvasEdgeInfo._fromJson)
        .toList(),
  );
}
