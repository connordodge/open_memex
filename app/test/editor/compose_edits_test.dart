// WI #169 (C2), ruling D20: `composeEdits` turns two edits (the second
// expressed on the text after the first) into one splice on the original
// text, so one user action is one SegmentEdit, one content report and one
// undo record. Every case checks the composed edit byte for byte against
// applying the two edits one after the other, and checks its selection.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_edits.dart';
import 'package:open_memex_app/src/editor/segment_selection.dart';

List<RowSpec> _rows(String text) => splitRows(text, atSegmentStart: true);

/// The row whose text holds [offset] (its text range, ends included).
int _rowAt(List<RowSpec> rows, int offset) {
  final i = rows.indexWhere(
    (r) => r.textStart <= offset && offset <= r.textEnd,
  );
  expect(i, isNot(-1), reason: 'no row holds offset $offset');
  return i;
}

/// Composes [first] and [second] on [text] and checks the result against
/// applying them in turn; returns the composed edit.
SegmentEdit _composeChecked(
  String text,
  SegmentEdit first,
  SegmentEdit second, {
  bool passText = false,
}) {
  final composed = passText
      ? composeEdits(first, second, text: text)
      : composeEdits(first, second);
  final sequential = second.apply(first.apply(text));
  expect(composed.apply(text), sequential);
  expect(composed.apply(text).codeUnits, sequential.codeUnits);
  return composed;
}

/// Enter over the cross-row [selection] of [text], the way the keyboard
/// handler builds it: A4 deletes the range, then A3 runs Enter at its start.
(SegmentEdit, SegmentEdit) _rangeEnter(
  String text,
  SegmentSelection selection,
) {
  final delete = deleteRange(text, _rows(text), selection);
  final after = delete.apply(text);
  final rows = _rows(after);
  final row = _rowAt(rows, selection.start);
  final spec = rows[row];
  final SegmentEdit? enter;
  if (!spec.isItem) {
    enter = SegmentEdit(
      start: selection.start,
      end: selection.start,
      replacement: '\n',
      selection: SegmentSelection.collapsed(selection.start + 1),
    );
  } else if (spec.textLength == 0) {
    enter = enterOnEmpty(after, rows, row);
  } else {
    enter = splitItem(after, rows, row, selection.start);
  }
  return (delete, enter!);
}

void main() {
  group('composeEdits for Enter over a cross-row selection', () {
    test('selection starting in an item row splits that item once', () {
      const text = '- one\n- two\nthree\n';
      const selection = SegmentSelection(baseOffset: 3, extentOffset: 14);
      final (delete, enter) = _rangeEnter(text, selection);
      final composed = _composeChecked(text, delete, enter);
      expect(composed.apply(text), '- o\n- ree\n');
      expect(
        composed,
        const SegmentEdit(
          start: 3,
          end: 14,
          replacement: '\n- ',
          selection: SegmentSelection.collapsed(6),
        ),
      );
    });

    test(
      'selection starting in a prose row equals replacing it with a newline',
      () {
        const text = 'intro\n- two\n- three\n';
        const selection = SegmentSelection(baseOffset: 2, extentOffset: 16);
        final (delete, enter) = _rangeEnter(text, selection);
        final composed = _composeChecked(text, delete, enter);
        expect(composed.apply(text), 'in\nree\n');
        expect(composed, replaceRange(text, _rows(text), selection, '\n'));
      },
    );

    test('selection ending on an empty item continues the start item', () {
      const text = '- one\n- two\n- \n';
      const selection = SegmentSelection(baseOffset: 3, extentOffset: 14);
      final (delete, enter) = _rangeEnter(text, selection);
      final composed = _composeChecked(text, delete, enter);
      expect(composed.apply(text), '- o\n- \n');
      expect(composed.selection, const SegmentSelection.collapsed(6));
    });

    test(
      'selection from an item text start to an empty item ends the list',
      () {
        const text = '- one\n- two\n- \n';
        const selection = SegmentSelection(baseOffset: 2, extentOffset: 14);
        final (delete, enter) = _rangeEnter(text, selection);
        final composed = _composeChecked(text, delete, enter);
        expect(composed.apply(text), '\n');
        expect(
          composed,
          const SegmentEdit(
            start: 0,
            end: 14,
            replacement: '',
            selection: SegmentSelection.collapsed(0),
          ),
        );
      },
    );

    test('a backwards selection over CRLF lines keeps the CRLF terminator', () {
      const text = '- one\r\n- two\r\nend';
      const selection = SegmentSelection(baseOffset: 11, extentOffset: 4);
      final (delete, enter) = _rangeEnter(text, selection);
      final composed = _composeChecked(text, delete, enter);
      expect(composed.apply(text), '- on\r\n- o\r\nend');
      expect(composed.selection, const SegmentSelection.collapsed(8));
    });
  });

  group('composeEdits geometry', () {
    const text = 'abcdefghij';

    test('second after the first written text, disjoint, needs the text', () {
      const first = SegmentEdit(start: 1, end: 3, replacement: 'XY');
      const second = SegmentEdit(start: 6, end: 8, replacement: 'Z');
      expect(() => composeEdits(first, second), throwsA(isA<ArgumentError>()));
      final composed = _composeChecked(text, first, second, passText: true);
      expect(
        composed,
        const SegmentEdit(start: 1, end: 8, replacement: 'XYdefZ'),
      );
    });

    test('second before the first, disjoint, needs the text', () {
      const first = SegmentEdit(start: 6, end: 7, replacement: 'XYZ');
      const second = SegmentEdit(start: 1, end: 2, replacement: '');
      expect(() => composeEdits(first, second), throwsA(isA<ArgumentError>()));
      final composed = _composeChecked(text, first, second, passText: true);
      expect(
        composed,
        const SegmentEdit(start: 1, end: 7, replacement: 'cdefXYZ'),
      );
    });

    test('second adjacent after the first written text', () {
      const first = SegmentEdit(start: 2, end: 4, replacement: 'XY');
      const second = SegmentEdit(start: 4, end: 5, replacement: 'Z');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 2, end: 5, replacement: 'XYZ'));
    });

    test('second adjacent before the first', () {
      const first = SegmentEdit(start: 4, end: 4, replacement: 'XY');
      const second = SegmentEdit(start: 2, end: 4, replacement: 'Q');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 2, end: 4, replacement: 'QXY'));
    });

    test('second overlapping the end of the first written text', () {
      const first = SegmentEdit(start: 2, end: 3, replacement: 'XYZ');
      const second = SegmentEdit(start: 4, end: 7, replacement: '_');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 2, end: 5, replacement: 'XY_'));
    });

    test('second overlapping the start of the first written text', () {
      const first = SegmentEdit(start: 5, end: 6, replacement: 'XYZ');
      const second = SegmentEdit(start: 3, end: 6, replacement: '_');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 3, end: 6, replacement: '_YZ'));
    });

    test('second inside the first written text', () {
      const first = SegmentEdit(start: 3, end: 3, replacement: 'WXYZ');
      const second = SegmentEdit(start: 4, end: 6, replacement: '-');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 3, end: 3, replacement: 'W-Z'));
    });

    test('second covering the whole first written text and more', () {
      const first = SegmentEdit(start: 4, end: 5, replacement: 'XY');
      const second = SegmentEdit(start: 1, end: 8, replacement: '!');
      final composed = _composeChecked(text, first, second);
      expect(composed, const SegmentEdit(start: 1, end: 7, replacement: '!'));
    });

    test('an empty no-op second gives the first back', () {
      const first = SegmentEdit(
        start: 2,
        end: 5,
        replacement: 'Q',
        selection: SegmentSelection.collapsed(3),
      );
      const second = SegmentEdit(start: 3, end: 3, replacement: '');
      final composed = _composeChecked(text, first, second);
      expect(composed, first);
    });

    test('a surrogate pair in the replacement stays whole', () {
      const first = SegmentEdit(start: 2, end: 2, replacement: 'a\u{1F600}b');
      const second = SegmentEdit(start: 3, end: 5, replacement: '\u{1F44D}');
      final composed = _composeChecked(text, first, second);
      expect(composed.replacement, 'a\u{1F44D}b');
      expect(composed.start, 2);
      expect(composed.end, 2);
    });
  });

  group('composeEdits selection', () {
    const text = 'abcdefghij';

    test('the second selection wins when it has one', () {
      const first = SegmentEdit(
        start: 2,
        end: 3,
        replacement: 'X',
        selection: SegmentSelection.collapsed(3),
      );
      const second = SegmentEdit(
        start: 3,
        end: 3,
        replacement: 'Y',
        selection: SegmentSelection(baseOffset: 1, extentOffset: 4),
      );
      final composed = _composeChecked(text, first, second);
      expect(
        composed.selection,
        const SegmentSelection(baseOffset: 1, extentOffset: 4),
      );
    });

    test('the first selection maps through a second without one', () {
      const first = SegmentEdit(
        start: 2,
        end: 3,
        replacement: 'XYZ',
        selection: SegmentSelection(baseOffset: 1, extentOffset: 5),
      );
      // Before the second range, at its end and inside it.
      const second = SegmentEdit(start: 3, end: 5, replacement: '1234');
      final composed = _composeChecked(text, first, second);
      expect(
        composed.selection,
        const SegmentSelection(baseOffset: 1, extentOffset: 7),
      );
      const inside = SegmentEdit(
        start: 2,
        end: 3,
        replacement: 'XYZ',
        selection: SegmentSelection.collapsed(4),
      );
      expect(
        _composeChecked(text, inside, second).selection,
        const SegmentSelection.collapsed(7),
      );
    });

    test('no selection on either edit gives none', () {
      const first = SegmentEdit(start: 2, end: 3, replacement: 'X');
      const second = SegmentEdit(start: 3, end: 3, replacement: 'Y');
      expect(_composeChecked(text, first, second).selection, isNull);
    });
  });
}
