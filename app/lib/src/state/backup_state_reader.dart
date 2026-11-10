// WI #321 (A0, D19): reads `<vault>/backup-state.json` (req 10a). The
// interface and provider are frozen; `FileBackupStateReader` is the stub A1
// (#322) replaces.
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  }) async => null;
}

final backupStateReaderProvider = Provider<BackupStateReader>(
  (ref) => const FileBackupStateReader(),
);
