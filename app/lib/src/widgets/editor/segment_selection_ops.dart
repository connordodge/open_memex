import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../editor/editor_rows.dart';
import '../../editor/segment_selection.dart';
import 'segment_undo.dart';
import 'segment_view.dart';

/// Clipboard, IME and undo operations over one text segment's editor rows
/// (D8, Spec R27, R29, R30).
///
/// Over a segment selection that spans rows:
/// - Cmd+C copies the range's raw markdown (A4's `copyText`, D17), Cmd+X
///   copies it then deletes it (`deleteRange`), and Cmd+V replaces it with
///   the clipboard's text (`replaceRange`).
/// - A key that types text first deletes the range into the focused row,
///   keeping focus there, and leaves the key to the field (or the IME).
/// - A composition that starts deletes the range the same way (the host's
///   composing interceptor, D19).
/// - The right-click menu offers Copy, Cut, Paste and Select All; Select
///   All invokes the field's `SelectAllTextIntent` as Cmd+A does.
///
/// Within one row, copy, cut, paste and typing keep the field's own
/// behaviour. Cmd+Z and Shift+Cmd+Z undo and redo the whole segment through
/// its [SegmentUndoRecorder]. While the focused field composes, keys go to
/// the field unchanged. Every edit is a `SegmentEdit` applied through
/// [SegmentViewState.applyEdit] (D2).
class SegmentSelectionOps extends StatefulWidget {
  const SegmentSelectionOps({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  State<SegmentSelectionOps> createState() => _SegmentSelectionOpsState();
}

class _SegmentSelectionOpsState extends State<SegmentSelectionOps> {
  late final SegmentViewState _view = context
      .findAncestorStateOfType<SegmentViewState>()!;
  late final TextEditingController _segment = _view.widget.controller;
  final _menu = ContextMenuController();

  /// True while this applies an edit of its own.
  bool _own = false;

  /// The pointer of a secondary-button press, until it goes up.
  int? _secondary;

  late final Map<Type, Action<Intent>> _actions = {
    CopySelectionTextIntent: _AcrossAction<CopySelectionTextIntent>(
      _across,
      (intent) => intent.collapseSelection ? _cut() : _copy(),
    ),
    PasteTextIntent: _AcrossAction<PasteTextIntent>(
      _across,
      (_) => unawaited(_paste()),
    ),
    UndoTextIntent: CallbackAction<UndoTextIntent>(
      onInvoke: (_) => _replay(_view.undo.undo(_view.text)),
    ),
    RedoTextIntent: CallbackAction<RedoTextIntent>(
      onInvoke: (_) => _replay(_view.undo.redo(_view.text)),
    ),
  };

  @override
  void initState() {
    super.initState();
    _view
      ..rowComposingInterceptor = _intercept
      ..undo.origin = _origin;
    _segment.addListener(_hideMenu);
  }

  @override
  void dispose() {
    _segment.removeListener(_hideMenu);
    _view.rowComposingInterceptor = null;
    if (_view.undo.origin == _origin) _view.undo.origin = null;
    _view.undo.flush();
    _menu.remove();
    super.dispose();
  }

  List<RowSpec> _rows() => splitRows(_view.text, atSegmentStart: true);

  SegmentSelection _selection() => SegmentSelection(
    baseOffset: _view.selection.baseOffset,
    extentOffset: _view.selection.extentOffset,
  );

  /// Whether the segment selection's ends lie in different rows.
  bool _across() {
    final rows = _rows();
    final selection = _view.selection;
    return _rowOf(rows, selection.start) != _rowOf(rows, selection.end);
  }

  /// The focused row field.
  EditableTextState? _field() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();

  /// How the edit the host is recording was made.
  SegmentEditOrigin _origin() {
    final selection = _selection();
    final row = _view.focusedRow;
    final value = _field()?.textEditingValue;
    if (_own || row == null || value == null) {
      return (typed: false, composing: false, selection: selection);
    }
    final spec = _rows()[row];
    return (
      typed: value.text != _view.text.substring(spec.textStart, spec.textEnd),
      composing: !value.composing.isCollapsed,
      selection: selection,
    );
  }

  void _apply(SegmentEdit edit) {
    _own = true;
    try {
      _view.applyEdit(edit);
    } finally {
      _own = false;
    }
  }

  void _replay(SegmentEdit? edit) {
    if (edit != null) _view.undo.replay(() => _view.applyEdit(edit));
  }

  /// Deletes the selected range into the focused row; the typed edit that
  /// follows completes the same undo step.
  void _deleteForTyping() {
    _apply(deleteRange(_view.text, _rows(), _selection()));
    _view.undo.continueWithTyping();
  }

  void _copy() {
    unawaited(
      Clipboard.setData(
        ClipboardData(text: copyText(_view.text, _selection())),
      ),
    );
  }

  void _cut() {
    _copy();
    _apply(deleteRange(_view.text, _rows(), _selection()));
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    _apply(replaceRange(_view.text, _rows(), _selection(), text));
  }

  void _selectAll() {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null) {
      Actions.maybeInvoke(
        focus,
        const SelectAllTextIntent(SelectionChangedCause.toolbar),
      );
    }
  }

  /// The host's composing interceptor (D19): a composition starts over a
  /// selection that spans rows.
  bool _intercept(int rowIndex, TextEditingValue value) {
    _deleteForTyping();
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      _view.undo.endTyping();
    } else if (_typesText(event) &&
        !(_field()?.textEditingValue.composing.isValid ?? true) &&
        _across()) {
      _deleteForTyping();
    }
    return KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    _secondary = event.buttons & kSecondaryButton != 0 ? event.pointer : null;
  }

  /// A right click went up: once the field has shown its own menu, this
  /// replaces it while the selection spans rows.
  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _secondary) return;
    _secondary = null;
    final at = event.position;
    scheduleMicrotask(() {
      if (mounted && _across()) _showMenu(at);
    });
  }

  void _showMenu(Offset at) {
    ContextMenuButtonItem item(
      ContextMenuButtonType type,
      void Function() run,
    ) => ContextMenuButtonItem(
      type: type,
      onPressed: () {
        _hideMenu();
        run();
      },
    );
    _menu.show(
      context: context,
      contextMenuBuilder: (context) => TextFieldTapRegion(
        child: AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: at),
          buttonItems: [
            item(ContextMenuButtonType.copy, _copy),
            item(ContextMenuButtonType.cut, _cut),
            item(ContextMenuButtonType.paste, _paste),
            item(ContextMenuButtonType.selectAll, _selectAll),
          ],
        ),
      ),
    );
  }

  void _hideMenu() => _menu.remove();

  @override
  Widget build(BuildContext context) => Actions(
    actions: _actions,
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (!focused) _hideMenu();
      },
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: widget.child,
      ),
    ),
  );
}

/// Whether [event] types text into a field: a printable character without
/// Cmd or Control.
bool _typesText(KeyEvent event) {
  final character = event.character;
  final keys = HardwareKeyboard.instance;
  if (character == null || keys.isMetaPressed || keys.isControlPressed) {
    return false;
  }
  return character.runes.every(
    (c) => c >= 0x20 && c != 0x7F && (c < 0xF700 || c > 0xF8FF),
  );
}

/// The index of the row holding segment [offset], as the rows host counts
/// it: the first row ending after it, or the last row.
int _rowOf(List<RowSpec> rows, int offset) {
  for (var i = 0; i < rows.length; i++) {
    if (offset < rows[i].end) return i;
  }
  return rows.length - 1;
}

/// An override of a row field's clipboard action (TD6): over a selection
/// that spans rows it runs [run], else the field's own action.
class _AcrossAction<T extends Intent> extends ContextAction<T> {
  _AcrossAction(this.across, this.run);

  final bool Function() across;
  final void Function(T intent) run;

  @override
  bool isEnabled(T intent, [BuildContext? context]) =>
      across() || (callingAction?.isEnabled(intent) ?? false);

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    if (across()) {
      run(intent);
      return null;
    }
    final native = callingAction;
    return native is ContextAction<T>
        ? native.invoke(intent, context)
        : native?.invoke(intent);
  }
}
