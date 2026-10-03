import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import 'tabs_state.dart';
import 'vault_state.dart';

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
}) async {
  try {
    final id = await cli.addNote(
      vaultPath: vaultPath,
      title: date,
      contentMd: contentMd,
      role: 'daily',
    );
    return DailyCreateResult(noteId: id, existed: false);
  } on MemexException catch (e) {
    final existing = e.fields['existing_id'];
    if (e.code == 'daily_note_exists' && existing is String) {
      return DailyCreateResult(noteId: existing, existed: true);
    }
    rethrow;
  }
}

/// The note the virtual Today tab for [date] stands for: an empty, unsaved
/// `role: daily` note titled [date], with the tab's id. Never in the vault.
Note virtualTodayNote(String date) => Note(
  id: VirtualTodayTab(date).id,
  title: date,
  contentMd: '',
  frontmatter: '{"role":"daily"}',
  version: 0,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// The note the editor shows: [virtualTodayNote] when the selection is a
/// virtual Today tab, otherwise [selectedNoteProvider]'s note.
final editorNoteProvider = Provider<Note?>((ref) {
  final date = VirtualTodayTab.dateOf(ref.watch(selectedNoteIdProvider));
  if (date != null) return virtualTodayNote(date);
  return ref.watch(selectedNoteProvider);
});
