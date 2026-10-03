import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../state/editor_controller.dart';
import '../state/note_poller_state.dart';
import '../state/tabs_state.dart' show VirtualTodayTab;
import '../state/today_state.dart';
import '../state/topic_actions.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';
import 'editor/editor_toolbar.dart';
import 'editor/note_header.dart';
import 'editor/note_menu.dart';
import 'editor/segmented_body.dart';
import 'editor/source_surface.dart';

/// The note editor host: wires the selected note and [EditorController] into
/// the [EditorToolbar], the body (with its [NoteHeader]) and the save status
/// bar.
///
/// The body is the [SegmentedBody] by default; the toolbar's `Source` toggle
/// switches it to the single plain [SourceSurface] field and back (WI #27).
/// Opening another note starts in the segmented view again.
///
/// The selected note comes from [editorNoteProvider], so a virtual Today tab
/// (#22) shows as an empty, unsaved daily note. Opening a daily note puts
/// the cursor at the end of its focused body, ready to type.
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
  final _bodyFocus = FocusNode(debugLabel: 'editor-body');
  String? _hydratedFor;

  /// The note the body was last hydrated for (see [_hydrate]).
  Note? _hydratedNote;

  /// Which body the editor shows; [_BodyView.segmented] for every newly
  /// opened note.
  _BodyView _view = _BodyView.segmented;

  bool get _sourceMode => _view == _BodyView.source;

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
    _bodyFocus.dispose();
    super.dispose();
  }

  void _hydrate(Note? note, EditorController controller) {
    if (note?.id == _hydratedFor) return;
    _hydratedFor = note?.id;
    _hydratedNote = note;
    // A virtual Today note that just became [note] keeps the editor's text
    // (typing may still be going on); any other note loads, in the
    // segmented view.
    final resolved = note != null && controller.takeResolved(note.id);
    if (!resolved) {
      controller.loadNote(note);
      _view = _BodyView.segmented;
    }
    // Rebuild with the hydrated note (this may run outside a build).
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
    final editor = ref.read(editorControllerProvider);
    _titleCtrl.text = editor.title;
    if (_bodyCtrl.text != editor.contentMd) {
      _bodyCtrl.value = TextEditingValue(
        text: editor.contentMd,
        selection: TextSelection.collapsed(offset: editor.contentMd.length),
      );
    }
    if (!resolved && note?.role == 'daily') {
      _bodyCtrl.selection = TextSelection.collapsed(
        offset: _bodyCtrl.text.length,
      );
      _bodyFocus.requestFocus();
    }
  }

  /// Switches the body between the segmented view and Source. Source starts
  /// from the editor's current markdown; coming back re-splits it.
  void _toggleSource() {
    final content = ref.read(editorControllerProvider).contentMd;
    setState(() {
      _view = _sourceMode ? _BodyView.segmented : _BodyView.source;
      if (_sourceMode) {
        _bodyCtrl.value = TextEditingValue(
          text: content,
          selection: TextSelection.collapsed(offset: content.length),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final note = ref.watch(editorNoteProvider);
    final editor = ref.watch(editorControllerProvider);
    final controller = ref.read(editorControllerProvider.notifier);
    final vaultPath = ref.watch(currentVaultProvider);
    // Polls the open daily note for server writes while it is the active
    // tab (WI #28).
    ref.watch(notePollerProvider);

    ref.listen<Note?>(
      editorNoteProvider,
      (_, curr) => _hydrate(curr, controller),
    );
    if (note != null && _hydratedFor != note.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hydrate(note, controller);
      });
    }

    final header = note == null
        ? null
        : NoteHeader(
            note: note,
            titleCtrl: _titleCtrl,
            onTitleChanged: controller.onTitleChanged,
          );

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
            sourceMode: _sourceMode,
            onToggleSource: note == null ? null : _toggleSource,
          ),
          const OmHairline(),
          if (note != null) NoteDeleteError(noteId: note.id),
          Expanded(
            child: note == null
                ? _EmptyEditor()
                : _sourceMode
                ? SourceSurface(
                    bodyCtrl: _bodyCtrl,
                    bodyFocusNode: _bodyFocus,
                    onContentChanged: controller.onContentChanged,
                    errorMessage: editor.errorMessage,
                    header: header,
                    dailyNoteId:
                        note.role == 'daily' &&
                            VirtualTodayTab.dateOf(note.id) == null
                        ? note.id
                        : null,
                    onTopicLinked: (version) => rebaseEditorOnVersion(
                      ref,
                      fallback: note,
                      version: version,
                      content: _bodyCtrl.text,
                    ),
                  )
                : SegmentedBody(
                    // Until the post-frame hydrate loads a newly selected
                    // note, the editor still holds the previous note's text:
                    // keep the body on the note that text belongs to.
                    note: _hydratedNote ?? note,
                    content: editor.contentMd,
                    savedVersion: editor.lastSavedVersion,
                    onContentChanged: controller.onContentChanged,
                    primaryFocusNode: _bodyFocus,
                    errorMessage: editor.errorMessage,
                    onDismissError: controller.dismissError,
                    header: header,
                  ),
          ),
          const OmHairline(),
          _StatusBar(status: editor.status),
        ],
      ),
    );
  }
}

/// The editor body: the segmented view (default) or the single Source field.
enum _BodyView { segmented, source }

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
