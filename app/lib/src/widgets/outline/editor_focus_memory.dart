// The editor field that last had keyboard focus (#70, Spec #58 R30, TD8),
// so Esc in the Outline can hand focus back to it.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/editor_controller.dart';
import '../editor/segment_view.dart';
import '../editor/source_surface.dart';
import '../editor/text_segment.dart' show EditorScrollScope;

/// The note title field's Key.
const _titleKey = Key('editor-title');

/// The editor body's Key: the first text segment, or the Source field.
const _bodyKey = Key('editor-body');

/// Remembers the last editor field (the note title, a body text row, the
/// Source field) that had primary focus since the editor showed its note,
/// and gives focus back to it.
///
/// It tracks [FocusManager]'s primary focus while [attach]ed (the workspace's
/// `OutlineKeys` attaches it); focus elsewhere (the sidebar, the Outline)
/// leaves the memory as it is. The editor showing another note forgets it.
class EditorFocusMemory {
  EditorFocusMemory._(this._activeNoteId);

  /// The note the editor shows now.
  final String? Function() _activeNoteId;

  int _attached = 0;
  FocusNode? _field;
  String? _fieldNote;

  /// Starts tracking primary focus; pair with [detach].
  void attach() {
    if (_attached++ == 0) {
      FocusManager.instance.addListener(_onFocus);
      _onFocus();
    }
  }

  /// Stops tracking primary focus.
  void detach() {
    if (_attached == 0) return;
    if (--_attached == 0) FocusManager.instance.removeListener(_onFocus);
  }

  void _dispose() {
    if (_attached > 0) FocusManager.instance.removeListener(_onFocus);
    _attached = 0;
  }

  void _onFocus() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !_isEditorField(node)) return;
    _field = node;
    _fieldNote = _activeNoteId();
  }

  /// The editor shows another note: what was focused before is forgotten,
  /// unless an editor field still has focus.
  void _noteChanged() {
    _field = null;
    _fieldNote = null;
    if (_attached > 0) _onFocus();
  }

  /// The remembered field, if it is still in the tree, focusable and of the
  /// note the editor shows.
  FocusNode? get remembered {
    final node = _field;
    if (node == null || _fieldNote != _activeNoteId()) return null;
    final context = node.context;
    if (context == null || !context.mounted || !node.canRequestFocus) {
      return null;
    }
    return node;
  }

  /// Gives focus back to the remembered field, or else to the editor body's
  /// primary focus node, without changing that field's selection or
  /// scrolling the editor. False when there is neither.
  bool restore() {
    final node = remembered ?? _bodyNode();
    if (node == null) return false;
    _focusInPlace(node);
    return true;
  }

  /// Whether [node] is the focus node of an editor text field.
  static bool _isEditorField(FocusNode node) {
    final context = node.context;
    if (context == null || !context.mounted) return false;
    final editable = _editableOf(context);
    if (editable == null || !identical(editable.widget.focusNode, node)) {
      return false;
    }
    var inEditor = false;
    context.visitAncestorElements((e) {
      final w = e.widget;
      inEditor = w.key == _titleKey || w is SegmentView || w is SourceSurface;
      return !inEditor;
    });
    return inEditor;
  }

  static EditableTextState? _editableOf(BuildContext context) =>
      context is StatefulElement && context.state is EditableTextState
      ? context.state as EditableTextState
      : context.findAncestorStateOfType<EditableTextState>();

  /// The editor body's focus node: the first text segment's (which hands
  /// focus to the row holding its caret), or the Source field's.
  static FocusNode? _bodyNode() {
    Element? body;
    void visit(Element e) {
      if (body != null) return;
      if (e.widget.key == _bodyKey) {
        body = e;
      } else {
        e.visitChildren(visit);
      }
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final found = body;
    if (found == null) return null;
    final segment = found.findAncestorWidgetOfExactType<SegmentView>();
    if (segment != null) return segment.focusNode;
    EditableTextState? field;
    void visitField(Element e) {
      if (field != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        field = e.state as EditableTextState;
      } else {
        e.visitChildren(visitField);
      }
    }

    found.visitChildren(visitField);
    return field?.widget.focusNode;
  }

  /// Focuses [node] and undoes what gaining focus does to the field: a
  /// single line field selecting all (macOS) and the caret being scrolled
  /// into view. Focus may pass on (a segment node hands it to a row); this
  /// holds the editor page and the field's selection until two frames end.
  static void _focusInPlace(FocusNode node) {
    final context = node.context;
    final scroll = context
        ?.getInheritedWidgetOfExactType<EditorScrollScope>()
        ?.controller;
    final held = [
      if (scroll != null)
        for (final p in scroll.positions)
          if (p.hasPixels) (position: p, pixels: p.pixels),
    ];
    final editable = context == null ? null : _editableOf(context);
    final controller =
        editable != null && identical(editable.widget.focusNode, node)
        ? editable.widget.controller
        : null;
    final selection = controller?.selection;
    var done = false;

    void hold(Duration _) {
      for (final (:position, :pixels) in held) {
        if (!position.hasPixels) continue;
        if (position.pixels != pixels || position.isScrollingNotifier.value) {
          // Also cancels a caret reveal animation that has not moved yet.
          position.jumpTo(pixels);
        }
      }
    }

    void onFocus() {
      if (done) return;
      if (controller != null &&
          selection != null &&
          identical(FocusManager.instance.primaryFocus, node) &&
          controller.selection != selection) {
        controller.selection = selection;
      }
      // After the field's own post-frame caret reveal, which it scheduled
      // as it was notified (nodes hear of a focus change before the
      // manager's listeners).
      SchedulerBinding.instance.addPostFrameCallback(hold);
    }

    FocusManager.instance.addListener(onFocus);
    node.requestFocus();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        SchedulerBinding.instance
          ..addPostFrameCallback((d) {
            done = true;
            FocusManager.instance.removeListener(onFocus);
            hold(d);
          })
          ..ensureVisualUpdate();
      })
      ..ensureVisualUpdate();
  }
}

/// The app's [EditorFocusMemory]. It forgets the field when the editor
/// shows another note.
final editorFocusMemoryProvider = Provider<EditorFocusMemory>((ref) {
  String? active() => ref.read(editorControllerProvider.notifier).activeNoteId;
  final memory = EditorFocusMemory._(active);
  var shown = active();
  ref.listen<EditorStateValue>(editorControllerProvider, (_, _) {
    final now = active();
    if (now == shown) return;
    shown = now;
    memory._noteChanged();
  });
  ref.onDispose(memory._dispose);
  return memory;
});
