// WI #80 (Spec #61 F1): matching (Reqs 1-10) and hidden matches with their
// outline (Reqs 4, 26) as pure functions over FindSource lists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

FindSource _body(String text, {int segment = 0, List<FindRange>? hidden}) =>
    FindSource(
      segment: segment,
      kind: FindSourceKind.body,
      text: text,
      hidden: hidden ?? const [],
    );

FindSource _card(
  String text, {
  required int segment,
  List<FindRange>? hidden,
}) => FindSource(
  segment: segment,
  kind: FindSourceKind.card,
  text: text,
  hidden: hidden ?? const [],
);

List<(int, int)> _spans(List<FindMatch> matches) => [
  for (final m in matches) (m.start, m.end),
];

void main() {
  group('findMatches matching (Reqs 5-10)', () {
    test('findMatches folds case so bread matches Bread and BREAD', () {
      final matches = findMatches([_body('Bread, BREAD and bread.')], 'bread');
      expect(_spans(matches), [(0, 5), (7, 12), (17, 22)]);

      // An upper-case query folds too, and the offsets stay the source text.
      final upper = findMatches([_body('a bReAd')], 'BREAD');
      expect(_spans(upper), [(2, 7)]);
    });

    test('findMatches keeps accents and punctuation exact', () {
      expect(findMatches([_body('one café here')], 'cafe'), isEmpty);
      expect(findMatches([_body('a well known name')], 'well-known'), isEmpty);
      // The exact forms do match, with case folding on the accented letter.
      expect(_spans(findMatches([_body('one CAFÉ here')], 'café')), [(4, 8)]);
      expect(_spans(findMatches([_body('a well-known name')], 'well-known')), [
        (2, 12),
      ]);
    });

    test(
      'findMatches never overlaps so aa on aaaa gives matches at 0 and 2',
      () {
        expect(_spans(findMatches([_body('aaaa')], 'aa')), [(0, 2), (2, 4)]);
        // The next search starts after the previous match ends.
        expect(_spans(findMatches([_body('aaa')], 'aa')), [(0, 2)]);
      },
    );

    test('findMatches lets a spaces only query match spaces', () {
      expect(_spans(findMatches([_body('a  b')], '  ')), [(1, 3)]);
      expect(_spans(findMatches([_body('a   b')], '  ')), [(1, 3)]);
      expect(findMatches([_body('a b')], '  '), isEmpty);
    });

    test('findMatches gives nothing for an empty query', () {
      expect(findMatches([_body('bread')], ''), isEmpty);
    });

    test(
      'findMatches orders body card and table matches by segment then offset',
      () {
        final sources = [
          _body('bread first, then bread', segment: 0),
          _card('card bread', segment: 1),
          _body(
            '| bread | rye |\n| --- | --- |\n| more bread | x |',
            segment: 2,
          ),
        ];
        final matches = findMatches(sources, 'bread');
        expect(
          [for (final m in matches) (m.segment, m.kind, m.start)],
          [
            (0, FindSourceKind.body, 0),
            (0, FindSourceKind.body, 18),
            (1, FindSourceKind.card, 5),
            (2, FindSourceKind.body, 2),
            (2, FindSourceKind.body, 37),
          ],
        );
        for (final m in matches) {
          expect(m.end - m.start, 5, reason: '$m');
          expect(m.hidden, isFalse, reason: '$m');
          expect(m.outline, isNull, reason: '$m');
        }

        // Sources given out of order still give document order.
        final shuffled = findMatches([
          sources[2],
          sources[0],
          sources[1],
        ], 'bread');
        expect(shuffled, matches);
      },
    );

    test('findMatches finds Source mode matches in the one Source field', () {
      const field =
          'bread\n![[2026-01-02#^a1]]\n<!-- memex:topics -->\n[[Bread~about]]\n';
      final matches = findMatches([
        const FindSource(segment: 0, kind: FindSourceKind.source, text: field),
      ], 'bread');
      expect(matches, [
        const FindMatch(
          segment: 0,
          kind: FindSourceKind.source,
          start: 0,
          end: 5,
        ),
        FindMatch(
          segment: 0,
          kind: FindSourceKind.source,
          start: field.indexOf('Bread~'),
          end: field.indexOf('Bread~') + 5,
        ),
      ]);
    });

    test('findMatches has no cap so 2431 occurrences give 2431 matches', () {
      final text = List.filled(2431, 'x').join(' ');
      final matches = findMatches([_body(text)], 'x');
      expect(matches, hasLength(2431));
      expect(matches.last.start, text.length - 1);
    });
  });

  group('findMatches hidden matches (Reqs 4, 26)', () {
    test(
      'findMatches drops a card match wholly hidden and counts one partly hidden',
      () {
        // `see [rye](http://rye.example)`: the card hides `[` and `](...)`.
        const text = 'see [rye](http://rye.example)';
        final hidden = [const FindRange(4, 5), FindRange(8, text.length)];
        final card = _card(text, segment: 1, hidden: hidden);

        // `example` lies wholly in the hidden `](url)`: dropped.
        expect(findMatches([card], 'example'), isEmpty);
        // `rye` at 5 is visible, and the `rye` in the url is hidden.
        expect(findMatches([card], 'rye'), [
          const FindMatch(
            segment: 1,
            kind: FindSourceKind.card,
            start: 5,
            end: 8,
          ),
        ]);
        // `rye](` starts visible and ends hidden: it counts, not hidden.
        expect(findMatches([card], 'rye]('), [
          const FindMatch(
            segment: 1,
            kind: FindSourceKind.card,
            start: 5,
            end: 10,
          ),
        ]);
      },
    );

    test(
      'findMatches drops a card match spread over two adjacent hidden ranges',
      () {
        final card = _card(
          'ab**cd',
          segment: 3,
          hidden: [const FindRange(1, 2), const FindRange(2, 4)],
        );
        expect(findMatches([card], 'b**'), isEmpty);
        expect(findMatches([card], 'ab*'), hasLength(1));
      },
    );

    test(
      'findMatches keeps a hidden body match with the link label or bold text as outline',
      () {
        // `see [lab](http://x.com) now`: hidden `[` (4,5) and `](http://x.com)`.
        const link = 'see [lab](http://x.com) now';
        final linkHidden = [const FindRange(4, 5), const FindRange(8, 23)];
        expect(findMatches([_body(link, hidden: linkHidden)], 'x.com'), [
          const FindMatch(
            segment: 0,
            kind: FindSourceKind.body,
            start: 17,
            end: 22,
            hidden: true,
            outline: FindRange(5, 8),
          ),
        ]);

        // `a **bold** b`: hidden `**` at (2,4) and (8,10); the owner is `bold`.
        const bold = 'a **bold** b';
        final boldHidden = [const FindRange(2, 4), const FindRange(8, 10)];
        expect(
          findMatches([_body(bold, segment: 2, hidden: boldHidden)], '**'),
          [
            const FindMatch(
              segment: 2,
              kind: FindSourceKind.body,
              start: 2,
              end: 4,
              hidden: true,
              outline: FindRange(4, 8),
            ),
            const FindMatch(
              segment: 2,
              kind: FindSourceKind.body,
              start: 8,
              end: 10,
              hidden: true,
              outline: FindRange(4, 8),
            ),
          ],
        );

        // `# h`: the heading marker hides `# ` but no inline element owns it.
        expect(
          findMatches([
            _body('# h', hidden: [const FindRange(0, 2)]),
          ], '#'),
          [
            const FindMatch(
              segment: 0,
              kind: FindSourceKind.body,
              start: 0,
              end: 1,
              hidden: true,
            ),
          ],
        );
      },
    );

    test(
      'findMatches marks a partly hidden body match visible with no outline',
      () {
        const bold = 'a **bold** b';
        final hidden = [const FindRange(2, 4), const FindRange(8, 10)];
        final matches = findMatches([_body(bold, hidden: hidden)], '*bo');
        expect(matches, [
          const FindMatch(
            segment: 0,
            kind: FindSourceKind.body,
            start: 3,
            end: 6,
          ),
        ]);
      },
    );

    test('findMatches never marks a Source mode match hidden', () {
      final matches = findMatches([
        const FindSource(
          segment: 0,
          kind: FindSourceKind.source,
          text: 'a **bold** b',
        ),
      ], '**');
      expect(matches.map((m) => m.hidden), [false, false]);
      expect(matches.map((m) => m.outline), [null, null]);
    });
  });

  group('find_in_note.dart stays pure Dart', () {
    test('find_in_note.dart imports no flutter and no dart ui', () {
      final file = File('lib/src/editor/find_in_note.dart');
      expect(file.existsSync(), isTrue);
      final imports = file
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.startsWith('import ') || l.startsWith('export '))
          .toList();
      expect(imports.where((l) => l.contains('package:flutter')), isEmpty);
      expect(imports.where((l) => l.contains('dart:ui')), isEmpty);
    });

    test('FindRange FindMatch and FindCaret compare by value', () {
      final start = DateTime(2026).year - 2026; // 0, built at run time
      expect(FindRange(start, 3), const FindRange(0, 3));
      expect(FindRange(start, 3).hashCode, const FindRange(0, 3).hashCode);
      expect(FindRange(start, 3), isNot(const FindRange(0, 4)));
      expect(FindCaret(1, start), const FindCaret(1, 0));
      expect(FindCaret(1, start).hashCode, const FindCaret(1, 0).hashCode);
      final m = FindMatch(
        segment: start,
        kind: FindSourceKind.body,
        start: 1,
        end: 2,
        hidden: true,
        outline: FindRange(start, 5),
      );
      expect(
        m,
        const FindMatch(
          segment: 0,
          kind: FindSourceKind.body,
          start: 1,
          end: 2,
          hidden: true,
          outline: FindRange(0, 5),
        ),
      );
      expect(
        m,
        isNot(
          const FindMatch(
            segment: 0,
            kind: FindSourceKind.body,
            start: 1,
            end: 2,
          ),
        ),
      );
      final source = FindSource(
        segment: start + 4,
        kind: FindSourceKind.card,
        text: 'x' * (start + 2),
        hidden: [FindRange(start, 1)],
      );
      expect(source.segment, 4);
      expect(source.text, 'xx');
      expect(source.hidden, [const FindRange(0, 1)]);
    });
  });
}
