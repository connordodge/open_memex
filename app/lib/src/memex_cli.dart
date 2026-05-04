import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thin wrapper around the `memex` CLI binary.
class MemexCli {
  MemexCli({required this.binaryPath});

  final String binaryPath;

  /// Find a `memex` binary in well-known places. Returns the first that exists.
  static String? autodiscover() {
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      if (home != null) p.join(home, '.cargo', 'bin', 'memex'),
      '/usr/local/bin/memex',
      '/opt/homebrew/bin/memex',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<MemexResult> _run(List<String> args, {String? stdinBody}) async {
    final proc = await Process.start(binaryPath, args, runInShell: false);
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

  Future<void> initVault(String vaultPath) async {
    final r = await _run(['init', vaultPath]);
    if (r.exitCode != 0) {
      throw MemexException('init failed: ${r.stderr}');
    }
  }

  Future<String> addNote({
    required String vaultPath,
    String? title,
    List<String> tags = const [],
    required String contentMd,
    bool withEmbeddings = false,
  }) async {
    final args = <String>[
      'add',
      '--vault',
      vaultPath,
      if (title != null && title.isNotEmpty) ...['--title', title],
      if (tags.isNotEmpty) ...['--tags', tags.join(',')],
      if (withEmbeddings) '--with-embeddings',
    ];
    final r = await _run(args, stdinBody: contentMd);
    if (r.exitCode != 0) {
      throw MemexException('add failed: ${r.stderr}');
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
    final r = await _run(args, stdinBody: contentMd);
    if (r.exitCode != 0) {
      final isVersionConflict =
          r.stderr.contains('VersionConflict') ||
          r.stderr.contains('version conflict');
      throw MemexException(
        'update failed: ${r.stderr}',
        kind: isVersionConflict
            ? MemexErrorKind.versionConflict
            : MemexErrorKind.other,
      );
    }
    final json = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
    return NoteUpdateResult(
      noteId: json['note_id'] as String,
      version: (json['version'] as num).toInt(),
      updatedAt: (json['updated_at'] as num).toInt(),
    );
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
    final r = await _run(args);
    if (r.exitCode != 0) {
      throw MemexException('add-link failed: ${r.stderr}');
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
    final r = await _run(args);
    if (r.exitCode != 0) {
      throw MemexException('get failed: ${r.stderr}');
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

class MemexException implements Exception {
  MemexException(this.message, {this.kind = MemexErrorKind.other});
  final String message;
  final MemexErrorKind kind;
  @override
  String toString() => message;
}
