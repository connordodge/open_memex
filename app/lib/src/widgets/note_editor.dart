import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../state/editor_controller.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';
import 'editor/editor_toolbar.dart';
import 'editor/note_header.dart';
import 'editor/note_menu.dart';
import 'editor/source_surface.dart';

/// The note editor host: wires the selected note and [EditorController] into
/// the [EditorToolbar], the [SourceSurface] (with its [NoteHeader]) and the
/// save status bar.
class NoteEditor extends ConsumerStatefulWidget {
  const NoteEditor({
    super.key,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
    this.onBackToCanvas,
  });
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  /// When non-null, the editor is shown zoomed-in from a canvas. The toolbar
  /// renders a "← back to canvas" affordance that invokes this.
  final VoidCallback? onBackToCanvas;

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
    final vaultPath = ref.watch(currentVaultProvider);

    ref.listen<Note?>(
      selectedNoteProvider,
      (_, curr) => _hydrate(curr, controller),
    );
    if (note != null && _hydratedFor != note.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hydrate(note, controller);
      });
    }

    // Returns a plain Container (not Expanded): each call site places this in
    // its own flex/bounded parent (workspace `_TabBody` inside an Expanded,
    // `_ZoomedNoteView` inside a Positioned.fill). Rooting in Expanded here
    // caused two competing FlexParentData widgets on the same RenderObject.
    return Container(
      color: OmColors.surface2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EditorToolbar(
            note: note,
            vaultPath: vaultPath,
            status: editor.status,
            rightOpen: widget.rightPanelOpen,
            onToggleRight: widget.onToggleRightPanel,
            onBackToCanvas: widget.onBackToCanvas,
          ),
          const OmHairline(),
          if (note != null) NoteDeleteError(noteId: note.id),
          Expanded(
            child: note == null
                ? _EmptyEditor()
                : SourceSurface(
                    bodyCtrl: _bodyCtrl,
                    onContentChanged: controller.onContentChanged,
                    errorMessage: editor.errorMessage,
                    header: NoteHeader(
                      note: note,
                      titleCtrl: _titleCtrl,
                      onTitleChanged: controller.onTitleChanged,
                    ),
                  ),
          ),
          const OmHairline(),
          _StatusBar(status: editor.status),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status});
  final SaveStatus status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SaveStatus.idle => ('idle', OmColors.fg3),
      SaveStatus.dirty => ('unsaved', OmColors.warn),
      SaveStatus.saving => ('saving…', OmColors.fg2),
      SaveStatus.clean => ('synced', OmColors.accent),
      SaveStatus.error => ('save failed', OmColors.danger),
      SaveStatus.conflict => ('conflict', OmColors.danger),
    };
    return Container(
      key: const Key('save-indicator'),
      height: 26,
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          OmDot(color: color, size: 5, pulse: status == SaveStatus.saving),
          const SizedBox(width: 5),
          Text(
            label,
            style: OmType.mono(size: 10.5, color: color, letterSpacing: 0.2),
          ),
          const SizedBox(width: 10),
          Text('·', style: OmType.mono(size: 11, color: OmColors.fg4)),
          const SizedBox(width: 10),
          Text('md', style: OmType.mono(size: 10.5, color: OmColors.fg3)),
          const Spacer(),
          Text(
            'agents API · ⌘;',
            style: OmType.mono(size: 10.5, color: OmColors.fg2),
          ),
        ],
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'select a note from the sidebar',
            style: OmType.mono(size: 12, color: OmColors.fg3),
          ),
          const SizedBox(height: 12),
          Text(
            'or press ⌘N to create a new one',
            style: OmType.mono(size: 11, color: OmColors.fg4),
          ),
        ],
      ),
    );
  }
}
