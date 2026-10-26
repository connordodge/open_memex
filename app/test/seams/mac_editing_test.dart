// WI #159 (D16, TS7): self-test of the shared macOS editing helper
// (test/support/mac_editing.dart). Every primitive is exercised against a
// plain widget, so a later WI can trust it: selector keys, Cmd chords,
// Cmd+click and Shift+click, the hover cursor, drags, typing and IME
// composition, and the clipboard.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mac_editing.dart';

class _Wi159ChordIntent extends Intent {
  const _Wi159ChordIntent();
}

/// A focused text field holding [controller], alone on the screen.
Future<void> _wi159PumpField(
  WidgetTester tester,
  TextEditingController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextField(
          key: const Key('field'),
          controller: controller,
          autofocus: true,
          maxLines: null,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('macSelector sends a macOS selector to the focused field', (
    tester,
  ) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await _wi159PumpField(tester, controller);
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();

    await tester.macSelector('deleteBackward:');
    expect(controller.text, 'ab');

    await tester.macSelector('moveLeftAndModifySelection:');
    expect(
      controller.selection,
      const TextSelection(baseOffset: 2, extentOffset: 1),
    );
  }, variant: macOnly);

  testWidgets('macSelector fails the test when no text field has focus', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await expectLater(
      tester.macSelector('deleteBackward:'),
      throwsA(isA<TestFailure>()),
    );
  }, variant: macOnly);

  testWidgets('a Cmd chord from macCmdChord reaches a Shortcuts binding', (
    tester,
  ) async {
    var plain = 0;
    var withShift = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                _Wi159ChordIntent(),
            SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true):
                DoNothingAndStopPropagationIntent(),
          },
          child: Actions(
            actions: {
              _Wi159ChordIntent: CallbackAction<_Wi159ChordIntent>(
                onInvoke: (_) => plain++,
              ),
              DoNothingAndStopPropagationIntent:
                  CallbackAction<DoNothingAndStopPropagationIntent>(
                    onInvoke: (_) => withShift++,
                  ),
            },
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.macCmdChord(LogicalKeyboardKey.keyK);
    expect(plain, 1);
    expect(withShift, 0);

    await tester.macCmdChord(LogicalKeyboardKey.keyK, shift: true);
    expect(plain, 1);
    expect(withShift, 1);

    // Nothing stays held after a chord.
    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
  }, variant: macOnly);

  testWidgets('macShiftKey presses a key with Shift held', (tester) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await _wi159PumpField(tester, controller);
    final seen = <Set<LogicalKeyboardKey>>[];
    bool record(KeyEvent e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyQ) {
        seen.add({...HardwareKeyboard.instance.logicalKeysPressed});
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(record);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(record));

    await tester.macShiftKey(LogicalKeyboardKey.keyQ);

    expect(seen, hasLength(1));
    expect(seen.single, contains(LogicalKeyboardKey.shiftLeft));
    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
  }, variant: macOnly);

  testWidgets(
    'Cmd+click from macCmdClick reports metaLeft pressed during the click',
    (tester) async {
      final pressedAtTap = <Set<LogicalKeyboardKey>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            key: const Key('target'),
            behavior: HitTestBehavior.opaque,
            onTap: () => pressedAtTap.add({
              ...HardwareKeyboard.instance.logicalKeysPressed,
            }),
            child: const SizedBox(width: 200, height: 200),
          ),
        ),
      );
      final at = tester.getCenter(find.byKey(const Key('target')));

      await tester.macCmdClick(at);
      await tester.macClick(at, shift: true);
      await tester.macClick(at);

      expect(pressedAtTap, hasLength(3));
      expect(pressedAtTap[0], contains(LogicalKeyboardKey.metaLeft));
      expect(pressedAtTap[0], isNot(contains(LogicalKeyboardKey.shiftLeft)));
      expect(pressedAtTap[1], contains(LogicalKeyboardKey.shiftLeft));
      expect(pressedAtTap[1], isNot(contains(LogicalKeyboardKey.metaLeft)));
      expect(pressedAtTap[2], isEmpty);
      expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    },
    variant: macOnly,
  );

  testWidgets(
    'macCursorAt reads back the click cursor over a region that sets it',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              MouseRegion(
                key: Key('link'),
                cursor: SystemMouseCursors.click,
                child: SizedBox(width: 100, height: 100),
              ),
              SizedBox(key: Key('plain'), width: 100, height: 100),
            ],
          ),
        ),
      );

      expect(
        await tester.macCursorAt(
          tester.getCenter(find.byKey(const Key('link'))),
        ),
        SystemMouseCursors.click,
      );
      expect(
        await tester.macCursorAt(
          tester.getCenter(find.byKey(const Key('plain'))),
        ),
        isNot(SystemMouseCursors.click),
      );
    },
    variant: macOnly,
  );

  testWidgets('a drag from macDrag reports its start and end positions', (
    tester,
  ) async {
    final downs = <Offset>[];
    final moves = <Offset>[];
    final ups = <Offset>[];
    final kinds = <PointerDeviceKind>{};
    final shiftAtDown = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            downs.add(e.position);
            kinds.add(e.kind);
            shiftAtDown.add(HardwareKeyboard.instance.isShiftPressed);
          },
          onPointerMove: (e) => moves.add(e.position),
          onPointerUp: (e) => ups.add(e.position),
          child: const SizedBox.expand(),
        ),
      ),
    );
    const from = Offset(40, 50);
    const to = Offset(300, 210);

    await tester.macDrag(from, to);

    expect(downs, [from]);
    expect(ups, [to]);
    expect(moves.last, to);
    expect(moves.length, greaterThanOrEqualTo(2));
    expect(kinds, {PointerDeviceKind.mouse});

    await tester.macDragAcross(
      Rect.fromLTWH(0, 0, 20, 20),
      Rect.fromLTWH(100, 100, 20, 20),
    );
    expect(downs.last, const Offset(10, 10));
    expect(ups.last, const Offset(110, 110));

    await tester.macDrag(to, from, shift: true);
    expect(downs.last, to);
    expect(ups.last, from);
    expect(shiftAtDown, [false, false, true]);
  }, variant: macOnly);

  testWidgets(
    'macCompose with a composing range sets composing on the focused field',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await _wi159PumpField(tester, controller);

      await tester.macEditingValue('caf');
      expect(controller.text, 'caf');
      expect(controller.selection, const TextSelection.collapsed(offset: 3));
      expect(controller.value.composing, TextRange.empty);

      await tester.macCompose('café', const TextRange(start: 3, end: 5));
      expect(controller.text, 'café');
      expect(controller.value.composing, const TextRange(start: 3, end: 5));
      expect(controller.selection, const TextSelection.collapsed(offset: 5));

      await tester.macEditingValue(
        'café',
        selection: const TextSelection.collapsed(offset: 2),
      );
      expect(controller.text, 'café');
      expect(controller.value.composing, TextRange.empty);
      expect(controller.selection, const TextSelection.collapsed(offset: 2));
    },
    variant: macOnly,
  );

  testWidgets('the MacClipboard mock round-trips text', (tester) async {
    final clip = MacClipboard.install(tester, initial: 'seed');

    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, 'seed');
    expect(await Clipboard.hasStrings(), isTrue);

    await Clipboard.setData(const ClipboardData(text: 'copied text'));
    expect(clip.text, 'copied text');
    expect(clip.writes, ['copied text']);
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      'copied text',
    );

    clip.text = null;
    expect(await Clipboard.getData(Clipboard.kTextPlain), isNull);
    expect(await Clipboard.hasStrings(), isFalse);
  }, variant: macOnly);

  testWidgets(
    'Cmd+C and Cmd+V in a focused field go through the MacClipboard mock',
    (tester) async {
      final clip = MacClipboard.install(tester);
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await _wi159PumpField(tester, controller);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();

      await tester.macCmdChord(LogicalKeyboardKey.keyC);
      expect(clip.text, 'hello');

      controller.selection = const TextSelection.collapsed(offset: 11);
      await tester.pump();
      await tester.macCmdChord(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(controller.text, 'hello worldhello');
    },
    variant: macOnly,
  );
}
