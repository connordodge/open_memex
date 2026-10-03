import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../editor/conflict_merge.dart';
import '../editor/segments.dart';
import '../memex_cli.dart';
import 'tabs_state.dart' show VirtualTodayTab, tabsProvider;
import 'today_state.dart';
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

  /// The CLI message of the last failed `memex add`.
  String? error;
}

/// Editor controller — owns the debounced save state for the open note.
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

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final date = _virtualDate;
    if (date != null) return _createDaily(date);
    final id = _activeNoteId;
    if (id == null) return;
    final cli = _ref.read(memexCliProvider);
    final vaultPath = _ref.read(currentVaultProvider);
    final version = state.lastSavedVersion;
    if (cli == null || vaultPath == null || version == null) return;

    state = state.copyWith(status: SaveStatus.saving, clearError: true);
    try {
      final result = await cli.updateNote(
        vaultPath: vaultPath,
        noteId: id,
        expectedVersion: version,
        title: state.title.trim().isEmpty ? null : state.title.trim(),
        contentMd: state.contentMd,
      );
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: SaveStatus.clean,
        lastSavedVersion: result.version,
        clearError: true,
      );
      _ref.read(vaultRevisionProvider.notifier).state++;
    } on MemexException catch (e) {
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: e.kind == MemexErrorKind.versionConflict
            ? SaveStatus.conflict
            : SaveStatus.error,
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

  /// The first edit of the virtual Today note for [date]: create the daily
  /// note with the draft's text, then [_resolve] the tab onto it. On any
  /// failure other than `daily_note_exists` the text stays in the editor
  /// with the CLI message, and the next edit tries again.
  Future<void> _createDaily(String date) async {
    final draft = _drafts[date];
    final cli = _ref.read(memexCliProvider);
    final vaultPath = _ref.read(currentVaultProvider);
    if (draft == null || cli == null || vaultPath == null) return;
    final sent = draft.sent = draft.text;
    if (_virtualDate == date) state = state.copyWith(status: SaveStatus.saving);
    final DailyCreateResult result;
    try {
      result = await createDailyNote(
        cli,
        vaultPath: vaultPath,
        date: date,
        contentMd: sent,
      );
    } catch (e) {
      draft
        ..sent = null
        ..error = e is MemexException ? e.message : e.toString();
      if (_virtualDate == date) {
        state = state.copyWith(
          status: SaveStatus.error,
          errorMessage: draft.error,
        );
      }
      return;
    }
    _drafts.remove(date);
    _resolve(date, result, sent: sent, latest: draft.text);
  }

  /// Moves the virtual Today note for [date] onto the daily note [result]
  /// names, with the [latest] text typed (of which [sent] went with the
  /// `add`):
  /// - created: the note holds [sent]; the editor keeps [latest];
  /// - adopted (Q2): the CLI appended [sent] to the note's old text, which
  ///   [latest] replaces;
  /// - `daily_note_exists`: [latest] is appended to the end of the note's
  ///   person section (C3.1).
  ///
  /// Anything the note does not hold yet is saved through `update`.
  void _resolve(
    String date,
    DailyCreateResult result, {
    required String sent,
    required String latest,
  }) {
    final id = result.noteId;
    final stored = _ref.read(vaultDbProvider)?.getNote(id);
    if (stored == null) return;
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

  /// Saves [content] to note [id] after the person left it (no editor state
  /// to report to). A failure leaves the stored note as it is.
  Future<void> _saveElsewhere(String id, int version, String content) async {
    final cli = _ref.read(memexCliProvider)!;
    final vaultPath = _ref.read(currentVaultProvider)!;
    try {
      await cli.updateNote(
        vaultPath: vaultPath,
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
