// WI #132 (Spec #122 Req 27, 33) with WI #147: a row field shows no context
// menu of its own over a selection that spans rows, so the segment's cross-row
// menu is the only one, and it waits for the clipboard as #147 shows it. The
// field got focus from a click (not from activation), then Shift+Arrow
// extended the selection across rows, then the focused row's part of the
// selection was right clicked. Helpers carry the `_t132m` prefix. Text is
// synthetic.
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/paste_or_attach.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';

import '../../support/app_harness.dart' show pumpFrames;
import '../../support/attachment_input_fakes.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/wi147_drop_paste_harness.dart';

const _t132mBody = 'Intro\n- alpha\n- beta';

/// A pasteboard reader whose read answers only after [open].
class _T132mHeldPasteboard extends FakePasteboardReader {
  _T132mHeldPasteboard(super.contents);

  final Completer<void> _gate = Completer<void>();

  void open() => _gate.complete();

  @override
  Future<PasteboardContents> read() async {
    await _gate.future;
    return super.read();
  }
}

/// A right click that pumps no time past the press, so the clipboard wait is
/// still running when it returns.
Future<void> _t132mRightClickNoWait(Wi147Rig g, Offset at) async {
  final mouse = await g.tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await g.tester.pump();
  await mouse.up();
  await g.tester.pump();
  await mouse.removePointer();
}

void main() {
  holdFontFetches();

  testWidgets(
    'a field focused by a click whose selection then spans rows shows no menu of its own on a right click and the cross row menu waits for the clipboard',
    (tester) async {
      final held = _T132mHeldPasteboard(
        const PasteboardContents(hasText: true),
      );
      final g = await wi147Pump(
        tester,
        body: _t132mBody,
        pasteboardReader: held,
      );
      await g.r.open();
      await g.setWritable(true);
      // Click into `alpha` (offset 10, after `al`): a real click, so the row
      // field is focused by the pointer and has its selection overlay.
      await tester.tapAt(g.caretPoint(10), kind: PointerDeviceKind.mouse);
      await pumpFrames(tester);
      final view = segmentEditingAt(tester, 0);
      expect(view.focusedRow, 1, reason: 'the click focused the alpha row');
      // Shift+Down extends the selection into `beta`.
      await tester.macShiftKey(LogicalKeyboardKey.arrowDown);
      await pumpFrames(tester);
      expect(view.selection.baseOffset, 10);
      expect(view.selection.extentOffset, greaterThan(14));
      expect(view.focusedRow, 1, reason: 'focus stays in the starting row');

      final a = g.caretPoint(11);
      final b = g.caretPoint(12);
      await _t132mRightClickNoWait(g, Offset((a.dx + b.dx) / 2, a.dy));

      expect(
        g.menuItem('Copy'),
        findsNothing,
        reason: 'within the wait the field shows no menu of its own',
      );
      await tester.pump(pasteOfferWait);
      await pumpFrames(tester);
      expect(g.menuItem('Copy'), findsOneWidget);
      expect(g.menuItem('Cut'), findsOneWidget);
      expect(g.menuItem('Paste'), findsNothing, reason: 'the read is late');

      held.open();
      await pumpFrames(tester);
      expect(g.menuItem('Paste'), findsOneWidget, reason: 'the late answer');
    },
    variant: macOnly,
  );

  testWidgets(
    'a field focused by a click whose selection stays in its row shows its own menu at once on a right click',
    (tester) async {
      final held = _T132mHeldPasteboard(
        const PasteboardContents(hasText: true),
      );
      final g = await wi147Pump(
        tester,
        body: _t132mBody,
        pasteboardReader: held,
      );
      await g.r.open();
      await g.setWritable(true);
      await tester.tapAt(g.caretPoint(10), kind: PointerDeviceKind.mouse);
      await pumpFrames(tester);
      // Shift+Right extends within `alpha`.
      await tester.macShiftKey(LogicalKeyboardKey.arrowRight);
      await pumpFrames(tester);
      final view = segmentEditingAt(tester, 0);
      expect(view.selection.baseOffset, 10);
      expect(view.selection.extentOffset, 11, reason: 'one char, same row');

      final a = g.caretPoint(10);
      final b = g.caretPoint(11);
      await _t132mRightClickNoWait(g, Offset((a.dx + b.dx) / 2, a.dy));
      await pumpFrames(tester);

      expect(
        g.menuItem('Copy'),
        findsOneWidget,
        reason: 'the field shows its own menu, no wait',
      );
    },
    variant: macOnly,
  );
}
