// WI #321 (A0, D19, D20): the one message function for the req 22a and 35
// tables. The sheet, the entry's warning label and the Restore dialog all use
// it. The signature is frozen; the body is the stub A1 (#322) replaces.

/// The plain-language text for a backup or restore failure [code] (a C1 error
/// code such as `backup_destination_unavailable`, `backup_in_progress`,
/// `backup_failed`, `network_filesystem`, `restore_target_not_empty`,
/// `backup_invalid`, `backup_too_new`, or any other code).
///
/// [message] is the raw C1 message, for the codes whose text includes it.
/// [destination] names the folder for `backup_destination_unavailable`.
/// [serverName] names the vault server for a hosted vault (its
/// `backup_destination_unavailable` text differs). [fields] are the C1
/// object's extra keys (`backup_too_new` reads `schema_version` and
/// `supported_schema_version`).
String backupMessage(
  String code, {
  String? message,
  String? destination,
  String? serverName,
  Map<String, Object?> fields = const {},
}) => '';
