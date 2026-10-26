// WI #162 (A3): structural row edits and Source-mode list continuation
// (Spec #157 R14-R20, R31; rulings D2, D17).
//
// Every case is written with `|` marking the caret (Source selections use
// two). Edits are applied here with a plain
// splice, so these tests pin A3's output bytes and selection, not A1's
// `SegmentEdit.apply`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_edits.dart';

/// The text of [marked] without its single `|`, and the caret offset the
/// `|` marks.
(String, int) _caret(String marked) {
  final at = marked.indexOf('|');
  expect(at, isNot(-1), reason: 'case $marked has no caret');
  expect(marked.indexOf('|', at + 1), -1, reason: 'case $marked has two');
  return (marked.replaceFirst('|', ''), at);
}

List<RowSpec> _rows(String text) => splitRows(text, atSegmentStart: false);

/// The row whose text holds [offset] (its text range, ends included).
int _rowAt(List<RowSpec> rows, int offset) {
  final i = rows.indexWhere(
    (r) => r.textStart <= offset && offset <= r.textEnd,
  );
  expect(i, isNot(-1), reason: 'no row holds offset $offset');
  return i;
}

String _apply(String text, SegmentEdit edit) =>
    text.replaceRange(edit.start, edit.end, edit.replacement);

/// [edit] turns [text] into [after] (with `|` marking the caret after it).
void _expectEdit(String text, SegmentEdit? edit, String after, {String? why}) {
  final (want, caret) = _caret(after);
  expect(edit, isNotNull, reason: why ?? text);
  expect(_apply(text, edit!), want, reason: why ?? text);
  expect(
    edit.selection,
    SegmentSelection.collapsed(caret),
    reason: why ?? text,
  );
}

/// Runs [op] with the caret marked in [before] on the row holding it.
SegmentEdit? _atCaret(
  String before,
  SegmentEdit? Function(String text, List<RowSpec> rows, int row, int caret) op,
) {
  final (text, caret) = _caret(before);
  final rows = _rows(text);
  return op(text, rows, _rowAt(rows, caret), caret);
}

/// Runs [op] on the row holding the caret marked in [before] (the caret is
/// only used to pick the row).
SegmentEdit? _onRow(
  String before,
  SegmentEdit? Function(String text, List<RowSpec> rows, int row) op,
) {
  final (text, caret) = _caret(before);
  final rows = _rows(text);
  return op(text, rows, _rowAt(rows, caret));
}

/// `(before, after)` pairs: [op] at the caret of `before` gives `after`.
void _expectCases(
  List<(String, String)> cases,
  SegmentEdit? Function(String text, List<RowSpec> rows, int row, int caret) op,
) {
  for (final (before, after) in cases) {
    final (text, _) = _caret(before);
    _expectEdit(text, _atCaret(before, op), after, why: before);
  }
}

void _expectRowCases(
  List<(String, String)> cases,
  SegmentEdit? Function(String text, List<RowSpec> rows, int row) op,
) {
  for (final (before, after) in cases) {
    final (text, _) = _caret(before);
    _expectEdit(text, _onRow(before, op), after, why: before);
  }
}

/// Source mode: `sourceEnter` with the caret (or a selection from the first
/// `|` to the second, in either direction when [backward]) in [marked].
SegmentEdit? _source(
  String marked, {
  bool shift = false,
  bool backward = false,
}) {
  final first = marked.indexOf('|');
  final second = marked.indexOf('|', first + 1);
  final text = marked.replaceAll('|', '');
  final SegmentSelection selection;
  if (second == -1) {
    selection = SegmentSelection.collapsed(first);
  } else {
    final end = second - 1;
    selection = backward
        ? SegmentSelection(baseOffset: end, extentOffset: first)
        : SegmentSelection(baseOffset: first, extentOffset: end);
  }
  return sourceEnter(text, selection, shift: shift);
}

void _expectSource(String marked, String after, {bool backward = false}) {
  final text = marked.replaceAll('|', '');
  _expectEdit(text, _source(marked, backward: backward), after, why: marked);
}

void main() {
  group('splitItem (R15)', () {
    test(
      'splitItem splits a bullet at the caret and puts the caret at the start of the new item text',
      () {
        _expectCases(const [
          ('- a|b', '- a\n- |b'),
          ('- |ab', '- \n- |ab'),
          ('- ab|', '- ab\n- |'),
          ('p\n- a|b\nq', 'p\n- a\n- |b\nq'),
          ('\t- a|b', '\t- a\n\t- |b'),
          ('    - a|b', '    - a\n    - |b'),
        ], splitItem);
      },
    );

    test('splitItem repeats the star and plus bullet characters', () {
      _expectCases(const [
        ('* a|b', '* a\n* |b'),
        ('+ a|b', '+ a\n+ |b'),
        ('  * x|', '  * x\n  * |'),
      ], splitItem);
    });

    test(
      'splitItem numbers the new item N plus 1 and keeps its indentation',
      () {
        _expectCases(const [
          ('  9. x|', '  9. x\n  10. |'),
          ('1. a|b', '1. a\n2. |b'),
          ('99. z|', '99. z\n100. |'),
        ], splitItem);
      },
    );

    test('splitItem does not renumber a later numbered item', () {
      _expectCases(const [
        ('1. a|\n2. b', '1. a\n2. |\n2. b'),
        ('1. a|b\n2. c\n3. d', '1. a\n2. |b\n2. c\n3. d'),
      ], splitItem);
    });

    test(
      'splitItem continues a task as an unchecked task with the same bullet character',
      () {
        _expectCases(const [
          ('- [x] a|b', '- [x] a\n- [ ] |b'),
          ('- [ ] a|b', '- [ ] a\n- [ ] |b'),
          ('* [X] a|b', '* [X] a\n* [ ] |b'),
          ('  + [x] t|', '  + [x] t\n  + [ ] |'),
        ], splitItem);
      },
    );

    test('splitItem gives the new line the CRLF terminator of a CRLF line', () {
      _expectCases(const [
        ('- a|b\r\nc', '- a\r\n- |b\r\nc'),
        ('x\r\n- a|b\r\n', 'x\r\n- a\r\n- |b\r\n'),
        ('3. a|\r\n4. b', '3. a\r\n4. |\r\n4. b'),
        ('- a|b\nc', '- a\n- |b\nc'),
      ], splitItem);
    });

    test('splitItem returns null in a prose row', () {
      expect(_atCaret('ab|c', splitItem), isNull);
      expect(_atCaret('- i\nab|c', splitItem), isNull);
    });
  });

  group('enterOnEmpty (R16)', () {
    test(
      'enterOnEmpty turns an empty item into an empty line with the caret on it',
      () {
        _expectRowCases(const [
          ('  - |', '|'),
          ('- [ ] |', '|'),
          ('- |', '|'),
          ('7. |', '|'),
          ('* [x] |', '|'),
        ], enterOnEmpty);
      },
    );

    test('enterOnEmpty leaves the surrounding lines unchanged', () {
      _expectRowCases(const [
        ('- a\n  - |\n- b', '- a\n|\n- b'),
        ('p\r\n- [ ] |\r\nq', 'p\r\n|\r\nq'),
        ('1. a\n2. |', '1. a\n|'),
      ], enterOnEmpty);
    });

    test('enterOnEmpty returns null for an item with text or a prose row', () {
      expect(_onRow('- a|', enterOnEmpty), isNull);
      expect(_onRow('ab|', enterOnEmpty), isNull);
    });
  });

  group('shiftEnter (R17)', () {
    test(
      'shiftEnter moves the text after the caret to a plain line below the item',
      () {
        _expectCases(const [
          ('- a|b', '- a\n|b'),
          ('- a|', '- a\n|'),
          ('  - [x] a|b', '  - [x] a\n|b'),
          ('3. a|b\n4. c', '3. a\n|b\n4. c'),
        ], shiftEnter);
      },
    );

    test('shiftEnter inherits the terminator of the split line', () {
      _expectCases(const [
        ('- a|b\r\nc', '- a\r\n|b\r\nc'),
        ('- a|b\nc', '- a\n|b\nc'),
      ], shiftEnter);
    });

    test('shiftEnter returns null in a prose row', () {
      expect(_atCaret('ab|c', shiftEnter), isNull);
    });
  });

  group('backspaceAtStart (R18)', () {
    test(
      'backspaceAtStart removes indentation and marker and keeps the caret before the text',
      () {
        _expectRowCases(const [
          ('  - [x] |text', '|text'),
          ('> |q', '|q'),
          ('3. |n', '|n'),
          ('- |a', '|a'),
          ('* [ ] |a', '|a'),
          ('\t+ |a', '|a'),
        ], backspaceAtStart);
      },
    );

    test(
      'backspaceAtStart leaves the other lines and terminators unchanged',
      () {
        _expectRowCases(const [
          ('p\n  - [x] |text\nq', 'p\n|text\nq'),
          ('a\r\n3. |n\r\n4. m', 'a\r\n|n\r\n4. m'),
        ], backspaceAtStart);
      },
    );

    test('backspaceAtStart returns null in a prose row', () {
      expect(_onRow('|ab', backspaceAtStart), isNull);
    });
  });

  group('joinPrevious (R19)', () {
    test(
      'joinPrevious joins a plain line onto the line above whether prose or item',
      () {
        _expectCases(const [
          // The line above is an item.
          ('- a\n|b', '- a|b'),
          ('- [x] a\n|b\nc', '- [x] a|b\nc'),
          ('- a\r\n|b', '- a|b'),
          ('- a\n|', '- a|'),
          // The line above is prose (an interior line of a prose row).
          ('a\n|b', 'a|b'),
          ('# H\r\n|b', '# H|b'),
          ('- i\nx\n|y', '- i\nx|y'),
        ], joinPrevious);
      },
    );

    test('joinPrevious returns null on the first line of the segment', () {
      expect(_atCaret('|ab', joinPrevious), isNull);
      expect(_atCaret('|ab\ncd', joinPrevious), isNull);
      expect(_atCaret('|', joinPrevious), isNull);
    });
  });

  group('deleteForwardAtEnd (R20)', () {
    test(
      'deleteForwardAtEnd drops only the indentation and marker of a next item line',
      () {
        _expectRowCases(const [
          ('a|\n- b', 'a|b'),
          ('a|\n  - b', 'a|b'),
          ('- a|\n- [x] b', '- a|b'),
          ('- a|\n10. b', '- a|b'),
          ('- a|\n> q', '- a|q'),
          ('- a|\r\n  * b\r\nc', '- a|b\r\nc'),
          ('x\n- a|\n- b\n- c', 'x\n- a|b\n- c'),
        ], deleteForwardAtEnd);
      },
    );

    test('deleteForwardAtEnd keeps the hash of a next heading line', () {
      _expectRowCases(const [
        ('- a|\n# H', '- a|# H'),
        ('- a|\r\n## H\r\nb', '- a|## H\r\nb'),
        ('- a|\nplain', '- a|plain'),
      ], deleteForwardAtEnd);
    });

    test('deleteForwardAtEnd returns null at the segment end', () {
      expect(_onRow('- a|', deleteForwardAtEnd), isNull);
      expect(_onRow('a\n- b|', deleteForwardAtEnd), isNull);
      expect(_onRow('ab|', deleteForwardAtEnd), isNull);
    });
  });

  group('sourceEnter (R31)', () {
    test(
      'sourceEnter continues a list line by the R15 and R16 rules on the whole body',
      () {
        for (final (before, after) in const [
          ('- a|', '- a\n- |'),
          ('- a|b', '- a\n- |b'),
          ('* a|', '* a\n* |'),
          ('  + a|', '  + a\n  + |'),
          ('  9. x|', '  9. x\n  10. |'),
          ('1. a|\n2. b', '1. a\n2. |\n2. b'),
          ('- [x] a|', '- [x] a\n- [ ] |'),
          ('* [X] a|b', '* [X] a\n* [ ] |b'),
          ('x\n- a|\ny', 'x\n- a\n- |\ny'),
          ('- a|\r\nb', '- a\r\n- |\r\nb'),
          // A prefix-only line loses its prefix.
          ('- a\n- |', '- a\n|'),
          ('  - |', '|'),
          ('- [ ] |', '|'),
          ('- a\n- |\n- b', '- a\n|\n- b'),
          ('3. |\r\nz', '|\r\nz'),
        ]) {
          _expectSource(before, after);
        }
      },
    );

    test(
      'sourceEnter returns null for quote lines fenced lines and lines without a prefix',
      () {
        for (final marked in const [
          '> q|',
          '> |',
          'plain|',
          '# H|',
          '#tag|',
          '1) x|',
          '|',
          '```\n- a|\n```',
          '```\n- a|',
          'x\n  ```\n  1. a|\n  ```\ny',
          '---\n- a|\n---\nbody',
        ]) {
          expect(_source(marked), isNull, reason: marked);
        }
      },
    );

    test('sourceEnter after a closed fence continues a list line again', () {
      _expectSource('```\n- a\n```\n- b|', '```\n- a\n```\n- b\n- |');
    });

    test('sourceEnter with shift returns null for a plain newline', () {
      expect(_source('- a|', shift: true), isNull);
      expect(_source('- [x] a|b', shift: true), isNull);
      expect(_source('- a|b|', shift: true), isNull);
    });

    test(
      'sourceEnter replaces a non collapsed selection before continuing',
      () {
        _expectSource('- a|bc|d', '- a\n- |d');
        _expectSource('- a|bc|d', '- a\n- |d', backward: true);
        _expectSource('- a|b\n- c|d', '- a\n- |d');
        _expectSource('1. x|yz|', '1. x\n2. |');
        // Replacing leaves a line without a prefix: a plain newline.
        expect(_source('a|b\n- c|d'), isNull);
      },
    );
  });

  // Contracts the row_edits doc comments promise beyond the AC examples
  // (verify-mode pins from the implementer handoff).
  group('documented contracts', () {
    test('splitItem and shiftEnter on a quote row insert a plain line', () {
      // R22: no blockquote continuation.
      _expectCases(const [
        ('> a|b', '> a\n|b'),
        ('> q|', '> q\n|'),
        ('> a|b\r\nc', '> a\r\n|b\r\nc'),
      ], splitItem);
      _expectCases(const [('> a|b', '> a\n|b')], shiftEnter);
    });

    test('enterOnEmpty removes the marker of an empty quote', () {
      _expectRowCases(const [
        ('> |', '|'),
        ('>|', '|'),
        ('p\n> |\nq', 'p\n|\nq'),
      ], enterOnEmpty);
    });

    test('splitItem splits an item whose text is empty', () {
      _expectCases(const [
        ('- |', '- \n- |'),
        ('3. |', '3. \n4. |'),
        ('- [x] |', '- [x] \n- [ ] |'),
      ], splitItem);
    });

    test(
      'splitItem and shiftEnter split at the text bounds when the caret is outside the item text',
      () {
        const text = '  - ab\r\nc';
        final rows = _rows(text);
        // In the indentation or marker: the split is at the text start.
        for (final caret in const [0, 1, 2, 3]) {
          _expectEdit(
            text,
            splitItem(text, rows, 0, caret),
            '  - \r\n  - |ab\r\nc',
            why: 'splitItem caret $caret',
          );
          _expectEdit(
            text,
            shiftEnter(text, rows, 0, caret),
            '  - \r\n|ab\r\nc',
            why: 'shiftEnter caret $caret',
          );
        }
        // Inside the terminator: the split is at the text end.
        _expectEdit(
          text,
          splitItem(text, rows, 0, 7),
          '  - ab\r\n  - |\r\nc',
          why: 'splitItem in the CRLF',
        );
        _expectEdit(
          text,
          shiftEnter(text, rows, 0, 7),
          '  - ab\r\n|\r\nc',
          why: 'shiftEnter in the CRLF',
        );
      },
    );

    test('splitItem keeps the width of a zero padded number', () {
      _expectCases(const [
        ('007. a|', '007. a\n008. |'),
        ('09. a|b', '09. a\n10. |b'),
        ('123456789. z|', '123456789. z\n123456790. |'),
      ], splitItem);
      _expectSource('  09. x|', '  09. x\n  10. |');
    });

    test('row edits count offsets in UTF-16 code units', () {
      // A surrogate pair before the caret: two code units.
      _expectCases(
        const [
          ('- \u{1F600}|x', '- \u{1F600}\n- |x'),
          ('\u{1F600}\n|b', '\u{1F600}|b'),
        ],
        (text, rows, row, caret) {
          return rows[row].isItem
              ? splitItem(text, rows, row, caret)
              : joinPrevious(text, rows, row, caret);
        },
      );
      _expectSource('- [ ] \u{1F600}|', '- [ ] \u{1F600}\n- [ ] |');
    });

    test('joinPrevious removes a line break that starts the segment', () {
      _expectCases(const [
        ('\r\n|b', '|b'),
        ('\n|b', '|b'),
        ('\r\n|', '|'),
      ], joinPrevious);
    });

    test(
      'joinPrevious returns null in an item row and away from a line start',
      () {
        const text = '- a\n- b\ncd';
        final rows = _rows(text);
        final item = rows.indexWhere((r) => r.start == 4);
        expect(rows[item].isItem, isTrue, reason: 'row $item is `- b`');
        expect(joinPrevious(text, rows, item, 4), isNull, reason: 'item row');
        final prose = rows.length - 1;
        expect(rows[prose].isItem, isFalse);
        expect(
          joinPrevious(text, rows, prose, 9),
          isNull,
          reason: 'caret between c and d',
        );
        expect(
          joinPrevious(text, rows, prose, 10),
          isNull,
          reason: 'caret at the end of cd',
        );
      },
    );

    test('deleteForwardAtEnd joins at the end of a multi line prose row', () {
      _expectRowCases(const [
        ('a\nb|\n- c', 'a\nb|c'),
        ('a\r\nb|\r\n- d', 'a\r\nb|d'),
      ], deleteForwardAtEnd);
    });

    test('sourceEnter returns null when the caret is before the line text', () {
      for (final marked in const [
        '|- a',
        '  |- a',
        '-| a',
        '1|. x',
        '- |[ ] t',
        'x\n  |* a',
      ]) {
        expect(_source(marked), isNull, reason: marked);
      }
    });

    test(
      'sourceEnter removes the prefix when the replaced selection leaves only a prefix',
      () {
        _expectSource('- |abc|', '|');
        _expectSource('  - [ ] |x|', '|');
        _expectSource('- a\n- |b|', '- a\n|');
        _expectSource('- a\r\n3. |bc|\r\nz', '- a\r\n|\r\nz');
        _expectSource('- |abc|', '|', backward: true);
      },
    );

    test('sourceEnter without the shift argument continues the list', () {
      final edit = sourceEnter('- a', SegmentSelection.collapsed(3));
      _expectEdit('- a', edit, '- a\n- |');
    });
  });

  group('purity (D2)', () {
    test('row_edits imports nothing from package flutter', () {
      // `flutter test` runs with the package root (`app/`) as cwd.
      const path = 'lib/src/editor/row_edits.dart';
      final source = File(path).readAsStringSync();
      expect(source, contains('sourceEnter'), reason: '$path was read');
      final imports = [
        for (final line in const LineSplitter().convert(source))
          if (RegExp(r'^\s*(import|export|part)\s').hasMatch(line)) line,
      ];
      for (final line in imports) {
        expect(line, isNot(contains('package:flutter')), reason: line);
        expect(line, isNot(contains('dart:ui')), reason: line);
      }
    });
  });
}
