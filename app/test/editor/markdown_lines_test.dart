// WI #160 (A1): the live-preview line grammar (Spec #157 R36, rulings D3,
// D4). Fence cases are ported from crates/memex-core/tests/blocks.rs and
// frontmatter cases from split_frontmatter in link_extractor.rs.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';

import '../support/markdown_fixtures.dart';

List<MdLine> _lines(String text, {bool atSegmentStart = false}) =>
    classifyLines(text, atSegmentStart: atSegmentStart);

List<MdLineKind> _kinds(String text, {bool atSegmentStart = false}) => [
  for (final l in _lines(text, atSegmentStart: atSegmentStart)) l.kind,
];

/// `(start, contentEnd, end, terminator)` of each line.
List<(int, int, int, String)> _ranges(String text) => [
  for (final l in _lines(text)) (l.start, l.contentEnd, l.end, l.terminator),
];

/// `(markerStart, markerEnd, separatorStart, separatorEnd)` of a line.
(int, int, int, int) _marker(MdLine l) =>
    (l.markerStart, l.markerEnd, l.separatorStart, l.separatorEnd);

/// The line's text after its marker and separator.
String _text(String source, MdLine l) =>
    source.substring(l.textStart, l.contentEnd);

const _b = MdLineKind.blank;
const _p = MdLineKind.plain;
const _open = MdLineKind.fenceOpen;
const _in = MdLineKind.fenceInside;
const _close = MdLineKind.fenceClose;
const _fm = MdLineKind.frontmatter;

void main() {
  group('terminators and line ranges (R36)', () {
    test(
      'lf and crlf terminators are kept verbatim with exact line ranges',
      () {
        expect(_ranges('a\r\nb\nc'), [
          (0, 1, 3, '\r\n'),
          (3, 4, 5, '\n'),
          (5, 6, 6, ''),
        ]);
        expect(_ranges('x\r\n'), [(0, 1, 3, '\r\n'), (3, 3, 3, '')]);
      },
    );

    test('a lone carriage return is content not a terminator', () {
      expect(_ranges('a\rb\nc\r'), [(0, 3, 4, '\n'), (4, 6, 6, '')]);
      expect(_kinds('a\rb\nc\r'), [_p, _p]);
    });

    test('an empty segment is one empty blank line', () {
      final lines = _lines('');
      expect(lines, hasLength(1));
      expect(lines.single.kind, _b);
      expect(
        (lines.single.start, lines.single.contentEnd, lines.single.end),
        (0, 0, 0),
      );
      expect(lines.single.terminator, '');
    });

    test('a trailing terminator ends in an empty line', () {
      expect(_ranges('a\n'), [(0, 1, 2, '\n'), (2, 2, 2, '')]);
      expect(_kinds('a\n'), [_p, _b]);
    });

    test('blank lines are empty or whitespace only', () {
      expect(_kinds('\n  \n\t\n'), [_b, _b, _b, _b]);
    });

    test('plain text is plain with no marker', () {
      final l = _lines('hello world').single;
      expect(l.kind, _p);
      expect(_marker(l), (0, 0, 0, 0));
      expect(l.textStart, 0);
      expect(l.indent, 0);
      expect(l.isItem, isFalse);
    });

    test('lines tile every fixture in order from 0 to its length', () {
      for (final MapEntry(key: name, value: text) in markdownFixtures.entries) {
        for (final atStart in [false, true]) {
          final lines = _lines(text, atSegmentStart: atStart);
          expect(lines, isNotEmpty, reason: name);
          expect(lines.first.start, 0, reason: name);
          expect(lines.last.end, text.length, reason: name);
          expect(lines.last.terminator, '', reason: name);
          for (var i = 0; i < lines.length; i++) {
            final l = lines[i];
            if (i > 0) expect(l.start, lines[i - 1].end, reason: '$name $i');
            expect(
              text.substring(l.contentEnd, l.end),
              l.terminator,
              reason: '$name $i',
            );
            expect(
              text.substring(l.start, l.contentEnd).contains('\n'),
              isFalse,
              reason: '$name $i',
            );
            if (i < lines.length - 1) {
              expect(['\n', '\r\n'], contains(l.terminator));
            }
          }
          expect(
            lines.length,
            '\n'.allMatches(text).length + 1,
            reason: '$name: one more line than terminators',
          );
        }
      }
    });
  });

  group('fenced code (R36, D3 blocks.rs)', () {
    test(
      'a fence opens after leading spaces or a tab and the next fence line closes',
      () {
        expect(_kinds('  ```\ncode\n\t```\nafter'), [_open, _in, _close, _p]);
        expect(_kinds('```js\nx\n```js\n- a'), [
          _open,
          _in,
          _close,
          MdLineKind.bullet,
        ]);
        expect(_kinds('```\r\nx\r\n```\r\n'), [_open, _in, _close, _b]);
      },
    );

    test('an unclosed fence runs to the segment end', () {
      expect(_kinds('p\n```\n- a\n\n# h\n'), [_p, _open, _in, _in, _in, _in]);
    });

    test('tilde fences and indented code are plain', () {
      expect(_kinds('~~~\ncode\n~~~\n    indented\n'), [_p, _p, _p, _p, _b]);
    });

    test(
      'lines inside a fence are fence content never items headings rules or quotes',
      () {
        const text =
            '```\n- a\n* b\n+ c\n1. d\n- [ ] e\n# f\n> g\n---\n***\n\n```';
        expect(_kinds(text), [_open, for (var i = 0; i < 10; i++) _in, _close]);
        for (final l in _lines(text).where((l) => l.kind == _in)) {
          expect(_marker(l), (l.start, l.start, l.start, l.start));
          expect(l.level, 0);
          expect(l.number, isNull);
          expect(l.done, isFalse);
        }
      },
    );

    test('parity blocks rs fenced code with a blank line is one fence', () {
      const text = 'Before.\n\n```\nlet a = 1;\n\nlet b = 2;\n```\n\nAfter.';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [_p, _b, _open, _in, _in, _in, _close, _b, _p],
      );
      // Rust: Code block 9..39.
      expect(lines[2].start, 9);
      expect(lines[6].contentEnd, 39);
    });

    test(
      'parity blocks rs never splits inside a fence on list or heading lines',
      () {
        const text = '```rust\n- not a list\n# not a heading\n\n```';
        final lines = _lines(text);
        expect([for (final l in lines) l.kind], [_open, _in, _in, _in, _close]);
        // Rust: Code block 0..41.
        expect(lines.first.start, 0);
        expect(lines.last.contentEnd, 41);
      },
    );

    test('parity blocks rs unclosed fence runs to end of input', () {
      const text = 'Before.\n\n```\ncode\n\nmore\n';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [_p, _b, _open, _in, _in, _in, _in],
      );
      // Rust: Code block 9..23 (its trailing blank lines aside).
      expect(lines[2].start, 9);
      expect(lines[5].contentEnd, 23);
    });
  });

  group('headings (R36)', () {
    test('headings are one to six hashes then one space at line start', () {
      const text = '# a\n## b\n### c\n#### d\n##### e\n###### f\n# ';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [for (var i = 0; i < 7; i++) MdLineKind.heading],
      );
      expect([for (final l in lines) l.level], [1, 2, 3, 4, 5, 6, 1]);
      for (final l in lines) {
        expect(_marker(l), (
          l.start,
          l.start + l.level,
          l.start + l.level,
          l.start + l.level + 1,
        ));
      }
      expect(_text(text, lines[3]), 'd');
      expect(_text(text, lines.last), '');
      expect(lines.first.isItem, isFalse);
    });

    test(
      'an indented hash line is plain because a heading starts at column zero',
      () {
        expect(_kinds('  # a\n\t## b\n # c\n# d'), [
          _p,
          _p,
          _p,
          MdLineKind.heading,
        ]);
        for (final l in _lines('  # a')) {
          expect(l.level, 0);
          expect(_marker(l), (0, 0, 0, 0));
        }
      },
    );

    test('seven hashes and hashes without a space are plain', () {
      expect(_kinds('####### x\n#tag\n#\n##\n#\tx'), [_p, _p, _p, _p, _p]);
      for (final l in _lines('#tag\n#')) {
        expect(l.level, 0);
      }
    });
  });

  group('bullets (R36)', () {
    test('dash star and plus with one space are bullets', () {
      const text = '- a\n* b\n+ c';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [MdLineKind.bullet, MdLineKind.bullet, MdLineKind.bullet],
      );
      expect(
        [for (final l in lines) _marker(l)],
        [(0, 1, 1, 2), (4, 5, 5, 6), (8, 9, 9, 10)],
      );
      expect([for (final l in lines) _text(text, l)], ['a', 'b', 'c']);
      expect(lines.first.isItem, isTrue);
    });

    test('an empty bullet is an item and a bare dash is plain', () {
      const text = '- \n-\n-x\n-\tx';
      final lines = _lines(text);
      expect([for (final l in lines) l.kind], [MdLineKind.bullet, _p, _p, _p]);
      expect(_marker(lines.first), (0, 1, 1, 2));
      expect(_text(text, lines.first), '');
    });

    test('indent is measured in columns with a tab as four', () {
      const text = '  - a\n\t- b\n\t\t- c\n    - d';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [for (var i = 0; i < 4; i++) MdLineKind.bullet],
      );
      expect([for (final l in lines) l.indent], [2, 4, 8, 4]);
      expect([for (final l in lines) l.markerStart], [2, 7, 13, 21]);
      expect([for (final l in lines) _text(text, l)], ['a', 'b', 'c', 'd']);
    });
  });

  group('numbered items (R36)', () {
    test(
      'numbered items have one to nine digits a dot and one space and keep the number as written',
      () {
        const text = '1. a\n10. b\n007. c\n123456789. d\n  2. e';
        final lines = _lines(text);
        expect(
          [for (final l in lines) l.kind],
          [for (var i = 0; i < 5; i++) MdLineKind.numbered],
        );
        expect(
          [for (final l in lines) l.number],
          ['1', '10', '007', '123456789', '2'],
        );
        expect(
          [for (final l in lines) _marker(l)],
          [
            (0, 2, 2, 3),
            (5, 8, 8, 9),
            (11, 15, 15, 16),
            (18, 28, 28, 29),
            (33, 35, 35, 36),
          ],
        );
        expect(lines.last.indent, 2);
        expect(
          [for (final l in lines) _text(text, l)],
          ['a', 'b', 'c', 'd', 'e'],
        );
      },
    );

    test('ten digits a paren or a missing space make numbered text plain', () {
      expect(_kinds('1234567890. a\n1) b\n1.\n1.x\n. x'), [_p, _p, _p, _p, _p]);
      expect(_lines('1) b').single.number, isNull);
    });
  });

  group('tasks (R36)', () {
    test(
      'a bullet marker then a box then a space or end of line is a task',
      () {
        const text = '- [ ] a\n- [x] b\n* [X] c\n+ [ ]\n  - [x]';
        final lines = _lines(text);
        expect(
          [for (final l in lines) l.kind],
          [for (var i = 0; i < 5; i++) MdLineKind.task],
        );
        expect(
          [for (final l in lines) l.done],
          [false, true, true, false, true],
        );
        expect(
          [for (final l in lines) _marker(l)],
          [
            (0, 5, 5, 6),
            (8, 13, 13, 14),
            (16, 21, 21, 22),
            (24, 29, 29, 29),
            (32, 37, 37, 37),
          ],
        );
        expect(lines.last.indent, 2);
        expect(
          [for (final l in lines) _text(text, l)],
          ['a', 'b', 'c', '', ''],
        );
      },
    );

    test('a box not followed by a space or end of line stays bullet text', () {
      const text = '- [ ]x\n- [y] a\n- []\n-[ ] a';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [MdLineKind.bullet, MdLineKind.bullet, MdLineKind.bullet, _p],
      );
      expect(_text(text, lines.first), '[ ]x');
      expect(lines.first.done, isFalse);
    });

    test(
      'a numbered box is a numbered item whose text starts with the box',
      () {
        const text = '1. [ ] x';
        final l = _lines(text).single;
        expect(l.kind, MdLineKind.numbered);
        expect(l.done, isFalse);
        expect(_marker(l), (0, 2, 2, 3));
        expect(_text(text, l), '[ ] x');
      },
    );
  });

  group('quotes (R36)', () {
    test(
      'a quote is gt space or gt at end of line and the rest is its text',
      () {
        const text = '> a\n>\n> > b\n> - c\n>x';
        final lines = _lines(text);
        expect(
          [for (final l in lines) l.kind],
          [
            MdLineKind.quote,
            MdLineKind.quote,
            MdLineKind.quote,
            MdLineKind.quote,
            _p,
          ],
        );
        expect(_marker(lines[1]), (4, 5, 5, 5));
        expect(
          [for (final l in lines.take(4)) _text(text, l)],
          ['a', '', '> b', '- c'],
        );
        expect(lines.first.isItem, isTrue);
      },
    );
  });

  group('rules (R36)', () {
    test(
      'three or more of the same dash star or underscore alone is a rule',
      () {
        expect(_kinds('---\n***\n___\n-----\n******'), [
          for (var i = 0; i < 5; i++) MdLineKind.rule,
        ]);
      },
    );

    test('mixed or short rule characters are plain', () {
      expect(_kinds('-*-\n--\n**\n__\n-_-'), [_p, _p, _p, _p, _p]);
    });

    test(
      'a rule line with spaces in it around it or before it is not a rule',
      () {
        expect(_kinds('--- \n ***\n___\t\n* * *\n- - -\n_ _ _'), [
          _p,
          _p,
          _p,
          MdLineKind.bullet,
          MdLineKind.bullet,
          _p,
        ]);
      },
    );

    test('text then a dash line is a rule not a setext heading', () {
      expect(_kinds('Text\n---'), [_p, MdLineKind.rule]);
    });
  });

  group('separator (R36)', () {
    test('two spaces after a marker leave one space in the text', () {
      const text = '-  a\n1.  b\n##  c\n>  d\n- [ ]  e';
      final lines = _lines(text);
      expect(
        [for (final l in lines) l.kind],
        [
          MdLineKind.bullet,
          MdLineKind.numbered,
          MdLineKind.heading,
          MdLineKind.quote,
          MdLineKind.task,
        ],
      );
      expect(
        [for (final l in lines) _text(text, l)],
        [' a', ' b', ' c', ' d', ' e'],
      );
      for (final l in lines) {
        expect(l.separatorEnd - l.separatorStart, 1);
        expect(l.separatorStart, l.markerEnd);
      }
    });
  });

  group('leading frontmatter (R36, D3 link_extractor.rs)', () {
    test('leading frontmatter is frontmatter only at segment start', () {
      const text = '---\ntitle: x\n\n- a\n# h\n```\n---\nbody\n';
      expect(_kinds(text, atSegmentStart: true), [
        for (var i = 0; i < 7; i++) _fm,
        _p,
        _b,
      ]);
      expect(_kinds(text), [
        MdLineKind.rule,
        _p,
        _b,
        MdLineKind.bullet,
        MdLineKind.heading,
        _open,
        _in,
        _in,
        _in,
      ]);
      // A fence line inside frontmatter opens nothing after it.
      expect(_kinds('---\n```\n---\n- a', atSegmentStart: true), [
        _fm,
        _fm,
        _fm,
        MdLineKind.bullet,
      ]);
      expect(_kinds('---\n---\n', atSegmentStart: true), [_fm, _fm, _b]);
    });

    test('parity link extractor no closing line means no frontmatter', () {
      expect(_kinds('---\nk: v\n- a\n', atSegmentStart: true), [
        MdLineKind.rule,
        _p,
        MdLineKind.bullet,
        _b,
      ]);
      expect(_kinds('---\n', atSegmentStart: true), [MdLineKind.rule, _b]);
    });

    test(
      'parity link extractor closing line with surrounding spaces closes',
      () {
        expect(_kinds('---\nk: v\n  ---  \nbody', atSegmentStart: true), [
          _fm,
          _fm,
          _fm,
          _p,
        ]);
        expect(_kinds('---\r\nk: v\r\n\t---\r\n# h', atSegmentStart: true), [
          _fm,
          _fm,
          _fm,
          MdLineKind.heading,
        ]);
      },
    );

    test(
      'parity link extractor input shorter than four code units has no frontmatter',
      () {
        expect(_kinds('---', atSegmentStart: true), [MdLineKind.rule]);
        // Seven code units, closing line without a terminator: frontmatter.
        expect(_kinds('---\n---', atSegmentStart: true), [_fm, _fm]);
        // The opening line must start at offset 0.
        expect(
          _kinds(' ---\nk\n---', atSegmentStart: true),
          isNot(contains(_fm)),
        );
      },
    );
  });

  _wi202TableGrammar();
}

// ------------------------------------------------------------------ WI #202
// Table line grammar (Spec #197 R1-R4, R7; rulings D9, D10, D23).

const _th = MdLineKind.tableHeader;
const _td = MdLineKind.tableDelimiter;
const _tb = MdLineKind.tableBody;

/// A two-column table: header, delimiter, one body line, final newline.
const _wi202Table = '| a | b |\n|---|---|\n| 1 | 2 |\n';

void _wi202TableGrammar() {
  group('tables: header delimiter and body (Spec 197 R1 R2)', () {
    test(
      'a table with outer pipes classifies as header delimiter and body',
      () {
        expect(_kinds('| a | b |\n|---|:-:|\n| 1 | 2 |'), [_th, _td, _tb]);
      },
    );

    test('a table without outer pipes is the same table', () {
      expect(_kinds('a | b\n--- | ---\n1 | 2'), [_th, _td, _tb]);
      // Mixed: outer pipes on some lines only.
      expect(_kinds('| a | b\n---|---|\n1 | 2 |'), [_th, _td, _tb]);
    });

    test('a header only table is a header and a delimiter line', () {
      expect(_kinds('| a | b |\n|---|---|'), [_th, _td]);
      expect(_kinds('| a | b |\n|---|---|\n'), [_th, _td, _b]);
    });

    test('a single column table with pipes is a table', () {
      expect(_kinds('| a |\n|---|\n| 1 |'), [_th, _td, _tb]);
      expect(_kinds('a |\n--- |\n1 |'), [_th, _td, _tb]);
    });

    test(
      'table lines have no marker and their text starts at the line start',
      () {
        const text = '| a |\n  |:-:|\n | 1 |';
        final lines = _lines(text);
        expect([for (final l in lines) l.kind], [_th, _td, _tb]);
        expect([for (final l in lines) l.indent], [0, 2, 1]);
        for (final l in lines) {
          expect(_marker(l), (l.start, l.start, l.start, l.start));
          expect(l.textStart, l.start);
          expect(l.isItem, isFalse, reason: '${l.kind}');
          expect(l.level, 0);
          expect(l.number, isNull);
          expect(l.done, isFalse);
        }
        expect(_ranges(text), [
          (0, 5, 6, '\n'),
          (6, 13, 14, '\n'),
          (14, 20, 20, ''),
        ]);
      },
    );

    test('table lines keep crlf terminators verbatim', () {
      const text = '| a |\r\n|---|\r\n| 1 |\r\n';
      expect(_kinds(text), [_th, _td, _tb, _b]);
      expect(_ranges(text), [
        (0, 5, 7, '\r\n'),
        (7, 12, 14, '\r\n'),
        (14, 19, 21, '\r\n'),
        (21, 21, 21, ''),
      ]);
    });

    test('a header line without a delimiter line below it stays plain', () {
      expect(_kinds('| a | b |'), [_p]);
      expect(_kinds('| a | b |\n'), [_p, _b]);
      expect(_kinds('| a | b |\n| 1 | 2 |'), [_p, _p]);
      expect(_kinds('| a | b |\n\n|---|---|'), [_p, _b, _p]);
    });
  });

  group('tables: delimiter cells (Spec 197 R1 R5)', () {
    test('a delimiter with as many cells as the header makes a table', () {
      expect(_kinds('| a | b | c |\n|---|---|---|'), [_th, _td]);
      expect(_kinds('| a |\n|---|'), [_th, _td]);
    });

    test(
      'a delimiter with one cell fewer than the header leaves plain lines',
      () {
        expect(_kinds('| a | b | c |\n|---|---|\n| 1 | 2 | 3 |'), [_p, _p, _p]);
        expect(_kinds('| a | b |\n|---|'), [_p, _p]);
      },
    );

    test(
      'a delimiter with one cell more than the header leaves plain lines',
      () {
        expect(_kinds('| a | b | c |\n|---|---|---|---|\n| 1 | 2 | 3 |'), [
          _p,
          _p,
          _p,
        ]);
        expect(_kinds('| a |\n|---|---|'), [_p, _p]);
      },
    );

    test('every delimiter cell is dashes with optional outer colons', () {
      expect(_kinds('| a | b | c | d | e |\n| :-- | -: | :-: | - | ---- |'), [
        _th,
        _td,
      ]);
      expect(_kinds('| a | b |\n|:--------:|--------:|'), [_th, _td]);
      // Spaces and tabs around a delimiter cell are allowed.
      expect(_kinds('| a | b |\n|  :-  |\t-:\t|'), [_th, _td]);
    });

    for (final (name, delimiter) in [
      ('a delimiter cell that is only a colon is not a delimiter', '|:|---|'),
      ('a delimiter cell of two colons is not a delimiter', '|::|---|'),
      ('a delimiter cell with an inner colon is not a delimiter', '|-:-|---|'),
      (
        'a delimiter cell with two leading colons is not a delimiter',
        '|::-|---|',
      ),
      (
        'a delimiter cell with two trailing colons is not a delimiter',
        '|-::|---|',
      ),
      ('a delimiter cell holding a letter is not a delimiter', '|-x-|---|'),
      ('a delimiter cell with an inner space is not a delimiter', '|- -|---|'),
      ('an empty delimiter cell is not a delimiter', '|   |---|'),
      ('a delimiter cell of equals signs is not a delimiter', '|===|---|'),
    ]) {
      test(name, () {
        expect(_kinds('| a | b |\n$delimiter\n| 1 | 2 |'), [_p, _p, _p]);
      });
    }

    test('the header and the delimiter each need a cell splitting pipe', () {
      // No pipe in the header line.
      expect(_kinds('a\n|---|'), [_p, _p]);
      // No pipe in the delimiter line.
      expect(_kinds('a |\n:--'), [_p, _p]);
      expect(_kinds('a |\n:-- |'), [_th, _td]);
      // An escaped pipe or a wikilink pipe is not a cell-splitting pipe.
      expect(_kinds('a \\| b\n|---|'), [_p, _p]);
      expect(_kinds('[[T|al]]\n|---|'), [_p, _p]);
      expect(_kinds('a |\n--- \\|'), [_p, _p]);
    });

    test('an escaped pipe in the header does not split a cell', () {
      expect(_kinds('| a \\| b | c |\n|---|---|'), [_th, _td]);
      expect(_kinds('| a \\| b | c |\n|---|---|---|'), [_p, _p]);
    });

    test('a pipe inside a wikilink in the header does not split a cell', () {
      expect(_kinds('| [[Title~kind|alias]] | c |\n|---|---|'), [_th, _td]);
      expect(_kinds('| [[Title|alias]] | c |\n|---|---|---|'), [_p, _p]);
      // An unclosed wikilink is no token: its pipe splits.
      expect(_kinds('| [[Title|alias | c |\n|---|---|---|'), [_th, _td]);
    });
  });

  group('tables: indentation (Spec 197 R3)', () {
    test('a table line with three leading spaces is a table line', () {
      expect(_kinds('   | a |\n   |---|\n   | 1 |'), [_th, _td, _tb]);
      expect(_kinds('  | a |\n |---|\n| 1 |'), [_th, _td, _tb]);
    });

    test('a header with four leading spaces or a leading tab stays plain', () {
      expect(_kinds('    | a |\n|---|\n| 1 |'), [_p, _p, _p]);
      expect(_kinds('\t| a |\n|---|\n| 1 |'), [_p, _p, _p]);
      expect(_kinds(' \t| a |\n|---|'), [_p, _p]);
    });

    test(
      'a delimiter with four leading spaces or a leading tab leaves the header plain',
      () {
        expect(_kinds('| a |\n    |---|\n| 1 |'), [_p, _p, _p]);
        expect(_kinds('| a |\n\t|---|\n| 1 |'), [_p, _p, _p]);
      },
    );

    test(
      'a body line with four leading spaces or a leading tab ends the table',
      () {
        expect(_kinds('| a |\n|---|\n   | 1 |\n    | 2 |'), [
          _th,
          _td,
          _tb,
          _p,
        ]);
        expect(_kinds('| a |\n|---|\n\t| 2 |'), [_th, _td, _p]);
      },
    );
  });

  group('tables: body extent (Spec 197 R4)', () {
    test('the body continues on plain lines holding a cell splitting pipe', () {
      expect(_kinds('$_wi202Table| 3 | 4 |\n5 | 6\n| 7\n8 |'), [
        _th,
        _td,
        _tb,
        _tb,
        _tb,
        _tb,
        _tb,
      ]);
    });

    test('a blank line ends the table body', () {
      expect(_kinds('$_wi202Table\n| 3 | 4 |'), [_th, _td, _tb, _b, _p]);
      expect(_kinds('$_wi202Table  \n| 3 | 4 |'), [_th, _td, _tb, _b, _p]);
    });

    test(
      'a plain line without a cell splitting pipe ends the body and stays plain',
      () {
        expect(_kinds('${_wi202Table}after\n| 3 | 4 |'), [
          _th,
          _td,
          _tb,
          _p,
          _p,
        ]);
        // Escaped and wikilink pipes don't split cells.
        expect(_kinds('${_wi202Table}x \\| y'), [_th, _td, _tb, _p]);
        expect(_kinds('$_wi202Table[[A|b]]'), [_th, _td, _tb, _p]);
      },
    );

    test('a heading line ends the table body', () {
      expect(_kinds('$_wi202Table# h | x\n| 3 | 4 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.heading,
        _p,
      ]);
    });

    test('a bullet line ends the table body', () {
      expect(_kinds('$_wi202Table- 3 | 4\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.bullet,
        _p,
      ]);
    });

    test('a numbered line ends the table body', () {
      expect(_kinds('${_wi202Table}1. 3 | 4\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.numbered,
        _p,
      ]);
    });

    test('a task line ends the table body', () {
      expect(_kinds('$_wi202Table- [ ] 3 | 4\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.task,
        _p,
      ]);
    });

    test('a quote line ends the table body', () {
      expect(_kinds('$_wi202Table> 3 | 4\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.quote,
        _p,
      ]);
    });

    test('a rule line ends the table body', () {
      expect(_kinds('$_wi202Table---\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        MdLineKind.rule,
        _p,
      ]);
      expect(_kinds('$_wi202Table***'), [_th, _td, _tb, MdLineKind.rule]);
    });

    test('a fence line ends the table body', () {
      expect(_kinds('$_wi202Table```\n| 3 | 4 |\n```\n| 5 | 6 |'), [
        _th,
        _td,
        _tb,
        _open,
        _in,
        _close,
        _p,
      ]);
      // Directly under the delimiter line.
      expect(_kinds('| a |\n|---|\n```'), [_th, _td, _open]);
    });
  });

  group('tables: a new table inside a body (D23)', () {
    test('a header and a delimiter inside a table body start a new table', () {
      expect(_kinds('| a | b |\n|---|---|\n| 1 | 2 |\n| c |\n|---|\n| 3 |'), [
        _th,
        _td,
        _tb,
        _th,
        _td,
        _tb,
      ]);
      // Directly under the first delimiter, same column count.
      expect(_kinds('| a |\n|---|\n| b |\n|:-:|\n| 1 |'), [
        _th,
        _td,
        _th,
        _td,
        _tb,
      ]);
    });

    test(
      'a body line above a delimiter of another cell count stays in the body',
      () {
        expect(_kinds('| a | b |\n|---|---|\n| 1 |\n|---|---|\n| 2 | 3 |'), [
          _th,
          _td,
          _tb,
          _tb,
          _tb,
        ]);
      },
    );
  });

  group('tables: lines that are never table lines (Spec 197 R3 R7)', () {
    test('table looking lines inside a fence stay fence lines', () {
      expect(_kinds('```\n| a | b |\n|---|---|\n| 1 | 2 |\n```'), [
        _open,
        _in,
        _in,
        _in,
        _close,
      ]);
      // A delimiter inside a fence doesn't complete a header above it.
      expect(_kinds('| a |\n```\n|---|\n```'), [_p, _open, _in, _close]);
      // An unclosed fence.
      expect(_kinds('x\n```\n| a |\n|---|'), [_p, _open, _in, _in]);
    });

    test('table looking lines inside leading frontmatter stay frontmatter', () {
      const text = '---\n| a | b |\n|---|---|\n| 1 | 2 |\n---\nbody';
      expect(_kinds(text, atSegmentStart: true), [_fm, _fm, _fm, _fm, _fm, _p]);
      // Away from the segment start the same lines are a table.
      expect(_kinds(text), [
        MdLineKind.rule,
        _th,
        _td,
        _tb,
        MdLineKind.rule,
        _p,
      ]);
    });

    test('a dash pipe dash line is a bullet not a delimiter', () {
      expect(_kinds('- | -'), [MdLineKind.bullet]);
      expect(_kinds('| a | b |\n- | -\n| 1 | 2 |'), [
        _p,
        MdLineKind.bullet,
        _p,
      ]);
    });

    test(
      'a header line directly after a paragraph line starts a table and the paragraph line stays plain',
      () {
        expect(_kinds('para\n| a |\n|---|\n| 1 |'), [_p, _th, _td, _tb]);
        // The paragraph line holds a pipe but has no delimiter below it.
        expect(_kinds('para | x\n| a |\n|---|'), [_p, _th, _td]);
      },
    );

    test('a heading item or quote line is never a table header', () {
      for (final (line, kind) in [
        ('# a | b', MdLineKind.heading),
        ('- a | b', MdLineKind.bullet),
        ('1. a | b', MdLineKind.numbered),
        ('- [ ] a | b', MdLineKind.task),
        ('> a | b', MdLineKind.quote),
      ]) {
        expect(_kinds('$line\n|---|---|'), [kind, _p], reason: line);
      }
    });

    test('a table line directly below a list item starts a table', () {
      expect(_kinds('- item\n| a |\n|---|\n| 1 |'), [
        MdLineKind.bullet,
        _th,
        _td,
        _tb,
      ]);
      expect(_kinds('# H\n| a |\n|---|'), [MdLineKind.heading, _th, _td]);
    });
  });
}
