// WI #245 (A1, Spec #234 R4-R6, R20; rulings D17, TD4): the Dart port of the
// inline `#tag` grammar. The contract is test/fixtures/tags/grammar.json (the
// Rust reference, crates/memex-core/src/tags.rs, passes the same rows).
//
// Three layers: every fixture row through the whole-text function and again
// line by line with exact ranges; the grammar rules the fixture only samples
// (the opener test, name characters, trailing trim, surrogate pairs, code
// spans, URLs, links, fences) as tables; and the system tag predicate.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/tag_grammar.dart';

Map<String, Object?> _fixture() =>
    jsonDecode(File('test/fixtures/tags/grammar.json').readAsStringSync())
        as Map<String, Object?>;

String _show(String s) =>
    s.replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t');

/// `[start, end, name]` triples, so failures print plainly.
List<List<Object>> _triples(Iterable<TagRange> ranges) => [
  for (final r in ranges) [r.start, r.end, r.name],
];

/// The sorted, de-duplicated names the line-level function finds in [input]
/// (split on `\n`), and the problems with any range it returns.
(List<String>, List<String>) _lineByLine(String input) {
  final names = <String>{};
  final problems = <String>[];
  for (final line in input.split('\n')) {
    var previousEnd = 0;
    for (final r in findTagsInLine(line)) {
      final at = '${_show(line)} @ ${r.start}..${r.end}';
      if (r.start < previousEnd) problems.add('$at: not in order');
      previousEnd = r.end;
      if (r.start < 0 || r.end > line.length || r.end <= r.start + 1) {
        problems.add('$at: range outside the line or empty name');
        continue;
      }
      if (line.codeUnitAt(r.start) != 0x23) problems.add('$at: no # at start');
      final written = line.substring(r.start + 1, r.end);
      if (written.toLowerCase() != r.name) {
        problems.add('$at: "$written" is not the name "${r.name}"');
      }
      if (written.endsWith('-') || written.endsWith('_')) {
        problems.add('$at: range keeps a trailing dash or underscore');
      }
      names.add(r.name);
    }
  }
  return ([...names]..sort(), problems);
}

void main() {
  group('grammar fixture (AC1)', () {
    test(
      'every grammar fixture case gives its tags through extractTagNames',
      () {
        final cases = (_fixture()['cases']! as List).cast<Map>();
        expect(cases.length, greaterThan(80), reason: 'the fixture is read');
        final bad = <String>[];
        for (final c in cases) {
          final input = c['input']! as String;
          final want = (c['tags']! as List).cast<String>();
          final got = extractTagNames(input);
          if (got.join('\u0000') != want.join('\u0000')) {
            bad.add(
              '${c['rule']} / ${c['name']}: ${_show(input)} '
              'want $want got $got',
            );
          }
        }
        expect(bad, isEmpty, reason: bad.join('\n'));
      },
    );

    test(
      'every single-line grammar fixture case gives its tags line by line with well formed ranges',
      () {
        final cases = (_fixture()['cases']! as List).cast<Map>();
        final bad = <String>[];
        var checked = 0;
        for (final c in cases) {
          // A fence is the caller's: the line function never sees fenced
          // lines, so the fence rows are whole-text rows only.
          if (c['rule'] == 'excluded-fence') continue;
          final input = c['input']! as String;
          final want = (c['tags']! as List).cast<String>();
          final (got, problems) = _lineByLine(input);
          checked++;
          bad.addAll(problems);
          if (got.join('\u0000') != want.join('\u0000')) {
            bad.add(
              '${c['rule']} / ${c['name']}: ${_show(input)} '
              'want $want got $got',
            );
          }
        }
        expect(checked, greaterThan(70), reason: 'rows were checked');
        expect(bad, isEmpty, reason: bad.join('\n'));
      },
    );

    test('every grammar fixture name row normalizes as the reference does', () {
      final names = (_fixture()['names']! as List).cast<Map>();
      expect(names.length, greaterThan(15), reason: 'the fixture is read');
      final bad = <String>[];
      for (final row in names) {
        final input = row['input']! as String;
        final want = row['name'] as String?;
        final got = normalizeTagName(input);
        if (got != want) bad.add('${_show(input)}: want $want got $got');
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
      // The table holds both answers.
      expect(names.any((r) => r['name'] != null), isTrue);
      expect(names.any((r) => r['name'] == null), isTrue);
    });

    test(
      'isSystemTag is true for exactly the system tags in the grammar fixture',
      () {
        final system = (_fixture()['system_tags']! as List).cast<String>();
        expect(system, ['inbox', 'agent-authored']);
        for (final name in system) {
          expect(isSystemTag(name), isTrue, reason: name);
        }
        // Every tag the fixture finds that is not listed is not a system tag.
        final cases = (_fixture()['cases']! as List).cast<Map>();
        final others = {
          for (final c in cases)
            for (final t in (c['tags']! as List).cast<String>())
              if (!system.contains(t)) t,
        };
        expect(others, contains('work'));
        for (final name in others) {
          expect(isSystemTag(name), isFalse, reason: name);
        }
      },
    );
  });

  group('system tag predicate (D17)', () {
    test('isSystemTag is case sensitive and rejects near misses', () {
      for (final name in [
        'Inbox',
        'INBOX',
        'agent_authored',
        'Agent-Authored',
        'agent',
        'authored',
        'inbox ',
        ' inbox',
        'inbox\n',
        '#inbox',
        'inboxes',
        'agent-authored-',
        '',
      ]) {
        expect(isSystemTag(name), isFalse, reason: '"${_show(name)}"');
      }
      expect(isSystemTag('inbox'), isTrue);
      expect(isSystemTag('agent-authored'), isTrue);
    });
  });

  group('the # start test (opensTag)', () {
    test(
      'opensTag is true at line start, after Unicode whitespace and after the five opening characters',
      () {
        final opens = <String, int?>{
          'line start': null,
          'space': 0x20,
          'tab': 0x09,
          'line feed': 0x0A,
          'vertical tab': 0x0B,
          'form feed': 0x0C,
          'carriage return': 0x0D,
          'next line (U+0085)': 0x85,
          'no-break space': 0xA0,
          'ogham space mark': 0x1680,
          'en quad': 0x2000,
          'hair space': 0x200A,
          'line separator': 0x2028,
          'paragraph separator': 0x2029,
          'narrow no-break space': 0x202F,
          'medium mathematical space': 0x205F,
          'ideographic space': 0x3000,
          'open paren': 0x28,
          'open square bracket': 0x5B,
          'open brace': 0x7B,
          'double quote': 0x22,
          'single quote': 0x27,
        };
        for (final MapEntry(key: name, value: unit) in opens.entries) {
          expect(opensTag(unit), isTrue, reason: name);
        }
      },
    );

    test(
      'opensTag is false after letters digits closers and other punctuation',
      () {
        // The contrast: a space and the line start do open one.
        expect(opensTag(0x20), isTrue, reason: 'after a space');
        expect(opensTag(null), isTrue, reason: 'at line start');
        final closed = <String, int>{
          'letter a': 0x61,
          'letter Z': 0x5A,
          'digit': 0x31,
          'close paren': 0x29,
          'close square bracket': 0x5D,
          'close brace': 0x7D,
          'backtick': 0x60,
          'backslash': 0x5C,
          'hash': 0x23,
          'dash': 0x2D,
          'underscore': 0x5F,
          'dot': 0x2E,
          'comma': 0x2C,
          'slash': 0x2F,
          'star': 0x2A,
          'greater than': 0x3E,
          'pipe': 0x7C,
          'bang': 0x21,
          'at sign': 0x40,
          'U+0084 just below next line': 0x84,
          'U+0086 just above next line': 0x86,
          'U+00A1': 0xA1,
          'U+167F just below ogham': 0x167F,
          'U+1681 just above ogham': 0x1681,
          'U+1FFF just below en quad': 0x1FFF,
          'zero width space': 0x200B,
          'U+202E': 0x202E,
          'U+2030': 0x2030,
          'U+205E just below mathematical space': 0x205E,
          'U+2060 word joiner': 0x2060,
          'U+2FFF': 0x2FFF,
          'U+3001 just above ideographic space': 0x3001,
          'byte order mark': 0xFEFF,
          'low surrogate (an emoji end)': 0xDE00,
          'high surrogate': 0xD83D,
        };
        for (final MapEntry(key: name, value: unit) in closed.entries) {
          expect(opensTag(unit), isFalse, reason: name);
        }
      },
    );
  });

  group('tag ranges in a line (AC2)', () {
    test('TagRange has value semantics and prints its range and name', () {
      final built = findTagsInLine('x #Work').single;
      expect(built, TagRange(2, 7, 'work'));
      expect(built.hashCode, TagRange(2, 7, 'work').hashCode);
      expect(built.start, 2);
      expect(built.end, 7);
      expect(built.name, 'work');
      expect(built, isNot(TagRange(3, 7, 'work')));
      expect(built, isNot(TagRange(2, 8, 'work')));
      expect(built, isNot(TagRange(2, 7, 'play')));
      // Value equality only holds for another TagRange.
      // ignore: unrelated_type_equality_checks
      expect(built == '#work', isFalse);
      expect({built, TagRange(2, 7, 'work')}, hasLength(1));
      expect(built.toString(), 'TagRange(2, 7, work)');
    });

    test(
      'findTagsInLine gives the exact UTF-16 range and lowercase name of each tag',
      () {
        final cases = <String, List<List<Object>>>{
          '#work': [
            [0, 5, 'work'],
          ],
          'note #work': [
            [5, 10, 'work'],
          ],
          '- call with Sam about pricing #work': [
            [30, 35, 'work'],
          ],
          '#work.': [
            [0, 5, 'work'],
          ],
          '(#work)': [
            [1, 6, 'work'],
          ],
          '#Work': [
            [0, 5, 'work'],
          ],
          '#RÉSUMÉ': [
            [0, 7, 'résumé'],
          ],
          '#a #b': [
            [0, 2, 'a'],
            [3, 5, 'b'],
          ],
          '#work #Work': [
            [0, 5, 'work'],
            [6, 11, 'work'],
          ],
          '#work#play': [
            [0, 5, 'work'],
          ],
          '#work/pricing': [
            [0, 5, 'work'],
          ],
          '#q3-plan': [
            [0, 8, 'q3-plan'],
          ],
          '#my_tag_x': [
            [0, 9, 'my_tag_x'],
          ],
          '#é': [
            [0, 2, 'é'],
          ],
          '#éa': [
            [0, 4, 'éa'],
          ],
          '#x²': [
            [0, 2, 'x'],
          ],
          'a #b `#c` #d': [
            [2, 4, 'b'],
            [10, 12, 'd'],
          ],
          '#': <List<Object>>[],
          '# ': <List<Object>>[],
          '': <List<Object>>[],
          'call with Sam #': <List<Object>>[],
          '#1': <List<Object>>[],
          '##x': <List<Object>>[],
          'a#b': <List<Object>>[],
          r'\#work': <List<Object>>[],
          '#work\r': [
            [0, 5, 'work'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine leaves a trailing dash or underscore out of the range',
      () {
        final cases = <String, List<List<Object>>>{
          '#plan-': [
            [0, 5, 'plan'],
          ],
          '#a_': [
            [0, 2, 'a'],
          ],
          '#plan--': [
            [0, 5, 'plan'],
          ],
          '#a-_': [
            [0, 2, 'a'],
          ],
          '#a_-_ and': [
            [0, 2, 'a'],
          ],
          '#q3-plan-': [
            [0, 8, 'q3-plan'],
          ],
          '#q3-plan- #b': [
            [0, 8, 'q3-plan'],
            [10, 12, 'b'],
          ],
          '#my_tag_': [
            [0, 7, 'my_tag'],
          ],
          '#a-b': [
            [0, 4, 'a-b'],
          ],
          '#a_b': [
            [0, 4, 'a_b'],
          ],
          '#a-_b': [
            [0, 5, 'a-_b'],
          ],
          '#-a': <List<Object>>[],
          '#_a': <List<Object>>[],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine counts ranges in UTF-16 units across surrogate pairs',
      () {
        const wide = '\u{20000}'; // a CJK letter outside the BMP: two units
        const digit = '\u{1D7D8}'; // a decimal digit outside the BMP
        final cases = <String, List<List<Object>>>{
          // The emoji is two units, so the # sits at 3.
          '\u{1F600} #w': [
            [3, 5, 'w'],
          ],
          // An emoji ends in a low surrogate, which opens nothing.
          '\u{1F600}#w': <List<Object>>[],
          '#${wide}x': [
            [0, 4, '${wide}x'],
          ],
          '#a$digit': [
            [0, 4, 'a$digit'],
          ],
          '#a$digit-': [
            [0, 4, 'a$digit'],
          ],
          // An emoji is not a letter: the name stops before it.
          '#ab\u{1F600}': [
            [0, 3, 'ab'],
          ],
          'x $wide #t': [
            [5, 7, 't'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine opens a tag after each opener character and after Unicode whitespace',
      () {
        for (final opener in [
          ' ',
          '\t',
          ' ',
          '\u0085',
          ' ',
          '　',
          '(',
          '[',
          '{',
          '"',
          "'",
        ]) {
          expect(_triples(findTagsInLine('x$opener#t')), [
            [2, 4, 't'],
          ], reason: 'after U+${opener.codeUnitAt(0).toRadixString(16)}');
        }
        for (final closer in [
          'a',
          '1',
          ')',
          ']',
          '}',
          '.',
          '-',
          '_',
          '`',
          '\\',
        ]) {
          expect(
            findTagsInLine('x$closer#t'),
            isEmpty,
            reason: 'after "$closer"',
          );
        }
      },
    );
  });

  group('hidden regions in a line (AC4)', () {
    test(
      'findTagsInLine finds no tag inside code spans and keeps the ones around them',
      () {
        final cases = <String, List<List<Object>>>{
          '`#code`': <List<Object>>[],
          '`#code` #after': [
            [8, 14, 'after'],
          ],
          '#before `#code`': [
            [0, 7, 'before'],
          ],
          '``a #b``': <List<Object>>[],
          '``a ` #b`` #c': [
            [11, 13, 'c'],
          ],
          // A backtick run with no partner is plain text.
          '`a #b': [
            [3, 5, 'b'],
          ],
          '``a` #b': [
            [5, 7, 'b'],
          ],
          // The first run of one pairs with the last run of one.
          '`a`` #b`': <List<Object>>[],
          '`a` #b `c`': [
            [4, 6, 'b'],
          ],
          '`a` `b` #c': [
            [8, 10, 'c'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine finds no tag inside wikilinks and transclusions and keeps the ones around them',
      () {
        final cases = <String, List<List<Object>>>{
          '[[a]] #b': [
            [6, 8, 'b'],
          ],
          '#b [[a]]': [
            [0, 2, 'b'],
          ],
          '[[a #b]]': <List<Object>>[],
          '[[Pricing#Annual]] and #p': [
            [23, 25, 'p'],
          ],
          '[[#x]]': <List<Object>>[],
          '[[a|b #c]] #d': [
            [11, 13, 'd'],
          ],
          '[[Note~references|(#x)]]': <List<Object>>[],
          '![[2026-11-06#^abc12]] #y': [
            [23, 25, 'y'],
          ],
          '![[2026-11-06#^a1..^b2]]': <List<Object>>[],
          // A wikilink never spans a line break.
          '[[a #b': [
            [4, 6, 'b'],
          ],
          '[[a]] [[b #c]] #d': [
            [15, 17, 'd'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine finds no tag inside markdown links and images and keeps the ones around them',
      () {
        final cases = <String, List<List<Object>>>{
          '[#x](https://example.com)': <List<Object>>[],
          '[see #x](https://e.com) #z': [
            [24, 26, 'z'],
          ],
          '[see](#x)': <List<Object>>[],
          '![#alt](i.png)': <List<Object>>[],
          '[a](b) #c': [
            [7, 9, 'c'],
          ],
          // The reference's link pattern allows spaces in the target.
          '[see #x](a b) #z': [
            [14, 16, 'z'],
          ],
          '[a #b](c d)': <List<Object>>[],
          // Brackets and parentheses that do not form a link hide nothing.
          '[a] (b #c)': [
            [7, 9, 'c'],
          ],
          '[a #b] x': [
            [3, 5, 'b'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );

    test(
      'findTagsInLine finds no tag inside a URL, which ends at whitespace',
      () {
        final cases = <String, List<List<Object>>>{
          'https://example.com/#section': <List<Object>>[],
          'git+ssh://host/#a': <List<Object>>[],
          'ftp://x.y/(#a)': <List<Object>>[],
          'see http://example.com/\'#x\' and #y': [
            [32, 34, 'y'],
          ],
          'http://a.b/c #d': [
            [13, 15, 'd'],
          ],
          'https://x.y/#a #b': [
            [15, 17, 'b'],
          ],
          '#a https://x.y/#b': [
            [0, 2, 'a'],
          ],
          'http://a.b/c #d': [
            [13, 15, 'd'],
          ],
          // No scheme, no URL: the text before a # decides alone.
          'compare with stripe.com/pricing #reading': [
            [32, 40, 'reading'],
          ],
          'example.com/docs#setup': <List<Object>>[],
          'issue #1 and `#fff` on example.com/docs#setup': <List<Object>>[],
          '://x/ #a': [
            [6, 8, 'a'],
          ],
        };
        for (final MapEntry(key: line, value: want) in cases.entries) {
          expect(
            _triples(findTagsInLine(line)),
            want,
            reason: 'line: ${_show(line)}',
          );
        }
      },
    );
  });

  group('whole text and fences (AC1, AC4)', () {
    test('extractTagNames sorts by name and keeps one of each', () {
      expect(extractTagNames('#b #a\n#B #c\nx #a'), ['a', 'b', 'c']);
      expect(extractTagNames('#zeta #alpha #mid'), ['alpha', 'mid', 'zeta']);
      expect(extractTagNames(''), isEmpty);
      expect(extractTagNames('\n\n'), isEmpty);
      expect(extractTagNames('no tags here # at all'), isEmpty);
    });

    test('extractTagNames treats a fence as CommonMark does', () {
      final cases = <String, List<String>>{
        // A longer fence is closed only by a run at least as long.
        '````\n#x\n```\n#y\n````\n#z': ['z'],
        '~~~~\n#x\n~~~\n#y\n~~~~\n#z': ['z'],
        // The closer is the fence character alone: an info string keeps it open.
        '```\n#x\n```rust\n#y': <String>[],
        // Trailing whitespace and a carriage return do not.
        '```\n#x\n``` \n#y': ['y'],
        '```\r\n#x\r\n```\r\n#y': ['y'],
        // Indentation by spaces or a tab, on both fences.
        '\t```\n#x\n\t```\n#y': ['y'],
        '   ~~~\n#x\n   ~~~\n#y': ['y'],
        // A backtick fence has no backtick in its info string; a tilde fence may.
        '```a`b\n#x': ['x'],
        '~~~a`b\n#x\n~~~\n#y': ['y'],
        // A closing run longer than the opener closes it too.
        '```\n#x\n`````\n#y': ['y'],
        '~~~\n#x\n~~~~~\n#y': ['y'],
        // Two characters make no fence.
        '``\n#x': ['x'],
        '~~\n#x': ['x'],
        // A fence line holds no tags; one before it does.
        '#a ```\n#b': ['a', 'b'],
        '```\n#x\n```\n```\n#y\n```\n#z': ['z'],
        // The tilde closer needs tildes, the backtick closer backticks.
        '```\n#x\n~~~\n#y\n```\n#z': ['z'],
        // Text after the closer's whitespace makes it no closer.
        '~~~\n#x\n~~~ x\n#y': <String>[],
      };
      for (final MapEntry(key: text, value: want) in cases.entries) {
        expect(extractTagNames(text), want, reason: 'text: ${_show(text)}');
      }
    });

    test(
      'extractTagNames reads tags on every line with CRLF or LF endings',
      () {
        expect(extractTagNames('#a\r\n- x #b\r\n> #c\r\n'), ['a', 'b', 'c']);
        expect(extractTagNames('# Heading #h\n## Sub #i\n### #j'), [
          'h',
          'i',
          'j',
        ]);
        expect(extractTagNames('- [ ] call Sam #work\n- [x] done #done'), [
          'done',
          'work',
        ]);
      },
    );
  });

  group('names (R4)', () {
    test('normalizeTagName accepts a whole name only and lowercases it', () {
      final cases = <String, String?>{
        'Work': 'work',
        'Работа': 'работа',
        'RÉSUMÉ': 'résumé',
        'q3-plan': 'q3-plan',
        'my_tag_x': 'my_tag_x',
        'a-_b': 'a-_b',
        '\u{20000}x': '\u{20000}x',
        'a\u{1D7D8}': 'a\u{1D7D8}',
        'x²': null,
        'plan-': null,
        'a--': null,
        'a b': null,
        '#a': null,
        'a#': null,
        '': null,
        ' ': null,
        '1': null,
        'é́': 'é́',
        '́a': null,
        'a\tb': null,
        'a.b': null,
      };
      for (final MapEntry(key: input, value: want) in cases.entries) {
        expect(normalizeTagName(input), want, reason: 'input: ${_show(input)}');
      }
    });
  });
}
