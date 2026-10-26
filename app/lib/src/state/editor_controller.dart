import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../editor/conflict_merge.dart';
import '../editor/segments.dart';
import '../memex_cli.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_access.dart';
import 'clock.dart';
import 'hosted_connection_state.dart';
import 'pending_saves.dart';
import 'tabs_state.dart' show VirtualTodayTab, tabsProvider;
import 'today_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

// The editor's state types are declared in vault_state.dart (owned by #18)
// and re-exported here so this file is the editor state's single import.
export 'vault_state.dart' show EditorStateValue, SaveStatus;

/// The unsaved text of a virtual Today note (#22), kept per date across tab
/// switches until its first-edit `memex add` resolves.
class _VirtualDraft {
  String text = '';

  /// The text sent with the in-flight `memex add`; null when none is.
  String? sent;

  /// The CLI message of the last failed `memex add` or read-back.
  String? error;

  /// The daily note an earlier `memex add` created (and [createdText], the
  /// text it was created with) when reading it back failed; null otherwise.
  String? createdId;
  String? createdText;

  /// On a hosted vault: the texts of earlier `add`s that timed out after
  /// they were sent, so the server may have created the note with one of
  /// them (L17).
  final List<String> maybeCreated = [];
}

/// A plain save of a hosted note held back while an earlier save of the
/// note typed in the same editor load is in flight (see
/// `EditorController._deferredSaves`): its text and title, the editor load
/// it was typed in, and its base version.
class _DeferredSave {
  _DeferredSave({
    required this.access,
    required this.loadSeq,
    required this.text,
    required this.rawTitle,
    required this.title,
    required this.baseVersion,
  });

  final VaultAccess access;
  final int loadSeq;
  final String text;
  final String rawTitle;
  final String? title;

  /// Moves onto the version the earlier save stored when it landed on this
  /// base without a merge.
  int baseVersion;
}

/// The save debounce: a save runs this long after the last edit (D14: on
/// [clockProvider]).
const saveDebounce = Duration(milliseconds: 500);

/// The inline error after a save and its merged retry both hit a
/// `version_conflict` (Req 60); the next debounce tick merges again.
const couldNotSaveMessage = "Couldn't save";

/// Editor controller — owns the debounced save state for the open note.
/// Every read and write goes through `vaultAccessProvider` (D13); a read
/// that lands after the editor switched notes is never applied.
///
/// A daily note's save that hits a `version_conflict` refetches the note,
/// rebuilds the body with [mergeConflict] (the local person text, the
/// agent / quick-entry blocks the editor has not seen, the server's footer)
/// and retries once with the refetched version. When the retry conflicts
/// too, the local text stays, the error reads [couldNotSaveMessage] and the
/// next debounce tick (re-armed here) merges and saves again.
///
/// For the virtual Today note (a [VirtualTodayTab], #22) the first edit
/// creates the daily note through [createDailyNote] instead of saving:
/// exactly one `add` at a time, and keystrokes typed while it is in flight
/// are saved to the note it yields.
///
/// On a hosted vault (#102, L16) a save or virtual Today create that can't
/// reach the vault server (`VaultUnreachableException`, or a `401`) keeps
/// its text in [pendingSaveQueueProvider] instead of showing an error.
/// Further edits replace the queued text and send nothing until the
/// server's connection status returns to connected; then every queued note
/// of the open vault retries once. A retry whose `version_conflict` shows
/// the queued text on the server counts as saved (L17 self-heal); a daily
/// note merges as above. Opening a queued note fills the editor from the
/// queue. Local vaults are unchanged.
class EditorController extends StateNotifier<EditorStateValue> {
  EditorController(this._ref)
    : super(
        const EditorStateValue(
          title: '',
          contentMd: '',
          status: SaveStatus.idle,
        ),
      ) {
    _ref.listen<VaultRef?>(
      currentVaultProvider,
      (_, vault) => _watchServer(vault),
      fireImmediately: true,
    );
  }

  final Ref _ref;
  Timer? _debounce;
  String? _activeNoteId;

  /// The id of the note the editor currently holds, or null when none.
  String? get activeNoteId => _activeNoteId;

  /// Bumped by every [loadNote]: a save that lands after the editor
  /// switched notes (and maybe back) can tell.
  int _loadSeq = 0;

  /// The open hosted vault's connection status subscription.
  ProviderSubscription<HostedConnectionStatus?>? _serverSub;

  /// The queued saves (vault, note id) whose retry is in flight.
  final Set<(HostedVaultRef, String)> _retrying = {};

  /// Numbers every hosted write of a note (a save, a retry, a save after
  /// leaving a resolved Today note) in send order.
  int _sendSeq = 0;

  /// The number of the latest write sent for each hosted (vault, note id).
  /// A failed write older than it is superseded by that later write: it
  /// never queues its older text (lead ruling, #102).
  final Map<(HostedVaultRef, String), int> _latestSent = {};

  /// The numbers of the plain saves and saves elsewhere of each hosted
  /// (vault, note id) still in flight.
  final Map<(HostedVaultRef, String), Set<int>> _inFlight = {};

  /// The number of the write that queued each hosted (vault, note id)'s
  /// entry (see [_waitsForOlderWrite]).
  final Map<(HostedVaultRef, String), int> _queuedBy = {};

  /// The queued saves whose retry waits for an older write of the note
  /// still in flight; it runs once that write's outcome is applied.
  final Set<(HostedVaultRef, String)> _deferred = {};

  /// The editor load each hosted plain save in flight was typed in, by its
  /// send number.
  final Map<int, int> _sentInLoad = {};

  /// The plain save of each hosted (vault, note id) held back while an
  /// earlier save of the note typed in the same editor load is in flight:
  /// its text was typed on top of that save's, and a save on the same base
  /// would conflict with it. One per note (the latest text); it goes once
  /// that save's outcome is applied ([_sendDeferred]).
  final Map<(HostedVaultRef, String), _DeferredSave> _deferredSaves = {};

  /// Set (to the base version) after a daily note's save and its merged
  /// retry both conflicted, or text was typed during a merged save: the next
  /// save goes straight to the merge. Null when the next save is plain.
  int? _mergeBase;

  /// The date of the open virtual Today note; null when a real note (or
  /// none) is open.
  String? _virtualDate;
  final Map<String, _VirtualDraft> _drafts = {};

  /// The note the open virtual Today note just became (see [takeResolved]).
  String? _resolvedNoteId;

  /// True, once, when the open virtual Today note just became [noteId]: the
  /// controller already holds that note's text and version, so the host keeps
  /// its editor text instead of loading the stored note.
  bool takeResolved(String noteId) {
    if (_resolvedNoteId != noteId) return false;
    _resolvedNoteId = null;
    return true;
  }

  void loadNote(Note? note) {
    final pending = _debounce?.isActive == true;
    _debounce?.cancel();
    _loadSeq++;
    _mergeBase = null;
    _resolvedNoteId = null;
    final leaving = _virtualDate;
    _virtualDate = null;
    // Leaving the virtual Today note before its first edit was sent: send
    // it now so nothing typed is lost.
    if (leaving != null && pending) unawaited(_createDaily(leaving));
    final date = VirtualTodayTab.dateOf(note?.id);
    if (note != null && date != null) {
      _activeNoteId = note.id;
      _virtualDate = date;
      final draft = _drafts[date];
      final queued = _queuedOf(note.id);
      state = EditorStateValue(
        title: note.title,
        contentMd: draft?.text ?? queued?.save.text ?? '',
        status: queued != null && draft?.sent == null
            ? queued.heldStatus ?? SaveStatus.dirty
            : draft?.sent == null
            ? SaveStatus.idle
            : SaveStatus.saving,
        errorMessage: queued?.heldMessage ?? draft?.error,
      );
      return;
    }
    if (note == null) {
      _activeNoteId = null;
      state = const EditorStateValue(
        title: '',
        contentMd: '',
        status: SaveStatus.idle,
      );
      return;
    }
    _activeNoteId = note.id;
    // A queued note opens with its queued text and base version, never the
    // server copy (D16).
    final queued = _queuedOf(note.id);
    if (queued != null) {
      _showQueued(queued);
      return;
    }
    state = EditorStateValue(
      title: note.title,
      contentMd: note.contentMd,
      status: SaveStatus.clean,
      lastSavedVersion: note.version,
    );
  }

  void onTitleChanged(String value) {
    if (_activeNoteId == null) return;
    if (value == state.title) return; // no-op (e.g. programmatic re-hydration)
    state = state.copyWith(
      title: value,
      status: SaveStatus.dirty,
      clearError: true,
    );
    _updateQueued();
    _scheduleSave();
  }

  void onContentChanged(String value) {
    if (_activeNoteId == null) return;
    if (value == state.contentMd) return; // no-op (programmatic re-hydration)
    state = state.copyWith(
      contentMd: value,
      status: SaveStatus.dirty,
      clearError: true,
    );
    final date = _virtualDate;
    if (date != null) {
      final draft = _drafts.putIfAbsent(date, _VirtualDraft.new)
        ..text = value
        ..error = null;
      _updateQueued();
      // One add only: while it is in flight the text waits for its note.
      if (draft.sent != null) return;
    } else {
      _updateQueued();
    }
    _scheduleSave();
  }

  /// Hides the save error (the inline error's dismiss); the status stays.
  void dismissError() {
    state = state.copyWith(clearError: true);
  }

  /// The poller saw note [noteId] change on disk (WI #28). Reads the stored
  /// note through `VaultAccess.notes` and completes with false when the
  /// stored version is the editor's own base version (its last save or load)
  /// or the editor shows another note (also when it switched notes while the
  /// read was in flight), true for a foreign change. A foreign change to the
  /// open note is applied when the editor is clean as the read lands: the
  /// server body becomes the editor's text and its version the base. A dirty
  /// editor keeps its text; its next save conflicts and merges.
  Future<bool> serverChanged(String noteId) async {
    if (_activeNoteId != noteId) return false;
    final access = _ref.read(vaultAccessProvider);
    if (access == null) return false;
    final note = await access.notes.getNote(noteId);
    if (note == null ||
        _activeNoteId != noteId ||
        note.version == state.lastSavedVersion) {
      return false;
    }
    if (state.status == SaveStatus.clean) {
      state = state.copyWith(
        contentMd: note.contentMd,
        lastSavedVersion: note.version,
      );
    }
    return true;
  }

  /// Saves now when a save debounce is pending (cancelling it); otherwise
  /// does nothing. Synchronous: the save captures the editor's state before
  /// it first awaits, so a caller may switch notes right after (D14, B3
  /// Cmd+click).
  void flushPendingSave() => throw UnimplementedError();

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = _ref.read(clockProvider).after(saveDebounce, () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final date = _virtualDate;
    if (date != null) return _createDaily(date);
    final id = _activeNoteId;
    if (id == null) return;
    final access = _ref.read(vaultAccessProvider);
    final version = state.lastSavedVersion;
    if (access == null || !access.canWrite || version == null) return;

    final local = state.contentMd;
    final rawTitle = state.title;
    final title = rawTitle.trim().isEmpty ? null : rawTitle.trim();
    final hosted = _hostedVault();
    if (hosted != null) {
      final queued = _queue.entryFor(hosted, id);
      if (queued != null) {
        // Queued: the text waits in the queue until the server answers,
        // then goes as the retry.
        _queue.updateText(hosted, id, local, title: rawTitle, sendTitle: title);
        if (_retrying.contains((hosted, id))) {
          if (queued.heldStatus == null) {
            state = state.copyWith(status: SaveStatus.dirty, clearError: true);
          }
          return;
        }
        if (!_connected(hosted)) {
          // The edit can't be sent now: a held save waits for the server
          // again, with its label.
          _queue.release(hosted, id);
          state = state.copyWith(status: SaveStatus.dirty, clearError: true);
          return;
        }
        _debounce?.cancel();
        if (_waitsForOlderWrite(hosted, id)) {
          // An older write of the note is still in flight: the retry goes
          // once its outcome is applied.
          _deferred.add((hosted, id));
          state = state.copyWith(status: SaveStatus.dirty, clearError: true);
          return;
        }
        return _retry(hosted, access, _queue.entryFor(hosted, id)!);
      }
      if (_waitsForOwnSave(hosted, id, _loadSeq)) {
        // An earlier save of this text is still in flight: this save goes
        // once it lands, on the version it stored, never beside it.
        _debounce?.cancel();
        _deferredSaves[(hosted, id)] = _DeferredSave(
          access: access,
          loadSeq: _loadSeq,
          text: local,
          rawTitle: rawTitle,
          title: title,
          baseVersion: version,
        );
        return;
      }
    }
    return _send(
      access,
      hosted,
      id,
      seq: _loadSeq,
      local: local,
      rawTitle: rawTitle,
      title: title,
      version: version,
      merging: _mergeBase != null,
    );
  }

  /// Sends [local] (titled [rawTitle], sending [title]) as note [id]'s
  /// save on [version] through [access], typed in editor load [seq];
  /// [merging] goes straight to the daily merge. The outcome reaches the
  /// editor only while it shows note [id]. On a hosted vault a daily note's
  /// `version_conflict` merges after the note was left too, and any other
  /// `version_conflict` of a save the editor no longer shows in load [seq]
  /// is queued as a held conflict ([_queueFailedSave]), never dropped.
  Future<void> _send(
    VaultAccess access,
    HostedVaultRef? hosted,
    String id, {
    required int seq,
    required String local,
    required String rawTitle,
    required String? title,
    required int version,
    required bool merging,
  }) async {
    final sendSeq = hosted == null ? 0 : _sent(hosted, id);
    if (hosted != null) {
      _sending(hosted, id, sendSeq);
      _sentInLoad[sendSeq] = seq;
    }
    if (_activeNoteId == id && _virtualDate == null && _loadSeq == seq) {
      state = state.copyWith(status: SaveStatus.saving, clearError: true);
    }
    try {
      ({NoteUpdateResult result, String body})? saved;
      Note? refetched;
      if (!merging) {
        try {
          final result = await access.notes.updateNote(
            noteId: id,
            expectedVersion: version,
            title: title,
            contentMd: local,
          );
          saved = (result: result, body: local);
        } on MemexException catch (e) {
          // Only a daily note merges (Req 60); other conflicts surface. On
          // a hosted vault a daily note merges after it was left too.
          if (e.kind != MemexErrorKind.versionConflict ||
              (hosted == null && _activeNoteId != id)) {
            rethrow;
          }
          // The conflict refetch: the stored note's role decides, and it is
          // the merge's server side.
          refetched = await access.notes.getNote(id);
          if ((hosted == null && _activeNoteId != id) ||
              refetched?.role != 'daily') {
            rethrow;
          }
          merging = true;
        }
      }
      saved ??= await _mergeAndSave(
        access,
        noteId: id,
        baseVersion: version,
        local: local,
        title: title,
        server: refetched,
      );
      final deferred = hosted == null ? null : _deferredSaves[(hosted, id)];
      if (deferred != null && !merging && deferred.baseVersion == version) {
        deferred.baseVersion = saved.result.version;
      }
      final stillQueued =
          hosted != null &&
          _afterSave(
            hosted,
            id,
            sendSeq,
            sent: local,
            baseVersion: version,
            savedVersion: saved.result.version,
            merged: merging,
          );
      if (_activeNoteId != id) return;
      _mergeBase = null;
      final later = stillQueued ? _queue.entryFor(hosted, id) : null;
      if (later != null) {
        // A later save of this note queued newer text: the editor keeps
        // its text and the queued save's base and status.
        state = state.copyWith(
          status: later.heldStatus ?? SaveStatus.dirty,
          lastSavedVersion: later.save.baseVersion,
          errorMessage: later.heldMessage,
          clearError: later.heldMessage == null,
        );
      } else if (merging && state.contentMd != local) {
        // Typed during the merged save: the new text lacks the merged
        // blocks, so the next save merges again from the same base.
        _mergeBase = version;
        state = state.copyWith(status: SaveStatus.dirty);
      } else if (merging ||
          (state.contentMd == local && state.title == rawTitle)) {
        state = state.copyWith(
          contentMd: merging ? saved.body : null,
          status: SaveStatus.clean,
          lastSavedVersion: saved.result.version,
          clearError: true,
        );
      } else if (_loadSeq != seq &&
          state.status == SaveStatus.clean &&
          state.lastSavedVersion == version) {
        // Opened again (from the server copy) while this save was in
        // flight, and not edited since: the editor shows what it saved.
        state = state.copyWith(
          title: rawTitle,
          contentMd: local,
          lastSavedVersion: saved.result.version,
          clearError: true,
        );
      } else if (state.status != SaveStatus.saving) {
        // Edited while this save was in flight (also after opening the
        // note again): the newer text stays unsaved, on the version this
        // save stored when it was based on the same one, and saves next.
        state = state.copyWith(
          status: SaveStatus.dirty,
          lastSavedVersion: state.lastSavedVersion == version
              ? saved.result.version
              : null,
        );
        if (_debounce?.isActive != true) _scheduleSave();
      }
      _ref.read(vaultRevisionProvider.notifier).state++;
    } on MemexException catch (e) {
      if (hosted != null && _couldNotReach(e)) {
        return _queueFailedSave(
          hosted,
          id,
          seq,
          local,
          rawTitle,
          title,
          version,
          sendSeq,
          e,
        );
      }
      final conflict = e.kind == MemexErrorKind.versionConflict;
      if (hosted != null &&
          conflict &&
          !(_activeNoteId == id && _virtualDate == null && _loadSeq == seq)) {
        // Left (or opened again) while this save was in flight: its text
        // is kept as a held conflict, never dropped (#102).
        return _queueFailedSave(
          hosted,
          id,
          seq,
          local,
          rawTitle,
          title,
          version,
          sendSeq,
          e,
          held: true,
        );
      }
      if (_activeNoteId != id) return;
      if (merging && conflict) {
        // The merged retry conflicted too: keep the local text and merge
        // again on the next debounce tick.
        _mergeBase = version;
        state = state.copyWith(
          status: SaveStatus.conflict,
          errorMessage: couldNotSaveMessage,
        );
        _scheduleSave();
        return;
      }
      state = state.copyWith(
        status: conflict ? SaveStatus.conflict : SaveStatus.error,
        errorMessage: e.message,
      );
    } catch (e) {
      if (hosted != null && _couldNotReach(e)) {
        return _queueFailedSave(
          hosted,
          id,
          seq,
          local,
          rawTitle,
          title,
          version,
          sendSeq,
          e,
        );
      }
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: SaveStatus.error,
        errorMessage: e.toString(),
      );
    } finally {
      if (hosted != null) _settled(hosted, id, sendSeq);
    }
  }

  /// A hosted save of note [id] (sent with [local] on [baseVersion], editor
  /// load [seq], titled [rawTitle], sending [sendTitle]) couldn't reach the
  /// server: queue the latest text with the base version and the first
  /// failure's time. The editor keeps its text and shows no error. When the
  /// person left the note and opened it again while the save was in flight
  /// (and nothing saved since), the editor shows the queued text instead,
  /// as [loadNote] does for a queued note. A save ([sendSeq]) superseded by
  /// a later write of the note queues nothing: the later write's text is
  /// newer (an entry it queued is kept). When the status already reads
  /// connected again the queued save retries now. With [held] (a
  /// `version_conflict` after the note was left) the entry is held with
  /// [error]'s conflict instead (see [QueuedSave.heldStatus]): it retries on
  /// the next edit of the note, not on its own.
  void _queueFailedSave(
    HostedVaultRef vault,
    String id,
    int seq,
    String local,
    String rawTitle,
    String? sendTitle,
    int baseVersion,
    int sendSeq,
    Object error, {
    bool held = false,
  }) {
    // A later write of this note was sent after this one: its text is
    // newer, and its outcome decides (saved, or queued itself). This older
    // text is never queued and never fills the editor. (Every entry of the
    // note queued after this save was sent was queued by such a later
    // write, so an entry is never already there below.)
    if (_supersededBy(vault, id, sendSeq)) return;
    final shown = _activeNoteId == id && _virtualDate == null;
    final open = shown && _loadSeq == seq;
    // Opened again (from the server copy) while this save was in flight,
    // with nothing saved since: the editor shows the queued text instead,
    // as opening a queued note does (AC6).
    final reopened = shown && !open && state.lastSavedVersion == baseVersion;
    _queue.put(
      vault: vault,
      noteId: id,
      title: open ? state.title : rawTitle,
      sendTitle: open
          ? (state.title.trim().isEmpty ? null : state.title.trim())
          : sendTitle,
      text: open ? state.contentMd : local,
      baseVersion: baseVersion,
      now: _ref.read(clockProvider).now(),
      serverName: _serverNameOf(error, vault),
    );
    if (held && error is MemexException) {
      _queue.hold(vault, id, SaveStatus.conflict, error.message);
    }
    _queuedBy[(vault, id)] = sendSeq;
    if (open) {
      // The retry merges from the base itself.
      _mergeBase = null;
      state = state.copyWith(status: SaveStatus.dirty, clearError: true);
    } else if (reopened) {
      _mergeBase = null;
      _showQueued(_queue.entryFor(vault, id)!);
    }
    if (_connected(vault)) _retryQueued(vault);
  }

  /// Sends queued save [queued] of [vault] once through [access] (its
  /// latest text on its base version). Success removes it from the queue,
  /// bumps the vault revision and, when the note is open, sets the editor's
  /// saved version. A `version_conflict` whose server body equals the text
  /// counts as saved (L17); a daily note merges (Req 60); any other conflict
  /// or error holds the save and, when open, shows today's conflict or
  /// error state. Couldn't-reach keeps it queued for the next recovery.
  Future<void> _retry(
    HostedVaultRef vault,
    VaultAccess access,
    QueuedSave queued,
  ) async {
    final id = queued.save.noteId;
    final base = queued.save.baseVersion;
    final key = (vault, id);
    if (base == null || !_retrying.add(key)) return;
    _sent(vault, id);
    final sent = queued.save.text;
    bool isOpen() =>
        _activeNoteId == id &&
        _virtualDate == null &&
        _ref.read(currentVaultProvider) == vault;
    if (isOpen()) {
      state = state.copyWith(status: SaveStatus.saving, clearError: true);
    }
    try {
      var merged = false;
      var body = sent;
      int version;
      try {
        final result = await access.notes.updateNote(
          noteId: id,
          expectedVersion: base,
          title: queued.sendTitle,
          contentMd: sent,
        );
        version = result.version;
      } on MemexException catch (e) {
        if (e.kind != MemexErrorKind.versionConflict) rethrow;
        final server = await access.notes.getNote(id);
        if (server != null && server.contentMd == sent) {
          // L17 self-heal: an earlier attempt committed this text.
          version = server.version;
        } else if (server?.role == 'daily') {
          final saved = await _mergeAndSave(
            access,
            noteId: id,
            baseVersion: base,
            local: sent,
            title: queued.sendTitle,
            server: server,
          );
          version = saved.result.version;
          body = saved.body;
          merged = true;
        } else {
          rethrow;
        }
      }
      final latest = _queue.entryFor(vault, id);
      final typed = latest != null && latest.save.text != sent;
      if (!typed) {
        _queue.remove(vault, id);
      } else if (!merged) {
        // Typed during the retry: the newer text stays queued on the
        // version just saved. (After a merge it stays on the old base, so
        // its save merges again.)
        _queue.rebase(vault, id, version);
      }
      if (isOpen()) {
        if (!typed) {
          state = state.copyWith(
            contentMd: merged ? body : null,
            status: SaveStatus.clean,
            lastSavedVersion: version,
            clearError: true,
          );
        } else {
          state = state.copyWith(
            status: SaveStatus.dirty,
            lastSavedVersion: merged ? null : version,
          );
          if (_debounce?.isActive != true) _scheduleSave();
        }
      }
      _ref.read(vaultRevisionProvider.notifier).state++;
    } on Object catch (e) {
      if (_couldNotReach(e)) {
        // Still queued (a held save waits for the server again, with its
        // label); the next recovery retries.
        _queue.release(vault, id);
        if (isOpen()) {
          state = state.copyWith(status: SaveStatus.dirty, clearError: true);
        }
        return;
      }
      final conflict =
          e is MemexException && e.kind == MemexErrorKind.versionConflict;
      final status = conflict ? SaveStatus.conflict : SaveStatus.error;
      final message = e is MemexException ? e.message : e.toString();
      _queue.hold(vault, id, status, message);
      if (isOpen()) {
        state = state.copyWith(status: status, errorMessage: message);
      }
    } finally {
      _retrying.remove(key);
    }
  }

  /// Every queued save of [vault] (the open vault) retries once: the server
  /// answers again (D17). Held saves wait for an edit.
  void _retryQueued(HostedVaultRef vault) {
    if (_ref.read(currentVaultProvider) != vault) return;
    final access = _ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    for (final q in _queue.entriesOf(vault)) {
      if (q.heldStatus != null) continue;
      final id = q.save.noteId;
      final date = VirtualTodayTab.dateOf(id);
      if (date != null) {
        if (_drafts.containsKey(date)) unawaited(_createDaily(date));
        continue;
      }
      _retryNow(vault, access, q);
    }
  }

  /// Retries queued save [q] of [vault] now, or, while an older write of
  /// its note is still in flight, once that write's outcome is applied
  /// ([_settled]).
  void _retryNow(HostedVaultRef vault, VaultAccess access, QueuedSave q) {
    final id = q.save.noteId;
    if (_waitsForOlderWrite(vault, id)) {
      _deferred.add((vault, id));
      return;
    }
    // The retry sends the open note's latest text: no second save.
    if (id == _activeNoteId && _virtualDate == null) _debounce?.cancel();
    unawaited(_retry(vault, access, q));
  }

  /// True while a write of note [id] in [vault] sent before the write that
  /// queued its entry is still in flight: that write's success may move the
  /// entry onto the version it saved ([_afterSave]), so the entry's retry
  /// waits for it instead of conflicting with it.
  bool _waitsForOlderWrite(HostedVaultRef vault, String id) {
    final by = _queuedBy[(vault, id)] ?? 0;
    return _inFlight[(vault, id)]?.any((s) => s < by) ?? false;
  }

  /// Write [sendSeq] of note [id] in [vault] is done (its outcome applied):
  /// a retry of the note's entry that waited for it runs now when the
  /// server's status reads connected (the next recovery retries otherwise).
  void _settled(HostedVaultRef vault, String id, int sendSeq) {
    final key = (vault, id);
    final pending = _inFlight[key];
    if (pending != null && pending.remove(sendSeq) && pending.isEmpty) {
      _inFlight.remove(key);
    }
    _sentInLoad.remove(sendSeq);
    if (!mounted) return;
    final held = _deferredSaves[key];
    if (held != null && !_waitsForOwnSave(vault, id, held.loadSeq)) {
      _sendDeferred(vault, id);
    }
    if (_waitsForOlderWrite(vault, id)) return;
    if (!_deferred.remove(key)) return;
    final q = _queue.entryFor(vault, id);
    if (q == null || !_connected(vault)) return;
    if (_ref.read(currentVaultProvider) != vault) return;
    final access = _ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    _retryNow(vault, access, q);
  }

  /// True while a plain save of note [id] in [vault] typed in editor load
  /// [load] is in flight.
  bool _waitsForOwnSave(HostedVaultRef vault, String id, int load) =>
      _inFlight[(vault, id)]?.any((s) => _sentInLoad[s] == load) ?? false;

  /// The earlier save note [id]'s held-back plain save in [vault] waited for
  /// is done: it goes now. While the editor still shows the note in the
  /// same load, the editor's latest text goes on the editor's base (the
  /// version the earlier save stored), unless the editor is clean; a queued
  /// entry of the note takes the text instead (its retry sends it);
  /// otherwise the held-back text goes on its base.
  void _sendDeferred(HostedVaultRef vault, String id) {
    final d = _deferredSaves.remove((vault, id))!;
    final open =
        _activeNoteId == id &&
        _virtualDate == null &&
        _loadSeq == d.loadSeq &&
        _ref.read(currentVaultProvider) == vault;
    if (open) {
      if (state.status == SaveStatus.clean) return;
      _debounce?.cancel();
      unawaited(_save());
      return;
    }
    if (_queue.entryFor(vault, id) != null) {
      _queue.updateText(
        vault,
        id,
        d.text,
        title: d.rawTitle,
        sendTitle: d.title,
      );
      return;
    }
    unawaited(
      _send(
        d.access,
        vault,
        id,
        seq: d.loadSeq,
        local: d.text,
        rawTitle: d.rawTitle,
        title: d.title,
        version: d.baseVersion,
        merging: false,
      ),
    );
  }

  /// Follows [vault]'s server connection status: on its return to
  /// connected every queued save retries. Opening [vault] while its status
  /// already reads connected retries its queued saves once too.
  void _watchServer(VaultRef? vault) {
    _serverSub?.close();
    _serverSub = null;
    if (vault is! HostedVaultRef) return;
    _serverSub = _ref.listen<HostedConnectionStatus?>(
      hostedConnectionStatusProvider(vault.serverId),
      (prev, next) {
        if (next == HostedConnectionStatus.connected &&
            prev != HostedConnectionStatus.connected) {
          _retryQueued(vault);
        }
      },
    );
    // Back in a vault whose server already answers (it may have answered
    // while another vault was open): its queued saves retry once (AC2).
    if (_queue.entriesOf(vault).isEmpty) return;
    scheduleMicrotask(() {
      if (!mounted || _ref.read(currentVaultProvider) != vault) return;
      if (_connected(vault)) _retryQueued(vault);
    });
  }

  /// Fills the editor from queued save [queued] of the open note: its text,
  /// title and base version, never the server copy (D16), and its held
  /// status and message when held.
  void _showQueued(QueuedSave queued) {
    state = EditorStateValue(
      title: queued.save.title,
      contentMd: queued.save.text,
      status: queued.heldStatus ?? SaveStatus.dirty,
      errorMessage: queued.heldMessage,
      lastSavedVersion: queued.save.baseVersion,
    );
  }

  PendingSaveQueue get _queue => _ref.read(pendingSaveQueueProvider.notifier);

  /// The open vault when it is hosted; null for a local vault.
  HostedVaultRef? _hostedVault() {
    final vault = _ref.read(currentVaultProvider);
    return vault is HostedVaultRef ? vault : null;
  }

  bool _connected(HostedVaultRef vault) =>
      _ref.read(hostedConnectionStatusProvider(vault.serverId)) ==
      HostedConnectionStatus.connected;

  /// Numbers a write of note [id] in [vault] about to be sent (see
  /// [_latestSent]) and returns its number.
  int _sent(HostedVaultRef vault, String id) =>
      _latestSent[(vault, id)] = ++_sendSeq;

  /// Write [sendSeq] of note [id] in [vault] is in flight until
  /// [_settled].
  void _sending(HostedVaultRef vault, String id, int sendSeq) =>
      _inFlight.putIfAbsent((vault, id), () => {}).add(sendSeq);

  /// True when a write of note [id] in [vault] was sent after write
  /// [sendSeq].
  bool _supersededBy(HostedVaultRef vault, String id, int sendSeq) =>
      (_latestSent[(vault, id)] ?? 0) > sendSeq;

  /// Hosted save [sendSeq] of note [id] in [vault], sent with [sent] on
  /// [baseVersion], saved at [savedVersion] ([merged]: through the daily
  /// merge). A queued entry of the note holding [sent] is saved and
  /// removed. Any other entry stays: one a later write queued holds newer
  /// text and moves onto [savedVersion] when it was based on [baseVersion]
  /// and this save did not merge; an older one keeps its base, so its retry
  /// meets this save's text as a conflict (a daily note merges). Returns
  /// true when an entry stays queued.
  bool _afterSave(
    HostedVaultRef vault,
    String id,
    int sendSeq, {
    required String sent,
    required int baseVersion,
    required int savedVersion,
    required bool merged,
  }) {
    final entry = _queue.entryFor(vault, id);
    if (entry == null) return false;
    if (entry.save.text == sent) {
      _queue.remove(vault, id);
      return false;
    }
    final later = (_queuedBy[(vault, id)] ?? 0) > sendSeq;
    if (later && !merged && entry.save.baseVersion == baseVersion) {
      _queue.rebase(vault, id, savedVersion);
    }
    return true;
  }

  /// The open vault's queued save of [noteId], or null.
  QueuedSave? _queuedOf(String noteId) {
    final hosted = _hostedVault();
    return hosted == null ? null : _queue.entryFor(hosted, noteId);
  }

  /// Copies the open note's text (and title) into its queued save, if any.
  void _updateQueued() {
    final id = _activeNoteId;
    final hosted = _hostedVault();
    if (id == null || hosted == null) return;
    final real = _virtualDate == null;
    final title = state.title.trim();
    _queue.updateText(
      hosted,
      id,
      state.contentMd,
      title: real ? state.title : null,
      sendTitle: real && title.isNotEmpty ? title : null,
    );
  }

  /// The server name for a save that failed with [error].
  String _serverNameOf(Object error, HostedVaultRef vault) =>
      error is VaultUnreachableException
      ? error.serverName
      : _ref.read(hostedServerNameProvider(vault.serverId));

  /// Req 60: refetches daily note [noteId] ([server] when the caller just
  /// did) and its blocks through [access], and saves [local]'s person text,
  /// then every agent / quick-entry block created after [baseVersion] (the
  /// version [local] was based on) whose text it lacks, then the server's
  /// footer ([mergeConflict]), with the refetched version.
  Future<({NoteUpdateResult result, String body})> _mergeAndSave(
    VaultAccess access, {
    required String noteId,
    required int baseVersion,
    required String local,
    required String? title,
    Note? server,
  }) async {
    final stored = server ?? await access.notes.getNote(noteId);
    if (stored == null) {
      throw MemexException('update failed: note $noteId not found');
    }
    final blocks = await access.daily.blocksForNote(noteId);
    final body = mergeConflict(
      localPerson: splitDailyBody(local).person,
      baseVersion: baseVersion,
      serverBody: stored.contentMd,
      serverBlocks: [
        for (final b in blocks)
          ServerBlock(
            source: b.source,
            createdVersion: b.createdVersion,
            ord: b.ord,
            text: b.text,
          ),
      ],
    );
    final result = await access.notes.updateNote(
      noteId: noteId,
      expectedVersion: stored.version,
      title: title,
      contentMd: body,
    );
    return (result: result, body: body);
  }

  /// The first edit of the virtual Today note for [date]: create the daily
  /// note with the draft's text through `VaultAccess.notes`, read it back,
  /// then [_resolve] the tab onto it. On any failure other than
  /// `daily_note_exists` (including a read-back that fails or finds no
  /// note) the text stays in the editor with the message, the status is
  /// [SaveStatus.error], and the next edit tries again.
  ///
  /// A retry after a failed read-back that answers `daily_note_exists` with
  /// the id the earlier add created resolves as that add (the note holds its
  /// text, which the editor text replaces), so the text is not appended
  /// twice.
  ///
  /// On a hosted vault a create (or read-back) that can't reach the server
  /// queues the draft under the tab's id instead (#102): it retries when
  /// the server answers. A retry that answers `daily_note_exists` for a
  /// note ending with the text of an earlier add that timed out after it
  /// was sent resolves as that add too.
  Future<void> _createDaily(String date) async {
    final draft = _drafts[date];
    final access = _ref.read(vaultAccessProvider);
    if (draft == null || access == null || !access.canWrite) return;
    // One add at a time.
    if (draft.sent != null) return;
    final hosted = _hostedVault();
    final queueId = VirtualTodayTab(date).id;
    final queued = hosted == null ? null : _queue.entryFor(hosted, queueId);
    if (hosted != null && queued != null) {
      _queue.updateText(hosted, queueId, draft.text);
      if (!_connected(hosted)) {
        // The edit can't be sent now: a held create waits for the server
        // again, with its label.
        _queue.release(hosted, queueId);
        draft.error = null;
        if (_virtualDate == date) {
          state = state.copyWith(status: SaveStatus.dirty, clearError: true);
        }
        return;
      }
    }
    var sent = draft.sent = draft.text;
    if (_virtualDate == date) state = state.copyWith(status: SaveStatus.saving);
    DailyCreateResult result;
    try {
      result = await createDailyNote(access.notes, date: date, contentMd: sent);
    } catch (e) {
      if (hosted != null && _couldNotReach(e)) {
        if (e is VaultUnreachableException && e.mayHaveCommitted) {
          draft.maybeCreated.add(sent);
        }
        _queueDraft(hosted, date, draft, e, retried: queued != null);
        return;
      }
      _failDraft(date, draft, e);
      return;
    }
    final createdText = draft.createdText;
    if (result.existed &&
        result.noteId == draft.createdId &&
        createdText != null) {
      // Our own earlier add made this note: it holds that add's text.
      result = DailyCreateResult(noteId: result.noteId, existed: false);
      sent = createdText;
    }
    // Read the note back while the draft still holds the add: text typed
    // meanwhile stays in the draft and goes with [_resolve].
    Note? stored;
    Object? readError;
    try {
      stored = await access.notes.getNote(result.noteId);
    } catch (e) {
      readError = e;
    }
    if (stored == null) {
      if (!result.existed) {
        draft
          ..createdId = result.noteId
          ..createdText = sent;
      }
      final error = readError;
      if (hosted != null && error != null && _couldNotReach(error)) {
        _queueDraft(hosted, date, draft, error, retried: queued != null);
        return;
      }
      _failDraft(
        date,
        draft,
        error ?? 'read failed: note ${result.noteId} not found',
      );
      return;
    }
    if (result.existed && draft.maybeCreated.isNotEmpty) {
      final person = splitDailyBody(stored.contentMd).person.trimRight();
      final candidates = [...draft.maybeCreated]
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final text in candidates) {
        final t = text.trimRight();
        if (t.isNotEmpty && person.endsWith(t)) {
          // An earlier add that timed out made this note: it holds that
          // add's text, which the editor text replaces.
          result = DailyCreateResult(noteId: result.noteId, existed: false);
          sent = text;
          break;
        }
      }
    }
    _drafts.remove(date);
    if (hosted != null) _queue.remove(hosted, queueId);
    _resolve(date, result, stored, sent: sent, latest: draft.text);
  }

  /// The hosted virtual Today create for [date] couldn't reach the server
  /// ([error]): queue the draft's text under the tab's id with the first
  /// failure's time; the editor keeps the text and shows no error. A first
  /// failure ([retried] false) retries now when the status already reads
  /// connected again.
  void _queueDraft(
    HostedVaultRef vault,
    String date,
    _VirtualDraft draft,
    Object error, {
    required bool retried,
  }) {
    draft.sent = null;
    _queue.put(
      vault: vault,
      noteId: VirtualTodayTab(date).id,
      title: date,
      text: draft.text,
      baseVersion: null,
      now: _ref.read(clockProvider).now(),
      serverName: _serverNameOf(error, vault),
    );
    if (_virtualDate == date) {
      state = state.copyWith(status: SaveStatus.dirty, clearError: true);
    }
    if (!retried && _connected(vault)) _retryQueued(vault);
  }

  /// Records [error] on the virtual Today [draft] for [date]: nothing is in
  /// flight, and the open editor shows the message with [SaveStatus.error].
  void _failDraft(String date, _VirtualDraft draft, Object error) {
    draft
      ..sent = null
      ..error = error is MemexException ? error.message : error.toString();
    // A queued create that reached the server and failed stops retrying on
    // its own; the next edit tries again.
    final hosted = _hostedVault();
    if (hosted != null) {
      _queue.hold(
        hosted,
        VirtualTodayTab(date).id,
        SaveStatus.error,
        draft.error!,
      );
    }
    if (_virtualDate == date) {
      state = state.copyWith(
        status: SaveStatus.error,
        errorMessage: draft.error,
      );
    }
  }

  /// Moves the virtual Today note for [date] onto the daily note [result]
  /// names ([stored], as read back), with the [latest] text typed (of which
  /// [sent] went with the `add`):
  /// - created: the note holds [sent]; the editor keeps [latest];
  /// - adopted (Q2): the CLI appended [sent] to the note's old text, which
  ///   [latest] replaces;
  /// - `daily_note_exists`: [latest] is appended to the end of the note's
  ///   person section (C3.1).
  ///
  /// Anything the note does not hold yet is saved through `update`.
  void _resolve(
    String date,
    DailyCreateResult result,
    Note stored, {
    required String sent,
    required String latest,
  }) {
    final id = result.noteId;
    final body = splitDailyBody(stored.contentMd);
    final created =
        !result.existed && body.person.trimRight() == sent.trimRight();
    final base = result.existed
        ? body.person
        : _withoutTrailing(body.person, sent);
    final content = created
        ? latest
        : assembleDailyBody(appendToPerson(base, latest), body.chips);
    final save = result.existed || latest != sent;
    if (_virtualDate == date) {
      _virtualDate = null;
      _activeNoteId = id;
      _resolvedNoteId = id;
      state = EditorStateValue(
        title: stored.title,
        contentMd: content,
        status: save ? SaveStatus.dirty : SaveStatus.clean,
        lastSavedVersion: stored.version,
      );
      if (save) unawaited(_save());
    } else if (save) {
      unawaited(
        _saveElsewhere(
          id,
          stored.version,
          content,
          title: stored.title,
          appended: latest,
        ),
      );
    }
    _ref
        .read(tabsProvider.notifier)
        .resolveVirtualToday(date: date, noteId: id);
    _ref.read(vaultRevisionProvider.notifier).state++;
  }

  /// Saves [content] to note [id] through `VaultAccess.notes` after the
  /// person left it (no editor state to report to). On a hosted vault a
  /// `version_conflict` merges [content] into the daily note
  /// ([_mergeAndSave], Req 60) instead of dropping it. A failure leaves the
  /// stored note as it is; on a hosted vault one that can't reach the
  /// server queues [content] for note [id] (titled [title]) on [version]
  /// instead, like the editor's own save (#102). When an older edit of
  /// note [id] is already queued, that edit keeps its text, title and base
  /// version: [appended] (the virtual Today text [content] carries) is
  /// appended to its person section (C3.1) unless it already holds it
  /// (lead ruling, #102).
  Future<void> _saveElsewhere(
    String id,
    int version,
    String content, {
    required String title,
    required String appended,
  }) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) return;
    final hosted = _hostedVault();
    final sendSeq = hosted == null ? 0 : _sent(hosted, id);
    if (hosted != null) _sending(hosted, id, sendSeq);
    try {
      NoteUpdateResult result;
      var merged = false;
      try {
        result = await access.notes.updateNote(
          noteId: id,
          expectedVersion: version,
          contentMd: content,
        );
      } on MemexException catch (e) {
        // On a hosted vault the daily note merges (Req 60) rather than
        // dropping the text (#102).
        if (hosted == null || e.kind != MemexErrorKind.versionConflict) {
          rethrow;
        }
        result = (await _mergeAndSave(
          access,
          noteId: id,
          baseVersion: version,
          local: content,
          title: null,
        )).result;
        merged = true;
      }
      if (hosted != null &&
          _afterSave(
            hosted,
            id,
            sendSeq,
            sent: content,
            baseVersion: version,
            savedVersion: result.version,
            merged: merged,
          ) &&
          _activeNoteId == id &&
          _virtualDate == null) {
        // Opened since, with a queued save: the editor keeps its base.
        final base = _queue.entryFor(hosted, id)!.save.baseVersion;
        state = state.copyWith(lastSavedVersion: base);
      }
    } on Exception catch (e) {
      if (hosted != null &&
          _couldNotReach(e) &&
          !_supersededBy(hosted, id, sendSeq)) {
        final older = _queue.entryFor(hosted, id);
        if (older != null) {
          // Not superseded, so the entry was queued by an older write: it
          // is the person's unsaved edit and keeps its place and base.
          final text = _withAppended(older.save.text, appended);
          _queue
            ..updateText(hosted, id, text)
            ..release(hosted, id);
          if (_activeNoteId == id &&
              _virtualDate == null &&
              state.contentMd == older.save.text) {
            state = state.copyWith(contentMd: text);
          }
        } else {
          _queue.put(
            vault: hosted,
            noteId: id,
            title: title,
            text: content,
            baseVersion: version,
            now: _ref.read(clockProvider).now(),
            serverName: _serverNameOf(e, hosted),
          );
          _queuedBy[(hosted, id)] = sendSeq;
        }
        if (_connected(hosted)) _retryQueued(hosted);
      }
      return;
    } finally {
      if (hosted != null) _settled(hosted, id, sendSeq);
    }
    _ref.read(vaultRevisionProvider.notifier).state++;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _serverSub?.close();
    super.dispose();
  }
}

/// True when [error] means a hosted save couldn't reach the vault server:
/// unreachable or timed out (D17), or a `401` (Req 51, L16).
bool _couldNotReach(Object error) =>
    error is VaultUnreachableException ||
    (error is MemexException && error.code == 'unauthorized');

final editorControllerProvider =
    StateNotifierProvider<EditorController, EditorStateValue>(
      EditorController.new,
    );

/// The daily body [body] with [text] appended to its person section
/// (C3.1), unchanged when the person section already holds [text].
String _withAppended(String body, String text) {
  final split = splitDailyBody(body);
  if (split.person.contains(text.trimRight())) return body;
  return assembleDailyBody(appendToPerson(split.person, text), split.chips);
}

/// [person] without the [text] at its end (ignoring trailing whitespace),
/// unchanged when it does not end with it.
String _withoutTrailing(String person, String text) {
  final p = person.trimRight();
  final t = text.trimRight();
  if (!p.endsWith(t)) return person;
  return p.substring(0, p.length - t.length);
}
