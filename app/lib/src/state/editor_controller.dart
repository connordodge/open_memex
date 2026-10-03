import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import 'vault_state.dart';

// The editor's state types are declared in vault_state.dart (owned by #18)
// and re-exported here so this file is the editor state's single import.
export 'vault_state.dart' show EditorStateValue, SaveStatus;

/// Editor controller — owns the debounced save state for the open note.
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

  void loadNote(Note? note) {
    _debounce?.cancel();
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
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
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
