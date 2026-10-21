import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../editor/conflict_merge.dart';
import '../editor/segments.dart';
import '../memex_cli.dart';
import '../vault_access/vault_access.dart';
import 'clock.dart';
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
class EditorController extends StateNotifier<EditorStateValue> {
  EditorController(this._ref)
    : super(
        const EditorStateValue(
          title: '',
          contentMd: '',
          status: SaveStatus.idle,
        ),
      );

  final Ref _ref;
  Timer? _debounce;
  String? _activeNoteId;

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
      state = EditorStateValue(
        title: note.title,
        contentMd: draft?.text ?? '',
        status: draft?.sent == null ? SaveStatus.idle : SaveStatus.saving,
        errorMessage: draft?.error,
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
      // One add only: while it is in flight the text waits for its note.
      if (draft.sent != null) return;
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
    final title = state.title.trim().isEmpty ? null : state.title.trim();
    var merging = _mergeBase != null;
    state = state.copyWith(status: SaveStatus.saving, clearError: true);
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
          // Only a daily note merges (Req 60); other conflicts surface.
          if (e.kind != MemexErrorKind.versionConflict || _activeNoteId != id) {
            rethrow;
          }
          // The conflict refetch: the stored note's role decides, and it is
          // the merge's server side.
          refetched = await access.notes.getNote(id);
          if (_activeNoteId != id || refetched?.role != 'daily') rethrow;
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
      if (_activeNoteId != id) return;
      _mergeBase = null;
      if (merging && state.contentMd != local) {
        // Typed during the merged save: the new text lacks the merged
        // blocks, so the next save merges again from the same base.
        _mergeBase = version;
        state = state.copyWith(status: SaveStatus.dirty);
      } else {
        state = state.copyWith(
          contentMd: merging ? saved.body : null,
          status: SaveStatus.clean,
          lastSavedVersion: saved.result.version,
          clearError: true,
        );
      }
      _ref.read(vaultRevisionProvider.notifier).state++;
    } on MemexException catch (e) {
      if (_activeNoteId != id) return;
      final conflict = e.kind == MemexErrorKind.versionConflict;
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
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: SaveStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

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
  Future<void> _createDaily(String date) async {
    final draft = _drafts[date];
    final access = _ref.read(vaultAccessProvider);
    if (draft == null || access == null || !access.canWrite) return;
    var sent = draft.sent = draft.text;
    if (_virtualDate == date) state = state.copyWith(status: SaveStatus.saving);
    DailyCreateResult result;
    try {
      result = await createDailyNote(access.notes, date: date, contentMd: sent);
    } catch (e) {
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
      _failDraft(
        date,
        draft,
        readError ?? 'read failed: note ${result.noteId} not found',
      );
      return;
    }
    _drafts.remove(date);
    _resolve(date, result, stored, sent: sent, latest: draft.text);
  }

  /// Records [error] on the virtual Today [draft] for [date]: nothing is in
  /// flight, and the open editor shows the message with [SaveStatus.error].
  void _failDraft(String date, _VirtualDraft draft, Object error) {
    draft
      ..sent = null
      ..error = error is MemexException ? error.message : error.toString();
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
      unawaited(_saveElsewhere(id, stored.version, content));
    }
    _ref
        .read(tabsProvider.notifier)
        .resolveVirtualToday(date: date, noteId: id);
    _ref.read(vaultRevisionProvider.notifier).state++;
  }

  /// Saves [content] to note [id] through `VaultAccess.notes` after the
  /// person left it (no editor state to report to). A failure leaves the
  /// stored note as it is.
  Future<void> _saveElsewhere(String id, int version, String content) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) return;
    try {
      await access.notes.updateNote(
        noteId: id,
        expectedVersion: version,
        contentMd: content,
      );
    } on Exception {
      return;
    }
    _ref.read(vaultRevisionProvider.notifier).state++;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final editorControllerProvider =
    StateNotifierProvider<EditorController, EditorStateValue>(
      EditorController.new,
    );

/// [person] without the [text] at its end (ignoring trailing whitespace),
/// unchanged when it does not end with it.
String _withoutTrailing(String person, String text) {
  final p = person.trimRight();
  final t = text.trimRight();
  if (!p.endsWith(t)) return person;
  return p.substring(0, p.length - t.length);
}
