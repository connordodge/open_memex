// WI #321 (A0, D19, D22): provider-folder discovery behind an injectable seam
// (Spec technical decision 9), so no test touches the real `~/Library`. The
// interface, provider and discovery signature are frozen; the bodies are the
// stubs A2 (#323) replaces.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_models.dart';

/// The file system as discovery and destination creation see it. Every method
/// is async. Failures are `FileSystemException`s, as `dart:io` throws them,
/// so a fake reproduces the real failure modes.
abstract class CloudFolderProbe {
  /// The home folder (an absolute path).
  Future<String> home();

  /// True when [path] exists and is a folder (symlinks followed).
  Future<bool> isDirectory(String path);

  /// The entry names (files and folders, not paths) directly inside
  /// [directory]. Throws `FileSystemException` when [directory] is missing or
  /// is not a folder.
  Future<List<String>> listNames(String directory);

  /// Creates [path] and any missing parents. Succeeds when it already exists
  /// as a folder. Throws `FileSystemException` on a refusal (permission,
  /// read-only volume, a file in the way).
  Future<void> createDirectory(String path);

  /// [path] with symlinks resolved. Throws `FileSystemException` when it does
  /// not exist.
  Future<String> resolveSymbolicLinks(String path);
}

/// The real probe over `dart:io`. Stub: neutral values, no I/O.
class IoCloudFolderProbe implements CloudFolderProbe {
  const IoCloudFolderProbe();

  @override
  Future<String> home() async => '';

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<List<String>> listNames(String directory) async => const [];

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<String> resolveSymbolicLinks(String path) async => '';
}

final cloudFolderProbeProvider = Provider<CloudFolderProbe>(
  (ref) => const IoCloudFolderProbe(),
);

/// The destination rows to list (req 20, D22), in order: iCloud Drive, Google
/// Drive by account, OneDrive by name, then "Choose folder…" (provider null,
/// path null). A provider that isn't installed is not listed; with none
/// found, only "Choose folder…" is. Each provider row's [path] is
/// `<provider folder>/Open Memex Backups`, not yet created.
Future<List<BackupDestinationOption>> discoverBackupDestinations(
  CloudFolderProbe probe,
) async => const [];

/// The C1 code of a destination that could not be made or resolved (the same
/// string `memex backup` fails with).
const backupDestinationUnavailableCode = 'backup_destination_unavailable';

/// What picking a destination came to.
sealed class BackupDestinationResult {
  const BackupDestinationResult();
}

/// The destination was made (if needed), resolved and saved: [destination] is
/// the stored, symlink-resolved path.
final class BackupDestinationPicked extends BackupDestinationResult {
  const BackupDestinationPicked(this.destination);

  final String destination;
}

/// Nothing was saved. [code] is [backupDestinationUnavailableCode].
final class BackupDestinationFailed extends BackupDestinationResult {
  const BackupDestinationFailed(this.code);

  final String code;
}

/// Picks [option] as the destination of the local vault at `vaultPath`: a
/// provider row creates `option.path` through the probe when it is missing; the
/// "Choose folder…" row (provider null) takes `pickedFolder` as it is. Either
/// way the symlink-resolved path is saved as the vault's destination (the
/// other settings stay as they are). A failure to create or resolve saves
/// nothing and answers [BackupDestinationFailed]. Stub: A2 (#323) fills it.
final pickBackupDestinationProvider =
    Provider<
      Future<BackupDestinationResult> Function(
        String vaultPath,
        BackupDestinationOption option, {
        String? pickedFolder,
      })
    >(
      (ref) =>
          (vaultPath, option, {pickedFolder}) async =>
              const BackupDestinationPicked(''),
    );
