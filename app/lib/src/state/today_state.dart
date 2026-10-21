import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import '../vault_access/notes_access.dart';
import '../vault_access/vault_scoped.dart';
import 'editor_controller.dart' show editorControllerProvider;
import 'pending_saves.dart';
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

/// Create the daily note for [date] (ISO) through [notes]' `addNote` with
/// role `daily`, the date as title and [contentMd] as the body (on a local
/// vault `memex add --role daily --title DATE`, #18). The first-edit helper
/// of the virtual Today tab (#22), shared with #26.
///
/// `Created note` and `Adopted note` (Q2) both return the printed note id
/// with `existed: false`. A `daily_note_exists` failure returns its
/// `existing_id` with `existed: true`. Any other failure throws the
/// [MemexException].
Future<DailyCreateResult> createDailyNote(
  NotesAccess notes, {
  required String date,
  String contentMd = '',
}) async {
  try {
    final id = await notes.addNote(
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

/// The editor's note read: [virtualTodayNote] for a virtual Today tab (no
/// vault read), else [selectedNoteAsyncProvider]'s note.
final _editorNoteReadProvider = FutureProvider<VaultScoped<Note?>>((ref) {
  final date = VirtualTodayTab.dateOf(ref.watch(selectedNoteIdProvider));
  if (date != null) {
    return VaultScoped(ref.watch(currentVaultProvider), virtualTodayNote(date));
  }
  return ref.watch(selectedNoteAsyncProvider.future);
});

/// The note queued save [queued] stands for while the note can't be read:
/// its id, title and queued text on its base version.
Note _queuedNote(QueuedSave queued) => Note(
  id: queued.save.noteId,
  title: queued.save.title,
  contentMd: queued.save.text,
  frontmatter: '{}',
  version: queued.save.baseVersion ?? 0,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// The editor's note, async (D14a), keyed by the selected note id:
/// [virtualTodayNote] for a virtual Today tab (no vault read), else
/// [selectedNoteAsyncProvider]'s note, with the vault it was loaded for.
///
/// While a newly selected note's read is in flight, or after it failed, it
/// never carries the previously selected note as its value (#102: offline,
/// the editor would show that note under the new tab and save it with the
/// text typed there). The previous value stays only on a reload of the same
/// note, or when the editor already holds the selected note (a virtual
/// Today note that just became it). On a hosted vault a failed read of a
/// newly selected note with a queued save yields the queued note
/// ([_queuedNote]) instead of the error.
final editorNoteAsyncProvider = Provider<AsyncValue<VaultScoped<Note?>>>((ref) {
  final read = ref.watch(_editorNoteReadProvider);
  final id = ref.watch(selectedNoteIdProvider);
  final shown = read.valueOrNull?.value;
  if (read is AsyncData || (shown != null && shown.id == id)) return read;
  if (read.hasError) {
    final vault = ref.read(currentVaultProvider);
    final queued = vault is HostedVaultRef && id != null
        ? ref.read(pendingSaveQueueProvider.notifier).entryFor(vault, id)
        : null;
    if (queued != null) {
      return AsyncData(VaultScoped(vault, _queuedNote(queued)));
    }
  }
  if (shown == null ||
      ref.read(editorControllerProvider.notifier).activeNoteId == id) {
    return read;
  }
  return read.hasError
      ? AsyncError<VaultScoped<Note?>>(read.error!, read.stackTrace!)
      : const AsyncLoading<VaultScoped<Note?>>();
});
