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

enum MemexErrorKind { other, versionConflict }

class MemexException implements Exception {
  MemexException(this.message, {this.kind = MemexErrorKind.other});
  final String message;
  final MemexErrorKind kind;
  @override
  String toString() => message;
}
