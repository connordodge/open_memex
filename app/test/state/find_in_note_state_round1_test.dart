// WI #80 (Spec #61 F1, TD1), fix round 1: line breaks of every kind in
// useSelection, switchMode open and closed, and carrying the current match
// through a same-line edit by setSources.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

FindInNoteState _state(ProviderContainer c) => c.read(findInNoteProvider);
FindInNoteNotifier _find(ProviderContainer c) =>
    c.read(findInNoteProvider.notifier);

FindSource _body(int segment, String text) =>
    FindSource(segment: segment, kind: FindSourceKind.body, text: text);

void main() {
  group('useSelection line breaks (Req 14)', () {
    for (final (name, text, query) in [
      ('useSelection turns a CRLF into spaces', 'bread\r\none', 'bread one'),
      ('useSelection turns a lone CR into spaces', 'bread\rone', 'bread one'),
      ('useSelection turns a lone LF into spaces', 'bread\none', 'bread one'),
      ('useSelection turns two LFs into spaces', 'bread\n\none', 'bread  one'),
      ('useSelection turns a CRLF then an LF into spaces', 'a\r\n\nb', 'a  b'),
      ('useSelection turns an LF then a CR into spaces', 'a\n\rb', 'a  b'),
    ]) {
      test(name, () {
        final c = _container();
        _find(c).useSelection(text);
        expect(_state(c).query, query);
        expect(_state(c).lastQuery, query);
        expect(_state(c).query, isNot(contains('\r')));
        expect(_state(c).open, isTrue);
      });
    }
  });

  group('switchMode (Req 39)', () {
    const seg0 = 'alpha bread\n';
    const token = '![[2026-01-02#^a1]]\n';
    const seg2 = 'more bread\n';
    final offsets = {0: 0, 1: seg0.length, 2: seg0.length + token.length};
    int tokenOffset(int segment) => offsets[segment]!;
    final live = [
      _body(0, seg0),
      const FindSource(
        segment: 1,
        kind: FindSourceKind.card,
        text: 'fresh bread',
      ),
      _body(2, seg2),
    ];
    final source = [
      const FindSource(
        segment: 0,
        kind: FindSourceKind.source,
        text: '$seg0$token$seg2',
      ),
    ];

    test(
      'switchMode while open keeps the query and maps the current match',
      () {
        final c = _container();
        _find(c)
          ..setSources(live)
          ..show()
          ..setQuery('bread')
          ..next()
          ..next();
        expect(_state(c).current, 2);

        _find(c).switchMode(source, tokenOffset: tokenOffset);

        final s = _state(c);
        expect(s.open, isTrue);
        expect(s.query, 'bread');
        expect(s.sources, source);
        expect(s.matches, findMatches(source, 'bread'));
        expect(s.current, 1);
        expect(s.matches[1].start, tokenOffset(2) + 5);

        _find(c).switchMode(live, tokenOffset: tokenOffset);
        expect(_state(c).sources, live);
        expect(_state(c).matches, findMatches(live, 'bread'));
        expect(_state(c).current, 2);
      },
    );

    test(
      'switchMode while open with no match in the new mode clears current',
      () {
        final c = _container();
        _find(c)
          ..setSources(live)
          ..show()
          ..setQuery('bread');
        _find(c).switchMode([
          const FindSource(segment: 0, kind: FindSourceKind.source, text: 'x'),
        ], tokenOffset: tokenOffset);
        expect(_state(c).matches, isEmpty);
        expect(_state(c).current, isNull);
        expect(_state(c).open, isTrue);
      },
    );

    test('switchMode while closed only stores the sources', () {
      final c = _container();
      _find(c).setSources(live);
      _find(c).switchMode(source, tokenOffset: tokenOffset);
      final s = _state(c);
      expect(s.open, isFalse);
      expect(s.sources, source);
      expect(s.matches, isEmpty);
      expect(s.current, isNull);
      expect(s.query, '');
      expect(s.lastQuery, '');
    });
  });

  group('setSources carries through a same-line edit (Req 38)', () {
    test('setSources keeps the current match after a backspace before it', () {
      final c = _container();
      _find(c)
        ..setSources([_body(0, 'bread ab bread')])
        ..show()
        ..setQuery('bread')
        ..next();
      expect(_state(c).current, 1);

      _find(c).setSources([_body(0, 'bread a bread')]);

      final s = _state(c);
      expect(s.matches.map((m) => m.start), [0, 8]);
      expect(s.current, 1);
    });
  });
}
