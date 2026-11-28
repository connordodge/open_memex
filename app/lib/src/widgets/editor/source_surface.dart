import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/editor_rows.dart';
import '../../editor/find_in_note.dart';
import '../../editor/list_indent.dart';
import '../../editor/row_edits.dart';
import '../../state/find_in_note_state.dart';
import '../../state/paste_or_attach.dart';
import '../../state/spell_check_controller.dart';
import '../find/find_highlights.dart';
import '../find/find_keys.dart';
import '../inline_error.dart';
import 'line_boxes.dart';
import 'spell_check_host.dart';
import 'spell_issue_scope.dart';
import 'spelling_menu.dart' show spellingIssueAtSelection;
import 'spell_squiggles.dart';
import 'text_segment.dart';

/// The plain markdown editing surface (Key `editor-source-surface`): a
/// scrolling page with [header] above one multi-line body `TextField`
/// (Key `editor-body`), plus wikilink autocomplete and the inline kind chip.
///
/// Every change to [bodyCtrl] (typed or spliced in by autocomplete or the
/// kind chip) is reported through [onContentChanged].
///
/// Every Paste in the body (Cmd+V, the right-click Paste, the spelling
/// menu's Paste) goes through `pasteOrAttach` (WI #147, D11), with the
/// field's own paste as its text paste. A right click on the body, off a
/// flagged word, shows the field's menu items with Paste enabled
/// ([pasteMenuItems]) in place of its own menu while the clipboard holds
/// file URLs or an image (lead ruling Q3). The header's fields keep their
/// own paste.
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
    this.noteId,
    this.noteRole,
    this.active = true,
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

  /// The note being edited and its role (WI #436): its body is spell
  /// checked, the Note footer excluded. Null: no spell checking.
  final String? noteId;
  final String? noteRole;

  /// Whether this surface belongs to the active editor (#61 F3, F6 wires
  /// it): the Source field's find highlights (Key `find-highlights-source`)
  /// paint only while true.
  final bool active;

  @override
  State<SourceSurface> createState() => _SourceSurfaceState();
}

class _SourceSurfaceState extends State<SourceSurface> {
  final _kindChips = KindChipHost();

  /// Holds the body field, whose line boxes the find highlights measure.
  final _fieldKey = GlobalKey(debugLabel: 'editor-source-field');

  /// This note editor's spelling issues, per row field (WI #434).
  final _spellIssues = SpellIssueRegistry();

  /// The CLI message of a failed autocomplete create in a daily note.
  String? _createError;

  /// The body's right-click menu with Paste enabled (Q3).
  final _menu = ContextMenuController();

  /// The pointer of a secondary-button press on the body, until it goes up.
  int? _secondary;

  /// Bumped by every press on the body: a right click's menu still waiting
  /// for the clipboard then shows nothing.
  int _presses = 0;

  late final Map<Type, Action<Intent>> _pasteActions = {
    PasteTextIntent: _SourcePasteAction((pasteText) {
      unawaited(pasteOrAttach(context, pasteText: pasteText));
    }),
  };

  @override
  void initState() {
    super.initState();
    widget.bodyCtrl.addListener(_hideMenu);
  }

  @override
  void didUpdateWidget(SourceSurface old) {
    super.didUpdateWidget(old);
    if (old.bodyCtrl != widget.bodyCtrl) {
      old.bodyCtrl.removeListener(_hideMenu);
      widget.bodyCtrl.addListener(_hideMenu);
    }
  }

  @override
  void dispose() {
    widget.bodyCtrl.removeListener(_hideMenu);
    _menu.remove();
    _kindChips.dispose();
    super.dispose();
  }

  void _hideMenu() => _menu.remove();

  void _onPointerDown(PointerDownEvent event) {
    _presses++;
    _secondary = event.buttons & kSecondaryButton != 0 ? event.pointer : null;
  }

  /// A right click on the body went up: once the field has shown its own
  /// menu, [_offerAttachPaste] may replace it.
  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _secondary) return;
    _secondary = null;
    final at = event.position;
    scheduleMicrotask(() {
      if (mounted) unawaited(_offerAttachPaste(at));
    });
  }

  /// Q3: with file URLs or an image on the clipboard and a vault that can
  /// be written, a right click at global [at] on the focused body field,
  /// off a flagged word (SpellingMenu wins), shows the field's items with
  /// Paste enabled. Nothing changes with text only or an empty clipboard,
  /// or once another press came.
  Future<void> _offerAttachPaste(Offset at) async {
    final press = _presses;
    if (!await pasteAttachesFiles(context)) return;
    if (!mounted || press != _presses) return;
    final focus = FocusManager.instance.primaryFocus?.context;
    final field = focus?.findAncestorStateOfType<EditableTextState>();
    if (field == null ||
        field.widget.controller != widget.bodyCtrl ||
        spellingIssueAtSelection(field) != null) {
      return;
    }
    _menu.show(
      context: context,
      contextMenuBuilder: (context) => TextFieldTapRegion(
        onTapOutside: (_) => _hideMenu(),
        child: AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: at),
          buttonItems: pasteMenuItems(field, hide: _hideMenu),
        ),
      ),
    );
  }

  /// Enter and Tab in the body. Enter (Spec R31): continues a list line through
  /// [sourceEnter] as one controller value change, so it's one undo step
  /// and [SourceSurface.onContentChanged] reports it. Ignored (the platform
  /// inserts a plain newline) for Shift+Enter, a line that doesn't continue,
  /// a modified Enter and while the IME composes.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isTab = event.logicalKey == LogicalKeyboardKey.tab;
    if (!isTab &&
        event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final value = widget.bodyCtrl.value;
    if (value.composing.isValid) {
      // Spec #193 R7: while composing, Tab and Shift+Tab go to the IME
      // unchanged. Skipping the remaining handlers keeps the app's default
      // Tab (focus traversal) from taking the key and ending the composition.
      return isTab
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }
    if (!value.selection.isValid) return KeyEventResult.ignored;
    if (isTab) return _onTab(value, outdent: keys.isShiftPressed);
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

  /// Tab and Shift+Tab on list lines (Spec R-rules): indents or outdents
  /// the touched items as one controller value change. Handled even when
  /// the edit is null (first item, already top level) so focus stays in the
  /// body; ignored off list lines so Flutter's default Tab applies.
  KeyEventResult _onTab(TextEditingValue value, {required bool outdent}) {
    final selection = SegmentSelection(
      baseOffset: value.selection.baseOffset,
      extentOffset: value.selection.extentOffset,
    );
    if (!touchesListItem(value.text, selection, source: true)) {
      return KeyEventResult.ignored;
    }
    final edit = indentListItems(
      value.text,
      selection,
      outdent: outdent,
      source: true,
    );
    if (edit == null) return KeyEventResult.handled;
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

  /// The page under this note's spell checks (WI #436).
  @override
  Widget build(BuildContext context) {
    final noteId = widget.noteId;
    if (noteId == null) return _page(context);
    return SpellCheckHost(
      noteId: noteId,
      registry: _spellIssues,
      footerStartOf: (text) => spellFooterStart(text, role: widget.noteRole),
      child: _page(context),
    );
  }

  Widget _page(BuildContext context) {
    return SpellIssueScope(
      registry: _spellIssues,
      child: EditorPage(
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
              // Every Paste in the body goes through pasteOrAttach (D11).
              child: Actions(
                actions: _pasteActions,
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerUp: _onPointerUp,
                  // List continuation (R31, D15): an ancestor of the field's
                  // own node, so the `[[` popover sees Enter first.
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    onFocusChange: (focused) {
                      if (!focused) _hideMenu();
                    },
                    child: SpellCheckField(
                      controller: widget.bodyCtrl,
                      // Spelling squiggles and hint (WI #437).
                      child: SpellSquiggles(
                        controller: widget.bodyCtrl,
                        // Find highlights under the field (#61 F3, Req 28).
                        child: Stack(
                          fit: StackFit.passthrough,
                          children: [
                            Positioned.fill(child: _findHighlights()),
                            KeyedSubtree(
                              key: _fieldKey,
                              child: TextSegmentField(
                                controller: widget.bodyCtrl,
                                focusNode: widget.bodyFocusNode,
                                onChanged: widget.onContentChanged,
                                kindChips: _kindChips,
                                minLines: 12,
                                hintText:
                                    'type [[ to link a note · write markdown…',
                                dailyNoteId: widget.dailyNoteId,
                                onTopicLinked: widget.onTopicLinked,
                                onCreateError: (message) {
                                  if (mounted) {
                                    setState(() => _createError = message);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        overlays: [KindChipLayer(host: _kindChips)],
      ),
    );
  }

  /// The Source field's find highlights (Key `find-highlights-source`):
  /// every match a fill, nothing hidden (Req 2); nothing while not active.
  Widget _findHighlights() => Consumer(
    builder: (context, ref, _) {
      final state = ref.watch(findInNoteProvider);
      return FindHighlights(
        key: findSourceHighlightsKey,
        ranges: widget.active
            ? findPaintRanges(
                state,
                segment: 0,
                kind: FindSourceKind.source,
                start: 0,
                end: widget.bodyCtrl.text.length,
              )
            : const [],
        boxes: _fieldBoxes,
        repaint: widget.bodyCtrl,
      );
    },
  );

  /// The body field's line boxes once it is laid out.
  LineBoxSource? _fieldBoxes() =>
      sourceFieldLineBoxes(_fieldKey.currentContext?.findRenderObject());
}

/// The Source field's line boxes once it is laid out, from the render
/// object [root] at or above it (WI #127: Source mode's one field is no
/// editor row, so its geometry comes from here, never from the row
/// accessor); null before.
RenderEditableLineBoxes? sourceFieldLineBoxes(RenderObject? root) {
  final editable = findRenderEditable(root);
  return editable != null && editable.hasSize
      ? RenderEditableLineBoxes(editable)
      : null;
}

/// The Source body's `PasteTextIntent` override (D11): every Paste runs
/// [paste] with the field's own paste as its text paste.
class _SourcePasteAction extends ContextAction<PasteTextIntent> {
  _SourcePasteAction(this.paste);

  final void Function(FutureOr<void> Function() pasteText) paste;

  @override
  bool isEnabled(PasteTextIntent intent, [BuildContext? context]) =>
      callingAction?.isEnabled(intent) ?? false;

  @override
  Object? invoke(PasteTextIntent intent, [BuildContext? context]) {
    final native = callingAction;
    if (native == null) return null;
    paste(() {
      if (native is ContextAction<PasteTextIntent>) {
        native.invoke(intent, context);
      } else {
        native.invoke(intent);
      }
    });
    return null;
  }
}
