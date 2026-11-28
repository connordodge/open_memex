// WI #80 (Spec #61 F1), fix round 1: carryCurrent carries the current match
// through the change of the whole note code unit by code unit (Reqs 37-38),
// and mapCurrentAcrossMode maps a card match by its token position (Req 39).
// The tests here fail if carryCurrent ignores the edit (the first review
// finding) or takes the card position as token plus the match start.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

FindSource _body(int segment, String text) =>
    FindSource(segment: segment, kind: FindSourceKind.body, text: text);

FindSource _card(int segment, String text) =>
    FindSource(segment: segment, kind: FindSourceKind.card, text: text);

/// The current match index after the change, and the start of the match it
/// is.
({int? index, int? start}) _carry(
  List<FindSource> before,
  int? oldCurrent,
  List<FindSource> after,
) {
  final newMatches = findMatches(after, 'bread');
  final index = carryCurrent(
    before: before,
    oldMatches: findMatches(before, 'bread'),
    oldCurrent: oldCurrent,
    after: after,
    newMatches: newMatches,
  );
  return (index: index, start: index == null ? null : newMatches[index].start);
}

void main() {
  group('carryCurrent through an edit on the current match line', () {
    test(
      'carryCurrent keeps the match after a deletion before it on its line',
      () {
        // One backspace at `ab`: the current second match moves from 9 to 8
        // and is still the second match.
        final r = _carry(
          [_body(0, 'bread ab bread')],
          1,
          [_body(0, 'bread a bread')],
        );
        expect(r.index, 1);
        expect(r.start, 8);
      },
    );

    test(
      'carryCurrent keeps the first match when text before it is deleted',
      () {
        final r = _carry(
          [_body(0, 'xxxx bread bread')],
          0,
          [_body(0, 'bread bread')],
        );
        expect(r.index, 0);
        expect(r.start, 0);
      },
    );

    test(
      'carryCurrent keeps the original match when an insertion adds a match after it',
      () {
        final r = _carry(
          [_body(0, 'one bread two')],
          0,
          [_body(0, 'one bread bread two')],
        );
        expect(r.index, 0);
        expect(r.start, 4);
      },
    );

    test(
      'carryCurrent reads an insertion that repeats its neighbour as after it',
      () {
        // Lead ruling Q2 (prefix first): `bread x bread` -> `bread x breadbread`
        // keeps the second match (index 1, start 8), not the one that follows.
        final r = _carry(
          [_body(0, 'bread x bread')],
          1,
          [_body(0, 'bread x breadbread')],
        );
        expect(r.index, 1);
        expect(r.start, 8);
      },
    );

    test(
      'carryCurrent shifts a match that starts where the changed run starts',
      () {
        // The current match starts exactly at the first changed code unit:
        // the insertion `x bread ` lands before it, so it is carried after
        // the insertion and stays the same (now second) match.
        final r = _carry(
          [_body(0, 'a bread')],
          0,
          [_body(0, 'a x bread bread')],
        );
        expect(r.index, 1);
        expect(r.start, 10);
      },
    );

    test(
      'carryCurrent shifts a match that starts where the unchanged tail starts',
      () {
        // `X` becomes `Y` and a match is added in the run before the current
        // match, which starts exactly where the common tail starts.
        final r = _carry(
          [_body(0, 'aXbread')],
          0,
          [_body(0, 'aYbread Zbread')],
        );
        expect(r.index, 1);
        expect(r.start, 9);
      },
    );

    test('carryCurrent clamps a match inside a shrunk run to the new run', () {
      // `XXXXbread` becomes `YYZ`: the current match was inside the changed
      // run and is gone. It carries to the end of the new run, so the first
      // match at or after it is the one that follows the run, not the next.
      final r = _carry(
        [_body(0, 'abXXXXbreadbread bread')],
        0,
        [_body(0, 'abYYZbread bread')],
      );
      expect(r.index, 0);
      expect(r.start, 5);
    });

    test('carryCurrent keeps a match before the changed run where it was', () {
      final r = _carry(
        [_body(0, 'bread one bread')],
        0,
        [_body(0, 'bread two bread')],
      );
      expect(r.index, 0);
      expect(r.start, 0);
    });

    test('carryCurrent shifts a match after the changed run by the change', () {
      final r = _carry(
        [_body(0, 'bread one bread')],
        1,
        [_body(0, 'bread bread bread bread')],
      );
      // Matches are added in the middle: the last match stays the last.
      expect(r.index, 3);
      expect(r.start, 18);
    });
  });

  group('carryCurrent when a segment is added or removed', () {
    test(
      'carryCurrent keeps the same match when a card segment is added above it',
      () {
        // The note body after the card was split() index 1 and is now 2.
        final before = [_body(0, 'bread'), _body(1, 'bread bread')];
        final after = [
          _body(0, 'bread'),
          _card(1, 'zzz bread'),
          _body(2, 'bread bread'),
        ];
        final r = _carry(before, 2, after);
        expect(findMatches(after, 'bread'), hasLength(4));
        expect(r.index, 3, reason: 'the second match of the last segment');
        expect(r.start, 6);
      },
    );

    test(
      'carryCurrent keeps the same match when a card segment is removed above it',
      () {
        final before = [
          _body(0, 'bread'),
          _card(1, 'zzz bread'),
          _body(2, 'bread bread'),
        ];
        final after = [_body(0, 'bread'), _body(1, 'bread bread')];
        final r = _carry(before, 3, after);
        expect(r.index, 2);
        expect(r.start, 6);
      },
    );
  });

  group('mapCurrentAcrossMode card position (Req 39)', () {
    // Live preview: body 0, card 1 (the bread is 20 code units into the
    // card text), body 2, body 3. Source: one field. The card token starts
    // at 2 and is 7 long, so the Source matches at 9 and 25 lie after it.
    const field = 'a\n![[x]]\nbread\nqqqqqqqqqqbread\n';
    final offsets = {0: 0, 1: 2, 2: 9, 3: 15};
    int tokenOffset(int segment) => offsets[segment]!;

    final live = findMatches([
      _body(0, 'a\n'),
      _card(1, '${'z' * 20}bread'),
      _body(2, 'bread\n'),
      _body(3, 'qqqqqqqqqqbread\n'),
    ], 'bread');
    final source = findMatches([
      const FindSource(segment: 0, kind: FindSourceKind.source, text: field),
    ], 'bread');

    test(
      'mapCurrentAcrossMode puts a card match at its token not at the match start',
      () {
        expect(live.first.kind, FindSourceKind.card);
        expect(live.first.start, 20);
        expect(source.map((m) => m.start), [9, 25]);
        // The card match maps to the first Source match at or after the
        // token (offset 2), which is at 9: not the one at 25 that follows
        // token + 20.
        expect(
          mapCurrentAcrossMode(
            from: live,
            current: 0,
            to: source,
            tokenOffset: tokenOffset,
          ),
          0,
        );
      },
    );
  });
}
