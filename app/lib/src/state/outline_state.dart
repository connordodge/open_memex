// The Outline's entries for the note the editor shows (Spec #58 R15, R31,
// R35, R41, TD3; WI #68).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../editor/outline.dart';
import '../vault_access/vault_scoped.dart';
import 'editor_controller.dart';
import 'today_state.dart';
import 'vault_state.dart';

/// The Outline of one note: its id, the live editor text the entries came
/// from, and the entries.
class NoteOutline {
  const NoteOutline({
    required this.noteId,
    required this.content,
    required this.entries,
  });

  /// The note the entries belong to.
  final String noteId;

  /// The editor text the entries were computed from.
  final String content;

  /// The entries, in document order.
  final List<OutlineEntry> entries;
}

/// The shape of [outlineEntries].
typedef OutlineEntriesFn =
    List<OutlineEntry> Function(String contentMd, {String? role});

/// The entry function the Outline runs: [outlineEntries]. A seam, so tests
/// can count how often entries are computed (R41).
final outlineEntriesFnProvider = Provider<OutlineEntriesFn>(
  (_) => outlineEntries,
);

/// The entries of one (text, role) pair, so an editor state change that
/// keeps the text computes nothing (R41). AutoDispose: a pair nothing
/// watches any more is dropped.
///
/// The one entries computation per text change (WI #131, Spec #122 Req 24):
/// the Outline panel ([outlineProvider]) and the editor's section tracker
/// both read their entries here, so a text both see is computed once.
final outlineEntriesOfProvider = Provider.autoDispose
    .family<List<OutlineEntry>, (String, String?)>((ref, key) {
      final (text, role) = key;
      return ref.watch(outlineEntriesFnProvider)(text, role: role);
    });

/// The Outline of the note in `editorNoteAsyncProvider`, from the live
/// `EditorController.contentMd` with that note's role. A null value means no
/// note is open. Loading while the editor's note is still loading, and while
/// the editor still holds another note's text (a note switch before the
/// editor loads the new note). When the editor already holds the selected
/// note but the note value is still the previous one (a virtual Today note
/// whose first edit just resolved it to the real daily note), the entries
/// come from the editor text with that previous value's role. AutoDispose:
/// nothing is computed while nothing listens (R41).
final outlineProvider =
    Provider.autoDispose<AsyncValue<VaultScoped<NoteOutline?>>>((ref) {
      final noteAsync = ref.watch(editorNoteAsyncProvider);
      // The whole state, not only its text: loading a note whose text equals
      // the previous text (an empty Today note over '') still changes the
      // note the entries belong to.
      final editor = ref.watch(editorControllerProvider);
      final scoped = noteAsync.valueOrNull;
      if (scoped == null) {
        return noteAsync.hasError
            ? AsyncError(noteAsync.error!, noteAsync.stackTrace!)
            : const AsyncLoading();
      }
      final Note? note = scoped.value;
      if (note == null) return AsyncData(VaultScoped(scoped.vault, null));
      final activeId = ref.read(editorControllerProvider.notifier).activeNoteId;
      // The editor already holds the selected note while the note value is
      // still the previous one: a virtual Today note that its first edit just
      // made the real daily note, whose read is in flight. Its text is the
      // selected note's, so the entries stay (same daily role) rather than
      // blanking to the loading state.
      if (activeId == null ||
          (activeId != note.id &&
              activeId != ref.watch(selectedNoteIdProvider))) {
        return const AsyncLoading();
      }
      final text = editor.contentMd;
      final entries = ref.watch(outlineEntriesOfProvider((text, note.role)));
      return AsyncData(
        VaultScoped(
          scoped.vault,
          NoteOutline(noteId: activeId, content: text, entries: entries),
        ),
      );
    });
