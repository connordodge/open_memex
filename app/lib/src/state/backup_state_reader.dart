// WI #321 (A0, D19): reads `<vault>/backup-state.json` (req 10a). The
// interface and provider are frozen; WI #322 (A1) filled `FileBackupStateReader`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'backup_models.dart';

/// Reads a local vault's backup history directly from its state file (the app
/// reads vault files, and writes only through `memex`).
abstract class BackupStateReader {
  /// The entry for [destination] in `<vaultPath>/backup-state.json`, found by
  /// exact string match on the resolved destination path. Null when the file
  /// is missing, unreadable or malformed (`format` other than 1), or has no
  /// entry for [destination]. Never throws.
  Future<BackupStatus?> read({
    required String vaultPath,
    required String destination,
  });
}

/// The real reader over the file system.
class FileBackupStateReader implements BackupStateReader {
  const FileBackupStateReader();

  @override
  Future<BackupStatus?> read({
    required String vaultPath,
    required String destination,
  }) async {
    try {
      final text = utf8.decode(
        await File(p.join(vaultPath, _stateFileName)).readAsBytes(),
      );
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final format = json['format'];
      if (format is! int || format != 1) return null;
      final destinations = json['destinations'];
      if (destinations is! Map<String, Object?>) return null;
      final entry = destinations[destination];
      if (entry is! Map<String, Object?>) return null;
      return BackupStatus.fromStateJson(entry);
    } on Object {
      // Missing, unreadable, a folder, not UTF-8, malformed, a wrong-typed
      // entry: all read as no history. The reader never throws (req 10a).
      return null;
    }
  }
}

/// The state file's name inside a vault folder.
const _stateFileName = 'backup-state.json';

final backupStateReaderProvider = Provider<BackupStateReader>(
  (ref) => const FileBackupStateReader(),
);
