// WI #325 (A4): the Backups sheet's own copy (design pack 325, every string
// lowercase as approved) and how a destination path reads in it. Failure
// messages, times and sizes come from `backup_messages.dart` (A1), never from
// here.
part of 'backups_sheet.dart';

const _docsPath = 'docs/backups.md';
const _hostedCommand =
    'memex serve --root <root> --listen <host:port> --backup-dir <dir>';

const _offTitle = 'backups are off';
const _offBody =
    'pick a folder in icloud drive, google drive or onedrive and that app '
    'uploads each backup. a nas share or an external disk works too.';
const _offLead =
    'a backup is one .memex.zip file of this vault — notes, block ids, review '
    "state, smart folders, canvases and attachments — made safely while it's "
    'open.';
const _turnOnEllipsis = 'turn on backups…';
const _turnOn = 'turn on backups';
const _turnOff = 'turn off backups';
const _cancel = 'cancel';
const _pickTitle = 'choose where backups go';
const _pickBody =
    'open memex writes each backup there as one finished file; the '
    "provider's own app uploads it.";
const _foundOnThisMac = 'found on this mac';
const _noProviderSub =
    'no icloud drive, google drive or onedrive folder on this mac. install '
    "the provider's app and sign in, then reopen this sheet — or choose any "
    'folder.';
const _pickNote =
    'a provider gets an Open Memex Backups folder. macOS may ask whether open '
    'memex can use it — choose allow.';
const _chooseFolder = 'choose folder…';
const _chooseFolderSub = 'a nas share, an external disk or any folder';
const _neverTitle = 'no backup yet';

/// A card title for a failed state whose view state carries no message (the
/// controller always sets one; this only keeps the card from being empty).
const _failedFallback = 'backup failed';
const _neverBody = 'the first automatic backup runs within the hour.';
const _backingUpTitle = 'backing up…';
const _backingUpBody =
    "keep writing — the backup reads a snapshot and doesn't block the vault.";
const _backUpNow = 'back up now';
const _retry = 'retry';
const _locateBinary = 'locate memex binary…';
const _req25 =
    "vaults that aren't open in open memex are backed up only by a memex "
    'backup you schedule — see docs/backups.md.';
const _oldFolderNote =
    "the old folder's backups stay where they are. turning backups off "
    'deletes none.';
const _settingsEyebrow = 'SETTINGS';
const _destinationLabel = 'destination';
const _keepLabel = 'keep';
const _keepSub = 'latest backups, 1–365';
const _automaticLabel = 'back up automatically';
const _automaticSub = "once a day when memex changed, while it's open here";
const _notConfiguredTitle = 'backups are set on the vault server';
const _hostedNote =
    'a nas tool such as synology cloud sync takes the backups on to the '
    'cloud. to restore a hosted vault, see docs/backups.md.';
const _fullGuide = 'full guide: ';

String _startedLine(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'started ${two(local.hour)}:${two(local.minute)}. ';
}

String _notConfiguredBody(String server, String vault) =>
    "$server wasn't started with a backup folder, so it doesn't back up "
    '$vault. add --backup-dir to memex serve on $server:';

String _unreachableBody(String server) =>
    'its backups show as soon as $server answers.';

String _tooOldTitle(String server) => "$server doesn't support backups yet";

String _tooOldBody(String server) =>
    'update memex on $server and restart memex serve, then reopen this sheet.';

/// A hosted vault whose status the controller hasn't read yet (no board;
/// lead ruling pending, see the PR's questions).
String _hostedCheckingTitle(String server) => 'checking backups on $server…';

String _hostedNeverBody(String server) =>
    '$server makes the first one within the hour.';

String _hostedBackingUpTitle(String server) => 'backing up on $server…';

String _hostedBackingUpBody(String server) =>
    'you can close this sheet; $server finishes it either way.';

/// "41.2 MB · " (nothing when the size is unknown).
String _sizePrefix(int? bytes) =>
    bytes == null ? '' : '${backupSize(bytes)} · ';

/// "today at 03:00 · 18.6 MB" (no size when it is unknown).
String _whenAndSize(DateTime at, int? bytes, DateTime now) => bytes == null
    ? backupWhen(at, now)
    : '${backupWhen(at, now)} · ${backupSize(bytes)}';

/// The last-good line under a failure. [server] is set for a hosted vault;
/// [retries] is false when nothing retries on its own (automatic off).
String _lastGoodLine(
  BackupStatus? status,
  DateTime now, {
  String? server,
  required bool retries,
}) {
  final at = status?.lastFileCreatedAt ?? status?.lastSuccessAt;
  final head = status != null && status.hasBackup && at != null
      ? 'last good backup: ${_whenAndSize(at, status.lastBytes, now)}.'
      : 'no good backup yet.';
  if (!retries) return head;
  return server == null
      ? '$head tries again hourly.'
      : '$head $server tries again hourly.';
}

/// How a destination folder reads in the sheet.
class _Where {
  const _Where({
    required this.provider,
    required this.relative,
    required this.label,
  });

  /// The provider whose folder holds it; null for a chosen folder.
  final BackupProvider? provider;

  /// Relative to the provider ("My Drive/Open Memex Backups"); a chosen
  /// folder's full path.
  final String relative;

  /// The destination menu's label ("Google Drive · connor@example.com"); a
  /// chosen folder's name.
  final String label;

  /// The provider in running text ("google drive"), or null.
  String? get providerWords => switch (provider) {
    BackupProvider.icloud => 'icloud drive',
    BackupProvider.googleDrive => 'google drive',
    BackupProvider.oneDrive => 'onedrive',
    null => null,
  };
}

// A provider's backup folder as discovery offers it and as A3's controller
// reads it for its failure copy (Spec req 20): `<provider folder>/Open Memex
// Backups`. Any other folder, one elsewhere in a provider's tree included,
// reads as a chosen folder, so the card and the failure copy agree.
final _icloudFolder = RegExp(
  r'/Library/Mobile Documents/com~apple~CloudDocs/(Open Memex Backups)$',
);
final _googleFolder = RegExp(
  r'/Library/CloudStorage/GoogleDrive-([^/]+)/(My Drive/Open Memex Backups)$',
);
final _oneDriveFolder = RegExp(
  r'/Library/CloudStorage/(OneDrive-([^/]+)/Open Memex Backups)$',
);

/// Reads [path] as a provider's backup folder (the macOS File Provider
/// locations discovery lists, ending in `Open Memex Backups`) or as a chosen
/// folder.
_Where _whereOf(String path) {
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final icloud = _icloudFolder.firstMatch(trimmed);
  if (icloud != null) {
    return _Where(
      provider: BackupProvider.icloud,
      relative: 'iCloud Drive/${icloud[1]}',
      label: 'iCloud Drive',
    );
  }
  final google = _googleFolder.firstMatch(trimmed);
  if (google != null) {
    return _Where(
      provider: BackupProvider.googleDrive,
      relative: google[2]!,
      label: 'Google Drive · ${google[1]}',
    );
  }
  final oneDrive = _oneDriveFolder.firstMatch(trimmed);
  if (oneDrive != null) {
    return _Where(
      provider: BackupProvider.oneDrive,
      relative: oneDrive[1]!,
      label: 'OneDrive · ${oneDrive[2]}',
    );
  }
  return _Where(provider: null, relative: path, label: p.basename(path));
}

/// The success card's size line: requirement 26's upload line for a
/// provider folder, the full path for a chosen folder. [compact] is B2-9's
/// card while the destination menu is open.
String _savedLine(int? bytes, String destination, {required bool compact}) {
  final where = _whereOf(destination);
  final words = where.providerWords;
  if (words == null) return '${_sizePrefix(bytes)}$destination';
  final folder = p.basename(destination);
  if (compact) return '${_sizePrefix(bytes)}$folder in $words';
  return '${_sizePrefix(bytes)}saved to $folder in $words. the $words app '
      "uploads it; open memex can't see when that's done.";
}
