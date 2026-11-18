// WI #80 (Spec #61 F1): the current match rules (Reqs 15, 18-19, 37-39) as
// pure functions: the caret anchor, stepping with wrap, carrying through an
// edit, and the Source mode toggle.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

FindMatch _m(int segment, int start, int end, {FindSourceKind? kind}) =>
    FindMatch(
      segment: segment,
      kind: kind ?? FindSourceKind.body,
      start: start,
      end: end,
    );

/// m0 (0, 2-5), m1 (0, 10-13), m2 (card 1, 0-3), m3 (2, 4-7).
final List<FindMatch> _four = [
  _m(0, 2, 5),
  _m(0, 10, 13),
  _m(1, 0, 3, kind: FindSourceKind.card),
  _m(2, 4, 7),
];

FindSource _body(int segment, String text) =>
    FindSource(segment: segment, kind: FindSourceKind.body, text: text);

void main() {
  group('firstAtOrAfter (Req 18)', () {
    test(
      'firstAtOrAfter returns the first match at or after the caret and wraps',
      () {
        // A caret exactly at a match start counts as at it.
        expect(firstAtOrAfter(_four, const FindCaret(0, 2)), 0);
        expect(firstAtOrAfter(_four, const FindCaret(0, 0)), 0);
        // One past a match start moves on.
        expect(firstAtOrAfter(_four, const FindCaret(0, 3)), 1);
        // A later segment comes after any offset in an earlier one.
        expect(firstAtOrAfter(_four, const FindCaret(0, 11)), 2);
        expect(firstAtOrAfter(_four, const FindCaret(0, 999)), 2);
        expect(firstAtOrAfter(_four, const FindCaret(2, 4)), 3);
        // Nothing at or after the caret: wrap to the first match.
        expect(firstAtOrAfter(_four, const FindCaret(2, 5)), 0);
        expect(firstAtOrAfter(_four, const FindCaret(3, 0)), 0);
      },
    );

    test('firstAtOrAfter gives the first match for a null caret', () {
      expect(firstAtOrAfter(_four, null), 0);
      expect(firstAtOrAfter([_m(4, 7, 9)], null), 0);
    });

    test('firstAtOrAfter gives null without matches', () {
      expect(firstAtOrAfter(const [], null), isNull);
      expect(firstAtOrAfter(const [], const FindCaret(0, 3)), isNull);
    });
  });

  group('lastBefore (Req 15)', () {
    test(
      'lastBefore returns the last match before the caret and wraps to the last',
      () {
        expect(lastBefore(_four, const FindCaret(0, 3)), 0);
        // A match starting at the caret is not before it: wrap to the last.
        expect(lastBefore(_four, const FindCaret(0, 2)), 3);
        expect(lastBefore(_four, const FindCaret(0, 0)), 3);
        expect(lastBefore(_four, const FindCaret(0, 10)), 0);
        expect(lastBefore(_four, const FindCaret(0, 11)), 1);
        // An earlier segment comes before any offset in a later one.
        expect(lastBefore(_four, const FindCaret(2, 0)), 2);
        expect(lastBefore(_four, const FindCaret(2, 4)), 2);
        expect(lastBefore(_four, const FindCaret(2, 5)), 3);
        expect(lastBefore(_four, const FindCaret(9, 0)), 3);
      },
    );

    test(
      'lastBefore gives the last match for a null caret and null without matches',
      () {
        expect(lastBefore(_four, null), 3);
        expect(lastBefore(const [], null), isNull);
        expect(lastBefore(const [], const FindCaret(0, 1)), isNull);
      },
    );
  });

  group('stepIndex (Req 19)', () {
    test(
      'stepIndex wraps next from the last to the first and previous from the first to the last',
      () {
        expect(stepIndex(2, 3, forward: true), 0);
        expect(stepIndex(0, 3, forward: false), 2);
      },
    );

    test('stepIndex steps one either way inside the range', () {
      expect(stepIndex(0, 3, forward: true), 1);
      expect(stepIndex(1, 3, forward: true), 2);
      expect(stepIndex(2, 3, forward: false), 1);
      expect(stepIndex(1, 3, forward: false), 0);
      expect(stepIndex(0, 1, forward: true), 0);
      expect(stepIndex(0, 1, forward: false), 0);
    });
  });

  group('carryCurrent (Reqs 37-38)', () {
    int? carry(
      List<FindSource> before,
      int? oldCurrent,
      List<FindSource> after, {
      String query = 'bread',
    }) => carryCurrent(
      before: before,
      oldMatches: findMatches(before, query),
      oldCurrent: oldCurrent,
      after: after,
      newMatches: findMatches(after, query),
    );

    test('carryCurrent keeps the same match through an edit before it', () {
      // A line added above the current match: its offsets shift by 4.
      final before = [_body(0, 'top\nbread one\nbread two')];
      final after = [_body(0, 'top\nnew\nbread one\nbread two')];
      final current = carry(before, 1, after);
      expect(current, 1);
      expect(findMatches(after, 'bread')[current!].start, 18);
    });

    test(
      'carryCurrent keeps the same match through an edit earlier on its line',
      () {
        final before = [_body(0, 'one bread two bread')];
        final after = [_body(0, 'ABone bread two bread')];
        expect(carry(before, 1, after), 1);
      },
    );

    test(
      'carryCurrent keeps the same match when a new match appears in an earlier segment',
      () {
        final before = [_body(0, 'plain'), _body(2, 'bread here')];
        final after = [_body(0, 'plain bread'), _body(2, 'bread here')];
        // The current match moves from index 0 to 1: the same match.
        expect(carry(before, 0, after), 1);
      },
    );

    test(
      'carryCurrent moves a deleted current match to the first match after its old position',
      () {
        final before = [_body(0, 'bread a bread b bread')];
        final after = [_body(0, 'bread a  b bread')];
        expect(carry(before, 1, after), 1);
      },
    );

    test('carryCurrent wraps a deleted last match to the first match', () {
      final before = [_body(0, 'bread x bread')];
      final after = [_body(0, 'bread x ')];
      expect(carry(before, 1, after), 0);
    });

    test(
      'carryCurrent treats a current match whose text changed as deleted',
      () {
        // The current `bread` becomes `brXead`: no match is left at or after
        // its old position, so the current match wraps to the first.
        final before = [_body(0, 'bread and bread')];
        final changed = [_body(0, 'bread and brXead')];
        expect(carry(before, 1, changed), 0);
      },
    );

    test('carryCurrent gives null when no match is left', () {
      final before = [_body(0, 'bread')];
      final after = [_body(0, 'bred')];
      expect(carry(before, 0, after), isNull);
    });
  });

  group('mapCurrentAcrossMode (Req 39)', () {
    // The note: segment 0 body, segment 1 card token, segment 2 body.
    const seg0 = 'alpha bread\n';
    const token = '![[2026-01-02#^a1]]\n';
    const seg2 = 'more bread\n';
    const field = '$seg0$token$seg2';
    final offsets = {0: 0, 1: seg0.length, 2: seg0.length + token.length};
    int tokenOffset(int segment) => offsets[segment]!;

    final live = findMatches([
      _body(0, seg0),
      const FindSource(
        segment: 1,
        kind: FindSourceKind.card,
        text: 'fresh bread',
      ),
      _body(2, seg2),
    ], 'bread');
    final source = findMatches([
      const FindSource(segment: 0, kind: FindSourceKind.source, text: field),
    ], 'bread');

    test('mapCurrentAcrossMode keeps a body current match on its offsets', () {
      // Live preview -> Source: the seg2 body match lands on the same text.
      final toSource = mapCurrentAcrossMode(
        from: live,
        current: 2,
        to: source,
        tokenOffset: tokenOffset,
      );
      expect(toSource, 1);
      expect(source[toSource!].start, tokenOffset(2) + 5);

      final first = mapCurrentAcrossMode(
        from: live,
        current: 0,
        to: source,
        tokenOffset: tokenOffset,
      );
      expect(first, 0);

      // Source -> live preview: the token-position match keeps its position.
      final back = mapCurrentAcrossMode(
        from: source,
        current: 1,
        to: live,
        tokenOffset: tokenOffset,
      );
      expect(back, 2);
    });

    test(
      'mapCurrentAcrossMode maps a card current match to the first match at or after its token',
      () {
        final mapped = mapCurrentAcrossMode(
          from: live,
          current: 1,
          to: source,
          tokenOffset: tokenOffset,
        );
        expect(mapped, 1);

        // A card with nothing at or after its token wraps to the first match.
        final lastCard = findMatches([
          _body(0, 'bread\n'),
          const FindSource(
            segment: 1,
            kind: FindSourceKind.card,
            text: 'bread',
          ),
        ], 'bread');
        final lastField = findMatches([
          const FindSource(
            segment: 0,
            kind: FindSourceKind.source,
            text: 'bread\n![[2026-01-02#^a1]]\n',
          ),
        ], 'bread');
        expect(
          mapCurrentAcrossMode(
            from: lastCard,
            current: 1,
            to: lastField,
            tokenOffset: (s) => s == 0 ? 0 : 6,
          ),
          0,
        );
      },
    );

    test(
      'mapCurrentAcrossMode gives null for no current match or no target matches',
      () {
        expect(
          mapCurrentAcrossMode(
            from: live,
            current: null,
            to: source,
            tokenOffset: tokenOffset,
          ),
          isNull,
        );
        expect(
          mapCurrentAcrossMode(
            from: live,
            current: 0,
            to: const [],
            tokenOffset: tokenOffset,
          ),
          isNull,
        );
      },
    );
  });
}
