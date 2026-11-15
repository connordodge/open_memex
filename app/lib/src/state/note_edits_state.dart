// Agent note edits: the app's gate, reads and writes (Spec #7, WI #13 A1;
// rulings D16 to D19). Frozen for A2 (#14, note menu + title icon) and A3
// (#15, Activity tab Restore); add, never change:
//
// - [agentEditsAvailableProvider] (`Provider<bool>`, D17): whether the open
//   vault supports Agent read-only and agent-edit Restore. Hosted: the
//   vault's `GET …/info` reports `schema_version >= 8`. Local:
//   `vaultV8ReadyProvider`. Re-evaluated on every `vaultRevisionProvider`
//   bump. False with no vault, while the first reading loads and after a
//   reading fails (fail closed), and never latched: the next bump reads
//   again. A reload after a bump keeps the previous good reading of the
//   same vault; a reading of the previous vault never stands after a switch.
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
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import '../vault_access/vault_scoped.dart';
import 'clock.dart';
import 'topic_actions.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The first vault schema with Agent read-only and `note_revisions` (W0).
const _agentEditsSchemaVersion = 8;

/// The hosted vault's `GET …/info` `schema_version`, read once per
/// `vaultRevisionProvider` bump through `vaultAccessProvider`, stamped with
/// the vault it was read for. Null with no vault access.
///
/// A failed reading is read again on [clockProvider] after [_retryDelay]
/// (2 s, doubling to at most 30 s, reset by a good reading or a vault
/// switch), so one failure does not keep the gate shut on an idle vault
/// (D17: never latched). A bump or a rebuild cancels the pending retry.
final _hostedSchemaVersionProvider =
    AsyncNotifierProvider<_HostedSchemaVersion, VaultScoped<int?>>(
      _HostedSchemaVersion.new,
    );

const _firstRetryDelay = Duration(seconds: 2);
const _maxRetryDelay = Duration(seconds: 30);

/// The wait before retry number [failures] (1-based) of a failed reading.
Duration _retryDelay(int failures) {
  var delay = _firstRetryDelay;
  for (var i = 1; i < failures && delay < _maxRetryDelay; i++) {
    delay *= 2;
  }
  return delay < _maxRetryDelay ? delay : _maxRetryDelay;
}

class _HostedSchemaVersion extends AsyncNotifier<VaultScoped<int?>> {
  /// Failed readings in a row of [_failedVault].
  int _failures = 0;
  VaultRef? _failedVault;

  /// Counts builds, so a reading superseded by a rebuild schedules nothing.
  int _build = 0;
  Timer? _retry;

  @override
  Future<VaultScoped<int?>> build() async {
    final build = ++_build;
    ref.onDispose(() {
      _retry?.cancel();
      _retry = null;
    });
    ref.watch(vaultRevisionProvider);
    final vault = ref.watch(currentVaultProvider);
    final access = ref.watch(vaultAccessProvider);
    if (vault != _failedVault) _failures = 0;
    if (access == null) return VaultScoped(vault, null);
    try {
      final version = await access.schemaVersion();
      if (build == _build) _failures = 0;
      return VaultScoped(vault, version);
    } catch (_) {
      if (build == _build) {
        _failedVault = vault;
        _failures++;
        _retry = ref
            .read(clockProvider)
            .after(_retryDelay(_failures), ref.invalidateSelf);
      }
      rethrow;
    }
  }
}

/// See the file comment (D17). While a reading after a bump loads, the
/// previous good reading of the same vault stands (so the controls do not
/// blink on every save); the first reading, any failed one and a reading
/// left over from the previous vault after a switch read false.
final agentEditsAvailableProvider = Provider<bool>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault == null) return false;
  if (vault is! HostedVaultRef) return ref.watch(vaultV8ReadyProvider);
  final reading = ref.watch(_hostedSchemaVersionProvider);
  if (reading.hasError) return false;
  final version = currentVaultData(reading, vault)?.value;
  return version != null && version >= _agentEditsSchemaVersion;
});

/// See the file comment.
final noteRevisionsProvider =
    FutureProvider.family<VaultScoped<List<NoteRevision>>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      // Req 36: an older server never sees the revisions route.
      if (access == null || !ref.watch(agentEditsAvailableProvider)) {
        return VaultScoped(vault, const <NoteRevision>[]);
      }
      return VaultScoped(vault, await access.notes.noteRevisions(noteId));
    });

/// See the file comment (D18).
final noteEditsActionsProvider = Provider<NoteEditsActions>(
  NoteEditsActions.new,
);

/// The agent-edit writes (D18). See the file comment.
class NoteEditsActions {
  NoteEditsActions(this._ref);

  final Ref _ref;

  void _bump() => _ref.read(vaultRevisionProvider.notifier).state++;

  /// Sets ([on]) or clears note [noteId]'s Agent read-only flag: one
  /// `NotesAccess.setAgentReadOnly` call, then one bump. A failure (a
  /// [StateError] with no vault open or no CLI) bumps nothing and is
  /// rethrown.
  Future<void> setAgentReadOnly(String noteId, bool on) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) throw StateError('No vault is open.');
    await access.notes.setAgentReadOnly(noteId, on);
    _bump();
  }

  /// Restores agent-edit revision [revisionId] of [note] through
  /// [flushThenWrite] (no `holdSaves`), then bumps once when the restore call
  /// succeeded. A failed flush throws [SaveFirstFailedException] and makes no
  /// restore call. A restore that reports another note throws a
  /// [MemexException] (null code) and never rebases the editor on it.
  Future<void> restoreNoteRevision({
    required Note note,
    required String revisionId,
  }) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) throw StateError('No vault is open.');
    var restored = false;
    try {
      await flushThenWrite(
        _ref.container,
        note: note,
        write: () async {
          final result = await access.notes.restoreNoteRevision(
            noteId: note.id,
            revisionId: revisionId,
          );
          restored = true;
          // The version of another note is never this note's new base.
          if (result.noteId != note.id) {
            throw MemexException(
              'revisions restore failed: revision $revisionId restored note '
              '${result.noteId}, not ${note.id}',
            );
          }
          return result.version;
        },
      );
    } finally {
      // The restore is stored even when the read-back or rebase after it
      // fails: its watchers still need the one bump.
      if (restored) _bump();
    }
  }
}
