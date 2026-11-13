// Agent note edits: the app's gate, reads and writes (Spec #7, WI #13 A1;
// rulings D16 to D19). Frozen for A2 (#14, note menu + title icon) and A3
// (#15, Activity tab Restore); add, never change:
//
// - [agentEditsAvailableProvider] (`Provider<bool>`, D17): whether the open
//   vault supports Agent read-only and agent-edit Restore. Hosted: the
//   vault's `GET …/info` reports `schema_version >= 8`. Local:
//   `vaultV8ReadyProvider`. Re-evaluated on every `vaultRevisionProvider`
//   bump. False with no vault, while the reading loads and after it fails
//   (fail closed), and never latched: the next bump reads again.
// - [noteRevisionsProvider] (`FutureProvider.family`, by note id): the
//   note's agent-edit revisions, newest first, stamped with the vault they
//   were read for. Empty, with no route called, while
//   [agentEditsAvailableProvider] is false. Re-reads on every bump.
// - [noteEditsActionsProvider] ([NoteEditsActions], D18):
//   - `setAgentReadOnly(noteId, on)`: one `NotesAccess.setAgentReadOnly`
//     call; on success exactly one `vaultRevisionProvider` bump, on failure
//     none and the error rethrown (a `MemexException` with its code). No
//     optimistic state: the menu check and the title icon read the re-read
//     note (`editorNoteAsyncProvider`).
//   - `restoreNoteRevision(note:, revisionId:)`: `flushThenWrite` without
//     `holdSaves` (the edit waiting on the save debounce is stored first),
//     one `NotesAccess.restoreNoteRevision` call, then exactly one bump. A
//     failed flush throws `SaveFirstFailedException` and restores nothing.
//
// The D19 Keys live in `widgets/agent_edits_keys.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// See the file comment (D17).
final agentEditsAvailableProvider = Provider<bool>((ref) => false);

/// See the file comment.
final noteRevisionsProvider =
    FutureProvider.family<VaultScoped<List<NoteRevision>>, String>(
      (ref, noteId) async =>
          VaultScoped(ref.watch(currentVaultProvider), const <NoteRevision>[]),
    );

/// See the file comment (D18).
final noteEditsActionsProvider = Provider<NoteEditsActions>(
  NoteEditsActions.new,
);

/// The agent-edit writes (D18). See the file comment.
class NoteEditsActions {
  NoteEditsActions(this._ref);

  // ignore: unused_field
  final Ref _ref;

  /// Sets ([on]) or clears note [noteId]'s Agent read-only flag.
  Future<void> setAgentReadOnly(String noteId, bool on) async {}

  /// Restores agent-edit revision [revisionId] of [note].
  Future<void> restoreNoteRevision({
    required Note note,
    required String revisionId,
  }) async {}
}
