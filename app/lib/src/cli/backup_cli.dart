// WI #321 (A0, D19, D20): the `memex backup` / `memex restore` runner seam.
// The interface and the provider are frozen; WI #322 (A1) filled
// `CliBackupRunner` and the provider's wiring.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../memex_cli.dart';
import '../state/backup_models.dart';
import '../state/vault_state.dart';

/// Runs `memex backup` and `memex restore` and classifies the outcome. Fakes
/// implement it (`FakeBackupRunner`). Methods take named, required
/// parameters and no defaults, so a fake sees every argument.
abstract class BackupRunner {
  /// `memex backup --vault <vaultPath> --dest <destination> --keep <keep>`,
  /// plus `--if-changed` when [ifChanged]. Never throws for a CLI failure or
  /// a spawn failure: those are results.
  Future<BackupRunResult> backup({
    required String vaultPath,
    required String destination,
    required int keep,
    required bool ifChanged,
  });

  /// `memex restore --from <from> --to <to>`. Never throws for a CLI failure
  /// or a spawn failure.
  Future<RestoreRunResult> restore({required String from, required String to});
}

/// [BackupRunner] over [MemexCli]: always passes `--keep`; exit 2 is "too
/// old" whatever stderr says; a `ProcessException` is "binary not found"; any
/// other failure is the C1 code and raw C1 message. A null [cli] (no `memex`
/// configured) answers binary not found. Arguments are a list, never a shell.
class CliBackupRunner implements BackupRunner {
  const CliBackupRunner(this.cli);

  final MemexCli? cli;

  @override
  Future<BackupRunResult> backup({
    required String vaultPath,
    required String destination,
    required int keep,
    required bool ifChanged,
  }) async {
    final cli = this.cli;
    if (cli == null) return const BackupBinaryNotFound();
    final MemexResult r;
    try {
      r = await cli.run([
        'backup',
        '--vault',
        vaultPath,
        '--dest',
        destination,
        '--keep',
        '$keep',
        if (ifChanged) '--if-changed',
      ]);
    } on ProcessException {
      return const BackupBinaryNotFound();
    }
    if (r.exitCode == 2) return const BackupTooOld();
    if (r.exitCode == 0) {
      return _parseBackupOutput(r.stdout) ??
          const BackupFailure(
            code: 'internal',
            message: 'memex backup printed output the app cannot read',
          );
    }
    final failure = _failure('backup', r);
    return BackupFailure(code: failure.code, message: failure.message);
  }

  @override
  Future<RestoreRunResult> restore({
    required String from,
    required String to,
  }) async {
    final cli = this.cli;
    if (cli == null) return const RestoreBinaryNotFound();
    final MemexResult r;
    try {
      r = await cli.run(['restore', '--from', from, '--to', to]);
    } on ProcessException {
      return const RestoreBinaryNotFound();
    }
    if (r.exitCode == 2) return const RestoreTooOld();
    if (r.exitCode == 0) {
      return _parseRestoreOutput(r.stdout) ??
          const RestoreFailure(
            code: 'internal',
            message: 'memex restore printed output the app cannot read',
          );
    }
    final failure = _failure('restore', r);
    return RestoreFailure(
      code: failure.code,
      message: failure.message,
      fields: failure.fields,
    );
  }
}

/// A failed run read once: the C1 [code] and raw [message] (without the
/// `<operation> failed: ` prefix `MemexException` adds), or `internal` and
/// the stderr text when stderr is not a C1 line.
({String code, String message, Map<String, Object?> fields}) _failure(
  String operation,
  MemexResult r,
) {
  final error = MemexException.fromCliFailure(operation, r);
  final prefix = '$operation failed: ';
  final message = error.message.startsWith(prefix)
      ? error.message.substring(prefix.length)
      : error.message;
  return (
    code: error.code ?? 'internal',
    message: message,
    fields: error.fields,
  );
}

Map<String, Object?>? _decodeObject(String stdout) {
  try {
    final decoded = jsonDecode(stdout.trim());
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

BackupRunResult? _parseBackupOutput(String stdout) {
  final json = _decodeObject(stdout);
  if (json == null) return null;
  switch (json) {
    case {
      'result': 'created',
      'file': final String file,
      'bytes': final int bytes,
      'fingerprint': final String fingerprint,
    }:
      final removed = json['removed'];
      if (removed != null && (removed is! List || !removed.every(_isString))) {
        return null;
      }
      return BackupCreated(
        file: file,
        bytes: bytes,
        fingerprint: fingerprint,
        removed: removed == null ? const [] : (removed as List).cast<String>(),
      );
    case {'result': 'unchanged'}:
      final lastFile = json['last_file'];
      if (lastFile != null && lastFile is! String) return null;
      return BackupUnchanged(lastFile: lastFile as String?);
  }
  return null;
}

bool _isString(Object? v) => v is String;

RestoreRunResult? _parseRestoreOutput(String stdout) {
  final json = _decodeObject(stdout);
  if (json == null) return null;
  if (json case {
    'vault_id': final String vaultId,
    'path': final String path,
    'created_at': final int createdAt,
  }) {
    const maxMs = 8640000000000000;
    if (createdAt < -maxMs || createdAt > maxMs) return null;
    return RestoreOk(
      vaultId: vaultId,
      path: path,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
    );
  }
  return null;
}

/// The runner over the configured `memex` (`memexCliProvider`).
final backupRunnerProvider = Provider<BackupRunner>(
  (ref) => CliBackupRunner(ref.watch(memexCliProvider)),
);
