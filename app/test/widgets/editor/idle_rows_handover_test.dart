// WI #132 (Spec #122 Req 27, 31-34, 38; ruling D17): which row of a text
// segment is the active row, and the handover of focus, IME, autocomplete
// and the text input connection from one row to another.
//
// Every test pumps the real note editor (`pumpSpellingEditor`, macOS) on
// [_t132Body] and reads the rows through the rows host
// (`wi132_idle_rows.dart`): `activeRow`, `focusedRow`, `rowField` (only the
// active row has a field) and `rowBoxes` (an idle row's is a RichText's).
// Each test checks main's behaviour first (focus, selection, text, the
// pasteboard) and the active/idle rows last, so the main behaviour it pins
// is checked on the branch's base too.
//
// "Within one frame": after the key, click or call, one `tester.pump()`.
// "Throughout": a listener on the segment's reveal gate (its focus gate)
// and focus node records every value they notify.
//
// Helpers carry the `_t132`/`wi132` prefix. Text is synthetic.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';

import '../../support/app_harness.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi132_idle_rows.dart';

const _t132First = 'First prose line words';
const _t132BulletOne = '- Bullet one words';
const _t132BulletTwo = '- Bullet two words';
const _t132Middle = 'Middle **bold** prose words';
const _t132Task = '- [ ] Task item words';
const _t132Quote = '> Quote line words';
const _t132Last = 'Last prose line words';

const _t132Body =
    '$_t132First\n'
    '$_t132BulletOne\n'
    '$_t132BulletTwo\n'
    '$_t132Middle\n'
    '$_t132Task\n'
    '$_t132Quote\n'
    '$_t132Last\n';

Future<SpellingEditorHarness> _t132Pump(WidgetTester tester) async {
  final e = await pumpSpellingEditor(tester, body: _t132Body);
  await e.advance(const Duration(seconds: 1));
  return e;
}

int _t132Row(WidgetTester tester, String line) => wi132RowOf(tester, line);

/// The caret at the end of row [row]'s text.
TextSelection _t132EndOf(WidgetTester tester, int row) =>
    TextSelection.collapsed(offset: wi132Spec(tester, row).textEnd);

/// Row [row]'s focus, the active row and the text input connection's text:
/// the row is the focused, active row and the platform edits its text.
void _t132ExpectFocusedActive(WidgetTester tester, int row, String what) {
  final host = wi132Host(tester);
  expect(host.focusedRow, row, reason: '$what: focus is in row $row');
  expect(
    TextEditingValue.fromJSON(tester.testTextInput.editingState!).text,
    wi132RowText(tester, row),
    reason: '$what: the platform edits row $row',
  );
  wi132ExpectOnlyActive(tester, row);
}

/// The width of the glyphs of [part] in row [row] now.
double _t132Width(WidgetTester tester, int row, String part) {
  final text = wi132RowText(tester, row);
  final at = text.indexOf(part);
  expect(at, isNonNegative, reason: 'fixture: "$part" in row $row');
  return wi132Boxes(tester, row)
      .boxesFor(TextRange(start: at, end: at + part.length))
      .fold<double>(0, (w, r) => w + r.width);
}

/// Every semantics node whose label or value is [text].
List<SemanticsNode> _t132NodesOf(String text) => find.semantics
    .byPredicate((node) {
      final data = node.getSemanticsData();
      return data.label == text || data.value == text;
    })
    .evaluate()
    .toList();

/// A focus node outside the editor (a palette, find bar or sidebar field
/// stands in): a plain [Focus] in the app's overlay.
Future<FocusNode> _t132OutsideNode(WidgetTester tester) async {
  final node = FocusNode(debugLabel: 'outside the editor');
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: Focus(focusNode: node, child: const SizedBox()),
    ),
  );
  tester.state<OverlayState>(find.byType(Overlay).first).insert(entry);
  addTearDown(() {
    entry.remove();
    entry.dispose();
    node.dispose();
  });
  await tester.pump();
  return node;
}

void main() {
  holdFontFetches();

  // ----------------------------------------------------- the active row rule

  group('which row is active (Req 27)', () {
    testWidgets(
      'while the segment has no focus the active row is the row holding the selection extent',
      (tester) async {
        await _t132Pump(tester);
        await wi132Unfocus(tester);
        final middle = _t132Row(tester, 'Middle');
        final quote = _t132Row(tester, '> Quote');

        await wi132Select(tester, wi132CaretIn(tester, middle, offset: 2));
        wi132ExpectOnlyActive(tester, middle);

        await wi132Select(
          tester,
          TextSelection(
            baseOffset: wi132Spec(tester, middle).textStart,
            extentOffset: wi132Spec(tester, quote).textStart + 1,
          ),
        );
        wi132ExpectOnlyActive(tester, quote);
      },
      variant: macOnly,
    );

    testWidgets(
      'focusing the segment makes the row holding the caret the focused active row',
      (tester) async {
        await _t132Pump(tester);
        await wi132Unfocus(tester);
        final task = _t132Row(tester, '- [ ] Task');
        await wi132Select(tester, wi132CaretIn(tester, task, offset: 3));

        wi132Host(tester).widget.focusNode.requestFocus();
        await tester.pump();
        await tester.pump();

        expect(wi132Host(tester).focusedRow, task, reason: 'the caret row');
        expect(
          wi132Host(tester).selection,
          wi132CaretIn(tester, task, offset: 3),
          reason: 'the caret stays',
        );
        _t132ExpectFocusedActive(tester, task, 'segment focus');
      },
      variant: macOnly,
    );
  });

  // ---------------------------------------------------------- keyboard moves

  group('keyboard moves (AC5)', () {
    for (final (name, from, atEnd, keys, to) in [
      (
        'Arrow Down from the last line of the active row makes the row below the focused active row',
        _t132First,
        true,
        [LogicalKeyboardKey.arrowDown],
        _t132BulletOne,
      ),
      (
        'Arrow Up from the first line of the active row makes the row above the focused active row',
        _t132Middle,
        false,
        [LogicalKeyboardKey.arrowUp],
        _t132BulletTwo,
      ),
      (
        'Arrow Right at the end of the active row makes the next row the focused active row',
        _t132Middle,
        true,
        [LogicalKeyboardKey.arrowRight],
        _t132Task,
      ),
      (
        'Arrow Left at the start of the active row makes the previous row the focused active row',
        _t132Quote,
        false,
        [LogicalKeyboardKey.arrowLeft],
        _t132Task,
      ),
      (
        'Cmd+Down makes the last row the focused active row',
        _t132BulletOne,
        false,
        [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.arrowDown],
        _t132Last,
      ),
      (
        'Cmd+Up makes the first row the focused active row',
        _t132Quote,
        false,
        [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.arrowUp],
        _t132First,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, from);
        final b = _t132Row(tester, to);
        await wi132Activate(
          tester,
          a,
          atEnd ? _t132EndOf(tester, a) : wi132CaretIn(tester, a),
        );
        expect(wi132Host(tester).focusedRow, a, reason: 'fixture: focus');

        if (keys.length == 1) {
          await wi132Key(tester, keys.single);
        } else {
          await tester.macHolding(
            keys.sublist(0, keys.length - 1),
            () => wi132Key(tester, keys.last),
          );
        }
        await tester.pump();
        await tester.pump();

        final host = wi132Host(tester);
        expect(host.selection.isCollapsed, isTrue, reason: 'a caret move');
        final spec = wi132Spec(tester, b);
        expect(
          host.selection.extentOffset,
          inInclusiveRange(spec.textStart, spec.textEnd),
          reason: 'the caret is in the receiving row',
        );
        _t132ExpectFocusedActive(tester, b, name);
      }, variant: macOnly);
    }

    for (final (name, key, from) in [
      (
        'Page Down in the active row moves neither the caret out of its row nor the active row',
        LogicalKeyboardKey.pageDown,
        _t132Middle,
      ),
      (
        'Page Up in the active row moves neither the caret out of its row nor the active row',
        LogicalKeyboardKey.pageUp,
        _t132Middle,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, from);
        await wi132Activate(tester, a, wi132CaretIn(tester, a, offset: 4));
        final before = wi132Host(tester).selection;
        final text = wi132Host(tester).text;
        final pixels = wi132Page(tester).pixels;

        await wi132Key(tester, key);
        await tester.pump();
        await tester.pump();
        _t132ExpectFocusedActive(tester, a, name);
        expect(wi132Host(tester).text, text, reason: 'no text change');
        expect(wi132Host(tester).selection, before, reason: 'the caret stays');
        expect(wi132Page(tester).pixels, pixels);
      }, variant: macOnly);
    }

    testWidgets(
      'a held Arrow Down whose repeats arrive before the next frame leaves the row it crossed into the focused active row and the next press moves on',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        final c = _t132Row(tester, _t132BulletTwo);
        await wi132Activate(tester, a, _t132EndOf(tester, a));

        // The key goes down and repeats while the row it crossed into is
        // still mounting its field (main's rows ignore the repeats).
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        );
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        );
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        );
        await tester.pump();
        await tester.pump();

        final spec = wi132Spec(tester, b);
        expect(
          wi132Host(tester).selection.extentOffset,
          inInclusiveRange(spec.textStart, spec.textEnd),
          reason: 'the press crossed one row',
        );
        expect(wi132Host(tester).focusedRow, b, reason: 'focus followed');

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
        final next = wi132Spec(tester, c);
        expect(
          wi132Host(tester).selection.extentOffset,
          inInclusiveRange(next.textStart, next.textEnd),
          reason: 'the next press moves on from that row',
        );
        _t132ExpectFocusedActive(tester, c, 'after a held Arrow Down');
      },
      variant: macOnly,
    );

    testWidgets(
      'two Arrow Down presses in one frame make the row two below the focused active row',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletTwo);
        await wi132Activate(tester, a, _t132EndOf(tester, a));

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();

        final spec = wi132Spec(tester, b);
        expect(
          wi132Host(tester).selection.extentOffset,
          inInclusiveRange(spec.textStart, spec.textEnd),
          reason: 'two rows down',
        );
        _t132ExpectFocusedActive(tester, b, 'two presses in one frame');
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift+Arrow Down into the next row extends the selection and focus and the active row stay in the starting row',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));

        await tester.macShiftKey(LogicalKeyboardKey.arrowDown);
        await tester.pump();

        final host = wi132Host(tester);
        expect(
          host.selection.baseOffset,
          wi132Spec(tester, a).textEnd,
          reason: 'the selection starts where the caret was',
        );
        expect(
          host.selection.extentOffset,
          inInclusiveRange(
            wi132Spec(tester, b).textStart,
            wi132Spec(tester, b).textEnd,
          ),
          reason: 'and extends into the next row',
        );
        expect(host.focusedRow, a, reason: 'focus stays in the start row');
        wi132ExpectOnlyActive(tester, a);
        wi132ExpectIdle(tester, b, reason: 'the row the selection entered');
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift+Cmd+Down extends the selection to the end and focus stays in the starting row',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132BulletTwo);
        await wi132Activate(tester, a, wi132CaretIn(tester, a, offset: 3));

        await tester.macCmdChord(LogicalKeyboardKey.arrowDown, shift: true);
        await tester.pump();

        final host = wi132Host(tester);
        expect(
          host.selection,
          TextSelection(
            baseOffset: wi132Spec(tester, a).textStart + 3,
            extentOffset: host.text.length,
          ),
          reason: 'extended to the segment end',
        );
        expect(host.focusedRow, a, reason: 'focus stays in the start row');
        wi132ExpectOnlyActive(tester, a);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------- Select All

  group('Select All (AC6)', () {
    testWidgets(
      'Select All highlights every row and focus and the active row stay where they were',
      (tester) async {
        await _t132Pump(tester);
        final middle = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, middle, wi132CaretIn(tester, middle));

        await tester.macCmdChord(LogicalKeyboardKey.keyA);
        await tester.pump();

        final host = wi132Host(tester);
        expect(
          host.selection,
          TextSelection(baseOffset: 0, extentOffset: host.text.length),
          reason: 'everything is selected',
        );
        expect(host.focusedRow, middle, reason: 'focus stays');
        for (var i = 0; i < host.rowCount; i++) {
          if (wi132RowText(tester, i).isEmpty) continue;
          expect(
            wi132SelectionRects(tester, i),
            isNotEmpty,
            reason: 'row $i is highlighted',
          );
        }
        wi132ExpectOnlyActive(tester, middle);
        for (var i = 0; i < host.rowCount; i++) {
          if (i != middle) wi132ExpectIdle(tester, i);
        }
      },
      variant: macOnly,
    );

    for (final (name, keys, text, clip) in [
      (
        'Copy over Select All copies the whole segment text as on main',
        [LogicalKeyboardKey.keyC],
        _t132Body,
        _t132Body,
      ),
      (
        'Cut over Select All empties the segment and copies its text as on main',
        [LogicalKeyboardKey.keyX],
        '',
        _t132Body,
      ),
      (
        'Delete over Select All empties the segment as on main',
        [LogicalKeyboardKey.backspace],
        '',
        null,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final pasteboard = MacClipboard.install(tester);
        await _t132Pump(tester);
        final middle = _t132Row(tester, _t132Middle);
        final last = _t132Row(tester, _t132Last);
        await wi132Activate(tester, middle, wi132CaretIn(tester, middle));
        await tester.macCmdChord(LogicalKeyboardKey.keyA);
        await tester.pump();
        // Whether Select All left the other rows idle (checked last).
        final idle = wi132IsIdle(tester, last);
        final field = wi132Host(tester).rowField(middle) != null;

        if (keys.single == LogicalKeyboardKey.backspace) {
          await wi132Key(tester, keys.single);
        } else {
          await tester.macCmdChord(keys.single);
        }
        await pumpFrames(tester);

        expect(wi132Host(tester).text, text, reason: 'the segment text');
        expect(pasteboard.text, clip, reason: 'the pasteboard');
        expect(idle, isTrue, reason: 'the rows under Select All were idle');
        expect(field, isTrue, reason: 'the active row kept its field');
      }, variant: macOnly);
    }
  });

  // ---------------------------------------------------- focus during handover

  group('handover keeps the segment focused (AC7)', () {
    testWidgets(
      'an Arrow Down into an idle row keeps the segment focused throughout and moves focus within one frame',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132BulletTwo);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final watch = Wi132FocusWatch(tester);

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();

        expect(wi132Host(tester).focusedRow, b, reason: 'within one frame');
        watch.expectSteady('Arrow Down');
        expect(
          _t132Width(tester, b, '**'),
          greaterThan(1),
          reason: 'the caret line of the new row shows its markup',
        );
        _t132ExpectFocusedActive(tester, b, 'Arrow Down');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click into an idle row keeps the segment focused throughout and makes it the focused active row',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final local = wi132RowText(tester, b).indexOf('prose') + 1;
        final boxes = wi132Boxes(tester, b);
        final glyph = boxes
            .boxesFor(TextRange(start: local, end: local + 1))
            .first;
        final point = boxes.box.localToGlobal(
          Offset(glyph.left + glyph.width * 0.25, glyph.center.dy),
        );
        final expected = wi132Host(tester).rowPositionAt(b, point)!.offset;
        final watch = Wi132FocusWatch(tester);

        await wi132Click(tester, point);

        expect(
          wi132Host(tester).selection,
          TextSelection.collapsed(
            offset: wi132Spec(tester, b).textStart + expected,
          ),
          reason: 'the caret goes to the click',
        );
        expect(wi132Host(tester).focusedRow, b, reason: 'focus moved');
        watch.expectSteady('click');
        _t132ExpectFocusedActive(tester, b, 'click');
      },
      variant: macOnly,
    );

    testWidgets(
      'activating an idle row from code keeps the segment focused throughout and moves focus within one frame',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final watch = Wi132FocusWatch(tester);

        wi132Host(tester).activateRow(b, wi132CaretIn(tester, b, offset: 9));
        await tester.pump();

        expect(wi132Host(tester).focusedRow, b, reason: 'within one frame');
        watch.expectSteady('activateRow');
        expect(
          _t132Width(tester, b, '**'),
          greaterThan(1),
          reason: 'the caret line of the new row shows its markup',
        );
        _t132ExpectFocusedActive(tester, b, 'activateRow');
      },
      variant: macOnly,
    );

    testWidgets(
      'a character typed right after an Arrow Down into an idle row before the next frame is not lost',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final before = wi132Host(tester).text;

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        wi132Type(tester, 'Z');
        await tester.pump();
        await tester.pump();

        final after = wi132Host(tester).text;
        expect('Z'.allMatches(after), hasLength(1), reason: 'Z is typed once');
        expect(
          after.replaceFirst('Z', ''),
          before,
          reason: 'nothing else changed',
        );
        // Where it went: in the row the caret moved to, at the caret, and
        // not in the row the caret left (Req 31, 33).
        expect(
          wi132RowText(tester, b),
          contains('Z'),
          reason: 'Z is in the row the caret moved to',
        );
        expect(
          wi132RowText(tester, a),
          isNot(contains('Z')),
          reason: 'Z is not in the row the caret left',
        );
        expect(
          wi132Host(tester).selection,
          wi132CaretIn(
            tester,
            b,
            offset: wi132RowText(tester, b).indexOf('Z') + 1,
          ),
          reason: 'the caret is just after Z',
        );
        _t132ExpectFocusedActive(tester, b, 'typed after the move');
      },
      variant: macOnly,
    );

    testWidgets(
      'a character typed after a click into an idle row before the next frame goes in at the click and not in the row the caret left',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final before = wi132Host(tester).text;
        final at = wi132RowText(tester, b).indexOf('prose') + 2;

        final gesture = await tester.startGesture(
          wi132GlyphPoint(tester, b, at),
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryButton,
        );
        await gesture.up();
        final caret = wi132Host(tester).selection;
        expect(caret.isCollapsed, isTrue, reason: 'fixture: a caret');
        expect(
          caret.start,
          inInclusiveRange(
            wi132Spec(tester, b).textStart,
            wi132Spec(tester, b).textEnd,
          ),
          reason: 'fixture: the click put the caret in row b',
        );
        wi132Type(tester, 'Z');
        await tester.pump();
        await tester.pump();
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

        final host = wi132Host(tester);
        expect(host.text.replaceFirst('Z', ''), before, reason: 'only Z added');
        expect(
          wi132RowText(tester, a),
          isNot(contains('Z')),
          reason: 'Z is not in the row the caret left',
        );
        expect(
          host.text.substring(caret.start, caret.start + 1),
          'Z',
          reason: 'Z went in at the click',
        );
        expect(
          host.selection,
          TextSelection.collapsed(offset: caret.start + 1),
          reason: 'the caret is just after Z',
        );
        _t132ExpectFocusedActive(tester, b, 'typed after the click');
      },
      variant: macOnly,
    );

    testWidgets(
      'a deletion the platform sends before the handover frame stays in the row that holds the connection',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        final value = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        final next = TextEditingValue(
          text: value.text.substring(0, value.text.length - 1),
          selection: TextSelection.collapsed(offset: value.text.length - 1),
        );
        tester.testTextInput.editingState = next.toJSON();
        tester.testTextInput.updateEditingValue(next);
        await tester.pump();
        await tester.pump();

        expect(
          wi132Host(tester).text,
          _t132Body.replaceFirst(
            _t132First,
            _t132First.substring(0, _t132First.length - 1),
          ),
          reason: 'the deletion stays in the row it was made in',
        );
        _t132ExpectFocusedActive(tester, b, 'deleted before the handover');
      },
      variant: macOnly,
    );

    testWidgets(
      'the row being left keeps its focus node attached and holding focus until the row taking over mounts its field',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final host = wi132Host(tester);
        final node = host.rowFocusNode(a)!;
        expect(node.hasPrimaryFocus, isTrue, reason: 'fixture: a is focused');
        expect(
          node.context,
          isNotNull,
          reason: 'fixture: its field is mounted',
        );

        // A callback registered first runs ahead of the one the handover
        // registers, after the frame built row a as an idle row and before
        // row b asked for focus.
        final seen = <String, Object?>{};
        tester.binding.addPostFrameCallback((_) {
          seen['rowAIdle'] = wi132IsIdle(tester, a);
          seen['rowBHasField'] = host.rowField(b) != null;
          seen['attached'] = node.context != null;
          seen['hasFocus'] = node.hasFocus;
          seen['segmentFocus'] = host.widget.focusNode.hasFocus;
        });
        host.activateRow(b, wi132CaretIn(tester, b, offset: 2));
        await tester.pump();

        expect(seen['rowAIdle'], isTrue, reason: 'the frame idled the old row');
        expect(
          seen['rowBHasField'],
          isTrue,
          reason: 'and mounted the new field',
        );
        expect(
          seen['attached'],
          isTrue,
          reason: 'the idle row keeps the old row focus node attached',
        );
        expect(seen['hasFocus'], isTrue, reason: 'it still holds focus');
        expect(seen['segmentFocus'], isTrue, reason: 'the segment is focused');
        _t132ExpectFocusedActive(tester, b, 'handover');
      },
      variant: macOnly,
    );

    testWidgets(
      'a character typed before the handover frame stays in the row that holds the connection when the selection moved across rows',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        final c = _t132Row(tester, _t132BulletTwo);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final before = wi132Host(tester).text;

        wi132Host(tester).activateRow(
          b,
          TextSelection(
            baseOffset: wi132Spec(tester, b).textStart,
            extentOffset: wi132Spec(tester, c).textStart + 2,
          ),
        );
        wi132Type(tester, 'Z');
        await tester.pump();
        await tester.pump();

        final host = wi132Host(tester);
        expect(host.text.replaceFirst('Z', ''), before, reason: 'only Z added');
        expect(
          wi132RowText(tester, a),
          contains('Z'),
          reason: 'Z stays in the row that held the connection',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'focus that leaves the editor right after an Arrow Down into an idle row is not taken back by the row waiting for its field',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final outside = await _t132OutsideNode(tester);

        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        outside.requestFocus();
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(outside.hasPrimaryFocus, isTrue, reason: 'focus stays outside');
        expect(
          wi132Host(tester).widget.focusNode.hasFocus,
          isFalse,
          reason: 'the segment did not take focus back',
        );
        expect(wi132Host(tester).focusedRow, isNull, reason: 'no row focused');
        wi132ExpectOnlyActive(tester, b);
      },
      variant: macOnly,
    );

    testWidgets(
      'focus that moves to another field before the frame of a row activated while the segment had no focus is not taken back',
      (tester) async {
        await _t132Pump(tester);
        await wi132Unfocus(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        final outside = await _t132OutsideNode(tester);
        await wi132Select(tester, wi132CaretIn(tester, a, offset: 2));
        wi132ExpectIdle(tester, b, reason: 'fixture: b has no field yet');

        wi132Host(tester).activateRow(b, wi132CaretIn(tester, b, offset: 3));
        outside.requestFocus();
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(outside.hasPrimaryFocus, isTrue, reason: 'focus stays outside');
        expect(wi132Host(tester).widget.focusNode.hasFocus, isFalse);
        expect(wi132Host(tester).focusedRow, isNull, reason: 'no row focused');
        wi132ExpectOnlyActive(tester, b);
      },
      variant: macOnly,
    );

    testWidgets(
      'a row activated while the segment had no focus takes focus when none moved elsewhere in between',
      (tester) async {
        await _t132Pump(tester);
        await wi132Unfocus(tester);
        final b = _t132Row(tester, _t132BulletOne);

        wi132Host(tester).activateRow(b, wi132CaretIn(tester, b, offset: 3));
        await tester.pump();
        await tester.pump();

        _t132ExpectFocusedActive(tester, b, 'activated from no focus');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click into an idle row while a field outside the editor has focus makes the row the focused active row',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final outside = await _t132OutsideNode(tester);
        outside.requestFocus();
        await tester.pump();
        await tester.pump();
        expect(outside.hasPrimaryFocus, isTrue, reason: 'fixture: outside');

        await wi132Click(tester, wi132GlyphPoint(tester, b, 3));

        expect(outside.hasFocus, isFalse, reason: 'the outside field let go');
        _t132ExpectFocusedActive(tester, b, 'click from outside');
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------------- IME

  group('IME composition on handover (AC8)', () {
    for (final (name, how) in [
      (
        'an open IME composition is committed into its row when a click moves the caret to another row',
        'click',
      ),
      (
        'an open IME composition is committed into its row when code moves the caret to another row',
        'code',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Middle);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final rowText = wi132RowText(tester, a);
        await tester.macCompose(
          '${rowText}ka',
          TextRange(start: rowText.length, end: rowText.length + 2),
        );
        expect(
          wi132Host(tester).rowController(a)!.value.composing.isValid,
          isTrue,
          reason: 'fixture: composing',
        );
        final controller = wi132Host(tester).rowController(a)!;

        final logged = tester.testTextInput.log.length;

        // The composition closes in the very call or press that moves the
        // caret, before any frame (the connection is still the old row's).
        if (how == 'click') {
          final gesture = await tester.startGesture(
            wi132GlyphPoint(tester, b, 2),
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryButton,
          );
          expect(
            controller.value.composing.isValid,
            isFalse,
            reason: 'the composition closes on the press',
          );
          await gesture.up();
          await tester.pump();
          await tester.pump();
          await tester.pump(
            kDoubleTapTimeout + const Duration(milliseconds: 50),
          );
        } else {
          wi132Host(tester).activateRow(b, wi132CaretIn(tester, b, offset: 2));
          expect(
            controller.value.composing.isValid,
            isFalse,
            reason: 'the composition closes in the activateRow call',
          );
          await tester.pump();
          await tester.pump();
        }

        // The platform hears the commit (an empty composing range) before
        // the old row's connection closes.
        final calls = tester.testTextInput.log.sublist(logged);
        final closed = calls.indexWhere(
          (c) => c.method == 'TextInput.clearClient',
        );
        final committed = calls.indexWhere(
          (c) =>
              c.method == 'TextInput.setEditingState' &&
              (c.arguments as Map)['composingBase'] == -1 &&
              (c.arguments as Map)['text'] == '${_t132First}ka',
        );
        expect(committed, isNonNegative, reason: 'the platform got the commit');
        expect(
          closed == -1 || committed < closed,
          isTrue,
          reason:
              'the commit reaches the platform before the connection closes',
        );

        final host = wi132Host(tester);
        expect(
          host.text,
          _t132Body.replaceFirst(_t132First, '${_t132First}ka'),
          reason: 'the composed text stays in its row',
        );
        expect(
          controller.value.composing.isValid,
          isFalse,
          reason: 'the composition is committed',
        );
        expect(host.focusedRow, b, reason: 'focus moved on');
        wi132Type(tester, 'z');
        await tester.pump();
        expect(
          wi132RowText(tester, b),
          contains('z'),
          reason: 'typing goes to the new row',
        );
        expect(
          wi132Host(tester).text.replaceFirst('z', ''),
          _t132Body.replaceFirst(_t132First, '${_t132First}ka'),
          reason: 'nothing typed is lost',
        );
        wi132ExpectOnlyActive(tester, b);
      }, variant: macOnly);
    }

    testWidgets(
      'an IME composition the platform commits with an Arrow Down stays in its row and focus moves on',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132BulletOne);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        final rowText = wi132RowText(tester, a);
        await tester.macCompose(
          '${rowText}ka',
          TextRange(start: rowText.length, end: rowText.length + 2),
        );

        // The IME commits the marked text, then the key arrives.
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '${rowText}ka',
            selection: TextSelection.collapsed(offset: rowText.length + 2),
          ),
        );
        await wi132Key(tester, LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();

        expect(
          wi132Host(tester).text,
          _t132Body.replaceFirst(_t132First, '${_t132First}ka'),
          reason: 'the composed text stays in its row',
        );
        _t132ExpectFocusedActive(tester, b, 'Arrow Down after a commit');
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------ agent reload

  group('agent reload (AC9)', () {
    for (final (name, focused) in [
      ('an agent reload keeps the controller of the focused active row', true),
      (
        'an agent reload keeps the controller of the unfocused active row',
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final middle = _t132Row(tester, _t132Middle);
        if (focused) {
          await wi132Activate(
            tester,
            middle,
            wi132CaretIn(tester, middle, offset: 2),
          );
        } else {
          await wi132Unfocus(tester);
          await wi132Select(tester, wi132CaretIn(tester, middle, offset: 2));
        }
        final host = wi132Host(tester);
        final controller = host.rowController(middle);
        final selection = host.selection;
        final at = wi132Spec(tester, middle).textEnd;
        final text = host.text.replaceRange(at, at, ' agent');

        // A change from outside: the segment controller's text is set.
        host.widget.controller.value = TextEditingValue(
          text: text,
          selection: selection,
        );
        await tester.pump();
        await tester.pump();

        expect(host.text, text, reason: 'the rows took the new text');
        expect(
          host.rowController(middle),
          same(controller),
          reason: 'the active row keeps its controller',
        );
        expect(
          host.focusedRow,
          focused ? middle : isNull,
          reason: 'focus as before',
        );
        wi132ExpectOnlyActive(tester, middle);
      }, variant: macOnly);
    }
  });

  group('agent reload changes the kind of the unfocused active row (AC9)', () {
    testWidgets(
      'an agent reload that changes the kind of the unfocused active row keeps its controller and the rows around it',
      (tester) async {
        await _t132Pump(tester);
        await wi132Unfocus(tester);
        final middle = _t132Row(tester, _t132Middle);
        await wi132Select(tester, wi132CaretIn(tester, middle, offset: 2));
        final host = wi132Host(tester);
        final before = [
          for (var i = 0; i < host.rowCount; i++) host.rowController(i),
        ];
        final start = wi132Spec(tester, middle).start;

        // An agent turns the active prose row into a bullet.
        host.widget.controller.value = TextEditingValue(
          text: host.text.replaceRange(start, start, '- '),
          selection: TextSelection.collapsed(
            offset: host.selection.extentOffset + 2,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          host.text.substring(wi132Spec(tester, middle).start).trimLeft(),
          startsWith('- Middle'),
          reason: 'fixture: the row is a bullet now',
        );
        expect(
          host.rowController(middle),
          same(before[middle]),
          reason: 'the active row keeps its controller across a kind change',
        );
        for (var i = 0; i < before.length; i++) {
          if (i == middle) continue;
          expect(
            host.rowController(i),
            same(before[i]),
            reason: 'row $i has a continuation of its own',
          );
        }
        expect(host.focusedRow, isNull, reason: 'still unfocused');
        wi132ExpectOnlyActive(tester, middle);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------ autocomplete

  group('autocomplete belongs to the active row (AC10)', () {
    for (final (name, typed, popover, accept) in [
      (
        'wikilink autocomplete opens in the active row and closes when the caret moves to another row',
        ' [[',
        const Key('wikilink-popover'),
        false,
      ),
      (
        'tag autocomplete opens in the active row and closes when the caret moves to another row',
        ' #wo',
        const Key('tag-autocomplete'),
        false,
      ),
      (
        'the kind chip of a linked wikilink closes when the caret moves to another row',
        ' [[',
        const Key('kind-chip'),
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Quote);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        await tester.macEditingValue('$_t132First$typed');
        await pumpFrames(tester);
        if (accept) {
          expect(
            find.byKey(const Key('wikilink-popover')),
            findsOneWidget,
            reason: 'fixture: the popover is open',
          );
          await wi132Key(tester, LogicalKeyboardKey.enter);
          await pumpFrames(tester);
        }
        expect(find.byKey(popover), findsOneWidget, reason: 'it opens');

        await wi132Activate(tester, b, wi132CaretIn(tester, b, offset: 2));
        await pumpFrames(tester);

        expect(find.byKey(popover), findsNothing, reason: 'closed on handover');
        expect(wi132Host(tester).focusedRow, b, reason: 'focus moved on');
        wi132ExpectOnlyActive(tester, b);
      }, variant: macOnly);
    }
  });

  // --------------------------------------------------------------- semantics

  group('semantics (AC11)', () {
    testWidgets(
      'each idle row is a read only leaf text node with an activate action and the active row is a text field',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _t132Pump(tester);
        final active = _t132Row(tester, _t132First);
        await wi132Activate(tester, active, _t132EndOf(tester, active));
        await tester.pump();
        final host = wi132Host(tester);

        final field = _t132NodesOf(wi132RowText(tester, active));
        expect(field, hasLength(1), reason: 'one node for the active row');
        expect(
          field.single,
          isSemantics(isTextField: true, isReadOnly: false),
          reason: 'the active row is an editable text field',
        );
        for (var i = 0; i < host.rowCount; i++) {
          if (i == active) continue;
          final text = wi132RowText(tester, i);
          if (text.isEmpty) continue;
          final nodes = _t132NodesOf(text);
          expect(nodes, hasLength(1), reason: 'one node for row $i');
          final node = nodes.single;
          expect(
            node,
            isSemantics(isReadOnly: true, hasTapAction: true),
            reason: 'row $i is read only with an activate action',
          );
          expect(node.childrenCount, 0, reason: 'row $i is one leaf node');
          final data = node.getSemanticsData();
          expect(
            data.label == text || data.value == text,
            isTrue,
            reason: 'row $i reads its text',
          );
        }
        semantics.dispose();
      },
      variant: macOnly,
    );

    testWidgets(
      'performing the activate action on an idle row makes it the active row with the caret at its end',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Quote);
        await wi132Activate(tester, a, _t132EndOf(tester, a));
        await tester.pump();
        final text = wi132RowText(tester, b);
        final nodes = _t132NodesOf(text);
        expect(nodes, hasLength(1), reason: 'one node for the quote row');
        final node = nodes.single;
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: 'the idle row offers an activate action',
        );

        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pump();
        await tester.pump();

        expect(
          wi132Host(tester).selection,
          _t132EndOf(tester, b),
          reason: 'the caret at the row end',
        );
        _t132ExpectFocusedActive(tester, b, 'the activate action');
        semantics.dispose();
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------- rows probe

  group('the rows probe with idle rows (AC13)', () {
    testWidgets(
      'the rows probe measures an idle row through its RichText and activates it',
      (tester) async {
        await _t132Pump(tester);
        final a = _t132Row(tester, _t132First);
        final b = _t132Row(tester, _t132Task);
        await wi132Activate(tester, a, _t132EndOf(tester, a));

        expect(
          rowBoxesOf(tester, 0, b),
          isA<RenderParagraphLineBoxes>(),
          reason: 'an idle row measures through its RichText',
        );
        expect(rowTextOf(tester, 0, b), 'Task item words');
        final rect = rowRectOf(tester, 0, b);
        expect(
          rect.overlaps(wi132SlotRect(tester, b)),
          isTrue,
          reason: 'the probe rect is the row slot',
        );

        await activateRow(tester, 0, b, offset: 2);

        expect(
          wi132Host(tester).selection,
          wi132CaretIn(tester, b, offset: 2),
          reason: 'the caret at the asked offset',
        );
        expect(
          rowBoxesOf(tester, 0, b),
          isA<RenderEditableLineBoxes>(),
          reason: 'the activated row measures through its field',
        );
        _t132ExpectFocusedActive(tester, b, 'probe activateRow');
      },
      variant: macOnly,
    );
  });
}
