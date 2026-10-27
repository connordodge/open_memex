// WI #194: pure list indent and outdent with renumbering (Spec #193 R2-R27,
// TD2, TD3; rulings D2, D3).
//
// Cases mark a collapsed caret with `|` in both the text before and the
// text after the edit; a caret case runs in live preview (`source: false`)
// and in Source (`source: true`), whose touch rules agree for a caret
// (R29). Non-collapsed selections are written as explicit offsets. Every
// non-null edit is checked to be the one minimal splice (R26, TD3).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/list_indent.dart';

/// The text of [marked] without its single `|`, and the offset it marks.
(String, int) _caret(String marked) {
  final at = marked.indexOf('|');
  expect(at, isNot(-1), reason: 'case $marked has no caret');
  expect(marked.indexOf('|', at + 1), -1, reason: 'case $marked has two');
  return (marked.replaceFirst('|', ''), at);
}

/// [edit] is the single minimal splice of [text]: it starts at the first
/// changed offset and its replacement ends at the last changed byte.
void _expectOneSplice(String text, SegmentEdit edit, {String? why}) {
  final minimal = SegmentEdit.diff(text, edit.apply(text));
  expect(edit.start, minimal.start, reason: 'splice start: ${why ?? text}');
  expect(edit.end, minimal.end, reason: 'splice end: ${why ?? text}');
  expect(
    edit.replacement,
    minimal.replacement,
    reason: 'splice replacement: ${why ?? text}',
  );
}

/// Tab (or Shift+Tab with [outdent]) with the caret marked in [before]
/// gives [after], whose `|` marks the caret after the edit; in both modes.
void _move(String before, String after, {bool outdent = false}) {
  final (text, caret) = _caret(before);
  final (want, caretAfter) = _caret(after);
  for (final source in [false, true]) {
    final why = '$before (outdent $outdent, source $source)';
    final edit = indentListItems(
      text,
      SegmentSelection.collapsed(caret),
      outdent: outdent,
      source: source,
    );
    expect(edit, isNotNull, reason: why);
    expect(edit!.apply(text), want, reason: why);
    _expectOneSplice(text, edit, why: why);
    expect(
      edit.selection,
      SegmentSelection.collapsed(caretAfter),
      reason: 'selection: $why',
    );
  }
}

/// Tab (or Shift+Tab) with the caret marked in [before] does nothing, in
/// both modes.
void _none(String before, {bool outdent = false}) {
  final (text, caret) = _caret(before);
  for (final source in [false, true]) {
    expect(
      indentListItems(
        text,
        SegmentSelection.collapsed(caret),
        outdent: outdent,
        source: source,
      ),
      isNull,
      reason: '$before (outdent $outdent, source $source)',
    );
  }
}

/// Tab (or Shift+Tab) with [selection] in [text] gives [after], and the
/// edit's selection is [selectionAfter] when given; in each of [modes]
/// (`source` values).
void _moveRange(
  String text,
  SegmentSelection selection,
  String after, {
  bool outdent = false,
  List<bool> modes = const [false, true],
  SegmentSelection? selectionAfter,
}) {
  for (final source in modes) {
    final why = '$text $selection (outdent $outdent, source $source)';
    final edit = indentListItems(
      text,
      selection,
      outdent: outdent,
      source: source,
    );
    expect(edit, isNotNull, reason: why);
    expect(edit!.apply(text), after, reason: why);
    _expectOneSplice(text, edit, why: why);
    if (selectionAfter != null) {
      expect(edit.selection, selectionAfter, reason: 'selection: $why');
    }
  }
}

/// Tab (or Shift+Tab) with [selection] in [text] does nothing, in each of
/// [modes].
void _noneRange(
  String text,
  SegmentSelection selection, {
  bool outdent = false,
  List<bool> modes = const [false, true],
}) {
  for (final source in modes) {
    expect(
      indentListItems(text, selection, outdent: outdent, source: source),
      isNull,
      reason: '$text $selection (outdent $outdent, source $source)',
    );
  }
}

SegmentSelection _sel(int base, int extent) =>
    SegmentSelection(baseOffset: base, extentOffset: extent);

void main() {
  group('R10 indentation bytes', () {
    test('R10 indent writes the content column under each marker', () {
      _move('- a\n- |b', '- a\n  - |b');
      _move('* a\n* |b', '* a\n  * |b');
      _move('+ a\n+ |b', '+ a\n  + |b');
      _move('- [ ] a\n- [x] |b', '- [ ] a\n  - [x] |b');
      _move('1. a\n2. |b', '1. a\n   1. |b');
      _move('10. a\n11. |b', '10. a\n    1. |b');
      _move('100. a\n101. |b', '100. a\n     1. |b');
    });

    test('R10 indent copies the indentation of the last existing child', () {
      _move('- a\n    - x\n- |b', '- a\n    - x\n    - |b');
      _move('- a\n\t- x\n- |b', '- a\n\t- x\n\t- |b');
      // The previous sibling's last child, not its first.
      _move('- a\n  - x\n - y\n- |b', '- a\n  - x\n - y\n - |b');
      // Searching back over deeper items to the previous sibling.
      _move('- a\n  - x\n    - y\n- |b', '- a\n  - x\n    - y\n  - |b');
    });

    test('R10 indent under a tab indented parent keeps its tab', () {
      _move('\t- p\n\t- |q', '\t- p\n\t  - |q');
      _move(' - a\n - |b', ' - a\n   - |b');
    });
  });

  group('R11 outdent', () {
    test('R11 outdent copies the parent indentation string exactly', () {
      _move('- a\n  - |b', '- a\n- |b', outdent: true);
      _move('\t- p\n\t  - |q', '\t- p\n\t- |q', outdent: true);
    });
  });

  group('R12 subtree', () {
    test('R12 indent moves the whole subtree by the same change', () {
      _move('- a\n- |b\n  - b1\n    - b2', '- a\n  - |b\n    - b1\n      - b2');
    });

    test('R12 subtree prefix replacement keeps a deeper tab', () {
      _move('- a\n- |b\n\t- b1', '- a\n  - |b\n  \t- b1');
    });

    test(
      'R12 mixed indentation falls back to spaces at the shifted column',
      () {
        _move('- p\n\t- |q\n        - r', '- p\n- |q\n    - r', outdent: true);
        // Indent: the subtree line does not start with the moved item old
        // indentation, so it becomes spaces at 4 + 2 columns.
        _move(' - a\n - |b\n\t- c', ' - a\n   - |b\n      - c');
      },
    );

    test('R12 lines after the subtree keep their bytes', () {
      _move(
        '- a\n- |b\n  - b1\n- c\n  - c1',
        '- a\n  - |b\n    - b1\n- c\n  - c1',
      );
    });
  });

  group('R13 outdent siblings', () {
    test('R13 outdent makes following siblings children with their bytes', () {
      _move('- a\n  - |b\n  - c', '- a\n- |b\n  - c', outdent: true);
    });

    test('R13 outdent re-indents a sibling that would become a grandchild', () {
      _move(
        '1. p\n   1. |q\n     - c\n   2. s',
        '1. p\n2. |q\n  - c\n  1. s',
        outdent: true,
      );
    });

    test('R13 re-indented siblings take their subtrees along', () {
      _move(
        '1. p\n   1. |q\n     - c\n   2. s\n      - t\n   3. u',
        '1. p\n2. |q\n  - c\n  1. s\n     - t\n  2. u',
        outdent: true,
      );
    });
  });

  group('R14 bytes kept', () {
    test('R14 CRLF terminators and the missing final newline are kept', () {
      _move('1. a\r\n2. |b\r\n3. c', '1. a\r\n   1. |b\r\n2. c');
      _move('- a\n- |b\n', '- a\n  - |b\n');
    });

    test('R14 markers task state and trailing spaces are unchanged', () {
      _move('- [ ] a\n- [X] |b  ', '- [ ] a\n  - [X] |b  ');
      _move(
        '* a\n* |b  \n  + c \n- [X] d ',
        '* a\n  * |b  \n    + c \n- [X] d ',
      );
      _move('+ a\n+ |b\t', '+ a\n  + |b\t');
    });
  });

  group('R16-R18 renumbering', () {
    test('R16 Tab on a middle item starts a sub-list and closes the gap', () {
      _move('1. a\n2. b\n3. |c\n4. d', '1. a\n2. b\n   1. |c\n3. d');
    });

    test('R16 Shift+Tab joins the parent run and renumbers below', () {
      _move(
        '1. a\n   1. x\n   2. |y\n2. b',
        '1. a\n   1. x\n2. |y\n3. b',
        outdent: true,
      );
    });

    test('R16 Tab joins and continues an existing sub-run', () {
      _move('1. a\n   1. x\n2. |c', '1. a\n   1. x\n   2. |c');
    });

    test(
      'R16 outdent restarts former siblings at 1 when it has no children',
      () {
        _move(
          '1. a\n   1. |x\n   2. y\n   3. z\n2. b',
          '1. a\n2. |x\n   1. y\n   2. z\n3. b',
          outdent: true,
        );
      },
    );

    test('R17 a run keeps its start number as written', () {
      _move('5. a\n6. |b\n7. c', '5. a\n   1. |b\n6. c');
    });

    test('R18 rewritten numbers keep their zero padding', () {
      _move('07. a\n08. |b\n09. c', '07. a\n    01. |b\n08. c');
    });

    test(
      'R17 the run left after a bullet sibling starts at the moved number',
      () {
        _move('- x\n1. |a\n2. b', '- x\n  1. |a\n1. b');
      },
    );

    test('R16 outdent keeps the start of the moved item numbered children', () {
      _move(
        '1. p\n   1. |q\n      3. r',
        '1. p\n2. |q\n   3. r',
        outdent: true,
      );
    });

    test('R16 a group move renumbers every run it touches', () {
      _moveRange(
        '1. a\n2. b\n3. c\n4. d',
        _sel(8, 14),
        '1. a\n   1. b\n   2. c\n2. d',
        selectionAfter: _sel(11, 20),
      );
    });
  });

  group('R19-R20', () {
    test('R19 untouched runs keep their numbers', () {
      _move('1. a\n1. |b\n\n1. x\n3. y', '1. a\n   1. |b\n\n1. x\n3. y');
    });

    test('R20 a number growing to two digits never re-indents children', () {
      _move(
        '8. a\n9. b\n   1. |c\n      - d',
        '8. a\n9. b\n10. |c\n   - d',
        outdent: true,
      );
    });

    test('R19 bullets and tasks are never renumbered', () {
      _move(
        '1. a\n2. |b\n   - x\n   - [ ] y\n3. c',
        '1. a\n   1. |b\n      - x\n      - [ ] y\n2. c',
      );
      _move('- a\n- |b\n- c', '- a\n  - |b\n- c');
      _move('- [ ] a\n- [ ] |b\n- [x] c', '- [ ] a\n  - [ ] |b\n- [x] c');
    });
  });

  group('R5 edges', () {
    test('R5 Tab on an item without a previous sibling returns null', () {
      _none('- |a\n- b');
      _none('- a\n  - |b\n  - c');
      _none('- a\n\n- |b');
      _none('> q\n- |b');
      // A cousin at the same depth under an earlier item is not a sibling.
      _none('- a\n  - x\n- b\n  - |y');
      // A code row ends the list.
      _none('- a\n```\nx\n```\n- |b');
    });

    test('R5 Shift+Tab on a top-level item returns null', () {
      _none('- |a\n- b', outdent: true);
      _none('- a\n- |b', outdent: true);
    });

    test('R5 quote prose and code lines return null in both directions', () {
      for (final outdent in [false, true]) {
        _none('> |q', outdent: outdent);
        _none('te|xt', outdent: outdent);
        _none('```\n- a\n- |b\n```', outdent: outdent);
        _none('- a\n> |q', outdent: outdent);
      }
    });

    test('R5 the caret line decides which item moves', () {
      // Offset 3 is the end of item a (first item); offset 4 starts line b.
      _none('- a|\n- b');
      _moveRange('- a\n- b', const SegmentSelection.collapsed(4), '- a\n  - b');
    });
  });

  group('TD2 frontmatter', () {
    test('TD2 frontmatter lines are not list items', () {
      const text = '---\n- a\n- b\n---\n- c\n- d';
      const inB = 10;
      for (final source in [false, true]) {
        expect(
          indentListItems(
            text,
            const SegmentSelection.collapsed(inB),
            source: source,
          ),
          isNull,
          reason: 'source $source',
        );
        expect(
          touchesListItem(
            text,
            const SegmentSelection.collapsed(inB),
            source: source,
          ),
          isFalse,
          reason: 'source $source',
        );
      }
      _move('---\n- a\n- b\n---\n- c\n- |d', '---\n- a\n- b\n---\n- c\n  - |d');
    });
  });

  group('R21-R24 group', () {
    test('R21 selecting siblings moves them with an unselected child', () {
      _moveRange(
        '- a\n- b\n  - b1\n- c',
        _sel(6, 18),
        '- a\n  - b\n    - b1\n  - c',
        selectionAfter: _sel(8, 24),
      );
    });

    test('R23 prose in the selection is untouched', () {
      _moveRange(
        '- a\n- b\npara',
        _sel(6, 10),
        '- a\n  - b\npara',
        selectionAfter: _sel(8, 12),
      );
    });

    test('R21 Shift+Tab over a group reverses the indent', () {
      _moveRange(
        '- a\n  - b\n    - b1\n  - c',
        _sel(8, 24),
        '- a\n- b\n  - b1\n- c',
        outdent: true,
        selectionAfter: _sel(6, 18),
      );
    });

    test('R21 an item inside a selected subtree moves once', () {
      _moveRange(
        '- a\n- b\n  - b1\n- c',
        _sel(6, 14),
        '- a\n  - b\n    - b1\n- c',
        selectionAfter: _sel(8, 18),
      );
      _moveRange(
        '- a\n  - b\n    - c',
        _sel(8, 17),
        '- a\n- b\n  - c',
        outdent: true,
        selectionAfter: _sel(6, 13),
      );
    });

    test('R21 a backward selection keeps its direction', () {
      _moveRange(
        '- a\n- b\n  - b1\n- c',
        _sel(18, 6),
        '- a\n  - b\n    - b1\n  - c',
        selectionAfter: _sel(24, 8),
      );
    });
  });

  group('R22 all or nothing', () {
    test(
      'R22 a group with an item lacking a previous sibling returns null',
      () {
        _noneRange('- a\n- b', _sel(2, 7));
        _noneRange('- a\n- b\n\n- c\n- d', _sel(6, 16));
        _noneRange('- a\n  - x\n- b\n  - y', _sel(8, 19));
      },
    );

    test('R22 a group with a top-level item returns null on Shift+Tab', () {
      _noneRange('- a\n  - b', _sel(2, 9), outdent: true);
    });
  });

  group('R25 boundary', () {
    const text = '- a\n- b\n- c';

    test('R25 live preview excludes an item reached at text offset 0', () {
      _moveRange(
        text,
        _sel(6, 10),
        '- a\n  - b\n- c',
        modes: const [false],
        selectionAfter: _sel(8, 12),
      );
      _moveRange(
        text,
        _sel(6, 11),
        '- a\n  - b\n  - c',
        modes: const [false],
        selectionAfter: _sel(8, 15),
      );
    });

    test('R25 Source excludes a line reached at its first character', () {
      _moveRange(
        text,
        _sel(6, 8),
        '- a\n  - b\n- c',
        modes: const [true],
        selectionAfter: _sel(8, 10),
      );
      _moveRange(text, _sel(6, 9), '- a\n  - b\n  - c', modes: const [true]);
      _moveRange(
        text,
        _sel(6, 10),
        '- a\n  - b\n  - c',
        modes: const [true],
        selectionAfter: _sel(8, 14),
      );
    });

    test('R25 touchesListItem agrees with the boundary in each mode', () {
      // Live preview: item text only, offset 0 excluded.
      expect(touchesListItem(text, _sel(8, 10)), isFalse);
      expect(touchesListItem(text, _sel(8, 11)), isTrue);
      expect(touchesListItem(text, _sel(6, 10)), isTrue);
      expect(touchesListItem(text, _sel(0, 2)), isFalse);
      expect(touchesListItem('para\n- c', _sel(0, 7)), isFalse);
      expect(touchesListItem('para\n- c', _sel(0, 8)), isTrue);
      // Source: whole lines, first character excluded.
      expect(touchesListItem(text, _sel(6, 8), source: true), isTrue);
      expect(touchesListItem(text, _sel(8, 10), source: true), isTrue);
      expect(touchesListItem(text, _sel(0, 2), source: true), isTrue);
      expect(touchesListItem('para\n- c', _sel(0, 5), source: true), isFalse);
      expect(touchesListItem('para\n- c', _sel(0, 6), source: true), isTrue);
    });

    test('R25 a selection inside the marker moves the item only in Source', () {
      _noneRange('- a\n- b', _sel(4, 5), modes: const [false]);
      _moveRange('- a\n- b', _sel(4, 5), '- a\n  - b', modes: const [true]);
    });
  });

  group('R3 R27 selection', () {
    test('R27 a caret keeps its offset in the moved item text', () {
      final edit = indentListItems(
        '- a\n- bc',
        const SegmentSelection.collapsed(7),
      );
      expect(edit, isNotNull);
      expect(edit!.apply('- a\n- bc'), '- a\n  - bc');
      expect(edit.selection, const SegmentSelection.collapsed(9));
      // Offset 0, the text end and an empty item.
      _move('- a\n- |b', '- a\n  - |b');
      _move('- a\n- b|', '- a\n  - b|');
      _move('- a\n- |', '- a\n  - |');
    });

    test('R3 a selection inside one item text moves it and stays on it', () {
      _moveRange(
        '- a\n- bcd',
        _sel(7, 9),
        '- a\n  - bcd',
        selectionAfter: _sel(9, 11),
      );
      _moveRange(
        '- a\n- bcd',
        _sel(9, 7),
        '- a\n  - bcd',
        selectionAfter: _sel(11, 9),
      );
    });

    test(
      'R27 a selection end in an untouched row shifts with the text before it',
      () {
        _moveRange(
          '- a\n- b\n- c',
          _sel(6, 10),
          '- a\n  - b\n- c',
          modes: const [false],
          selectionAfter: _sel(8, 12),
        );
        _moveRange(
          '- a\n- b\npara',
          _sel(6, 11),
          '- a\n  - b\npara',
          selectionAfter: _sel(8, 13),
        );
      },
    );

    test(
      'R29 a caret in the indentation or marker moves the item in both modes',
      () {
        for (final source in [false, true]) {
          for (final caret in [4, 5, 6]) {
            final edit = indentListItems(
              '- a\n- b',
              SegmentSelection.collapsed(caret),
              source: source,
            );
            expect(edit, isNotNull, reason: 'caret $caret source $source');
            expect(edit!.apply('- a\n- b'), '- a\n  - b');
          }
          final edit = indentListItems(
            '- a\n  - b',
            const SegmentSelection.collapsed(5),
            outdent: true,
            source: source,
          );
          expect(edit, isNotNull, reason: 'outdent source $source');
          expect(edit!.apply('- a\n  - b'), '- a\n- b');
        }
      },
    );
  });

  group('touchesListItem', () {
    test('touchesListItem is true for a caret anywhere on a list line', () {
      const text = '- a\n  1. b\n\t- [x] c\n- ';
      for (final source in [false, true]) {
        for (var offset = 0; offset <= text.length; offset++) {
          expect(
            touchesListItem(
              text,
              SegmentSelection.collapsed(offset),
              source: source,
            ),
            isTrue,
            reason: 'offset $offset source $source',
          );
        }
      }
      // Also at an edge, where indentListItems returns null.
      expect(
        touchesListItem('- a\n- b', const SegmentSelection.collapsed(2)),
        isTrue,
      );
    });

    test(
      'touchesListItem is false on quote prose fence and frontmatter lines',
      () {
        for (final text in [
          '> q',
          'text',
          '',
          '# heading\n\npara',
          '```\n- a\n- b\n```',
          '---\n- a\n---',
        ]) {
          for (final source in [false, true]) {
            for (var offset = 0; offset <= text.length; offset++) {
              expect(
                touchesListItem(
                  text,
                  SegmentSelection.collapsed(offset),
                  source: source,
                ),
                isFalse,
                reason: '$text offset $offset source $source',
              );
            }
          }
        }
        // The prose line before a list: its content end is not the list.
        for (final source in [false, true]) {
          expect(
            touchesListItem(
              'intro\n- a',
              const SegmentSelection.collapsed(5),
              source: source,
            ),
            isFalse,
          );
          expect(
            touchesListItem(
              'intro\n- a',
              const SegmentSelection.collapsed(6),
              source: source,
            ),
            isTrue,
          );
        }
      },
    );

    test(
      'touchesListItem is false for a selection over prose and quotes only',
      () {
        for (final source in [false, true]) {
          expect(
            touchesListItem('> q\npara\n- a', _sel(0, 8), source: source),
            isFalse,
          );
          expect(
            touchesListItem('> q\npara\n- a', _sel(0, 12), source: source),
            isTrue,
          );
        }
      },
    );
  });

  group('R26 one splice', () {
    test(
      'R26 the edit is one splice from the first to the last changed byte',
      () {
        const text = '1. a\n2. b\n3. c\n4. d';
        final edit = indentListItems(
          text,
          const SegmentSelection.collapsed(13),
        );
        expect(edit, isNotNull);
        expect(edit!.apply(text), '1. a\n2. b\n   1. c\n3. d');
        expect(edit.start, 10);
        expect(edit.end, 16);
        expect(edit.replacement, '   1. c\n3');
        expect(edit.selection, const SegmentSelection.collapsed(16));
      },
    );
  });
}
