// Shared test seam (#159, D16, TS7): macOS editing primitives for keyboard,
// selection, pointer, IME and clipboard tests. Self-tested in
// test/seams/mac_editing_test.dart. Frozen after #159: a later WI keeps any
// extra primitive private to its own test files.
//
// Run every keyboard, selection and pointer test under [macOnly]: on macOS
// Flutter leaves most editing keys to the platform's selectors, so a test
// sends the selector the platform would ([macSelector]).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run a `testWidgets` only with `defaultTargetPlatform` = macOS.
final macOnly = TargetPlatformVariant.only(TargetPlatform.macOS);

/// macOS editing primitives on a [WidgetTester].
extension MacEditing on WidgetTester {
  /// Send the macOS text-system selector [selector] (e.g. `deleteBackward:`,
  /// `moveLeftAndModifySelection:`, `insertNewline:`) to the focused text
  /// field, as the platform does for an editing key, and pump.
  Future<void> macSelector(String selector) async {
    final context = FocusManager.instance.primaryFocus?.context;
    final editable = context == null
        ? null
        : context is StatefulElement && context.state is EditableTextState
        ? context.state as EditableTextState
        : context.findAncestorStateOfType<EditableTextState>();
    if (editable == null) {
      throw TestFailure('macSelector($selector): no text field has focus');
    }
    editable.performSelector(selector);
    await pump();
  }

  /// Hold [keys] down (in order) while [body] runs, then release them (in
  /// reverse order) and pump.
  Future<T> macHolding<T>(
    List<LogicalKeyboardKey> keys,
    Future<T> Function() body,
  ) async {
    for (final k in keys) {
      await sendKeyDownEvent(k, platform: 'macos');
    }
    try {
      return await body();
    } finally {
      for (final k in keys.reversed) {
        await sendKeyUpEvent(k, platform: 'macos');
      }
      await pump();
    }
  }

  /// Press [key] with Cmd (and Shift / Option when asked) held, e.g.
  /// Cmd+A, Cmd+Shift+Z.
  Future<void> macCmdChord(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) => macHolding([
    LogicalKeyboardKey.metaLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ], () => sendKeyEvent(key, platform: 'macos'));

  /// Press [key] with Shift held (e.g. Shift+Left), as a key event.
  Future<void> macShiftKey(LogicalKeyboardKey key) => macHolding([
    LogicalKeyboardKey.shiftLeft,
  ], () => sendKeyEvent(key, platform: 'macos'));

  /// A primary mouse click at global [at], with Cmd and/or Shift held
  /// while it happens (Cmd+click, Shift+click), then pump.
  Future<void> macClick(Offset at, {bool cmd = false, bool shift = false}) =>
      macHolding([
        if (cmd) LogicalKeyboardKey.metaLeft,
        if (shift) LogicalKeyboardKey.shiftLeft,
      ], () => tapAt(at, kind: PointerDeviceKind.mouse));

  /// Cmd+click at global [at].
  Future<void> macCmdClick(Offset at) => macClick(at, cmd: true);

  /// Move a mouse to global [at] (no button down), pump, and return the
  /// mouse cursor the app shows there. The mouse is removed afterwards.
  Future<MouseCursor?> macCursorAt(Offset at) async {
    final mouse = await createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: at);
    try {
      await pump();
      await mouse.moveTo(at);
      await pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    } finally {
      await mouse.removePointer();
      await pump();
    }
  }

  /// A primary-button mouse drag from global [from] to global [to] in
  /// [steps] moves (pumping after each), with Shift held when asked.
  Future<void> macDrag(
    Offset from,
    Offset to, {
    int steps = 4,
    bool shift = false,
  }) => macHolding([if (shift) LogicalKeyboardKey.shiftLeft], () async {
    final mouse = await startGesture(from, kind: PointerDeviceKind.mouse);
    await pump();
    for (var i = 1; i <= steps; i++) {
      await mouse.moveTo(Offset.lerp(from, to, i / steps)!);
      await pump();
    }
    await mouse.up();
    await pump();
  });

  /// A mouse drag from the centre of [from] to the centre of [to] (e.g. two
  /// rows' rects).
  Future<void> macDragAcross(Rect from, Rect to, {int steps = 4}) =>
      macDrag(from.center, to.center, steps: steps);

  /// The platform's text input sends [text] with [selection] (default: the
  /// caret at its end) and [composing] (default: none) to the focused field,
  /// as typing or an IME does, then pumps.
  Future<void> macEditingValue(
    String text, {
    TextSelection? selection,
    TextRange composing = TextRange.empty,
  }) async {
    testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: selection ?? TextSelection.collapsed(offset: text.length),
        composing: composing,
      ),
    );
    await pump();
  }

  /// An IME composition: the focused field's text becomes [text] with the
  /// marked (composing) range [composing] and the caret at its end.
  Future<void> macCompose(String text, TextRange composing) => macEditingValue(
    text,
    selection: TextSelection.collapsed(offset: composing.end),
    composing: composing,
  );
}

/// A fake macOS pasteboard behind `SystemChannels.platform`'s
/// `Clipboard.setData` / `Clipboard.getData` / `Clipboard.hasStrings`.
/// [MacClipboard.install] replaces the handler for the current test and
/// removes it at teardown.
class MacClipboard {
  MacClipboard._();

  /// The pasteboard's plain text; null when empty.
  String? text;

  /// Every `Clipboard.setData` text, in order.
  final List<String?> writes = [];

  /// Install a fresh fake pasteboard holding [initial].
  static MacClipboard install(WidgetTester tester, {String? initial}) {
    final clip = MacClipboard._()..text = initial;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          final data = call.arguments as Map<Object?, Object?>;
          clip.text = data['text'] as String?;
          clip.writes.add(clip.text);
          return null;
        case 'Clipboard.getData':
          final text = clip.text;
          return text == null ? null : <String, Object?>{'text': text};
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': clip.text?.isNotEmpty ?? false};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return clip;
  }
}
