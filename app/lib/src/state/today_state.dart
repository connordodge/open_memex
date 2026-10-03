import '../memex_cli.dart';

/// What [createDailyNote] did.
class DailyCreateResult {
  const DailyCreateResult({required this.noteId, required this.existed});

  /// The daily note's id: the created (or adopted, Q2) note, or the
  /// `existing_id` of the daily note that already existed.
  final String noteId;

  /// True when `memex add` failed with `daily_note_exists` (C1): the note
  /// [noteId] already existed and the content was NOT written.
  final bool existed;
}

/// Create the daily note for [date] (ISO) through
/// `memex add --role daily --title <date>` with [contentMd] on stdin (#18 `addNote(role:)`). The
/// first-edit helper of the virtual Today tab (#22), shared with #26.
///
/// `Created note` and `Adopted note` (Q2) both return the printed note id
/// with `existed: false`. A `daily_note_exists` failure returns its
/// `existing_id` with `existed: true`. Any other failure throws the
/// [MemexException].
Future<DailyCreateResult> createDailyNote(
  MemexCli cli, {
  required String vaultPath,
  required String date,
  String contentMd = '',
}) {
  throw UnimplementedError();
}
