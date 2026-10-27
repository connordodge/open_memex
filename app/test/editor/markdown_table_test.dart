// WI #202 (Tables 1): the one table cell splitter and parseTable (Spec #197
// R1, R2, R5, R6; rulings D10, L6), and the pure list-indent contracts next
// to a table (ruling D11; #193's indentListItems is read only here).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/list_indent.dart';
import 'package:open_memex_app/src/editor/markdown_table.dart';

/// The text of each of [cells] in [source].
List<String> _texts(List<TableCell> cells, String source) => [
  for (final c in cells) c.text(source),
];

/// `(start, end)` of each of [cells].
List<(int, int)> _spans(List<TableCell> cells) => [
  for (final c in cells) (c.start, c.end),
];

/// The table rows of [text] (atSegmentStart true, as indentListItems splits).
List<RowSpec> _tables(String text) => [
  for (final r in splitRows(text, atSegmentStart: true))
    if (r.kind == RowKind.table) r,
];

/// The text of each table row of [text].
List<String> _tableTexts(String text) => [
  for (final r in _tables(text)) text.substring(r.textStart, r.textEnd),
];

void main() {
  group('splitTableLine (D10, Spec 197 R2)', () {
    test('cells are trimmed source ranges of the line', () {
      const outer = '| a | bb |';
      final line = splitTableLine(outer);
      expect((line.start, line.end), (0, outer.length));
      expect(_spans(line.cells), [(2, 3), (6, 8)]);
      expect(_texts(line.cells, outer), ['a', 'bb']);

      const bare = 'a | b';
      expect(_spans(splitTableLine(bare).cells), [(0, 1), (4, 5)]);

      // Spaces and tabs around a cell are not part of it.
      const padded = '  a  |\tb\t';
      expect(_spans(splitTableLine(padded).cells), [(2, 3), (7, 8)]);
      expect(_texts(splitTableLine('|a|').cells, '|a|'), ['a']);
    });

    test('the cell splitting pipes are reported in order', () {
      expect(splitTableLine('| a | bb |').pipes, [0, 4, 9]);
      expect(splitTableLine('a | b').pipes, [2]);
      expect(splitTableLine('| a |').pipes, [0, 4]);
      expect(splitTableLine('abc').pipes, isEmpty);
      expect(splitTableLine('abc').cells, hasLength(1));
    });

    test('an escaped pipe does not split a cell and keeps its backslash', () {
      const one = 'a \\| b';
      final split = splitTableLine(one);
      expect(_texts(split.cells, one), ['a \\| b']);
      expect(_spans(split.cells), [(0, 6)]);
      expect(split.pipes, isEmpty);

      const two = '| a \\| b | c |';
      final line = splitTableLine(two);
      expect(_texts(line.cells, two), ['a \\| b', 'c']);
      expect(_spans(line.cells), [(2, 8), (11, 12)]);
      expect(line.pipes, [0, 9, 13]);
    });

    test('an escaped final pipe is cell text not a trailing pipe', () {
      const text = '| a \\|';
      final line = splitTableLine(text);
      expect(_texts(line.cells, text), ['a \\|']);
      expect(line.pipes, [0]);
    });

    test('a pipe inside a wikilink does not split its cell', () {
      for (final link in ['[[Title|alias]]', '[[Title~kind|alias]]']) {
        final text = '| $link | x |';
        final line = splitTableLine(text);
        expect(_texts(line.cells, text), [link, 'x'], reason: link);
        expect(line.pipes, [
          0,
          text.indexOf(' | x') + 1,
          text.length - 1,
        ], reason: link);
      }
      // Two wikilinks in one line, each kept whole.
      const both = '[[A|a]] | [[B~k|b]]';
      expect(_texts(splitTableLine(both).cells, both), [
        '[[A|a]]',
        '[[B~k|b]]',
      ]);
    });

    test('a pipe in an unclosed wikilink splits the cell', () {
      const text = '| [[a|b |';
      expect(_texts(splitTableLine(text).cells, text), ['[[a', 'b']);
    });

    test('one leading and one trailing pipe make no extra cells', () {
      for (final (text, cells) in [
        ('| a |', ['a']),
        ('a |', ['a']),
        ('| a', ['a']),
        ('| a |   ', ['a']),
        ('  | a |', ['a']),
        ('| a | b |', ['a', 'b']),
        ('| | a |', ['', 'a']),
        ('| a | |', ['a', '']),
      ]) {
        expect(_texts(splitTableLine(text).cells, text), cells, reason: text);
      }
    });

    test('an empty cell is an empty range between its pipes', () {
      const text = '| a |   | c |';
      final cells = splitTableLine(text).cells;
      expect(cells, hasLength(3));
      final empty = cells[1];
      expect(empty.start, empty.end);
      expect(empty.start, inInclusiveRange(5, 8));
      expect(empty.text(text), '');
    });

    test('split offsets index the whole text for a line inside it', () {
      const text = 'x\n| a | b |\ny';
      final line = splitTableLine(text, start: 2, end: 11);
      expect((line.start, line.end), (2, 11));
      expect(_spans(line.cells), [(4, 5), (8, 9)]);
      expect(line.pipes, [2, 6, 10]);
      expect(_texts(line.cells, text), ['a', 'b']);
      // The end defaults to the text end.
      expect(splitTableLine('| a |').end, 5);
      expect(
        splitTableLine('zz| a |', start: 2).cells.single,
        isA<TableCell>(),
      );
      expect(_spans(splitTableLine('zz| a |', start: 2).cells), [(4, 5)]);
    });

    test('cells around emoji keep code unit ranges', () {
      const text = '| 😀 | b |';
      final line = splitTableLine(text);
      expect(_spans(line.cells), [(2, 4), (7, 8)]);
      expect(_texts(line.cells, text), ['😀', 'b']);
    });

    test('a table cell compares by its source range', () {
      final start = 'ab'.length;
      final end = start + 3;
      final a = TableCell(start, end);
      final b = TableCell(start, end);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(TableCell(start, end + 1)));
      expect(a, isNot(TableCell(start + 1, end)));
      expect(a.text('ab|cde|'), '|cd');
      expect(a.toString(), contains('$start'));
    });
  });

  group('parseTable (Spec 197 R1 R5 R6)', () {
    test('parseTable reads the alignment of each delimiter cell', () {
      expect(parseTable('| a | b | c | d |\n|:--|:-:|--:|---|')!.alignments, [
        TableAlign.left,
        TableAlign.center,
        TableAlign.right,
        TableAlign.left,
      ]);
      expect(parseTable('| a | b | c |\n| :- | -: | :------: |')!.alignments, [
        TableAlign.left,
        TableAlign.right,
        TableAlign.center,
      ]);
      expect(parseTable('a | b\n-- | :-:\n1 | 2')!.alignments, [
        TableAlign.left,
        TableAlign.center,
      ]);
    });

    test('parseTable gives header cells and body rows with source ranges', () {
      const text = '| h1 | h2 |\r\n|---|--:|\r\n| x | y |\r\n|  z | ww |';
      final table = parseTable(text)!;
      expect(table.columnCount, 2);
      expect(_texts(table.header.cells, text), ['h1', 'h2']);
      expect((table.header.start, table.header.end), (0, 11));
      expect((table.delimiter.start, table.delimiter.end), (13, 22));
      expect(table.alignments, [TableAlign.left, TableAlign.right]);
      expect(table.body, hasLength(2));
      expect(_texts(table.body[0].cells, text), ['x', 'y']);
      expect(_texts(table.body[1].cells, text), ['z', 'ww']);
      expect((table.body[0].line.start, table.body[0].line.end), (24, 33));
      // A displayed cell offset maps back to field offsets.
      final z = table.body[1].cells.first;
      expect(z.start, text.lastIndexOf('z'));
      expect(z.end, z.start + 1);
      expect(table.body[1].line.end, text.length);
      for (final row in table.body) {
        expect(row.beyond, isEmpty);
      }
    });

    test(
      'a body row with fewer cells than the header reports only its cells',
      () {
        const text = '| a | b | c |\n|---|---|---|\n| 1 |\n| 2 | 3 |';
        final table = parseTable(text)!;
        expect(table.columnCount, 3);
        expect(_texts(table.body[0].cells, text), ['1']);
        expect(_texts(table.body[1].cells, text), ['2', '3']);
        expect(table.body[0].beyond, isEmpty);
        expect(table.body[1].beyond, isEmpty);
      },
    );

    test(
      'cells past the header column count are reported as beyond the column count',
      () {
        const text =
            '| a | b |\n|---|---|\n| 1 | 2 | 3 | 4 |\n| 5 | 6 |\n| 7 | 8 | 9 |';
        final table = parseTable(text)!;
        final wide = table.body[0];
        expect(_texts(wide.cells, text), ['1', '2']);
        expect(_texts(wide.beyond, text), ['3', '4']);
        expect(_spans(wide.beyond), [
          (text.indexOf('3'), text.indexOf('3') + 1),
          (text.indexOf('4'), text.indexOf('4') + 1),
        ]);
        expect(wide.line.cells, hasLength(4));
        // Exactly the column count: nothing beyond.
        expect(_texts(table.body[1].cells, text), ['5', '6']);
        expect(table.body[1].beyond, isEmpty);
        // One past it.
        expect(_texts(table.body[2].cells, text), ['7', '8']);
        expect(_texts(table.body[2].beyond, text), ['9']);
      },
    );

    test('a header only table has zero body rows', () {
      final table = parseTable('| a | b |\n|---|---|')!;
      expect(table.columnCount, 2);
      expect(table.body, isEmpty);
      expect(table.alignments, [TableAlign.left, TableAlign.left]);
    });

    test('a single column table with pipes has one column', () {
      const text = '| a |\n|:-:|\n| 1 |';
      final table = parseTable(text)!;
      expect(table.columnCount, 1);
      expect(_spans(table.header.cells), [(2, 3)]);
      expect(table.alignments, [TableAlign.center]);
      expect(_texts(table.body.single.cells, text), ['1']);
    });

    test('parseTable cells keep escaped and wikilink pipes whole', () {
      const text =
          '| [[T|al]] | a \\| b |\n|---|---|\n| [[X~k|y]] | 2 | [[Z|z]] |';
      final table = parseTable(text)!;
      expect(_texts(table.header.cells, text), ['[[T|al]]', 'a \\| b']);
      expect(_texts(table.body.single.cells, text), ['[[X~k|y]]', '2']);
      expect(_texts(table.body.single.beyond, text), ['[[Z|z]]']);
    });

    test('parseTable reads an indented table', () {
      const text = '  | a |\n   |---|\n | 1 |';
      final table = parseTable(text)!;
      expect(_spans(table.header.cells), [(4, 5)]);
      expect(_texts(table.body.single.cells, text), ['1']);
    });

    test('parseTable gives null for text that is not a table', () {
      for (final text in [
        '',
        'just text',
        '| a | b |',
        '| a | b |\n| 1 | 2 |',
        '| a | b |\n|---|',
        '| a | b |\n|---|---|---|',
        '| a | b |\n|-x-|---|',
        '- | -\n|---|---|',
      ]) {
        expect(parseTable(text), isNull, reason: text);
      }
    });
  });

  group('list indent next to a table (D11, Spec 197 R24 pure part)', () {
    test('indentListItems with the caret in a table line returns null', () {
      const text = '- a\n- b\n| x | y |\n|---|---|\n| 1 | 2 |\n';
      final table = _tables(text).single;
      for (var o = table.textStart; o <= table.textEnd; o++) {
        final caret = SegmentSelection.collapsed(o);
        expect(indentListItems(text, caret), isNull, reason: 'indent at $o');
        expect(
          indentListItems(text, caret, outdent: true),
          isNull,
          reason: 'outdent at $o',
        );
      }
      // Below a nested item too: the table is no list item to outdent.
      const nested = '- a\n  - b\n| x |\n|---|\n';
      final inner = _tables(nested).single;
      for (var o = inner.textStart; o <= inner.textEnd; o++) {
        expect(
          indentListItems(nested, SegmentSelection.collapsed(o), outdent: true),
          isNull,
          reason: 'outdent at $o',
        );
      }
    });

    test(
      'a selection spanning a list item and a table moves only the item',
      () {
        const table = '| x | y |\n|---|---|\n| 1 | 2 |';
        const text = '- a\n- b\n$table\n';
        final into = text.indexOf('| 1');
        final edit = indentListItems(
          text,
          SegmentSelection(baseOffset: text.indexOf('b'), extentOffset: into),
        );
        expect(edit, isNotNull);
        final after = edit!.apply(text);
        expect(after, '- a\n  - b\n$table\n');
        expect(_tableTexts(after), [table]);

        // Outdent the other way.
        const nested = '- a\n  - b\n$table\n';
        final back = indentListItems(
          nested,
          SegmentSelection(
            baseOffset: nested.indexOf('b'),
            extentOffset: nested.indexOf('| 1'),
          ),
          outdent: true,
        );
        expect(back!.apply(nested), text);
      },
    );

    test(
      'after an indent next to a table the table bytes and the table row count are unchanged',
      () {
        const first = '| h |\n|---|';
        const second = '| x | y |\n|---|---|\n| 1 | 2 |';
        const text = '$first\n- a\n- b\n$second\n';
        expect(_tableTexts(text), [first, second]);
        final edit = indentListItems(
          text,
          SegmentSelection.collapsed(text.indexOf('b')),
        );
        final after = edit!.apply(text);
        expect(after, '$first\n- a\n  - b\n$second\n');
        expect(_tableTexts(after), [first, second]);
        expect(_tables(after), hasLength(_tables(text).length));
      },
    );

    test(
      'an item right after a table has no previous sibling to indent under',
      () {
        const text = '- x\n| t |\n|---|\n- a\n';
        expect(_tables(text), hasLength(1));
        expect(
          indentListItems(text, SegmentSelection.collapsed(text.indexOf('a'))),
          isNull,
        );
      },
    );
  });

  group('purity and the one splitter (D2, D10)', () {
    /// The import, export and part lines of the library at [path].
    List<String> imports(String path) => [
      for (final line in const LineSplitter().convert(
        File(path).readAsStringSync(),
      ))
        if (RegExp(r'^\s*(import|export|part)\s').hasMatch(line)) line,
    ];

    test('markdown_table imports nothing from package flutter', () {
      const path = 'lib/src/editor/markdown_table.dart';
      expect(File(path).readAsStringSync(), contains('splitTableLine'));
      for (final line in imports(path)) {
        expect(line, isNot(contains('package:flutter')), reason: path);
        expect(line, isNot(contains('dart:ui')), reason: path);
      }
    });

    test('classifyLines splits table cells with the one cell splitter', () {
      const lines = 'lib/src/editor/markdown_lines.dart';
      expect(
        imports(lines).where((l) => l.contains('markdown_table.dart')),
        hasLength(1),
        reason: '$lines imports markdown_table.dart',
      );
      for (final path in [lines, 'lib/src/editor/editor_rows.dart']) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains('RegExp(')),
          reason: '$path: no second splitter or regex',
        );
      }
    });
  });
}
