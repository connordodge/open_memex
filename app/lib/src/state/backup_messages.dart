// WI #321 (A0, D19, D20): the one source of the backup and restore copy (Spec
// req 22a and 35). The sheet, the entry's warning label and the Restore dialog
// all use it. The wording is the approved design's: `design/315-vault-backups/
// packs/325.md` ("Message table"), `326.md` ("Semantic label") and
// `327.md` ("Copy"), every string lowercase. The signatures are frozen; the
// bodies are the stubs A1 (#322) replaces.
import 'backup_models.dart';
import 'vault_open_controller.dart'
    show memexTooOldMessage, networkDriveRefusalMessage;

/// One backup outcome as the sheet's card shows it.
class BackupMessage {
  const BackupMessage({
    required this.title,
    required this.detail,
    required this.short,
  });

  /// The card title, for example "the automatic backup failed at 09:00".
  final String title;

  /// The paragraph under the title.
  final String detail;

  /// The tail of the entry warning's semantic label, for example "can't
  /// write to google drive".
  final String short;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupMessage &&
          other.title == title &&
          other.detail == detail &&
          other.short == short;

  @override
  int get hashCode => Object.hash(title, detail, short);

  @override
  String toString() => 'BackupMessage($title, $detail, $short)';
}

/// The card for a failed backup, local or hosted (Message table).
///
/// [code] is the C1 error code (`backup_destination_unavailable`,
/// `backup_destination_inside_vault`, `backup_in_progress`, `backup_failed`,
/// `network_filesystem`, `internal`, or any other, which reads as
/// `backup_failed`); [message] is its raw message, for the codes whose text
/// includes it. [automatic] picks the title ("the automatic backup failed" or
/// "back up now failed"); [failedAt] and [now] give its `<failedAt>` (see
/// [backupWhen]). [destination] is the destination folder's full path and
/// [provider] its provider (null for a chosen folder): they build `<where>`
/// and `<provider>`. [serverName] is set for a hosted vault, which switches to
/// the hosted wording (`<server>'s backup failed ...`).
BackupMessage backupFailureMessage({
  required String code,
  String? message,
  required bool automatic,
  required DateTime failedAt,
  required DateTime now,
  String? destination,
  BackupProvider? provider,
  String? serverName,
}) {
  final when = _failedAtText(failedAt, now);
  final server = serverName;
  if (server != null) {
    final title = "$server's backup failed $when";
    if (code == 'backup_destination_unavailable') {
      return BackupMessage(
        title: title,
        detail:
            "$server can't write to its backup folder. check that the folder "
            'given to --backup-dir exists on $server and is writable.',
        short: "$server can't write to its backup folder",
      );
    }
    return BackupMessage(
      title: title,
      detail: _couldNot("$server couldn't make the backup", message),
      short: "$server couldn't make the backup",
    );
  }
  final title = automatic
      ? 'the automatic backup failed $when'
      : 'back up now failed $when';
  switch (code) {
    case 'backup_destination_unavailable':
      return BackupMessage(
        title: title,
        detail:
            "can't write to ${_where(destination, provider)}. check that it's "
            'still there and connected (a nas share mounted, the cloud app '
            'signed in), and that open memex may use it in system settings › '
            'privacy & security › files and folders.',
        short: "can't write to ${_providerName(destination, provider)}",
      );
    case 'backup_destination_inside_vault':
      return BackupMessage(
        title: title,
        detail:
            'the backup folder is inside the vault. choose a folder outside '
            'it.',
        short: 'the backup folder is inside the vault',
      );
    case 'backup_in_progress':
      return BackupMessage(
        title: title,
        detail: 'a backup of this vault is already running.',
        short: 'a backup is already running',
      );
    case 'network_filesystem':
      return BackupMessage(
        title: title,
        detail: networkDriveRefusalMessage,
        short: 'this folder is on a network drive',
      );
  }
  // `backup_failed`, `internal` and any other code.
  return BackupMessage(
    title: title,
    detail: _couldNot("the backup couldn't be made", message),
    short: "the backup couldn't be made",
  );
}

/// "sentence: message." or, with no message, "sentence.".
String _couldNot(String sentence, String? message) =>
    message == null || message.isEmpty ? '$sentence.' : '$sentence: $message.';

/// [backupWhen] without its leading "today ": the title reads "the automatic
/// backup failed at 09:00" for today.
String _failedAtText(DateTime failedAt, DateTime now) {
  const today = 'today ';
  final when = backupWhen(failedAt, now);
  return when.startsWith(today) ? when.substring(today.length) : when;
}

/// `<where>`: "Open Memex Backups in google drive" for a provider folder, the
/// full path for a chosen folder.
String _where(String? destination, BackupProvider? provider) {
  if (provider == null) return destination ?? 'the backup folder';
  return 'Open Memex Backups in ${switch (provider) {
    BackupProvider.icloud => 'icloud drive',
    BackupProvider.googleDrive => 'google drive',
    BackupProvider.oneDrive => 'onedrive',
  }}';
}

/// `<provider>`: the display name, or a chosen folder's own name.
String _providerName(String? destination, BackupProvider? provider) {
  if (provider != null) {
    return switch (provider) {
      BackupProvider.icloud => 'iCloud Drive',
      BackupProvider.googleDrive => 'Google Drive',
      BackupProvider.oneDrive => 'OneDrive',
    };
  }
  final segments = (destination ?? '')
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty);
  return segments.isEmpty ? 'the backup folder' : segments.last;
}

/// The card for exit 2 (this memex is too old to make backups).
BackupMessage backupTooOldMessage() => const BackupMessage(
  title: 'this memex is too old to make backups',
  detail: 'update memex, then try again.',
  short: 'this memex is too old to make backups',
);

/// The card for a memex binary that was not found.
BackupMessage backupBinaryNotFoundMessage() => const BackupMessage(
  title: 'memex binary not found',
  detail: 'install memex, or locate it, then try again.',
  short: 'memex binary not found',
);

/// The Restore dialog's error text for a failed [result]
/// (`RestoreFailure`, `RestoreTooOld` or `RestoreBinaryNotFound`; a
/// `RestoreOk` has no error and gives the empty string). [name] is the
/// trimmed vault-name field and [parent] the parent folder as shown, for
/// `restore_target_not_empty`; `backup_too_new` reads `schema_version` and
/// `supported_schema_version` from `RestoreFailure.fields` and shows them only
/// when both are ints; otherwise it drops the whole parenthetical.
String restoreFailureMessage(
  RestoreRunResult result, {
  required String name,
  required String parent,
}) {
  switch (result) {
    case RestoreOk():
      return '';
    case RestoreTooOld():
      return memexTooOldMessage;
    case RestoreBinaryNotFound():
      return 'memex binary not found. install memex, or locate it, then try '
          'again.';
    case RestoreFailure(:final code, :final message, :final fields):
      switch (code) {
        case 'restore_target_not_empty':
          return 'a folder named $name already exists in $parent and isn\'t '
              'empty. choose another name or folder.';
        case 'backup_invalid':
          return 'this file isn\'t an open memex backup, or it\'s damaged. '
              'nothing was written.';
        case 'backup_too_new':
          final found = fields['schema_version'];
          final supported = fields['supported_schema_version'];
          if (found is! int || supported is! int) {
            return 'this backup was made by a newer memex. update memex, then '
                'try again.';
          }
          return 'this backup was made by a newer memex (schema V$found; this '
              'memex supports V$supported). update memex, then try again.';
        case 'network_filesystem':
          return networkDriveRefusalMessage;
      }
      return _couldNot("the backup couldn't be restored", message);
  }
}

const _monthNames = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// "today at 14:03", "yesterday at 09:02" or "9 nov at 14:03": [at] against
/// [now], in the viewer's local time.
String backupWhen(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = now.toLocal();
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  // Calendar days, not 24-hour spans. `DateTime.utc(y, m, d - 1)` rolls over
  // months and years and is immune to daylight-saving shifts.
  final day = DateTime.utc(local.year, local.month, local.day);
  final todayDay = DateTime.utc(today.year, today.month, today.day);
  if (day == todayDay) return 'today at $clock';
  if (day == DateTime.utc(today.year, today.month, today.day - 1)) {
    return 'yesterday at $clock';
  }
  return '${local.day} ${_monthNames[local.month - 1]} at $clock';
}

/// A byte count in decimal units (1 KB = 1000 bytes, as Finder shows): one
/// decimal for MB and GB, none for KB: "41.2 MB", "812 KB", "1.3 GB".
String backupSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  final kb = (bytes / 1000).round();
  if (kb < 1000) return '$kb KB';
  final mb = bytes / 1000000;
  if (mb.toStringAsFixed(1) != '1000.0' && mb < 1000) {
    return '${mb.toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
}
