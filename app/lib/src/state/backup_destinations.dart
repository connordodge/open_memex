// WI #321 (A0, D19, D22): provider-folder discovery behind an injectable seam
// (Spec technical decision 9), so no test touches the real `~/Library`. The
// interface, provider and discovery signature are frozen; the bodies are the
// stubs A2 (#323) replaces.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

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

/// The real probe over `dart:io`.
class IoCloudFolderProbe implements CloudFolderProbe {
  /// [environment] defaults to the process environment; tests pass their own.
  const IoCloudFolderProbe({Map<String, String>? environment})
    : _environment = environment;

  final Map<String, String>? _environment;

  @override
  Future<String> home() async {
    final home = (_environment ?? Platform.environment)['HOME'];
    if (home == null || home.isEmpty) {
      throw const FileSystemException('The HOME folder is not set');
    }
    return home;
  }

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);

  @override
  Future<List<String>> listNames(String directory) async => [
    await for (final e in Directory(directory).list()) p.basename(e.path),
  ];

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<String> resolveSymbolicLinks(String path) =>
      File(path).resolveSymbolicLinks();
}

final cloudFolderProbeProvider = Provider<CloudFolderProbe>(
  (ref) => const IoCloudFolderProbe(),
);

/// The destination rows to list (req 20, D22), in order: iCloud Drive, Google
/// Drive by account, OneDrive by name, then "choose folder…" (provider null,
/// path null, label exactly `choose folder…`). A label is the bare
/// distinguishing text: `iCloud Drive`, the account (`connor@example.com`), the
/// name after `OneDrive-` (`Personal`; `OneDrive-SharedLibraries[-<org>]` is
/// skipped, it holds SharePoint libraries); A4 composes `Google Drive · <label>`. A provider that isn't installed is not listed; with none
/// found, only "choose folder…" is. Each provider row's [path] is
/// `<provider folder>/Open Memex Backups`, not yet created.
Future<List<BackupDestinationOption>> discoverBackupDestinations(
  CloudFolderProbe probe,
) async {
  const googlePrefix = 'GoogleDrive-';
  const oneDrivePrefix = 'OneDrive-';
  const sharedLibraries = 'OneDrive-SharedLibraries';
  final options = <BackupDestinationOption>[];

  final String home;
  try {
    home = await probe.home();
  } on FileSystemException {
    return [_chooseFolderOption];
  }
  final library = p.posix.join(home, 'Library');

  final icloud = p.posix.join(
    library,
    'Mobile Documents',
    'com~apple~CloudDocs',
  );
  if (await probe.isDirectory(icloud)) {
    options.add(_providerOption(BackupProvider.icloud, 'iCloud Drive', icloud));
  }

  final cloudStorage = p.posix.join(library, 'CloudStorage');
  List<String> names;
  try {
    names = await probe.listNames(cloudStorage);
  } on FileSystemException {
    // No CloudStorage folder: no Google Drive or OneDrive installed.
    names = const [];
  }

  final accounts = <String>[];
  final oneDriveNames = <String>[];
  for (final name in names) {
    if (name.startsWith(googlePrefix) && name.length > googlePrefix.length) {
      final folder = p.posix.join(cloudStorage, name, 'My Drive');
      if (await probe.isDirectory(folder)) {
        accounts.add(name.substring(googlePrefix.length));
      }
    } else if (name.startsWith(oneDrivePrefix) &&
        name.length > oneDrivePrefix.length) {
      // `OneDrive-SharedLibraries[-<org>]` holds SharePoint libraries, not a
      // OneDrive root.
      if (name == sharedLibraries || name.startsWith('$sharedLibraries-')) {
        continue;
      }
      if (await probe.isDirectory(p.posix.join(cloudStorage, name))) {
        oneDriveNames.add(name.substring(oneDrivePrefix.length));
      }
    }
  }
  accounts.sort();
  oneDriveNames.sort();

  for (final account in accounts) {
    options.add(
      _providerOption(
        BackupProvider.googleDrive,
        account,
        p.posix.join(cloudStorage, '$googlePrefix$account', 'My Drive'),
      ),
    );
  }
  for (final name in oneDriveNames) {
    options.add(
      _providerOption(
        BackupProvider.oneDrive,
        name,
        p.posix.join(cloudStorage, '$oneDrivePrefix$name'),
      ),
    );
  }
  options.add(_chooseFolderOption);
  return options;
}

const _backupFolderName = 'Open Memex Backups';

const _chooseFolderOption = BackupDestinationOption(label: 'choose folder…');

BackupDestinationOption _providerOption(
  BackupProvider provider,
  String label,
  String providerFolder,
) => BackupDestinationOption(
  provider: provider,
  label: label,
  path: p.posix.join(providerFolder, _backupFolderName),
);

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
class BackupDestinationResolver {
  const BackupDestinationResolver(this._probe);

  final CloudFolderProbe _probe;

  /// A provider row creates `option.path` (the provider folder plus
  /// `Open Memex Backups`) through the probe only when missing, then answers its
  /// symlink-resolved path; when the provider folder itself is gone it answers
  /// [BackupDestinationUnavailable] and creates nothing. The "Choose folder" row (provider null) answers the
  /// symlink-resolved [pickedFolder], nothing appended. A
  /// `FileSystemException` from creating or resolving answers
  /// [BackupDestinationUnavailable]. It never saves: A4 saves on "turn on
  /// backups" or a destination-menu pick, so cancelling saves nothing.
  Future<BackupDestinationResolution> resolve(
    BackupDestinationOption option, {
    String? pickedFolder,
  }) async {
    final String target;
    final bool create;
    if (option.provider == null) {
      target = pickedFolder ?? (throw ArgumentError.notNull('pickedFolder'));
      create = false;
    } else {
      target = option.path ?? (throw ArgumentError('option has no path'));
      create = !await _probe.isDirectory(target);
      // The provider folder must still be there: creating it would make an
      // ordinary local folder that no provider client syncs.
      if (create && !await _probe.isDirectory(p.posix.dirname(target))) {
        return BackupDestinationUnavailable(
          message:
              'Could not use the folder $target: '
              'its parent folder no longer exists',
        );
      }
    }
    try {
      if (create) await _probe.createDirectory(target);
      return BackupDestinationResolved(
        await _probe.resolveSymbolicLinks(target),
      );
    } on FileSystemException catch (e) {
      final reason = e.osError?.message ?? e.message;
      return BackupDestinationUnavailable(
        message: 'Could not use the folder $target: $reason',
      );
    }
  }
}

final resolveBackupDestinationProvider = Provider<BackupDestinationResolver>(
  (ref) => BackupDestinationResolver(ref.watch(cloudFolderProbeProvider)),
);
