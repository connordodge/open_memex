// WI #20 (A3): canonical daily body (C3), transclusion parse (C4) and the
// segment split/join. Fixture literals are copied verbatim from
// contracts-1.md C3/C4; Rust (#7, #9) passes the same fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';

/// A comparable description of a segment list.
List<Object?> _describe(List<Segment> segments) => [
  for (final s in segments)
    switch (s) {
      TextSegment(:final text) => ['text', text],
      TransclusionSegment(:final raw, :final date, :final from, :final to) => [
        'card',
        raw,
        date,
        from,
        to,
      ],
      FooterSegment(:final chips) => ['footer', chips],
    },
];

void _expectSplit(String input, String person, List<String> chips, String id) {
  final result = splitDailyBody(input);
  expect(result.person, person, reason: '$id person');
  expect(result.chips, chips, reason: '$id chips');
}

List<Object?> _describeTokens(List<TransclusionToken> tokens) => [
  for (final t in tokens) [t.date, t.from, t.to, t.start, t.end],
];

// C3 split fixtures.
const s1 = 'Morning pages\n\n- buy milk\n';
const s2 =
    'Morning pages\n<!-- memex:topics -->\n[[Player Loop~about]]\n[[Sleep~about]]\n';

// C3 assemble fixture outputs.
const j1 =
    'Morning pages\n<!-- memex:topics -->\n[[Player Loop~about]]\n[[Sleep~about]]\n';
const j2 = 'Morning pages\n<!-- memex:topics -->\n';
const j3 = '<!-- memex:topics -->\n';

// Segment fixtures.
const g1 =
    '## 2026-09-05\n![[2026-09-05#^b7k2m9]]\n![[2026-09-05#^b7k2m9..^c3d4e5]]\nMy own words.\n';
const g2 = 'See ![[2026-09-05#^b7k2m9]] here\n';
const g3 = 'x\n![[2026-09-05#^b7k2m9]]';

void main() {
  group('splitDailyBody (C3)', () {
    test('splitDailyBody returns C3 fixtures S1-S8 exactly', () {
      _expectSplit(s1, 'Morning pages\n\n- buy milk\n', [], 'S1');
      _expectSplit(s2, 'Morning pages\n', ['Player Loop', 'Sleep'], 'S2');
      _expectSplit('<!-- memex:topics -->\n', '', [], 'S3');
      _expectSplit('a\n<!-- memex:topics -->  \r\n[[X~about]]\r\n', 'a\n', [
        'X',
      ], 'S4');
      _expectSplit(
        'see <!-- memex:topics --> here\n',
        'see <!-- memex:topics --> here\n',
        [],
        'S5',
      );
      _expectSplit(
        'a\n<!-- memex:topics -->\n[[X~about]]\nlate thought\n',
        'a\nlate thought\n',
        ['X'],
        'S6',
      );
      _expectSplit('a\n<!-- memex:topics -->\nlate', 'a\nlate\n', [], 'S7');
      _expectSplit(
        'a\n<!-- memex:topics -->\n\n<!-- memex:topics -->\n[[X~about]]\n',
        'a\n',
        ['X'],
        'S8',
      );
    });

    test('splitDailyBody with no marker keeps the whole body as person', () {
      _expectSplit(s1, s1, [], 'S1');
      _expectSplit('', '', [], 'empty body');
      _expectSplit('no newline', 'no newline', [], 'no trailing newline');
      _expectSplit(
        '[[X~about]]\n',
        '[[X~about]]\n',
        [],
        'chip-like, no marker',
      );
    });

    test('splitDailyBody splits at the marker line only, not inline text', () {
      _expectSplit(
        'see <!-- memex:topics --> here\n',
        'see <!-- memex:topics --> here\n',
        [],
        'S5',
      );
      _expectSplit(
        'x <!-- memex:topics -->\n[[X~about]]\n',
        'x <!-- memex:topics -->\n[[X~about]]\n',
        [],
        'marker with prefix text',
      );
    });

    test(
      'splitDailyBody ignores trailing spaces and CR on marker and chips',
      () {
        _expectSplit('a\n<!-- memex:topics -->  \r\n[[X~about]]\r\n', 'a\n', [
          'X',
        ], 'S4');
        _expectSplit(
          'a\n<!-- memex:topics -->\n[[X~about]]   \n[[Y~about]] \r\n',
          'a\n',
          ['X', 'Y'],
          'trailing spaces on chips',
        );
      },
    );

    test(
      'splitDailyBody keeps chip order and reads a last chip without newline',
      () {
        _expectSplit(
          'a\n<!-- memex:topics -->\n[[Zeta~about]]\n[[Alpha~about]]\n[[Mid~about]]',
          'a\n',
          ['Zeta', 'Alpha', 'Mid'],
          'order preserved, last line unterminated',
        );
      },
    );

    test(
      'splitDailyBody moves stray text below the marker to the end of person (Q1)',
      () {
        _expectSplit(
          'a\n<!-- memex:topics -->\n[[X~about]]\nlate thought\n',
          'a\nlate thought\n',
          ['X'],
          'S6',
        );
        _expectSplit('a\n<!-- memex:topics -->\nlate', 'a\nlate\n', [], 'S7');
        _expectSplit(
          'a\n<!-- memex:topics -->\n[[X~about]]\nfoo\n[[Y~about]]\nbar\n',
          'a\nfoo\nbar\n',
          ['X', 'Y'],
          'stray lines interleaved with chips keep their order',
        );
        _expectSplit(
          'a\n<!-- memex:topics -->\n- [[X~about]]\n[[~about]]\n',
          'a\n- [[X~about]]\n[[~about]]\n',
          [],
          'near-miss chip lines are stray text',
        );
      },
    );

    test(
      'splitDailyBody with empty person adds stray text without a leading newline',
      () {
        _expectSplit('<!-- memex:topics -->\nlate\n[[X~about]]\n', 'late\n', [
          'X',
        ], 'empty person + stray');
      },
    );

    test(
      'splitDailyBody drops blank lines and repeated marker lines below the marker',
      () {
        _expectSplit(
          'a\n<!-- memex:topics -->\n\n<!-- memex:topics -->\n[[X~about]]\n',
          'a\n',
          ['X'],
          'S8',
        );
        _expectSplit(
          'a\n<!-- memex:topics -->\n\n\n[[X~about]]\n\n<!-- memex:topics -->  \n[[Y~about]]\n\n',
          'a\n',
          ['X', 'Y'],
          'many blanks and markers',
        );
      },
    );
  });

  group('assembleDailyBody (C3)', () {
    test('assembleDailyBody returns C3 fixtures J1-J3 exactly', () {
      expect(
        assembleDailyBody('Morning pages\n', ['Player Loop', 'Sleep']),
        j1,
        reason: 'J1',
      );
      expect(assembleDailyBody('Morning pages', []), j2, reason: 'J2');
      expect(assembleDailyBody('', []), j3, reason: 'J3');
    });

    test('assembleDailyBody keeps the person text verbatim', () {
      expect(
        assembleDailyBody('a\n\n', ['X']),
        'a\n\n<!-- memex:topics -->\n[[X~about]]\n',
      );
      expect(
        assembleDailyBody('café 😀', ['Été']),
        'café 😀\n<!-- memex:topics -->\n[[Été~about]]\n',
      );
    });

    test(
      'assembleDailyBody round-trips the J1-J3 outputs through splitDailyBody',
      () {
        for (final b in [j1, j2, j3]) {
          final parts = splitDailyBody(b);
          expect(assembleDailyBody(parts.person, parts.chips), b, reason: b);
        }
      },
    );
  });

  group('parseTransclusions (C4)', () {
    test(
      'parseTransclusions returns C4 fixtures P1-P5 with UTF-16 offsets',
      () {
        expect(
          _describeTokens(
            parseTransclusions('See ![[2026-09-05#^b7k2m9]] here'),
          ),
          [
            ['2026-09-05', 'b7k2m9', null, 4, 27],
          ],
          reason: 'P1',
        );
        expect(
          _describeTokens(
            parseTransclusions('![[2026-09-05#^b7k2m9..^c3d4e5]]'),
          ),
          [
            ['2026-09-05', 'b7k2m9', 'c3d4e5', 0, 32],
          ],
          reason: 'P2',
        );
        expect(
          parseTransclusions('[[2026-09-05#^b7k2m9]]'),
          isEmpty,
          reason: 'P3',
        );
        expect(
          parseTransclusions('![[2026-9-5#^b7k2m9]]'),
          isEmpty,
          reason: 'P4',
        );
        expect(
          _describeTokens(parseTransclusions('café ![[2026-09-05#^b7k2m9]]')),
          [
            ['2026-09-05', 'b7k2m9', null, 5, 28],
          ],
          reason: 'P5 (UTF-16 start 5, not UTF-8 byte 6)',
        );
      },
    );

    test(
      'parseTransclusions counts an emoji before a token as two UTF-16 units',
      () {
        expect(
          _describeTokens(parseTransclusions('😀 ![[2026-09-05#^b7k2m9]]')),
          [
            ['2026-09-05', 'b7k2m9', null, 3, 26],
          ],
        );
      },
    );

    test('parseTransclusions finds several tokens in order', () {
      expect(
        _describeTokens(
          parseTransclusions(
            'a ![[2026-09-05#^b7k2m9]] b ![[2026-09-06#^c3d4e5..^f6g7h8]]',
          ),
        ),
        [
          ['2026-09-05', 'b7k2m9', null, 2, 25],
          ['2026-09-06', 'c3d4e5', 'f6g7h8', 28, 60],
        ],
      );
    });

    test('parseTransclusions enforces the C4 id alphabet and length', () {
      final id26 = 'a' * 26;
      final id27 = 'a' * 27;
      expect(_describeTokens(parseTransclusions('![[2026-09-05#^$id26]]')), [
        ['2026-09-05', id26, null, 0, 43],
      ], reason: '26-char id is accepted');
      expect(
        parseTransclusions('![[2026-09-05#^$id27]]'),
        isEmpty,
        reason: '27-char id is rejected',
      );
      expect(
        parseTransclusions('![[2026-09-05#^B7K2M9]]'),
        isEmpty,
        reason: 'uppercase id is rejected',
      );
      expect(
        parseTransclusions('![[2026-09-05#^]]'),
        isEmpty,
        reason: 'empty id is rejected',
      );
      expect(
        parseTransclusions('![[2026-09-05#^b7k2m9..c3d4e5]]'),
        isEmpty,
        reason: 'range end without ^ is rejected',
      );
      expect(
        parseTransclusions('![[2026-09-05^b7k2m9]]'),
        isEmpty,
        reason: 'missing # is rejected',
      );
    });
  });

  group('split / join, daily', () {
    test('split isDaily S2 yields person text and footer with chips', () {
      final segments = split(s2, isDaily: true);
      expect(_describe(segments), [
        ['text', 'Morning pages\n'],
        [
          'footer',
          ['Player Loop', 'Sleep'],
        ],
      ]);
    });

    test('join of the daily S2 segments equals assembleDailyBody output', () {
      final segments = split(s2, isDaily: true);
      expect(join(segments), j1);
      expect(join(segments), s2);
    });

    test(
      'split isDaily keeps transclusion-looking lines inside the person text',
      () {
        const body =
            'Notes\n![[2026-09-05#^b7k2m9]]\n<!-- memex:topics -->\n[[X~about]]\n';
        expect(_describe(split(body, isDaily: true)), [
          ['text', 'Notes\n![[2026-09-05#^b7k2m9]]\n'],
          [
            'footer',
            ['X'],
          ],
        ]);
      },
    );

    test('split isDaily with no marker yields an empty footer', () {
      expect(_describe(split(s1, isDaily: true)), [
        ['text', s1],
        ['footer', <String>[]],
      ]);
    });

    test('join of edited daily segments assembles the canonical body', () {
      expect(
        join(const [
          TextSegment('Hi'),
          FooterSegment(['X', 'Y']),
        ]),
        'Hi\n<!-- memex:topics -->\n[[X~about]]\n[[Y~about]]\n',
      );
      expect(
        join(const [TextSegment(''), FooterSegment([])]),
        '<!-- memex:topics -->\n',
      );
    });
  });

  group('split / join, non-daily', () {
    test(
      'split non-daily G1 yields text, card, empty text, range card, text',
      () {
        expect(_describe(split(g1, isDaily: false)), [
          ['text', '## 2026-09-05\n'],
          ['card', '![[2026-09-05#^b7k2m9]]\n', '2026-09-05', 'b7k2m9', null],
          ['text', ''],
          [
            'card',
            '![[2026-09-05#^b7k2m9..^c3d4e5]]\n',
            '2026-09-05',
            'b7k2m9',
            'c3d4e5',
          ],
          ['text', 'My own words.\n'],
        ]);
      },
    );

    test('split non-daily G2 keeps an inline token in one text segment', () {
      expect(_describe(split(g2, isDaily: false)), [
        ['text', g2],
      ]);
    });

    test(
      'split non-daily G3 keeps an unterminated card line raw and ends with empty text',
      () {
        expect(_describe(split(g3, isDaily: false)), [
          ['text', 'x\n'],
          ['card', '![[2026-09-05#^b7k2m9]]', '2026-09-05', 'b7k2m9', null],
          ['text', ''],
        ]);
      },
    );

    test(
      'split non-daily puts an empty text segment before a leading card',
      () {
        const body = '![[2026-09-05#^b7k2m9]]\nafter\n';
        expect(_describe(split(body, isDaily: false)), [
          ['text', ''],
          ['card', '![[2026-09-05#^b7k2m9]]\n', '2026-09-05', 'b7k2m9', null],
          ['text', 'after\n'],
        ]);
      },
    );

    test('split non-daily card line keeps trailing spaces and CRLF in raw', () {
      const body = 'a\r\n![[2026-09-05#^b7k2m9]]  \r\nb\r\n';
      expect(_describe(split(body, isDaily: false)), [
        ['text', 'a\r\n'],
        ['card', '![[2026-09-05#^b7k2m9]]  \r\n', '2026-09-05', 'b7k2m9', null],
        ['text', 'b\r\n'],
      ]);
    });

    test('split non-daily leaves lines with more than one token in text', () {
      const twoTokens = '![[2026-09-05#^b7k2m9]]![[2026-09-05#^c3d4e5]]\n';
      const prefixed = '> ![[2026-09-05#^b7k2m9]]\n';
      const suffixed = '![[2026-09-05#^b7k2m9]] tail\n';
      for (final body in [twoTokens, prefixed, suffixed]) {
        expect(_describe(split(body, isDaily: false)), [
          ['text', body],
        ], reason: body);
      }
    });

    test('split non-daily of an empty string is one empty text segment', () {
      expect(_describe(split('', isDaily: false)), [
        ['text', ''],
      ]);
    });

    // TEST-CHANGE (#253, R10): every note can have a Note footer now, so this
    // no longer pins that a non-daily marker is plain text.
    test('split non-daily treats the Topics marker as a footer', () {
      final segments = split(s2, isDaily: false);
      expect(segments.whereType<FooterSegment>(), hasLength(1));
      expect(join(segments), s2);
    });

    test('join(split(s)) == s for G1, G2, G3 and S1', () {
      for (final s in [g1, g2, g3, s1]) {
        expect(join(split(s, isDaily: false)), s, reason: s);
      }
    });

    test('join(split(s)) == s for multi-byte, CRLF and card-heavy inputs', () {
      const inputs = [
        'café ☕\n![[2026-09-05#^b7k2m9]]\n😀 done\n',
        '![[2026-09-05#^b7k2m9]]\n![[2026-09-05#^c3d4e5]]\n![[2026-09-05#^f6g7h8]]',
        'a\r\n![[2026-09-05#^b7k2m9]]  \r\n\r\nb',
        '\n\n',
      ];
      for (final s in inputs) {
        expect(join(split(s, isDaily: false)), s, reason: s);
      }
    });

    test('join concatenates edited text segments with card raw text', () {
      expect(
        join(const [
          TextSegment('intro\n'),
          TransclusionSegment(
            raw: '![[2026-09-05#^b7k2m9]]\n',
            date: '2026-09-05',
            from: 'b7k2m9',
          ),
          TextSegment('typed here'),
        ]),
        'intro\n![[2026-09-05#^b7k2m9]]\ntyped here',
      );
    });
  });

  group('transclusion card ids', () {
    test(
      'a range card exposes from and to; a single-block card has to == null',
      () {
        final cards = split(
          g1,
          isDaily: false,
        ).whereType<TransclusionSegment>().toList();
        expect(cards, hasLength(2));
        expect(cards[0].date, '2026-09-05');
        expect(cards[0].from, 'b7k2m9');
        expect(cards[0].to, isNull);
        expect(cards[1].date, '2026-09-05');
        expect(cards[1].from, 'b7k2m9');
        expect(cards[1].to, 'c3d4e5');
      },
    );
  });

  // WI #238 (T2): footer tag lines and the non-daily split. The fixture is
  // the contract Rust `daily::split_body` / `split_note_body` / `assemble`
  // pass too (D13); the named tests pin each arm of the rules on their own.
  group('Note footer split (D13)', () {
    test('footer_split.json rows all pass in Dart', () {
      final fixture =
          jsonDecode(
                File('test/fixtures/tags/footer_split.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(fixture['marker'], topicsMarker);
      final rows = (fixture['split']! as List).cast<Map<String, Object?>>();
      final decisions = {for (final r in rows) r['decision']};
      for (final required in [
        'chip line',
        'tag line',
        'legacy tag line',
        'heading',
        'double hash',
        'blank',
        'repeated marker',
        'fenced marker',
        'no marker',
      ]) {
        expect(decisions, contains(required), reason: 'a $required row');
      }

      final failures = <String>[];
      var checked = 0;
      for (final row in rows) {
        final input = row['input']! as String;
        final want = [
          row['person'],
          (row['chips']! as List).cast<String>(),
          (row['tags']! as List).cast<String>(),
        ];
        for (final on in (row['on']! as List).cast<String>()) {
          final DailyBody got = switch (on) {
            'daily' => splitDailyBody(input),
            'note' => splitNoteBody(input),
            _ => throw StateError('unknown splitter $on'),
          };
          checked++;
          final gotParts = [got.person, got.chips, got.tags];
          if (jsonEncode(gotParts) != jsonEncode(want)) {
            failures.add(
              '$on / ${row['name']}: ${jsonEncode(input)}\n'
              '  want ${jsonEncode(want)}\n  got  ${jsonEncode(gotParts)}',
            );
          }
        }
      }
      for (final row
          in (fixture['assemble']! as List).cast<Map<String, Object?>>()) {
        checked++;
        final got = assembleDailyBody(
          row['person']! as String,
          (row['chips']! as List).cast<String>(),
        );
        if (got != row['body']) {
          failures.add('assemble / ${row['name']}: ${jsonEncode(got)}');
        }
      }
      expect(
        failures,
        isEmpty,
        reason: '${failures.length} of $checked checks failed',
      );
    });

    test('both splitters drop footer tag lines and report their names', () {
      const tagLines = {
        '#work': 'work',
        '#My Tag': 'My Tag',
        '#123': '123',
        '#x  \r': 'x',
        '#été': 'été',
      };
      for (final MapEntry(key: line, value: name) in tagLines.entries) {
        final body = 'Day.\n$topicsMarker\n[[X~about]]\n$line\n';
        for (final got in [splitDailyBody(body), splitNoteBody(body)]) {
          expect(got.person, 'Day.\n', reason: '$line is not person text');
          expect(got.chips, ['X'], reason: line);
          expect(got.tags, [name], reason: '$line is a tag line');
        }
      }
      for (final line in ['# Heading', '##x', '#', '  #x', 'x #y']) {
        final body = 'Day.\n$topicsMarker\n[[X~about]]\n$line\n';
        for (final got in [splitDailyBody(body), splitNoteBody(body)]) {
          expect(got.person, 'Day.\n$line\n', reason: '$line is stray text');
          expect(got.chips, ['X'], reason: line);
          expect(got.tags, isEmpty, reason: line);
        }
      }
    });

    test('splitNoteBody ignores a marker inside fenced code', () {
      for (final fence in ['```', '~~~', '````']) {
        final body =
            'Code:\n$fence\n$topicsMarker\n[[X~about]]\n$fence\nAfter.\n';
        final got = splitNoteBody(body);
        expect(got.person, body, reason: '$fence: fenced marker is body text');
        expect(got.chips, isEmpty, reason: fence);
        expect(got.tags, isEmpty, reason: fence);

        final withFooter = '$body$topicsMarker\n[[Y~about]]\n#y\n';
        final split = splitNoteBody(withFooter);
        expect(split.person, body, reason: '$fence: the later marker splits');
        expect(split.chips, ['Y'], reason: fence);
        expect(split.tags, ['y'], reason: fence);
      }
      const plain = 'Notes.\n$topicsMarker\n[[X~about]]\n#x\nlate\n';
      final note = splitNoteBody(plain);
      final daily = splitDailyBody(plain);
      expect(note.person, 'Notes.\nlate\n');
      expect(note.person, daily.person);
      expect(note.chips, daily.chips);
      expect(note.tags, daily.tags);
      for (final body in ['', 'Last line', 'a\n\n- b\n']) {
        final got = splitNoteBody(body);
        expect(got.person, body);
        expect(got.chips, isEmpty);
        expect(got.tags, isEmpty);
      }
    });
  });

  // WI #253 (A5): the Note footer on every note. Non-daily footer text stays
  // out of the editable text and `join` gives it back byte for byte; a note
  // with no marker splits as it always did.
  group('split and join on a non-daily note with a footer', () {
    const marker = topicsMarker;
    const footer = '$marker\n[[Pricing~about]]\n#memex\n#pricing\n';
    const card = '![[2026-09-05#^b7k2m9..^c3d4e5]]\n';

    test(
      'split on a non-daily note ends in a FooterSegment holding its chips',
      () {
        final segments = split('Plan\n$footer', isDaily: false);

        expect(segments, hasLength(2));
        expect((segments[0] as TextSegment).text, 'Plan\n');
        expect((segments[1] as FooterSegment).chips, ['Pricing']);
      },
    );

    test(
      'cards above the marker stay cards and the footer comes after the last text',
      () {
        final segments = split('A\n${card}B\n$footer', isDaily: false);

        expect(_describe(segments), [
          ['text', 'A\n'],
          ['card', card, '2026-09-05', 'b7k2m9', 'c3d4e5'],
          ['text', 'B\n'],
          [
            'footer',
            ['Pricing'],
          ],
        ]);
      },
    );

    test(
      'join of split round-trips a non-daily note with a footer and transclusions',
      () {
        final body = 'Intro\n${card}Middle\n$card$footer';

        final segments = split(body, isDaily: false);

        expect(segments.last, isA<FooterSegment>());
        expect(segments.whereType<TransclusionSegment>(), hasLength(2));
        expect(join(segments), body);
      },
    );

    for (final (name, body) in const [
      ('only a marker', '$marker\n'),
      ('a marker with no final newline', 'Plan\n$marker'),
      ('a footer with no final newline', 'Plan\n$marker\n#memex'),
      ('a CRLF footer', 'Plan\r\n$marker\r\n[[A~about]]\r\n#memex\r\n'),
      ('trailing spaces on the marker', 'Plan\n$marker  \n#memex  \n'),
      ('blank lines in the footer', 'Plan\n$marker\n\n#memex\n\n'),
      ('a second marker', 'Plan\n$marker\n#memex\n$marker\n#work\n'),
      ('tag lines before chip lines', 'Plan\n$marker\n#memex\n[[A~about]]\n'),
      ('a stray line below the marker', 'Plan\n$marker\n#memex\nstray\n'),
      (
        'a transclusion token below the marker',
        'Plan\n$marker\n![[2026-09-05#^b7k2m9]]\n',
      ),
      ('an empty person section', '$marker\n[[A~about]]\n'),
    ]) {
      test('join of split round-trips $name', () {
        final segments = split(body, isDaily: false);

        expect(segments.last, isA<FooterSegment>());
        expect(join(segments), body);
      });
    }

    test('split keeps the footer text out of every text segment', () {
      final segments = split('Plan\n$card$footer', isDaily: false);

      final text = segments.whereType<TextSegment>().map((s) => s.text).join();
      expect(text, 'Plan\n');
    });

    test('a transclusion token below the marker is not a card', () {
      final segments = split(
        'Plan\n$marker\n![[2026-09-05#^b7k2m9]]\n',
        isDaily: false,
      );

      expect(segments.whereType<TransclusionSegment>(), isEmpty);
      expect(segments.last, isA<FooterSegment>());
    });

    test('a marker inside fenced code on a non-daily note is body text', () {
      const fenced = 'Code:\n```\n$marker\n#memex\n```\nAfter\n';

      expect(_describe(split(fenced, isDaily: false)), [
        ['text', fenced],
      ]);
      expect(join(split(fenced, isDaily: false)), fenced);
    });

    test('a marker after a closed fence starts the footer', () {
      const body = '```\ncode\n```\n$marker\n#memex\n';

      final segments = split(body, isDaily: false);

      expect((segments.first as TextSegment).text, '```\ncode\n```\n');
      expect(segments.last, isA<FooterSegment>());
      expect(join(segments), body);
    });

    test(
      'a non-daily note with no marker splits as it did before the footer',
      () {
        const body = 'Intro\n$card\nOutro\n';

        expect(_describe(split(body, isDaily: false)), [
          ['text', 'Intro\n'],
          ['card', card, '2026-09-05', 'b7k2m9', 'c3d4e5'],
          ['text', '\nOutro\n'],
        ]);
        expect(join(split(body, isDaily: false)), body);
      },
    );

    test(
      'an edited text segment with no final newline keeps the marker on its own line',
      () {
        final segments = split('Plan\n$footer', isDaily: false);
        segments[0] = const TextSegment('Plan edited');

        expect(join(segments), 'Plan edited\n$footer');
      },
    );

    test('an edited text segment keeps the footer bytes as they were', () {
      const raw = '$marker  \r\n\r\n#memex  \n[[A~about]]';
      final segments = split('Plan\n$raw', isDaily: false);
      segments[0] = const TextSegment('Plan edited\n');

      expect(join(segments), 'Plan edited\n$raw');
    });

    test('emptying the text segment keeps the footer with no blank line', () {
      final segments = split('Plan\n$footer', isDaily: false);
      segments[0] = const TextSegment('');

      expect(join(segments), footer);
    });

    test('a removed card leaves the footer where it was', () {
      final segments = split('A\n${card}B\n$footer', isDaily: false)
        ..removeAt(1);

      expect(segments.last, isA<FooterSegment>());
      expect(join(segments), 'A\nB\n$footer');
    });

    test(
      'a daily note still joins to the canonical body without tag lines',
      () {
        final segments = split('Day\n$footer', isDaily: true);

        expect(join(segments), 'Day\n$marker\n[[Pricing~about]]\n');
      },
    );
  });
}
