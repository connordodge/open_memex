import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/poll_reads.dart';
import 'clock.dart';
import 'editor_controller.dart';
import 'tabs_state.dart' show VirtualTodayTab;
import 'today_state.dart';
import 'vault_state.dart';

/// The poller's one read of a note's `updated_at` ([PollReads.noteUpdatedAt]
/// on the current vault). The `notePollerProvider` (TD8) reads through this
/// provider, never the database directly, so tests can count its reads.
final noteUpdatedAtReaderProvider = Provider<int? Function(String noteId)>((
  ref,
) {
  final db = ref.watch(vaultDbProvider);
  return (noteId) => db?.noteUpdatedAt(noteId);
});

/// How often the open daily note's `updated_at` is read (Req 61).
const notePollInterval = Duration(seconds: 2);

/// Polls one daily note's `updated_at` every [notePollInterval] on the
/// [clockProvider] (D14) while its tab is active (WI #28).
///
/// A changed `updated_at` asks the [EditorController] whether the stored note
/// is a foreign write ([EditorController.serverChanged], which also applies
/// it to a clean editor); only a foreign write bumps [vaultRevisionProvider],
/// so the footer chips, blocks and excerpt cards re-read. The app's own saves
/// are not foreign: their version is the editor's base version.
///
/// Each poll is one autocommit `SELECT`: no read transaction is held across
/// awaits (WAL), and nothing is locked (Req 62).
class NotePoller {
  NotePoller._(this._ref, this.noteId);

  final Ref _ref;

  /// The polled daily note.
  final String noteId;

  Timer? _timer;

  /// The `updated_at` the last poll saw; null before the first poll.
  int? _seen;

  void _start() {
    _timer = _ref.read(clockProvider).periodic(notePollInterval, (_) => poll());
  }

  void _stop() => _timer?.cancel();

  /// One poll: reads `updated_at` once and handles a change.
  void poll() {
    final updatedAt = _ref.read(noteUpdatedAtReaderProvider)(noteId);
    if (updatedAt == null || updatedAt == _seen) return;
    _seen = updatedAt;
    if (_ref.read(editorControllerProvider.notifier).serverChanged(noteId)) {
      _ref.read(vaultRevisionProvider.notifier).state++;
    }
  }
}

/// The id of the note the editor shows (the active tab's note) when it is a
/// stored daily note, not the virtual Today note; null otherwise.
final _shownDailyNoteIdProvider = Provider.autoDispose<String?>(
  (ref) => ref.watch(
    editorNoteProvider.select(
      (note) =>
          note != null &&
              note.role == 'daily' &&
              VirtualTodayTab.dateOf(note.id) == null
          ? note.id
          : null,
    ),
  ),
);

/// TD8: the [NotePoller] of the daily note the editor shows (the active
/// tab's note), or null when that is not a stored daily note. Closing or
/// leaving the tab disposes the poller (its timer stops); coming back starts
/// a new one. The note editor keeps it alive while it is shown.
final notePollerProvider = Provider.autoDispose<NotePoller?>((ref) {
  final noteId = ref.watch(_shownDailyNoteIdProvider);
  if (noteId == null) return null;
  final poller = NotePoller._(ref, noteId).._start();
  ref.onDispose(poller._stop);
  return poller;
});
