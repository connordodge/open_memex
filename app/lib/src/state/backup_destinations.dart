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
/// Drive by account, OneDrive by name, then "choose folder…" (provider null,
/// path null, label exactly `choose folder…`). A label is the bare
/// distinguishing text: `iCloud Drive`, the account (`connor@example.com`), the
/// name after `OneDrive-` (`Personal`); A4 composes `Google Drive · <label>`. A provider that isn't installed is not listed; with none
/// found, only "choose folder…" is. Each provider row's [path] is
/// `<provider folder>/Open Memex Backups`, not yet created.
Future<List<BackupDestinationOption>> discoverBackupDestinations(
  CloudFolderProbe probe,
) async => const [];

/// The C1 code of a destination that could not be made or resolved (the same
/// string `memex backup` fails with).
const backupDestinationUnavailableCode = 'backup_destination_unavailable';

/// What resolving a picked destination came to. Resolving saves nothing: the
/// caller saves through `saveVaultBackupSettingsProvider`.
sealed class BackupDestinationResolution {
  const BackupDestinationResolution();
}

/// The destination exists and is [path], symlinks resolved (the form
/// `backup-state.json` keys it by).
final class BackupDestinationResolved extends BackupDestinationResolution {
  const BackupDestinationResolved(this.path);

  final String path;
}

/// The destination could not be made or resolved. [code] is
/// [backupDestinationUnavailableCode]; [message] says why, for the user.
final class BackupDestinationUnavailable extends BackupDestinationResolution {
  const BackupDestinationUnavailable({
    this.code = backupDestinationUnavailableCode,
    required this.message,
  });

  final String code;
  final String message;
}

/// Turns a picked [BackupDestinationOption] into the destination to store.
/// Stub: A2 (#323) fills it.
class BackupDestinationResolver {
  const BackupDestinationResolver(this._probe);

  // ignore: unused_field
  final CloudFolderProbe _probe;

  /// A provider row creates `option.path` (the provider folder plus
  /// `Open Memex Backups`) through the probe only when missing, then answers its
  /// symlink-resolved path. The "Choose folder" row (provider null) answers the
  /// symlink-resolved [pickedFolder], nothing appended. A
  /// `FileSystemException` from creating or resolving answers
  /// [BackupDestinationUnavailable]. It never saves: A4 saves on "turn on
  /// backups" or a destination-menu pick, so cancelling saves nothing.
  Future<BackupDestinationResolution> resolve(
    BackupDestinationOption option, {
    String? pickedFolder,
  }) async => const BackupDestinationResolved('');
}

final resolveBackupDestinationProvider = Provider<BackupDestinationResolver>(
  (ref) => BackupDestinationResolver(ref.watch(cloudFolderProbeProvider)),
);
