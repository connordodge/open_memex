// WI #161 (A2): offset-preserving inline tokenizer (Spec R4, R5, R37, R38;
// rulings D2, D3). Wikilink parity inputs are the Rust `link_extractor.rs`
// test inputs; their expected groups are what `WIKILINK_RE` captures.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_inline.dart';

/// `[start, end]` pairs, so failures print plainly and don't depend on
/// `InlineRange.==`.
List<List<int>> _pairs(Iterable<InlineRange> ranges) => [
  for (final r in ranges) [r.start, r.end],
];

List<int>? _pair(InlineRange? r) => r == null ? null : [r.start, r.end];

/// A compact description of a token list: kind, span, markers, content.
List<Object> _describe(List<InlineToken> tokens) => [
  for (final t in tokens)
    [t.kind, _pair(t.span), _pairs(t.markers), _pair(t.content)],
];

void _expectNoTokens(String input) {
  expect(tokenizeInline(input), isEmpty, reason: 'input: ${_show(input)}');
}

String _show(String s) => s.replaceAll('\n', r'\n').replaceAll('\r', r'\r');

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

/// Kinds a later token may nest inside (in the content only).
const _nestable = {
  InlineTokenKind.link,
  InlineTokenKind.bold,
  InlineTokenKind.italic,
  InlineTokenKind.boldItalic,
  InlineTokenKind.strike,
};

/// Checks every structural contract of `tokenizeInline` on [text].
void _expectWellFormed(String text) {
  final why = 'input: ${_show(text)}';
  final tokens = tokenizeInline(text);
  final n = text.length;

  bool splitsPair(int b) =>
      b > 0 &&
      b < n &&
      _isHigh(text.codeUnitAt(b - 1)) &&
      _isLow(text.codeUnitAt(b));

  void checkRange(InlineRange r, String what) {
    expect(r.start, inInclusiveRange(0, n), reason: '$why $what start');
    expect(r.end, inInclusiveRange(r.start, n), reason: '$why $what end');
    expect(splitsPair(r.start), isFalse, reason: '$why $what start splits');
    expect(splitsPair(r.end), isFalse, reason: '$why $what end splits');
  }

  bool inside(InlineRange outer, InlineRange inner) =>
      outer.start <= inner.start && inner.end <= outer.end;
  bool disjoint(InlineRange a, InlineRange b) =>
      a.end <= b.start || b.end <= a.start;

  for (final t in tokens) {
    final s = t.span;
    checkRange(s, '${t.kind} span');
    expect(s.end, greaterThan(s.start), reason: '$why ${t.kind} empty span');
    expect(
      text.substring(s.start, s.end).contains('\n'),
      isFalse,
      reason: '$why ${t.kind} spans a newline',
    );
    checkRange(t.content, '${t.kind} content');
    expect(inside(s, t.content), isTrue, reason: '$why content in span');
    var covered = t.content.end - t.content.start;
    for (var i = 0; i < t.markers.length; i++) {
      final m = t.markers[i];
      checkRange(m, '${t.kind} marker $i');
      expect(m.end, greaterThan(m.start), reason: '$why empty marker');
      expect(inside(s, m), isTrue, reason: '$why marker in span');
      expect(disjoint(m, t.content), isTrue, reason: '$why marker vs content');
      if (i > 0) {
        expect(
          m.start,
          greaterThanOrEqualTo(t.markers[i - 1].end),
          reason: '$why markers sorted and disjoint',
        );
      }
      covered += m.end - m.start;
    }
    if (t.kind == InlineTokenKind.escape) {
      expect(t.markers, isEmpty, reason: '$why escape has no markers');
      expect(text[s.start], r'\', reason: '$why escape starts with backslash');
      expect(t.content.start, s.start + 1, reason: '$why escape content');
      expect(t.content.end, s.end, reason: '$why escape content end');
    } else {
      expect(covered, s.end - s.start, reason: '$why markers+content=span');
    }
    switch (t) {
      case WikilinkToken():
        expect(t.kind, InlineTokenKind.wikilink, reason: why);
        for (final r in [t.titleRange, t.kindRange, t.aliasRange]) {
          if (r == null) continue;
          checkRange(r, 'wikilink group');
          expect(inside(s, r), isTrue, reason: '$why group in span');
        }
        expect(
          t.target,
          text.substring(t.titleRange.start, t.titleRange.end).trim(),
          reason: '$why target',
        );
      case LinkToken():
        expect(t.kind, InlineTokenKind.link, reason: why);
        expect(_pair(t.textRange), _pair(t.content), reason: '$why link text');
        checkRange(t.urlRange, 'link url');
        expect(
          t.markers.any((m) => inside(m, t.urlRange)),
          isTrue,
          reason: '$why url hidden in a marker',
        );
        expect(t.url, text.substring(t.urlRange.start, t.urlRange.end));
        expect(t.url.contains(' '), isFalse, reason: '$why url has a space');
      case TransclusionLinkToken():
        expect(t.kind, InlineTokenKind.transclusion, reason: why);
        expect(t.date, text.substring(t.content.start, t.content.end));
        expect(t.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')), reason: why);
      default:
        expect(
          t.kind,
          isNot(
            anyOf(
              InlineTokenKind.wikilink,
              InlineTokenKind.link,
              InlineTokenKind.transclusion,
            ),
          ),
          reason: '$why kind needs its subtype',
        );
    }
  }

  for (var i = 0; i < tokens.length; i++) {
    for (var j = i + 1; j < tokens.length; j++) {
      final a = tokens[i];
      final b = tokens[j];
      expect(
        b.span.start,
        greaterThan(a.span.start),
        reason: '$why tokens sorted by start',
      );
      final nested = _nestable.contains(a.kind) && inside(a.content, b.span);
      expect(
        a.span.end <= b.span.start || nested,
        isTrue,
        reason:
            '$why ${a.kind} ${_pair(a.span)} and ${b.kind} ${_pair(b.span)} '
            'overlap without nesting in content',
      );
    }
  }
}

/// Local fuzz fixture lines (A1's `markdown_fixtures.dart` isn't merged yet).
const _fixtureLines = <String>[
  '',
  'plain text with nothing special',
  '# Heading with **bold** and `code`',
  '- [ ] task with [[Note~extends|alias]] and *it*',
  '1. numbered with ~~strike~~ and __bold__',
  '> quote with _italic_ and ***both***',
  'snake_case_word and __init__ and a_b_c',
  'mixed **bold _italic_ bold** end',
  'see ![[2026-09-05#^ab12]] then ![[2026-09-05#^ab12..^cd34]]',
  'link [text](http://example.com/a_b) and [bad](http://x y)',
  'emoji 😀 **😀** [[😀]] `😀` _😀_ ~~😀~~',
  'café **crème** [[Café|crème]]',
  'escapes \\*x\\* \\_y\\_ \\\\ \\`z\\`',
  '`[[x]]` and `[t](http://x)` and `*a*`',
  '[[a*b*]] and **[[a**]] and [a*](u)*',
  '***',
  '**',
  '* * *',
  '``',
  '` `',
  '[[]] [[ ]] [[a|]] [[a~]] [[~k]]',
  '[[a [[b]] [[[c]] [[d]]]',
  '<http://x> ==hi== <b>x</b> ![alt](http://x) [^1] \$x^2\$',
  '| a | b |\n|---|---|',
  'first *line\nsecond* line',
  '**a\nb** and `c\nd` and [e\nf](u) and [g](h\ni)',
  'crlf *a*\r\n*b* done\r\n',
  'x\n*a*\n',
  '😀😀😀*😀*😀😀',
  '\u{1F600}\\\u{1F600}',
  'trailing backslash \\',
  '**unclosed and *unclosed and ~~unclosed and `unclosed',
  '_a_b_ *a*b* __a__b__',
  'a*b*c a_b_c',
  '***bi*** ****four**** *****five*****',
  '`` `inner` ``',
  '![[2026-13-45#^zz]] ![[bad]] !![[2026-09-05#^ab]]',
  '[[x]](http://y) [t]([[z]])',
];

const _fragments = <String>[
  '*',
  '**',
  '***',
  '_',
  '__',
  '~~',
  '~',
  '`',
  '``',
  '[[',
  ']]',
  '[',
  ']',
  '](',
  '(',
  ')',
  '|',
  '!',
  '\\',
  'a',
  'b',
  ' ',
  ' ',
  '\n',
  '\r\n',
  '😀',
  'é',
  '#^ab',
  '2026-09-05',
  '![[2026-09-05#^ab12]]',
  '[[T~k|al]]',
  '[t](http://x)',
  'http://x',
  '<b>',
  '==',
  'word_word',
  'x',
];

void main() {
  group('emphasis, strike and code spans (AC1)', () {
    test(
      'emphasis strike and code delimiters give one token with exact ranges',
      () {
        final cases = <(String, InlineTokenKind, List<List<int>>, List<int>)>[
          (
            '**b**',
            InlineTokenKind.bold,
            [
              [0, 2],
              [3, 5],
            ],
            [2, 3],
          ),
          (
            '__b__',
            InlineTokenKind.bold,
            [
              [0, 2],
              [3, 5],
            ],
            [2, 3],
          ),
          (
            '*i*',
            InlineTokenKind.italic,
            [
              [0, 1],
              [2, 3],
            ],
            [1, 2],
          ),
          (
            '_i_',
            InlineTokenKind.italic,
            [
              [0, 1],
              [2, 3],
            ],
            [1, 2],
          ),
          (
            '***bi***',
            InlineTokenKind.boldItalic,
            [
              [0, 3],
              [5, 8],
            ],
            [3, 5],
          ),
          (
            '~~s~~',
            InlineTokenKind.strike,
            [
              [0, 2],
              [3, 5],
            ],
            [2, 3],
          ),
          (
            '`c`',
            InlineTokenKind.codeSpan,
            [
              [0, 1],
              [2, 3],
            ],
            [1, 2],
          ),
          (
            '``c``',
            InlineTokenKind.codeSpan,
            [
              [0, 2],
              [3, 5],
            ],
            [2, 3],
          ),
        ];
        for (final (input, kind, markers, content) in cases) {
          for (final (prefix, suffix) in [('', ''), ('x ', ' y')]) {
            final text = '$prefix$input$suffix';
            final d = prefix.length;
            final tokens = tokenizeInline(text);
            expect(tokens, hasLength(1), reason: text);
            final t = tokens.single;
            expect(t.kind, kind, reason: text);
            expect(_pair(t.span), [d, d + input.length], reason: text);
            expect(_pairs(t.markers), [
              for (final m in markers) [m[0] + d, m[1] + d],
            ], reason: text);
            expect(_pair(t.content), [
              content[0] + d,
              content[1] + d,
            ], reason: text);
            expect(t.start, d, reason: '$text start shorthand');
            expect(t.end, d + input.length, reason: '$text end shorthand');
          }
        }
      },
    );

    test('tokens in running text come back in order with exact spans', () {
      expect(_describe(tokenizeInline('a **b** and *c* then ~~d~~ or `e`')), [
        [
          InlineTokenKind.bold,
          [2, 7],
          [
            [2, 4],
            [5, 7],
          ],
          [4, 5],
        ],
        [
          InlineTokenKind.italic,
          [12, 15],
          [
            [12, 13],
            [14, 15],
          ],
          [13, 14],
        ],
        [
          InlineTokenKind.strike,
          [21, 26],
          [
            [21, 23],
            [24, 26],
          ],
          [23, 24],
        ],
        [
          InlineTokenKind.codeSpan,
          [30, 33],
          [
            [30, 31],
            [32, 33],
          ],
          [31, 32],
        ],
      ]);
    });

    test('code spans need backtick runs of equal length', () {
      expect(_describe(tokenizeInline('``a`b``')), [
        [
          InlineTokenKind.codeSpan,
          [0, 7],
          [
            [0, 2],
            [5, 7],
          ],
          [2, 5],
        ],
      ]);
      _expectNoTokens('`a``');
      _expectNoTokens('``a`');
    });

    test('code span content keeps its spaces untrimmed', () {
      expect(_describe(tokenizeInline('` a `')), [
        [
          InlineTokenKind.codeSpan,
          [0, 5],
          [
            [0, 1],
            [4, 5],
          ],
          [1, 4],
        ],
      ]);
    });

    test('nothing inside a code span is tokenized', () {
      for (final input in ['`*a*`', r'`\*`', '`~~s~~`', '`__b__`']) {
        expect(tokenizeInline(input).map((t) => t.kind), [
          InlineTokenKind.codeSpan,
        ], reason: input);
      }
    });

    test('star emphasis may open and close inside a word', () {
      expect(_describe(tokenizeInline('a*b*c')), [
        [
          InlineTokenKind.italic,
          [1, 4],
          [
            [1, 2],
            [3, 4],
          ],
          [2, 3],
        ],
      ]);
    });

    test('emoji content keeps whole surrogate pairs', () {
      expect(_describe(tokenizeInline('**😀**')), [
        [
          InlineTokenKind.bold,
          [0, 6],
          [
            [0, 2],
            [4, 6],
          ],
          [2, 4],
        ],
      ]);
    });
  });

  group('precedence (AC2)', () {
    test(
      'precedence is code span then wikilink or transclusion then link then emphasis',
      () {
        final code = tokenizeInline('`[[x]]`');
        expect(_describe(code), [
          [
            InlineTokenKind.codeSpan,
            [0, 7],
            [
              [0, 1],
              [6, 7],
            ],
            [1, 6],
          ],
        ]);

        final wl = tokenizeInline('[[a*b*]]');
        expect(wl.map((t) => t.kind), [InlineTokenKind.wikilink]);
        expect(_pair(wl.single.span), [0, 8]);
        expect((wl.single as WikilinkToken).target, 'a*b*');

        const tr = '![[2026-09-05#^ab12]]';
        final trTokens = tokenizeInline(tr);
        expect(trTokens.map((t) => t.kind), [InlineTokenKind.transclusion]);
        final t = trTokens.single as TransclusionLinkToken;
        expect(t.date, '2026-09-05');
        expect(_pair(t.span), [0, tr.length]);

        final codeLink = tokenizeInline('`[t](http://x)`');
        expect(codeLink.map((t) => t.kind), [InlineTokenKind.codeSpan]);
        expect(_pair(codeLink.single.span), [0, 15]);
      },
    );

    test('transclusion markers hide the bang brackets and block reference', () {
      const text = 'see ![[2026-09-05#^ab12..^cd34]] and [[B]]';
      expect(_describe(tokenizeInline(text)), [
        [
          InlineTokenKind.transclusion,
          [4, 32],
          [
            [4, 7],
            [17, 32],
          ],
          [7, 17],
        ],
        [
          InlineTokenKind.wikilink,
          [37, 42],
          [
            [37, 39],
            [40, 42],
          ],
          [39, 40],
        ],
      ]);
    });

    test('a dated wikilink without a block reference is a plain wikilink', () {
      final tokens = tokenizeInline('![[2026-09-05]]');
      expect(tokens.map((t) => t.kind), [InlineTokenKind.wikilink]);
      final w = tokens.single as WikilinkToken;
      expect(_pair(w.span), [1, 15]);
      expect(w.target, '2026-09-05');
    });

    test('a code span that overlaps a wikilink or link wins over it', () {
      expect(_describe(tokenizeInline('[[a `b]] c`')), [
        [
          InlineTokenKind.codeSpan,
          [4, 11],
          [
            [4, 5],
            [10, 11],
          ],
          [5, 10],
        ],
      ]);
      expect(_describe(tokenizeInline('[a `b](u)`')), [
        [
          InlineTokenKind.codeSpan,
          [3, 10],
          [
            [3, 4],
            [9, 10],
          ],
          [4, 9],
        ],
      ]);
    });

    test('a wikilink wins over emphasis delimiters around and inside it', () {
      final tokens = tokenizeInline('**[[a**]]');
      expect(tokens.map((t) => t.kind), [InlineTokenKind.wikilink]);
      final w = tokens.single as WikilinkToken;
      expect(_pair(w.span), [2, 9]);
      expect(w.target, 'a**');
    });

    test('a link wins over emphasis in its text edge and its url', () {
      final a = tokenizeInline('[a*](u)*');
      expect(a.map((t) => t.kind), [InlineTokenKind.link]);
      expect(_pair(a.single.span), [0, 7]);

      final b = tokenizeInline('[t](a*b*c)');
      expect(b.map((t) => t.kind), [InlineTokenKind.link]);
      expect((b.single as LinkToken).url, 'a*b*c');
    });
  });

  group('wikilinks (AC3)', () {
    test(
      'wikilinks match WIKILINK_RE parity and expose title kind alias ranges',
      () {
        // input -> [start, end, title, kind, alias, target] per match.
        final cases = <(String, List<List<Object?>>)>[
          (
            'Hello [[Foo]] world.',
            [
              [
                6,
                13,
                [8, 11],
                null,
                null,
                'Foo',
              ],
            ],
          ),
          (
            'This [[Foo~extends]] thing.',
            [
              [
                5,
                20,
                [7, 10],
                [11, 18],
                null,
                'Foo',
              ],
            ],
          ),
          (
            'Was [[Foo~inspired-by]] this.',
            [
              [
                4,
                23,
                [6, 9],
                [10, 21],
                null,
                'Foo',
              ],
            ],
          ),
          (
            'Read [[Foo|My Foo]] later.',
            [
              [
                5,
                19,
                [7, 10],
                null,
                [11, 17],
                'Foo',
              ],
            ],
          ),
          (
            '[[Foo~extends|alias text]]',
            [
              [
                0,
                26,
                [2, 5],
                [6, 13],
                [14, 24],
                'Foo',
              ],
            ],
          ),
          (
            '[[Foo~Made_Up]]',
            [
              [
                0,
                15,
                [2, 5],
                [6, 13],
                null,
                'Foo',
              ],
            ],
          ),
          (
            '[[]] and [[ ]] and [[Foo]]',
            [
              [
                9,
                14,
                [11, 12],
                null,
                null,
                '',
              ],
              [
                19,
                26,
                [21, 24],
                null,
                null,
                'Foo',
              ],
            ],
          ),
          (
            '[[Foo]] then [[Foo]] again',
            [
              [
                0,
                7,
                [2, 5],
                null,
                null,
                'Foo',
              ],
              [
                13,
                20,
                [15, 18],
                null,
                null,
                'Foo',
              ],
            ],
          ),
          (
            '[[a [[b]]',
            [
              [
                4,
                9,
                [6, 7],
                null,
                null,
                'b',
              ],
            ],
          ),
          (
            '[[A #x]]',
            [
              [
                0,
                8,
                [2, 6],
                null,
                null,
                'A #x',
              ],
            ],
          ),
          (
            '[[日本語|ラベル]]',
            [
              [
                0,
                11,
                [2, 5],
                null,
                [6, 9],
                '日本語',
              ],
            ],
          ),
          (
            '[[Alpha|日本語 😀]]',
            [
              [
                0,
                16,
                [2, 7],
                null,
                [8, 14],
                'Alpha',
              ],
            ],
          ),
          (
            '[[Café|crème]]',
            [
              [
                0,
                14,
                [2, 6],
                null,
                [7, 12],
                'Café',
              ],
            ],
          ),
          (
            '[[A|Ünïcode – dash]]',
            [
              [
                0,
                20,
                [2, 3],
                null,
                [4, 18],
                'A',
              ],
            ],
          ),
          ('[[Alpha\n  Beta]]', []),
          ('[[Foo\nx', []),
          (
            '[[2026-10-01#^ab]]',
            [
              [
                0,
                18,
                [2, 16],
                null,
                null,
                '2026-10-01#^ab',
              ],
            ],
          ),
          (
            '[[a|b|c]]',
            [
              [
                0,
                9,
                [2, 3],
                null,
                [4, 7],
                'a',
              ],
            ],
          ),
          (
            '[[a~b~c]]',
            [
              [
                0,
                9,
                [2, 3],
                [4, 7],
                null,
                'a',
              ],
            ],
          ),
          (
            '[[a~b|c~d]]',
            [
              [
                0,
                11,
                [2, 3],
                [4, 5],
                [6, 9],
                'a',
              ],
            ],
          ),
          (
            '[[a]]]',
            [
              [
                0,
                5,
                [2, 3],
                null,
                null,
                'a',
              ],
            ],
          ),
          (
            '[[[a]]',
            [
              [
                1,
                6,
                [3, 4],
                null,
                null,
                'a',
              ],
            ],
          ),
          ('[[a|]]', []),
          ('[[a~]]', []),
          ('[[~k]]', []),
          ('[[a~k|]]', []),
          ('[[a]b]]', []),
          (
            '[[  Foo Bar  ~ k |  shown  ]]',
            [
              [
                0,
                29,
                [2, 13],
                [14, 17],
                [18, 27],
                'Foo Bar',
              ],
            ],
          ),
          (
            '[[😀]]',
            [
              [
                0,
                6,
                [2, 4],
                null,
                null,
                '😀',
              ],
            ],
          ),
          (
            '[[x]][[y]]',
            [
              [
                0,
                5,
                [2, 3],
                null,
                null,
                'x',
              ],
              [
                5,
                10,
                [7, 8],
                null,
                null,
                'y',
              ],
            ],
          ),
        ];
        for (final (input, expected) in cases) {
          final tokens = tokenizeInline(input);
          expect(
            tokens.map((t) => t.kind),
            everyElement(InlineTokenKind.wikilink),
            reason: _show(input),
          );
          expect(
            [
              for (final t in tokens.cast<WikilinkToken>())
                [
                  t.span.start,
                  t.span.end,
                  _pair(t.titleRange),
                  _pair(t.kindRange),
                  _pair(t.aliasRange),
                  t.target,
                ],
            ],
            expected,
            reason: _show(input),
          );
        }

        // The four shapes: hidden markers and shown content (alias, else
        // title).
        final shapes = <(String, List<List<int>>, List<int>)>[
          (
            '[[Title~kind|alias]]',
            [
              [0, 13],
              [18, 20],
            ],
            [13, 18],
          ),
          (
            '[[Title|alias]]',
            [
              [0, 8],
              [13, 15],
            ],
            [8, 13],
          ),
          (
            '[[Title~kind]]',
            [
              [0, 2],
              [7, 14],
            ],
            [2, 7],
          ),
          (
            '[[Title]]',
            [
              [0, 2],
              [7, 9],
            ],
            [2, 7],
          ),
          (
            '[[  Foo Bar  ~ k |  shown  ]]',
            [
              [0, 18],
              [27, 29],
            ],
            [18, 27],
          ),
        ];
        for (final (input, markers, content) in shapes) {
          final t = tokenizeInline(input).single;
          expect(_pairs(t.markers), markers, reason: input);
          expect(_pair(t.content), content, reason: input);
        }
      },
    );
  });

  group('links (AC4)', () {
    test(
      'links expose text and url ranges and reject spaced urls and newlines',
      () {
        final a = tokenizeInline('[text](url)').single as LinkToken;
        expect(a.kind, InlineTokenKind.link);
        expect(_pair(a.span), [0, 11]);
        expect(_pair(a.textRange), [1, 5]);
        expect(_pair(a.urlRange), [7, 10]);
        expect(a.url, 'url');
        expect(_pairs(a.markers), [
          [0, 1],
          [5, 11],
        ]);
        expect(_pair(a.content), [1, 5]);

        final b = tokenizeInline('see [t](http://x) now').single as LinkToken;
        expect(_pair(b.span), [4, 17]);
        expect(_pair(b.textRange), [5, 6]);
        expect(_pair(b.urlRange), [8, 16]);
        expect(b.url, 'http://x');
        expect(_pairs(b.markers), [
          [4, 5],
          [6, 17],
        ]);

        final c = tokenizeInline('[a b](u)').single as LinkToken;
        expect(_pair(c.textRange), [1, 4]);

        for (final input in [
          '[t](http://x y)',
          '[a b](http://x y)',
          '[t](http://x\ny)',
          '[a\nb](http://x)',
          '[t]\n(http://x)',
        ]) {
          expect(
            tokenizeInline(input).where((t) => t.kind == InlineTokenKind.link),
            isEmpty,
            reason: _show(input),
          );
        }
      },
    );
  });

  group('emphasis edges and escapes (AC5)', () {
    test(
      'intraword underscores unclosed and cross line emphasis and escapes stay literal',
      () {
        _expectNoTokens('snake_case_word');
        _expectNoTokens('*unclosed');

        final boldish = tokenizeInline('**a*');
        expect(
          boldish.map((t) => t.kind),
          isNot(
            contains(anyOf(InlineTokenKind.bold, InlineTokenKind.boldItalic)),
          ),
        );
        final hidden = {
          for (final t in boldish)
            for (final m in t.markers)
              for (var i = m.start; i < m.end; i++) i,
        };
        expect(
          [0, 1, 3].where((i) => !hidden.contains(i)),
          isNotEmpty,
          reason: 'an unmatched star of **a* stays literal',
        );

        for (final input in [
          '*a\nb*',
          '**a\nb**',
          '_a\nb_',
          '***a\nb***',
          '~~a\nb~~',
          '`a\nb`',
          '*a\r\nb*',
        ]) {
          _expectNoTokens(input);
        }

        final esc = tokenizeInline(r'\*x\*');
        expect(_describe(esc), [
          [
            InlineTokenKind.escape,
            [0, 2],
            <List<int>>[],
            [1, 2],
          ],
          [
            InlineTokenKind.escape,
            [3, 5],
            <List<int>>[],
            [4, 5],
          ],
        ]);
      },
    );

    test('emphasis on a later line still tokenizes', () {
      expect(_describe(tokenizeInline('x\n*a*')), [
        [
          InlineTokenKind.italic,
          [2, 5],
          [
            [2, 3],
            [4, 5],
          ],
          [3, 4],
        ],
      ]);
      expect(_describe(tokenizeInline('*a*\r\n*b*')), [
        [
          InlineTokenKind.italic,
          [0, 3],
          [
            [0, 1],
            [2, 3],
          ],
          [1, 2],
        ],
        [
          InlineTokenKind.italic,
          [5, 8],
          [
            [5, 6],
            [7, 8],
          ],
          [6, 7],
        ],
      ]);
    });

    test('unclosed constructs of every kind produce no tokens', () {
      for (final input in [
        '**b',
        '__b',
        '_i',
        '~~s',
        '`c',
        '``c`',
        '[[a',
        '[[a]',
        '[t](u',
        '[t]',
        '![[2026-09-05#^ab12',
        'b**',
        'i_',
      ]) {
        _expectNoTokens(input);
      }
    });

    test('underscores never open or close inside a word', () {
      _expectNoTokens('foo_bar_');
      _expectNoTokens('_foo_bar');
      _expectNoTokens('a__b__c');
      expect(_describe(tokenizeInline('x _i_ y')), [
        [
          InlineTokenKind.italic,
          [2, 5],
          [
            [2, 3],
            [4, 5],
          ],
          [3, 4],
        ],
      ]);
    });

    test('an escaped backslash leaves the following emphasis intact', () {
      expect(_describe(tokenizeInline(r'\\*a*')), [
        [
          InlineTokenKind.escape,
          [0, 2],
          <List<int>>[],
          [1, 2],
        ],
        [
          InlineTokenKind.italic,
          [2, 5],
          [
            [2, 3],
            [4, 5],
          ],
          [3, 4],
        ],
      ]);
    });
  });

  group('not rendered (AC6)', () {
    test('bare urls autolinks highlights and html produce no tokens', () {
      for (final input in [
        'see http://example.com now',
        'http://example.com/a_b_c',
        'www.example.com',
        '<http://x>',
        '==hi==',
        '<b>x</b>',
        '![alt](http://x)',
        '| a | b |',
        'note[^1]',
        r'$x^2$',
      ]) {
        _expectNoTokens(input);
      }
    });
  });

  group('structural invariants (AC7)', () {
    test(
      'token ranges stay in bounds without overlap or split surrogate pairs',
      () {
        for (final line in _fixtureLines) {
          _expectWellFormed(line);
        }
        // Seeded generated lines from markdown fragments.
        final rng = Random(161);
        for (var i = 0; i < 2000; i++) {
          final b = StringBuffer();
          final count = rng.nextInt(14);
          for (var k = 0; k < count; k++) {
            b.write(_fragments[rng.nextInt(_fragments.length)]);
          }
          _expectWellFormed(b.toString());
        }
        // Sanity: the fixtures do produce tokens of every kind.
        final kinds = {
          for (final line in _fixtureLines)
            for (final t in tokenizeInline(line)) t.kind,
        };
        expect(kinds, containsAll(InlineTokenKind.values));
      },
    );

    test('a token never nests inside a code span wikilink or transclusion', () {
      for (final input in [
        '`**b**`',
        '[[**b**]]',
        '[[a|*b*]]',
        '![[2026-09-05#^ab12]]',
        r'[[a\*b]]',
      ]) {
        expect(tokenizeInline(input), hasLength(1), reason: input);
      }
    });
  });

  group('InlineRange', () {
    test('InlineRange has value semantics and range helpers', () {
      final start = int.parse('2');
      final r = InlineRange(start, 5);
      expect(r.start, 2);
      expect(r.end, 5);
      expect(r.length, 3);
      expect(r.isEmpty, isFalse);
      expect(InlineRange(start, 2).isEmpty, isTrue);
      expect(InlineRange(start, 2).length, 0);
      expect(r, InlineRange(2, 5));
      expect(r.hashCode, InlineRange(2, 5).hashCode);
      expect(r == InlineRange(2, 6), isFalse);
      expect(r == InlineRange(1, 5), isFalse);
      expect(r.of('0123456'), '234');

      expect(r.encloses(InlineRange(2, 5)), isTrue);
      expect(r.encloses(InlineRange(3, 4)), isTrue);
      expect(r.encloses(InlineRange(1, 4)), isFalse);
      expect(r.encloses(InlineRange(3, 6)), isFalse);

      expect(r.overlaps(InlineRange(4, 8)), isTrue);
      expect(r.overlaps(InlineRange(0, 3)), isTrue);
      expect(r.overlaps(InlineRange(3, 4)), isTrue);
      expect(r.overlaps(InlineRange(5, 8)), isFalse);
      expect(r.overlaps(InlineRange(0, 2)), isFalse);
      expect(r.overlaps(InlineRange(3, 3)), isFalse);
      expect(InlineRange(start, 2).overlaps(InlineRange(0, 9)), isFalse);
    });
  });
}
