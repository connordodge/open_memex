// WI #321 (A0, D19, D20): the one source of the backup and restore copy (Spec
// req 22a and 35). The sheet, the entry's warning label and the Restore dialog
// all use it. The wording is the approved design's: `design/315-vault-backups/
// packs/325.md` ("Message table"), `326.md` ("Semantic label") and
// `327.md` ("Copy"), every string lowercase. The signatures are frozen; the
// bodies are the stubs A1 (#322) replaces.
import 'backup_models.dart';

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
}) => const BackupMessage(title: '', detail: '', short: '');

/// The card for exit 2 (this memex is too old to make backups).
BackupMessage backupTooOldMessage() =>
    const BackupMessage(title: '', detail: '', short: '');

/// The card for a memex binary that was not found.
BackupMessage backupBinaryNotFoundMessage() =>
    const BackupMessage(title: '', detail: '', short: '');

/// The Restore dialog's error text for a failed [result]
/// (`RestoreFailure`, `RestoreTooOld` or `RestoreBinaryNotFound`; a
/// `RestoreOk` has no error and gives the empty string). [name] is the
/// trimmed vault-name field and [parent] the parent folder as shown, for
/// `restore_target_not_empty`; `backup_too_new` reads `schema_version` and
/// `supported_schema_version` from `RestoreFailure.fields`.
String restoreFailureMessage(
  RestoreRunResult result, {
  required String name,
  required String parent,
}) => '';

/// "today at 14:03", "yesterday at 09:02" or "9 nov at 14:03": [at] against
/// [now], in the viewer's local time.
String backupWhen(DateTime at, DateTime now) => '';

/// A byte count with one decimal: "41.2 MB", "812 KB", "1.3 GB".
String backupSize(int bytes) => '';
