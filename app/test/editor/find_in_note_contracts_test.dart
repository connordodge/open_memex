// WI #80 (Spec #61 F1): contracts the first test pass left unpinned (found in
// verify): the case fold of a length-changing letter, the innermost outline
// owner, carrying through a vanished source, hidden ranges given out of
// order, and the counter for an unset current match.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

FindSource _body(String text, {int segment = 0, List<FindRange>? hidden}) =>
    FindSource(
      segment: segment,
      kind: FindSourceKind.body,
      text: text,
      hidden: hidden ?? const [],
    );

FindSource _card(String text, {int segment = 1, List<FindRange>? hidden}) =>
    FindSource(
      segment: segment,
      kind: FindSourceKind.card,
      text: text,
      hidden: hidden ?? const [],
    );

List<(int, int)> _spans(List<FindMatch> matches) => [
  for (final m in matches) (m.start, m.end),
];

void main() {
  group('findMatches case fold keeps offsets (Reqs 5-6)', () {
    test(
      'findMatches keeps source offsets after a letter whose lower case is longer',
      () {
        // U+0130 lower-cases to two code units; the fold must not shift the
        // offsets of what follows it.
        expect(_spans(findMatches([_body('İ bread')], 'bread')), [(2, 7)]);
        // Other letters still fold in a text that holds such a letter.
        expect(_spans(findMatches([_body('İ BREAD')], 'bread')), [(2, 7)]);
        expect(_spans(findMatches([_body('İ Bread')], 'BREAD')), [(2, 7)]);
        // A surrogate pair stays whole and keeps its two code units.
        expect(_spans(findMatches([_body('İ\u{1F600}Bread')], 'bread')), [
          (3, 8),
        ]);
      },
    );

    test('findMatches matches the length-changing letter itself', () {
      expect(_spans(findMatches([_body('xİx')], 'İ')), [(1, 2)]);
      expect(_spans(findMatches([_body('xİx İ')], 'xİ')), [(0, 2)]);
    });
  });

  group('findMatches hidden ranges (Reqs 4, 26)', () {
    test('findMatches reads hidden ranges given out of order', () {
      // `abcdefgh` hides 4-8 and 0-4, given later range first: `cdef` lies
      // wholly in the joined hidden run, so the card drops it.
      final card = _card(
        'abcdefgh',
        hidden: [const FindRange(4, 8), const FindRange(0, 4)],
      );
      expect(findMatches([card], 'cdef'), isEmpty);
      expect(findMatches([card], 'cdefg'), isEmpty);
    });

    test('findMatches checks each match against the hidden ranges near it', () {
      // `aa` at 0 and 6 are hidden, `bb` at 3 is visible, in two ranges.
      final card = _card(
        'aa bb aa',
        hidden: [const FindRange(0, 2), const FindRange(6, 8)],
      );
      expect(findMatches([card], 'aa'), isEmpty);
      expect(_spans(findMatches([card], 'bb')), [(3, 5)]);
      // A hidden range ending exactly where the match starts does not hide it.
      final touching = _card('aabb', hidden: [const FindRange(0, 2)]);
      expect(_spans(findMatches([touching], 'bb')), [(2, 4)]);
    });

    test('findMatches gives the innermost inline element as the outline', () {
      // `**[lab](http://x.com)**`: a link inside a bold run. The link holds
      // the url, so its label is the visible owner, not the bold content.
      const text = '**[lab](http://x.com)**';
      final hidden = [const FindRange(0, 3), const FindRange(6, 23)];
      final url = findMatches([_body(text, hidden: hidden)], 'x.com');
      expect(url, [
        const FindMatch(
          segment: 0,
          kind: FindSourceKind.body,
          start: 15,
          end: 20,
          hidden: true,
          outline: FindRange(3, 6),
        ),
      ]);
      // The leading `**` lies only in the bold run: its content is the owner.
      final stars = findMatches([_body(text, hidden: hidden)], '**');
      expect(stars.map((m) => m.outline), [
        const FindRange(2, 21),
        const FindRange(2, 21),
      ]);
    });
  });

  group('carryCurrent edge cases (Reqs 37-38)', () {
    test('carryCurrent gives null when there was no current match', () {
      final before = [_body('bread')];
      final after = [_body('bread bread')];
      expect(
        carryCurrent(
          before: before,
          oldMatches: findMatches(before, 'bread'),
          oldCurrent: null,
          after: after,
          newMatches: findMatches(after, 'bread'),
        ),
        isNull,
      );
    });

    test(
      'carryCurrent moves a current match whose source vanished to the next match',
      () {
        // Segment 2 held the current match and is gone after the edit; the
        // current match becomes the first match at or after its old place.
        final before = [
          _body('x bread', segment: 1),
          _body('bread', segment: 2),
        ];
        final after = [
          _body('x bread', segment: 1),
          _body('bread', segment: 3),
        ];
        final oldMatches = findMatches(before, 'bread');
        final newMatches = findMatches(after, 'bread');
        expect(
          carryCurrent(
            before: before,
            oldMatches: oldMatches,
            oldCurrent: 1,
            after: after,
            newMatches: newMatches,
          ),
          1,
        );
        // With nothing after it, the current match wraps to the first.
        final onlyEarlier = [_body('x bread', segment: 1)];
        expect(
          carryCurrent(
            before: before,
            oldMatches: oldMatches,
            oldCurrent: 1,
            after: onlyEarlier,
            newMatches: findMatches(onlyEarlier, 'bread'),
          ),
          0,
        );
      },
    );
  });

  group('findCounterText unset current (Req 10)', () {
    test('findCounterText shows an unset current match as 0', () {
      expect(
        findCounterText(
          current: null,
          total: 5,
          query: 'x',
          form: FindCounterForm.full,
        ),
        '0 of 5',
      );
      expect(
        findCounterText(
          current: null,
          total: 5,
          query: 'x',
          form: FindCounterForm.short,
        ),
        '0/5',
      );
    });

    test('findCounterForm keeps short when the field is exactly 96 px', () {
      // 260 - 110 - 54 = 96.
      expect(
        findCounterForm(boxWidth: 260, shortTextWidth: 54),
        FindCounterForm.short,
      );
      expect(
        findCounterForm(boxWidth: 260, shortTextWidth: 54.5),
        FindCounterForm.hidden,
      );
    });
  });
}
