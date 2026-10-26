import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_edits.dart';
import '../inline_error.dart';
import 'text_segment.dart';

/// The plain markdown editing surface (Key `editor-source-surface`): a
/// scrolling page with [header] above one multi-line body `TextField`
/// (Key `editor-body`), plus wikilink autocomplete and the inline kind chip.
///
/// Every change to [bodyCtrl] (typed or spliced in by autocomplete or the
/// kind chip) is reported through [onContentChanged].
class SourceSurface extends StatefulWidget {
  const SourceSurface({
    super.key,
    required this.bodyCtrl,
    required this.onContentChanged,
    this.header,
    this.errorMessage,
    this.bodyFocusNode,
    this.dailyNoteId,
    this.onTopicLinked,
  });
  final TextEditingController bodyCtrl;
  final ValueChanged<String> onContentChanged;

  /// Shown above the body, inside the same scroll view.
  final Widget? header;

  /// Save error shown just above the body.
  final String? errorMessage;

  /// The body field's focus node, when the host moves focus to the body
  /// (e.g. on launch, #22). Owned by the host; one is made here otherwise.
  final FocusNode? bodyFocusNode;

  /// The saved daily note being edited, else null: `[[` autocomplete create
  /// then links the new topic from its footer (see
  /// [TextSegmentField.dailyNoteId]).
  final String? dailyNoteId;

  /// Called with the daily note's new version after its footer chip was
  /// added.
  final void Function(int version)? onTopicLinked;

  @override
  State<SourceSurface> createState() => _SourceSurfaceState();
}

class _SourceSurfaceState extends State<SourceSurface> {
  final _kindChips = KindChipHost();

  /// The CLI message of a failed autocomplete create in a daily note.
  String? _createError;

  @override
  void dispose() {
    _kindChips.dispose();
    super.dispose();
  }

  /// Enter in the body (Spec R31): continues a list line through
  /// [sourceEnter] as one controller value change, so it's one undo step
  /// and [SourceSurface.onContentChanged] reports it. Ignored (the platform
  /// inserts a plain newline) for Shift+Enter, a line that doesn't continue,
  /// a modified Enter and while the IME composes.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final value = widget.bodyCtrl.value;
    if (value.composing.isValid || !value.selection.isValid) {
      return KeyEventResult.ignored;
    }
    final edit = sourceEnter(
      value.text,
      SegmentSelection(
        baseOffset: value.selection.baseOffset,
        extentOffset: value.selection.extentOffset,
      ),
      shift: keys.isShiftPressed,
    );
    if (edit == null) return KeyEventResult.ignored;
    final caret = edit.selection!;
    widget.bodyCtrl.value = TextEditingValue(
      text: edit.apply(value.text),
      selection: TextSelection(
        baseOffset: caret.baseOffset,
        extentOffset: caret.extentOffset,
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      key: const Key('editor-source-surface'),
      header: widget.header,
      errorMessage: widget.errorMessage,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_createError case final message?)
            InlineError(
              message: message,
              onDismiss: () => setState(() => _createError = null),
            ),
          KeyedSubtree(
            key: const Key('editor-body'),
            // List continuation (R31, D15): an ancestor of the field's own
            // node, so the `[[` popover sees Enter first.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: TextSegmentField(
                controller: widget.bodyCtrl,
                focusNode: widget.bodyFocusNode,
                onChanged: widget.onContentChanged,
                kindChips: _kindChips,
                minLines: 12,
                hintText: 'type [[ to link a note · write markdown…',
                dailyNoteId: widget.dailyNoteId,
                onTopicLinked: widget.onTopicLinked,
                onCreateError: (message) {
                  if (mounted) setState(() => _createError = message);
                },
              ),
            ),
          ),
        ],
      ),
      overlays: [KindChipLayer(host: _kindChips)],
    );
  }
}
