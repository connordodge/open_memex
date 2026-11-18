// The Outline's entries for the note the editor shows (Spec #58 R15, R31,
// R35, R41, TD3; WI #68).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/outline.dart';
import '../vault_access/vault_scoped.dart';

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

/// The Outline of the note in `editorNoteAsyncProvider`, from the live
/// `EditorController.contentMd` with that note's role. A null value means no
/// note is open. Loading while the editor's note is still loading.
/// AutoDispose: nothing is computed while nothing listens (R41).
final outlineProvider =
    Provider.autoDispose<AsyncValue<VaultScoped<NoteOutline?>>>(
      (ref) => const AsyncLoading(),
    );
