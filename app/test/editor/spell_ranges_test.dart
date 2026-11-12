// WI #435 (392-E2): spell-check skip ranges, paragraph splitting and the
// spelling and grammar drop rules (Spec #392 requirements 2 and 3).
//
// Range boundaries the Spec leaves open (is the space after `##` in the
// marker range? is a fence line break in the code range?) are not pinned:
// tests assert that the construct is covered and that the checked text is
// untouched. Every "nothing here" assertion sits beside a positive one, so no
// test passes against code that returns nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/spell_ranges.dart';

List<SpellSkipRange> _skips(String text, {bool start = true, int? footer}) =>
    spellSkipRanges(text, atSegmentStart: start, footerStart: footer);

/// `[start, end]` pairs of the ranges of [kind], sorted by start.
List<List<int>> _pairs(
  String text,
  SpellSkipKind kind, {
  bool start = true,
  int? footer,
}) => [
  for (final r in _skips(text, start: start, footer: footer))
    if (r.kind == kind) [r.start, r.end],
]..sort((a, b) => a[0].compareTo(b[0]));

/// The offsets covered by ranges of [kind], or by any range when null.
Set<int> _covered(
  String text,
  SpellSkipKind? kind, {
  bool start = true,
  int? footer,
}) => {
  for (final r in _skips(text, start: start, footer: footer))
    if (kind == null || r.kind == kind)
      for (var i = r.start; i < r.end; i++) i,
};

/// Maximal runs of offsets covered by [kind], as trimmed text. Splitting one
/// range in two, or including a separator space, does not change the result.
List<String> _runs(
  String text,
  SpellSkipKind kind, {
  bool start = true,
  int? footer,
}) {
  final offsets = _covered(text, kind, start: start, footer: footer).toList()
    ..sort();
  final out = <String>[];
  var i = 0;
  while (i < offsets.length) {
    var j = i;
    while (j + 1 < offsets.length && offsets[j + 1] == offsets[j] + 1) {
      j++;
    }
    final run = text.substring(offsets[i], offsets[j] + 1).trim();
    if (run.isNotEmpty) out.add(run);
    i = j + 1;
  }
  return out;
}

int _find(String text, String needle, [int from = 0]) {
  final i = text.indexOf(needle, from);
  expect(i, isNonNegative, reason: '"$needle" is not in the test text');
  return i;
}

/// Every code unit of [needle] (found at or after [from]) is in a [kind]
/// range.
void _expectCovered(
  String text,
  SpellSkipKind kind,
  String needle, {
  int from = 0,
  bool start = true,
  int? footer,
}) {
  final at = _find(text, needle, from);
  final offsets = _covered(text, kind, start: start, footer: footer);
  for (var i = at; i < at + needle.length; i++) {
    expect(
      offsets.contains(i),
      isTrue,
      reason:
          'offset $i of "$needle" in "$text" should be a ${kind.name} skip, '
          'got ${_pairs(text, kind, start: start, footer: footer)}',
    );
  }
}

/// No code unit of [needle] (found at or after [from]) is in any range.
void _expectUntouched(
  String text,
  String needle, {
  int from = 0,
  bool start = true,
  int? footer,
}) {
  final at = _find(text, needle, from);
  final offsets = _covered(text, null, start: start, footer: footer);
  for (var i = at; i < at + needle.length; i++) {
    expect(
      offsets.contains(i),
      isFalse,
      reason: 'offset $i of "$needle" in "$text" must stay checked',
    );
  }
}

void main() {
  group('inline code', () {
    test('skips an inline code span with its backticks', () {
      const text = 'a `code` b';
      expect(_pairs(text, SpellSkipKind.code), [
        [2, 8],
      ]);
      _expectUntouched(text, 'a');
      _expectUntouched(text, 'b', from: 3);
    });

    test('skips a double backtick span that holds a backtick', () {
      const text = 'x ``a`b`` y';
      expect(_pairs(text, SpellSkipKind.code), [
        [2, 9],
      ]);
      _expectUntouched(text, 'y', from: 9);
    });

    test('skips a code span inside a heading, bullet and quote', () {
      expect(_pairs('## a `code`', SpellSkipKind.code), [
        [5, 11],
      ]);
      expect(_pairs('- see `code`', SpellSkipKind.code), [
        [6, 12],
      ]);
      expect(_pairs('> see `code`', SpellSkipKind.code), [
        [6, 12],
      ]);
    });
  });

  group('fenced code blocks', () {
    test('skips a fenced block with both fences', () {
      const text = 'intro\n```dart\nlet x = 1;\n\nmore\n```\noutro';
      final open = _find(text, '```dart');
      final close = _find(text, '```\noutro');
      final code = _covered(text, SpellSkipKind.code);
      for (var i = open; i < close + 3; i++) {
        expect(code.contains(i), isTrue, reason: 'offset $i');
      }
      _expectUntouched(text, 'intro');
      _expectUntouched(text, 'outro');
    });

    test('an unclosed fence skips to the end of the text', () {
      const text = 'intro\n```\nopen fence\nmore words';
      final open = _find(text, '```');
      final code = _covered(text, SpellSkipKind.code);
      for (var i = open; i < text.length; i++) {
        expect(code.contains(i), isTrue, reason: 'offset $i');
      }
      _expectUntouched(text, 'intro');
    });

    test('markdown inside a fence gives no other range', () {
      const text = 'pre\n```\n**x** [[N]] #t ![[2026-01-02#^abc]]\n```\n';
      final kinds = {for (final r in _skips(text)) r.kind};
      expect(kinds, {SpellSkipKind.code});
    });

    test('two fenced blocks skip both and leave the prose between', () {
      const text = '```\na\n```\nmiddle\n```\nb\n```';
      final second = _find(text, '```\nb');
      expect(_covered(text, SpellSkipKind.code).contains(second), isTrue);
      _expectCovered(text, SpellSkipKind.code, '```\na\n```');
      _expectCovered(text, SpellSkipKind.code, '```\nb\n```');
      _expectUntouched(text, 'middle');
    });
  });

  group('wikilinks and transclusions', () {
    for (final (name, link) in [
      ('skips a plain wikilink in full', '[[Note]]'),
      ('skips a wikilink with an alias in full', '[[Note|alias]]'),
      ('skips a wikilink with a kind in full', '[[Note~kind]]'),
      (
        'skips a wikilink with a kind and an alias in full',
        '[[Note~kind|alias]]',
      ),
    ]) {
      test(name, () {
        final text = 'see $link here';
        expect(_runs(text, SpellSkipKind.wikilink), [link]);
        expect(_pairs(text, SpellSkipKind.wikilink), [
          [4, 4 + link.length],
        ]);
        _expectUntouched(text, 'see');
        _expectUntouched(text, 'here');
      });
    }

    test('skips a transclusion as a transclusion and not as a wikilink', () {
      const text = 'see ![[2026-09-05#^b7k2m9]] here';
      expect(_runs(text, SpellSkipKind.transclusion), [
        '![[2026-09-05#^b7k2m9]]',
      ]);
      expect(_pairs(text, SpellSkipKind.transclusion), [
        [4, 27],
      ]);
      expect(_covered(text, SpellSkipKind.wikilink), isEmpty);
      _expectUntouched(text, 'see');
      _expectUntouched(text, 'here');
    });

    test('skips a transclusion with a block range in full', () {
      const text = '![[2026-09-05#^b7k2m9..^c3d4e5]] tail';
      expect(_runs(text, SpellSkipKind.transclusion), [
        '![[2026-09-05#^b7k2m9..^c3d4e5]]',
      ]);
      _expectUntouched(text, 'tail');
    });

    test('a wikilink inside bold is skipped and the bold markers too', () {
      const text = '**[[Note]]**';
      expect(_runs(text, SpellSkipKind.wikilink), ['[[Note]]']);
      expect(_runs(text, SpellSkipKind.marker), ['**', '**']);
    });
  });

  group('links', () {
    test('skips only the url part of a link', () {
      const text = 'see [text](https://x.y) end';
      _expectCovered(text, SpellSkipKind.url, 'https://x.y');
      _expectUntouched(text, 'text');
      _expectUntouched(text, 'see');
      _expectUntouched(text, 'end');
    });

    test(
      'a link inside bold skips the url and the bold markers, not the text',
      () {
        const text = '**[text](https://x.y)**';
        _expectCovered(text, SpellSkipKind.url, 'https://x.y');
        final marker = _covered(text, SpellSkipKind.marker);
        expect(
          marker.containsAll([0, 1, text.length - 2, text.length - 1]),
          isTrue,
        );
        _expectUntouched(text, 'text');
      },
    );

    test('emphasis inside link text is a marker and the url is skipped', () {
      const text = '[**t**](https://x.y)';
      _expectCovered(text, SpellSkipKind.marker, '**');
      _expectCovered(text, SpellSkipKind.marker, '**', from: 4);
      _expectCovered(text, SpellSkipKind.url, 'https://x.y');
      _expectUntouched(text, 't');
    });

    test('a bare url is skipped without its trailing period', () {
      const text = 'see https://x.example/a. ok';
      expect(_runs(text, SpellSkipKind.url), ['https://x.example/a']);
      _expectUntouched(text, '.', from: text.lastIndexOf('.'));
      _expectUntouched(text, 'see');
      _expectUntouched(text, 'ok');
    });

    test('a bare url alone is one url range with exact offsets', () {
      expect(_pairs('https://z.example', SpellSkipKind.url), [
        [0, 17],
      ]);
    });

    test(
      'a link url and a bare url both skip and no url range overlaps another',
      () {
        const text =
            '[t](https://a.example) https://b.example mailto:c@d.example';
        _expectCovered(text, SpellSkipKind.url, 'https://a.example');
        _expectCovered(text, SpellSkipKind.url, 'https://b.example');
        _expectCovered(text, SpellSkipKind.url, 'mailto:c@d.example');
        final urls =
            _skips(text).where((r) => r.kind == SpellSkipKind.url).toList()
              ..sort((a, b) => a.start.compareTo(b.start));
        for (var i = 1; i < urls.length; i++) {
          expect(urls[i].start, greaterThanOrEqualTo(urls[i - 1].end));
        }
        _expectUntouched(text, 't');
      },
    );

    test('the url of a link is not also reported as a second range', () {
      const text = '[text](https://x.example/p)';
      final at = _find(text, 'https');
      final over = _skips(text)
          .where(
            (r) =>
                r.kind == SpellSkipKind.url && r.start < at + 5 && r.end > at,
          )
          .toList();
      expect(over, hasLength(1));
    });
  });

  group('tags and escapes', () {
    test('skips a tag but not the comma after it', () {
      const text = 'a #idea, b';
      expect(_runs(text, SpellSkipKind.tag), ['#idea']);
      expect(_pairs(text, SpellSkipKind.tag), [
        [2, 7],
      ]);
      _expectUntouched(text, ',');
      _expectUntouched(text, 'a');
      _expectUntouched(text, 'b', from: 8);
    });

    test('skips a tag inside italic and keeps the italic markers', () {
      const text = '*a #x*';
      expect(_runs(text, SpellSkipKind.tag), ['#x']);
      expect(_runs(text, SpellSkipKind.marker), ['*', '*']);
      _expectUntouched(text, 'a');
    });

    test('skips an escape', () {
      const text = 'a \\* b';
      expect(_runs(text, SpellSkipKind.escape), ['\\*']);
      _expectUntouched(text, 'a');
      _expectUntouched(text, 'b');
    });

    test('skips an escaped underscore next to a word', () {
      const text = 'snake\\_case word';
      expect(_runs(text, SpellSkipKind.escape), ['\\_']);
      _expectUntouched(text, 'snake');
      _expectUntouched(text, 'case');
    });
  });

  group('emphasis markers', () {
    for (final (name, text, markers, inner) in [
      (
        'skips the markers of double star bold',
        'a **bold** c',
        ['**', '**'],
        'bold',
      ),
      (
        'skips the markers of double underscore bold',
        'a __bold__ c',
        ['__', '__'],
        'bold',
      ),
      ('skips the markers of star italic', 'a *ital* c', ['*', '*'], 'ital'),
      (
        'skips the markers of underscore italic',
        'a _ital_ c',
        ['_', '_'],
        'ital',
      ),
      (
        'skips the markers of bold italic',
        'a ***both*** c',
        ['***', '***'],
        'both',
      ),
      ('skips the markers of strike', 'a ~~gone~~ c', ['~~', '~~'], 'gone'),
    ]) {
      test(name, () {
        expect(_runs(text, SpellSkipKind.marker), markers);
        _expectUntouched(text, inner);
        _expectUntouched(text, 'a');
        _expectUntouched(text, 'c', from: text.length - 1);
      });
    }

    test('marker offsets are exact for bold', () {
      expect(_pairs('a **bold** c', SpellSkipKind.marker), [
        [2, 4],
        [8, 10],
      ]);
    });
  });

  group('block markers', () {
    test('a heading marker is skipped and the title is not', () {
      const text = '## Title words';
      _expectCovered(text, SpellSkipKind.marker, '##');
      _expectUntouched(text, 'Title words');
    });

    test('a level one heading marker is skipped', () {
      const text = '# Top';
      _expectCovered(text, SpellSkipKind.marker, '#');
      _expectUntouched(text, 'Top');
    });

    test('a bullet marker is skipped and the item text is not', () {
      for (final m in ['-', '*', '+']) {
        final text = '$m item text';
        _expectCovered(text, SpellSkipKind.marker, m);
        _expectUntouched(text, 'item text');
      }
    });

    test('an indented bullet marker is skipped', () {
      const text = '    - nested item';
      _expectCovered(text, SpellSkipKind.marker, '-');
      _expectUntouched(text, 'nested item');
    });

    test('a numbered marker is skipped and the item text is not', () {
      const text = '12. numbered item';
      _expectCovered(text, SpellSkipKind.marker, '12.');
      _expectUntouched(text, 'numbered item');
    });

    test('an open task marker is skipped and the task text is not', () {
      const text = '- [ ] todo item';
      _expectCovered(text, SpellSkipKind.marker, '- [ ]');
      _expectUntouched(text, 'todo item');
    });

    test('a done task marker is skipped and the task text is not', () {
      const text = '- [x] done item';
      _expectCovered(text, SpellSkipKind.marker, '- [x]');
      _expectUntouched(text, 'done item');
    });

    test('a quote marker is skipped and the quote text is not', () {
      const text = '> quoted words';
      _expectCovered(text, SpellSkipKind.marker, '>');
      _expectUntouched(text, 'quoted words');
    });

    test('inline markers after a quote marker keep exact offsets', () {
      const text = '> **b** c';
      expect(
        _pairs(text, SpellSkipKind.marker).where((p) => p[0] >= 2).toList(),
        [
          [2, 4],
          [5, 7],
        ],
      );
      _expectCovered(text, SpellSkipKind.marker, '>');
      _expectUntouched(text, 'b');
      _expectUntouched(text, 'c');
    });

    test('inline ranges after a list marker keep exact offsets', () {
      expect(_pairs('1. #tag x', SpellSkipKind.tag), [
        [3, 7],
      ]);
      expect(_pairs('- see [[Note]]', SpellSkipKind.wikilink), [
        [6, 14],
      ]);
      expect(_pairs('- [ ] see [[Note]]', SpellSkipKind.wikilink), [
        [10, 18],
      ]);
    });

    test('a hashtag line is a tag and not a heading marker', () {
      const text = '#tag words';
      expect(_runs(text, SpellSkipKind.tag), ['#tag']);
      expect(_covered(text, SpellSkipKind.marker), isEmpty);
      _expectUntouched(text, 'words');
    });

    test(
      'a number without a period or a dash without a space is not a marker',
      () {
        const text = '1) not a marker -word `c`';
        expect(_runs(text, SpellSkipKind.marker), isEmpty);
        expect(_runs(text, SpellSkipKind.code), ['`c`']);
        _expectUntouched(text, '1)');
        _expectUntouched(text, '-word');
      },
    );
  });

  group('tables', () {
    const table = '| a | b |\n|---|:-:|\n| c | d |';

    test('every table pipe is a marker', () {
      final marker = _covered(table, SpellSkipKind.marker);
      for (var i = 0; i < table.length; i++) {
        if (table[i] == '|') {
          expect(marker.contains(i), isTrue, reason: 'pipe at $i');
        }
      }
    });

    test('the whole delimiter line is a marker', () {
      _expectCovered(table, SpellSkipKind.marker, '|---|:-:|');
    });

    test('the cell text stays checked', () {
      _expectCovered(table, SpellSkipKind.marker, '|---|:-:|');
      for (final cell in ['a', 'b', 'c', 'd']) {
        _expectUntouched(table, cell);
      }
    });

    test('inline ranges inside table cells are found', () {
      const text = '| `x` | **y** |\n|---|---|';
      expect(_runs(text, SpellSkipKind.code), ['`x`']);
      _expectCovered(text, SpellSkipKind.marker, '**');
      _expectCovered(text, SpellSkipKind.marker, '**', from: 10);
      _expectUntouched(text, 'y');
    });

    test('a wikilink in a cell is skipped with exact offsets', () {
      const text = '| [[Note]] | b |\n|---|---|';
      expect(_pairs(text, SpellSkipKind.wikilink), [
        [2, 10],
      ]);
    });

    test('table lines after prose keep their offsets', () {
      const text = 'intro\n| a | `b` |\n|---|---|\n| c | d |';
      final at = _find(text, '`b`');
      expect(_pairs(text, SpellSkipKind.code), [
        [at, at + 3],
      ]);
      _expectCovered(text, SpellSkipKind.marker, '|---|---|');
      _expectUntouched(text, 'intro');
    });
  });

  group('frontmatter', () {
    test('frontmatter at a segment start is one frontmatter range', () {
      const text = '---\ntitle: a\n---\nBody `c`';
      final fm = _pairs(text, SpellSkipKind.frontmatter);
      expect(fm, hasLength(1));
      expect(fm.single[0], 0);
      expect(fm.single[1], inInclusiveRange(16, 17));
      _expectUntouched(text, 'Body');
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
    });

    test('frontmatter with CRLF line ends is one range', () {
      const text = '---\r\ntitle: a\r\n---\r\nBody `c`';
      final fm = _pairs(text, SpellSkipKind.frontmatter);
      expect(fm, hasLength(1));
      expect(fm.single[0], 0);
      expect(fm.single[1], inInclusiveRange(18, 20));
      _expectUntouched(text, 'Body');
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
    });

    test('markdown inside frontmatter gives no other range', () {
      const text = '---\ntags: [[x]] `c` #t\n---\n';
      expect(
        {for (final r in _skips(text)) r.kind},
        {SpellSkipKind.frontmatter},
      );
    });

    test('the same text not at a segment start is not frontmatter', () {
      const text = '---\ntitle: a\n---\nBody `c`';
      expect(_pairs(text, SpellSkipKind.frontmatter, start: false), isEmpty);
      expect(_runs(text, SpellSkipKind.code, start: false), ['`c`']);
      _expectUntouched(text, 'title: a', start: false);
      _expectUntouched(text, 'Body', start: false);
    });

    test('the same text later in a segment is not frontmatter', () {
      const text = 'para\n---\ntitle: a\n---\nBody `c`';
      expect(_pairs(text, SpellSkipKind.frontmatter), isEmpty);
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
      _expectUntouched(text, 'title: a');
    });

    test('an unclosed frontmatter opener is not frontmatter', () {
      const text = '---\ntitle: a\nBody `c`';
      expect(_pairs(text, SpellSkipKind.frontmatter), isEmpty);
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
    });

    test('ranges after frontmatter keep exact offsets', () {
      const text = '---\nk: v\n---\n## Head [[N]]';
      final at = _find(text, '[[N]]');
      expect(_pairs(text, SpellSkipKind.wikilink), [
        [at, at + 5],
      ]);
      _expectCovered(text, SpellSkipKind.marker, '##');
    });
  });

  group('footer', () {
    test('everything from footerStart to the end is a footer range', () {
      const text = 'body text\n\n## Topics\n#a #b\n';
      final at = _find(text, '## Topics');
      expect(_pairs(text, SpellSkipKind.footer, footer: at), [
        [at, text.length],
      ]);
      _expectUntouched(text, 'body text', footer: at);
    });

    test('a footer at offset zero covers the whole text', () {
      const text = 'all footer';
      expect(_pairs(text, SpellSkipKind.footer, footer: 0), [
        [0, text.length],
      ]);
    });

    test('without footerStart there is no footer range', () {
      const text = 'body `c`\n\n## Topics\n#a';
      expect(_pairs(text, SpellSkipKind.footer), isEmpty);
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
      _expectUntouched(text, 'body');
    });

    test('a footer starting at the end of the text covers nothing', () {
      const text = 'body `c`';
      expect(
        _covered(text, SpellSkipKind.footer, footer: text.length),
        isEmpty,
      );
      // No zero-length footer range either: callers never see an empty one.
      expect(_pairs(text, SpellSkipKind.footer, footer: text.length), isEmpty);
      expect(_runs(text, SpellSkipKind.code, footer: text.length), ['`c`']);
    });

    test('the text before the footer still gets its ranges', () {
      const text = 'a `c` b\n---\nfooter words';
      final at = _find(text, 'footer words');
      expect(_runs(text, SpellSkipKind.code, footer: at), ['`c`']);
      expect(_pairs(text, SpellSkipKind.footer, footer: at), [
        [at, text.length],
      ]);
    });
  });

  group('offsets', () {
    test('stay correct after an emoji', () {
      const text = '😀 `c` [[N]] #t **b** \\* https://x.y';
      expect(_pairs(text, SpellSkipKind.code), [
        [3, 6],
      ]);
      expect(_pairs(text, SpellSkipKind.wikilink), [
        [7, 12],
      ]);
      expect(_pairs(text, SpellSkipKind.tag), [
        [13, 15],
      ]);
      expect(_pairs(text, SpellSkipKind.marker), [
        [16, 18],
        [19, 21],
      ]);
      expect(_runs(text, SpellSkipKind.escape), ['\\*']);
      expect(_pairs(text, SpellSkipKind.escape).single[0], 22);
      expect(_runs(text, SpellSkipKind.url), ['https://x.y']);
      expect(_pairs(text, SpellSkipKind.url).single[0], 25);
    });

    test(
      'stay correct after an emoji on an earlier line and inside a fence',
      () {
        const text = '😀\n```\n😀\n```\n[[N]] ## x';
        final at = _find(text, '[[N]]');
        expect(_pairs(text, SpellSkipKind.wikilink), [
          [at, at + 5],
        ]);
        _expectCovered(text, SpellSkipKind.code, '😀', from: 3);
        _expectUntouched(text, '😀');
      },
    );

    test('stay correct after an emoji inside link text and a heading', () {
      const text = '## 🎉 [😀](https://x.y) #t';
      _expectCovered(text, SpellSkipKind.url, 'https://x.y');
      expect(_pairs(text, SpellSkipKind.tag), [
        [text.length - 2, text.length],
      ]);
      _expectUntouched(text, '😀');
      _expectUntouched(text, '🎉');
    });

    test(
      'every range lies inside the text and never splits a surrogate pair',
      () {
        const text =
            '---\nk: 😀\n---\n## 😀 **b** [[N😀]] `😀`\n'
            '- [ ] #t😀 \\* https://x.y/😀 ok\n```\n😀\n```\n'
            '| 😀 | b |\n|---|---|\n| ![[2026-09-05#^b7k2m9]] | d |\n';
        final skips = _skips(text, footer: text.length - 5);
        expect(skips, isNotEmpty);
        for (final r in skips) {
          expect(r.start, inInclusiveRange(0, text.length));
          expect(r.end, inInclusiveRange(r.start, text.length));
          for (final edge in [r.start, r.end]) {
            if (edge > 0 && edge < text.length) {
              final before = text.codeUnitAt(edge - 1);
              final after = text.codeUnitAt(edge);
              final split =
                  before >= 0xD800 &&
                  before <= 0xDBFF &&
                  after >= 0xDC00 &&
                  after <= 0xDFFF;
              expect(split, isFalse, reason: '${r.kind} edge $edge');
            }
          }
        }
        expect({for (final r in skips) r.kind}, SpellSkipKind.values.toSet());
      },
    );
  });

  group('paragraphs', () {
    /// Removes a leading block marker, so a paragraph that keeps its marker
    /// and one that starts after it compare equal.
    String norm(String s) => s
        .trim()
        .replaceFirst(
          RegExp(
            r'^(#{1,6}[ \t]+|[-*+>][ \t]*(\[[ xX]\][ \t]*)?|\d{1,9}\.[ \t]+)',
          ),
          '',
        )
        .trim();

    /// The paragraphs equal [expected] (by [norm]), in order, and each one
    /// holds its expected text, starts on its first line, ends before its
    /// last line break and never overlaps the previous one.
    void expectParagraphs(
      String text,
      List<String> expected, {
      bool start = true,
    }) {
      final paras = spellParagraphs(text, atSegmentStart: start);
      expect(
        [for (final p in paras) norm(p.text)],
        [for (final e in expected) norm(e)],
        reason: 'paragraphs of ${text.replaceAll('\n', r'\n')}',
      );
      var cursor = 0;
      var prevEnd = 0;
      for (var i = 0; i < paras.length; i++) {
        final p = paras[i];
        final want = norm(expected[i]);
        expect(p.text, text.substring(p.start, p.end));
        final at = text.indexOf(want, cursor);
        expect(at, isNonNegative);
        final lineStart = at == 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
        var nl = text.indexOf('\n', at + want.length);
        if (nl < 0) nl = text.length;
        final lineEnd =
            nl > 0 && nl <= text.length && text.startsWith('\r', nl - 1)
            ? nl - 1
            : nl;
        expect(p.start, lessThanOrEqualTo(at), reason: 'start of $i');
        expect(p.start, greaterThanOrEqualTo(lineStart), reason: 'start of $i');
        expect(
          p.end,
          greaterThanOrEqualTo(at + want.length),
          reason: 'end of $i',
        );
        expect(p.end, lessThanOrEqualTo(lineEnd), reason: 'end of $i');
        expect(p.start, greaterThanOrEqualTo(prevEnd), reason: 'overlap at $i');
        cursor = at + want.length;
        prevEnd = p.end;
      }
    }

    test('splits a prose row at blank lines', () {
      expectParagraphs('one a\nstill one\n\ntwo\n\n\n\nthree', [
        'one a\nstill one',
        'two',
        'three',
      ]);
    });

    test('a line of only spaces and tabs is a blank line', () {
      expectParagraphs('a\n  \t \nb', ['a', 'b']);
    });

    test('a prose paragraph gets exact offsets and its own text', () {
      final paras = spellParagraphs(
        'one a\nstill\n\ntwo',
        atSegmentStart: true,
      );
      expect(paras, hasLength(2));
      expect(paras[0].start, 0);
      expect(paras[0].text.trimRight(), 'one a\nstill');
      expect(paras[1].start, 13);
      expect(paras[1].end, 16);
      expect(paras[1].text, 'two');
    });

    test('a heading is its own paragraph without a blank line', () {
      expectParagraphs('before\n## Head\nafter', [
        'before',
        '## Head',
        'after',
      ]);
    });

    test('consecutive headings are separate paragraphs', () {
      expectParagraphs('# One\n## Two\n### Three', [
        '# One',
        '## Two',
        '### Three',
      ]);
    });

    test('each list and task item line is its own paragraph', () {
      expectParagraphs(
        '- one\n- two\n1. three\n2. four\n- [ ] five\n- [x] six',
        ['- one', '- two', '1. three', '2. four', '- [ ] five', '- [x] six'],
      );
    });

    test('prose before a list and after it are separate paragraphs', () {
      expectParagraphs('intro\n- a\n- b\n\noutro', [
        'intro',
        '- a',
        '- b',
        'outro',
      ]);
    });

    test('a quote is its own paragraph between prose', () {
      expectParagraphs('before\n> quoted\nafter', [
        'before',
        '> quoted',
        'after',
      ]);
    });

    test('each table header and body line is its own paragraph', () {
      expectParagraphs('| h1 | h2 |\n|---|---|\n| c1 | c2 |\n| c3 | c4 |', [
        '| h1 | h2 |',
        '| c1 | c2 |',
        '| c3 | c4 |',
      ]);
    });

    test('a table splits from the prose around it', () {
      expectParagraphs('intro\n| h1 | h2 |\n|---|---|\n| c1 | c2 |\n\nafter', [
        'intro',
        '| h1 | h2 |',
        '| c1 | c2 |',
        'after',
      ]);
    });

    test('a fenced block gives no paragraph, blank lines inside included', () {
      expectParagraphs('before\n```\ncode line\n\nmore code\n```\nafter', [
        'before',
        'after',
      ]);
    });

    test('an unclosed fence gives no paragraph to the end', () {
      expectParagraphs('before\n```\ncode\n\nmore', ['before']);
    });

    test('frontmatter gives no paragraph at a segment start', () {
      expectParagraphs('---\ntitle: x\n---\nBody', ['Body']);
    });

    test(
      'the same lines not at a segment start are prose around two rules',
      () {
        expectParagraphs('---\ntitle: x\n---\nBody', [
          'title: x',
          'Body',
        ], start: false);
      },
    );

    test('a rule gives no paragraph and splits the prose', () {
      for (final rule in ['---', '***', '___', '-----']) {
        expectParagraphs('a\n$rule\nb', ['a', 'b']);
      }
    });

    test('CRLF line ends split paragraphs and stay out of the text', () {
      const text = 'a\r\n\r\nb\r\n## H\r\n- i';
      expectParagraphs(text, ['a', 'b', '## H', '- i']);
      expect(spellParagraphs(text, atSegmentStart: true)[1].start, 5);
    });

    test('empty and blank text give no paragraph while a word gives one', () {
      expect(spellParagraphs('', atSegmentStart: true), isEmpty);
      expect(spellParagraphs('\n\n  \n', atSegmentStart: true), isEmpty);
      expect(spellParagraphs('a', atSegmentStart: true), hasLength(1));
    });

    test('offsets stay correct after an emoji', () {
      const text = '😀 hello\n\nworld\n## 🎉 title\n- item 😀';
      expectParagraphs(text, ['😀 hello', 'world', '## 🎉 title', '- item 😀']);
      final paras = spellParagraphs(text, atSegmentStart: true);
      expect(paras[0].start, 0);
      expect(paras[1].start, 10);
      expect(paras[1].end, 15);
    });

    test('a whole Source mode body splits into the right paragraphs', () {
      const body =
          '---\ntitle: x\n---\n# Title\n\nIntro line one\nline two\n\n'
          '- item a\n- [ ] task b\n1. num c\n\n'
          '| h1 | h2 |\n|---|---|\n| c1 | c2 |\n\n'
          '```dart\nvoid main() {}\n\nprint(1);\n```\n\n---\n\n> quoted\n\nend text';
      expectParagraphs(body, [
        '# Title',
        'Intro line one\nline two',
        '- item a',
        '- [ ] task b',
        '1. num c',
        '| h1 | h2 |',
        '| c1 | c2 |',
        '> quoted',
        'end text',
      ]);
    });

    test('a fence between prose lines splits the prose in three', () {
      expectParagraphs(
        '## Head\n\nsome prose\nmore prose\n- item\n```\ncode\n```\nlast',
        ['## Head', 'some prose\nmore prose', '- item', 'last'],
        start: false,
      );
    });

    test('a live preview row of the same body gives the same paragraphs', () {
      const body =
          '---\ntitle: x\n---\n# Title\n\nIntro line one\nline two\n\n'
          '- item a\n- [ ] task b\n1. num c\n\n'
          '| h1 | h2 |\n|---|---|\n| c1 | c2 |\n\n'
          '```dart\nvoid main() {}\n\nprint(1);\n```\n\n---\n\n> quoted\n\nend text';
      final rows = splitRows(body, atSegmentStart: true);
      // The body really is several kinds of row, items and fences included.
      expect(
        {for (final r in rows) r.kind},
        containsAll([
          RowKind.prose,
          RowKind.bullet,
          RowKind.task,
          RowKind.numbered,
          RowKind.table,
          RowKind.code,
          RowKind.quote,
        ]),
      );
      final whole = [
        for (final p in spellParagraphs(body, atSegmentStart: true))
          '${p.start}-${p.end}:${p.text}',
      ];
      expect(whole, hasLength(9));
      // Item rows pass their whole line, marker included (ruling Q1).
      final perRow = [
        for (final row in rows)
          for (final p in spellParagraphs(
            body.substring(row.start, row.end),
            atSegmentStart: row.start == 0,
          ))
            '${row.start + p.start}-${row.start + p.end}:${p.text}',
      ];
      expect(perRow, whole);
    });

    test('live preview rows give the same skip ranges as the whole body', () {
      const body =
          '---\ntitle: x\n---\n# Title [[Note]] #tag\n\n'
          'Intro `code` [t](https://u.example) https://b.example\n\n'
          '- item ![[Other]] a\\*b\n- [ ] task [[x|y]] **bold**\n'
          '1. num https://n.example\n\n'
          '| h1 | `c` |\n|---|---|\n| [[c1]] | c2 |\n\n'
          '```dart\nvoid main() {}\n\nprint(1);\n```\n\n---\n\n'
          '> quoted #q ![i](dir/p.png)\n\nend text';
      List<String> shifted(List<SpellSkipRange> skips, int by) => [
        for (final r in skips) '${r.kind.name}:${by + r.start}-${by + r.end}',
      ];
      final whole = shifted(_skips(body), 0)..sort();
      final rows = splitRows(body, atSegmentStart: true);
      expect(rows.length, greaterThan(6));
      final perRow = [
        for (final row in rows)
          ...shifted(
            spellSkipRanges(
              body.substring(row.start, row.end),
              atSegmentStart: row.start == 0,
            ),
            row.start,
          ),
      ]..sort();
      expect(whole.length, greaterThan(15));
      expect(perRow, whole);
    });
  });

  group('drop rules', () {
    SpellSkipRange skip(SpellSkipKind kind, int start, int end) =>
        SpellSkipRange(kind: kind, start: start, end: end);

    const grammarKinds = {
      SpellSkipKind.code,
      SpellSkipKind.wikilink,
      SpellSkipKind.transclusion,
      SpellSkipKind.url,
    };

    test('dropsSpelling is true when the range touches any skip kind', () {
      for (final kind in SpellSkipKind.values) {
        final skips = [skip(kind, 10, 20)];
        expect(dropsSpelling(12, 15, skips), isTrue, reason: kind.name);
        expect(dropsSpelling(0, 30, skips), isTrue, reason: kind.name);
        expect(dropsSpelling(10, 20, skips), isTrue, reason: kind.name);
        expect(dropsSpelling(9, 11, skips), isTrue, reason: kind.name);
        expect(dropsSpelling(19, 21, skips), isTrue, reason: kind.name);
      }
    });

    test('dropsSpelling is false for a range that only touches an edge', () {
      for (final kind in SpellSkipKind.values) {
        final skips = [skip(kind, 10, 20)];
        expect(dropsSpelling(0, 10, skips), isFalse, reason: kind.name);
        expect(dropsSpelling(20, 30, skips), isFalse, reason: kind.name);
        expect(dropsSpelling(0, 5, skips), isFalse, reason: kind.name);
        expect(dropsSpelling(25, 30, skips), isFalse, reason: kind.name);
        // A positive in the same test, so a constant false cannot pass.
        expect(dropsSpelling(0, 11, skips), isTrue, reason: kind.name);
      }
    });

    test('dropsSpelling finds a later skip in an unsorted list', () {
      final skips = [
        skip(SpellSkipKind.url, 100, 110),
        skip(SpellSkipKind.code, 0, 5),
        skip(SpellSkipKind.tag, 40, 50),
      ];
      expect(dropsSpelling(2, 3, skips), isTrue);
      expect(dropsSpelling(45, 46, skips), isTrue);
      expect(dropsSpelling(105, 106, skips), isTrue);
      expect(dropsSpelling(60, 70, skips), isFalse);
      expect(dropsSpelling(5, 40, skips), isFalse);
    });

    test('dropsSpelling is false with no skips while it is true with one', () {
      expect(dropsSpelling(0, 5, const []), isFalse);
      expect(dropsSpelling(0, 5, [skip(SpellSkipKind.escape, 4, 6)]), isTrue);
    });

    test('dropsGrammar is true for code, wikilink, transclusion and url', () {
      for (final kind in grammarKinds) {
        final skips = [skip(kind, 10, 20)];
        expect(dropsGrammar(12, 15, skips), isTrue, reason: kind.name);
        expect(dropsGrammar(0, 30, skips), isTrue, reason: kind.name);
        expect(dropsGrammar(10, 20, skips), isTrue, reason: kind.name);
        expect(dropsGrammar(9, 11, skips), isTrue, reason: kind.name);
        expect(dropsGrammar(19, 21, skips), isTrue, reason: kind.name);
      }
    });

    test(
      'dropsGrammar is false for tag, escape, marker, frontmatter and footer',
      () {
        for (final kind in SpellSkipKind.values.where(
          (k) => !grammarKinds.contains(k),
        )) {
          final skips = [skip(kind, 10, 20)];
          expect(dropsGrammar(12, 15, skips), isFalse, reason: kind.name);
          expect(dropsGrammar(0, 30, skips), isFalse, reason: kind.name);
          expect(dropsGrammar(10, 20, skips), isFalse, reason: kind.name);
          // The same range still drops spelling.
          expect(dropsSpelling(12, 15, skips), isTrue, reason: kind.name);
        }
      },
    );

    test('dropsGrammar is false for a range that only touches an edge', () {
      for (final kind in grammarKinds) {
        final skips = [skip(kind, 10, 20)];
        expect(dropsGrammar(0, 10, skips), isFalse, reason: kind.name);
        expect(dropsGrammar(20, 30, skips), isFalse, reason: kind.name);
        expect(dropsGrammar(0, 5, skips), isFalse, reason: kind.name);
        expect(dropsGrammar(25, 30, skips), isFalse, reason: kind.name);
        expect(dropsGrammar(0, 11, skips), isTrue, reason: kind.name);
      }
    });

    test(
      'dropsGrammar ignores a non grammar skip that overlaps a grammar skip',
      () {
        final skips = [
          skip(SpellSkipKind.marker, 0, 50),
          skip(SpellSkipKind.code, 10, 12),
        ];
        expect(dropsGrammar(11, 12, skips), isTrue);
        expect(dropsGrammar(30, 40, skips), isFalse);
        expect(dropsSpelling(30, 40, skips), isTrue);
      },
    );

    test(
      'dropsGrammar looks past a skip that does not match to a later one',
      () {
        final skips = [
          skip(SpellSkipKind.tag, 0, 5),
          skip(SpellSkipKind.footer, 5, 8),
          skip(SpellSkipKind.url, 20, 30),
        ];
        expect(dropsGrammar(0, 25, skips), isTrue);
        expect(dropsGrammar(0, 18, skips), isFalse);
      },
    );

    test('dropsGrammar is false with no skips while it is true with one', () {
      expect(dropsGrammar(0, 5, const []), isFalse);
      expect(dropsGrammar(0, 5, [skip(SpellSkipKind.url, 4, 6)]), isTrue);
    });

    test('the rules work on real skip ranges for a line of text', () {
      const text = 'word `code` #tag **bold** [[Note]] https://x.example end';
      final skips = _skips(text);
      (int, int) span(String s) =>
          (text.indexOf(s), text.indexOf(s) + s.length);
      final code = span('`code`');
      final tag = span('#tag');
      final wiki = span('[[Note]]');
      final url = span('https://x.example');
      final bold = span('**bold**');
      final word = span('word');
      final end = span('end');
      for (final s in [code, tag, wiki, url, bold]) {
        expect(
          dropsSpelling(s.$1, s.$2, skips),
          isTrue,
          reason: text.substring(s.$1, s.$2),
        );
      }
      for (final s in [code, wiki, url]) {
        expect(
          dropsGrammar(s.$1, s.$2, skips),
          isTrue,
          reason: text.substring(s.$1, s.$2),
        );
      }
      for (final s in [tag, bold]) {
        expect(
          dropsGrammar(s.$1, s.$2, skips),
          isFalse,
          reason: text.substring(s.$1, s.$2),
        );
      }
      for (final s in [word, end]) {
        expect(dropsSpelling(s.$1, s.$2, skips), isFalse);
      }
      expect(dropsSpelling(word.$1, end.$2, skips), isTrue);
    });
  });

  group('verify pins', () {
    test('ranges are returned sorted by start and then by end', () {
      const text = '`c` | [t](https://u.example) | #tag **b**\n---\nfooter';
      for (final footer in <int?>[null, 0, 4]) {
        final skips = _skips(text, footer: footer);
        for (var i = 1; i < skips.length; i++) {
          final a = skips[i - 1];
          final b = skips[i];
          expect(
            a.start < b.start || (a.start == b.start && a.end <= b.end),
            isTrue,
            reason:
                '${a.kind} ${a.start}-${a.end} before '
                '${b.kind} ${b.start}-${b.end}',
          );
        }
        expect(skips.length, greaterThan(4));
      }
      // A footer from offset zero ties on start with the code span: the
      // shorter range comes first.
      final tied = _skips('`c` tail', footer: 0);
      expect(
        [for (final r in tied) r.kind],
        [SpellSkipKind.code, SpellSkipKind.footer],
      );
    });

    test('a footerStart past the end or below zero is clamped', () {
      const text = 'body `c`';
      expect(
        _covered(text, SpellSkipKind.footer, footer: text.length + 5),
        isEmpty,
      );
      expect(
        _pairs(text, SpellSkipKind.footer, footer: text.length + 5),
        isEmpty,
      );
      expect(_pairs(text, SpellSkipKind.footer, footer: -3), [
        [0, text.length],
      ]);
      expect(_runs(text, SpellSkipKind.code, footer: text.length + 5), ['`c`']);
    });

    test('a bare url inside a code span or wikilink is skipped as that', () {
      const text = 'a `see https://c.example` b [[https://w.example]] c';
      expect(_runs(text, SpellSkipKind.url), isEmpty);
      expect(_runs(text, SpellSkipKind.code), ['`see https://c.example`']);
      expect(_runs(text, SpellSkipKind.wikilink), ['[[https://w.example]]']);
    });

    test('a bare url right after a code span is still a url', () {
      const text = '`c`https://x.example';
      expect(_runs(text, SpellSkipKind.url), ['https://x.example']);
      expect(_runs(text, SpellSkipKind.code), ['`c`']);
    });

    test('whitespace only text after a marker gives no paragraph', () {
      expect(spellParagraphs('#  \n-   \n', atSegmentStart: true), isEmpty);
      expect(
        spellParagraphs('# h\n-   \n', atSegmentStart: true),
        hasLength(1),
      );
    });

    test('an image url is skipped, a relative path included', () {
      const text =
          'see ![a pic](pics/cat.png) and ![b](https://i.example/b.png)';
      expect(_runs(text, SpellSkipKind.url), [
        'pics/cat.png',
        'https://i.example/b.png',
      ]);
      expect(_pairs(text, SpellSkipKind.url).first, [
        text.indexOf('pics'),
        text.indexOf('pics') + 'pics/cat.png'.length,
      ]);
      expect(_covered(text, null).contains(text.indexOf('a pic')), isFalse);
    });

    test('an image inside a code span is skipped as code only', () {
      const text = 'x `![a](pics/cat.png)` y';
      expect(_runs(text, SpellSkipKind.url), isEmpty);
      expect(_runs(text, SpellSkipKind.code), ['`![a](pics/cat.png)`']);
    });

    test('a url used as link text is a url range, the link url too', () {
      const text = '[https://a.example/x](https://b.example) tail';
      expect(_pairs(text, SpellSkipKind.url), [
        [1, 20],
        [22, 39],
      ]);
    });
  });
}
