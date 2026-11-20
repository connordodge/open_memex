// WI #132 (Spec #122 Req 27, 33): contracts of the active row seam that the
// mapped handover tests do not reach: requests past either end, focus loss
// with a selection across rows, an active row that an agent reload removes,
// and the kind chip's release.
//
// The editor tests pump the real note editor (`pumpSpellingEditor`, macOS)
// and read rows through the rows host (`wi132_idle_rows.dart`). Helpers carry
// the `_t132c`/`wi132` prefix. Text is synthetic.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi132_idle_rows.dart';

const _t132cBody =
    'First prose line words\n'
    '- Bullet one words\n'
    'Middle prose words\n'
    '- Bullet two words\n'
    'Last prose line words\n';

Future<void> _t132cPump(WidgetTester tester) async {
  final e = await pumpSpellingEditor(tester, body: _t132cBody);
  await e.advance(const Duration(seconds: 1));
}

void main() {
  holdFontFetches();

  group('activateRow past either end (Req 30)', () {
    for (final (name, at) in [
      ('activating a row before the first row changes nothing', -1),
      ('activating a row past the last row changes nothing', 5),
    ]) {
      testWidgets(name, (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        expect(host.rowCount, 5, reason: 'fixture: five rows');
        final middle = wi132RowOf(tester, 'Middle');
        await wi132Activate(
          tester,
          middle,
          wi132CaretIn(tester, middle, offset: 3),
        );
        final selection = host.selection;
        final focused = host.focusedRow;
        expect(focused, middle, reason: 'fixture: the middle row has focus');

        host.activateRow(at, TextSelection.collapsed(offset: 0));
        await tester.pump();
        await tester.pump();

        expect(host.selection, selection, reason: 'the selection stays');
        expect(host.focusedRow, focused, reason: 'focus stays');
        wi132ExpectOnlyActive(tester, middle);
      }, variant: macOnly);
    }

    testWidgets('activating the first and the last row works at both ends', (
      tester,
    ) async {
      await _t132cPump(tester);
      final host = wi132Host(tester);
      await wi132Activate(tester, 0, wi132CaretIn(tester, 0, offset: 1));
      wi132ExpectOnlyActive(tester, 0);
      expect(host.focusedRow, 0, reason: 'the first row has focus');

      final last = host.rowCount - 1;
      await wi132Activate(tester, last, wi132CaretIn(tester, last));
      wi132ExpectOnlyActive(tester, last);
      expect(host.focusedRow, last, reason: 'the last row has focus');
    }, variant: macOnly);
  });

  group('focus loss and a selection across rows (Req 27)', () {
    for (final (name, forward) in [
      (
        'losing focus with a selection across rows makes the row holding its extent active',
        true,
      ),
      (
        'losing focus with a backward selection across rows makes the earlier row, holding its extent, active',
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        final first = wi132RowOf(tester, 'First');
        final last = wi132RowOf(tester, 'Last');
        await wi132Activate(tester, first, wi132CaretIn(tester, first));
        final a = wi132Spec(tester, first).textStart + 2;
        final b = wi132Spec(tester, last).textStart + 3;
        host.select(
          TextSelection(
            baseOffset: forward ? a : b,
            extentOffset: forward ? b : a,
          ),
        );
        await tester.pump();
        await tester.pump();
        wi132ExpectOnlyActive(tester, first);

        await wi132Unfocus(tester);

        wi132ExpectOnlyActive(tester, forward ? last : first);
      }, variant: macOnly);
    }
  });

  group('an agent reload that removes the active row (Req 27)', () {
    testWidgets(
      'an agent reload that deletes the active row makes the row holding the selection extent active',
      (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        final middle = wi132RowOf(tester, 'Middle');
        await wi132Unfocus(tester);
        await wi132Select(tester, wi132CaretIn(tester, middle, offset: 2));
        wi132ExpectOnlyActive(tester, middle);

        // The agent deletes the Middle line and the caret lands in the line
        // that is now at its place.
        final spec = wi132Spec(tester, middle);
        final text = host.text.replaceRange(spec.start, spec.end, '');
        final caret = spec.start + 4;
        host.widget.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: caret),
        );
        await tester.pump();
        await tester.pump();

        expect(host.text, text, reason: 'the rows took the new text');
        expect(host.rowCount, 4, reason: 'the active row went away');
        final holder = host.rowCount - 2;
        expect(
          host.rowSpec(holder)!.start <= caret &&
              caret <= host.rowSpec(holder)!.textEnd,
          isTrue,
          reason: 'fixture: the caret is in row $holder',
        );
        wi132ExpectOnlyActive(tester, holder);
      },
      variant: macOnly,
    );

    testWidgets(
      'an agent reload that deletes the focused active row makes another row the one active row',
      (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        final middle = wi132RowOf(tester, 'Middle');
        await wi132Activate(
          tester,
          middle,
          wi132CaretIn(tester, middle, offset: 2),
        );
        final spec = wi132Spec(tester, middle);
        final text = host.text.replaceRange(spec.start, spec.end, '');
        host.widget.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: spec.start),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();

        final active = host.activeRow.value;
        expect(active, isNotNull, reason: 'a row is active');
        expect(active, inInclusiveRange(0, host.rowCount - 1));
        wi132ExpectOnlyActive(tester, active!);
      },
      variant: macOnly,
    );
  });

  group('the row a handover leaves (Req 28, 33)', () {
    testWidgets(
      'the row an activation leaves holds no selection and shows its markup hidden',
      (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        final one = wi132RowOf(tester, '- Bullet one');
        final two = wi132RowOf(tester, '- Bullet two');
        await wi132Activate(tester, one, wi132CaretIn(tester, one, offset: 3));
        expect(
          host.rowController(one)!.selection.isValid,
          isTrue,
          reason: 'fixture: the active row holds the caret',
        );

        await wi132Activate(tester, two, wi132CaretIn(tester, two, offset: 3));

        wi132ExpectOnlyActive(tester, two);
        expect(
          host.rowController(one)!.selection.isValid,
          isFalse,
          reason:
              'the row left behind holds no selection, so it is not revealed',
        );
        expect(
          host.rowController(two)!.selection,
          const TextSelection.collapsed(offset: 3),
          reason: 'the active row holds the caret',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Arrow Down out of an item row leaves that row with no selection',
      (tester) async {
        await _t132cPump(tester);
        final host = wi132Host(tester);
        final one = wi132RowOf(tester, '- Bullet one');
        final middle = wi132RowOf(tester, 'Middle');
        await wi132Activate(
          tester,
          one,
          wi132CaretIn(tester, one, offset: wi132RowText(tester, one).length),
        );

        await tester.sendKeyEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        );
        await tester.pump();
        await tester.pump();

        expect(host.focusedRow, middle, reason: 'the caret moved down a row');
        expect(
          host.rowController(one)!.selection.isValid,
          isFalse,
          reason: 'the row left behind holds no selection',
        );
      },
      variant: macOnly,
    );
  });

  group('the kind chip release (WI #132)', () {
    test('releasing the chip of a field that goes away hides the chip once '
        'the microtask has run', () async {
      final host = KindChipHost();
      addTearDown(host.dispose);
      final field = TextEditingController(text: '[[Zeta Game]]');
      addTearDown(field.dispose);
      host.showFor(field, start: 0, end: 13);
      expect(host.chip.visible, isTrue, reason: 'fixture: chip shown');

      host.release(field);
      expect(
        host.chip.visible,
        isTrue,
        reason: 'not before the microtask: the tree may be tearing down',
      );
      await Future<void>.value();

      expect(host.chip.visible, isFalse, reason: 'the chip is hidden');
      expect(host.target, isNull, reason: 'the chip forgot its field');
    });

    test(
      'releasing a field the chip does not belong to leaves the chip',
      () async {
        final host = KindChipHost();
        addTearDown(host.dispose);
        final shown = TextEditingController(text: '[[Zeta Game]]');
        final other = TextEditingController(text: 'other');
        addTearDown(shown.dispose);
        addTearDown(other.dispose);
        host.showFor(shown, start: 0, end: 13);

        host.release(other);
        await Future<void>.value();

        expect(host.chip.visible, isTrue, reason: 'the chip stays');
        expect(host.target, same(shown), reason: 'its field stays');
      },
    );

    test(
      'a chip that moved to another field before the microtask is kept',
      () async {
        final host = KindChipHost();
        addTearDown(host.dispose);
        final a = TextEditingController(text: '[[Zeta Game]]');
        final b = TextEditingController(text: '[[Zeta Game]]');
        addTearDown(a.dispose);
        addTearDown(b.dispose);
        host.showFor(a, start: 0, end: 13);

        host.release(a);
        host.showFor(b, start: 0, end: 13);
        await Future<void>.value();

        expect(host.chip.visible, isTrue, reason: 'the new chip stays');
        expect(host.target, same(b), reason: 'for its new field');
      },
    );

    test('releasing then disposing the host before the microtask throws '
        'nothing', () async {
      final host = KindChipHost();
      final field = TextEditingController(text: '[[Zeta Game]]');
      addTearDown(field.dispose);
      host.showFor(field, start: 0, end: 13);

      host.release(field);
      host.dispose();
      await Future<void>.value();
      await Future<void>.value();
    });
  });
}
