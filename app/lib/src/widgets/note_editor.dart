import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import '../state/vault_state.dart';

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
    state = state.copyWith(
      title: value,
      status: SaveStatus.dirty,
      clearError: true,
    );
    _scheduleSave();
  }

  void onContentChanged(String value) {
    if (_activeNoteId == null) return;
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
      if (_activeNoteId != id) return; // user switched notes mid-save
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

class NoteEditor extends ConsumerStatefulWidget {
  const NoteEditor({super.key});

  @override
  ConsumerState<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<NoteEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  String? _hydratedFor;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _bodyCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _hydrate(Note? note, EditorController controller) {
    if (note?.id == _hydratedFor) return;
    _hydratedFor = note?.id;
    controller.loadNote(note);
    _titleCtrl.text = note?.title ?? '';
    _bodyCtrl.text = note?.contentMd ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final note = ref.watch(selectedNoteProvider);
    final editor = ref.watch(editorControllerProvider);
    final controller = ref.read(editorControllerProvider.notifier);

    // Sync controllers when the selected note changes after first frame.
    ref.listen<Note?>(
      selectedNoteProvider,
      (_, curr) => _hydrate(curr, controller),
    );

    // Initial-mount hydration (ref.listen doesn't fire for the existing value).
    if (note != null && _hydratedFor != note.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hydrate(note, controller);
      });
    }

    if (note == null) {
      return const Center(child: Text('Select a note from the sidebar.'));
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('editor-title'),
            controller: _titleCtrl,
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Title',
            ),
            onChanged: controller.onTitleChanged,
          ),
          const SizedBox(height: 8),
          if (note.tags.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: note.tags
                  .map(
                    (t) => Chip(
                      label: Text(t),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 12),
          if (editor.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                editor.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: TextField(
              key: const Key('editor-content'),
              controller: _bodyCtrl,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 14,
                height: 1.4,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Write markdown…',
              ),
              onChanged: controller.onContentChanged,
            ),
          ),
        ],
      ),
    );
  }
}
