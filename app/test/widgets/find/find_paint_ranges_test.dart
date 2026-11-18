// WI #83 (Spec #61 F3): findPaintRanges, the mapping from F1's
// FindInNoteState (matches, current) to one field's field-local paint
// ranges (Reqs 3, 24-26, 29; D8; pack 83 B3.11, B3.12).
//
// Pure: states are built from F1's own findMatches over hand-made sources.
import 'package:flutter/painting.dart' show TextRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';

const _other = FindPaintStyle.other;
const _current = FindPaintStyle.current;
const _outline = FindPaintStyle.outline;

/// An open state on [sources] with [query], current match [current].
FindInNoteState _wi83State(
  List<FindSource> sources,
  String query, {
  int? current = 0,
  bool open = true,
}) {
  final matches = findMatches(sources, query);
  return FindInNoteState(
    open: open,
    query: query,
    lastQuery: query,
    sources: sources,
    matches: matches,
    current: matches.isEmpty ? null : current,
  );
}

FindSource _wi83Body(int segment, String text, [List<FindRange>? hidden]) =>
    FindSource(
      segment: segment,
      kind: FindSourceKind.body,
      text: text,
      hidden: hidden ?? const [],
    );

/// The hidden ranges of a bold run `**x**` starting at [at] with content
/// length [n]: both markers.
List<FindRange> _wi83BoldMarkers(int at, int n) => [
  FindRange(at, at + 2),
  FindRange(at + 2 + n, at + 4 + n),
];

List<FindPaintRange> _wi83Paint(
  FindInNoteState state, {
  int segment = 0,
  FindSourceKind kind = FindSourceKind.body,
  required int start,
  required int end,
  bool reveals = true,
}) => findPaintRanges(
  state,
  segment: segment,
  kind: kind,
  start: start,
  end: end,
  reveals: reveals,
);

void main() {
  group('visible matches', () {
    test(
      'three matches of rye with the second current paint other current other on their own ranges',
      () {
        const text = 'rye one rye two rye';
        final s = _wi83State([_wi83Body(0, text)], 'rye', current: 1);
        expect(
          _wi83Paint(s, start: 0, end: text.length),
          unorderedEquals(const [
            FindPaintRange(0, 3, _other),
            FindPaintRange(8, 11, _current),
            FindPaintRange(16, 19, _other),
          ]),
        );
      },
    );

    test('ranges are field local: the field start is subtracted', () {
      // Two rows of one segment: row 1 is [8, 19).
      const text = 'a rye b\nc rye d rye';
      final s = _wi83State([_wi83Body(0, text)], 'rye', current: 2);
      expect(
        _wi83Paint(s, start: 8, end: text.length),
        unorderedEquals(const [
          FindPaintRange(2, 5, _other),
          FindPaintRange(8, 11, _current),
        ]),
      );
      expect(_wi83Paint(s, start: 0, end: 7), const [
        FindPaintRange(2, 5, _other),
      ]);
    });

    test('a match crossing the field start or end is clipped to the field', () {
      const text = 'ab cd ef';
      final s = _wi83State([_wi83Body(0, text)], 'b cd e', current: 0);
      // The match is [1, 7). Field [3, 5) holds only `cd`.
      expect(_wi83Paint(s, start: 3, end: 5), const [
        FindPaintRange(0, 2, _current),
      ]);
      // Field [0, 3): the head `b `.
      expect(_wi83Paint(s, start: 0, end: 3), const [
        FindPaintRange(1, 3, _current),
      ]);
      // Field [5, 8): the tail ` e`.
      expect(_wi83Paint(s, start: 5, end: 8), const [
        FindPaintRange(0, 2, _current),
      ]);
    });

    test(
      'a match ending at the field start or starting at the field end paints nothing there',
      () {
        const text = 'rye|bread|rye';
        final s = _wi83State([_wi83Body(0, text)], 'rye', current: 0);
        // Matches [0, 3) and [10, 13); the field is [3, 10).
        expect(_wi83Paint(s, start: 3, end: 10), isEmpty);
        // A field starting exactly at a match start holds it.
        expect(_wi83Paint(s, start: 10, end: 13), const [
          FindPaintRange(0, 3, _other),
        ]);
        // A field ending exactly at a match end holds it.
        expect(_wi83Paint(s, start: 0, end: 3), const [
          FindPaintRange(0, 3, _current),
        ]);
        // One code unit of overlap at either edge still paints that unit.
        expect(_wi83Paint(s, start: 2, end: 11), const [
          FindPaintRange(0, 1, _current),
          FindPaintRange(8, 9, _other),
        ]);
      },
    );

    test('matches of another segment or another kind are not this field', () {
      final s = _wi83State(
        [
          _wi83Body(0, 'rye'),
          const FindSource(segment: 1, kind: FindSourceKind.card, text: 'rye'),
          _wi83Body(2, 'rye rye'),
        ],
        'rye',
        current: 1,
      );
      expect(_wi83Paint(s, segment: 0, start: 0, end: 3), const [
        FindPaintRange(0, 3, _other),
      ]);
      expect(
        _wi83Paint(s, segment: 1, kind: FindSourceKind.card, start: 0, end: 3),
        const [FindPaintRange(0, 3, _current)],
      );
      // Segment 1 asked for as body: the card's match is not it.
      expect(_wi83Paint(s, segment: 1, start: 0, end: 3), isEmpty);
      expect(
        _wi83Paint(s, segment: 2, start: 0, end: 7),
        unorderedEquals(const [
          FindPaintRange(0, 3, _other),
          FindPaintRange(4, 7, _other),
        ]),
      );
      // Segment 0 asked for as a card: nothing.
      expect(
        _wi83Paint(s, segment: 0, kind: FindSourceKind.card, start: 0, end: 3),
        isEmpty,
      );
    });

    test('the paint range keeps its own field local start and end', () {
      // Built from run-time values: a range of non-zero start and end.
      final start = 'x'.length * 4;
      final s = _wi83State([_wi83Body(0, 'abcdrye rye')], 'rye', current: 1);
      final out = _wi83Paint(s, start: start, end: 11)
        ..sort((a, b) => a.start.compareTo(b.start));
      expect(out, hasLength(2));
      expect(out.first.start, 0);
      expect(out.first.end, 3);
      expect(out.first.style, _other);
      expect(out.last, FindPaintRange(start, start + 3, _current));
    });
  });

  group('closed bar and empty query', () {
    test('a closed bar paints nothing even with matches in its state', () {
      const text = 'rye rye';
      final open = _wi83State([_wi83Body(0, text)], 'rye');
      final closed = FindInNoteState(
        query: 'rye',
        lastQuery: 'rye',
        sources: open.sources,
        matches: open.matches,
        current: 0,
      );
      expect(_wi83Paint(open, start: 0, end: 7), hasLength(2));
      expect(_wi83Paint(closed, start: 0, end: 7), isEmpty);
    });

    test('an empty query paints nothing', () {
      final s = _wi83State([_wi83Body(0, 'rye rye')], 'rye');
      expect(_wi83Paint(s, start: 0, end: 7), hasLength(2));
      final empty = s.copyWith(query: '');
      expect(_wi83Paint(empty, start: 0, end: 7), isEmpty);
    });
  });

  group('hidden matches', () {
    // `see [label](https://x.org/rye) rye`: the URL match is hidden; its
    // outline is the label.
    const link = 'see [label](https://x.org/rye) rye';
    final linkHidden = [
      const FindRange(4, 5), // [
      FindRange(10, link.indexOf(' rye', 11)), // ](https://x.org/rye)
    ];
    final label = FindRange(5, 10);
    final url = TextRange(
      start: link.indexOf('rye'),
      end: link.indexOf('rye') + 3,
    );
    final plain = TextRange(
      start: link.lastIndexOf('rye'),
      end: link.lastIndexOf('rye') + 3,
    );

    test('fixture: F1 marks the URL match hidden with the label outline', () {
      final s = _wi83State([_wi83Body(0, link, linkHidden)], 'rye');
      expect(s.matches.first.hidden, isTrue);
      expect(s.matches.first.outline, label);
      expect(s.matches.last.hidden, isFalse);
    });

    test(
      'a hidden non current match in a link URL paints an outline on the link label',
      () {
        final s = _wi83State(
          [_wi83Body(0, link, linkHidden)],
          'rye',
          current: 1,
        );
        expect(
          _wi83Paint(s, start: 0, end: link.length),
          unorderedEquals([
            FindPaintRange(label.start, label.end, _outline),
            FindPaintRange(plain.start, plain.end, _current),
          ]),
        );
      },
    );

    test('a hidden current body match paints current on its own range', () {
      final s = _wi83State([_wi83Body(0, link, linkHidden)], 'rye');
      expect(
        _wi83Paint(s, start: 0, end: link.length),
        unorderedEquals([
          FindPaintRange(url.start, url.end, _current),
          FindPaintRange(plain.start, plain.end, _other),
        ]),
      );
    });

    test('the outline range is clipped to the field and made field local', () {
      final s = _wi83State(
        [
          _wi83Body(0, 'ab\n$link', [
            for (final r in linkHidden) FindRange(r.start + 3, r.end + 3),
          ]),
        ],
        'rye',
        current: 1,
      );
      // The row holding the link starts at 3; a field [6, 11) covers `abel]`.
      expect(
        _wi83Paint(s, start: 3, end: 3 + link.length),
        unorderedEquals([
          FindPaintRange(label.start, label.end, _outline),
          FindPaintRange(plain.start, plain.end, _current),
        ]),
      );
      // The URL match itself lies outside this field; its outline does not.
      expect(_wi83Paint(s, start: 3 + 6, end: 3 + 11), const [
        FindPaintRange(0, 4, _outline),
      ]);
    });

    test('a hidden match with no visible owner paints nothing', () {
      // A hidden heading marker `# ` holds no inline token; the later `#`
      // is plain text and current.
      const text = '# Title and # more';
      final s = _wi83State(
        [
          _wi83Body(0, text, const [FindRange(0, 2)]),
        ],
        '#',
        current: 1,
      );
      expect(s.matches, hasLength(2));
      expect(s.matches.first.hidden, isTrue);
      expect(s.matches.first.outline, isNull);
      expect(_wi83Paint(s, start: 0, end: text.length), const [
        FindPaintRange(12, 13, _current),
      ]);
    });

    test('both hidden markers of one bold run paint its outline once', () {
      // `Bake **hot** now.\nBulk **domed**.`, query `**`: four matches.
      const line1 = 'Bake **hot** now.';
      const line2 = 'Bulk **domed**.';
      const text = '$line1\n$line2';
      final hidden = [
        ..._wi83BoldMarkers(5, 3),
        ..._wi83BoldMarkers(line1.length + 1 + 5, 5),
      ];
      // Current: line 2's second marker (index 3), on another line.
      final s = _wi83State([_wi83Body(0, text, hidden)], '**', current: 3);
      expect(s.matches, hasLength(4));
      expect(s.matches.every((m) => m.hidden), isTrue);
      final line1Paint = _wi83Paint(s, start: 0, end: line1.length);
      expect(line1Paint, const [FindPaintRange(7, 10, _outline)]);
    });

    test(
      'a hidden non current match on the line of a hidden current match paints other on its own range',
      () {
        // Pack 83 B3.12: the current line reveals, so its second `**` is an
        // ordinary other box; line 1 keeps its outline.
        const line1 = 'Bake **hot** now.';
        const line2 = 'Bulk **domed**.';
        const text = '$line1\n$line2';
        final at2 = line1.length + 1;
        final hidden = [
          ..._wi83BoldMarkers(5, 3),
          ..._wi83BoldMarkers(at2 + 5, 5),
        ];
        final s = _wi83State([_wi83Body(0, text, hidden)], '**', current: 2);
        expect(
          _wi83Paint(s, start: 0, end: text.length),
          unorderedEquals([
            const FindPaintRange(7, 10, _outline),
            FindPaintRange(at2 + 5, at2 + 7, _current),
            FindPaintRange(at2 + 12, at2 + 14, _other),
          ]),
        );
        // The same, read as two row fields.
        expect(
          _wi83Paint(s, start: at2, end: text.length),
          unorderedEquals(const [
            FindPaintRange(5, 7, _current),
            FindPaintRange(12, 14, _other),
          ]),
        );
      },
    );

    test(
      'a hidden match on a line next to the hidden current line keeps its outline',
      () {
        // The line boundary: the match right after the current line's line
        // break is on the next line.
        const line1 = 'Bulk **domed**';
        const line2 = '**hot** x';
        const text = '$line1\n$line2';
        final at2 = line1.length + 1;
        final hidden = [..._wi83BoldMarkers(5, 5), ..._wi83BoldMarkers(at2, 3)];
        // Current: line 1's second marker, ending right at the line break.
        final s = _wi83State([_wi83Body(0, text, hidden)], '**', current: 1);
        expect(_wi83Paint(s, start: at2, end: text.length), const [
          FindPaintRange(2, 5, _outline),
        ]);
        expect(
          _wi83Paint(s, start: 0, end: line1.length),
          unorderedEquals(const [
            FindPaintRange(5, 7, _other),
            FindPaintRange(12, 14, _current),
          ]),
        );
      },
    );
  });

  group('table grid cells (D8)', () {
    // One table line; the cell `[flour](https://x.org/rye)` hides its URL.
    const row = '| Dry | see [flour](https://x.org/rye) | rye b |';
    final open = row.indexOf('[');
    final close = row.indexOf('](');
    final hidden = [
      FindRange(open, open + 1),
      FindRange(close, row.indexOf(')') + 1),
    ];
    final flour = FindRange(open + 1, close);
    final cellStart = row.indexOf('see');
    final cellEnd = row.indexOf(')') + 1;

    test(
      'a match wholly in hidden markup inside a grid cell paints an outline also when current',
      () {
        final current = _wi83State(
          [_wi83Body(0, row, hidden)],
          'rye',
          current: 0,
        );
        expect(current.matches.first.hidden, isTrue);
        expect(current.matches.first.outline, flour);
        expect(
          _wi83Paint(current, start: cellStart, end: cellEnd, reveals: false),
          [
            FindPaintRange(
              flour.start - cellStart,
              flour.end - cellStart,
              _outline,
            ),
          ],
        );
        final other = _wi83State(
          [_wi83Body(0, row, hidden)],
          'rye',
          current: 1,
        );
        expect(
          _wi83Paint(other, start: cellStart, end: cellEnd, reveals: false),
          [
            FindPaintRange(
              flour.start - cellStart,
              flour.end - cellStart,
              _outline,
            ),
          ],
        );
      },
    );

    test(
      'a grid cell never reveals: a hidden match on the current line keeps its outline',
      () {
        // Two hidden matches on one table line, the first current.
        const two = '| [a](x/rye) | [b](y/rye) |';
        final h = <FindRange>[];
        for (final m in RegExp(r'\[|\]\([^)]*\)').allMatches(two)) {
          h.add(FindRange(m.start, m.end));
        }
        final s = _wi83State([_wi83Body(0, two, h)], 'rye', current: 0);
        expect(s.matches.every((m) => m.hidden), isTrue);
        expect(
          s.matches.last.outline,
          FindRange(two.indexOf('[b]') + 1, two.indexOf('[b]') + 2),
        );
        final second = two.indexOf('[b]');
        final end = two.lastIndexOf(')') + 1;
        expect(_wi83Paint(s, start: second, end: end, reveals: false), const [
          FindPaintRange(1, 2, _outline),
        ]);
        // The same field where it reveals: other on its own range.
        expect(_wi83Paint(s, start: second, end: end), [
          FindPaintRange(
            two.lastIndexOf('rye') - second,
            two.lastIndexOf('rye') - second + 3,
            _other,
          ),
        ]);
      },
    );

    test('a match spanning two cells paints its part in each cell', () {
      const line = '| Wet | rye here | a lot |';
      final s = _wi83State([_wi83Body(0, line)], 'here | a');
      final c1 = TextRange(
        start: line.indexOf('rye'),
        end: line.indexOf('here') + 4,
      );
      final c2 = TextRange(
        start: line.indexOf('a lot'),
        end: line.indexOf('a lot') + 5,
      );
      expect(
        _wi83Paint(s, start: c1.start, end: c1.end, reveals: false),
        const [FindPaintRange(4, 8, _current)],
      );
      expect(
        _wi83Paint(s, start: c2.start, end: c2.end, reveals: false),
        const [FindPaintRange(0, 1, _current)],
      );
    });
  });

  group('Source and cards', () {
    test('every Source match paints a fill and none an outline', () {
      const text = 'rye [l](https://x.org/rye) **rye**';
      final s = _wi83State(
        [const FindSource(segment: 0, kind: FindSourceKind.source, text: text)],
        'rye',
        current: 1,
      );
      final out = _wi83Paint(
        s,
        kind: FindSourceKind.source,
        start: 0,
        end: text.length,
      );
      expect(out, hasLength(3));
      expect(out.map((r) => r.style), isNot(contains(_outline)));
      expect(
        out,
        unorderedEquals([
          const FindPaintRange(0, 3, _other),
          FindPaintRange(
            text.indexOf('rye', 4),
            text.indexOf('rye', 4) + 3,
            _current,
          ),
          FindPaintRange(
            text.lastIndexOf('rye'),
            text.lastIndexOf('rye') + 3,
            _other,
          ),
        ]),
      );
    });

    test('a card match partly in hidden markup paints its own range', () {
      // Req 4: it counts, not hidden; the painter paints its range (F4 and
      // the zero-width markers show only its visible part).
      const text = 'a **rye** b';
      final s = _wi83State([
        FindSource(
          segment: 3,
          kind: FindSourceKind.card,
          text: text,
          hidden: _wi83BoldMarkers(2, 3),
        ),
      ], '**rye');
      expect(s.matches.single.hidden, isFalse);
      expect(
        _wi83Paint(s, segment: 3, kind: FindSourceKind.card, start: 0, end: 11),
        const [FindPaintRange(2, 7, _current)],
      );
    });
  });

  group('FindPaintRange', () {
    test('equality and hash follow start end and style', () {
      final a = FindPaintRange(1, 'abc'.length, _other);
      expect(a, const FindPaintRange(1, 3, _other));
      expect(a.hashCode, const FindPaintRange(1, 3, _other).hashCode);
      expect(a, isNot(const FindPaintRange(0, 3, _other)));
      expect(a, isNot(const FindPaintRange(1, 4, _other)));
      expect(a, isNot(const FindPaintRange(1, 3, _current)));
      expect(a.toString(), 'FindPaintRange(1, 3, other)');
    });
  });
}
